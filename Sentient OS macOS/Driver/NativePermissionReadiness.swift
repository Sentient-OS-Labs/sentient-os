// Effective helper capability evidence, independent of Full Disk Access and TCC databases.
// A successful service connection or list_apps reply alone never proves AX or capture access.
// Doc: Documentation - Native Computer Use.md
import Foundation

nonisolated enum NativePermissionReadiness {
    /// The helper owns consent and its live grant indicators. The native request opens its
    /// setup UI when necessary. Useful native results complete the workflow; individual
    /// evidence fields describe only capabilities present in that result.
    static func helperSetup(call: Call) async throws -> Snapshot {
        try Task.checkCancellation()
        // Sentient is already running. Setup must not depend on System Settings being open.
        let data = try await call("get_app_state", JSONSerialization.data(withJSONObject: ["app": Bundle.main.bundleURL.path]))
        try Task.checkCancellation()
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .probe)
        }
        _ = try OpenAIComputerUseProbe.appStateResult(result)
        let hasText = (result["content"] as? [[String: Any]] ?? []).contains(where: {
            $0["type"] as? String == "text" && ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        })
        let hasCapture = (try? OpenAIComputerUseProbe.validateResult(result, requiresCapture: true)) != nil
        return Snapshot(accessibility: hasText ? .verified : .unknown,
                        screenRecording: hasCapture ? .verified : .unknown)
    }

    enum State: String, Sendable { case unknown, verified, denied }
    struct Snapshot: Equatable, Sendable {
        var accessibility: State = .unknown
        var screenRecording: State = .unknown
        var isReady: Bool { accessibility == .verified && screenRecording == .verified }
    }
    struct Evidence: Sendable {
        let snapshot: Snapshot
        fileprivate init(snapshot: Snapshot) { self.snapshot = snapshot }
    }
    typealias Call = @Sendable (String, Data) async throws -> Data
    typealias TimedCall = @Sendable (String, Data, TimeInterval) async throws -> Data
    enum ReadOutcome: String, Sendable { case passed, retrying, failed, cancelled }
    struct ReadObservation: Sendable {
        let readIndex: Int
        let elapsedMilliseconds: Int
        // nil means this boundary was not reached, rather than evidence of lost focus.
        let beforeCurrent: Bool?
        let afterCurrent: Bool?
        let markerObserved: Bool
        let captureValidated: Bool
        let outcome: ReadOutcome
        let detail: NativeComputerUseFailure.Detail?
    }
    typealias ReadObserver = @Sendable (ReadObservation) -> Void

    /// Only a fresh, app-owned marker in accessibility text AND a decoded screenshot suffice.
    /// The marker is never supplied as a tool argument, so an echoed request cannot prove access.
    static func verify(app: String, marker: String, isCurrent: @MainActor @Sendable () -> Bool,
                       call: Call) async throws -> Snapshot {
        try await verify(app: app, marker: marker, isCurrent: isCurrent) { tool, arguments, _ in
            try await call(tool, arguments)
        }
    }

    /// The transport must honor each remaining timeout. A healthy, valid-image reply that
    /// misses the marker gets one settling read, within the original deadline, never actions.
    static func verify(app: String, marker: String, isCurrent: @MainActor @Sendable () -> Bool,
                       timeout: TimeInterval = 12, observe: ReadObserver = { _ in },
                       timedCall: TimedCall) async throws -> Snapshot {
        let clock = ContinuousClock()
        let validTimeout = timeout.isFinite && timeout > 0
        let deadline = clock.now.advanced(by: .seconds(validTimeout ? timeout : 0))
        let arguments = try JSONSerialization.data(withJSONObject: ["app": app])
        for attempt in 0..<2 {
            let started = clock.now
            var beforeCurrent: Bool?, afterCurrent: Bool?
            var markerObserved = false, captureValidated = false
            var outcome = ReadOutcome.failed
            var detail: NativeComputerUseFailure.Detail?
            defer {
                let elapsed = started.duration(to: clock.now).components
                let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                // Only closed values leave the verifier: no response, nonce, path or error text.
                observe(ReadObservation(readIndex: attempt + 1,
                    elapsedMilliseconds: Int(min(120_000, max(0, milliseconds))),
                    beforeCurrent: beforeCurrent, afterCurrent: afterCurrent,
                    markerObserved: markerObserved, captureValidated: captureValidated,
                    outcome: outcome, detail: detail))
            }
            do {
                try Task.checkCancellation()
                guard validTimeout else { throw timedOut() }
                // The second attempt owns its settling wait, including cancellation before
                // dispatch. Its observation therefore does not imply a second native call.
                if attempt > 0 { try await Task.sleep(for: .milliseconds(150)) }
                beforeCurrent = await isCurrent()
                guard beforeCurrent == true else { throw interrupted(.testWindowNotCurrentBeforeRead) }
                guard !marker.isEmpty else { throw interrupted(.testWindowMarkerMissing) }
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { throw timedOut() }
                let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
                let data = try await timedCall("get_app_state", arguments, seconds)
                try Task.checkCancellation()
                afterCurrent = await isCurrent()
                guard afterCurrent == true else { throw interrupted(.testWindowNotCurrentAfterRead) }
                guard clock.now < deadline else { throw timedOut() }
                guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .probe)
                }
                do {
                    _ = try accessibilityText(in: result, marker: marker)
                    markerObserved = true
                } catch let failure as NativeComputerUseFailure {
                    guard attempt == 0, failure.detail == .testWindowMarkerMissing else { throw failure }
                    // A missing marker alone can be AX publication lag. Do not retry missing
                    // or invalid screenshots, native errors, cancelled reads or changed windows.
                    try OpenAIComputerUseProbe.validateResult(result, requiresCapture: true)
                    captureValidated = true
                    guard clock.now.advanced(by: .milliseconds(150)) < deadline else { throw failure }
                    outcome = .retrying; detail = failure.detail
                    continue
                }
                try OpenAIComputerUseProbe.validateResult(result, requiresCapture: true)
                captureValidated = true
                try Task.checkCancellation()
                guard clock.now < deadline else { throw timedOut() }
                outcome = .passed
                return Snapshot(accessibility: .verified, screenRecording: .verified)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    outcome = .cancelled
                    throw CancellationError()
                }
                detail = (error as? NativeComputerUseFailure)?.detail ?? .unspecified
                throw error
            }
        }
        throw interrupted(.testWindowMarkerMissing)
    }

    /// Shared with the richer owned-window diagnostic. Only typed text blocks establish AX
    /// evidence; unrelated fields, images and echoed request arguments cannot supply a nonce.
    static func accessibilityText(in result: [String: Any], marker: String) throws -> String {
        try OpenAIComputerUseProbe.validateResult(result, requiresCapture: false)
        let text = (result["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !marker.isEmpty, text.contains(marker) else { throw interrupted(.testWindowMarkerMissing) }
        return text
    }

    static func evidence(in result: [String: Any], marker: String) throws -> Evidence {
        _ = try accessibilityText(in: result, marker: marker)
        try OpenAIComputerUseProbe.validateResult(result, requiresCapture: true)
        return Evidence(snapshot: Snapshot(accessibility: .verified, screenRecording: .verified))
    }

    /// Only an exact ScreenCaptureKit denial identifies a particular denied grant. Generic
    /// permission/auth/policy failures remain unknown; they must not fabricate two denied grants.
    static func afterFailure(_ failure: NativeComputerUseFailure?) -> Snapshot {
        var snapshot = Snapshot()
        if let failure, ["SCStreamErrorDomain", "com.apple.ScreenCaptureKit.SCStreamErrorDomain"].contains(failure.systemDomain ?? ""),
           failure.systemCode == -3801 { snapshot.screenRecording = .denied }
        return snapshot
    }

    private static func interrupted(_ detail: NativeComputerUseFailure.Detail) -> NativeComputerUseFailure {
        .init(kind: .unknown, code: nil, detail: detail, stage: .probe)
    }

    private static func timedOut() -> NativeComputerUseFailure {
        .init(kind: .timeout, code: nil, detail: .requestTimedOut, stage: .probe)
    }
}
