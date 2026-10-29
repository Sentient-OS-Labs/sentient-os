#!/usr/bin/env python3
"""Production SQLite transcript paging and exact read-receipt regression tests.

Uses complete store code, temporary databases and independent SQLite handles. No app,
model, credentials, production history/preferences or UI is touched.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sentient OS macOS/Notch Magic/SidekickConversationStore.swift"
FIXTURE = r'''
import Foundation
import SQLite3

nonisolated final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String] = []
    func add(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(String(describing: error)) }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return errors.isEmpty }
}

typealias Store = SidekickConversationStore
typealias Event = SidekickConversationEvent

nonisolated func sql(_ url: URL, _ command: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { fatalError("open fixture") }
    defer { sqlite3_close_v2(db) }
    guard sqlite3_exec(db, command, nil, nil, nil) == SQLITE_OK else { fatalError(String(cString: sqlite3_errmsg(db))) }
}
nonisolated func queryPlan(_ url: URL, _ query: String) throws -> String {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { fatalError("open query-plan fixture") }
    defer { sqlite3_close_v2(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + query, -1, &statement, nil) == SQLITE_OK, let statement else { fatalError("prepare query plan") }
    defer { sqlite3_finalize(statement) }
    var lines: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW { lines.append(String(cString: sqlite3_column_text(statement, 3))) }
    return lines.joined(separator: "\n")
}
@main struct TranscriptTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { fatalError(label) }; checks += 1
    }
    static func rejects(_ label: String, _ body: () throws -> Void) {
        do { try body() } catch { checks += 1; return }; fatalError(label)
    }
    static func taskMetadata(_ root: URL) throws {
        let store = try Store(url: root.appendingPathComponent("task-metadata.sqlite"))
        let generation = try store.generation
        let began = Date(timeIntervalSinceReferenceDate: 76543210.125)
        let completed = UUID(), legacy = UUID(), idle = UUID(), bookkeeping = UUID(), memory = UUID()
        let start = Event(id: "caller-supplied-start-identity", taskID: completed, kind: .taskStarted, text: "Actual execution", createdAt: began)
        let startRecord = try store.append(start)
        _ = try store.append(Event(id: "visible-request", taskID: completed, kind: .userMessage, text: "Do the work", createdAt: began.addingTimeInterval(-50)))
        _ = try store.append(Event(id: "completed-operation", taskID: completed, kind: .activity, text: "calendar.search",
            activity: .init(toolID: "provider-42", name: "calendar.search", status: .completed)))
        _ = try store.append(Event(id: "caller-supplied-terminal-identity", taskID: completed, kind: .taskFinished,
            text: "Done", createdAt: began.addingTimeInterval(12.375), outcome: .success))
        let oldPrompt = try store.append(Event(id: "old-request-without-start", taskID: legacy, kind: .userMessage,
            text: "Legacy request", createdAt: began.addingTimeInterval(-5000)))
        _ = try store.append(Event(id: "legacy-operation", taskID: legacy, kind: .activity, text: "files.read",
            activity: .init(toolID: "legacy-tool", name: "files.read", status: .failed)))
        _ = try store.append(Event(id: "old-terminal-without-start", taskID: legacy, kind: .taskFinished,
            text: "Stopped", createdAt: began.addingTimeInterval(-4900), outcome: .stopped))
        _ = try store.append(Event(taskID: idle, kind: .taskStarted, text: "No tools yet", createdAt: began.addingTimeInterval(20)))
        _ = try store.append(Event(taskID: bookkeeping, kind: .taskStarted, text: "Internal bookkeeping", createdAt: began))
        for name in ["describe_task_usage", "message_user", "read_history", "search_history"] {
            for qualified in ["sentient_recovery." + name, "mcp__sentient_recovery__" + name] {
                _ = try store.append(Event(taskID: bookkeeping, kind: .activity, text: qualified,
                    activity: .init(toolID: qualified, name: qualified, status: .completed)))
            }
        }
        _ = try store.append(Event(taskID: memory, kind: .activity, text: "sentient_recovery.update_sidekick_instructions",
            activity: .init(toolID: "memory-1", name: "sentient_recovery.update_sidekick_instructions", status: .completed)))
        // Metadata must not inspect activity payloads at all. The activity disclosure itself
        // will correctly report this synthetic corrupt payload if a separate caller opens it.
        try sql(store.url, "UPDATE events SET payload = x'ff' WHERE id = 'legacy-operation';")
        let states = try store.transcriptTaskStates(taskIDs: [memory, legacy, completed, idle, bookkeeping, completed, UUID()], expectedGeneration: generation)
        try check(states.count == 5, "bulk task metadata duplicated IDs or invented unknown tasks")
        let finished = states.first { $0.taskID == completed }!
        try check(finished.firstSequence == startRecord.sequence && finished.startedAt == began, "metadata did not use actual started_sequence timestamp")
        try check(finished.finished?.event.id == "caller-supplied-terminal-identity", "metadata inferred a generated terminal identity")
        try check(finished.finished!.event.createdAt.timeIntervalSince(finished.startedAt!) == 12.375, "start/end duration inputs changed")
        try check(finished.hasActivity, "real completed task activity was missed")
        let old = states.first { $0.taskID == legacy }!
        try check(old.firstSequence == oldPrompt.sequence && old.startedAt == nil, "missing start was fabricated from legacy request time")
        try check(old.hasActivity && old.finished?.event.outcome == .stopped, "activity existence decoded payload or lost stopped outcome")
        let pending = states.first { $0.taskID == idle }!
        try check(pending.startedAt == began.addingTimeInterval(20) && pending.finished == nil && !pending.hasActivity,
                  "task without tools or ending fabricated work metadata")
        try check(states.first { $0.taskID == bookkeeping }?.hasActivity == false, "hidden telemetry/message/history bookkeeping became visible work")
        try check(states.first { $0.taskID == memory }?.hasActivity == true, "real memory operation was overfiltered")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(start)) as! [String: Any]
        try check((encoded["createdAt"] as? NSNumber)?.doubleValue == began.timeIntervalSinceReferenceDate,
                  "Date encoding no longer uses Foundation's reference-date epoch")
        let plan = try queryPlan(store.url, "SELECT EXISTS(SELECT 1 FROM events WHERE task_id = '\(completed.uuidString)' AND kind = 'activity')")
        try check(plan.contains("events_task_sequence"), "activity existence did not use existing task index")

        let lateStartTask = UUID()
        let first = try store.append(Event(taskID: lateStartTask, kind: .userMessage, text: "Earlier request", createdAt: began))
        _ = try store.append(Event(taskID: lateStartTask, kind: .taskStarted, createdAt: began.addingTimeInterval(30)))
        let lateStart = try store.transcriptTaskStates(taskIDs: [lateStartTask], expectedGeneration: generation).first!
        try check(lateStart.firstSequence == first.sequence && lateStart.startedAt == began.addingTimeInterval(30),
                  "first message timestamp replaced later actual task start")

        // The legacy converter created synthetic start/end records from one request date.
        // That structural start is not observed execution timing, even if an old ending
        // happens to carry a different timestamp. Preserve the records, but expose no duration.
        for endingOffset in [0.0, 12_345.0] {
            let importedTask = UUID()
            let importedStart = try store.append(Event(id: "legacy-start:\(importedTask)", taskID: importedTask,
                kind: .taskStarted, text: "Imported request", createdAt: began, source: "command"))
            _ = try store.append(Event(id: "legacy-request:\(importedTask)", taskID: importedTask,
                kind: .userMessage, text: "Imported request", createdAt: began, source: "command"))
            let importedEnd = try store.append(Event(id: "legacy-end:\(importedTask)", taskID: importedTask,
                kind: .taskFinished, text: "✓ done", createdAt: began.addingTimeInterval(endingOffset), outcome: .success))
            let imported = try store.transcriptTaskStates(taskIDs: [importedTask], expectedGeneration: generation).first!
            try check(imported.startedAt == nil, "synthetic imported start fabricated duration for offset \(endingOffset)")
            try check(imported.firstSequence == importedStart.sequence && imported.finished == importedEnd,
                      "legacy timing exclusion altered stored task anchors or outcome")
            try check(!imported.hasActivity, "legacy duration exclusion invented activity")
            let reopened = try Store(url: store.url)
            try check(try reopened.transcriptTaskStates(taskIDs: [importedTask], expectedGeneration: generation).first?.startedAt == nil,
                      "reopened imported task restored fabricated execution timing")
        }
        let similarName = UUID()
        _ = try store.append(Event(id: "legacy-started-real-operation", taskID: similarName,
            kind: .taskStarted, createdAt: began.addingTimeInterval(40)))
        try check(try store.transcriptTaskStates(taskIDs: [similarName], expectedGeneration: generation).first?.startedAt == began.addingTimeInterval(40),
                  "legacy namespace exclusion swallowed an unrelated caller-supplied start ID")

        let bulk = (0..<100).map { _ in UUID() }
        _ = try store.appendBatch(bulk.enumerated().map { offset, id in
            Event(id: "arbitrary-anchor-\(offset)", taskID: id, kind: .taskStarted, createdAt: began.addingTimeInterval(Double(offset)))
        })
        let bulkStates = try store.transcriptTaskStates(taskIDs: Array(bulk.reversed()), expectedGeneration: generation)
        try check(bulkStates.map(\.taskID) == bulk, "bulk metadata lost or reordered variable task identities")
        try check(bulkStates.enumerated().allSatisfy { $0.element.startedAt == began.addingTimeInterval(Double($0.offset)) && !$0.element.hasActivity },
                  "bulk timestamp/activity metadata differs by task")
        rejects("task metadata exceeded 100-task bound") { _ = try store.transcriptTaskStates(taskIDs: bulk + [UUID()], expectedGeneration: generation) }
        try store.reset()
        rejects("stale generation returned metadata after reset") { _ = try store.transcriptTaskStates(taskIDs: [completed], expectedGeneration: generation) }
        let currentGeneration = try store.generation
        try check(try store.transcriptTaskStates(taskIDs: [completed], expectedGeneration: currentGeneration).isEmpty,
                  "reset retained old task metadata")
        _ = try store.append(Event(taskID: completed, kind: .taskStarted, createdAt: began.addingTimeInterval(1000)))
        let recreated = try store.transcriptTaskStates(taskIDs: [completed], expectedGeneration: currentGeneration).first!
        try check(recreated.startedAt == began.addingTimeInterval(1000) && recreated.finished == nil && !recreated.hasActivity,
                  "reused task ID inherited old generation's work")
        print("PASS bulk task start/end inputs and activity existence without activity payload decoding")
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try taskMetadata(root)
        let url = root.appendingPathComponent("transcript.sqlite")
        let store = try Store(url: url)
        let generation = try store.generation
        var visible: [Store.Record] = [], tasks: [UUID] = []
        for index in 0..<35 {
            let task = UUID(); tasks.append(task)
            _ = try store.append(Event(id: "start-\(index)", taskID: task, kind: .taskStarted, text: "Internal task envelope"))
            visible.append(try store.append(Event(id: "user-\(index)", taskID: task, kind: .userMessage, text: "Request \(index)")))
            for operation in 0..<5 {
                _ = try store.append(Event(taskID: task, kind: .activity, text: "INTERNAL_TRACE",
                    activity: .init(toolID: "tool-\(operation)", name: "search", status: .completed)))
            }
            _ = try store.append(Event(taskID: task, kind: .checkpoint, text: "INTERNAL_CHECKPOINT"))
            if index == 10 {
                visible.append(try store.append(Event(id: "question", taskID: task, kind: .question, text: "Choose a day", choices: ["Monday", "Tuesday"])))
                visible.append(try store.append(Event(id: "choice", taskID: task, kind: .answer, text: "Tuesday", reply: .init(messageID: "question"))))
            }
            visible.append(try store.append(Event(id: "assistant-\(index)", taskID: task, kind: .assistantMessage,
                text: "Answer \(index): **café 👩🏽‍💻**", messageKind: .answer)))
            visible.append(try store.append(Event(id: "end-\(index)", taskID: task, kind: .taskFinished,
                text: index == 10 ? "Stopped by user" : "Done", outcome: index == 10 ? .stopped : .success)))
        }
        let latest = try store.transcriptPage()
        try check(latest.generation == generation, "page generation missing")
        try check(latest.records == Array(visible.suffix(40)), "initial 40 rows must be latest visible transcript, not model context")
        try check(latest.hasEarlier && !latest.hasLater, "recent page boundaries wrong")
        try check(!latest.records.contains { [.activity, .checkpoint, .taskStarted].contains($0.event.kind) }, "internal rows leaked to main transcript")
        let capped = try store.transcriptPage(limit: 1000)
        try check(capped.records.count == 100, "page cap not enforced")
        var reversePages = latest.records
        var page = latest
        while page.hasEarlier {
            page = try store.transcriptPage(before: page.records.first!.sequence, limit: 17)
            try check(page.records.last!.sequence < reversePages.first!.sequence, "before cursor overlaps loaded rows")
            reversePages.insert(contentsOf: page.records, at: 0)
        }
        try check(reversePages == visible, "backward pagination lost or duplicated visible records")
        var forward: [Store.Record] = [], cursor: Int64 = 0
        repeat {
            page = try store.transcriptPage(after: cursor, limit: 13)
            forward += page.records
            if let last = page.records.last { cursor = last.sequence }
        } while page.hasLater
        try check(forward == visible, "forward pagination lost or duplicated visible records")
        let firstEmpty = try store.transcriptPage(before: visible.first!.sequence)
        let lastEmpty = try store.transcriptPage(after: visible.last!.sequence)
        try check(firstEmpty.records.isEmpty && !firstEmpty.hasEarlier && firstEmpty.hasLater, "first boundary empty page misleading")
        try check(lastEmpty.records.isEmpty && lastEmpty.hasEarlier && !lastEmpty.hasLater, "last boundary empty page misleading")
        rejects("mixed page cursors accepted") { _ = try store.transcriptPage(before: 5, after: 2) }
        rejects("negative page cursor accepted") { _ = try store.transcriptPage(after: -1) }

        for target in ["user-0", "assistant-17", "question", "choice", "end-10", "end-34"] {
            let center = try store.transcriptAround(messageID: target, limit: 9)
            try check(center.records.count == 9 && center.records.contains { $0.event.id == target }, "around page must include exact target and fill available neighbors")
            let positions = center.records.map { record in visible.firstIndex(of: record)! }
            try check(positions == Array(positions.first!...positions.last!), "around page contains hidden gaps")
        }
        rejects("internal checkpoint became a transcript destination") {
            let checkpoint = try store.records(taskID: tasks[0]).first { $0.event.kind == .checkpoint }!
            _ = try store.transcriptAround(messageID: checkpoint.event.id)
        }
        rejects("missing transcript destination silently opened newest messages") { _ = try store.transcriptAround(messageID: "missing") }
        let exactStates = try store.transcriptTaskStates(taskIDs: [tasks[10], tasks[17]], expectedGeneration: generation)
        try check(exactStates.count == 2 && exactStates[0].finished?.event.outcome == .stopped && exactStates[1].finished?.event.outcome == .success,
                  "task states inferred wrong outcomes from partial transcript")
        try check(exactStates[0].firstSequence == (try store.taskStart(taskID: tasks[10]))?.sequence, "task anchor changed")
        let active = UUID()
        _ = try store.append(Event(taskID: active, kind: .taskStarted, text: "Still running"))
        _ = try store.append(Event(taskID: active, kind: .userMessage, text: "Live request"))
        try check(try store.transcriptTaskStates(taskIDs: [active], expectedGeneration: generation).first?.finished == nil, "unfinished task fabricated a terminal outcome")
        _ = try store.append(Event(id: "search-match", taskID: active, kind: .assistantMessage, text: "Literal search 100%_done\\today"))
        for _ in 0..<12 {
            _ = try store.append(Event(taskID: active, kind: .checkpoint, text: "Literal search 100%_done\\today"))
        }
        try check(try store.searchTranscript("100%_done\\today", limit: 1).map(\.event.id) == ["search-match"], "internal checkpoint matches hid visible transcript search result")
        try check(try store.searchTranscript("100%_done\\today").allSatisfy { $0.event.kind == .assistantMessage }, "search exposed internal rows or expanded SQL wildcards")
        print("PASS transcript filtering, cursors, around destinations and exact task outcomes")

        let huge = String(repeating: "👩🏽‍💻\n", count: 5000)
        let hugeRecord = try store.append(Event(id: "large-answer", taskID: active, kind: .assistantMessage, text: huge))
        let tiny = try store.transcriptPage(limit: 40, byteBudget: 100)
        try check(tiny.records == [hugeRecord] && tiny.hasEarlier, "oversized newest message must remain exact and pagination must progress")
        let aroundTiny = try store.transcriptAround(messageID: "large-answer", limit: 40, byteBudget: 100)
        try check(aroundTiny.records == [hugeRecord], "around byte budget truncated or dropped exact target")
        let older = try store.transcriptPage(before: hugeRecord.sequence, limit: 2, byteBudget: 100)
        try check(older.records.count == 1 && older.records[0].sequence < hugeRecord.sequence, "byte-budget paging got stuck")
        let previousAnchor = latest.records.first!.sequence
        let beforeNewAppend = try store.transcriptPage(before: previousAnchor, limit: 5)
        _ = try store.append(Event(taskID: active, kind: .assistantMessage, text: "New incoming answer"))
        try check(try store.transcriptPage(before: previousAnchor, limit: 5).records == beforeNewAppend.records, "new append moved an older cursor window")
        let legal = try Store(url: root.appendingPathComponent("legal-escaped.sqlite"))
        let escaped = String(repeating: "\"\n", count: 60_000)
        let original = try legal.append(Event(id: "escaped-source", taskID: UUID(), kind: .assistantMessage, text: escaped))
        let quoted = try legal.append(Event(id: "escaped-reply", taskID: UUID(), kind: .userMessage, text: escaped,
            reply: .init(messageID: original.event.id, selectedText: escaped)))
        let escapedPage = try legal.transcriptPage(after: original.sequence, byteBudget: 1024)
        try check(escapedPage.records == [quoted], "legal JSON-escaped text plus selected quote falsely reported corrupt")
        try check(try legal.transcriptAround(messageID: quoted.event.id, byteBudget: 1024).records.first?.event.reply?.selectedText == escaped,
                  "around target lost large legal selected quote")
        print("PASS exact large messages, byte budget and stable cursors during new appends")

        // Exact receipts can mark the new answer without marking older skipped answers read.
        let unreadBefore = try store.unreadCount
        try store.markRead(messageIDs: ["assistant-34"], expectedGeneration: generation)
        try check(try store.unreadCount == unreadBefore - 1, "exact receipt marked older skipped answers read")
        try check(try store.readThroughSequence == 0, "exact receipt advanced old high watermark")
        try check(try store.unread(limit: 500).contains { $0.event.id == "assistant-0" }, "old unseen answer disappeared")
        try store.markRead(messageIDs: ["assistant-34", "assistant-34"], expectedGeneration: generation)
        try check(try store.unreadCount == unreadBefore - 1, "duplicate exact receipts changed unread count")
        let beforeInvalid = try store.unreadCount
        do {
            try store.markRead(messageIDs: ["missing"], expectedGeneration: generation)
            fatalError("missing read target was accepted")
        } catch Store.Failure.invalidReadReceipt { checks += 1 }
        rejects("unknown ID was accepted alongside a valid receipt") {
            try store.markRead(messageIDs: ["assistant-0", "missing"], expectedGeneration: generation)
        }
        try check(try store.unreadCount == beforeInvalid, "invalid receipt batch partially committed")
        rejects("outgoing message treated as an incoming receipt") { try store.markRead(messageIDs: ["user-0"], expectedGeneration: generation) }
        let reopened = try Store(url: url)
        try check(try reopened.unreadCount == beforeInvalid, "exact receipts were not durable on reopen")
        try store.markRead(throughSequence: visible.first { $0.event.id == "assistant-2" }!.sequence, expectedGeneration: generation)
        try check(try store.unread(limit: 500).contains { $0.event.id == "assistant-3" }, "legacy watermark consumed a newer answer")
        try check(try !store.unread(limit: 500).contains { ["assistant-0", "assistant-1", "assistant-2", "assistant-34"].contains($0.event.id) }, "watermark and exact receipts did not combine")
        try store.reset()
        rejects("old generation marked post-reset history read") { try store.markRead(messageIDs: [], expectedGeneration: generation) }
        rejects("old generation read post-reset task state") { _ = try store.transcriptTaskStates(taskIDs: [], expectedGeneration: generation) }
        let freshTask = UUID()
        _ = try store.append(Event(taskID: freshTask, kind: .assistantMessage, text: "New generation answer"))
        try check(try store.unreadCount == 1, "reset left exact receipts for reused sequences")
        print("PASS precise read receipts, atomic rejection, reopen and reset generation checks")

        let attention = try Store(url: root.appendingPathComponent("priority.sqlite"))
        let attentionTask = UUID(), attentionGeneration = try attention.generation
        _ = try attention.append(Event(id: "older-high", taskID: attentionTask, kind: .assistantMessage, text: "Important result", priority: .high))
        _ = try attention.append(Event(id: "newer-normal", taskID: attentionTask, kind: .assistantMessage, text: "Routine answer", priority: .normal))
        try check(try attention.latestUnreadHighPriorityMessage?.event.id == "older-high", "newer normal answer masked earlier unread high-priority message")
        _ = try attention.append(Event(id: "newer-question", taskID: attentionTask, kind: .question, text: "A current question", priority: .high, choices: ["A", "B"]))
        try check(try attention.latestUnreadHighPriorityMessage?.event.id == "older-high", "newer question masked explicit high-priority message")
        try check(try attention.latestUnreadAttention?.event.id == "newer-question", "old attention-query contract changed")
        _ = try attention.append(Event(id: "newest-high", taskID: attentionTask, kind: .assistantMessage, text: "New important update", messageKind: .update, priority: .high))
        try check(try attention.latestUnreadHighPriorityMessage?.event.id == "newest-high", "newest explicit high-priority update not selected")
        try attention.markRead(messageIDs: ["newest-high"], expectedGeneration: attentionGeneration)
        try check(try attention.latestUnreadHighPriorityMessage?.event.id == "older-high", "exact receipt consumed an older skipped high-priority message")
        try attention.markRead(messageIDs: ["older-high"], expectedGeneration: attentionGeneration)
        try check(try attention.latestUnreadHighPriorityMessage == nil && attention.unreadCount == 2, "exact receipts did not clear only explicit high-priority messages")
        print("PASS explicit high-priority query cannot be masked by later normal answers or questions")

        // Simulate a real prior v1 database lacking the additive receipt table.
        let legacyURL = root.appendingPathComponent("prior-v1.sqlite")
        do {
            let legacy = try Store(url: legacyURL)
            let task = UUID()
            let seen = try legacy.append(Event(id: "old-seen", taskID: task, kind: .assistantMessage, text: "Already seen"))
            _ = try legacy.append(Event(id: "old-unseen", taskID: task, kind: .assistantMessage, text: "Still unseen"))
            try legacy.markRead(throughSequence: seen.sequence)
            legacy.close()
        }
        try sql(legacyURL, "DROP TABLE read_events;")
        let migrated = try Store(url: legacyURL)
        try check(try migrated.unread().map(\.event.id) == ["old-unseen"], "additive v1 migration lost legacy read state")
        try migrated.markRead(messageIDs: ["old-unseen"], expectedGeneration: migrated.generation)
        try check(try migrated.unreadCount == 0, "migrated v1 database could not save exact receipts")
        let incompatibleURL = root.appendingPathComponent("bad-receipts.sqlite")
        let incompatible = try Store(url: incompatibleURL); incompatible.close()
        try sql(incompatibleURL, "DROP TABLE read_events; CREATE TABLE read_events(sequence TEXT);")
        rejects("incompatible read-receipt table accepted") { _ = try Store(url: incompatibleURL) }
        try sql(incompatibleURL, "DROP TABLE read_events; CREATE TABLE read_events(sequence INTEGER PRIMARY KEY);")
        rejects("read-receipt table without expected foreign key accepted") { _ = try Store(url: incompatibleURL) }
        print("PASS compatible existing-v1 upgrade and incompatible additive schema rejection")

        // Independent writer resets while a reader builds multi-query pages. Every nonempty
        // page must belong wholly to the generation reported with that same read snapshot.
        let raceURL = root.appendingPathComponent("snapshot-race.sqlite")
        let writer = try Store(url: raceURL), reader = try Store(url: raceURL)
        let errors = Failures(), group = DispatchGroup(), go = DispatchSemaphore(value: 0)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            go.wait()
            do {
                for _ in 0..<40 {
                    try writer.reset()
                    let current = try writer.generation
                    _ = try writer.appendBatch((0..<8).map { _ in Event(taskID: UUID(), kind: .assistantMessage, text: current.uuidString) }, expectedGeneration: current)
                }
            } catch { errors.add(error) }
        }
        go.signal()
        for _ in 0..<80 {
            let snapshot = try reader.transcriptPage(limit: 7)
            try check(snapshot.records.allSatisfy { $0.event.text == snapshot.generation.uuidString }, "transcript mixed records and generation across a concurrent reset")
        }
        try check(group.wait(timeout: .now() + 10) == .success && errors.isEmpty, "concurrent transcript writer did not complete cleanly")
        print("PASS independent-handle reset never mixes page generations")

        // A long-lived profile dominated by internal activity must use the small partial
        // indexes. Seed synthetic activity directly only to keep this performance fixture fast.
        let perfURL = root.appendingPathComponent("tool-heavy.sqlite")
        let seed = try Store(url: perfURL), perfTask = UUID()
        _ = try seed.append(Event(id: "perf-high", taskID: perfTask, kind: .assistantMessage, text: "Earlier important answer", priority: .high))
        seed.close()
        try sql(perfURL, """
            DROP INDEX events_transcript_sequence;
            DROP INDEX events_incoming_sequence;
            DROP INDEX events_answers_sequence;
            WITH RECURSIVE counter(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM counter WHERE n<100000)
            INSERT INTO events(id, task_id, kind, text, payload)
            SELECT 'activity-'||n, '\(perfTask.uuidString)', 'activity', 'Synthetic operation',
              CAST(json_object('id','activity-'||n,'taskID','\(perfTask.uuidString)', 'kind','activity',
                'text','Synthetic operation','createdAt',0,'priority','normal',
                'activity',json_object('toolID','tool-'||n,'name','search','status','completed')) AS BLOB)
            FROM counter;
            """)
        let reopenBegan = Date()
        let perf = try Store(url: perfURL)
        let indexMilliseconds = Date().timeIntervalSince(reopenBegan) * 1000
        let tail = try perf.append(Event(id: "perf-normal", taskID: perfTask, kind: .assistantMessage, text: "Latest ordinary answer"))
        _ = try perf.append(Event(id: "perf-question", taskID: perfTask, kind: .question, text: "Latest question", choices: ["A", "B"]))
        let visibleKinds = "kind IN ('userMessage', 'assistantMessage', 'question', 'answer', 'taskFinished')"
        let transcriptPlan = try queryPlan(perfURL, "SELECT sequence,length(payload) FROM events WHERE \(visibleKinds) AND sequence < \(tail.sequence) ORDER BY sequence DESC LIMIT 40")
        try check(transcriptPlan.contains("events_transcript_sequence"), "tool-heavy transcript cursor did not use its partial index")
        let incomingPlan = try queryPlan(perfURL, "SELECT sequence,payload FROM events WHERE kind IN ('assistantMessage', 'question') AND sequence > 0 ORDER BY sequence DESC LIMIT 1")
        try check(incomingPlan.contains("events_incoming_sequence"), "tool-heavy unread query did not use incoming partial index")
        let answerPlan = try queryPlan(perfURL, "SELECT 1 FROM events AS answer WHERE answer.kind = 'answer' AND json_extract(CAST(answer.payload AS TEXT), '$.reply.messageID') = 'perf-question'")
        try check(answerPlan.contains("events_answers_sequence"), "question resolution scanned internal activity instead of answer index")
        try check(try perf.transcriptPage(before: tail.sequence).records.map(\.event.id) == ["perf-high"], "tool-heavy cursor did not recover earlier message")
        try check(try perf.latestUnreadHighPriorityMessage?.event.id == "perf-high", "tool-heavy attention lost unread priority message")
        try check(try perf.unreadCount == 3, "tool-heavy profile unread count is wrong")
        let queriesBegan = Date()
        for _ in 0..<100 {
            _ = try perf.transcriptPage(before: tail.sequence)
            _ = try perf.latestUnreadHighPriorityMessage
            _ = try perf.unreadCount
        }
        let pairMilliseconds = Date().timeIntervalSince(queriesBegan) * 1000 / 100
        print(String(format: "PASS 100k-activity profile: additive index build %.1f ms; cursor+priority+unread queries %.3f ms", indexMilliseconds, pairMilliseconds))
        print("PASS \(checks) Sidekick transcript assertions")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="sentient-transcript-") as temporary:
    root = Path(temporary)
    fixture = root / "TranscriptTests.swift"
    fixture.write_text(FIXTURE)
    binary = root / "transcript-tests"
    subprocess.run(["swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
                    "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library",
                    str(SOURCE), str(fixture), "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary), str(root)], check=True, timeout=60)
