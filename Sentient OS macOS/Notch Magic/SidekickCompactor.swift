// Summarizes one immutable completed prefix, outside the foreground execution session.
// Conversation owns debounce/single-job scheduling; cancellation propagates to the CLI worker.
import Foundation

nonisolated enum SidekickCompactor {
    typealias Store = SidekickConversationStore
    typealias Summarizer = @Sendable (CodexCLI.Invocation) async throws -> String
    enum Failure: LocalizedError {
        case invalidSummary
        var errorDescription: String? { "Sidekick could not validate the background history summary. Original conversation history is unchanged." }
    }
    private enum Method: Sendable {
        case model(prompt: String)
        case legacy(text: String)
    }
    private struct Snapshot: Sendable {
        let generation: UUID
        let fromSequence: Int64
        let throughSequence: Int64
        let records: [Store.Record]
        let method: Method
    }
    private static let maximumRecords = 500
    private static let maximumSourceBytes = 2_000_000
    static let maximumSummaryBytes = 10_000
    static let schema = #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"],"additionalProperties":false}"#

    /// Does not run on the caller's actor. Foreground never awaits this operation; the
    /// app-owned debounce task does, allowing Stop/reset to cancel and drain its child.
    static func compactIfNeeded(store: Store, summarize: Summarizer? = nil) async throws {
        try Task.checkCancellation()
        let backend = ModelBackend.current
        let worker = Task.detached(priority: .utility) {
            try await ModelBackend.$runOverride.withValue(backend) {
                try await SidekickInteraction.$current.withValue(nil) {
                    try await SidekickToolServer.$connection.withValue(nil) {
                        try await ResearchToolServer.$connection.withValue(nil) {
                            try await DirectMCPRuntime.$current.withValue([]) {
                                try await perform(store: store, backend: backend, summarize: summarize)
                            }
                        }
                    }
                }
            }
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func snapshot(_ store: Store) throws -> Snapshot? {
        let generation = try store.generation
        let previous = try store.summary?.throughSequence ?? 0
        guard let boundary = try store.compactionBoundary(keepingRecentTasks: 15), boundary > previous else { return nil }
        var records: [Store.Record] = [], open = Set<UUID>()
        var cursor = previous, sourceBytes = 0, completedCount = 0
        while cursor < boundary, records.count < maximumRecords, sourceBytes < maximumSourceBytes {
            try Task.checkCancellation()
            let page = try store.contextRecordsForCompaction(after: cursor, limit: min(64, maximumRecords - records.count))
            guard !page.isEmpty else { break }
            for record in page where record.sequence <= boundary {
                records.append(record); cursor = record.sequence
                sourceBytes += record.event.text.utf8.count + (record.event.choices?.reduce(0) { $0 + $1.utf8.count } ?? 0)
                if record.event.kind == .taskFinished { open.remove(record.event.taskID) }
                else { open.insert(record.event.taskID) }
                if open.isEmpty { completedCount = records.count }
                if records.count >= maximumRecords || sourceBytes >= maximumSourceBytes { break }
            }
            if page.last!.sequence >= boundary { break }
        }
        // A bounded scan never claims a partially read task. Leave the previous context usable
        // if a single unusually large task exceeds the scan budget; exact history stays intact.
        guard completedCount > 0 else {
            SidekickDiagnostics.event(.compaction, outcome: .skipped, reason: .budgetExceeded, source: .compactor)
            return nil
        }
        records = Array(records.prefix(completedCount))
        guard try store.generation == generation else { throw Store.Failure.staleGeneration }
        guard (try store.summary?.throughSequence ?? 0) == previous else { throw Store.Failure.staleSummary }
        let method: Method
        switch SidekickContext.legacySummary(records: records, byteBudget: maximumSummaryBytes) {
        case .notApplicable:
            guard let prompt = SidekickContext.compactionPrompt(records: records) else { return nil }
            method = .model(prompt: prompt)
        case .cannotFit:
            // Missing legacy evidence must not become model-authored claims. If even one
            // whole task's metadata cannot fit, keep the watermark and original context.
            SidekickDiagnostics.event(.compaction, outcome: .skipped, reason: .budgetExceeded, source: .compactor)
            return nil
        case .extracted(let through, let text):
            records.removeAll { $0.sequence > through }
            method = .legacy(text: text)
        }
        guard let through = records.last?.sequence else { return nil }
        return Snapshot(generation: generation, fromSequence: previous + 1,
                        throughSequence: through, records: records, method: method)
    }

    private static func perform(store: Store, backend: ModelBackend, summarize: Summarizer?) async throws {
        let diagnosticBackend = SidekickDiagnostics.Backend(rawValue: backend.rawValue) ?? .unknown
        let began = Date()
        do {
            guard let snapshot = try snapshot(store) else { return }
            try Task.checkCancellation()
            var counts: [SidekickDiagnostics.Count: Int] = [.events: snapshot.records.count,
                .coveredSequence: Int(snapshot.throughSequence)]
            if case .legacy = snapshot.method {
                counts[.migratedTasks] = snapshot.records.filter { $0.event.kind == .taskFinished }.count
            }
            SidekickDiagnostics.event(.compaction, outcome: .started, backend: diagnosticBackend,
                source: .compactor, counts: counts)
            let raw: String
            switch snapshot.method {
            case .legacy(let text):
                raw = SidekickContext.json(["summary": text])
            case .model(let prompt):
                let invocation = invocation(prompt: prompt)
                if let summarize { raw = try await summarize(invocation) }
                else { raw = try await FrontierRun.run(invocation).jsonResult }
            }
            try Task.checkCancellation()
            let summary = try validatedSummary(raw)
            // The store verifies both generation and starting watermark atomically. A later
            // worker/reset can win while inference runs; its accepted context is never replaced.
            try store.installSummary(generation: snapshot.generation, throughSequence: snapshot.throughSequence,
                text: summary, expectedFromSequence: snapshot.fromSequence)
            counts[.bytes] = summary.utf8.count
            SidekickDiagnostics.event(.compaction, backend: diagnosticBackend, source: .compactor,
                counts: counts, duration: Date().timeIntervalSince(began))
        } catch Store.Failure.staleGeneration {
            SidekickDiagnostics.event(.compaction, outcome: .skipped, reason: .staleGeneration, backend: diagnosticBackend, source: .compactor)
        } catch Store.Failure.staleSummary {
            SidekickDiagnostics.event(.compaction, outcome: .skipped, reason: .sourceChanged, backend: diagnosticBackend, source: .compactor)
        } catch is CancellationError {
            SidekickDiagnostics.event(.compaction, outcome: .skipped, reason: .cancelled, backend: diagnosticBackend, source: .compactor)
            throw CancellationError()
        }
    }

    static func invocation(prompt: String) -> CodexCLI.Invocation {
        var invocation = CodexCLI.Invocation(prompt: prompt)
        invocation.model = .gpt6sol; invocation.effort = .low
        invocation.sandbox = .readOnly; invocation.toolsDisabled = true
        invocation.webSearch = false; invocation.includeUserConfig = false
        invocation.outputSchema = schema; invocation.timeout = 180
        invocation.feature = "sidekick-compaction"
        return invocation
    }

    static func validatedSummary(_ raw: String) throws -> String {
        // Bound before JSON parsing; escaped text can be substantially larger than decoded text.
        guard raw.utf8.count <= maximumSummaryBytes * 6 + 256,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["summary"], let summary = object["summary"] as? String,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              summary.utf8.count <= maximumSummaryBytes else { throw Failure.invalidSummary }
        return summary
    }
}
