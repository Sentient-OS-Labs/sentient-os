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
    func observed(_ tool: String, arguments: Data) throws {
        count += 1
        precondition(tool == "get_app_state")
        let args = try JSONSerialization.jsonObject(with: arguments) as! [String:String]
        precondition(args == ["app":"fixture.app"], "Only the owned app is requested; nonce is not echoed")
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
        do {
            _ = try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{false}) { _,_ in fatalError("Hidden window read") }
            fatalError("Hidden window accepted")
        } catch let failure as NativeComputerUseFailure { check(failure.detail == .testWindowNotObserved,"Lost window is interruption") }
        var stillCurrent = true
        do {
            _ = try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{stillCurrent}) { _,_ in
                await MainActor.run { stillCurrent = false }; return payload
            }
            fatalError("Changed window accepted")
        } catch let failure as NativeComputerUseFailure { check(failure.detail == .testWindowNotObserved,"Focus change cannot produce proof") }
        let task = Task {
            try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true}) { _,_ in
                try await Task.sleep(for:.seconds(30)); return payload
            }
        }
        try await Task.sleep(for:.milliseconds(10)); task.cancel()
        do { _ = try await task.value; fatalError("Cancellation ignored") }
        catch is CancellationError { count += 1 }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NativePermissionReadiness.verify(app:"fixture.app",marker:marker,isCurrent:{true}) { _,_ in fatalError("Cancelled read started") }
        }
        do { _ = try await cancelled.value; fatalError("Pre-cancellation ignored") }
        catch is CancellationError { count += 1 }
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
