#!/usr/bin/env python3
"""Compile the real native MCP server/read policy against an inert scripted session.

Exercises passthrough, FIFO cancellation, timeouts, catalog changes and RPC replay without
starting a helper, capturing a screen, changing permissions, calling a model or networking.
NSWorkspace lookup is read-only diagnostic context, never a prerequisite for a tool call.
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
    struct Configuration: Sendable {
        var appURL: URL {URL(fileURLWithPath:"/fixture-helper.app")}
 let script: Script }
}

actor Script {
    enum Reply: Sendable { case data(Data), failure(NativeComputerUseFailure) }
    struct Call: Sendable {
        let tool: String
        let arguments: Data
        let timeout: TimeInterval
        let uptime: TimeInterval
    }
    private var delay: Duration = .zero
    private var names = ["list_apps", "get_app_state", "click", "perform_secondary_action", "set_value", "select_text", "scroll", "drag", "press_key", "type_text"]
    func configure(delay: Duration = .zero, names: [String]? = nil) { self.delay = delay; if let names { self.names = names } }
    func catalog() -> [String] { names }
    private var opens = 0
    private var closes = 0
    func opened() { opens += 1 }
    func closed() { closes += 1 }
    func lifecycle() -> (opens: Int, closes: Int) { (opens, closes) }
    private var remaining: [Reply]
    private var observed: [Call] = []
    init(_ replies: [Reply]) { remaining = replies }
    func call(_ tool: String, arguments: Data, timeout: TimeInterval) async throws -> Data {
        observed.append(Call(tool: tool, arguments: arguments, timeout: timeout,
                             uptime: ProcessInfo.processInfo.systemUptime))
        guard !remaining.isEmpty else { fatalError("Unexpected extra native call: \(tool)") }
        let next = remaining.removeFirst()
        try await Task.sleep(for: delay)
        switch next {
        case .data(let data): return data
        case .failure(let failure): throw failure
        }
    }
    func calls() -> [Call] { observed }
}

actor OpenAIComputerUseSession {
    static let permissionSetupTimeout: TimeInterval = 300
    let script: Script
    init(script: Script) { self.script = script }
    static func open(_ configuration: OpenAIComputerUse.Configuration) async throws -> OpenAIComputerUseSession {
        await configuration.script.opened()
        return OpenAIComputerUseSession(script: configuration.script)
    }
    func catalog() async throws -> Data {
        let names = await script.catalog()
        return try JSONSerialization.data(withJSONObject: ["data": [["name": "sentient_native",
            "tools": Dictionary(uniqueKeysWithValues: names.map { ($0, ["name": $0]) })]]])
    }
    func call(_ tool: String, arguments: Data, timeout: TimeInterval = 125) async throws -> Data {
        try await script.call(tool, arguments: arguments, timeout: timeout)
    }
    func close() async { await script.closed() }
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
    let onWorkWindow: (@MainActor @Sendable (SidekickWorkWindow?) -> Void)? = nil
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
@MainActor final class NativePermissionSetup {
    var canAttemptTask = false
    static let shared=NativePermissionSetup()
    func permissionFailed()->UUID {UUID()}
    func recovered(ifCurrent token:UUID) {}
}
@MainActor final class NativePermissionCheck {
    static let shared = NativePermissionCheck()
    var isTearingDown = false
    var snapshot = NativePermissionReadiness.Snapshot(accessibility: .verified, screenRecording: .verified)
    var invalidations = 0
    func refresh() {}
    func invalidate(failure: NativeComputerUseFailure? = nil) {
        invalidations += 1; snapshot = NativePermissionReadiness.afterFailure(failure)
    }
}
'''
SUPPORT += r'''
nonisolated enum NativeComputerUseErrorLog { static func record(tool: String, failure: NativeComputerUseFailure) {} }
'''
TESTS = r'''
import Foundation
import AppKit

@main struct Tests {
    static var count = 0
    static func check(_ value: Bool, _ name: String) { guard value else { fatalError(name) }; count += 1 }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func request(_ id: Int, _ tool: String = "get_app_state", app: String = "Unresolvable fixture") throws -> Data {
        try json(["jsonrpc":"2.0", "id":id, "method":"tools/call", "params":["name":tool, "arguments":["app":app]]])
    }
    static func result(_ data: Data) throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: data) as! [String: Any])["result"] as! [String: Any]
    }
    static func successful(_ data: Data) throws -> Bool { !NativeComputerUseFailure.isError(try result(data)) }
    static func open(_ replies: [Script.Reply], delay: Duration = .zero, timeout: TimeInterval = 120,
                     names: [String]? = nil) async throws -> (NativeComputerUseServer, Script) {
        let script = Script(replies)
        await script.configure(delay: delay, names: names)
        let server = NativeComputerUseServer(configuration: .init(script: script), requestTimeout: timeout, resolveTarget: { _ in nil })
        _ = try await server.start()
        return (server, script)
    }
    static func started(_ script: Script, count: Int = 1) async throws {
        for _ in 0..<500 {
            if await script.calls().count >= count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        fatalError("call never started")
    }
    static func cancelled(_ task: Task<Data, Error>) async throws {
        do { _ = try await task.value; fatalError("cancel ignored") }
        catch is CancellationError { count += 1 }
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

    static func main() async throws {
        try await progressModes()
        let ok = try json(["content":[["type":"text", "text":"synthetic native state"]]])
        let reply = Script.Reply.data(ok)
        // Name resolution and locally remembered reads cannot veto the actual helper.
        do {
            let (server,script) = try await open(Array(repeating: reply, count: 5))
            for (id,tool) in ["click","get_app_state","type_text","press_key","get_app_state"].enumerated() {
                check(try successful(await server.respond(request(id,tool,app: "WhatsApp"))), "Unknown local identity reaches helper")
            }
            check(await script.calls().count == 5, "Each explicit request executes once")
            await server.stop()
        }
        // Native errors of every class are exact passthroughs, never retried or rewritten.
        for message in ["timeoutReached", "screenCaptureFailed", "permissionDenied", "focusChanged", "newErrorName"] {
            let raw = try json(["isError":true,"content":[["type":"text","text":message],["type":"text","text":"Exact second detail: α\\nß"]],
                "structuredContent":["vendor":["code":42]],"_meta":["future_field":true]])
            let (server,script) = try await open([.data(raw),reply])
            let rpc = try request(1)
            let failed = try await server.respond(rpc)
            try await stream(failed)
            check(try json(result(failed)) == raw, "Entire native error stays intact")
            check(await script.calls().count == 1, "One read attempt even for transient failure")
            check(try await server.respond(rpc) == failed, "Error duplicate is cached")
            check(try successful(await server.respond(request(2,"click"))), "Error does not create a local action veto")
            check(await script.calls().count == 2, "No automatic retry")
            await server.stop()
        }
        // Native capture failures can strand an otherwise live RPC session. Only a new
        // model-requested read resets it, once until a successful state read proves recovery.
        do {
            let raw = try json(["isError": true, "content": [["type": "text",
                "text": "Computer Use server error -10005: Error Domain=com.apple.ScreenCaptureKit.SCStreamErrorDomain Code=-3811 \"Failed to start due to video/audio capture failure\""]]])
            let (server, script) = try await open([.data(raw), .data(raw), reply, .data(raw), reply])
            let first = try await server.respond(request(200))
            check(try json(result(first)) == raw, "Original capture error is preserved")
            check(await script.lifecycle().opens == 1, "Error alone cannot open a replacement session")
            _ = try await server.respond(request(201))
            check(await script.lifecycle().opens == 2, "Next explicit read reopens the failed native session")
            _ = try await server.respond(request(202))
            check(await script.lifecycle().opens == 2, "Persistent failure cannot restart on every read")
            _ = try await server.respond(request(203))
            check(await script.lifecycle().opens == 2, "No hidden retry after later error")
            check(try successful(await server.respond(request(204))), "Later explicit read can recover")
            check(await script.lifecycle().opens == 3, "A successful state read permits a future independent recovery")
            check(await script.calls().count == 5, "Recovery never injects extra native actions or reads")
            await server.stop()
        }
        do {
            let error = try json(["isError": true, "content": [["type": "text", "text": "disconnected"]]])
            let (server, script) = try await open([.data(error), reply, reply])
            _ = try await server.respond(request(210, "click"))
            _ = try await server.respond(request(211, "press_key"))
            check(await script.lifecycle().opens == 1, "An action never triggers connection replacement or replay")
            _ = try await server.respond(request(212))
            check(await script.lifecycle().opens == 2, "Agent-requested state read recovers after action failure")
            check(await script.calls().map(\.tool) == ["click", "press_key", "get_app_state"], "Only explicitly requested actions reach native tools")
            await server.stop()
        }
        // FIFO, including simultaneous identical IDs: only one physical action per request.
        do {
            let (server,script) = try await open([reply,reply], delay: .milliseconds(80))
            let first = Task { try await server.respond(request(10,"click")) }
            try await started(script)
            let duplicate = Task { try await server.respond(request(10,"click")) }
            try await Task.sleep(for: .milliseconds(10))
            let second = Task { try await server.respond(request(11,"press_key")) }
            let one = try await first.value
            check(try await duplicate.value == one, "In-flight duplicate receives original result")
            check(try successful(await second.value), "Next queued request executes")
            check(await script.calls().map(\.tool) == ["click","press_key"], "FIFO never overlaps or duplicates native work")
            let collision = try await server.respond(request(10,"type_text"))
            check(!successfulUnchecked(collision), "Same ID different payload remains rejected")
            check(await script.calls().count == 2, "Collision never executes")
            await server.stop()
        }
        // Cancellation of one waiting call leaves both its neighbors usable.
        do {
            let (server,script) = try await open([reply,reply], delay: .milliseconds(100))
            let first = Task { try await server.respond(request(20)) }; try await started(script)
            let middle = Task { try await server.respond(request(21,"click")) }
            try await Task.sleep(for: .milliseconds(10))
            let last = Task { try await server.respond(request(22,"press_key")) }
            middle.cancel(); try await cancelled(middle)
            _ = try await first.value; check(try successful(await last.value), "Queue continues past cancelled waiter")
            check(await script.calls().map(\.tool) == ["get_app_state","press_key"], "Cancelled queued action never executes")
            await server.stop()
        }
        // Expired waiting calls cannot execute late after the upstream request times out.
        do {
            let (server,script) = try await open([reply], delay: .milliseconds(1500), timeout: 0.5)
            let first = Task { try await server.respond(request(30)) }; try await started(script)
            let expired = try await server.respond(request(31,"click"))
            check(!successfulUnchecked(expired), "Queued call expires")
            check(String(decoding: expired, as: UTF8.self).contains("No action was executed"), "Timeout explains non-dispatch")
            _ = try await first.value
            check(await script.calls().count == 1, "Expired call never executes later")
            await server.stop()
        }
        // Stop drains active and queued callers; cancellation before enqueue is also safe.
        do {
            let (server,script) = try await open([reply], delay: .milliseconds(100))
            let first = Task { try await server.respond(request(40)) }; try await started(script)
            let queued = Task { try await server.respond(request(41,"click")) }
            try await Task.sleep(for: .milliseconds(10))
            await server.stop(); first.cancel()
            try await cancelled(first); try await cancelled(queued)
            check(await script.calls().count == 1, "Stop never dispatches pending actions")
        }
        // New, renamed and missing tools are accepted; only advertised names are callable.
        do {
            let (server,script) = try await open([reply],names:["new_native_action"])
            let list = try await server.respond(json(["jsonrpc":"2.0","id":50,"method":"tools/list"]))
            check(String(decoding:list,as:UTF8.self).contains("new_native_action"),"Future native tool advertised")
            check(try successful(await server.respond(request(51,"new_native_action"))),"Future native tool works")
            check(!successfulUnchecked(try await server.respond(request(52,"click"))),"Unadvertised tool rejected")
            check(await script.calls().count == 1,"Removed tools never get fabricated")
            await server.stop()
        }
        // Long tasks continue; eviction prevents old actions from being replayed.
        do {
            let (server,script) = try await open(Array(repeating: reply,count:20))
            for id in 100..<120 { _ = try await server.respond(request(id,"click")) }
            check(!successfulUnchecked(try await server.respond(request(100,"click"))),"Evicted action remains consumed")
            check(await script.calls().count == 20,"No late replay after eviction")
            await server.stop()
        }
        // Valid text survives a bad image; totally unusable data remains an honest error.
        do {
            let mixed = try json(["content":[["type":"text","text":"valid AX"],["type":"image","data":"broken"]]])
            let (server,_) = try await open([.data(mixed),.data(try json(["content":[]]))])
            check(try successful(await server.respond(request(60))),"AX remains usable with invalid image")
            check(!successfulUnchecked(try await server.respond(request(61))),"Empty result remains invalid")
            await server.stop()
        }
        print("PASS \(count) native passthrough, FIFO, cancellation, catalog and replay assertions")
    }
    static func successfulUnchecked(_ data: Data) -> Bool { (try? successful(data)) == true }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-native-passthrough-") as directory:
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
        str(APP / "Driver/NativeComputerUseServer.swift"), str(APP / "Notch Magic/SidekickWorkWindow.swift"),
        str(APP / "Cloud/ComputerUseStream.swift"), str(APP.parent / "Scripts/Fixtures/NativeHelperPermissionNoteStub.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
