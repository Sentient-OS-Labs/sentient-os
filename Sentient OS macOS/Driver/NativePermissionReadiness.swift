// Effective helper capability evidence, independent of Full Disk Access and TCC databases.
// A successful service connection or list_apps reply alone never proves AX or capture access.
import Foundation

nonisolated enum NativePermissionReadiness {
    enum State: String, Sendable { case unknown, verified, denied }
    struct Snapshot: Equatable, Sendable {
        var accessibility: State = .unknown
        var screenRecording: State = .unknown
        var isReady: Bool { accessibility == .verified && screenRecording == .verified }
    }
    typealias Call = @Sendable (String, Data) async throws -> Data

    /// Only a fresh, app-owned marker in accessibility text AND a decoded screenshot suffice.
    /// The marker is never supplied as a tool argument, so an echoed request cannot prove access.
    static func verify(app: String, marker: String, isCurrent: @MainActor @Sendable () -> Bool,
                       call: Call) async throws -> Snapshot {
        try Task.checkCancellation()
        guard !marker.isEmpty, await isCurrent() else { throw interrupted() }
        let data = try await call("get_app_state", JSONSerialization.data(withJSONObject: ["app": app]))
        try Task.checkCancellation()
        guard await isCurrent() else { throw interrupted() }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .probe)
        }
        try OpenAIComputerUseProbe.validateResult(result, requiresCapture: false)
        let text = (result["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard text.contains(marker) else { throw interrupted() }
        try OpenAIComputerUseProbe.validateResult(result, requiresCapture: true)
        return Snapshot(accessibility: .verified, screenRecording: .verified)
    }

    /// Only an exact ScreenCaptureKit denial identifies a particular denied grant. Generic
    /// permission/auth/policy failures remain unknown; they must not fabricate two denied grants.
    static func afterFailure(_ failure: NativeComputerUseFailure?) -> Snapshot {
        var snapshot = Snapshot()
        if let failure, ["SCStreamErrorDomain", "com.apple.ScreenCaptureKit.SCStreamErrorDomain"].contains(failure.systemDomain ?? ""),
           failure.systemCode == -3801 { snapshot.screenRecording = .denied }
        return snapshot
    }

    private static func interrupted() -> NativeComputerUseFailure {
        .init(kind: .unknown, code: nil, detail: .testWindowNotObserved, stage: .probe)
    }
}
