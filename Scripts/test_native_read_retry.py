#!/usr/bin/env python3
"""Compile the real native MCP server/read policy against an inert scripted session.

Exercises production retry delays, model continuation, cancellation, state fencing and RPC replay without
starting a helper, capturing a screen, changing permissions, calling a model or networking.
NSWorkspace is read only to choose an unambiguous running app for the identity gate.
Requires macOS + Swift. All generated images, RPC data and diagnostics are synthetic.
"""
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"
SUPPORT = r'''
import Foundation
import AppKit

nonisolated enum OpenAIComputerUse {
    static let bundleID = "fixture.native"
    struct Configuration: Sendable { let script: Script }
}

actor Script {
    enum Reply: Sendable { case data(Data), failure(NativeComputerUseFailure) }
    struct Call: Sendable {
        let tool: String
        let arguments: Data
        let timeout: TimeInterval
        let uptime: TimeInterval
    }
    private var remaining: [Reply]
    private var observed: [Call] = []
    init(_ replies: [Reply]) { remaining = replies }
    func call(_ tool: String, arguments: Data, timeout: TimeInterval) throws -> Data {
        observed.append(Call(tool: tool, arguments: arguments, timeout: timeout,
                             uptime: ProcessInfo.processInfo.systemUptime))
        guard !remaining.isEmpty else { fatalError("Unexpected extra native call: \(tool)") }
        switch remaining.removeFirst() {
        case .data(let data): return data
        case .failure(let failure): throw failure
        }
    }
    func calls() -> [Call] { observed }
}

actor OpenAIComputerUseSession {
    let script: Script
    init(script: Script) { self.script = script }
    static func open(_ configuration: OpenAIComputerUse.Configuration) async throws -> OpenAIComputerUseSession {
        OpenAIComputerUseSession(script: configuration.script)
    }
    func catalog() throws -> Data {
        let names = ["list_apps", "get_app_state", "click", "perform_secondary_action", "set_value",
                     "select_text", "scroll", "drag", "press_key", "type_text"]
        return try JSONSerialization.data(withJSONObject: ["data": [["name": "sentient_native",
            "tools": Dictionary(uniqueKeysWithValues: names.map { ($0, ["name": $0]) })]]])
    }
    func call(_ tool: String, arguments: Data, timeout: TimeInterval = 125) async throws -> Data {
        try await script.call(tool, arguments: arguments, timeout: timeout)
    }
    func close() {}
    func isUsable() -> Bool { true }
}

actor LocalMCPServer {
    nonisolated struct Connection: Sendable {}
    init(name: String, tools: [String], timeout: TimeInterval, maximumBody: Int,
         response: @escaping @Sendable (Data) async throws -> Data) {}
    func start() async throws -> Connection { Connection() }
    func stop() {}
}

nonisolated struct CaptureDiagnostics: Sendable {
    enum Source: String, Sendable { case native, healthProbe }
    enum Outcome: String, Sendable { case started, passed, failed, recovered, cancelled, skipped }
    struct Entry: Sendable {
        let outcome: Outcome
        let attempt: Int
        let failure: NativeComputerUseFailure?
        let fields: [String: String]
    }
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Entry] = []
        func append(_ entry: Entry) { lock.lock(); defer { lock.unlock() }; storage.append(entry) }
        func entries() -> [Entry] { lock.lock(); defer { lock.unlock() }; return storage }
        func reset() { lock.lock(); defer { lock.unlock() }; storage.removeAll() }
    }
    static let log = Log()
    init(source: Source, context: CaptureDiagnostics? = nil) {}
    @MainActor static func environment(target: NSRunningApplication? = nil) -> [String: String] { [:] }
    func record(_ outcome: Outcome, attempt: Int = 1, failure: NativeComputerUseFailure? = nil,
                fields: [String: String] = [:]) {
        Self.log.append(Entry(outcome: outcome, attempt: attempt, failure: failure, fields: fields))
    }
}

// Run the actual stream reader with inert, scripted CLI lines.
actor StreamScript {
    private var lines: [String] = []
    func set(_ lines: [String]) { self.lines = lines }
    func snapshot() -> [String] { lines }
}
nonisolated enum CodexCLI {
    struct ExecResult: Sendable { let status: Int32 }
    static let script = StreamScript()
    static func executeStreaming(binary: String, args: [String], timeout: TimeInterval,
                                 extraEnv: [String: String], onLine: @Sendable (String) throws -> Void) async throws -> ExecResult {
        for line in await script.snapshot() { try onLine(line) }
        return ExecResult(status: 0)
    }
}
nonisolated final class SidekickInteraction: Sendable {
    func endExecution(streamID: UUID) {}
    func observeToolEvent(_ line: String, streamID: UUID) throws {}
    static let current: SidekickInteraction? = nil
    let computerUseCheckConsent = ComputerUseDiagnosticConsent()
}
nonisolated enum AgentRunDiagnostics {
    struct Context: Sendable {
        func observe(_ line: String) {}
        func recordProcess(status: Int32) {}
    }
    static let current: Context? = nil
}
nonisolated enum SidekickConversationRun {
__ACTUAL_HIDDEN_TOOL_POLICY__
}
@MainActor final class OpenAIComputerUseRuntime {
    static let shared = OpenAIComputerUseRuntime()
    private(set) var invalidations = 0
    func invalidate() { invalidations += 1 }
}
@MainActor final class TargetSlot {
    var value: String?
    init(_ value: String?) { self.value = value }
    func set(_ value: String?) { self.value = value }
}
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

'''
# Compile the actual small pure filter without pulling the app-owned conversation model
# into this transport fixture. Hidden-message/telemetry assertions must use production policy.
_run_source = (APP / "Notch Magic/SidekickConversationRun.swift").read_text()
_hidden_start = _run_source.index("    static func hidden(server:")
_hidden_end = _run_source.index("    static func answerText(", _hidden_start)
SUPPORT = SUPPORT.replace("__ACTUAL_HIDDEN_TOOL_POLICY__", _run_source[_hidden_start:_hidden_end])

SUPPORT += r'''
nonisolated enum ModelBackend: Sendable { case chatgpt; static let current = ModelBackend.chatgpt }

nonisolated enum Permissions {
    enum TCCState { case granted, denied, notAsked, unavailable }
    enum AutomationState { case granted, denied, notAsked, unavailable }
    static func nativeAutomationState(ask: Bool) async -> AutomationState { .granted }
    static func hasScreenRecording() -> Bool { true }
    static func tccState(service: String, clientBundleID: String) -> TCCState { .granted }
}

@MainActor final class ComputerUseDoctor {
    static let shared = ComputerUseDoctor()
    func checkFromAgent(authorization: ComputerUseDiagnosticAuthorization, backend: ModelBackend, call: @escaping @Sendable (String, Data) async throws -> Data) async throws -> Data {
        fatalError("A normal failed tool must never automatically trigger diagnostics")
    }
}
'''
SUPPORT += r'''
@MainActor final class NativePermissionCheck {
    static let shared = NativePermissionCheck()
    var snapshot = NativePermissionReadiness.Snapshot(accessibility: .verified, screenRecording: .verified)
    var invalidations = 0
    func refresh() {}
    func invalidate(failure: NativeComputerUseFailure? = nil) {
        invalidations += 1; snapshot = NativePermissionReadiness.afterFailure(failure)
    }
}
'''
TESTS = r'''
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct Tests {
    static var count = 0
    static let app = "/Applications/Synthetic.app"
    static func check(_ value: Bool, _ label: String) { guard value else { fatalError(label) }; count += 1 }
    static func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: .sortedKeys) }
    static func request(_ id: Int, _ tool: String = "get_app_state") throws -> Data {
        try json(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool,
            "arguments": ["app": app, "synthetic_marker": "same-read", "element_index": 2]]])
    }
    static func error(_ detail: NativeComputerUseFailure.Detail, code: Int = -10005) throws -> Script.Reply {
        try errorText("Computer Use server error \(code): \(detail.rawValue)")
    }
    static func errorText(_ value: String) throws -> Script.Reply {
        .data(try json(["isError": true, "content": [["type": "text", "text": value]]]))
    }
    static func result(_ reply: Data) throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: reply) as! [String: Any])["result"] as! [String: Any]
    }
    static func item(_ reply: Data, tool: String = "get_app_state", encoding: Int = 0) throws -> [String: Any] {
        var payload = try result(reply)
        var event: [String: Any] = ["type": "mcp_tool_call", "server": "sentient_native", "tool": tool, "status": "completed"]
        if encoding == 3 {
            let first = (payload["content"] as! [[String: Any]]).first!["text"] as! String
            event["status"] = "failed"; event["result"] = NSNull(); event["error"] = ["message": first]
            return event
        }
        if encoding > 0 {
            payload["structured_content"] = payload.removeValue(forKey: "structuredContent")
            payload["is_error"] = payload.removeValue(forKey: "isError")
        }
        if encoding == 2 {
            // Exact pinned Codex exec formatter: status:failed, error:null, no result error flag.
            payload.removeValue(forKey: "is_error"); event["status"] = "failed"; event["error"] = NSNull()
        }
        event["result"] = payload
        return event
    }
    static func failure(_ reply: Data, tool: String = "get_app_state", encoding: Int = 0) throws -> NativeComputerUseFailure {
        guard let failure = NativeComputerUseFailure.from(item: try item(reply, tool: tool, encoding: encoding)) else {
            fatalError("Expected diagnostic failure")
        }
        return failure
    }
    static func open(_ replies: [Script.Reply]) async throws -> (NativeComputerUseServer, Script) {
        CaptureDiagnostics.log.reset()
        let script = Script(replies)
        let server = NativeComputerUseServer(configuration: .init(script: script), resolveTarget: { _ in app })
        _ = try await server.start()
        return (server, script)
    }
    static func stream(_ reply: Data, tool: String = "get_app_state", expectedStage: NativeComputerUseFailure.Stage? = nil) async throws {
        for encoding in 0...3 {
            let native = try item(reply, tool: tool, encoding: encoding)
            if encoding != 3, let expectedStage {
                check(NativeComputerUseFailure.from(item: native)?.stage == expectedStage, "Metadata retains original diagnostic stage")
            }
            let event = String(decoding: try json(["type": "item.completed", "item": native]), as: UTF8.self)
            let final = String(decoding: try json(["type": "item.completed", "item": ["type": "agent_message", "text": "agent explains or continues"]]), as: UTF8.self)
            await CodexCLI.script.set([event, final])
            let before = await OpenAIComputerUseRuntime.shared.invalidations
            let output = Lines()
            let result = try await ComputerUseStream.run(binary: "inert", args: [], timeout: 1) { output.append($0) }
            check(result.status == 0, "Failed tool does not abort model execution")
            check(output.snapshot().contains("agent explains or continues"), "Agent can deliver its own response after any tool failure")
            let after = await OpenAIComputerUseRuntime.shared.invalidations
            check(after == before, "Tool-result failure does not invalidate native runtime")
        }
    }
    static func assertReads(_ calls: [Script.Call], _ expected: Int) {
        check(calls.count == expected && calls.allSatisfy { $0.tool == "get_app_state" }, "Only bounded reads retried")
        check(calls.allSatisfy { $0.arguments == calls.first?.arguments }, "Automatic read arguments unchanged")
        check(calls.allSatisfy { $0.timeout.isFinite && $0.timeout > 0 && $0.timeout <= 90 }, "Each read shares finite deadline")
        for index in 1..<calls.count {
            let delay = NativeAppStateRetry.delays[index - 1]
            check(calls[index].uptime - calls[index - 1].uptime >= delay - 0.05, "Actual delay precedes native retry")
            check(calls[index].timeout < calls[index - 1].timeout - delay + 0.05, "Read deadline is not reset per attempt")
        }
    }

    static func progressModes() async throws {
        let items: [(String, [String: Any])] = [
            ("item.started", ["id": "native", "type": "mcp_tool_call", "server": "sentient_native", "tool": "get_app_state", "arguments": ["app": "com.spotify.client"]]),
            ("item.started", ["id": "message", "type": "mcp_tool_call", "server": "sentient_recovery", "tool": "message_user"]),
            ("item.started", ["id": "telemetry", "type": "mcp_tool_call", "server": "sentient_recovery", "tool": "describe_task_usage"]),
            ("item.started", ["id": "command", "type": "command_execution", "command": "synthetic command"]),
            ("item.started", ["id": "search", "type": "web_search", "query": "synthetic query"]),
            ("item.completed", ["id": "answer", "type": "agent_message", "text": "Synthetic outer narration."])]
        let events = try items.map { String(decoding: try json(["type": $0.0, "item": $0.1]), as: UTF8.self) }
        var toolOutputs: [[String]] = []
        for narration in [true, false] {
            await CodexCLI.script.set(events)
            let output = Lines()
            let result = try await ComputerUseStream.run(binary: "inert", args: [], timeout: 1, narrate: narration) { output.append($0) }
            let lines = output.snapshot()
            check(result.status == 0, "Both provider narration modes complete")
            check(lines.contains("→ sentient_native.get_app_state"), "Native activity remains visible for both providers")
            check(lines.contains("Synthetic outer narration.") == narration, "Only outer assistant narration follows narrate flag")
            check(!lines.contains { $0.contains("message_user") || $0.contains("describe_task_usage") }, "Message and telemetry wrappers stay hidden in both modes")
            let command = lines.firstIndex(of: "exec")!
            check(Array(lines[command..<command + 4]) == ["exec", "synthetic command", "codex", "→ command_execution"], "Command marker follows exec section reset in both modes")
            check(lines.contains("🔎 synthetic query"), "Web search remains visible in both modes")
            toolOutputs.append(lines.filter { $0.hasPrefix("→ ") || $0.hasPrefix("🔎 ") })
        }
        check(toolOutputs[0] == toolOutputs[1], "Actual executor tool progress is identical with ChatGPT and Claude narration modes")
    }

    static func policy() {
        check(NativeAppStateRetry.delays == [2, 3, 5] && NativeAppStateRetry.timeout == 90, "Existing read grace retained")
        let eligible: Set<NativeComputerUseFailure.Detail> = [.timeoutReached, .noWindowsAvailable, .windowNotFoundForID,
            .windowNotFoundAtPosition, .failedToGetWindowIDForElement, .screenshotCaptureFailed, .screenCaptureFailed, .unknownCaptureFailed]
        let stages: [NativeComputerUseFailure.Stage] = [.initialize, .thread, .catalog, .transport, .appState, .imageDecode, .action, .recovery, .probe]
        for stage in stages {
            for detail in NativeComputerUseFailure.Detail.allCases {
                let failure = NativeComputerUseFailure.classify(detail.rawValue, stage: stage)
                let permitted = eligible.contains(detail) && [.appState, .imageDecode].contains(stage)
                check(NativeAppStateRetry.delay(afterAttempt: 1, failure: failure, elapsed: 0) == (permitted ? 2 : nil), "Automatic retries remain strictly read-only")
            }
        }
        let transient = NativeComputerUseFailure(kind: .timeout, code: nil, detail: .timeoutReached)
        for attempt in 1...3 {
            let delay = NativeAppStateRetry.delays[attempt - 1]
            check(NativeAppStateRetry.delay(afterAttempt: attempt, failure: transient, elapsed: 0) == delay, "Backoff attempt mapping")
            check(NativeAppStateRetry.delay(afterAttempt: attempt, failure: transient, elapsed: 90 - delay) == nil, "Exhausted request budget cannot retry")
        }
        for attempt in [Int.min, -1, 0, 4, Int.max] {
            check(NativeAppStateRetry.delay(afterAttempt: attempt, failure: transient, elapsed: 0) == nil, "Invalid attempt rejected")
        }
        for elapsed in [-1.0, .nan, .infinity, -.infinity, 90, 100] {
            check(NativeAppStateRetry.delay(afterAttempt: 1, failure: transient, elapsed: elapsed) == nil, "Invalid elapsed time rejected")
        }
    }
    static func main() async throws {
        policy()
        try await progressModes()
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        check(CGImageDestinationFinalize(destination), "Synthetic image generated")
        let image = Script.Reply.data(try json(["content": [["type": "image", "data": (bytes as Data).base64EncodedString()]]]))
        let text = Script.Reply.data(try json(["content": [["type": "text", "text": "synthetic app accessibility state"]]]))
        let empty = Script.Reply.data(try json(["content": []]))
        let invalidImage = Script.Reply.data(try json(["content": [["type": "image", "data": "invalid"]]]))

        do {
            let (server, script) = try await open([try error(.timeoutReached), image])
            let rpc = try request(1)
            let reply = try await server.respond(rpc)
            check(!NativeComputerUseFailure.isError(try result(reply)), "Cold-start read recovers")
            assertReads(await script.calls(), 2)
            check(CaptureDiagnostics.log.entries().map(\.outcome) == [.skipped, .recovered], "Read recovery diagnostics")
            let cached = try await server.respond(rpc)
            check(cached == reply, "Same request ID returns cached reply")
            let calls = await script.calls()
            check(calls.count == 2, "Cached request never repeats native calls")
            await server.stop()
        }
        do {
            let (server, script) = try await open([try error(.timeoutReached), try error(.noWindowsAvailable),
                try error(.screenshotCaptureFailed), try error(.windowNotFoundForID, code: -12345), image])
            let reply = try await server.respond(request(2))
            check(try failure(reply).detail == .windowNotFoundForID && failure(reply).code == -12345, "Exhausted request preserves final native error")
            assertReads(await script.calls(), 4)
            try await stream(reply, expectedStage: .appState)
            let next = try await server.respond(request(3))
            check(!NativeComputerUseFailure.isError(try result(next)), "Exhausted read does not poison later model request")
            let calls = await script.calls()
            check(calls.count == 5, "New explicit request may read again")
            await server.stop()
        }
        do {
            let (server, script) = try await open([try error(.noWindowsAvailable), try error(.windowNotFoundAtPosition),
                try error(.screenCaptureFailed), image])
            let reply = try await server.respond(request(4))
            check(!NativeComputerUseFailure.isError(try result(reply)), "Fourth read may succeed")
            assertReads(await script.calls(), 4)
            check(CaptureDiagnostics.log.entries().last?.attempt == 4, "Final recovery attempt recorded")
            await server.stop()
        }

        // All failed actions return useful errors without ending the agent or poisoning later calls.
        let failures: [(Script.Reply, NativeComputerUseFailure.Detail, NativeComputerUseFailure.Stage)] = [
            (try errorText("Computer Use server error -10005: Cannot set a value for an element that is not settable"), .unspecified, .action),
            (try error(.permissionDenied), .permissionDenied, .action),
            (try error(.senderNotAuthenticated), .senderNotAuthenticated, .action),
            (try error(.approvalDenied), .approvalDenied, .action),
            (try error(.blockedByPolicy), .blockedByPolicy, .action),
            (try error(.staleState), .staleState, .action),
            (try error(.invalidArguments), .invalidArguments, .action),
            (try error(.noWindowsAvailable), .noWindowsAvailable, .action),
            (try error(.timeoutReached), .timeoutReached, .action),
            (.failure(.init(kind: .timeout, code: nil, detail: .requestTimedOut, stage: .transport)), .requestTimedOut, .transport),
            (.failure(.init(kind: .connection, code: nil, detail: .disconnected, stage: .transport)), .disconnected, .transport),
            (.data(Data("not-json".utf8)), .malformedResponse, .transport)]
        for (nativeError, expected, stage) in failures {
            let (server, script) = try await open([image, nativeError, text, text])
            _ = try await server.respond(request(10))
            let rpc = try request(11, "set_value")
            let reply = try await server.respond(rpc)
            check(try failure(reply, tool: "set_value", encoding: 2).detail == expected, "Original action diagnostic retained")
            check(try result(reply)["isError"] as? Bool == true, "Failed action honestly marked failed")
            let blocks = try result(reply)["content"] as! [[String: Any]]
            let first = blocks.first!["text"] as! String
            check(blocks.count == 1 && first.contains("get_app_state"), "Model sees complete error and fresh-state guidance in first block")
            check(first.contains("effects may be unknown"), "Unknown action effects explained")
            if expected == .unspecified {
                check(first.contains("Cannot set a value for an element that is not settable"), "Actionable unsupported-set_value reason retained")
                if let path = ProcessInfo.processInfo.environment["TEST_NATIVE_ERROR_FIXTURE"] {
                    try json(result(reply)).write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            }
            try await stream(reply, tool: "set_value", expectedStage: stage)
            let cached = try await server.respond(rpc)
            check(cached == reply, "Failed action deduplicated by request ID")
            let stale = try await server.respond(request(12, "type_text"))
            check(try failure(stale, tool: "type_text").detail == .staleState, "Failure clears state before another mutation")
            let beforeRead = await script.calls()
            check(beforeRead.count == 2, "No automatic mutation replay or stale mutation")
            let state = try await server.respond(request(13))
            check(!NativeComputerUseFailure.isError(try result(state)), "Later explicit read can recover after every error class")
            let corrected = try await server.respond(request(14, "type_text"))
            check(!NativeComputerUseFailure.isError(try result(corrected)), "Model can select fallback after fresh state")
            let calls = await script.calls()
            check(calls.map(\.tool) == ["get_app_state", "set_value", "get_app_state", "type_text"], "Each mutation requires an explicit model request")
            await server.stop()
        }

        // A failed read also leaves the model alive, including access and malformed-state errors.
        let reads: [(Script.Reply, NativeComputerUseFailure.Detail)] = [
            (try errorText("The app has not finished constructing its view."), .unspecified),
            (try error(.permissionDenied), .permissionDenied),
            (try error(.senderNotAuthenticated), .senderNotAuthenticated),
            (empty, .missingImage), (invalidImage, .invalidImage),
            (.data(Data("not-json".utf8)), .malformedResponse)]
        for (nativeError, expected) in reads {
            let (server, script) = try await open([nativeError, text, text])
            let reply = try await server.respond(request(20))
            check(try failure(reply).detail == expected, "Read diagnostic retained")
            try await stream(reply)
            let state = try await server.respond(request(21))
            check(!NativeComputerUseFailure.isError(try result(state)), "New read allowed after earlier failed read")
            let action = try await server.respond(request(22, "click"))
            check(!NativeComputerUseFailure.isError(try result(action)), "Usable accessibility-only state permits action")
            let calls = await script.calls()
            check(calls.count == 3, "Permission/unknown/protocol errors not automatically retried")
            await server.stop()
        }

        // Chromium errors have no hidden hard budget; the agent decides how to proceed.
        do {
            let changed = "The user changed '/Applications/Google Chrome.app'. Re-query the latest state with `get_app_state` before sending more actions."
            let native = try errorText(changed)
            let (server, script) = try await open([text, native, text, native, text, native, text, text])
            for id in [30, 32, 34] {
                _ = try await server.respond(request(id))
                let reply = try await server.respond(request(id + 1, "click"))
                check(try failure(reply, tool: "click").modelError?.contains("Re-query") == true, "Browser's actual diagnostic remains available")
                try await stream(reply, tool: "click")
            }
            _ = try await server.respond(request(36))
            let success = try await server.respond(request(37, "click"))
            check(!NativeComputerUseFailure.isError(try result(success)), "Repeated browser errors never poison model's later request")
            let calls = await script.calls()
            check(calls.count == 8, "No automatic browser mutation/retry")
            await server.stop()
        }

        do {
            let slot = await MainActor.run { TargetSlot(app) }
            let script = Script([image, text, text])
            let server = NativeComputerUseServer(configuration: .init(script: script), resolveTarget: { _ in slot.value })
            _ = try await server.start()
            _ = try await server.respond(request(40))
            slot.set(nil)
            let absent = try await server.respond(request(41, "click"))
            check(try failure(absent, tool: "click").detail == .staleState, "Missing app requires fresh state")
            slot.set(app)
            let relaunched = try await server.respond(request(42, "click"))
            check(try failure(relaunched, tool: "click").detail == .staleState, "Relaunch cannot reuse old verification")
            let prior = await script.calls()
            check(prior.count == 1, "No mutation reaches unverified relaunched app")
            _ = try await server.respond(request(43))
            _ = try await server.respond(request(44, "click"))
            await server.stop()
        }

        // Preserve useful text-only state and strip unusable images instead of failing the task.
        do {
            let mixed = Script.Reply.data(try json(["content": [["type": "text", "text": "button 2: text field"], ["type": "image", "data": "invalid"]]]))
            let (server, _) = try await open([mixed, text])
            let reply = try await server.respond(request(50))
            let blocks = try result(reply)["content"] as! [[String: Any]]
            check(blocks.allSatisfy { $0["type"] as? String == "text" } && blocks.first?["text"] as? String == "button 2: text field", "Runtime returns normalized usable AX state")
            check(CaptureDiagnostics.log.entries().last?.fields["image_valid"] == "false", "Runtime does not falsely log valid image for AX fallback")
            let action = try await server.respond(request(51, "click"))
            check(!NativeComputerUseFailure.isError(try result(action)), "AX fallback verifies native state")
            await server.stop()
        }

        // The exact pinned CLI null-error shape remains a diagnostic input, never a stop signal.
        do {
            let captured = #"{"type":"mcp_tool_call","server":"sentient_native","tool":"probe","result":{"content":[{"type":"text","text":"Computer Use server error -10005: unspecified"},{"type":"text","text":"Native error detail: Cannot set a value for an element that is not settable"}],"structured_content":{"sentient_native_failure":{"version":1,"kind":"unknown","detail":"unspecified","stage":"action","disposition":"refresh_state","effects_may_be_unknown":true,"native_code":-10005}}},"error":null,"status":"failed"}"#
            let observed = try JSONSerialization.jsonObject(with: Data(captured.utf8)) as! [String: Any]
            let decoded = NativeComputerUseFailure.from(item: observed)
            check(decoded?.code == -10005 && decoded?.modelError != nil, "Actual null-error event retains native evidence")
            check(decoded?.stage == .action, "Legacy metadata remains diagnostic-readable")
        }
        for stage in [NativeComputerUseFailure.Stage.appState, .action, .transport] {
            let raw = "Synthetic private error " + String(repeating: "PRIVATE", count: 600)
            let value = NativeComputerUseFailure.classify(["code": -32603, "message": raw], stage: stage)
            check(value.modelError?.count == 2048, "Original native error bounded for every stage")
            check(!value.fields.values.joined().contains("PRIVATE"), "Original native error excluded from diagnostics")
            check(!value.modelGuidance.contains("terminal") && !value.modelGuidance.contains("Stop computer use"), "Tool guidance never orders task termination")
        }

        // User Stop still interrupts real backoff and leaves no further computer actions.
        do {
            let (server, script) = try await open([try error(.timeoutReached), image])
            let rpc = try request(60)
            let pending = Task { try await server.respond(rpc) }
            let start = ProcessInfo.processInfo.systemUptime
            while CaptureDiagnostics.log.entries().last?.outcome != .skipped {
                guard ProcessInfo.processInfo.systemUptime - start < 3 else { fatalError("Backoff never started") }
                try await Task.sleep(for: .milliseconds(10))
            }
            let cancelled = ProcessInfo.processInfo.systemUptime
            pending.cancel()
            do { _ = try await pending.value; fatalError("Stop ignored") } catch is CancellationError { count += 1 }
            check(ProcessInfo.processInfo.systemUptime - cancelled < 1, "Stop interrupts wait promptly")
            let calls = await script.calls()
            check(calls.count == 1, "No read after Stop")
            check(CaptureDiagnostics.log.entries().last?.outcome == .cancelled, "Stop remains cancellation, not a tool failure")
            await server.stop()
            do { _ = try await server.respond(request(61)); fatalError("Stopped server accepted work") } catch is CancellationError { count += 1 }
        }
        print("PASS \(count) native read/continuation assertions (real 2/3/5-second delays; no helper, network or model)")
    }
}

'''

with tempfile.TemporaryDirectory(prefix="sentient-native-read-retry-") as directory:
    root = Path(directory)
    (root / "Support.swift").write_text(SUPPORT)
    (root / "Tests.swift").write_text(TESTS)
    binary = root / "tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-target",
        f"{platform.machine()}-apple-macos15.0", str(root / "Support.swift"), str(root / "Tests.swift"),
        str(APP / "Diagnostics/NativeComputerUseFailure.swift"),
        str(APP / "Diagnostics/ComputerUseDiagnosticConsent.swift"),
        str(APP / "Diagnostics/ComputerUseDiagnosticPolicy.swift"),
        str(APP / "Driver/OpenAIComputerUseProbe.swift"),
        str(APP / "Driver/NativePermissionReadiness.swift"),
        str(APP / "Driver/NativeAppStateRetry.swift"),
        str(APP / "Driver/NativeComputerUseServer.swift"),
        str(APP / "Cloud/ComputerUseStream.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=75)
