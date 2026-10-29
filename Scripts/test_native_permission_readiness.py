#!/usr/bin/env python3
"""Verify effective native readiness with synthetic in-memory replies and inert peers.
No permission reads/writes, windows, model, user preferences/storage or real helper processes.
"""
from pathlib import Path
import platform
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'
SUPPORT = r'''
import Foundation
nonisolated enum OpenAIComputerUse { struct Configuration: Sendable {} }
actor OpenAIComputerUseSession {
    static func open(_ configuration: OpenAIComputerUse.Configuration) async throws -> OpenAIComputerUseSession { fatalError("No real session") }
    func call(_ name: String, arguments: Data) async throws -> Data { fatalError("No real session") }
    func close() {}
}
nonisolated struct CaptureDiagnostics {
    enum Source { case healthProbe }; enum Outcome { case passed, failed, cancelled }
    init(source: Source) {}
    static func environment() async -> [String:String] { [:] }
    func record(_ value: Outcome, failure: NativeComputerUseFailure? = nil, fields: [String:String]) {}
}
actor Calls {
    var count = 0
    var timeouts: [TimeInterval] = []
    func observed(_ tool: String, arguments: Data) throws {
        count += 1
        precondition(tool == "get_app_state")
        let args = try JSONSerialization.jsonObject(with: arguments) as! [String:String]
        precondition(args == ["app":"fixture.app"], "Only the owned app is requested; nonce is not echoed")
    }
    func observed(_ tool: String, arguments: Data, timeout: TimeInterval) throws {
        try observed(tool, arguments: arguments)
        precondition(timeout > 0 && timeout <= 12, "Each read receives a bounded remaining budget")
        timeouts.append(timeout)
    }
}
final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NativePermissionReadiness.ReadObservation] = []
    func append(_ value: NativePermissionReadiness.ReadObservation) {
        lock.lock(); defer { lock.unlock() }; storage.append(value)
    }
    var values: [NativePermissionReadiness.ReadObservation] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}
'''
TESTS = r'''
import Foundation
import ImageIO
import UniformTypeIdentifiers
@main struct Tests {
    @MainActor static var count = 0
    @MainActor static func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
    @MainActor static func main() async throws {
        let marker = "Sentient check " + UUID().uuidString
        let context = CGContext(data:nil,width:4,height:4,bitsPerComponent:8,bytesPerRow:16,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let image: [String:Any] = ["type":"image","data":(bytes as Data).base64EncodedString()]
        let calls = Calls()
        let payload = try JSONSerialization.data(withJSONObject:["content":[["type":"text","text":"1 text " + marker],image]])
        let verified = try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true}) { tool,args in
            try await calls.observed(tool,arguments:args); return payload
        }
        check(verified.isReady, "AX marker and valid image prove readiness without TCC")
        check(await calls.count == 1, "Exactly one read and no actions")
        check(!NativePermissionReadiness.Snapshot().isReady, "Unknown grants never pass")
        let unproven: [[String:Any]] = [
            ["content":[["type":"text","text":"fixture.app"]]], // list_apps-style service success
            ["content":[["type":"text","text":marker]]], // AX alone
            ["content":[image]], // screenshot alone
            ["content":[["type":"text","text":"Another window"],image]],
            ["content":[["type":"text","text":marker],["type":"image","data":"bad"]]],
            ["content":[]], ["isError":true,"content":[["type":"text","text":marker],image]]
        ]
        for invalid in unproven {
            let data = try JSONSerialization.data(withJSONObject:invalid)
            do {
                _ = try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true}) { _,_ in data }
                fatalError("Unproven capability accepted")
            } catch is NativeComputerUseFailure { count += 1 }
        }
        for error in [NativeComputerUseFailure(kind:.timeout,code:nil,detail:.requestTimedOut),
                      .init(kind:.permission,code:nil,detail:.senderNotAuthenticated),
                      .init(kind:.capture,code:nil,detail:.screenshotCaptureFailed)] {
            do {
                _ = try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true}) { _,_ in throw error }
                fatalError("Tool failure swallowed")
            } catch let returned as NativeComputerUseFailure { check(returned == error,"Original failure survives") }
            let unknown = NativePermissionReadiness.afterFailure(error)
            check(!unknown.isReady && unknown.accessibility == .unknown && unknown.screenRecording == .unknown,
                  "Generic error never claims permission denied or granted")
        }
        let denial = NativePermissionReadiness.afterFailure(.init(kind:.permission,code:nil,detail:.permissionDenied,
            systemDomain:"SCStreamErrorDomain",systemCode:-3801))
        check(denial.screenRecording == .denied && denial.accessibility == .unknown,"Exact OS denial affects only its grant")
        let beforeLost = Observations()
        do {
            _ = try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{false},observe:{ beforeLost.append($0) }) { _,_,_ in fatalError("Hidden window read") }
            fatalError("Hidden window accepted")
        } catch let failure as NativeComputerUseFailure {
            check(failure.detail == .testWindowNotCurrentBeforeRead && failure.isReadinessInterruption,
                  "Pre-read window loss has its own interruption detail")
        }
        check(beforeLost.values.count == 1 && beforeLost.values[0].beforeCurrent == false && beforeLost.values[0].afterCurrent == nil
              && beforeLost.values[0].detail == .testWindowNotCurrentBeforeRead,"Pre-read observation does not invent an unsampled post-read boundary")
        var stillCurrent = true
        let afterLost = Observations()
        do {
            _ = try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{stillCurrent},observe:{ afterLost.append($0) }) { _,_,_ in
                await MainActor.run { stillCurrent = false }; return payload
            }
            fatalError("Changed window accepted")
        } catch let failure as NativeComputerUseFailure {
            check(failure.detail == .testWindowNotCurrentAfterRead && failure.isReadinessInterruption,
                  "Post-read focus change cannot produce proof and has its own detail")
        }
        check(afterLost.values.count == 1 && afterLost.values[0].beforeCurrent == true && afterLost.values[0].afterCurrent == false
              && !afterLost.values[0].markerObserved && !afterLost.values[0].captureValidated,
              "Changed-window result is not treated as validated AX or capture evidence")
        let missingMarker = try JSONSerialization.data(withJSONObject:["content":[["type":"text","text":"Window is publishing"],image]])
        let retried = Calls()
        let retryObservations = Observations()
        let settled = try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true},observe:{ retryObservations.append($0) },timedCall:{tool,args,remaining in
            try await retried.observed(tool,arguments:args,timeout:remaining)
            return await retried.count == 1 ? missingMarker : payload
        })
        let budgets = await retried.timeouts
        check(settled.isReady && budgets.count == 2,"A healthy missing-marker reply gets exactly one settling retry")
        check(budgets[1] < budgets[0] - 0.1,"Settling and the first read consume the same overall budget")
        let reads = retryObservations.values
        check(reads.count == 2 && reads.map(\.readIndex) == [1,2] && reads.map(\.outcome) == [.retrying,.passed],
              "Successful retry produces exactly two ordered bounded observations")
        check(reads[0].beforeCurrent == true && reads[0].afterCurrent == true && !reads[0].markerObserved
              && reads[0].captureValidated && reads[0].detail == .testWindowMarkerMissing,
              "Retry metadata records the healthy image and missing marker")
        check(reads[1].markerObserved && reads[1].captureValidated && reads[1].detail == nil,
              "Successful read records both independently established evidence flags")
        let missing = Calls()
        let missingObservations = Observations()
        do {
            _ = try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true},observe:{ missingObservations.append($0) },timedCall:{tool,args,remaining in
                try await missing.observed(tool,arguments:args,timeout:remaining); return missingMarker
            })
            fatalError("Missing marker accepted")
        } catch let failure as NativeComputerUseFailure {
            check(failure.detail == .testWindowMarkerMissing && failure.isReadinessInterruption,
                  "Two healthy reads without the marker preserve the specific failure")
        }
        check(await missing.count == 2,"No third read or unbounded marker retry")
        check(missingObservations.values.map(\.outcome) == [.retrying,.failed]
              && missingObservations.values.last?.detail == .testWindowMarkerMissing,
              "Final missing marker remains a failed observation, not another retry")
        let short = Calls()
        do {
            _ = try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true},timeout:0.05,timedCall:{tool,args,remaining in
                try await short.observed(tool,arguments:args,timeout:remaining); return missingMarker
            })
            fatalError("Missing marker accepted with short deadline")
        } catch let failure as NativeComputerUseFailure {
            check(failure.detail == .testWindowMarkerMissing,"An insufficient retry budget preserves the observed marker failure")
        }
        check(await short.count == 1,"No settling read after its budget is exhausted")
        for invalid in [
            ["content":[["type":"text","text":"No marker"]]],
            ["content":[["type":"text","text":"No marker"],["type":"image","data":"invalid"]]],
            ["isError":true,"content":[["type":"text","text":"Computer Use server error -10005: permissionDenied"],image]]
        ] as [[String:Any]] {
            let once = Calls(), data = try JSONSerialization.data(withJSONObject:invalid)
            do {
                _ = try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true},timedCall:{tool,args,remaining in
                    try await once.observed(tool,arguments:args,timeout:remaining); return data
                })
                fatalError("Unhealthy reply accepted")
            } catch is NativeComputerUseFailure { count += 1 }
            check(await once.count == 1,"Capture and native failures are never retried as marker publication lag")
        }
        let expiredObservation = Observations()
        do {
            _ = try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true},timeout:0,observe:{ expiredObservation.append($0) },timedCall:{_,_,_ in
                fatalError("Expired deadline dispatched a tool")
            })
            fatalError("Expired deadline accepted")
        } catch let failure as NativeComputerUseFailure { check(failure.detail == .requestTimedOut,"Expired budget never dispatches") }
        check(expiredObservation.values.count == 1 && expiredObservation.values[0].beforeCurrent == nil
              && expiredObservation.values[0].afterCurrent == nil && expiredObservation.values[0].detail == .requestTimedOut,
              "Expired admission is observed without fabricating a focus check or native read")
        let lateObservation = Observations()
        do {
            _ = try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true},timeout:0.01,observe:{ lateObservation.append($0) },timedCall:{_,_,_ in
                try await Task.sleep(for:.milliseconds(20)); return payload
            })
            fatalError("Late success accepted")
        } catch let failure as NativeComputerUseFailure { check(failure.detail == .requestTimedOut,"A late reply cannot publish readiness") }
        check(lateObservation.values.count == 1 && lateObservation.values[0].afterCurrent == true
              && !lateObservation.values[0].markerObserved && !lateObservation.values[0].captureValidated
              && lateObservation.values[0].detail == .requestTimedOut,"Late result observation cannot claim evidence validation")
        let evidence = try NativePermissionReadiness.evidence(in:JSONSerialization.jsonObject(with:payload) as! [String:Any],marker:marker)
        check(evidence.snapshot.isReady,"Doctor can use the same strict evidence validator")
        do {
            _ = try NativePermissionReadiness.evidence(in:["content":[["type":"other","text":marker],image]],marker:marker)
            fatalError("Marker in non-text content accepted")
        } catch let failure as NativeComputerUseFailure { check(failure.detail == .testWindowMarkerMissing,"Only typed text can establish the marker") }
        do {
            _ = try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true},timedCall:{_,_,_ in Data("not json".utf8) })
            fatalError("Malformed JSON accepted")
        } catch let failure as NativeComputerUseFailure { check(failure.detail == .malformedResponse,"Malformed JSON has a stable content-free error") }
        do {
            _ = try await NativePermissionReadiness.verify(app:"fixture.app",marker:"",isCurrent:{true},timedCall:{_,_,_ in
                fatalError("Empty nonce dispatched a tool")
            })
            fatalError("Empty nonce accepted")
        } catch let failure as NativeComputerUseFailure { check(failure.detail == .testWindowMarkerMissing,"Empty nonce cannot establish evidence") }
        var retryCurrent = true
        let focusDuringSettle = Task {
            try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{retryCurrent},timedCall:{_,_,_ in missingMarker })
        }
        try await Task.sleep(for:.milliseconds(50)); retryCurrent = false
        do { _ = try await focusDuringSettle.value; fatalError("Settling retry ignored focus change") }
        catch let failure as NativeComputerUseFailure { check(failure.detail == .testWindowNotCurrentBeforeRead,"Settling does not recapture a changed window") }
        let settleObservations = Observations()
        let cancelDuringSettle = Task {
            try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true},observe:{ settleObservations.append($0) },timedCall:{_,_,_ in missingMarker })
        }
        try await Task.sleep(for:.milliseconds(50)); cancelDuringSettle.cancel()
        do { _ = try await cancelDuringSettle.value; fatalError("Settling ignored cancellation") }
        catch is CancellationError { count += 1 }
        check(settleObservations.values.map(\.outcome) == [.retrying,.cancelled]
              && settleObservations.values[1].readIndex == 2 && settleObservations.values[1].beforeCurrent == nil,
              "Cancellation during settling is observed before the second native read")
        let cancelledObservations = Observations()
        let task = Task {
            try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true},observe:{ cancelledObservations.append($0) }) { _,_,_ in
                try await Task.sleep(for:.seconds(30)); return payload
            }
        }
        try await Task.sleep(for:.milliseconds(10)); task.cancel()
        do { _ = try await task.value; fatalError("Cancellation ignored") }
        catch is CancellationError { count += 1 }
        check(cancelledObservations.values.count == 1 && cancelledObservations.values[0].outcome == .cancelled
              && cancelledObservations.values[0].beforeCurrent == true && cancelledObservations.values[0].afterCurrent == nil,
              "Transport cancellation emits once and does not sample a post-read focus check")
        let preCancelledObservations = Observations()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true},observe:{ preCancelledObservations.append($0) }) { _,_,_ in fatalError("Cancelled read started") }
        }
        do { _ = try await cancelled.value; fatalError("Pre-cancellation ignored") }
        catch is CancellationError { count += 1 }
        check(preCancelledObservations.values.count == 1 && preCancelledObservations.values[0].outcome == .cancelled
              && preCancelledObservations.values[0].beforeCurrent == nil && preCancelledObservations.values[0].detail == nil,
              "Pre-cancellation emits a closed cancellation outcome without an invented native error")

        let privateText = "PRIVATE_WINDOW_TITLE_AND_CUSTOMER_CONTENT"
        let privatePath = "/private/customer/example.app"
        let nativeFailure = NativeComputerUseFailure(kind:.permission,code:nil,detail:.permissionDenied,
            systemDomain:privateText,modelError:privateText + marker + privatePath)
        let observedFailures: [(Data?,NativeComputerUseFailure.Detail,Bool)] = [
            (try JSONSerialization.data(withJSONObject:["content":[["type":"text","text":marker + privateText]]]),.missingImage,true),
            (try JSONSerialization.data(withJSONObject:["content":[["type":"text","text":marker],["type":"image","data":privateText]]]),.invalidImage,true),
            (try JSONSerialization.data(withJSONObject:["isError":true,"content":[["type":"text","text":"permissionDenied " + privateText + marker]]]),.permissionDenied,false),
            (Data(privateText.utf8),.malformedResponse,false),
            (nil,.permissionDenied,false)
        ]
        var allObservations = reads + missingObservations.values + beforeLost.values + afterLost.values
            + expiredObservation.values + lateObservation.values + settleObservations.values
            + cancelledObservations.values + preCancelledObservations.values
        for (data, expected, sawMarker) in observedFailures {
            let log = Observations()
            do {
                _ = try await NativePermissionReadiness.verify(app:privatePath,marker:marker,isCurrent:{true},observe:{ log.append($0) },timedCall:{_,_,_ in
                    if let data { return data }; throw nativeFailure
                })
                fatalError("Failure accepted")
            } catch is NativeComputerUseFailure { count += 1 }
            let entries = log.values
            check(entries.count == 1 && entries[0].outcome == .failed && entries[0].detail == expected
                  && entries[0].markerObserved == sawMarker && !entries[0].captureValidated,
                  "Failure observations distinguish AX evidence from validated capture without retry")
            allObservations += entries
        }
        for (error, expected) in [
            (NativeComputerUseFailure(kind:.timeout,code:nil,detail:.requestTimedOut) as any Error, NativeComputerUseFailure.Detail.requestTimedOut),
            (NSError(domain:privateText,code:99,userInfo:[NSLocalizedDescriptionKey:privateText + marker]) as any Error, .unspecified)
        ] {
            let log = Observations()
            do {
                _ = try await NativePermissionReadiness.verify(app:privatePath,marker:marker,isCurrent:{true},observe:{ log.append($0) },timedCall:{_,_,_ in throw error })
                fatalError("Transport failure accepted")
            } catch { count += 1 }
            check(log.values.count == 1 && log.values[0].outcome == .failed && log.values[0].detail == expected
                  && log.values[0].beforeCurrent == true && log.values[0].afterCurrent == nil,
                  "Transport timeout and opaque errors emit fixed details without a fabricated response")
            allObservations += log.values
        }
        check(allObservations.allSatisfy { (1...2).contains($0.readIndex) && (0...120_000).contains($0.elapsedMilliseconds) },
              "Every observation has a bounded read index and elapsed duration")
        let metadata = String(reflecting:allObservations)
        check(!metadata.contains(marker) && !metadata.contains(privateText) && !metadata.contains(privatePath),
              "Observation values cannot retain nonce, app path, window contents or native error text")
        print("PASS \(count) no-FDA native permission assertions")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-permission-readiness-') as directory:
    root = Path(directory)
    (root/'Support.swift').write_text(SUPPORT)
    (root/'Tests.swift').write_text(TESTS)
    binary = root/'check'
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-target',f'{platform.machine()}-apple-macos15.0',
                    str(root/'Support.swift'),str(root/'Tests.swift'),
                    *[str(APP/f) for f in ['Diagnostics/NativeComputerUseFailure.swift','Driver/OpenAIComputerUseProbe.swift','Driver/NativePermissionReadiness.swift']],
                    '-o',str(binary)],check=True,timeout=60)
    subprocess.run([str(binary)],check=True,timeout=15)
