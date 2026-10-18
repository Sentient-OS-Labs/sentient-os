#!/usr/bin/env python3
"""Behavioral MCP/conversation tests using whole production Swift files and real SQLite.

Only transport and diagnostic/platform sinks are inert fixtures. No model, network,
credentials, production defaults, live app, or external action is used.
"""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FOLDER = ROOT / "Sentient OS macOS/Notch Magic"
FILES = [
    FOLDER / name for name in (
        "SidekickConversationStore.swift", "SidekickConversationRun.swift",
        "SidekickConversationTools.swift", "SidekickInteraction.swift",
        "SidekickToolServer.swift", "SidekickRecovery.swift",
        "SidekickInstructionStore.swift", "SidekickPersonalization.swift",
        "SidekickTaskSummary.swift",
    )
] + [ROOT / "Sentient OS macOS/Cloud/AgentStatus.swift",
     ROOT / "Sentient OS macOS/System/CustomInstructions.swift",
     ROOT / "Sentient OS macOS/Diagnostics/SidekickDiagnostics.swift"]

STUBS = r'''
import Foundation
import Observation

nonisolated enum ModelBackend: String, Sendable {
    case chatgpt, claude, custom
    static var current: Self { .chatgpt }
}
nonisolated enum Diagnostics {
    struct Payload: Sendable { let event: String; let tags: [String:String]; let extra: [String:String]; let fingerprint: [String] }
    static func isCancellation(_ error: Error) -> Bool { error is CancellationError }
}
nonisolated enum AgentRunDiagnostics {
    enum Reason: String { case unknown; static func classify(_ error: String) -> Self { .unknown } }
}
nonisolated enum DiagnosticHistory { static func recordError(_ payload: Diagnostics.Payload) {} }
nonisolated enum CrashReporting {
    enum Level { case info, warning }
    static func diagnosticBreadcrumb(_ name: String, data: [String:String]) {}
    static func captureEvent(_ name: String, level: Level, tags: [String: String],
        extra: [String: String], fingerprint: [String], cooldown: TimeInterval,
        includeInformational: Bool = false) {}
}
nonisolated struct SidekickTaskEnd: Sendable {}
@MainActor enum Analytics {
    enum Tier { case extended }
    static func signal(_ name: String, parameters: [String:String], floatValue: Double?, tier: Tier) {}
    static var taskSummariesEnabled: Bool { false }
    static func recordTaskEnd(_ end: SidekickTaskEnd, backend: ModelBackend, source: String, method: String) {}
    static func recordTaskSummary(_ report: SidekickTaskSummary.Report, backend: ModelBackend,
        end: SidekickTaskEnd, source: String, method: String) {}
}
nonisolated func Log(_ text: String) {}
extension URL {
    nonisolated static var sentientSupport: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SENTIENT_TOOL_TEST_ROOT"]!, isDirectory: true)
    }
}
actor LocalMCPServer {
    nonisolated struct Connection: Sendable {
        let name: String
        let tools: [String]
        var codexOverrides: [String] { [] }
    }
    private let name: String
    private let tools: [String]
    init(name: String, tools: [String], timeout: TimeInterval, maximumBody: Int,
         response: @escaping @Sendable (Data) async throws -> Data) {
        self.name = name; self.tools = tools
    }
    func start() async throws -> Connection { Connection(name: name, tools: tools) }
    func stop() async {}
    nonisolated static func addToClaudeArguments(_ arguments: [String], connection: Connection?) throws -> [String] { arguments }
}
'''

FIXTURE = r'''
import Foundation
import SQLite3
import Darwin

typealias Event = SidekickConversationEvent
typealias Store = SidekickConversationStore

@MainActor final class Harness {
    let store: Store
    let run: SidekickConversationRun
    let recovery = SidekickRecovery()
    let interaction: SidekickInteraction
    let server: SidekickToolServer
    let memory: SidekickPersonalization?
    let defaults: UserDefaults?
    let defaultsName: String?
    let memoryURL: URL?
    var questions = 0

    init(_ root: URL, memoryEnabled: Bool = false) throws {
        store = try Store(url: root.appendingPathComponent("history.sqlite"))
        let taskID = UUID()
        _ = try store.appendBatch([Event(taskID: taskID, kind: .taskStarted),
            Event(taskID: taskID, kind: .userMessage, text: "Synthetic Sidekick task")])
        run = SidekickConversationRun(store: store, taskID: taskID, generation: try store.generation)
        if memoryEnabled {
            let name = "sentient.tools.fixture." + UUID().uuidString
            defaultsName = name
            defaults = UserDefaults(suiteName: name)!
            memoryURL = root.appendingPathComponent("SidekickMemory.md")
            let snapshot = SidekickInstructionStore.snapshot(defaults: defaults!, memoryURL: memoryURL!)
            memory = SidekickPersonalization(snapshot: snapshot, taskID: taskID, request: "Synthetic",
                defaults: defaults!, memoryURL: memoryURL!, onChange: { _ in })
        } else { defaults = nil; defaultsName = nil; memoryURL = nil; memory = nil }
        let recovery = self.recovery, run = self.run
        interaction = SidekickInteraction(personalization: memory, taskSummary: SidekickTaskSummary(),
            conversationRun: run) { question in
                guard try run.store.record(id: "question:\(question.id)") != nil else {
                    fatalError("Question was presented before durable commit")
                }
                return try await recovery.ask(question, onCancel: { _ in })
            }
        server = SidekickToolServer(interaction: interaction)
    }

    func clean() async {
        await server.stop()
        recovery.cancel()
        if let defaultsName { defaults?.removePersistentDomain(forName: defaultsName) }
    }
}

nonisolated func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
}
nonisolated func send(_ server: SidekickToolServer, request: Data) async throws -> Data {
    let rpc = try JSONSerialization.jsonObject(with: request) as! [String: Any]
    return try await server.response(rpc)
}
nonisolated func sql(_ path: URL, _ command: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(path.path, &db) == SQLITE_OK, let db else { fatalError("fixture SQLite open") }
    defer { sqlite3_close_v2(db) }
    guard sqlite3_exec(db, command, nil, nil, nil) == SQLITE_OK else { fatalError("fixture SQLite operation") }
}

@main enum ToolTests {
    static var checks = 0
    static var failures: [String] = []

    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        checks += 1
        if try !condition() {
            failures.append(label)
            FileHandle.standardError.write(Data(("FAIL: " + label + "\n").utf8))
        }
    }
    static func request(_ name: String, id: String = UUID().uuidString, _ arguments: [String: Any]) throws -> Data {
        try json(["jsonrpc": "2.0", "id": id, "method": "tools/call",
                  "params": ["name": name, "arguments": arguments]])
    }
    static func result(_ data: Data) throws -> [String: Any] {
        let rpc = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return rpc["result"] as? [String: Any] ?? [:]
    }
    static func payload(_ data: Data) throws -> [String: Any] {
        let response = try result(data)
        guard let content = response["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
    static func isError(_ data: Data) throws -> Bool { try result(data)["isError"] as? Bool == true }
    static func call(_ harness: Harness, _ name: String, id: String = UUID().uuidString,
                     _ arguments: [String: Any]) async throws -> Data {
        try await send(harness.server, request: request(name, id: id, arguments))
    }
    static func visible(_ harness: Harness) throws -> [Store.Record] {
        try harness.store.records(limit: 500).filter { $0.event.kind == .assistantMessage }
    }
    static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Timed out waiting for deterministic fixture boundary")
    }
    static func wire(_ type: String, id: String, server: String = "sentient_native",
                     tool: String = "get_app_state", result: [String: Any]? = nil) throws -> String {
        var item: [String: Any] = ["id": id, "type": "mcp_tool_call", "server": server, "tool": tool,
            "arguments": ["app": "Synthetic", "password": "MUST_NOT_PERSIST", "accessibility_tree": "TREE_SECRET"]]
        if let result { item["result"] = result }
        return String(decoding: try json(["type": type, "item": item]), as: UTF8.self)
    }

    static func protocolBoundaries(_ root: URL) async throws {
        let h = try Harness(root.appendingPathComponent("protocol"))
        let connection = try await h.server.start()
        try check(connection.tools.contains("message_user"), "transport registration carries conversation tool allowlist")
        let numeric = try await send(h.server, request: json(["id": 42, "method": "ping"]))
        let numericRoot = try JSONSerialization.jsonObject(with: numeric) as! [String: Any]
        try check(numericRoot["id"] as? Int == 42, "numeric JSON-RPC ID is retained")
        let unknown = try await send(h.server, request: json(["id": "unknown", "method": "unknown/method"]))
        let unknownRoot = try JSONSerialization.jsonObject(with: unknown) as! [String: Any]
        try check((unknownRoot["error"] as? [String: Any])?["code"] as? Int == -32601, "unsupported method returns protocol error")
        for request: [String: Any] in [
            ["method": "ping"], ["id": NSNull(), "method": "ping"], ["id": true, "method": "ping"]
        ] {
            do {
                _ = try await send(h.server, request: json(request))
                try check(false, "malformed JSON-RPC ID rejected: \(request)")
            } catch is CancellationError { try check(true, "malformed JSON-RPC ID rejected") }
        }
        let noTool = try await call(h, "unknown_tool", [:])
        try check(try isError(noTool), "unknown tool rejected without action")
        for arguments: [String: Any] in [
            ["error": NSNull(), "question": "Which?", "answers": ["Only one"]],
            ["error": NSNull(), "question": "Which?", "answers": ["Same", "Same"]],
            ["error": NSNull(), "question": "", "answers": ["A", "B"]],
            ["error": 5, "question": "Which?", "answers": ["A", "B"]]
        ] {
            let rejected = try await call(h, "ask_user", arguments)
            try check(try isError(rejected), "malformed question rejected before presentation")
        }
        try check(h.recovery.content == nil, "invalid questions never create a UI continuation")
        await h.clean()
        do {
            _ = try await send(h.server, request: json(["id": "closed", "method": "ping"]))
            try check(false, "closed server rejects later requests")
        } catch is CancellationError { try check(true, "closed server rejects later requests") }

        let bareInteraction = SidekickInteraction { _ in SidekickAnswer(text: "unused", selectedAnswer: nil) }
        let bare = SidekickToolServer(interaction: bareInteraction)
        let listed = try await send(bare, request: json(["id": "bare", "method": "tools/list"]))
        let names = try (result(listed)["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        try check(names == ["ask_user"], "missing conversation capability does not expose message/history tools")
        let refused = try await send(bare, request: request("message_user", ["markdown": "x", "kind": "answer", "priority": "normal"]))
        try check(try isError(refused), "missing conversation capability cannot create messages")
        await bare.stop()
    }

    static func messaging(_ root: URL) async throws {
        let h = try Harness(root.appendingPathComponent("messages"))
        let listed = try await send(h.server, request: json(["id": "list", "method": "tools/list"]))
        let names = try (result(listed)["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        try check(Set(["ask_user", "message_user", "read_history", "search_history", "describe_task_usage"]).isSubset(of: Set(names)), "tools/list exposes run capabilities")
        let text = "## Your answer\n\n- café\n- 世界 👩🏽‍💻\n\n**Done**"
        let rpc = try request("message_user", id: "duplicate", ["markdown": text, "kind": "answer", "priority": "high"])
        async let first = send(h.server, request: rpc)
        async let second = send(h.server, request: rpc)
        let (a, b) = try await (first, second)
        try check(a == b, "simultaneous RPC retries return identical result")
        let saved = try payload(a)
        try check(saved["saved"] as? Bool == true, "successful message acknowledges save")
        let id = saved["message_id"] as? String ?? "missing"
        try check(try h.store.record(id: id)?.event.text == text, "MCP success follows exact durable commit")
        try check(try visible(h).count == 1, "concurrent duplicate delivers once")
        let changed = try await call(h, "message_user", id: "duplicate", ["markdown": "Different", "kind": "answer", "priority": "high"])
        try check(try isError(changed), "RPC ID cannot be reused with altered arguments")
        for arguments: [String: Any] in [
            ["markdown": "", "kind": "answer", "priority": "normal"],
            ["markdown": "  \n ", "kind": "answer", "priority": "normal"],
            ["markdown": "x", "kind": "wrong", "priority": "normal"],
            ["markdown": "x", "kind": "answer", "priority": true],
            ["markdown": "x", "kind": "answer", "priority": "normal", "completion": "success"],
            ["markdown": "x", "kind": "answer", "priority": "normal", "completion": true],
            ["markdown": "x", "kind": "answer", "priority": "normal", "completion": NSNull()],
            ["markdown": "x", "kind": "update", "priority": "normal", "completion": "done"],
            ["markdown": "x", "kind": "answer", "priority": "high", "extra": "x"],
            ["markdown": String(repeating: "👩🏽‍💻", count: 10_000), "kind": "answer", "priority": "normal"]
        ] {
            let rejected = try await call(h, "message_user", arguments)
            try check(try isError(rejected), "malformed/oversized message rejected")
        }
        try check(try visible(h).count == 1, "rejected messages never enter history")
        try h.run.finish(outcome: .success, status: "✓ done", finalText: text + "\nSTATUS: DONE")
        try check(try visible(h).count == 1, "explicit final answer suppresses duplicate completion bubble")
        let late = try await call(h, "message_user", ["markdown": "Late", "kind": "update", "priority": "normal"])
        try check(try isError(late), "closed task rejects new message")
        let retried = try await send(h.server, request: rpc)
        try check(retried == a, "retry after task closure reports original delivery without rewriting")
        try check(try h.store.records(taskID: h.run.taskID).filter { $0.event.kind == .taskFinished }.count == 1, "terminal outcome recorded once")
        await h.clean()
    }

    static func completion(_ root: URL) async throws {
        let h = try Harness(root.appendingPathComponent("completion"))
        let legacy = try await call(h, "message_user", ["markdown": "Saved answer", "kind": "answer", "priority": "high"])
        try check(try !isError(legacy) && h.run.completionStatus == nil, "legacy message saves without inventing completion")
        let rpc = try request("message_user", id: "done-claim", ["markdown": "Completed and verified.", "kind": "answer", "priority": "high", "completion": "done"])
        let done = try await send(h.server, request: rpc)
        try check(try payload(done)["saved"] as? Bool == true && h.run.completionStatus == .done, "structured DONE travels through real MCP handler")
        try check(AgentStatus.resolve("Final answer without sentinel", completion: h.run.completionStatus, providerSucceeded: true) == .done, "clean exit accepts explicit saved completion")
        try h.interaction.observeToolEvent(wire("item.started", id: "later-action"), streamID: UUID())
        try check(h.run.completionStatus == nil, "later actual tool observation invalidates MCP completion")
        let replay = try await send(h.server, request: rpc)
        try check(replay == done && h.run.completionStatus == nil, "cached delivery receipt never restores stale completion")
        await h.clean()

        let refused = try Harness(root.appendingPathComponent("completion-refused"))
        _ = try await call(refused, "message_user", ["markdown": "The service did not confirm the change.", "kind": "answer", "priority": "high", "completion": "could_not"])
        try check(refused.run.completionStatus == .couldNot(reason: "The service did not confirm the change."), "structured refusal carries exact answer reason")
        try check(AgentStatus.resolve("", completion: refused.run.completionStatus, providerSucceeded: true, connector: true) == refused.run.completionStatus, "connector completion uses same structured claim")
        await refused.clean()

        let correction = try Harness(root.appendingPathComponent("completion-correction"))
        _ = try await call(correction, "message_user", ["markdown": "Initially looked done.", "kind": "answer", "priority": "high", "completion": "done"])
        try sql(correction.store.url, "CREATE TRIGGER deny_correction BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'fixture write denial'); END;")
        let unsaved = try await call(correction, "message_user", ["markdown": "Actually, I could not verify it.", "kind": "answer", "priority": "high", "completion": "could_not"])
        try check(try isError(unsaved) && correction.run.completionStatus == nil, "failed final correction cannot leave a stale successful claim")
        try sql(correction.store.url, "DROP TRIGGER deny_correction;")
        await correction.clean()
    }

    static func history(_ root: URL) async throws {
        let h = try Harness(root.appendingPathComponent("history"))
        let oldTask = UUID(), full = "Calendars: café 👩🏽‍💻 and e\u{301}.\nOption 1\nOption 2\n```\ncode\n```"
        _ = try h.store.append(Event(id: "old-answer", taskID: oldTask, kind: .assistantMessage, text: full))
        let first = try await call(h, "read_history", ["message_id": "old-answer", "offset": 0, "limit": 17])
        let firstPage = try payload(first)
        let offset = firstPage["next_offset"] as? Int ?? -1
        let second = try await call(h, "read_history", ["message_id": "old-answer", "offset": offset, "limit": 16000])
        try check((firstPage["text"] as? String ?? "") + (try payload(second)["text"] as? String ?? "") == full, "paged history reassembles exact Unicode/Markdown")
        try check(firstPage["historical_data"] as? Bool == true, "history returned as historical data")
        try check(firstPage["task_request_id"] == nil, "history without a task start omits rather than fabricates request reference")
        try check(try payload(second)["has_more"] as? Bool == false, "last history page terminates")
        for arguments: [String: Any] in [
            ["message_id": "old-answer", "offset": -1], ["message_id": "old-answer", "limit": 0],
            ["message_id": "old-answer", "offset": 1.5], ["message_id": "old-answer", "offset": true],
            ["message_id": "old-answer", "limit": true], ["message_id": "missing"],
            ["message_id": "old-answer", "offset": full.count + 1]
        ] {
            let rejected = try await call(h, "read_history", arguments)
            try check(try isError(rejected), "history rejects invalid pagination/source: \(arguments)")
        }
        let activities = (0..<120).map { Event(id: "a-\($0)", taskID: oldTask, kind: .activity,
            text: "Calendars.search", activity: .init(toolID: "\($0)", name: "Calendars.search", status: .completed)) }
        _ = try h.store.appendBatch(activities)
        let search = try await call(h, "search_history", ["query": "Calendars"])
        let matches = try payload(search)["historical_data"] as? [[String: Any]] ?? []
        try check(matches.contains { $0["message_id"] as? String == "old-answer" }, "matching activity cannot crowd real message out of search")
        try check(!matches.contains { $0["kind"] as? String == "activity" }, "history search omits activity results")
        let activity = try await call(h, "read_history", ["message_id": "a-0"])
        try check(try isError(activity), "message lookup does not expose tool traces")
        _ = try h.store.append(Event(id: "old-failure", taskID: oldTask, kind: .taskFinished,
            text: "Operation failed; effects unknown", outcome: .failed))
        let retry = try h.store.append(Event(taskID: UUID(), kind: .userMessage, text: "Try again after checking current state",
            reply: .init(messageID: "old-failure")))
        try check(retry.event.reply?.messageID == "old-failure", "new retry request can reference original terminal outcome")
        do {
            _ = try h.store.append(Event(taskID: UUID(), kind: .taskStarted,
                reply: .init(messageID: "old-failure")))
            try check(false, "taskStarted cannot masquerade as a user retry reference")
        } catch Store.Failure.invalidEvent { try check(true, "retry link stays on actual user message") }
        do {
            _ = try h.store.append(Event(taskID: UUID(), kind: .userMessage, text: "Retry",
                reply: .init(messageID: "old-failure", selectedText: "Operation failed")))
            try check(false, "terminal continuation source requires whole status reference")
        } catch Store.Failure.invalidReply { try check(true, "terminal continuation has narrow whole-reference semantics") }
        try check(try h.store.needsLegacyImport, "legacy import marker is readable before decoding source")
        let legacyTask = UUID()
        let legacyStart = "legacy-start:\(legacyTask)", legacyRequest = "legacy-request:\(legacyTask)"
        _ = try h.store.importLegacy(events: [
            Event(id: legacyStart, taskID: legacyTask, kind: .taskStarted, text: "Exact original migrated request"),
            Event(id: legacyRequest, taskID: legacyTask, kind: .userMessage, text: "Exact original migrated request"),
            Event(id: "legacy-end:\(legacyTask)", taskID: legacyTask, kind: .taskFinished, outcome: .success)
        ])
        try check(try !h.store.needsLegacyImport, "successful import consumes marker")
        let migrated = try await call(h, "read_history", ["message_id": legacyRequest])
        let migratedSource = try payload(migrated)["task_request_id"] as? String
        try check(migratedSource == legacyStart, "migrated history resolves actual stored task-start identity")
        let migratedOriginal = try await call(h, "read_history", ["message_id": migratedSource!])
        try check(try !isError(migratedOriginal) && payload(migratedOriginal)["text"] as? String == "Exact original migrated request",
            "returned migrated request reference is readable and exact")
        let seededRequest = try h.store.records(taskID: h.run.taskID).first { $0.event.kind == .userMessage }!
        let seeded = try await call(h, "read_history", ["message_id": seededRequest.event.id])
        let seededSource = try payload(seeded)["task_request_id"] as? String
        try check(try seededSource.flatMap { try h.store.record(id: $0) }?.event.kind == .taskStarted,
            "caller-supplied task-start IDs remain resolvable")
        await h.clean()
    }

    static func questions(_ root: URL) async throws {
        let h = try Harness(root.appendingPathComponent("questions"))
        let args: [String: Any] = ["error": NSNull(), "question": "Which calendar?", "answers": ["Work", "Personal"]]
        let rpc = try request("ask_user", id: "same-question", args)
        let first = Task { try await send(h.server, request: rpc) }
        let second = Task { try await send(h.server, request: rpc) }
        try await waitFor { h.recovery.content?.question != nil }
        try check(h.interaction.isWaiting, "ask_user enters wait state")
        try check(try h.store.records().filter { $0.event.kind == .question }.count == 1, "simultaneous question RPC presents/persists once")
        let busy = try await call(h, "ask_user", args)
        try check(try isError(busy), "second question is rejected while one waits")
        let messageWhileWaiting = try await call(h, "message_user", ["markdown": "x", "kind": "update", "priority": "normal"])
        try check(try isError(messageWhileWaiting), "no competing local tool while waiting")
        do {
            try h.interaction.observeToolEvent(wire("item.started", id: "forbidden-action"), streamID: UUID())
            try check(false, "executor cannot start an action while user is answering")
        } catch SidekickInteraction.Failure.toolWhileWaiting { try check(true, "executor wait exclusivity enforced") }
        let questionID = h.recovery.content!.id
        h.recovery.answer(id: questionID, choice: 1)
        let a = try await first.value, b = try await second.value
        try check(a == b, "simultaneous question callers receive same actual answer")
        try check(try payload(a)["text"] as? String == "Personal", "actual selected answer returned")
        try check(try h.store.records().filter { $0.event.kind == .answer }.map(\.event.text) == ["Personal"], "answer persisted exactly once before RPC result")
        try check(!h.interaction.isWaiting && h.interaction.waitingSeconds >= 0, "answer clears wait state and preserves timing")
        await h.clean()

        let cancelled = try Harness(root.appendingPathComponent("cancel-question"))
        let pending = Task { try await send(cancelled.server, request: request("ask_user", args)) }
        try await waitFor { cancelled.recovery.content?.question != nil }
        await cancelled.server.stop()
        do { _ = try await pending.value; try check(false, "cancelled question cannot return approval") }
        catch is CancellationError { try check(true, "server stop cancels pending question") }
        try check(try cancelled.store.records().filter { $0.event.kind == .answer }.isEmpty, "cancellation invents no user reply")
        try check(!cancelled.interaction.isWaiting, "cancelled question releases waiting state")
        await cancelled.clean()
    }

    static func streams(_ root: URL) async throws {
        let h = try Harness(root.appendingPathComponent("streams"))
        let one = UUID(), two = UUID()
        for stream in [one, two] { try h.interaction.observeToolEvent(wire("item.started", id: "item_0"), streamID: stream) }
        try h.interaction.observeToolEvent(wire("item.completed", id: "item_0", result: ["content": [["type": "image", "data": "PIXEL_SECRET"]], "accessibility_tree": "TREE_SECRET"]), streamID: one)
        try check(h.interaction.hasActiveTools, "identical provider IDs in different streams stay independent")
        if h.interaction.hasActiveTools {
            let blocked = try await call(h, "ask_user", ["error": NSNull(), "question": "Continue?", "answers": ["Yes", "No"]])
            try check(try isError(blocked), "question remains blocked while second stream action runs")
            let quiet = try await call(h, "message_user", ["markdown": "Checking the other calendar", "kind": "update", "priority": "normal"])
            try check(try payload(quiet)["saved"] as? Bool == true, "quiet update may be saved while an independent action is pending")
        }
        try h.interaction.observeToolEvent(wire("item.completed", id: "item_0"), streamID: two)
        try check(!h.interaction.hasActiveTools, "all completed streams clear action guard")
        for phase in ["item.started", "item.completed"] {
            try h.interaction.observeToolEvent(wire(phase, id: "telemetry", server: "sentient_recovery", tool: "describe_task_usage", result: ["isError": true]), streamID: one)
            try h.interaction.observeToolEvent(wire(phase, id: "message-wrapper", server: "sentient_recovery", tool: "message_user"), streamID: one)
        }
        let claudeStart: [String: Any] = ["type": "assistant", "message": ["content": [
            ["type": "text", "text": "RAW_NARRATION_SECRET"], ["type": "thinking", "thinking": "REASONING_SECRET"],
            ["type": "tool_use", "id": "relay", "name": "mcp__sentient_relay__tool_1", "input": [:]],
            ["type": "tool_use", "id": "usage", "name": "mcp__sentient_recovery__describe_task_usage", "input": [:]],
            ["type": "tool_use", "id": "claude-calendar", "name": "mcp__calendar__read", "input": ["access_token": "TOKEN_SECRET"]]
        ]]]
        try h.interaction.observeToolEvent(String(decoding: json(claudeStart), as: UTF8.self), streamID: one)
        try check(h.interaction.hasActiveTools, "Claude connector starts action guard")
        let claudeResult: [String: Any] = ["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "claude-calendar", "content": [["type": "text", "text": "A calendar result"]]]
        ]]]
        try h.interaction.observeToolEvent(String(decoding: json(claudeResult), as: UTF8.self), streamID: one)
        try check(!h.interaction.hasActiveTools, "Claude connector result clears action guard")
        let events = try h.store.records(limit: 500)
        let stored = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for forbidden in ["PIXEL_SECRET", "TREE_SECRET", "TOKEN_SECRET", "MUST_NOT_PERSIST", "REASONING_SECRET", "RAW_NARRATION_SECRET", "describe_task_usage", "message-wrapper", "mcp__sentient_relay"] {
            try check(!stored.contains(forbidden), "selected activity excludes \(forbidden)")
        }
        try check(events.filter { $0.event.kind == .activity }.count == 6, "authoritative execution events stored without relay duplication")
        let countBeforeAnalytics = try h.store.latestSequence
        let bookkeeping = try await call(h, "describe_task_usage", ["phase": "final", "summary": "Reading a calendar"])
        try check(try !isError(bookkeeping), "analytics capability remains callable")
        try check(try h.store.latestSequence == countBeforeAnalytics, "analytics tool produces no conversation entry")
        let failedLeg = UUID()
        try h.interaction.observeToolEvent(wire("item.started", id: "unfinished-leg"), streamID: failedLeg)
        h.interaction.endExecution(streamID: failedLeg)
        try check(!h.interaction.hasActiveTools, "drained failed leg releases recovery action guard")
        try check(try h.store.records().contains { $0.event.activity?.toolID == "\(failedLeg):unfinished-leg" },
            "drained failed leg preserves its uncertain execution record")
        await h.clean()
    }

    static func failureAndFinish(_ root: URL) async throws {
        let h = try Harness(root.appendingPathComponent("write-failure"))
        try sql(h.store.url, "CREATE TRIGGER deny_fixture BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'fixture write denial'); END;")
        let denied = try await call(h, "message_user", id: "failed-save", ["markdown": "Must not appear", "kind": "answer", "priority": "high", "completion": "done"])
        try check(try isError(denied) && payload(denied)["saved"] == nil, "failed commit cannot claim saved=true")
        try check(try visible(h).isEmpty && h.run.completionStatus == nil, "failed commit creates no visible answer or completion claim")
        try sql(h.store.url, "DROP TRIGGER deny_fixture;")
        let repeatFailure = try await call(h, "message_user", id: "failed-save", ["markdown": "Must not appear", "kind": "answer", "priority": "high", "completion": "done"])
        try check(try isError(repeatFailure), "same failed RPC remains idempotent after storage recovers")
        let accepted = try await call(h, "message_user", ["markdown": "Now saved", "kind": "update", "priority": "normal"])
        try check(try payload(accepted)["saved"] as? Bool == true, "new delivery can succeed after failed transaction")
        try h.run.finish(outcome: .success, status: "✓ done", finalText: "Useful full answer\n\nSTATUS: DONE\n")
        try check(try visible(h).map(\.event.text) == ["Now saved", "Useful full answer"], "missing final-message fallback strips status and preserves answer")
        try h.run.finish(outcome: .failed, status: "Late conflicting end")
        try check(try h.store.records().filter { $0.event.kind == .taskFinished }.count == 1, "duplicate finish is harmless")
        await h.clean()

        let stopped = try Harness(root.appendingPathComponent("stopped"))
        try stopped.interaction.observeToolEvent(wire("item.started", id: "pending-send", server: "mail", tool: "send"), streamID: UUID())
        try stopped.run.finish(outcome: .stopped, status: "[Stopped by user]", finalText: "uncommitted final")
        try check(try visible(stopped).isEmpty, "forced Stop invents no model answer")
        let state = try stopped.store.records().compactMap(\.event.activity)
        try check(state.last?.status == .interrupted && state.last?.result?.contains("Verify current state") == true,
            "pending action retains uncertain outcome on Stop")
        await stopped.clean()

        let reset = try Harness(root.appendingPathComponent("reset"))
        try reset.store.reset()
        let stale = try await call(reset, "message_user", ["markdown": "Old callback", "kind": "answer", "priority": "high"])
        try check(try isError(stale), "reset rejects old run delivery honestly")
        try check(try reset.store.records().isEmpty, "stale callback cannot recreate history")
        await reset.clean()
    }

    static func memory(_ root: URL) async throws {
        let h = try Harness(root.appendingPathComponent("memory"), memoryEnabled: true)
        let read = try await call(h, "update_sidekick_instructions", ["operation": "read", "markdown": NSNull(), "revision": NSNull()])
        let message = try payload(read)["message"] as? String ?? ""
        let data = Data(message.split(separator: "\n", maxSplits: 1).last.map(String.init)!.utf8)
        let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let revision = original["revision"] as! String
        let saved = try await call(h, "update_sidekick_instructions", ["operation": "write", "markdown": "Prefer concise replies.", "revision": revision])
        try check(try !isError(saved), "memory tool saves immediately")
        try check(try String(contentsOf: h.memoryURL!, encoding: .utf8) == "Prefer concise replies.", "MCP memory success follows file write")
        let stale = try await call(h, "update_sidekick_instructions", ["operation": "write", "markdown": "Overwrite stale snapshot", "revision": revision])
        try check(try isError(stale), "concurrent memory edit rejects stale write")
        _ = h.memory!.finish(success: false)
        try check(try String(contentsOf: h.memoryURL!, encoding: .utf8) == "Prefer concise replies.", "later task failure does not roll back memory")
        let late = try await call(h, "update_sidekick_instructions", ["operation": "read", "markdown": NSNull(), "revision": NSNull()])
        try check(try isError(late), "finished task cannot access memory capability")
        await h.clean()
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try await protocolBoundaries(root)
        try await messaging(root)
        try await completion(root)
        try await history(root)
        try await questions(root)
        try await streams(root)
        try await failureAndFinish(root)
        try await memory(root)
        FileHandle.standardOutput.write(Data("\(checks - failures.count)/\(checks) Sidekick tool checks passed\n".utf8))
        if !failures.isEmpty { exit(EXIT_FAILURE) }
    }
}
'''


def main() -> None:
    import os

    with tempfile.TemporaryDirectory(prefix="sentient-tools-test-") as temporary:
        directory = Path(temporary)
        stubs = directory / "ToolPlatformStubs.swift"
        fixture = directory / "ToolTests.swift"
        stubs.write_text(STUBS)
        fixture.write_text(FIXTURE)
        executable = directory / "tool-tests"
        subprocess.run([
            "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
            "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library",
            *map(str, FILES), str(stubs), str(fixture), "-o", str(executable),
        ], check=True, timeout=60)
        environment = os.environ | {"SENTIENT_TOOL_TEST_ROOT": str(directory / "support")}
        subprocess.run([str(executable), str(directory / "data")], check=True, timeout=60, env=environment)


if __name__ == "__main__":
    main()
