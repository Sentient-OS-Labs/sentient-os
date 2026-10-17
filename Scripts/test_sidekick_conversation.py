#!/usr/bin/env python3
"""Compile the complete production store and exercise real, temporary SQLite databases.

No app launch, provider calls, production defaults, credentials, or user history. The Swift
fixture uses actual concurrent connections and OS write failures rather than a mock store.
"""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sentient OS macOS/Notch Magic/SidekickConversationStore.swift"

FIXTURE = r'''
import Foundation
import Dispatch
import Darwin
import SQLite3

typealias Store = SidekickConversationStore
typealias Event = SidekickConversationEvent

nonisolated final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func access<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}

nonisolated func sql(_ url: URL, _ command: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let db else { throw NSError(domain: "fixture", code: 1) }
    defer { sqlite3_close_v2(db) }
    guard sqlite3_exec(db, command, nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "fixture", code: 2,
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
}

@main enum ConversationTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { fatalError("FAIL: " + label) }
        checks += 1
    }

    static func fails(_ label: String, _ body: () throws -> Void,
                      matching: (Store.Failure) -> Bool = { _ in true }) throws {
        do { try body() }
        catch let error as Store.Failure {
            try check(matching(error), label + " (expected error case)")
            return
        }
        fatalError("FAIL: " + label + " did not throw a store error")
    }

    static func basic(_ directory: URL) throws {
        let path = directory.appendingPathComponent("basic/history.sqlite")
        let store = try Store(url: path)
        let generation = try store.generation
        try check(try store.latestSequence == 0, "fresh database is empty")
        try check(try store.summary == nil, "fresh database has no summary")
        let observations = Locked((count: 0, failures: 0))
        let observer = NotificationCenter.default.addObserver(forName: .sidekickConversationChanged,
            object: nil, queue: nil) { notification in
                guard (notification.object as? Store) === store else { return }
                // Reentry proves publication happens after commit, outside the store lock.
                do {
                    let latest = try store.latestSequence
                    observations.access { $0.count += 1; if latest < 0 { $0.failures += 1 } }
                } catch { observations.access { $0.failures += 1 } }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        let task = UUID()
        let request = Event(id: "request", taskID: task, kind: .userMessage,
            text: "# Hello, 世界 👩🏽‍💻\n\n- café\n- 100%_done\\today\n\n```swift\nlet x = 1\n```\u{0}tail")
        let initial = try store.appendBatch([
            Event(taskID: task, kind: .taskStarted, text: "A task"), request
        ], expectedGeneration: generation)
        try check(initial.map(\.sequence) == [1, 2], "batch order is stable")
        try check(try store.record(id: request.id)?.event.text == request.text, "exact Markdown/Unicode/NUL roundtrip")
        try check(observations.access { $0.count } == 1, "one notification per committed batch")
        let reply = Event(id: "response", taskID: task, kind: .assistantMessage,
            text: "**Two options**\n\n1. Monday\n2. Tuesday 👩🏽‍💻", priority: .high)
        let original = try store.append(reply, expectedGeneration: generation)
        try check(original.sequence == 3, "monotonic sequences")
        try check(original.event.messageKind == .answer, "assistant defaults to answer")
        let repeated = try store.append(reply, expectedGeneration: generation)
        try check(repeated == original, "identical event retry returns original")
        try check(observations.access { $0.count } == 2, "duplicate emits no new notification")
        let changed = Event(id: reply.id, taskID: task, kind: .assistantMessage,
            text: "changed", createdAt: reply.createdAt)
        try fails("changed duplicate rejected", { _ = try store.append(changed) }) {
            if case .duplicateEvent = $0 { return true }; return false
        }
        try fails("duplicate task start rejected", {
            _ = try store.append(Event(taskID: task, kind: .taskStarted))
        }) { if case .duplicateTaskStart = $0 { return true }; return false }
        try check(try store.unread().map(\.event.id) == [reply.id], "only user-facing incoming content is unread")
        try store.markRead(throughSequence: 3, expectedGeneration: generation)
        try store.markRead(throughSequence: 2, expectedGeneration: generation)
        try check(try store.readThroughSequence == 3, "read watermark never regresses")
        try check(try store.unread().isEmpty, "reading clears known messages")
        try fails("future read watermark rejected", { try store.markRead(throughSequence: 999) }) {
            if case .invalidWatermark = $0 { return true }; return false
        }
        let question = Event(id: "question", taskID: task, kind: .question,
            text: "Which option?", choices: ["Monday", "Tuesday"])
        _ = try store.append(question)
        _ = try store.append(Event(taskID: task, kind: .answer, text: "Tuesday",
            reply: .init(messageID: question.id)))
        let end = Event(id: "end", taskID: task, kind: .taskFinished,
            text: "Stopped by user", outcome: .stopped)
        _ = try store.append(end)
        _ = try store.append(end)
        try fails("late callback cannot append after task terminal", {
            _ = try store.append(Event(taskID: task, kind: .assistantMessage, text: "late"))
        }) { if case .taskAlreadyFinished = $0 { return true }; return false }
        try fails("second terminal cannot rewrite outcome", {
            _ = try store.append(Event(taskID: task, kind: .taskFinished, outcome: .success))
        }) { if case .taskAlreadyFinished = $0 { return true }; return false }
        let followup = Event(taskID: UUID(), kind: .userMessage, text: "Use this one",
            reply: .init(messageID: reply.id, selectedText: "Tuesday 👩🏽‍💻"))
        _ = try store.append(followup)
        try fails("fabricated quote rejected", {
            _ = try store.append(Event(taskID: UUID(), kind: .userMessage, text: "Reply",
                reply: .init(messageID: reply.id, selectedText: "Wednesday")))
        }) { if case .invalidReply = $0 { return true }; return false }
        try fails("missing reply source rejected", {
            _ = try store.append(Event(taskID: UUID(), kind: .userMessage, text: "Reply",
                reply: .init(messageID: "missing")))
        }) { if case .invalidReply = $0 { return true }; return false }
        try check(try store.search("100%_done\\today").count == 1, "search escapes SQL wildcard characters")
        try check(try store.search("☃").isEmpty, "search missing content returns empty")
        try check(try store.search("").isEmpty, "empty search is bounded")
        try check(try store.recent(limit: 2).map(\.sequence) == [6, 7], "recent window remains chronological")
        try check(try store.records(after: 2, limit: 2).map(\.sequence) == [3, 4], "cursor pagination")
        try check(try store.records(taskID: task).count == 6, "task-scoped history")
        try check(try store.records(limit: 0).isEmpty, "empty page is explicit")
        let secondHandle = try Store(url: path)
        try check(try secondHandle.generation == generation, "second handle shares generation")
        try check(try secondHandle.record(id: request.id)?.event == request, "reopen preserves exact events")
        try check(try secondHandle.readThroughSequence == 3, "read watermark persists")
        let recovered = try secondHandle.recoverInterruptedTasks()
        try check(recovered.count == 1 && recovered[0].event.taskID == followup.taskID,
            "recovery closes only unfinished tasks")
        try check(recovered[0].event.outcome == .interrupted, "recovery never invents success or user Stop")
        try check(try store.recoverInterruptedTasks().isEmpty, "recovery is idempotent across handles")
        try check(try store.record(id: question.id)?.event.choices == ["Monday", "Tuesday"], "question choices survive recovery")
        try check(observations.access { $0.failures } == 0, "observers can read committed history")
    }

    static func boundaries(_ directory: URL) throws {
        let store = try Store(url: directory.appendingPathComponent("boundaries.sqlite"))
        let generation = try store.generation
        let first = UUID(), second = UUID()
        _ = try store.appendBatch([
            Event(taskID: first, kind: .taskStarted),
            Event(taskID: first, kind: .userMessage, text: "Old request"),
            Event(taskID: first, kind: .taskFinished, outcome: .success),
            Event(taskID: second, kind: .taskStarted),
            Event(taskID: second, kind: .userMessage, text: "Current request")
        ])
        try fails("summary cannot split completed task", {
            try store.installSummary(generation: generation, throughSequence: 2, text: "Bad prefix")
        }) { if case .incompleteSummaryPrefix = $0 { return true }; return false }
        try fails("summary cannot cover active task", {
            try store.installSummary(generation: generation, throughSequence: 5, text: "Bad prefix")
        }) { if case .incompleteSummaryPrefix = $0 { return true }; return false }
        try store.installSummary(generation: generation, throughSequence: 3, text: "Old request completed; source 1–3.")
        try check(try store.summary?.throughSequence == 3, "completed prefix accepted with active newer tail")
        _ = try store.appendBatch([
            Event(taskID: second, kind: .assistantMessage, text: "Here is the result"),
            Event(taskID: second, kind: .taskFinished, outcome: .success)
        ])
        try check(try store.summary?.throughSequence == 3, "new tail does not invalidate installed summary")
        try fails("higher watermark with stale starting prefix rejected", {
            try store.installSummary(generation: generation, throughSequence: 7, text: "Overlapping old input", expectedFromSequence: 1)
        }) { if case .staleSummary = $0 { return true }; return false }
        try store.installSummary(generation: generation, throughSequence: 7, text: "The second request completed.", expectedFromSequence: 4)
        try store.installSummary(generation: generation, throughSequence: 7, text: "The second request completed.", expectedFromSequence: 4)
        let summaries = try store.summaries()
        try check(summaries.map(\.fromSequence) == [1, 4] && summaries.map(\.throughSequence) == [3, 7],
            "summaries preserve independent source intervals")
        try check(summaries.first?.text == "Old request completed; source 1–3.", "new segments preserve older summary text")
        try check(try store.summaries(limit: 1).first?.fromSequence == 4, "summary window is bounded")
        try check(try Store(url: store.url).summaries() == summaries, "summary segments survive reopen")
        try fails("slow compactor cannot replace newer summary", {
            try store.installSummary(generation: generation, throughSequence: 3, text: "Old")
        }) { if case .staleSummary = $0 { return true }; return false }
        try fails("same-prefix changed summary rejected", {
            try store.installSummary(generation: generation, throughSequence: 7, text: "Conflicting")
        }) { if case .staleSummary = $0 { return true }; return false }
        try fails("future summary rejected", {
            try store.installSummary(generation: generation, throughSequence: 8, text: "Future")
        }) { if case .invalidWatermark = $0 { return true }; return false }
        try check(try store.records().count == 7, "compaction never deletes original conversation")
        let other = try Store(url: store.url)
        try store.reset()
        let newGeneration = try store.generation
        try check(newGeneration != generation, "reset changes generation")
        try check(try store.latestSequence == 0 && store.records().isEmpty, "reset clears events")
        try check(try store.summary == nil && store.readThroughSequence == 0, "reset clears summaries and read state")
        try check(try store.summaries().isEmpty, "reset clears every stored summary segment")
        try fails("stale callback cannot recreate history", {
            _ = try other.append(Event(taskID: UUID(), kind: .userMessage, text: "Late"), expectedGeneration: generation)
        }) { if case .staleGeneration = $0 { return true }; return false }
        _ = try store.append(Event(taskID: UUID(), kind: .userMessage, text: "New request"), expectedGeneration: newGeneration)
        try fails("stale view cannot mark new conversation read", {
            try other.markRead(throughSequence: 1, expectedGeneration: generation)
        }) { if case .staleGeneration = $0 { return true }; return false }
        try fails("stale summary cannot revive deleted content", {
            try other.installSummary(generation: generation, throughSequence: 1, text: "Old")
        }) { if case .staleGeneration = $0 { return true }; return false }
        try check(try other.generation == newGeneration, "all handles observe reset generation")
    }

    static func contextQueries(_ directory: URL) throws {
        let store = try Store(url: directory.appendingPathComponent("context.sqlite"))
        let old = UUID(), current = UUID()
        _ = try store.appendBatch([
            Event(taskID: old, kind: .userMessage, text: "Older request"),
            Event(taskID: old, kind: .assistantMessage, text: "Older answer"),
            Event(taskID: old, kind: .taskFinished, outcome: .success),
            Event(taskID: current, kind: .userMessage, text: "Latest request")
        ])
        for chunk in 0..<3 {
            let events = (0..<800).map { index in
                Event(id: "activity-\(chunk)-\(index)", taskID: current, kind: .activity,
                    activity: .init(toolID: "tool-\(chunk)-\(index)", name: "read", status: .completed))
            }
            _ = try store.appendBatch(events)
        }
        _ = try store.append(Event(taskID: current, kind: .assistantMessage, text: "Latest answer"))
        let recent = try store.contextRecords(taskLimit: 1)
        try check(recent.map(\.event.text) == ["Latest request", "Latest answer"],
            "thousands of activity events cannot crowd out a recent request")
        let prefix = try store.contextRecordsForCompaction(limit: 3)
        try check(prefix.map(\.sequence) == [1, 2, 3], "compaction page filters activity before applying limit")
        try check(try store.contextRecordsForCompaction(after: 3).map(\.event.text) == ["Latest request", "Latest answer"],
            "compaction paging crosses activity-heavy runs")
        try check(try store.compactionBoundary(keepingRecentTasks: 1) == 3,
            "retained current task leaves complete older prefix")
        try check(try store.compactionBoundary(keepingRecentTasks: 0) == 3,
            "unfinished task protects its whole prefix even without recent retention")
        let terminal = try store.append(Event(taskID: current, kind: .taskFinished, outcome: .success))
        try check(try store.compactionBoundary(keepingRecentTasks: 0) == terminal.sequence,
            "all completed tasks may be compacted when retention is zero")
        try check(try store.compactionBoundary(keepingRecentTasks: 2) == nil,
            "retaining all tasks yields no compaction work")
        try check(try store.contextRecords(after: terminal.sequence).isEmpty, "context cursor excludes covered records")

        let interleaved = try Store(url: directory.appendingPathComponent("interleaved.sqlite"))
        let one = UUID(), two = UUID(), three = UUID()
        _ = try interleaved.appendBatch([
            Event(taskID: one, kind: .userMessage, text: "First"),
            Event(taskID: two, kind: .userMessage, text: "Second"),
            Event(taskID: two, kind: .taskFinished, outcome: .success),
            Event(taskID: three, kind: .userMessage, text: "Third"),
            Event(taskID: three, kind: .taskFinished, outcome: .success)
        ])
        try check(try interleaved.compactionBoundary(keepingRecentTasks: 0) == nil,
            "completed later task cannot cover an unfinished earlier task")
        _ = try interleaved.append(Event(taskID: one, kind: .taskFinished, outcome: .success))
        try check(try interleaved.compactionBoundary(keepingRecentTasks: 0) == 6,
            "interleaved tasks compact as one complete interval")
        try check(try interleaved.compactionBoundary(keepingRecentTasks: 1) == nil,
            "retaining latest interleaved task protects its earlier beginning")
    }

    static func closure(_ directory: URL) throws {
        let path = directory.appendingPathComponent("closed.sqlite")
        let store = try Store(url: path)
        _ = try store.append(Event(taskID: UUID(), kind: .userMessage, text: "Before close"))
        let generation = try store.generation
        let results = Locked((accepted: 0, refused: 0, unexpected: 0))
        let group = DispatchGroup()
        for index in 0..<40 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    _ = try store.append(Event(taskID: UUID(), kind: .userMessage, text: "Concurrent \(index)"))
                    results.access { $0.accepted += 1 }
                } catch Store.Failure.closed { results.access { $0.refused += 1 } }
                catch { results.access { $0.unexpected += 1 } }
            }
        }
        store.close(); store.close()
        group.wait()
        let observed = results.access { $0 }
        try check(observed.accepted + observed.refused == 40 && observed.unexpected == 0,
            "close serializes with racing appends without invalid-handle failures")
        let reopened = try Store(url: path)
        try check(try reopened.records(limit: 500).count == observed.accepted + 1, "close preserves every committed append")
        reopened.close()
        let closed: (Store.Failure) -> Bool = { if case .closed = $0 { return true }; return false }
        try fails("closed read rejects", { _ = try store.records() }, matching: closed)
        try fails("closed empty page rejects", { _ = try store.records(limit: 0) }, matching: closed)
        try fails("closed empty search rejects", { _ = try store.search("") }, matching: closed)
        try fails("closed summary read rejects", { _ = try store.summary }, matching: closed)
        try fails("closed empty summary page rejects", { _ = try store.summaries(limit: 0) }, matching: closed)
        try fails("closed unread count rejects", { _ = try store.unreadCount }, matching: closed)
        try fails("closed attention read rejects", { _ = try store.latestUnreadAttention }, matching: closed)
        try fails("closed watermark write rejects", { try store.markRead(throughSequence: 0, expectedGeneration: generation) }, matching: closed)
        try fails("closed reset rejects", { try store.reset() }, matching: closed)
        try fails("closed background install rejects", { try store.installSummary(generation: generation, throughSequence: 1, text: "Late summary") }, matching: closed)
        try FileManager.default.removeItem(at: path)
        try fails("retained handle cannot recreate removed database", {
            _ = try store.append(Event(taskID: UUID(), kind: .userMessage, text: "After unlink"))
        }, matching: closed)
        try check(!FileManager.default.fileExists(atPath: path.path), "closed producer leaves uninstalled file absent")
    }

    static func contextPriority(_ directory: URL) throws {
        let store = try Store(url: directory.appendingPathComponent("context-priority.sqlite"))
        var retainedRequests: [String] = []
        for index in 0..<15 {
            let task = UUID(), request = "Older request \(index)"
            if index > 0 { retainedRequests.append(request) }
            _ = try store.appendBatch([
                Event(taskID: task, kind: .taskStarted, text: request),
                Event(taskID: task, kind: .userMessage, text: request),
                Event(taskID: task, kind: .assistantMessage, text: "Final answer \(index)"),
                Event(taskID: task, kind: .taskFinished, outcome: .success)
            ])
        }
        let newest = UUID()
        retainedRequests.append("Newest request anchor")
        _ = try store.appendBatch([
            Event(taskID: newest, kind: .taskStarted, text: "Newest task"),
            Event(taskID: newest, kind: .userMessage, text: "Newest request anchor")
        ])
        _ = try store.appendBatch((0..<330).map { index in
            Event(taskID: newest, kind: .assistantMessage, text: "Progress \(index)", messageKind: .update)
        })
        let context = try store.contextRecords(taskLimit: 15, limit: 300)
        try check(context.count == 300, "chatty context remains bounded")
        try check(context.filter { $0.event.kind == .userMessage }.map(\.event.text) == retainedRequests,
            "over 300 updates cannot evict recent fifteen user requests")
        try check(context.filter { $0.event.kind == .taskFinished }.count == 14,
            "terminal outcomes survive progress chatter")
        try check(context.filter { $0.event.kind == .assistantMessage && $0.event.messageKind == .answer }.count == 14,
            "final answers survive progress chatter")
        try check(context.map(\.sequence) == context.map(\.sequence).sorted(), "prioritized records return in source chronology")
        try check(try store.contextRecordsForCompaction(limit: 1).first?.event.kind == .taskStarted,
            "compaction still pages exact original prefix without prioritization")
    }

    static func unreadAndActivity(_ directory: URL) throws {
        let store = try Store(url: directory.appendingPathComponent("unread.sqlite"))
        let task = UUID()
        _ = try store.append(Event(taskID: task, kind: .userMessage, text: "A long-running request"))
        _ = try store.appendBatch((0..<501).map { index in
            Event(taskID: task, kind: .assistantMessage, text: "Quiet update \(index)", messageKind: .update)
        })
        try check(try store.unreadCount == 501, "unread count is independent of page limit")
        try check(try store.latestUnreadAttention == nil, "quiet updates alone do not request attention")
        let latest = try store.append(Event(id: "latest-answer", taskID: task, kind: .assistantMessage, text: "The newest answer"))
        try check(try store.unreadCount == 502, "new answer counted beyond first 500 unread records")
        try check(try store.latestUnreadAttention?.event.id == latest.event.id, "new answer beyond first unread page receives attention")
        let important = try store.append(Event(id: "important-update", taskID: task, kind: .assistantMessage,
            text: "Important update", messageKind: .update, priority: .high))
        _ = try store.append(Event(taskID: task, kind: .assistantMessage, text: "Later quiet update", messageKind: .update))
        try check(try store.latestUnreadAttention?.event.id == important.event.id, "attention filters priority before selecting newest message")
        try store.markRead(throughSequence: important.sequence, expectedGeneration: store.generation)
        try check(try store.unreadCount == 1 && store.latestUnreadAttention == nil, "read watermark clears known attention without swallowing later quiet updates")
        let question = Event(id: "pending-question", taskID: task, kind: .question, text: "Which account?", choices: ["First", "Second"])
        _ = try store.append(question)
        try check(try store.latestUnreadAttention?.event.id == question.id && store.unreadCount == 2, "pending question requests attention")
        _ = try store.append(Event(taskID: task, kind: .answer, text: "First", reply: .init(messageID: question.id)))
        try check(try store.latestUnreadAttention == nil && store.unreadCount == 1, "answered question no longer requests attention")
        let stoppedQuestion = Event(id: "stopped-question", taskID: task, kind: .question, text: "Continue?", priority: .high, choices: ["Yes", "No"])
        _ = try store.append(stoppedQuestion)
        _ = try store.append(Event(taskID: task, kind: .taskFinished, outcome: .stopped))
        try check(try store.latestUnreadAttention == nil && store.unreadCount == 1, "Stop removes dead question attention")
        try check(try store.record(id: stoppedQuestion.id) != nil && store.record(id: question.id) != nil, "resolved questions remain exact history")
        let abandoned = UUID()
        _ = try store.append(Event(taskID: abandoned, kind: .question, text: "Sign in first", priority: .high, choices: ["Done", "Stop"]))
        try check(try store.latestUnreadAttention?.event.taskID == abandoned, "new pending question is actionable")
        _ = try store.recoverInterruptedTasks()
        try check(try store.latestUnreadAttention == nil, "restart interruption cannot revive an old question")

        let active = UUID()
        _ = try store.appendBatch((0..<225).map { index in
            Event(taskID: active, kind: .assistantMessage, text: "Progress before tools \(index)", messageKind: .update)
        })
        let tools = try store.appendBatch((0..<2).map { index in
            Event(id: "late-tool-\(index)", taskID: active, kind: .activity,
                activity: .init(toolID: "late-\(index)", name: "fixture", status: .completed))
        })
        let page = try store.activityRecords(taskID: active, limit: 1)
        try check(page.map(\.event.id) == [tools[0].event.id], "activity filters before mixed-record page limit")
        let next = try store.activityRecords(taskID: active, after: page[0].sequence, limit: 1)
        try check(next.map(\.event.id) == [tools[1].event.id], "activity cursor pages exact later operations")
        try check(try store.activityRecords(taskID: active, after: next[0].sequence).isEmpty, "activity cursor finishes only after last operation")
        try check(try store.activityRecords(taskID: task).isEmpty && store.activityRecords(taskID: active, limit: 0).isEmpty,
            "activity query respects task and empty-page bounds")
    }

    static func migration(_ directory: URL) throws {
        let store = try Store(url: directory.appendingPathComponent("migration.sqlite"))
        let task = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Event(id: "old-request", taskID: task, kind: .userMessage,
            text: "Original legacy request", createdAt: date)
        let conflict = Event(id: "old-request", taskID: task, kind: .userMessage,
            text: "Conflicting entry", createdAt: date)
        try fails("interrupted import rolls back the whole batch", { _ = try store.importLegacy(events: [first, conflict]) }) {
            if case .duplicateEvent = $0 { return true }; return false
        }
        try check(try store.records().isEmpty, "failed import leaves no partial entries")
        let events = [first, Event(taskID: task, kind: .taskFinished,
            text: "Legacy answer unavailable", outcome: .interrupted)]
        try check(try store.importLegacy(events: events), "retry imports after rollback")
        let reopened = try Store(url: store.url)
        try check(try !reopened.importLegacy(events: events), "import marker survives reopen")
        try check(try reopened.records().count == 2, "legacy imports exactly once")
        try store.reset()
        try check(try !reopened.importLegacy(events: events), "stale legacy data cannot return after reset")
        try check(try reopened.records().isEmpty, "reset stays empty after attempted reimport")

        let atomic = try Store(url: directory.appendingPathComponent("batch.sqlite"))
        try fails("ordinary append batch is atomic", { _ = try atomic.appendBatch([first, conflict]) }) {
            if case .duplicateEvent = $0 { return true }; return false
        }
        try check(try atomic.latestSequence == 0, "batch failure rolls back sequence allocation")
        try check(try atomic.recoverInterruptedTasks().isEmpty, "batch failure leaves no ghost task")
    }

    static func concurrency(_ directory: URL) throws {
        let path = directory.appendingPathComponent("concurrent.sqlite")
        let handles = try (0..<4).map { _ in try Store(url: path) }
        let errors = Locked<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 80) { index in
            do {
                let task = UUID()
                _ = try handles[index % 4].appendBatch([
                    Event(id: "request-\(index)", taskID: task, kind: .userMessage, text: "Request \(index)"),
                    Event(taskID: task, kind: .taskFinished, outcome: .success)
                ])
            } catch { errors.access { $0.append(String(describing: error)) } }
        }
        try check(errors.access { $0.isEmpty }, "concurrent handles append without lost writes")
        let rows = try handles[0].records(limit: 500)
        try check(rows.count == 160, "all concurrent events retained")
        try check(rows.map(\.sequence) == Array(1...160).map(Int64.init), "concurrent sequence order unique and contiguous")
        try check(stride(from: 0, to: 160, by: 2).allSatisfy { rows[$0].event.taskID == rows[$0+1].event.taskID },
            "concurrent batches cannot interleave")
        let same = Event(id: "same-retry", taskID: UUID(), kind: .userMessage, text: "Exactly once")
        let delivered = Locked<[Int64]>([])
        DispatchQueue.concurrentPerform(iterations: 30) { index in
            do { let record = try handles[index % 4].append(same); delivered.access { $0.append(record.sequence) } }
            catch { errors.access { $0.append(String(describing: error)) } }
        }
        try check(errors.access { $0.isEmpty }, "concurrent delivery retries succeed")
        try check(delivered.access { $0.count == 30 && Set($0).count == 1 }, "all retry callers receive same committed event")
        let endings = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 30) { index in
            do {
                _ = try handles[index % 4].append(Event(taskID: same.taskID, kind: .taskFinished, outcome: .success))
                endings.access { $0 += 1 }
            } catch Store.Failure.taskAlreadyFinished { }
            catch { errors.access { $0.append(String(describing: error)) } }
        }
        try check(endings.access { $0 } == 1, "exactly one concurrent terminal wins")
        try check(errors.access { $0.isEmpty }, "terminal race has only expected rejections")
        try check(try handles[0].records(taskID: same.taskID).count == 2, "terminal race leaves two honest records")

        let simultaneousPath = directory.appendingPathComponent("simultaneous/history.sqlite")
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                let opened = try Store(url: simultaneousPath)
                _ = try opened.append(Event(taskID: UUID(), kind: .userMessage, text: "Concurrent initialization"))
            } catch { errors.access { $0.append(String(describing: error)) } }
        }
        try check(errors.access { $0.isEmpty }, "simultaneous creation serializes schema setup")
        try check(try Store(url: simultaneousPath).records().count == 8, "simultaneous open preserves all commits")

        let racePath = directory.appendingPathComponent("reset-race.sqlite")
        let resetter = try Store(url: racePath), writer = try Store(url: racePath)
        for _ in 0..<30 {
            let staleGeneration = try writer.generation
            DispatchQueue.concurrentPerform(iterations: 2) { operation in
                do {
                    if operation == 0 { try resetter.reset() }
                    else {
                        _ = try writer.append(Event(taskID: UUID(), kind: .userMessage, text: "Before reset"),
                            expectedGeneration: staleGeneration)
                    }
                } catch Store.Failure.staleGeneration { }
                catch { errors.access { $0.append(String(describing: error)) } }
            }
            // If append wins, reset deletes it; if reset wins, the stale writer is rejected.
            try check(try writer.records().isEmpty, "racing reset cannot leave an old-generation message")
        }
        try check(errors.access { $0.isEmpty }, "reset/write races produce only expected generation rejections")

        let importPath = directory.appendingPathComponent("import-race.sqlite")
        let importers = try [Store(url: importPath), Store(url: importPath)]
        let legacyTask = UUID()
        let legacyEvents = [Event(id: "legacy-once", taskID: legacyTask, kind: .userMessage, text: "Old"),
            Event(id: "legacy-finish", taskID: legacyTask, kind: .taskFinished, outcome: .interrupted)]
        let imports = Locked<[Bool]>([])
        DispatchQueue.concurrentPerform(iterations: 2) { operation in
            do { let imported = try importers[operation].importLegacy(events: legacyEvents); imports.access { $0.append(imported) } }
            catch { errors.access { $0.append(String(describing: error)) } }
        }
        try check(imports.access { $0.filter { $0 }.count == 1 && $0.count == 2 }, "concurrent legacy migration commits once")
        try check(try importers[0].records().count == 2, "concurrent legacy migration has no duplicate entries")
        try check(errors.access { $0.isEmpty }, "concurrent migration completes without errors")
    }

    static func failures(_ directory: URL) throws {
        let store = try Store(url: directory.appendingPathComponent("failures.sqlite"))
        let baseline = Event(taskID: UUID(), kind: .userMessage, text: "Keep this committed entry")
        _ = try store.append(baseline)
        let notices = Locked(0)
        let observer = NotificationCenter.default.addObserver(forName: .sidekickConversationChanged,
            object: nil, queue: nil) { note in
                if (note.object as? Store) === store { notices.access { $0 += 1 } }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        try sql(store.url, "CREATE TRIGGER deny_fixture BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'fixture write failure'); END;")
        try fails("database write failure is propagated", {
            _ = try store.append(Event(taskID: UUID(), kind: .userMessage, text: "Must not appear"))
        }) { if case .database = $0 { return true }; return false }
        try check(notices.access { $0 } == 0, "failed write never announces message delivery")
        try check(try store.latestSequence == 1, "failed write preserves prior commit")
        try sql(store.url, "DROP TRIGGER deny_fixture;")
        _ = try store.append(Event(taskID: baseline.taskID, kind: .taskFinished, outcome: .failed))
        try check(try store.latestSequence == 2, "connection remains usable after write failure")
        try fails("oversized assistant body rejected", {
            _ = try store.append(Event(taskID: UUID(), kind: .assistantMessage,
                text: String(repeating: "é", count: Store.maximumMessageBytes)))
        }) { if case .invalidEvent = $0 { return true }; return false }
        try fails("oversized tool output rejected", {
            _ = try store.append(Event(taskID: UUID(), kind: .activity,
                activity: .init(toolID: "x", name: "tool", result: String(repeating: "x", count: Store.maximumActivityTextBytes + 1), status: .completed)))
        }) { if case .invalidEvent = $0 { return true }; return false }
        try fails("terminal without outcome rejected", { _ = try store.append(Event(taskID: UUID(), kind: .taskFinished)) }) {
            if case .invalidEvent = $0 { return true }; return false
        }
        try fails("wrong payload shape rejected", {
            _ = try store.append(Event(taskID: UUID(), kind: .userMessage, text: "x", outcome: .success))
        }) { if case .invalidEvent = $0 { return true }; return false }

        let corrupt = directory.appendingPathComponent("corrupt.sqlite")
        let bytes = Data("not a sqlite database, preserve me".utf8)
        try bytes.write(to: corrupt)
        try fails("corrupt database rejected without reset", { _ = try Store(url: corrupt) })
        try check(try Data(contentsOf: corrupt) == bytes, "corrupt source bytes are preserved")
        let unknown = directory.appendingPathComponent("unknown.sqlite")
        try sql(unknown, "CREATE TABLE other(value TEXT); INSERT INTO other VALUES('preserve');")
        let unknownBytes = try Data(contentsOf: unknown)
        try fails("unrecognized unversioned database rejected", { _ = try Store(url: unknown) }) {
            if case .invalidSchema = $0 { return true }; return false
        }
        try check(try Data(contentsOf: unknown) == unknownBytes, "unrecognized database preserved")
        let newer = directory.appendingPathComponent("newer.sqlite")
        try sql(newer, "PRAGMA user_version = 99; CREATE TABLE future(value TEXT);")
        let newerBytes = try Data(contentsOf: newer)
        try fails("newer schema rejected", { _ = try Store(url: newer) }) {
            if case .unsupportedSchema(99) = $0 { return true }; return false
        }
        try check(try Data(contentsOf: newer) == newerBytes, "newer schema untouched")
        try sql(store.url, "UPDATE events SET payload = X'7B' WHERE sequence = 1;")
        try fails("malformed payload is not an empty history", { _ = try store.records() }) {
            if case .corruptPayload = $0 { return true }; return false
        }

        let readonly = directory.appendingPathComponent("readonly/history.sqlite")
        try makeReadonlyFixture(readonly)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readonly.deletingLastPathComponent().path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readonly.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readonly.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readonly.deletingLastPathComponent().path)
        try fails("read-only storage fails honestly", {
            let readonlyStore = try Store(url: readonly)
            _ = try readonlyStore.append(Event(taskID: UUID(), kind: .userMessage, text: "Must not save"))
        }) {
            if case .database = $0 { return true }; return false
        }
        let mode = try FileManager.default.attributesOfItem(atPath: readonly.path)[.posixPermissions] as? NSNumber
        try check(mode?.intValue == 0o444, "store does not silently make read-only user files writable")
    }

    static func makeReadonlyFixture(_ url: URL) throws {
        let store = try Store(url: url)
        _ = try store.append(Event(taskID: UUID(), kind: .userMessage, text: "Read-only committed data"))
    }

    static func diskFailure(_ directory: URL) throws {
        let path = directory.appendingPathComponent("limited.sqlite")
        let store = try Store(url: path)
        _ = try store.append(Event(taskID: UUID(), kind: .userMessage, text: "Before file-size quota"))
        let notices = Locked(0)
        let observer = NotificationCenter.default.addObserver(forName: .sidekickConversationChanged,
            object: nil, queue: nil) { note in
                if (note.object as? Store) === store { notices.access { $0 += 1 } }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        var original = rlimit()
        guard getrlimit(RLIMIT_FSIZE, &original) == 0 else { fatalError("getrlimit") }
        let oldSignal = signal(SIGXFSZ, SIG_IGN)
        defer { signal(SIGXFSZ, oldSignal); _ = setrlimit(RLIMIT_FSIZE, &original) }
        var limited = rlimit(rlim_cur: 4_096, rlim_max: original.rlim_max)
        guard setrlimit(RLIMIT_FSIZE, &limited) == 0 else { fatalError("setrlimit") }
        try fails("real OS write quota failure propagated", {
            _ = try store.append(Event(taskID: UUID(), kind: .assistantMessage,
                text: String(repeating: "large result ", count: 10_000)))
        }) { if case .database = $0 { return true }; return false }
        _ = setrlimit(RLIMIT_FSIZE, &original)
        try check(notices.access { $0 } == 0, "quota failure emits no committed change")
        try check(try store.latestSequence == 1, "quota failure rolls back pending message")
        let reopened = try Store(url: path)
        try check(try reopened.records().map(\.event.text) == ["Before file-size quota"], "prior durable data survives quota failure and reopen")
    }

    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let mode = CommandLine.arguments[1]
        if mode == "crash" {
            let store = try Store(url: directory.appendingPathComponent("crash.sqlite"))
            _ = try store.append(Event(id: "durable-before-crash", taskID: UUID(), kind: .userMessage, text: "Committed before abrupt process exit"))
            _exit(17) // no deinit, SQLite close, or graceful application shutdown
        }
        if mode == "verify-crash" {
            let store = try Store(url: directory.appendingPathComponent("crash.sqlite"))
            try check(try store.record(id: "durable-before-crash") != nil, "commit survives abrupt process exit")
            let recovered = try store.recoverInterruptedTasks()
            try check(recovered.count == 1 && recovered[0].event.outcome == .interrupted, "restart honestly records interruption")
            try check(try store.recoverInterruptedTasks().isEmpty, "restart recovery does not repeat")
        } else if mode == "quota" { try diskFailure(directory) }
        else {
            try basic(directory)
            try boundaries(directory)
            try contextQueries(directory)
            try contextPriority(directory)
            try closure(directory)
            try unreadAndActivity(directory)
            try migration(directory)
            try concurrency(directory)
            try failures(directory)
        }
        print("PASS: \(checks) Sidekick conversation \(mode) checks")
    }
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sentient-conversation-test-") as temporary:
        directory = Path(temporary)
        fixture = directory / "ConversationTests.swift"
        fixture.write_text(FIXTURE)
        executable = directory / "conversation-tests"
        subprocess.run([
            "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
            "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library",
            str(SOURCE), str(fixture), "-o", str(executable),
        ], check=True, timeout=60)
        for mode in ("standard", "quota", "crash", "verify-crash"):
            result = subprocess.run([str(executable), mode, str(directory)], timeout=60)
            expected = 17 if mode == "crash" else 0
            if result.returncode != expected:
                raise RuntimeError(f"{mode} exited {result.returncode}; expected {expected}")


if __name__ == "__main__":
    main()
