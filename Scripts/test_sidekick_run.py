#!/usr/bin/env python3
"""Exercise production task recording with real temporary SQLite and provider event fixtures."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Sentient OS macOS/Notch Magic'
HARNESS = r'''
import Foundation

enum FixtureFailure: Error { case intentional }

@main struct RunTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-run-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SidekickConversationStore(url: root.appendingPathComponent("history.sqlite"))
        var checks = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); checks += 1 }
        func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        func start() throws -> SidekickConversationRun {
            let id = UUID()
            _ = try store.append(.init(taskID: id, kind: .taskStarted, text: "Fixture request"))
            return try SidekickConversationRun(store: store, taskID: id, generation: store.generation)
        }
        func raw(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let run = try start(), stream = UUID()
        let text = "**Résumé**\n\n- café 🦊\n- [report](https://example.invalid/report)"
        _ = try run.message(text, kind: .update, priority: .normal, id: "update")
        check(try store.record(id: "update")?.event.text == text, "Markdown and Unicode exact")
        check(rejects { _ = try run.message("changed duplicate", kind: .update, priority: .normal, id: "update") }, "changed message identity rejected")
        check(rejects { _ = try run.message("  ", kind: .answer, priority: .high) }, "empty message rejected")
        check(rejects { _ = try run.message(String(repeating: "x", count: 65_537), kind: .answer, priority: .high) }, "oversized message rejected")
        let q = UUID()
        try run.question(id: q, text: "Which account?", choices: ["Work", "Personal"], error: nil)
        try run.answer(questionID: q, text: "Work")
        check(try store.record(id: "answer:\(q)")?.event.reply?.messageID == "question:\(q)", "real answer references question")
        let countBefore = try store.latestSequence
        for name in ["describe_task_usage", "message_user", "read_history", "search_history"] {
            try run.observe(raw(["type":"item.started", "item":["id":name, "type":"mcp_tool_call", "server":"sentient_recovery", "tool":name, "arguments":["private":"SENTINEL"]]]), streamID: stream)
        }
        try run.observe(raw(["type":"item.completed", "item":["id":"reason", "type":"reasoning", "text":"PRIVATE_THINKING"]]), streamID: stream)
        try run.observe(raw(["type":"item.completed", "item":["id":"message", "type":"agent_message", "text":"UNREQUESTED_NARRATION"]]), streamID: stream)
        check(try store.latestSequence == countBefore, "internal tools/reasoning/narration absent")
        let nativeStart = try raw(["type":"item.started", "item":["id":"item_0", "type":"mcp_tool_call", "server":"sentient_native", "tool":"get_app_state", "arguments":["app":"Fixture"]]])
        try run.observe(nativeStart, streamID: stream)
        try run.observe(nativeStart, streamID: stream)
        try run.observe(raw(["type":"item.completed", "item":["id":"item_0", "type":"mcp_tool_call", "server":"sentient_native", "tool":"get_app_state", "status":"completed", "result":["content":[["type":"image","data":"IMAGE_SENTINEL"],["type":"text","text":"ACCESSIBILITY_TREE_SENTINEL"]]]]]), streamID: stream)
        try run.observe(nativeStart, streamID: stream) // late start cannot reopen completed tool
        try run.observe(nativeStart, streamID: UUID()) // a different execution can reuse item_0
        let shell = try raw(["type":"item.started", "item":["id":"shell", "type":"command_execution", "command":"echo fixture"]])
        try run.observe(shell, streamID: stream)
        try run.observe(raw(["type":"item.completed", "item":["id":"shell", "type":"command_execution", "status":"failed", "aggregated_output":"fixture failure"]]), streamID: stream)
        let claude = UUID()
        try run.observe(raw(["type":"assistant","message":["content":[["type":"tool_use","id":"c1","name":"mcp__calendar__list","input":["access_token":"SECRET_SENTINEL","query":"tomorrow"]]]]]), streamID: claude)
        try run.observe(raw(["type":"user","message":["content":[["type":"tool_result","tool_use_id":"c1","content":[["type":"text","text":"Two slots"],["type":"image","data":"SECOND_IMAGE"]]]]]]), streamID: claude)
        try run.observe(raw(["type":"assistant","message":["content":[["type":"tool_use","id":"relay","name":"mcp__sentient_relay__tool_0","input":[:]]]]]), streamID: claude)
        let records = try store.records(taskID: run.taskID, limit: 200)
        let activities = records.compactMap { $0.event.activity }
        check(activities.count == 7, "deduplicated Codex and Claude operations")
        let encoded = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        for sentinel in ["IMAGE_SENTINEL", "ACCESSIBILITY_TREE_SENTINEL", "SECOND_IMAGE", "SECRET_SENTINEL", "PRIVATE_THINKING", "UNREQUESTED_NARRATION"] {
            check(!encoded.contains(sentinel), "private/raw payload omitted: \(sentinel)")
        }
        check(activities.contains { $0.arguments?.contains("[redacted]") == true }, "credential fields redacted")
        try run.finish(outcome: .stopped, status: "[Stopped by user]")
        let afterStop = try store.records(taskID: run.taskID, limit: 200)
        check(afterStop.last?.event.outcome == .stopped, "stopped terminal saved")
        check(afterStop.contains { $0.event.activity?.status == .interrupted }, "pending action retains uncertainty")
        let stopContext = SidekickContext.build(records: try store.contextRecords(), summaries: []).prompt
        check(stopContext.contains("get_app_state") && stopContext.contains("not confirmed"), "Stop context retains unknown operation names without raw tool trace")
        check(afterStop.contains { $0.event.kind == .checkpoint && $0.event.text.contains("completed") && $0.event.text.contains("failed") }, "terminal checkpoint includes observed counts")
        check(!afterStop.contains { $0.event.id.hasPrefix("fallback:") }, "Stop does not invent final model response")
        let terminalSequence = try store.latestSequence
        try run.observe(shell, streamID: UUID())
        try run.finish(outcome: .success, status: "wrong late completion")
        check(try store.latestSequence == terminalSequence, "late events and duplicate endings ignored")
        check(rejects { _ = try run.message("late answer", kind: .answer, priority: .high) }, "post-terminal message rejected")
        let normal = try start()
        try normal.finish(outcome: .success, status: "Done", finalText: "Here are the slots.\nSTATUS: DONE — checked calendar\n")
        check(try store.record(id: "fallback:\(normal.taskID)")?.event.text == "Here are the slots.", "fallback preserves answer and strips sentinel")
        let answered = try start()
        _ = try answered.message("Your answer", kind: .answer, priority: .high)
        try answered.finish(outcome: .success, status: "Done", finalText: "Your answer\nSTATUS: DONE")
        check(try store.record(id: "fallback:\(answered.taskID)") == nil, "explicit answer not duplicated")
        let failed = try start()
        try failed.finish(outcome: .failed, status: "Action verification failed", finalText: "Successfully sent it!\nSTATUS: DONE")
        check(try store.record(id: "fallback:\(failed.taskID)")?.event.text == "Action verification failed", "failed outcome never repeats an unverified success claim")

        // A connector's final answer covers that execution, not a subsequent computer leg.
        for provider in ["codex", "claude"] {
            let fallback = try start(), firstStream = UUID(), nextStream = UUID()
            let began: [String: Any] = provider == "codex" ? ["type":"thread.started", "thread_id":"fixture"]
                : ["type":"system", "subtype":"init", "session_id":"fixture"]
            try fallback.observe(raw(began), streamID: firstStream)
            _ = try fallback.message("The first connector could not finish.", kind: .answer, priority: .normal)
            try fallback.observe(raw(began), streamID: nextStream)
            try fallback.finish(outcome: .success, status: "Done", finalText: "Completed the later leg.\nSTATUS: DONE")
            check(try store.record(id: "fallback:\(fallback.taskID)")?.event.text == "Completed the later leg.", "\(provider) execution invalidates previous answer coverage")

            let repeatedStart = try start(), sameStream = UUID()
            try repeatedStart.observe(raw(began), streamID: sameStream)
            _ = try repeatedStart.message("Already delivered.", kind: .answer, priority: .normal)
            try repeatedStart.observe(raw(began), streamID: sameStream)
            try repeatedStart.finish(outcome: .success, status: "Done", finalText: "Already delivered.")
            check(try store.record(id: "fallback:\(repeatedStart.taskID)") == nil, "repeated \(provider) start does not invalidate delivered answer")
        }
        let bookkeeping = try start(), bookkeepingStream = UUID()
        _ = try bookkeeping.message("The useful final answer.", kind: .answer, priority: .normal)
        for name in ["message_user", "describe_task_usage", "read_history", "search_history", "update_sidekick_instructions"] {
            for kind in ["item.started", "item.completed"] {
                try bookkeeping.observe(raw(["type":kind, "item":["id":name, "type":"mcp_tool_call", "server":"sentient_recovery", "tool":name, "status":"completed"]]), streamID: bookkeepingStream)
            }
        }
        try bookkeeping.observe(raw(["type":"assistant", "message":["content":[["type":"tool_use", "id":"structured", "name":"StructuredOutput", "input":[:]]]]]), streamID: bookkeepingStream)
        try bookkeeping.finish(outcome: .success, status: "Done", finalText: "The useful final answer.")
        check(try store.record(id: "fallback:\(bookkeeping.taskID)") == nil, "memory/telemetry/history/message bookkeeping does not cause duplicate final answer")
        let moreWork = try start(), workStream = UUID()
        _ = try moreWork.message("Initial result.", kind: .answer, priority: .normal)
        let action = try raw(["type":"item.started", "item":["id":"more-work", "type":"mcp_tool_call", "server":"calendar", "tool":"list", "arguments":[:]]])
        try moreWork.observe(action, streamID: workStream)
        try moreWork.finish(outcome: .success, status: "Done", finalText: "Later result.")
        check(try store.record(id: "fallback:\(moreWork.taskID)")?.event.text == "Later result.", "new substantive action invalidates prior answer")
        let repeatedAction = try start(), repeatedStream = UUID()
        try repeatedAction.observe(action, streamID: repeatedStream)
        _ = try repeatedAction.message("Final after that action.", kind: .answer, priority: .normal)
        try repeatedAction.observe(action, streamID: repeatedStream)
        try repeatedAction.finish(outcome: .success, status: "Done", finalText: "Final after that action.")
        check(try store.record(id: "fallback:\(repeatedAction.taskID)") == nil, "duplicate action start does not invalidate newer final answer")
        let clarified = try start(), clarificationID = UUID()
        _ = try clarified.message("Initial answer.", kind: .answer, priority: .normal)
        try clarified.question(id: clarificationID, text: "Which day?", choices: ["Today", "Tomorrow"], error: nil)
        try clarified.answer(questionID: clarificationID, text: "Tomorrow")
        try clarified.finish(outcome: .success, status: "Done", finalText: "Tomorrow is available.")
        check(try store.record(id: "fallback:\(clarified.taskID)")?.event.text == "Tomorrow is available.", "new user clarification needs its own final response")

        // Completion is a typed, task-scoped claim, independent of answer delivery and final formatting.
        func resolved(_ run: SidekickConversationRun, _ reply: String = "", success: Bool = true,
                      connector: Bool = false) -> AgentStatus {
            AgentStatus.resolve(reply, completion: run.completionStatus,
                                providerSucceeded: success, connector: connector)
        }
        let claimed = try start()
        _ = try claimed.message("The requested answer.", kind: .answer, priority: .normal, completion: .done)
        check(resolved(claimed) == .done, "structured final outcome survives missing STATUS line")
        check(resolved(claimed, "Useful answer", connector: true) == .done, "connector uses same structured completion")
        check(resolved(claimed, "STATUS: DONE", success: false) == .none, "failed provider cannot be promoted by either completion source")
        check(resolved(claimed, "STATUS: COULD_NOT - Outcome not verified") == .couldNot(reason: "Outcome not verified"), "explicit final refusal overrides saved DONE")
        _ = try claimed.message("I could not verify the send.", kind: .answer, priority: .normal, completion: .couldNot)
        check(resolved(claimed) == .couldNot(reason: "I could not verify the send."), "structured could_not carries honest final explanation")
        check(resolved(claimed, "STATUS: DONE") == .couldNot(reason: "I could not verify the send."), "structured refusal beats contradictory final DONE")
        _ = try claimed.message("Another answer without a completion claim.", kind: .answer, priority: .normal)
        check(resolved(claimed) == .none, "ordinary saved answer does not imply completion or retain older claim")
        check(resolved(claimed, "STATUS: DONE") == .done, "legacy DONE still works")
        check(resolved(claimed, "STATUS: COULD_NOT - Not possible") == .couldNot(reason: "Not possible"), "legacy refusal still works")
        for misleading in ["Done!", "STATUS: NOT DONE", "STATUS: DONE\nMore text", "Quoted STATUS: DONE"] {
            check(resolved(claimed, misleading) == .none, "text content cannot invent a completion: \(misleading)")
        }
        check(rejects { _ = try claimed.message("Progress", kind: .update, priority: .normal, completion: .done) }, "updates cannot assert completion")
        let workClaim = try start(), workClaimStream = UUID()
        _ = try workClaim.message("Done before more work.", kind: .answer, priority: .normal, id: "claim-before-work", completion: .done)
        try workClaim.observe(action, streamID: workClaimStream)
        check(resolved(workClaim) == .none, "substantive tool start invalidates earlier completion")
        _ = try workClaim.message("Done before more work.", kind: .answer, priority: .normal, id: "claim-before-work", completion: .done)
        check(resolved(workClaim) == .none, "replayed saved answer cannot re-arm stale completion")
        check(rejects { _ = try workClaim.message("Done before more work.", kind: .answer, priority: .normal, id: "claim-before-work", completion: .couldNot) }, "same message ID cannot change its completion claim")
        _ = try workClaim.message("Premature completion.", kind: .answer, priority: .normal, completion: .done)
        check(resolved(workClaim) == .none, "answer while substantive work is pending cannot confirm it")
        try workClaim.observe(raw(["type":"item.completed", "item":["id":"more-work", "type":"mcp_tool_call", "server":"calendar", "tool":"list", "arguments":[:], "status":"completed"]]), streamID: workClaimStream)
        check(resolved(workClaim) == .none, "tool completion cannot resurrect an earlier premature claim")
        _ = try workClaim.message("Verified after the tool returned.", kind: .answer, priority: .normal, completion: .done)
        check(resolved(workClaim) == .done, "fresh final answer after result can establish completion")
        try workClaim.observe(action, streamID: workClaimStream)
        check(resolved(workClaim) == .done, "replayed old tool start does not invalidate a newer outcome")
        try workClaim.question(id: UUID(), text: "One more detail?", choices: ["A", "B"], error: nil)
        check(resolved(workClaim) == .none, "question invalidates completion even before an answer")
        for provider in ["codex", "claude"] {
            let scope = try start(), scopeStream = UUID()
            let began: [String: Any] = provider == "codex" ? ["type":"thread.started", "thread_id":"fixture"]
                : ["type":"system", "subtype":"init", "session_id":"fixture"]
            try scope.observe(raw(began), streamID: scopeStream)
            _ = try scope.message("Done", kind: .answer, priority: .normal, completion: .done)
            try scope.observe(raw(began), streamID: scopeStream)
            check(resolved(scope) == .done, "repeated \(provider) start preserves current claim")
            try scope.observe(raw(began), streamID: UUID())
            check(resolved(scope) == .none, "new \(provider) provider leg invalidates previous completion")
            _ = try scope.message("New result", kind: .answer, priority: .normal, completion: .done)
            scope.invalidate()
            check(resolved(scope) == .none, "closed \(provider) run exposes no completion capability")
        }
        let bookClaim = try start(), bookClaimStream = UUID()
        _ = try bookClaim.message("Answer", kind: .answer, priority: .normal, completion: .done)
        for name in ["message_user", "describe_task_usage", "read_history", "update_sidekick_instructions"] {
            try bookClaim.observe(raw(["type":"item.started", "item":["id":name, "type":"mcp_tool_call", "server":"sentient_recovery", "tool":name]]), streamID: bookClaimStream)
        }
        check(resolved(bookClaim) == .done, "bookkeeping cannot erase a valid completion claim")
        try bookClaim.finish(outcome: .failed, status: "Provider failed after the answer")
        check(try store.records(taskID: bookClaim.taskID).last?.event.outcome == .failed, "a failed process result remains failed despite delivered structured DONE")
        check(resolved(bookClaim) == .none, "finished run drops its transient completion claim")

        // JSON encoded inside text needs the same redaction as a structured tool result.
        let nestedJSON = #"{"accessToken":"SECRET_CAMEL","result":{"text":"{\"api_key\":\"SECRET_NESTED\",\"slots\":[\"10 AM\"]}"},"tree_markdown":"PRIVATE_TREE"}"#
        let cleanedJSON = SidekickConversationRun.details(nestedJSON)!
        for sentinel in ["SECRET_CAMEL", "SECRET_NESTED", "PRIVATE_TREE"] {
            check(!cleanedJSON.contains(sentinel), "nested JSON redacts \(sentinel)")
        }
        check(cleanedJSON.contains("10 AM"), "legitimate nested connector results retained")
        let readable = SidekickConversationRun.details(["data": ["events": [["title": "Planning", "time": "10 AM"]]], "url": "https://example.invalid/report"])!
        check(readable.contains("Planning") && readable.contains("10 AM") && readable.contains("example.invalid"), "ordinary connector data and links remain readable")
        for key in ["tree_markdown", "axTree", "accessibilityTree", "accessibilityNodes", "screenshotData", "imageBase64"] {
            check(!SidekickConversationRun.details([key:"PRIVATE_STRUCTURE"])!.contains("PRIVATE_STRUCTURE"), "structure omitted: \(key)")
        }
        check(!SidekickConversationRun.details(["role":"AXWindow", "children":[["role":"AXButton", "label":"PRIVATE_AX"]]])!.contains("PRIVATE_AX"), "AX node structure omitted")
        check(!SidekickConversationRun.details(["private_key":"PRIVATE_KEY_VALUE", "credentials":["value":"PRIVATE_KEY_VALUE"]])!.contains("PRIVATE_KEY_VALUE"), "private key and credentials structures redacted")
        check(!SidekickConversationRun.details("-----BEGIN PRIVATE KEY-----\nPARTIAL_PEM_VALUE")!.contains("PARTIAL_PEM_VALUE"), "partial private key block omitted")
        check(!SidekickConversationRun.details("response token=PRIVATE_TOKEN_VALUE")!.contains("PRIVATE_TOKEN_VALUE"), "generic token assignment redacted")
        check(!SidekickConversationRun.details(["type":"resource", "resource":["mimeType":"image/png", "blob":"EMBEDDED_IMAGE"]])!.contains("EMBEDDED_IMAGE"), "embedded image resource omitted")
        let sensitiveText = "Authorization: Bearer SECRET_HEADER\nCookie: browser=SECRET_COOKIE\npassword=SECRET_PASSWORD\napiKey: SECRET_API\n--token SECRET_FLAG\nhttps://user:SECRET_URL@example.invalid\n[preview](data:image/png;base64,IMAGE_INLINE)"
        let cleanedText = SidekickConversationRun.details(["content":[["type":"text", "text":sensitiveText]]])!
        for sentinel in ["SECRET_HEADER", "SECRET_COOKIE", "SECRET_PASSWORD", "SECRET_API", "SECRET_FLAG", "SECRET_URL", "IMAGE_INLINE"] {
            check(!cleanedText.contains(sentinel), "embedded credential/image removed: \(sentinel)")
        }
        let embeddedImage = SidekickConversationRun.details("Before data:image/png;base64,IMAGE_SENTINEL after")!
        check(!embeddedImage.contains("IMAGE_SENTINEL") && embeddedImage.contains("Before") && embeddedImage.contains("after"), "inline image removed without discarding readable text")

        let execution = try start(), executionStream = UUID()
        try execution.observe(raw(["type":"item.completed", "item":["id":"nonzero", "type":"command_execution", "command":"fixture command", "status":"completed", "exit_code":17, "aggregated_output":"PRIVATE_EXECUTOR_STDOUT"]]), streamID: executionStream)
        try execution.observe(raw(["type":"item.completed", "item":["id":"js", "type":"mcp_tool_call", "server":"node_repl", "tool":"js", "status":"completed", "result":["content":[["type":"text", "text":"PRIVATE_JS_TREE"]]]]]), streamID: executionStream)
        let claudeExec = UUID()
        try execution.observe(raw(["type":"assistant", "message":["content":[["type":"tool_use", "id":"bash", "name":"Bash", "input":["command":"fixture command"]]]]]), streamID: claudeExec)
        try execution.observe(raw(["type":"user", "message":["content":[["type":"tool_result", "tool_use_id":"bash", "is_error":true, "content":"PRIVATE_CLAUDE_STDOUT"]]]]), streamID: claudeExec)
        try execution.observe(raw(["type":"assistant", "message":["content":[["type":"tool_use", "id":"native", "name":"mcp__sentient_native__get_app_state", "input":[:]]]]]), streamID: claudeExec)
        try execution.observe(raw(["type":"user", "message":["content":[["type":"tool_result", "tool_use_id":"native", "content":"PRIVATE_CLAUDE_AX"]]]]), streamID: claudeExec)
        let executionEvents = try store.records(taskID: execution.taskID)
        check(executionEvents.contains { $0.event.activity?.toolID.hasSuffix(":nonzero") == true && $0.event.activity?.status == .failed }, "nonzero exit status wins over completed transport status")
        let executionJSON = String(decoding: try JSONEncoder().encode(executionEvents), as: UTF8.self)
        for sentinel in ["PRIVATE_EXECUTOR_STDOUT", "PRIVATE_JS_TREE", "PRIVATE_CLAUDE_STDOUT", "PRIVATE_CLAUDE_AX"] {
            check(!executionJSON.contains(sentinel), "execution/capture result body omitted: \(sentinel)")
        }
        check(executionJSON.contains("fixture command"), "command input stays inspectable")
        try execution.finish(outcome: .failed, status: "Failed")
        let checkpoint = try store.records(taskID: execution.taskID).first { $0.event.kind == .checkpoint }!
        check(checkpoint.event.text.contains("2 completed") && checkpoint.event.text.contains("2 failed"), "checkpoint counts final observed tool states, not starts")

        // Retry deduplication must not silently accept changed sanitized payloads.
        let duplicates = try start(), duplicateStream = UUID()
        func duplicateWire(_ kind: String, query: String = "original", result: String = "original result", status: String = "completed") throws -> String {
            try raw(["type":kind, "item":["id":"duplicate", "type":"mcp_tool_call", "server":"calendar", "tool":"list",
                "arguments":["query":query], "result":["text":result], "status":status]])
        }
        try duplicates.observe(duplicateWire("item.started"), streamID: duplicateStream)
        let startSequence = try store.latestSequence
        try duplicates.observe(duplicateWire("item.started"), streamID: duplicateStream)
        check(try store.latestSequence == startSequence, "identical activity start is idempotent")
        do {
            try duplicates.observe(duplicateWire("item.started", query: "changed"), streamID: duplicateStream)
            preconditionFailure("Changed duplicate start accepted")
        } catch SidekickConversationStore.Failure.duplicateEvent { checks += 1 }
        check(try store.latestSequence == startSequence, "changed duplicate start leaves store unchanged")
        try duplicates.observe(duplicateWire("item.completed"), streamID: duplicateStream)
        let completeSequence = try store.latestSequence
        try duplicates.observe(duplicateWire("item.completed"), streamID: duplicateStream)
        check(try store.latestSequence == completeSequence, "identical terminal activity is idempotent")
        do {
            try duplicates.observe(duplicateWire("item.completed", result: "changed result"), streamID: duplicateStream)
            preconditionFailure("Changed duplicate completion accepted")
        } catch SidekickConversationStore.Failure.duplicateEvent { checks += 1 }
        check(try store.latestSequence == completeSequence, "changed duplicate result leaves store unchanged")
        for initial in ["completed", "failed"] {
            let terminal = try start(), terminalStream = UUID()
            try terminal.observe(duplicateWire("item.started"), streamID: terminalStream)
            let original = try duplicateWire("item.completed", status: initial)
            try terminal.observe(original, streamID: terminalStream)
            let savedSequence = try store.latestSequence
            try terminal.observe(original, streamID: terminalStream)
            check(try store.latestSequence == savedSequence, "identical \(initial) terminal retry is harmless")
            do {
                try terminal.observe(duplicateWire("item.completed", status: initial == "completed" ? "failed" : "completed"), streamID: terminalStream)
                preconditionFailure("Contradictory terminal status accepted")
            } catch SidekickConversationStore.Failure.duplicateEvent { checks += 1 }
            check(try store.latestSequence == savedSequence, "conflicting \(initial) terminal cannot append or rewrite activity")
            check(try store.records(taskID: terminal.taskID).last?.event.activity?.status.rawValue == initial, "original terminal status remains authoritative")
        }

        // Read capabilities are valid only while the owning run and store generation are live.
        let readableRun = try start()
        let exactHistory = "Exact historical reply 🦊"
        let readableID = try readableRun.message(exactHistory, kind: .answer, priority: .normal)
        let lookedUp = try readableRun.withOpenHistory { try store.record(id: readableID)?.event.text }
        check(lookedUp == exactHistory, "open history returns the real lookup result")
        do {
            _ = try readableRun.withOpenHistory { throw FixtureFailure.intentional }
            preconditionFailure("History body failure swallowed")
        } catch FixtureFailure.intentional { checks += 1 }
        try readableRun.finish(outcome: .success, status: "Done")
        var closedBodyEntered = false
        do {
            _ = try readableRun.withOpenHistory { closedBodyEntered = true; return "must not run" }
            preconditionFailure("Finished run read history")
        } catch SidekickConversationRun.Failure.closed { checks += 1 }
        check(!closedBodyEntered, "finished run rejects lookup before evaluating its body")
        let invalidatedRead = try start()
        invalidatedRead.invalidate()
        var invalidatedBodyEntered = false
        do {
            _ = try invalidatedRead.withOpenHistory { invalidatedBodyEntered = true; return 1 }
            preconditionFailure("Invalidated run read history")
        } catch SidekickConversationRun.Failure.closed { checks += 1 }
        check(!invalidatedBodyEntered, "invalidated run rejects lookup before evaluating body")

        // Reset via another SQLite handle between lookup and delivery, deterministically.
        let racingStore = try SidekickConversationStore(url: root.appendingPathComponent("race/history.sqlite"))
        let resettingStore = try SidekickConversationStore(url: racingStore.url)
        let racingTask = UUID()
        _ = try racingStore.append(.init(taskID: racingTask, kind: .taskStarted, text: "Fixture"))
        let racingRun = try SidekickConversationRun(store: racingStore, taskID: racingTask, generation: racingStore.generation)
        let racingID = try racingRun.message("Previous generation answer", kind: .answer, priority: .normal)
        var readOldValue = false, deliveredOldValue = false
        do {
            _ = try racingRun.withOpenHistory {
                let value = try racingStore.record(id: racingID)?.event.text
                readOldValue = value == "Previous generation answer"
                try resettingStore.reset()
                return value
            }
            deliveredOldValue = true
        } catch SidekickConversationStore.Failure.staleGeneration { checks += 1 }
        check(readOldValue && !deliveredOldValue, "generation recheck discards a result read before concurrent reset")
        check(try racingStore.latestSequence == 0, "racing lookup cannot recreate reset history")
        var staleBodyEntered = false
        do {
            _ = try racingRun.withOpenHistory { staleBodyEntered = true; return 1 }
            preconditionFailure("Stale run entered read body")
        } catch SidekickConversationStore.Failure.staleGeneration { checks += 1 }
        check(!staleBodyEntered, "already-reset generation rejects lookup before evaluating body")
        let stale = try start()
        try store.reset()
        check(rejects { _ = try stale.message("stale", kind: .answer, priority: .normal) }, "old generation cannot resurrect history")
        check(try store.latestSequence == 0, "reset remains empty")
        let long = String(repeating: "🦊é", count: 1000)
        let bounded = SidekickConversationRun.bounded(long, bytes: 200)
        check(bounded.utf8.count <= 200 && !bounded.contains("�"), "UTF8 bounds never split scalar")
        let family = "👨‍👩‍👧‍👦"
        let graphemes = SidekickConversationRun.bounded(String(repeating: family, count: 20), bytes: 80)
        let prefix = graphemes.components(separatedBy: "\n[truncated]")[0]
        check(prefix.allSatisfy { String($0) == family }, "bounds preserve complete composed graphemes")
        for budget in [0, 1, 5, 11] {
            check(SidekickConversationRun.bounded("longer than the budget", bytes: budget).utf8.count <= budget, "tiny bound respected")
        }
        print("PASS \(checks) Sidekick run assertions")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-run-fixture-') as tmp:
    work = Path(tmp)
    (work / 'Main.swift').write_text(HARNESS)
    subprocess.run(['swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
                    '-strict-concurrency=complete', '-warnings-as-errors',
                    str(APP.parent / 'Cloud/AgentStatus.swift'), str(APP / 'SidekickConversationStore.swift'), str(APP / 'SidekickConversationRun.swift'), str(APP / 'SidekickContext.swift'),
                    str(work / 'Main.swift'), '-o', str(work / 'test')], check=True)
    subprocess.run([str(work / 'test')], check=True)
