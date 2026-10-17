// App-lifetime conversation projection. Provider processes and Home views do not own history.
// Writes are committed by the store before this observable projection is refreshed.

import Foundation

@MainActor @Observable
final class SidekickConversation {
    typealias Event = SidekickConversationEvent
    typealias Record = SidekickConversationStore.Record
    static let shared = SidekickConversation()
    private(set) var messages: [Record] = []
    private(set) var unreadCount = 0
    private(set) var attention: Record?
    private(set) var storageError: String?
    private(set) var destinationMessageID: String?
    private(set) var navigationRequest: UUID?
    private(set) var generation: UUID?
    private(set) var revision: UInt64 = 0
    var draft = ""
    var replyReference: Event.ReplyReference?
    var isVisible = false { didSet { refresh() } }
    @ObservationIgnored private(set) var store: SidekickConversationStore?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var active: SidekickConversationRun?
    @ObservationIgnored private var compactTask: Task<Void, Never>?
    @ObservationIgnored private var maintenance = false
    @ObservationIgnored var onRefresh: (() -> Void)?
    @ObservationIgnored private let storageURL: URL

    init(url: URL? = nil, defaults: UserDefaults = .standard) {
        storageURL = url ?? URL.sentientSupport.appendingPathComponent("Sidekick/Conversation.sqlite")
        do {
            let store = try SidekickConversationStore(url: storageURL)
            if try store.needsLegacyImport {
                let legacy = try SidekickHistory.legacyEvents(defaults: defaults)
                _ = try store.importLegacy(events: legacy)
                SidekickDiagnostics.event(.migration, counts: [.events: legacy.count])
            }
            SidekickHistory.reset(defaults: defaults)
            let recovered = try store.recoverInterruptedTasks()
            if !recovered.isEmpty {
                SidekickDiagnostics.event(.task, outcome: .interrupted, source: .startup, counts: [.recoveredTasks: recovered.count])
            }
            self.store = store
            SidekickDiagnostics.event(.storeOpen)
            observe(store)
            refresh()
        } catch { report(error, stage: .storeOpen) }
    }

    func begin(request: String, source: String, taskID: UUID, userMessage: String? = nil,
               reply: Event.ReplyReference? = nil, continuation: String? = nil) throws -> (SidekickConversationRun, String) {
        guard active == nil, !maintenance else { throw SidekickConversationRun.Failure.closed }
        guard let store else { throw Failure.unavailable }
        var durableContinuation = continuation
        if reply == nil, let continuation, try store.record(id: continuation) == nil {
            // A failed terminal transaction never created end:<task>. Retry can still refer
            // to its durable original request after storage recovers; do not invent an ending.
            guard continuation.hasPrefix("end:"), let task = UUID(uuidString: String(continuation.dropFirst(4))),
                  let request = try store.record(id: "request:\(task.uuidString)"), request.event.kind == .userMessage else {
                throw SidekickConversationRun.Failure.invalidReference
            }
            durableContinuation = request.event.id
        }
        // The single app owner has no live producer here. A prior terminal-write failure
        // must not leave an orphan that blocks compaction until the next application launch.
        let recovered = try store.recoverInterruptedTasks()
        if !recovered.isEmpty {
            SidekickDiagnostics.event(.task, outcome: .interrupted,
                source: source == "proactive_card" ? .proactive : (.init(rawValue: source) ?? .command),
                counts: [.recoveredTasks: recovered.count])
        }
        let generation = try store.generation
        let referenced = try reply.map { reference -> Record in
            guard let record = try store.record(id: reference.messageID),
                  reference.selectedText.map({ !$0.isEmpty && record.event.text.contains($0) }) ?? true else {
                throw SidekickConversationRun.Failure.invalidReference
            }
            return record
        }
        // Fifteen is a compaction target, not a hard context cliff. Short exchanges can
        // retain more exact turns; the builder enforces the actual encoded byte budget.
        let context = SidekickContext.build(records: try store.contextRecords(taskLimit: 30), summaries: try store.summaries(),
                                           reply: referenced, selectedText: reply?.selectedText)
        SidekickDiagnostics.event(.context, taskID: taskID,
            backend: .init(rawValue: ModelBackend.current.rawValue) ?? .unknown,
            counts: [.bytes: context.bytes, .messages: context.includedMessages, .omittedEvents: context.omittedMessages])
        let at = Date()
        _ = try store.appendBatch([
            Event(id: "start:\(taskID)", taskID: taskID, kind: .taskStarted, text: request,
                  createdAt: at, source: source),
            Event(id: "request:\(taskID)", taskID: taskID, kind: .userMessage, text: userMessage ?? request,
                  createdAt: at, source: source, reply: reply ?? durableContinuation.map { .init(messageID: $0) })
        ], expectedGeneration: generation)
        storageError = nil
        let run = SidekickConversationRun(store: store, taskID: taskID, generation: generation,
                                         backend: ModelBackend.current.rawValue, source: source)
        active = run
        refresh()
        return (run, context.prompt)
    }

    @discardableResult
    func finish(_ run: SidekickConversationRun, outcome: Event.Outcome, status: String, finalText: String) -> Bool {
        guard active === run else { return false }
        let saved: Bool
        do {
            try run.finish(outcome: outcome, status: status, finalText: finalText)
            storageError = nil; saved = true
        }
        catch { report(error, stage: .storeWrite); saved = false }
        run.invalidate(); active = nil
        refresh()
        scheduleCompaction()
        return saved
    }

    /// Retained records stay on disk. UI asks for older pages/activity only when expanded.
    func history(after sequence: Int64 = 0, limit: Int = 100) throws -> [Record] {
        guard let store else { throw Failure.unavailable }
        return try store.records(after: sequence, limit: limit)
    }
    func activity(taskID: UUID, after sequence: Int64 = 0) throws -> [Record] {
        guard let store else { throw Failure.unavailable }
        return try store.activityRecords(taskID: taskID, after: sequence, limit: 200)
    }
    /// Request a transcript destination without opening or activating another window.
    func requestNavigation(messageID: String? = nil) {
        destinationMessageID = messageID
        navigationRequest = UUID()
    }
    func show(messageID: String? = nil) {
        requestNavigation(messageID: messageID)
        HomeWindowOpening.open()
    }
    func consumeDestination() { destinationMessageID = nil; navigationRequest = nil }

    func markRead(messageIDs: [String], generation: UUID) {
        guard !maintenance, let store else { return }
        do { try store.markRead(messageIDs: messageIDs, expectedGeneration: generation) }
        catch SidekickConversationStore.Failure.staleGeneration { }
        catch { report(error, stage: .storeWrite) }
    }
    func markRead(through sequence: Int64, generation: UUID) {
        guard !maintenance, let store else { return }
        do { try store.markRead(throughSequence: sequence, expectedGeneration: generation); refresh() }
        catch SidekickConversationStore.Failure.staleGeneration {
            SidekickDiagnostics.event(.attention, outcome: .skipped, reason: .staleGeneration)
        }
        catch { report(error, stage: .storeWrite) }
    }

    func refresh() {
        refresh(allowDuringMaintenance: false)
    }

    private func refresh(allowDuringMaintenance: Bool) {
        guard (!maintenance || allowDuringMaintenance), let store else { return }
        do {
            generation = try store.generation
            let recent = try store.transcriptPage(limit: 40).records
            if messages != recent { messages = recent; revision &+= 1 }
            unreadCount = try store.unreadCount
            attention = isVisible ? nil : try store.latestUnreadAttention
            onRefresh?()
        } catch { report(error, stage: .storeRead) }
    }

    /// Invalidate producers before any awaited teardown. Store generation rejects delayed jobs.
    func reset(defaults: UserDefaults = .standard) throws {
        compactTask?.cancel()
        active?.invalidate(); active = nil
        if let store { try store.reset() }
        else {
            // Only an explicit reset may remove an unreadable database. Normal startup never
            // replaces it. Memory is a different file and survives the history reset.
            for suffix in ["", "-wal", "-shm"] {
                let path = storageURL.path + suffix
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            }
            let replacement = try SidekickConversationStore(url: storageURL)
            _ = try replacement.importLegacy(events: [])
            store = replacement; observe(replacement)
        }
        SidekickHistory.reset(defaults: defaults)
        draft = ""; replyReference = nil; destinationMessageID = nil; navigationRequest = nil; storageError = nil
        refresh(allowDuringMaintenance: true)
    }

    func beginMaintenance() { maintenance = true; compactTask?.cancel() }
    func endMaintenance() { maintenance = false; refresh() }
    #if DEBUG
    /// Observation only: native acceptance waits for below-threshold debounce work to finish
    /// before crossing the real threshold. The test never starts or substitutes the compactor.
    var hasPendingCompactionWorkForTesting: Bool { compactTask != nil }
    #endif
    func drainBackgroundWork() async {
        let owned = compactTask
        owned?.cancel()
        await owned?.value
    }

    /// Called only after foreground and background work have drained, immediately before
    /// removing app support. No late UI callback or retained recorder can use the old handle.
    func closeForUninstall() {
        maintenance = true
        compactTask?.cancel()
        active?.invalidate(); active = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        store?.close(); store = nil
        messages = []; unreadCount = 0; attention = nil; generation = nil
        destinationMessageID = nil; navigationRequest = nil; draft = ""; replyReference = nil; storageError = nil
        onRefresh?()
    }

    private func scheduleCompaction() {
        guard !maintenance, compactTask == nil, let store else { return }
        compactTask = Task { [weak self] in
            defer { self?.compactTask = nil }
            do {
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                try await SidekickCompactor.compactIfNeeded(store: store)
            } catch is CancellationError { }
            catch { SidekickDiagnostics.failure(.compaction, reason: .providerFailure, source: .compactor) }
        }
    }

    private func observe(_ store: SidekickConversationStore) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .sidekickConversationChanged,
            object: store, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
    }

    private func report(_ error: Error, stage: SidekickDiagnostics.Stage) {
        storageError = (error as? LocalizedError)?.errorDescription ?? "Sidekick history could not be saved. Existing history has been preserved."
        let reason: SidekickDiagnostics.Reason
        switch error {
        case SidekickConversationStore.Failure.staleGeneration: reason = .staleGeneration
        case SidekickConversationStore.Failure.unsupportedSchema: reason = .newerSchema
        case SidekickConversationStore.Failure.invalidSchema, SidekickConversationStore.Failure.corruptPayload: reason = .corruptStore
        default: reason = stage == .storeRead ? .readFailed : .writeFailed
        }
        SidekickDiagnostics.failure(stage, reason: reason)
    }

    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Sidekick history is unavailable. Your existing data has been preserved. Restart Sentient to try again." }
    }
}
