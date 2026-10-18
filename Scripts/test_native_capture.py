#!/usr/bin/env python3
"""Exercise native error/image contracts and the real model-free session with a fake RPC peer.
No model calls, permission changes, screen contents, or telemetry. Requires macOS + Swift.
Real-window capture acceptance is separate because it needs a signed native helper.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"
SUPPORT = r'''
import Foundation
nonisolated enum OpenAIComputerUse {
    struct Configuration: Sendable {
        let cliURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_RPC_PEER"]!)
        let clientEnvironment = ProcessInfo.processInfo.environment
        let codexOverrides: [String] = []
    }
}
__REAL_CAPTURE_SCRUBBER__
nonisolated enum Diagnostics {
    struct Payload { let event: String; let tags: [String:String]; let extra: [String:String] }
}
nonisolated struct CaptureDiagnostics {
    enum Source { case healthProbe }
    enum Outcome { case passed, failed, cancelled }
    init(source: Source) {}
    static func environment() async -> [String:String] { [:] }
    func record(_ outcome: Outcome, failure: NativeComputerUseFailure? = nil, fields: [String:String] = [:]) {}
}
'''
# Compile the real scrubber bodies; approved capture IDs/cases must survive the upload backstop.
scrubber_source = (APP / "Diagnostics/CrashReporting.swift").read_text()
scrub_data = scrubber_source[scrubber_source.index("    nonisolated static func scrubData("):scrubber_source.index("    // MARK: - Helpers")]
scrub_text = scrubber_source[scrubber_source.index("    nonisolated static func scrub(text:"):scrubber_source.rfind("}")]
SUPPORT = SUPPORT.replace("__REAL_CAPTURE_SCRUBBER__", "nonisolated enum CrashReporting {\n" + scrub_data + scrub_text + "\n}")
PEER = r'''#!/usr/bin/env python3
import json, sys, time, os
for line in sys.stdin:
    obj = json.loads(line)
    method = obj.get('method')
    if 'id' not in obj: continue
    if method == 'initialize': result = {}
    elif method == 'thread/start':
        assert obj['params']['sandbox'] == 'danger-full-access'
        assert obj['params']['ephemeral'] is True
        assert obj['params']['approvalPolicy'] == 'never'
        result = {'thread': {'id': 'test-thread'}}
    elif method == 'mcpServer/tool/call':
        tool = obj['params']['tool']
        if tool == 'disconnect': sys.exit(23)
        if tool == 'malformed': print('not json', flush=True); continue
        if tool == 'hang': time.sleep(20); continue
        if tool == 'rpc-error':
            print(json.dumps({'id':obj['id'],'error':{'code':-32603,'message':'Computer Use server error -10005: screenshotCaptureFailed'}}),flush=True)
            continue
        result = {'content': [{'type':'text','text':'synthetic'}]}
    else: raise AssertionError(method)
    print(json.dumps({'id':obj['id'],'result':result}),flush=True)
'''
TESTS = r'''
import Foundation
import ImageIO
import UniformTypeIdentifiers
@main struct Tests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError(label) }; count += 1
    }
    static func main() async throws {
        let cases: [(String, NativeComputerUseFailure.Kind, NativeComputerUseFailure.Detail)] = [
            ("screenshotCaptureFailed", .capture, .screenshotCaptureFailed),
            ("unknownCaptureFailed", .capture, .unknownCaptureFailed),
            ("noWindowsAvailable", .noWindows, .noWindowsAvailable),
            ("timeoutReached", .timeout, .timeoutReached),
            ("Sender process is not authenticated", .permission, .senderNotAuthenticated),
            ("Computer Use approval denied via MCP elicitation for app 'PRIVATE'", .permission, .approvalDenied),
            ("windowNotFoundForID", .noWindows, .windowNotFoundForID),
            ("blockedByPolicy", .permission, .blockedByPolicy),
            ("could not create image from display", .capture, .displayUnavailable)]
        for (text, kind, detail) in cases {
            let failure = NativeComputerUseFailure.classify(["error":["code":-32603,
                "data":["content":[["type":"text","text":"Computer Use server error -10005: " + text]]]]])
            check(failure.kind == kind && failure.detail == detail, "classify " + text)
            check(failure.code == -10005 && failure.rpcCode == -32603, "separate native and RPC codes")
        }
        let nested = NativeComputerUseFailure.classify(["structuredContent":["error":["message":"screenshotCaptureFailed",
            "data":["domain":"SCStreamErrorDomain","code":-3807]]]])
        check(nested.systemDomain == "SCStreamErrorDomain" && nested.systemCode == -3807, "structured underlying OS error")
        let ns = NativeComputerUseFailure.classify("screenshotCaptureFailed Error Domain=SCStreamErrorDomain Code=-3807 \"PRIVATE\"")
        check(ns.systemCode == -3807, "text underlying OS error")
        let privateText = "PRIVATE person@example.com /Users/private/Secret.txt mail message"
        let unknown = NativeComputerUseFailure.classify(["error":["message":privateText]])
        check(unknown.detail == .unspecified, "opaque errors stay opaque")
        check(unknown.fields["underlying_error_available"] == "false", "missing cause is explicit")
        check(!unknown.fields.values.joined().contains("PRIVATE"), "no private error text")
        check(NativeComputerUseFailure.from(item:["type":"mcp_tool_call","server":"sentient_native","status":"completed",
              "result":["content":[["type":"text","text":"screenshotCaptureFailed"]]]]) == nil, "successful app text is not an error")
        let context = CGContext(data:nil,width:4,height:4,bitsPerComponent:8,bytesPerRow:16,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        check(CGImageDestinationFinalize(destination), "generate synthetic PNG")
        let valid: [String:Any] = ["content":[["type":"image","data":(bytes as Data).base64EncodedString()]]]
        try OpenAIComputerUseProbe.validateResult(valid, requiresCapture:true); count += 1
        for (content, detail) in [([["type":"text","text":"done"]], NativeComputerUseFailure.Detail.missingImage),
                                   ([["type":"image","data":"invalid"]], .invalidImage)] {
            do { try OpenAIComputerUseProbe.validateResult(["content":content],requiresCapture:true); fatalError("accepted invalid capture") }
            catch let failure as NativeComputerUseFailure { check(failure.detail == detail, "invalid image classified") }
        }
        let accessibility = "Synthetic accessibility: editable element 7, text is empty"
        let textState: [String:Any] = ["content": [["type":"text", "text":accessibility]]]
        let textOnly = try OpenAIComputerUseProbe.appStateResult(textState)
        check((textOnly["content"] as? [[String:Any]])?.first?["text"] as? String == accessibility,
              "Runtime preserves useful accessibility state without requiring screenshot")
        let mixed: [String:Any] = ["content": [["type":"text", "text":accessibility], ["type":"image", "data":"invalid"]]]
        let cleaned = try OpenAIComputerUseProbe.appStateResult(mixed)
        let cleanedBlocks = cleaned["content"] as! [[String:Any]]
        check(cleanedBlocks.first?["text"] as? String == accessibility, "Broken screenshot does not discard accessibility tree")
        check(!cleanedBlocks.contains { $0["type"] as? String == "image" }, "Invalid image bytes cannot break provider input")
        check(cleanedBlocks.last?["text"] as? String != nil && cleanedBlocks.count == 2, "Missing image is disclosed to model")
        let imageOnly = try OpenAIComputerUseProbe.appStateResult(valid)
        check((imageOnly["content"] as? [[String:Any]])?.first?["type"] as? String == "image", "Valid screenshot-only state remains supported")
        let unusable: [[String:Any]] = [[:], ["content": []], ["content": [["type":"text", "text":"  \n"]]],
                                  ["content": [["type":"image", "data":"invalid"]]],
                                  ["isError":true, "content": [["type":"text", "text":accessibility]]]]
        for bad in unusable {
            do { _ = try OpenAIComputerUseProbe.appStateResult(bad); fatalError("accepted error or empty state") }
            catch is NativeComputerUseFailure { count += 1 }
        }
        let captureID = UUID().uuidString
        let scrubbed = CrashReporting.scrubData(["capture_id":captureID,"native_detail":"failedToGetWindowIDForElement", "path":"/Users/private/Secret.txt"])
        check(scrubbed["capture_id"] as? String == captureID, "capture correlation survives Sentry scrubber")
        check(scrubbed["native_detail"] as? String == "failedToGetWindowIDForElement", "known native case survives Sentry scrubber")
        check(scrubbed["path"] as? String == "<redacted>", "scrubber still removes paths")
        let unsafe = CrashReporting.scrubData(["capture_id":"PRIVATE_TOKEN_ABCDEFGHIJKLMNOPQRSTUV", "native_detail":"PRIVATE_TOKEN_ABCDEFGHIJKLMNOPQRSTUV"])
        check(unsafe.values.allSatisfy { ($0 as? String)?.contains("PRIVATE") == false }, "unknown values cannot use capture allowlist")
        let suite = "native-capture-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        var fields = ns.fields
        fields.merge(["capture_source":"native", "capture_outcome":"failed", "capture_id":UUID().uuidString,
                      "capture_attempt":"1", "raw_error":privateText, "window_title":privateText, "image":"PRIVATE"]) { _,new in new }
        DiagnosticHistory.recordCapture(fields, defaults:defaults)
        let exported = try DiagnosticHistory.snapshot(defaults:defaults).errors.last!
        check(exported.fields["system_error_code"] == "-3807", "OS code survives local export")
        check(exported.fields["failure_stage"] == "app_state", "failure stage survives local export")
        DiagnosticHistory.recordCapture(["capture_outcome":"failed", "native_detail":"failedToGetWindowIDForElement"],defaults:defaults)
        check(try! DiagnosticHistory.snapshot(defaults:defaults).errors.last?.fields["native_detail"] == "failedToGetWindowIDForElement", "known native case survives local export scrubber")
        check(exported.fields["raw_error"] == nil && exported.fields["window_title"] == nil && exported.fields["image"] == nil, "raw data excluded from export")
        let exportedJSON = try JSONEncoder().encode(exported)
        check(!String(decoding:exportedJSON,as:UTF8.self).contains("PRIVATE"), "no private content in stored error")
        let session = try await OpenAIComputerUseSession.open(.init())
        let result = try await session.call("list_apps",arguments:Data("{}".utf8))
        check(!result.isEmpty, "real transport initialized with capture-capable policy")
        do { _ = try await session.call("rpc-error",arguments:Data("{}".utf8)); fatalError("RPC error accepted") }
        catch let failure as NativeComputerUseFailure { check(failure.rpcCode == -32603 && failure.code == -10005, "transport preserves both error codes") }
        await session.close(); count += 1
        for tool in ["disconnect","malformed"] {
            let session = try await OpenAIComputerUseSession.open(.init())
            do { _ = try await session.call(tool,arguments:Data("{}".utf8)); fatalError("broken transport accepted") }
            catch let failure as NativeComputerUseFailure { check(failure.kind == .connection, "transport failure is typed") }
            await session.close()
        }
        let cancelSession = try await OpenAIComputerUseSession.open(.init())
        let task = Task { try await cancelSession.call("hang",arguments:Data("{}".utf8)) }
        try await Task.sleep(for:.milliseconds(100))
        let began = Date(); task.cancel()
        do { _ = try await task.value; fatalError("cancel ignored") } catch is CancellationError { count += 1 }
        await cancelSession.close()
        check(Date().timeIntervalSince(began) < 4, "STOP bounds process cleanup")
        let deadlineSession = try await OpenAIComputerUseSession.open(.init())
        let deadlineBegan = Date()
        do {
            _ = try await deadlineSession.call("hang", arguments: Data("{}".utf8), timeout: 0.12)
            fatalError("per-read deadline was ignored")
        } catch let failure as NativeComputerUseFailure {
            check(failure.kind == .timeout && failure.detail == .requestTimedOut,
                  "per-read deadline closes transport with a typed non-retryable timeout")
        }
        await deadlineSession.close()
        check(Date().timeIntervalSince(deadlineBegan) < 4, "per-read deadline bounds request plus owned cleanup")
        print("PASS \(count) native capture assertions")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="sentient-capture-contract-") as directory:
    root = Path(directory)
    (root / "Support.swift").write_text(SUPPORT)
    (root / "Tests.swift").write_text(TESTS)
    peer = root / "peer"
    peer.write_text(PEER)
    peer.chmod(0o700)
    binary = root / "tests"
    env = dict(os.environ, TEST_RPC_PEER=str(peer))
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-target", "arm64-apple-macos15.0",
                    str(root / "Support.swift"), str(root / "Tests.swift"),
                    str(APP / "Diagnostics/NativeComputerUseFailure.swift"),
                    str(APP / "Diagnostics/DiagnosticHistory.swift"),
                    str(APP / "Driver/OpenAIComputerUseSession.swift"),
                    str(APP / "Driver/OpenAIComputerUseProbe.swift"), "-o", str(binary)], check=True, env=env)
    subprocess.run([str(binary)], check=True, env=env, timeout=45)
