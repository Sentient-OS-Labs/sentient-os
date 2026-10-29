// Full production Gmail/CycleStore regression fixture. External reads and unrelated
// sources are synthetic; all Gmail persistence and scheduling run the actual code.
import Foundation
import SwiftData

nonisolated enum SourceKind: String, Codable { case file, gmail, appleCalendar }
nonisolated struct AppleMailCheckpoint: Codable { var version = 2 }
nonisolated enum AppleMailError: Error { case unsupportedSchema }
nonisolated enum AppleCalendarSource {
    static let bucketKey = "apple-calendar"
    static let isEnabled = false
    struct Coverage: Codable, Equatable {
        var encoded: String { "fixture" }
        var matchesSelection: Bool { false }
        static func decode(_ value: String) -> Self? { nil }
    }
    struct Snapshot {
        let capturedAt: Date
        let coverage: Coverage
        var marker: NoteDraft { fatalError("Calendar cannot execute in Gmail fixture") }
    }
    enum ReadError: Error { case changed }
}
nonisolated struct CalendarRetryCache: Codable {
    var version = 1
    var coverage: AppleCalendarSource.Coverage
    mutating func validate(against: AppleCalendarSource.Snapshot) {}
}
nonisolated func Log(_ message: String) { print(message) }
nonisolated func ErrorLabel(_ error: Error) -> String { String(describing: type(of: error)) }
nonisolated enum DiskSpace {
    static func isDiskFull(_ error: Error) -> Bool { (error as NSError).code == NSFileWriteOutOfSpaceError }
}
nonisolated enum Diagnostics {
    enum Event { case storeReadFailed, cleanupFailed, sourceReadFailed }
    enum Phase { case read, reset }
    enum Count { case failed }
    static func report(_ event: Event, phase: Phase, reason: String, error: Error, source: String? = nil, counts: [Count: Int] = [:]) {}
    static func errorFields(_ error: Error) -> [String: String] { [:] }
    static func isCancellation(_ error: Error) -> Bool { error is CancellationError }
}
nonisolated enum CodexFailureReason {
    case usageLimit, unknown
    static func classify(_ error: Error) -> Self { .unknown }
}
nonisolated enum CrashReporting {
    enum Level { case error }
    static func captureEvent(_ name: String, level: Level, tags: [String: String], fingerprint: [String]) {}
}
extension URL {
    nonisolated static var sentientSupport: URL { fatalError("Production store must never open in this fixture") }
}
nonisolated enum ModelBackend {
    case chatgpt, claude
    @TaskLocal static var runOverride: Self?
    static var current: Self { runOverride ?? BackendPreference.shared.get() }
}
nonisolated final class BackendPreference: @unchecked Sendable {
    static let shared = BackendPreference()
    private let lock = NSLock()
    private var backend: ModelBackend = .chatgpt
    func get() -> ModelBackend { lock.lock(); defer { lock.unlock() }; return backend }
    func set(_ value: ModelBackend) { lock.lock(); defer { lock.unlock() }; backend = value }
}
nonisolated final class ProcessingSpy: @unchecked Sendable {
    struct Event { let kind: String; let backend: ModelBackend; let pinned: Bool }
    static let shared = ProcessingSpy()
    private let lock = NSLock()
    private var events: [Event] = []
    func reset() { lock.lock(); defer { lock.unlock() }; events = [] }
    func record(_ kind: String) {
        lock.lock(); defer { lock.unlock() }
        events.append(Event(kind: kind, backend: ModelBackend.current, pinned: ModelBackend.runOverride == ModelBackend.current))
    }
    func snapshot() -> [Event] { lock.lock(); defer { lock.unlock() }; return events }
}
nonisolated enum ConnectorLinks { static func page(for slug: String) -> URL { URL(string: "https://example.invalid")! } }
@MainActor enum HostedConnectorSetup {
    static func processingStarted(slug: String) { ProcessingSpy.shared.record("hook") }
}
nonisolated enum MCPSource { enum MCPError: Error { case clockMovedBackwards, connectionChanged, toolFailure, connectorAuth } }
nonisolated enum ConnectorReadFailure {
    enum GmailFailure: Error { case accountLimit }
    static func isConnectionFailure(_ error: Error) -> Bool { (error as? MCPSource.MCPError) == .connectorAuth }
}
nonisolated enum CodexCLI {
    struct Invocation: Sendable {
        enum Model { case gpt6luna }
        enum Effort { case medium }
        enum Sandbox { case readOnly }
        let prompt: String
        var feature = ""
        var model: Model = .gpt6luna
        var effort: Effort = .medium
        var sandbox: Sandbox = .readOnly
        var outputSchema = ""
        var timeout: TimeInterval = 0
        var mcpReadConnectors: [String] = []
    }
}
nonisolated final class Origin: @unchecked Sendable {
    static let shared = Origin()
    private let lock = NSLock()
    private var value = "fixture:0"
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: String) { lock.lock(); defer { lock.unlock() }; value = next }
}
nonisolated enum GoogleSourceRead {
    struct Summary: Sendable { let text: String; let hasActionItems: Bool; let count: Int }
    enum Failure: Error { case storage, invalidResponse }
    static func origin(bucket: String) -> String { Origin.shared.get() }
    static func read(_ invocation: CodexCLI.Invocation, slug: String, countKey: String) async throws -> Summary? {
        try await ReadProbe.shared.read(invocation.prompt)
    }
}

actor ReadProbe {
    static let shared = ReadProbe()
    enum Mode { case success, oneFailure, auth, accountLimit, cancel, originChange }
    private var mode: Mode = .success
    private var windows: [GmailReadState.Window] = []
    private var calls: [Int] = []
    private var active = 0
    private var maximum = 0
    func reset(_ mode: Mode, windows: [GmailReadState.Window]) {
        self.mode = mode; self.windows = windows; calls = []; active = 0; maximum = 0
        ProcessingSpy.shared.reset()
    }
    func stats() -> (calls: [Int], maximum: Int) { (calls, maximum) }
    func read(_ prompt: String) async throws -> GoogleSourceRead.Summary? {
        let matching = windows.indices.filter { prompt.contains(windows[$0].query) }
        guard matching.count == 1, let index = matching.first else {
            throw TestFailure.message("Gmail did not request exactly one persisted window's epoch boundaries")
        }
        calls.append(index); active += 1; maximum = max(maximum, active)
        ProcessingSpy.shared.record("read")
        defer { active -= 1 }
        switch mode {
        case .originChange:
            Origin.shared.set("fixture:new")
            try await Task.sleep(for: .milliseconds(20))
        case .cancel: try await Task.sleep(for: .seconds(20))
        case .auth:
            if index == 0 { try await Task.sleep(for: .milliseconds(20)); throw MCPSource.MCPError.connectorAuth }
            try await Task.sleep(for: .seconds(20))
        case .accountLimit:
            if index == 1 { try await Task.sleep(for: .milliseconds(80)); throw ConnectorReadFailure.GmailFailure.accountLimit }
            try await Task.sleep(for: .milliseconds(index == 0 ? 10 : 20_000))
        case .oneFailure:
            try await Task.sleep(for: .milliseconds(index == 0 ? 80 : 20))
            if index == 0 { throw MCPSource.MCPError.toolFailure }
            if index == 2 { return nil }
        case .success: try await Task.sleep(for: .milliseconds(10))
        }
        return .init(text: "Synthetic useful weekly context \(index)", hasActionItems: false, count: 1)
    }
}
nonisolated enum TestFailure: Error { case message(String) }
nonisolated final class QueueGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
}
extension CycleStore {
    func holdForFixture(_ gate: QueueGate) { gate.entered.signal(); gate.release.wait() }
}
nonisolated final class ProgressSpy: @unchecked Sendable {
    struct Completion { let completed: Int; let kept: Int; let summary: String? }
    private let lock = NSLock()
    private var completions: [Completion] = []
    func record(_ event: GmailConnect.Progress) {
        guard case let .windowDone(_, _, summary, _, completed, kept) = event else { return }
        lock.lock(); defer { lock.unlock() }
        completions.append(.init(completed: completed, kept: kept, summary: summary))
    }
    func snapshot() -> [Completion] { lock.lock(); defer { lock.unlock() }; return completions }
}

@main enum GmailImportRecoveryTests {
    static let through = Date(timeIntervalSince1970: 1_792_843_421)
    static let prior = ItemKey(order: 1_790_000_000, tiebreak: "prior")
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure.message(message) }
        print("PASS \(message)")
    }
    static func makeStore(_ path: URL) throws -> CycleStore {
        let schema = Schema([BucketPointer.self, CycleNote.self, AppleMailReceipt.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: path))
        return CycleStore(modelContainer: container)
    }
    static func note(_ state: GmailReadState, _ index: Int) -> NoteDraft {
        .init(kind: .gmail, sourceID: "gmail:window:\(state.id.uuidString):\(index)", folder: "Gmail",
              itemDate: state.windows[index].end, text: "Synthetic durable summary \(index)", title: "Fixture", reminderFlagged: false)
    }
    static func initial(_ origin: String = "fixture:0", at date: Date = through, replace: Bool = false) throws -> GmailReadState {
        GmailReadState.initial(origin: origin, through: date, replaceNotes: replace)
    }
    static func main() async throws {
        let arguments = CommandLine.arguments
        let phase = arguments[1], root = URL(fileURLWithPath: arguments[2])
        let store = try makeStore(root.appending(path: phase.contains("partial") || phase == "reopen-complete" ? "durable.store" : "\(phase).store"))
        try await CycleStore.$acceptanceStore.withValue(store) {
            switch phase {
            case "migration":
                try check(await store.notes().map(\.sourceID) == ["gmail:legacy"], "pre-change SwiftData schema migrates with summary intact")
                try check(try await store.mcpCheckpoint("gmail")?.mark == prior, "pre-change global checkpoint survives migration")
                try check(try await store.gmailReadState() == nil, "pre-change store has no invented pending import")
                _ = try await store.beginGmailRead(initial())
                try check(await store.notes().count == 1, "migrated store accepts new pending state without erasing notes")
            case "write-partial":
                let state = try await store.beginGmailRead(initial())
                _ = try await store.commitGmailWindow(stateID: state.id, origin: state.origin, index: 0, note: note(state, 0))
                _ = try await store.commitGmailWindow(stateID: state.id, origin: state.origin, index: 2, note: note(state, 2))
                try check(await store.notes().count == 2, "two independent windows saved before process exit")
                try check((try await store.mcpCheckpoint("gmail")?.mark.order ?? 0) == 0, "fresh partial import has no advanced watermark")
            case "reopen-partial":
                guard let state = try await store.gmailReadState() else { throw TestFailure.message("Missing durable state") }
                try check(state.completed == [0, 2] && state.through == through, "new process reopens exact partial coverage and original end")
                try check(await store.notes().count == 2, "new process reopens completed summaries")
                let resumed = try await store.beginGmailRead(initial(at: through.addingTimeInterval(3 * 86_400), replace: true))
                try check(resumed.id == state.id && resumed.windows == state.windows, "later force-initial request resumes fixed window bounds")
                await store.wipeNotes(sourceIDs: Set((await store.notes()).map(\.sourceID)))
                try check(try await store.gmailReadState()?.completed == [0, 2], "downstream consumption leaves durable coverage receipts")
            case "finish-partial":
                guard let state = try await store.gmailReadState() else { throw TestFailure.message("Missing resume state") }
                try check(await store.notes().isEmpty, "consumed notes remain absent after process restart")
                let duplicate = try await store.commitGmailWindow(stateID: state.id, origin: state.origin, index: 0, note: note(state, 0))
                let afterDuplicate = await store.notes()
                try check(!duplicate && afterDuplicate.isEmpty, "duplicate completed window cannot recreate consumed note")
                _ = try await store.commitGmailWindow(stateID: state.id, origin: state.origin, index: 3, note: nil)
                try check((try await store.mcpCheckpoint("gmail")?.mark.order ?? 0) == 0, "quiet window commits coverage without jumping remaining gap")
                _ = try await store.commitGmailWindow(stateID: state.id, origin: state.origin, index: 1, note: note(state, 1))
                try check(try await store.gmailReadState() == nil, "last window retires pending import")
                try check(try await store.mcpCheckpoint("gmail")?.mark.order == through.timeIntervalSince1970, "last window commits original end so intervening mail remains unread")
            case "reopen-complete":
                try check(try await store.gmailReadState() == nil, "completed import stays completed across process restart")
                try check(try await store.mcpCheckpoint("gmail")?.mark.order == through.timeIntervalSince1970, "final watermark is durable")
                try check(await store.notes().count == 1, "only unconsumed successful note remains")
            case "transactions": try await transactions(store)
            case "pipeline": try await pipeline(store)
            case "origins": try await origins(store)
            default: throw TestFailure.message("Unknown phase")
            }
        }
    }
    static func transactions(_ store: CycleStore) async throws {
        let old = NoteDraft(kind: .gmail, sourceID: "gmail:old", folder: "Gmail", itemDate: through,
                            text: "Previous pending summary", title: nil, reminderFlagged: false)
        _ = await store.commitMCPRead(bucketKey: "gmail", notes: [old], through: prior, origin: "fixture:0", replaceNotes: false)
        let state = try await store.beginGmailRead(initial(replace: true))
        await store.failNextMCPCommitForTesting()
        do {
            _ = try await store.commitGmailWindow(stateID: state.id, origin: state.origin, index: 0, note: note(state, 0))
            throw TestFailure.message("Injected save failure unexpectedly succeeded")
        } catch let failure as TestFailure { throw failure }
        catch { try check(DiskSpace.isDiskFull(error), "weekly transaction surfaces the actual disk-full failure") }
        try check(try await store.gmailReadState()?.completed.isEmpty == true, "failed transaction rolls back completion receipt")
        try check(await store.notes().map(\.sourceID) == [old.sourceID], "failed transaction rolls back insertion and retains old summary")
        try check(try await store.mcpCheckpoint("gmail")?.mark == prior, "failed transaction preserves previous global watermark")
        for index in [0, 1, 2] {
            _ = try await store.commitGmailWindow(stateID: state.id, origin: state.origin, index: index, note: note(state, index))
        }
        try check(await store.notes().count == 4, "force-initial partial progress preserves earlier pending note")
        await store.failNextMCPCommitForTesting()
        do {
            _ = try await store.commitGmailWindow(stateID: state.id, origin: state.origin, index: 3, note: note(state, 3))
            throw TestFailure.message("Injected final save failure unexpectedly succeeded")
        } catch let failure as TestFailure { throw failure }
        catch { try check(DiskSpace.isDiskFull(error), "final transaction surfaces the actual disk-full failure") }
        try check(try await store.gmailReadState()?.completed == [0, 1, 2], "failed final transaction retains missing window")
        let rolledBackNotes = await store.notes()
        let rolledBackMark = try await store.mcpCheckpoint("gmail")
        try check(rolledBackNotes.count == 4 && rolledBackMark?.mark == prior,
                  "failed final replacement restores old notes and watermark")
        _ = try await store.commitGmailWindow(stateID: state.id, origin: state.origin, index: 3, note: note(state, 3))
        let replacementNotes = await store.notes()
        try check(replacementNotes.count == 4 && !replacementNotes.contains { $0.sourceID == old.sourceID }, "completed force-initial replaces old pending notes once")

        let stale = try await store.beginGmailRead(initial())
        let changed = try await store.beginGmailRead(initial("fixture:1"))
        try check(changed.id != stale.id, "new origin starts distinct import")
        do {
            _ = try await store.commitGmailWindow(stateID: stale.id, origin: stale.origin, index: 0, note: note(stale, 0))
            throw TestFailure.message("Stale import result committed")
        } catch MCPSource.MCPError.connectionChanged {} catch { throw error }
        let afterStale = try await store.gmailReadState()
        try check(afterStale?.id == changed.id && afterStale?.completed.isEmpty == true,
                  "stale callback cannot mutate replacement import")

        let gate = QueueGate()
        let holder = Task.detached { await store.holdForFixture(gate) }
        await Task.detached { waitForGate(gate) }.value
        let queued = Task { try await store.commitGmailWindow(stateID: changed.id, origin: changed.origin, index: 0, note: note(changed, 0)) }
        queued.cancel()
        gate.release.signal()
        await holder.value
        do { _ = try await queued.value; throw TestFailure.message("Cancelled queued commit succeeded") }
        catch is CancellationError {} catch { throw error }
        try check(try await store.gmailReadState()?.completed.isEmpty == true, "cancelled queued transaction writes nothing")

        // Returning old-origin results while the account changes must not stamp the new origin.
        let oldGate = QueueGate()
        let held = Task.detached { await store.holdForFixture(oldGate) }
        await Task.detached { waitForGate(oldGate) }.value
        let admitted = Task { try await store.commitGmailWindow(stateID: changed.id, origin: changed.origin, index: 0, note: note(changed, 0)) }
        Origin.shared.set("fixture:2")
        oldGate.release.signal(); await held.value
        _ = try await admitted.value
        let retained = try await store.gmailReadState()
        try check(retained?.origin == "fixture:1" && retained?.completed == [0], "queued commit retains captured origin after account changes")
        let latest = try await store.beginGmailRead(initial("fixture:2"))
        try check(latest.id != changed.id && latest.completed.isEmpty, "new account backfills despite late old-account commit")
        Origin.shared.set("fixture:0")

        // A partial force-initial read can already have delivered its accepted notes to the vault.
        let replacement = try await store.beginGmailRead(initial(replace: true))
        for index in [0, 1] { _ = try await store.commitGmailWindow(stateID: replacement.id, origin: replacement.origin, index: index, note: note(replacement, index)) }
        await store.wipeNotes(sourceIDs: Set([replacement.sourceID(for: 0), replacement.sourceID(for: 1)]))
        for index in [2, 3] { _ = try await store.commitGmailWindow(stateID: replacement.id, origin: replacement.origin, index: index, note: note(replacement, index)) }
        let afterReplacement = await store.notes()
        try check(Set(afterReplacement.map(\.sourceID)) == Set([replacement.sourceID(for: 2), replacement.sourceID(for: 3)]),
                  "final force-initial replacement never recreates already consumed windows")
    }
    static func origins(_ store: CycleStore) async throws {
        for backend in [ModelBackend.chatgpt, .claude] {
            BackendPreference.shared.set(backend)
            for explicit in [true, false] {
                await store.clearBucket("gmail")
                Origin.shared.set("fixture:0")
                let state = try await store.beginGmailRead(initial())
                await ReadProbe.shared.reset(.originChange, windows: state.windows)
                do {
                    _ = explicit ? try await GmailConnect.runInitial() : try await GmailConnect.runIterative()
                    throw TestFailure.message("Origin change accepted")
                } catch MCPSource.MCPError.connectionChanged {}
                try check(try await store.gmailReadState()?.completed.isEmpty == true, "\(backend) pending origin change cannot certify a window")
                let events = ProcessingSpy.shared.snapshot()
                try check(events.first?.kind == "hook" && events.filter { $0.kind == "hook" }.count == 1,
                          "\(backend) \(explicit ? "initial" : "iterative") calls setup hook once before reads")
                try check(events.allSatisfy { $0.backend == backend && $0.pinned }, "\(backend) entrypoint pins its own backend across hook and workers")
                let newState = try await store.beginGmailRead(initial("fixture:new"))
                await ReadProbe.shared.reset(.success, windows: newState.windows)
                _ = try await GmailConnect.runIterative()
                try check(await ReadProbe.shared.stats().calls.count == 4, "\(backend) changed account receives complete fresh coverage")
                try check(try await store.mcpCheckpoint("gmail")?.origin == "fixture:new", "\(backend) fresh account completion owns the new watermark")
            }
        }
        BackendPreference.shared.set(.chatgpt); Origin.shared.set("fixture:0")
    }
    static func pipeline(_ store: CycleStore) async throws {
        var state = try await store.beginGmailRead(initial())
        await ReadProbe.shared.reset(.oneFailure, windows: state.windows)
        let partialProgress = ProgressSpy()
        do { _ = try await GmailConnect.runIterative(onProgress: { partialProgress.record($0) }); throw TestFailure.message("Failed week reported full success") }
        catch let failure as TestFailure { throw failure } catch {}
        var observed = await ReadProbe.shared.stats()
        try check(observed.maximum == 2, "at most two Gmail windows execute concurrently")
        try check(Set(observed.calls) == Set(0..<4), "non-auth failure does not abandon healthy windows")
        try check(try await store.gmailReadState()?.completed == [1, 2, 3], "healthy windows survive failed sibling")
        try check(await store.notes().count == 2, "useful summaries are persisted and quiet coverage creates no note")
        let completed = partialProgress.snapshot()
        try check(completed.count == 3 && completed.last?.completed == 3 && completed.last?.kept == 2
            && completed.filter { $0.summary == nil }.count == 1,
                  "partial pipeline emits completion only for two saved summaries and one covered quiet window")
        await store.wipeNotes(sourceIDs: Set((await store.notes()).map(\.sourceID)))
        await ReadProbe.shared.reset(.success, windows: state.windows)
        _ = try await GmailConnect.runIterative()
        observed = await ReadProbe.shared.stats()
        try check(observed.calls == [0], "retry reads only incomplete window after prior notes were consumed")
        try check(await store.notes().count == 1, "retry does not duplicate consumed summaries")
        try check(try await store.mcpCheckpoint("gmail")?.mark.order == state.through.timeIntervalSince1970, "resumed reader keeps original cutoff")

        state = try await store.beginGmailRead(initial(at: through.addingTimeInterval(86_400)))
        await ReadProbe.shared.reset(.auth, windows: state.windows)
        do { _ = try await GmailConnect.runInitial(); throw TestFailure.message("Auth failure reported success") }
        catch MCPSource.MCPError.connectorAuth {} catch { throw error }
        observed = await ReadProbe.shared.stats()
        try check(observed.calls.count == 2, "auth failure halts scheduling untouched windows")

        await ReadProbe.shared.reset(.success, windows: state.windows)
        await store.failNextMCPCommitForTesting()
        let failedSaveProgress = ProgressSpy()
        do { _ = try await GmailConnect.runIterative(onProgress: { failedSaveProgress.record($0) }); throw TestFailure.message("Storage failure reported success") }
        catch let failure as TestFailure { throw failure }
        catch { try check(DiskSpace.isDiskFull(error), "pipeline surfaces disk-full instead of treating it as a bad week") }
        try check(await ReadProbe.shared.stats().calls.count == 2, "storage failure halts scheduling untouched windows")
        try check(try await store.gmailReadState()?.completed.isEmpty == true, "storage failure publishes no misleading completed windows")
        try check(failedSaveProgress.snapshot().isEmpty, "failed transaction never emits a saved-window progress event")

        await ReadProbe.shared.reset(.cancel, windows: state.windows)
        let running = Task { try await GmailConnect.runIterative() }
        for _ in 0..<100 where await ReadProbe.shared.stats().calls.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        try check(await ReadProbe.shared.stats().calls.count == 2, "cancel fixture reaches both active workers")
        running.cancel()
        do { _ = try await running.value; throw TestFailure.message("Cancelled import succeeded") }
        catch is CancellationError {} catch { throw error }
        try check(try await store.gmailReadState()?.completed.isEmpty == true, "cancelled active import keeps all unfinished windows retryable")

        await ReadProbe.shared.reset(.accountLimit, windows: state.windows)
        do { _ = try await GmailConnect.runIterative(); throw TestFailure.message("Account limit reported success") }
        catch ConnectorReadFailure.GmailFailure.accountLimit {} catch { throw error }
        observed = await ReadProbe.shared.stats()
        try check(Set(observed.calls) == [0, 1, 2], "account limit stops untouched windows and cancels active siblings")
        try check(try await store.gmailReadState()?.completed == [0], "account limit retains the earlier committed window")
        try check((await store.notes()).contains { $0.sourceID == state.sourceID(for: 0) }, "summary committed before account limit remains available downstream")
    }
    nonisolated static func waitForGate(_ gate: QueueGate) { gate.entered.wait() }
}
