#!/usr/bin/env python3
"""Compile full production context/compaction/store with deterministic model-free fixtures.
Only temporary SQLite/files and inert diagnostics are used. No CLI, credentials or network.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"
SUPPORT = r'''
import Foundation
import Synchronization
nonisolated enum ModelBackend: String, Sendable, CaseIterable {
    case chatgpt, claude, custom
    @TaskLocal static var runOverride: Self?
    static var current: Self { runOverride ?? .chatgpt }
}
nonisolated enum CodexCLI {
    enum Model: Sendable { case gpt6sol }
    enum Effort: Sendable { case low }
    enum Sandbox: Sendable { case readOnly }
    struct Invocation: Sendable {
        var prompt: String
        var model: Model = .gpt6sol
        var effort: Effort = .low
        var sandbox: Sandbox = .readOnly
        var toolsDisabled = false, webSearch = true, includeUserConfig = true
        var outputSchema: String?
        var timeout: TimeInterval = 3600
        var feature = "unknown"
        var mcpActionServer: String?
        var mcpReadConnectors: [String] = []
        var bypassApprovals = false
        var resumeSessionID: String?
    }
    struct Envelope { let jsonResult: String }
}
nonisolated enum FrontierRun {
    static func run(_ invocation: CodexCLI.Invocation) async throws -> CodexCLI.Envelope {
        fatalError("Tests must not invoke real model execution")
    }
}
nonisolated enum SidekickInteraction { @TaskLocal static var current: String? }
nonisolated enum SidekickToolServer { @TaskLocal static var connection: String? }
nonisolated enum ResearchToolServer { @TaskLocal static var connection: String? }
nonisolated enum DirectMCPRuntime { @TaskLocal static var current: [String] = [] }
nonisolated enum SidekickDiagnostics {
    enum Stage { case compaction }
    enum Outcome { case completed, started, skipped }
    enum Reason { case budgetExceeded, none, staleGeneration, sourceChanged, cancelled }
    enum Backend: String { case chatgpt, claude, custom, unknown }
    enum Source { case compactor }
    enum Count: Hashable { case events, coveredSequence, bytes, migratedTasks }
    static func event(_ stage: Stage, outcome: Outcome = .completed, reason: Reason = .none,
                      backend: Backend = .unknown, source: Source = .compactor,
                      counts: [Count:Int] = [:], duration: TimeInterval? = nil) { }
}
nonisolated final class ValueBox<T: Sendable>: Sendable {
    private let storage: Mutex<T>
    init(_ initial: T) { storage = Mutex(initial) }
    func get() -> T { storage.withLock { $0 } }
    func set(_ value: T) { storage.withLock { $0 = value } }
}
actor Barrier {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func enter() async {
        started = true
        let waiters = startWaiters; startWaiters.removeAll(); waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
'''
TESTS = r'''
import Foundation

@main @MainActor struct Tests {
    typealias Store = SidekickConversationStore
    typealias Event = SidekickConversationEvent
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { fatalError(label) }; checks += 1
    }
    static func body(_ context: SidekickContext.Snapshot) throws -> [String: Any] {
        let start = context.prompt.firstIndex(of: "{")!
        return try JSONSerialization.jsonObject(with: Data(context.prompt[start...].utf8)) as! [String:Any]
    }
    static func record(_ event: Event, _ sequence: Int64) -> Store.Record { .init(sequence: sequence, event: event) }
    static func seed(_ root: URL, name: String, count: Int = 20) throws -> Store {
        let store = try Store(url: root.appendingPathComponent(name + ".sqlite"))
        for i in 0..<count {
            let id = UUID()
            _ = try store.appendBatch([
                Event(taskID: id, kind: .taskStarted, text: "RAW_START_CONTEXT_SENTINEL"),
                Event(id: "request-\(name)-\(i)", taskID: id, kind: .userMessage, text: "Question \(i)"),
                Event(taskID: id, kind: .activity, text: "RAW_TOOL_CONTEXT_SENTINEL", activity: .init(toolID: UUID().uuidString,
                    name: "fixture", arguments: "RAW_ARGUMENT_SENTINEL", result: "RAW_RESULT_SENTINEL", status: .completed)),
                Event(id: "answer-\(name)-\(i)", taskID: id, kind: .assistantMessage, text: "Answer \(i): **exact** café 👩🏽‍💻"),
                Event(taskID: id, kind: .taskFinished, text: "Finished", outcome: i == 2 ? .stopped : .success)
            ])
        }
        return store
    }
    static func legacyTask(_ id: UUID = UUID(), request: String = "Read the café 👩🏽‍💻 note.",
                           outcome: Event.Outcome = .failed, status: String = "App unavailable",
                           blocker: String? = "Last reported blocker: fixture app was closed.",
                           at: Date = Date(timeIntervalSinceReferenceDate: 721692800)) -> [Event] {
        var result = [
            Event(id: "legacy-start:\(id)", taskID: id, kind: .taskStarted, text: request, createdAt: at, source: "command"),
            Event(id: "legacy-request:\(id)", taskID: id, kind: .userMessage, text: request, createdAt: at, source: "command")
        ]
        if let blocker { result.append(Event(taskID: id, kind: .checkpoint, text: blocker, createdAt: at)) }
        result.append(Event(id: "legacy-end:\(id)", taskID: id, kind: .taskFinished, text: status, createdAt: at, outcome: outcome))
        return result
    }
    static func appendRichTasks(_ count: Int, to store: Store, label: String) throws {
        for i in 0..<count {
            let id = UUID()
            _ = try store.appendBatch([
                Event(taskID: id, kind: .taskStarted, text: "RAW_RICH_START"),
                Event(id: "rich-request-\(label)-\(i)", taskID: id, kind: .userMessage, text: "RICH_REQUEST_\(label)_\(i)"),
                Event(id: "rich-answer-\(label)-\(i)", taskID: id, kind: .assistantMessage, text: "RICH_ANSWER_\(label)_\(i)"),
                Event(taskID: id, kind: .taskFinished, text: "Finished", outcome: .success)
            ])
        }
    }
    static func legacyRecords(_ events: [Event], after: Int64 = 0) -> [Store.Record] {
        events.enumerated().map { record($0.element, after + Int64($0.offset) + 1) }
    }
    static func legacyBody(_ text: String) throws -> [[String: Any]] {
        guard let marker = text.range(of: "RECORDS:\n") else { fatalError("legacy summary lacks typed record section") }
        return try JSONSerialization.jsonObject(with: Data(text[marker.upperBound...].utf8)) as! [[String: Any]]
    }
    static func testLegacySummaryBounds() throws {
        let unicode = String(repeating: "\"\\\n\t café 👩🏽‍💻 e\u{301} 🇮🇳 ", count: 2_000)
        let first = legacyRecords(legacyTask(request: unicode, status: "Uncertain \"status\"\\\n", blocker: unicode))
        let second = legacyRecords(legacyTask(request: "Second legacy request", outcome: .stopped), after: Int64(first.count))
        let combined = first + second
        let original = combined
        var fittedBudget: Int?
        for budget in [0, 1, 128, 512, 1_024, 2_048, 4_096, 10_000] {
            switch SidekickContext.legacySummary(records: first, byteBudget: budget) {
            case .notApplicable: fatalError("genuine legacy records not recognized")
            case .cannotFit:
                try check(budget < 4_096, "reasonable metadata budget unexpectedly refused all legacy context")
            case .extracted(let through, let text):
                fittedBudget = budget
                let values = try legacyBody(text)
                try check(through == first.last!.sequence && values.count == first.count,
                          "bounded legacy ledger claimed only part of a task")
                try check(text.utf8.count <= budget, "legacy encoded JSON/Unicode escaped byte budget exceeded")
                try check(text.contains("are unconfirmed") && text.contains("not proof that")
                            && text.contains("Do not infer that nothing was read"),
                          "legacy ledger omitted its evidence/uncertainty contract")
                try check(values.map { $0["id"] as! String } == first.map(\.event.id), "legacy metadata IDs were shortened or dropped")
                try check(values.map { $0["kind"] as! String } == first.map { $0.event.kind.rawValue },
                          "legacy start/request/blocker/outcome record kinds lost")
                for (source, value) in zip(first, values) {
                    let copied = value["text"] as! String
                    try check(source.event.text.hasPrefix(copied) && (copied.isEmpty || String(source.event.text.prefix(copied.count)) == copied),
                              "legacy extraction paraphrased a fact or split a grapheme")
                    try check(value["truncated"] as? Bool == (copied != source.event.text),
                              "legacy incomplete source did not carry accurate truncation metadata")
                    try check(value["task"] as? String == source.event.taskID.uuidString
                                && value["sequence"] as? Int64 == source.sequence
                                && value["at"] as? String == source.event.createdAt.ISO8601Format(),
                              "legacy extraction fabricated task, sequence, or timestamp metadata")
                }
                try check(values.last?["outcome"] as? String == "failed", "typed terminal status was lost")
                try check(values.contains { $0["truncated"] as? Bool == true }, "oversized legacy text silently appeared complete")
                try check(!text.contains("note was not read"), "extractive legacy path invented a negative effect")
            }
        }
        try check(fittedBudget != nil, "bounded legacy record never produced usable context")
        // Find the exact first-task metadata floor. One byte less must reject the entire
        // task; an additional task cannot be claimed simply by omitting some of its IDs.
        var low = 0, high = 10_000
        while low < high {
            let middle = low + (high - low) / 2
            if case .extracted = SidekickContext.legacySummary(records: first, byteBudget: middle) { high = middle }
            else { low = middle + 1 }
        }
        if case .cannotFit = SidekickContext.legacySummary(records: first, byteBudget: low - 1) { checks += 1 }
        else { fatalError("legacy metadata overflow was not distinguished from nonlegacy input") }
        guard case .extracted(let through, let text) = SidekickContext.legacySummary(records: combined, byteBudget: low) else {
            fatalError("first task was lost because a following task exceeded the budget")
        }
        try check(through == first.last!.sequence && (try legacyBody(text)).count == first.count,
                  "metadata budget split or skipped a whole legacy task")
        let short = legacyRecords(legacyTask(request: "Literal \"quote\" and \\ slash\n café 👩🏽‍💻", blocker: nil))
        guard case .extracted(let shortThrough, let exactText) = SidekickContext.legacySummary(records: short) else {
            fatalError("short legacy record was not extracted")
        }
        let exact = try legacyBody(exactText)
        try check(shortThrough == short.last!.sequence && exact.map { $0["text"] as! String } == short.map(\.event.text)
                    && exact.allSatisfy { $0["truncated"] as? Bool == false }, "fitting escaped legacy sources were not copied verbatim")
        try check(combined == original, "legacy summary mutated supplied original records")

        let normal = legacyTask(blocker: nil)
        func renamed(_ index: Int, _ id: String) -> [Store.Record] {
            var values = normal
            let old = values[index]
            values[index] = Event(id: id, taskID: old.taskID, kind: old.kind, text: old.text,
                createdAt: old.createdAt, source: old.source, outcome: old.outcome)
            return legacyRecords(values)
        }
        let wrong = UUID()
        let invalidGroups: [[Store.Record]] = [
            [], legacyRecords(Array(normal.dropFirst())), legacyRecords(Array(normal.dropLast())),
            legacyRecords([normal[0], normal[2]]),
            renamed(0, "start:\(normal[0].taskID)"), renamed(1, "legacy-request:\(wrong)"), renamed(2, "legacy-end:\(wrong)"),
            renamed(0, "legacy-start:looks-legacy-but-is-not-the-task"),
            legacyRecords([normal[0], normal[1], Event(taskID: normal[0].taskID, kind: .assistantMessage, text: "Actual rich answer"), normal[2]])
        ]
        for invalid in invalidGroups {
            if case .notApplicable = SidekickContext.legacySummary(records: invalid) { checks += 1 }
            else { fatalError("missing/wrong legacy identity or rich conversation classified as migrated-only") }
        }
        let richFirst = renamed(0, "real-start")
        if case .notApplicable = SidekickContext.legacySummary(records: richFirst + second) { checks += 1 }
        else { fatalError("legacy extractor skipped an earlier nonlegacy task") }
        let splitTask = legacyRecords(normal)
            + legacyRecords([Event(taskID: normal[0].taskID, kind: .assistantMessage, text: "Later actual evidence")], after: 3)
        if case .notApplicable = SidekickContext.legacySummary(records: splitTask) { checks += 1 }
        else { fatalError("apparently complete legacy slice hid later richer evidence for the same task") }
        let laterRich = renamed(0, "real-start").enumerated().map { record($0.element.event, Int64(short.count + $0.offset + 1)) }
        guard case .extracted(let shortPrefix, _) = SidekickContext.legacySummary(records: short + laterRich) else {
            fatalError("leading legacy task was lost before rich records")
        }
        try check(shortPrefix == short.last!.sequence, "legacy extraction advanced into a nonlegacy task")
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-context-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try testLegacySummaryBounds()
        let store = try seed(root, name: "context")
        let records = try store.contextRecords(taskLimit: 30, limit: 500)
        let context = SidekickContext.build(records: records, summaries: [])
        try check(context.bytes <= 72_000 && context.bytes == context.prompt.utf8.count, "actual encoded context budget")
        try check(!context.prompt.contains("RAW_TOOL_CONTEXT_SENTINEL") && !context.prompt.contains("RAW_START_CONTEXT_SENTINEL"), "no activity or start payload in context")
        try check(!context.prompt.contains("RAW_ARGUMENT_SENTINEL") && !context.prompt.contains("RAW_RESULT_SENTINEL"), "no raw tool argument/result context even for latest task")
        try check(context.prompt.contains("café 👩🏽‍💻") && context.prompt.contains("stopped"), "exact Unicode answers and stopped outcomes preserved")
        let parsed = try body(context)
        let messages = parsed["recentExchanges"] as! [[String: Any]]
        try check(messages.count == 60, "short complete exchanges can retain more than fifteen tasks")
        try check(messages.first?["text"] as? String == "Question 0", "chronological context")
        try check((messages.first?["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } != nil, "historical relative dates have readable source timestamps")
        try check(messages.allSatisfy { $0["truncated"] as? Bool == false }, "fitting messages remain exact")

        let task = UUID()
        let question = Event(id: "question", taskID: task, kind: .question, text: "Which option?", choices: ["First: café", "Second: 👩🏽‍💻"])
        let paired = [record(Event(taskID: task, kind: .userMessage, text: "Pick a time"), 1), record(question, 2),
            record(Event(taskID: task, kind: .answer, text: "Second", reply: .init(messageID: "question")), 3),
            record(Event(taskID: task, kind: .assistantMessage, text: "Selected the second option"), 4)]
        let pairedBody = try body(SidekickContext.build(records: paired, summaries: []))
        let pairedMessages = pairedBody["recentExchanges"] as! [[String:Any]]
        try check(pairedMessages[1]["choices"] as? [String] == question.choices, "question choices retained with answers")
        try check(pairedMessages[2]["replyTo"] as? String == "question", "answer retains exact question reference")

        let huge = String(repeating: "\"\\\n👩🏽‍💻", count: 20_000)
        let giantRecords = [record(Event(id: "huge-request", taskID: task, kind: .userMessage, text: "Please revise this answer"), 1),
            record(Event(id: "huge-answer", taskID: task, kind: .assistantMessage, text: huge), 2)]
        for budget in [0, 1, 512, 2_048, 4_096, 12_000, 72_000] {
            let result = SidekickContext.build(records: giantRecords, summaries: [], byteBudget: budget)
            try check(result.bytes <= budget, "escaping/Unicode overhead never exceeds requested budget")
            if budget >= 2_048 {
                try check(result.includedMessages == 2, "oversized newest answer does not erase its request or entire history")
                let values = try body(result)["recentExchanges"] as! [[String:Any]]
                try check(values[1]["truncated"] as? Bool == true && !(values[1]["text"] as! String).isEmpty, "oversized answer explicitly shortened with usable text")
                try check(huge.hasPrefix(values[1]["text"] as! String), "truncated text stays an exact Unicode prefix")
            }
        }
        let referenced = record(Event(id: "quoted", taskID: UUID(), kind: .assistantMessage, text: "first\nsecond\nthird"), 1)
        let replyContext = SidekickContext.build(records: records, summaries: [], reply: referenced, selectedText: "second")
        let reply = try body(replyContext)["replyReference"] as! [String:Any]
        try check(reply["messageID"] as? String == "quoted" && reply["quote"] as? String == "second", "selected quote is exact and source-linked")
        let longReply = SidekickContext.build(records: records, summaries: [], reply: giantRecords[1], byteBudget: 4_096)
        try check(longReply.bytes <= 4_096, "large quoted reference respects encoded budget")
        try check((try body(longReply)["replyReference"] as? [String:Any])?["truncated"] as? Bool == true, "long reference is explicitly incomplete")

        guard let prompt = SidekickContext.compactionPrompt(records: records, byteBudget: 12_000) else { fatalError("compact prompt missing") }
        try check(prompt.utf8.count <= 12_000, "compaction prompt is encoded-budgeted")
        try check(!prompt.contains("RAW_TOOL_CONTEXT_SENTINEL") && !prompt.contains("RAW_START_CONTEXT_SENTINEL"), "compactor never receives raw activity/start data")
        try check(prompt.contains("source message IDs") && prompt.contains("untrusted DATA"), "compactor source/authorization contract")
        try check(SidekickContext.compactionPrompt(records: records, byteBudget: 1) == nil, "too-small compaction budget refuses safely")
        for invalid in ["bad JSON", "{}", "{\"summary\":\" \"}", "{\"summary\":3}", "{\"summary\":\"ok\",\"command\":\"run\"}",
                        SidekickContext.json(["summary": String(repeating: "x", count: 10_001)])] {
            do { _ = try SidekickCompactor.validatedSummary(invalid); fatalError("invalid summary accepted") }
            catch is SidekickCompactor.Failure { checks += 1 }
        }

        for backend in ModelBackend.allCases {
            let fresh = try seed(root, name: backend.rawValue)
            let invoked = ValueBox(false)
            try await ModelBackend.$runOverride.withValue(backend) {
                try await SidekickInteraction.$current.withValue("foreground") {
                    try await SidekickToolServer.$connection.withValue("foreground-tools") {
                        try await ResearchToolServer.$connection.withValue("research-tools") {
                            try await DirectMCPRuntime.$current.withValue(["action-account"]) {
                                try await SidekickCompactor.compactIfNeeded(store: fresh) { invocation in
                                    guard SidekickInteraction.current == nil, SidekickToolServer.connection == nil,
                                          ResearchToolServer.connection == nil, DirectMCPRuntime.current.isEmpty,
                                          ModelBackend.current == backend else { fatalError("foreground capabilities inherited") }
                                    guard invocation.toolsDisabled, !invocation.webSearch, !invocation.includeUserConfig,
                                          !invocation.bypassApprovals, invocation.resumeSessionID == nil,
                                          invocation.mcpActionServer == nil, invocation.mcpReadConnectors.isEmpty,
                                          invocation.outputSchema == SidekickCompactor.schema else { fatalError("unsafe compactor recipe") }
                                    guard !invocation.prompt.contains("RAW_ARGUMENT_SENTINEL"), !invocation.prompt.contains("Question 5") else { fatalError("wrong compaction prefix") }
                                    invoked.set(true)
                                    return SidekickContext.json(["summary": "Questions 0–4 completed. Exact source: answer-\(backend.rawValue)-0."])
                                }
                            }
                        }
                    }
                }
            }
            try check(invoked.get(), "all existing provider backends use isolated worker")
            try check(try fresh.summary?.throughSequence == 25 && fresh.summary?.fromSequence == 1, "only completed tasks older than recent fifteen summarized")
            try check(try fresh.records(limit: 500).count == 100, "summary installation never deletes original history")
            invoked.set(false)
            try await SidekickCompactor.compactIfNeeded(store: fresh) { _ in invoked.set(true); fatalError("unexpected repeat inference") }
            try check(!invoked.get(), "already current snapshot does not invoke a model")
        }

        // Legacy records contain requests and app statuses, not confirming action results.
        // A structurally extracted ledger must never ask a model to rewrite that uncertainty.
        let legacy = try Store(url: root.appendingPathComponent("legacy.sqlite"))
        let legacyOutcomes: [Event.Outcome] = [.failed, .stopped, .interrupted, .success]
        for i in 0..<20 {
            _ = try legacy.appendBatch(legacyTask(request: "LEGACY_REQUEST_\(i): read the café 👩🏽‍💻 note.",
                outcome: legacyOutcomes[i % legacyOutcomes.count]))
        }
        let legacyOriginals = try legacy.records(limit: 500)
        let maliciousInvocations = ValueBox(0)
        let malicious: SidekickCompactor.Summarizer = { _ in
            maliciousInvocations.set(maliciousInvocations.get() + 1)
            return SidekickContext.json(["summary": "The task outcome is unknown, but the note was not read."])
        }
        try await SidekickCompactor.compactIfNeeded(store: legacy, summarize: malicious)
        try check(maliciousInvocations.get() == 0, "legacy-only compaction invoked an unreliable summarizer")
        try check(try legacy.summary?.fromSequence == 1 && legacy.summary?.throughSequence == 20,
                  "legacy extraction did not cover exactly the eligible five complete tasks")
        let savedLegacy = try legacy.summary!.text
        let savedLegacyRecords = try legacyBody(savedLegacy)
        try check(!savedLegacy.contains("note was not read") && savedLegacy.contains("LEGACY_REQUEST_0")
                    && savedLegacy.contains("LEGACY_REQUEST_4") && !savedLegacy.contains("LEGACY_REQUEST_5"),
                  "legacy ledger invented an absence of effects or covered the protected tail")
        try check(savedLegacyRecords.filter { $0["kind"] as? String == "taskFinished" }.map { $0["outcome"] as! String }
                    == ["failed", "stopped", "interrupted", "success", "failed"],
                  "legacy extraction strengthened or conflated terminal status categories")
        try check(try legacy.records(limit: 500) == legacyOriginals, "legacy extraction rewrote original history")
        try await SidekickCompactor.compactIfNeeded(store: legacy, summarize: malicious)
        try check(maliciousInvocations.get() == 0 && (try legacy.summaries()).count == 1,
                  "legacy retry re-ran inference or duplicated a committed segment")

        let mixed = try Store(url: root.appendingPathComponent("legacy-rich.sqlite"))
        for i in 0..<2 { _ = try mixed.appendBatch(legacyTask(request: "LEGACY_ONLY_SENTINEL_\(i)")) }
        try appendRichTasks(18, to: mixed, label: "mixed")
        let mixedOriginals = try mixed.records(limit: 500)
        try await SidekickCompactor.compactIfNeeded(store: mixed, summarize: malicious)
        try check(maliciousInvocations.get() == 0 && (try mixed.summary)?.throughSequence == 8,
                  "mixed history passed legacy to the model or advanced past its extracted prefix")
        let richInvocations = ValueBox(0)
        try await SidekickCompactor.compactIfNeeded(store: mixed) { invocation in
            richInvocations.set(richInvocations.get() + 1)
            guard !invocation.prompt.contains("LEGACY_ONLY_SENTINEL"),
                  !invocation.prompt.contains("legacy-request:"), !invocation.prompt.contains("legacy-end:"),
                  invocation.prompt.contains("RICH_REQUEST_mixed_0"), invocation.prompt.contains("RICH_ANSWER_mixed_2"),
                  !invocation.prompt.contains("RICH_REQUEST_mixed_3") else { fatalError("rich model segment includes legacy or protected records") }
            return SidekickContext.json(["summary": "Rich tasks zero through two; source rich-answer-mixed-2."])
        }
        try check(richInvocations.get() == 1 && (try mixed.summaries()).count == 2,
                  "rich transcript did not retain model compaction after legacy extraction")
        try check(try mixed.summary?.fromSequence == 9 && mixed.summary?.throughSequence == 20,
                  "rich summary claimed the previously extracted legacy prefix")
        try check(try mixed.records(limit: 500) == mixedOriginals, "mixed compaction altered original source records")

        // A single legal stored task can have more metadata than the summary allowance.
        // That is a safe refusal, never permission to send migrated-only data to a model.
        let metadataHeavy = try Store(url: root.appendingPathComponent("legacy-metadata.sqlite"))
        let metadataTask = legacyTask(blocker: nil)
        var heavyEvents = Array(metadataTask.prefix(2))
        for i in 0..<35 {
            heavyEvents.append(Event(id: String(repeating: "checkpoint-metadata-", count: 24) + "\(i)",
                taskID: metadataTask[0].taskID, kind: .checkpoint, text: "Reported blocker \(i)"))
        }
        heavyEvents.append(metadataTask.last!)
        _ = try metadataHeavy.appendBatch(heavyEvents)
        try appendRichTasks(15, to: metadataHeavy, label: "metadata-protected")
        let heavyOriginals = try metadataHeavy.records(limit: 500)
        if case .cannotFit = SidekickContext.legacySummary(records: legacyRecords(heavyEvents)) { checks += 1 }
        else { fatalError("oversized legal legacy metadata did not return cannotFit") }
        try await SidekickCompactor.compactIfNeeded(store: metadataHeavy, summarize: malicious)
        try check(maliciousInvocations.get() == 0 && (try metadataHeavy.summary) == nil,
                  "legacy metadata overflow fell back to an unreliable model or installed an incomplete summary")
        try check(try metadataHeavy.records(limit: 500) == heavyOriginals,
                  "legacy metadata refusal changed original stored records")

        let concurrent = try seed(root, name: "concurrent")
        let barrier = Barrier()
        let slow = Task {
            try await SidekickCompactor.compactIfNeeded(store: concurrent) { _ in
                await barrier.enter()
                return SidekickContext.json(["summary": "Original fixed prefix; answer-concurrent-0."])
            }
        }
        await barrier.waitForStart()
        try check(try concurrent.summary == nil, "slow worker does not publish incomplete summary")
        let newTask = UUID()
        _ = try concurrent.append(Event(taskID: newTask, kind: .userMessage, text: "Foreground continues immediately"))
        let foreground = SidekickContext.build(records: try concurrent.contextRecords(), summaries: try concurrent.summaries())
        try check(foreground.prompt.contains("Foreground continues immediately"), "foreground builds context while model is blocked")
        await barrier.release(); try await slow.value
        try check(try concurrent.summary?.throughSequence == 25, "new tail never expands worker snapshot")
        try check(try concurrent.record(id: "request-concurrent-0") != nil, "original source retained after concurrent work")

        let resetStore = try seed(root, name: "reset")
        let resetBarrier = Barrier()
        let stale = Task {
            try await SidekickCompactor.compactIfNeeded(store: resetStore) { _ in
                await resetBarrier.enter(); return "{\"summary\":\"Old history\"}"
            }
        }
        await resetBarrier.waitForStart(); try resetStore.reset()
        await resetBarrier.release(); try await stale.value
        try check(try resetStore.summary == nil && resetStore.latestSequence == 0, "reset invalidates in-flight summary")

        let race = try seed(root, name: "race")
        let raceBarrier = Barrier()
        let racing = Task {
            try await SidekickCompactor.compactIfNeeded(store: race) { _ in
                await raceBarrier.enter(); return "{\"summary\":\"Stale candidate\"}"
            }
        }
        await raceBarrier.waitForStart()
        try race.installSummary(generation: race.generation, throughSequence: 10, text: "Already accepted independent segment", expectedFromSequence: 1)
        await raceBarrier.release(); try await racing.value
        try check(try race.summary?.throughSequence == 10 && race.summary?.text == "Already accepted independent segment", "overlapping candidate cannot overwrite committed segment")
        try await SidekickCompactor.compactIfNeeded(store: race) { invocation in
            guard !invocation.prompt.contains("Already accepted independent segment"), !invocation.prompt.contains("Question 0") else { fatalError("summary-of-summary or repeated old prefix") }
            return "{\"summary\":\"New original segment only; answer-race-2.\"}"
        }
        try check(try race.summaries().count == 2 && race.summary?.fromSequence == 11, "independent source segments preserved")

        let failure = try seed(root, name: "failure")
        enum FixtureFailure: Error { case unavailable }
        do {
            try await SidekickCompactor.compactIfNeeded(store: failure) { _ in throw FixtureFailure.unavailable }
            fatalError("provider failure swallowed")
        } catch FixtureFailure.unavailable { checks += 1 }
        try check(try failure.summary == nil && failure.records(limit: 500).count == 100, "provider failure preserves history and prior snapshot")
        let cancelled = ValueBox(false), began = ValueBox(false)
        let cancellation = Task {
            try await SidekickCompactor.compactIfNeeded(store: failure) { _ in
                began.set(true)
                do { try await Task.sleep(for: .seconds(30)) }
                catch is CancellationError { cancelled.set(true); throw CancellationError() }
                return "{\"summary\":\"must not commit\"}"
            }
        }
        while !began.get() { try await Task.sleep(for: .milliseconds(1)) }
        cancellation.cancel()
        do { try await cancellation.value; fatalError("cancelled worker returned success") }
        catch is CancellationError { checks += 1 }
        try check(cancelled.get() && (try failure.summary) == nil, "caller cancellation reaches owned model worker and prevents commit")
        print("Sidekick context/compaction: \(checks) assertions passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="sentient-context-tests-") as directory:
    tmp = Path(directory)
    (tmp / "Support.swift").write_text(SUPPORT)
    (tmp / "Tests.swift").write_text(TESTS)
    sources = [APP / "Notch Magic" / name for name in ["SidekickConversationStore.swift", "SidekickContext.swift", "SidekickCompactor.swift"]]
    executable = tmp / "context-tests"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", *map(str, sources), str(tmp / "Support.swift"), str(tmp / "Tests.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=40)
