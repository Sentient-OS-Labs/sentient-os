// Controlled native, model and storage boundaries for the real Calendar run and parser.
import Foundation

enum FixtureError: Error { case reload }
enum ChatWindowing { static func clampToContext(_ text: String) -> String { text } }
struct ItemKey: Sendable { let date: Date; let tiebreak: String }
struct NoteDraft: Sendable {
    let kind: SourceKind; let sourceID: String; let folder: String; let itemDate: Date
    let text: String; let title: String?; let reminderFlagged: Bool
}
nonisolated enum AppleCalendarSource {
    enum ReadError: Error { case changed, invalidEvent }
    enum Issue { case incomplete, model, storage, deadline }
    nonisolated(unsafe) static var selectedIDs: Set<String> = ["fixture-calendar"]
    static let bucketKey = "apple-calendar"
    static let issueKey = "unused-fixture-key"
    nonisolated(unsafe) static var issue: String?
    nonisolated(unsafe) static var counts: (Int, Int)?
    nonisolated(unsafe) static var changed = false
    nonisolated(unsafe) static var hasAccess = true
    nonisolated(unsafe) static var events: [Event] = []
    struct Event: Sendable {
        let id: String; let title: String; let notes: String
        var revision = "fixture-v1"
        let start = Date(timeIntervalSince1970: 1_792_000_000)
        var schedule: String { "Start: fixture; status: tentative; response: declined." }
        var content: String { candidate.metadata["calendarText"]! }
        var candidate: Candidate {
            let fields = ["title": title, "notes": notes, "location": "", "schedule": schedule]
            let text = String(decoding: try! JSONEncoder().encode(fields), as: UTF8.self)
            return Candidate(id: id, kind: .appleCalendar, itemDate: start,
                             metadata: ["calendarText": text])
        }
    }
    struct Coverage: Codable, Equatable, Sendable { var scope = "fixture-window" }
    struct Snapshot: Sendable {
        let events: [Event]
        var coverage = Coverage()
        func validate() throws { if changed || !hasAccess { throw ReadError.changed } }
    }
    static func capture(ids: Set<String>) throws -> Snapshot {
        guard ids == selectedIDs, hasAccess else { throw ReadError.changed }
        return Snapshot(events: events)
    }
    static func recordIssue(_ issue: Issue, attempted: Int? = nil, failed: Int? = nil) {
        self.issue = String(describing: issue)
        counts = attempted.flatMap { a in failed.map { (a, $0) } }
    }
    static func recordIssue(_ error: Error? = nil) { issue = error == nil ? "incomplete" : "changed"; counts = nil }
    static func clearIssue() { issue = nil; counts = nil }
    static func issueMessage(_ code: String) -> String? { code }
}
actor CycleStore {
    static let shared = CycleStore()
    enum Outcome { case saved, diskFull, failed }
    var result: Outcome = .saved
    var cacheResult: Outcome = .saved
    var retryCache: CalendarRetryCache?
    var commits = 0
    var saved: [NoteDraft] = []
    func invalidateCalendarSnapshot() { saved = [] }
    func calendarRetryCache(for snapshot: AppleCalendarSource.Snapshot) throws -> CalendarRetryCache {
        var cache = retryCache ?? CalendarRetryCache(coverage: snapshot.coverage)
        if cache.coverage != snapshot.coverage || cache.version != 1 {
            cache = CalendarRetryCache(coverage: snapshot.coverage)
        }
        cache.validate(against: snapshot)
        return cache
    }
    func saveCalendarRetryCache(_ cache: CalendarRetryCache) -> Outcome {
        guard cacheResult == .saved else { return cacheResult }
        retryCache = cache
        return .saved
    }
    func commitCalendarSnapshot(_ snapshot: AppleCalendarSource.Snapshot, notes: [NoteDraft]) -> Outcome {
        commits += 1
        guard result == .saved, !Task.isCancelled else { return result == .diskFull ? .diskFull : .failed }
        saved = notes
        return .saved
    }
    func setResult(_ value: Outcome) { result = value }
    func setCacheResult(_ value: Outcome) { cacheResult = value }
}
actor Engine {
    struct Result { let text: String; let totalTime: Double }
    var replies: [String: [String]]
    var calls: [String: [Int]] = [:]
    var prompts: [String: [String]] = [:]
    var reloads = 0
    let failReload: Bool
    let cancelReload: Bool
    let changeOnCall: Bool
    let revokeOnCall: Bool
    let cancelOnCall: Bool
    init(_ replies: [String: [String]] = [:], failReload: Bool = false, cancelReload: Bool = false,
         changeOnCall: Bool = false, revokeOnCall: Bool = false, cancelOnCall: Bool = false) {
        self.replies = replies; self.failReload = failReload; self.cancelReload = cancelReload
        self.changeOnCall = changeOnCall; self.revokeOnCall = revokeOnCall; self.cancelOnCall = cancelOnCall
    }
    func generate(prompt: String, imageData: Data? = nil, samplingSeed: Int = 0) async throws -> Result {
        if cancelOnCall { throw CancellationError() }
        if changeOnCall { AppleCalendarSource.changed = true }
        if revokeOnCall { AppleCalendarSource.hasAccess = false }
        let id = AppleCalendarSource.events.first { prompt.contains($0.title) }!.id
        let index = calls[id, default: []].count
        calls[id, default: []].append(samplingSeed); prompts[id, default: []].append(prompt)
        let options = replies[id] ?? [Harness.valid]
        return Result(text: options[min(index, options.count - 1)], totalTime: 1)
    }
    func reload() async throws {
        reloads += 1
        if cancelReload { throw CancellationError() }
        if failReload { throw FixtureError.reload }
    }
}
struct IterativeRun {
    let store: CycleStore
    static let preemptiveReloadEvery = 40
    static let extractionTimeoutSeconds = 30.0
    nonisolated(unsafe) static var sourceTimeCapSeconds = 3600.0
}
nonisolated enum LifetimeStats {
    nonisolated(unsafe) static var calls = 0
    static func bump(_ verdict: Verdict) { calls += 1 }
}
nonisolated enum SourceHealth {
    nonisolated(unsafe) static var outcomes: [String] = []
    static func recordReadOutcome(source: String, outcome: String) { outcomes.append(outcome) }
}
enum Diagnostics {
    enum Phase { case snapshot, extract, generate, parse, validate, commit }
    enum Event { case modelOutputInvalid, sourceReadFailed, sourceReadDegraded }
    enum Count: Hashable { case bytes, retries, attempted, failed }
    enum Flag: Hashable { case retriable, partial, previousStateRetained }
    static func report(_ event: Event, phase: Phase, reason: String = "", error: Error? = nil,
                       source: String, counts: [Count: Int] = [:], flags: [Flag: Bool] = [:], terminal: Bool = false) {}
}
func Log(_ message: String) {}
func withExtractionTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () throws -> T) async throws -> T { try work() }

@main struct Harness {
    static let valid = #"{"junk":false,"sensitive":false,"summary":"A planning review is scheduled.","title":"Planning review"}"#
    static let invalidJSON = "malformed model response"
    static let invalidFields = #"{"junk":false,"summary":"Planning review","title":"Planning"}"#
    static func check(_ name: String, _ value: Bool) {
        guard value else { fatalError("FAIL \(name)") }
        print("PASS \(name)")
    }
    static func reset(_ events: [AppleCalendarSource.Event]? = nil) {
        AppleCalendarSource.events = events ?? [
            .init(id: "a", title: "fixture-alpha-review", notes: "Review the product plan."),
            .init(id: "b", title: "fixture-beta-review", notes: "Review the launch plan.")
        ]
        AppleCalendarSource.changed = false; AppleCalendarSource.hasAccess = true
        AppleCalendarSource.clearIssue(); LifetimeStats.calls = 0
        SourceHealth.outcomes = []
        IterativeRun.sourceTimeCapSeconds = 3600
    }
    static func run(_ engine: Engine, store: CycleStore = CycleStore()) async -> (RunProgress, CycleStore) {
        let p = await IterativeRun(store: store).runCalendar(
            AppleCalendarConnector(calendarIDs: AppleCalendarSource.selectedIDs), engine: engine, onProgress: { _ in })
        return (p, store)
    }
    static func main() async throws {
        reset()
        let artifact = try AppleCalendarConnector(calendarIDs: AppleCalendarSource.selectedIDs).load(AppleCalendarSource.events[0].candidate)
        let rejects: [(String, String, Triage.ReplyFailure)] = [
            ("empty", "", .empty), ("prose", "Here is the answer: " + valid, .invalidJSON),
            ("missing flag", invalidFields, .invalidFields),
            ("string flag", valid.replacingOccurrences(of: "\"sensitive\":false", with: "\"sensitive\":\"false\""), .invalidFields),
            ("duplicate flag", valid.replacingOccurrences(of: "\"junk\":false", with: "\"junk\":true,\"junk\":false"), .invalidFields),
            ("empty preview", valid.replacingOccurrences(of: "A planning review is scheduled.", with: ""), .emptySummary),
        ]
        for (name, text, reason) in rejects {
            if case .failure(let actual) = Triage.calendarReply(text, for: artifact) { check("reject \(name)", actual == reason) }
            else { fatalError("FAIL accepted \(name)") }
        }
        let flags = #"{"junk":false,"sensitive":true,"summary":"","title":""}"#
        if case .success(let outcome) = Triage.calendarReply(flags, for: artifact) {
            check("sensitive outcome has no preview", outcome.verdict == .sensitive && outcome.summary.isEmpty && outcome.title == nil)
        } else { fatalError("FAIL valid sensitive response") }

        reset()
        let recovered = Engine(["b": [invalidJSON, invalidFields, valid]])
        let (p, store) = await run(recovered)
        let calls = await recovered.calls, prompts = await recovered.prompts, saved = await store.saved
        let commits = await store.commits
        check("recovery publishes complete snapshot once", p.failed == 0 && p.survivors == 2 && saved.count == 2 && commits == 1)
        check("completed event never regenerated", calls["a"] == [0])
        check("failed event uses distinct bounded seeds", calls["b"] == [0, 1, 2])
        check("feedback tracks latest failure", prompts["b"]![1].contains("not one valid JSON") && prompts["b"]![2].contains("missing, duplicate or mistyped"))
        check("recovery rebuilds engine", await recovered.reloads == 1)
        check("progress counts events once", p.done == 2 && p.total == 2 && p.totalSeconds == 4)
        check("committed schedule preserved", saved.allSatisfy { $0.text.hasSuffix("status: tentative; response: declined.") })
        check("only committed verdicts counted", LifetimeStats.calls == 2 && AppleCalendarSource.issue == nil)
        check("successful recovery preserves source health", SourceHealth.outcomes == ["incomplete", "ok"])

        reset()
        let persistent = Engine(["b": [invalidJSON]])
        let (failed, failedStore) = await run(persistent)
        check("persistent failure never publishes partial notes", await failedStore.commits == 0 && failed.survivors == 0)
        check("unresolved count is final and precise", failed.failed == 1 && failed.parseFailures == 1 && failed.done == 2 && AppleCalendarSource.counts?.0 == 2 && AppleCalendarSource.counts?.1 == 1)
        check("failed snapshot adds no lifetime verdicts", LifetimeStats.calls == 0)
        check("retries stop after three attempts", await persistent.calls["b"] == [0, 1, 2])
        let retained = await failedStore.retryCache
        check("incomplete run retains only accepted survivor for retry", retained?.survivors.count == 1 && retained?.survivors["a"] != nil)
        check("incomplete recovery keeps source health incomplete", SourceHealth.outcomes == ["incomplete"])
        let resumed = Engine()
        let (resumedProgress, _) = await run(resumed, store: failedStore)
        let resumedCalls = await resumed.calls
        check("later run reuses accepted survivor and generates only unresolved event", resumedProgress.survivors == 2 && resumedCalls["a"] == nil && resumedCalls["b"] == [0])

        reset()
        let revisionStore = CycleStore()
        _ = await run(Engine(["b": [invalidJSON]]), store: revisionStore)
        AppleCalendarSource.events[0].revision = "fixture-v2"
        let edited = Engine()
        let (editedProgress, _) = await run(edited, store: revisionStore)
        let editedCalls = await edited.calls
        check("edited survivor is reanalyzed instead of reusing stale summary", editedProgress.survivors == 2 && editedCalls["a"] == [0])

        reset()
        let sensitiveRetryStore = CycleStore()
        _ = await run(Engine(["b": [invalidJSON]]), store: sensitiveRetryStore)
        // Deliberately retain the revision to exercise privacy pruning independently of hashing.
        AppleCalendarSource.events[0] = .init(id: "a", title: "fixture-alpha-review", notes: "Password: synthetic-only-value")
        let privateRetry = Engine()
        let (privateProgress, _) = await run(privateRetry, store: sensitiveRetryStore)
        let privateCache = await sensitiveRetryStore.retryCache, privateSaved = await sensitiveRetryStore.saved
        let privateRetryCalls = await privateRetry.calls
        check("newly sensitive survivor is purged from retry cache before reuse", privateCache?.survivors["a"] == nil && privateProgress.sensitive == 1)
        check("newly sensitive cached event bypasses model and final notes", privateRetryCalls["a"] == nil && privateSaved.allSatisfy { $0.sourceID != "a" })

        reset()
        let cacheStore = CycleStore(); await cacheStore.setCacheResult(.failed)
        let cacheEngine = Engine()
        let (cacheFailed, _) = await run(cacheEngine, store: cacheStore)
        let cacheCalls = await cacheEngine.calls, cacheCommits = await cacheStore.commits
        check("failed cache pruning prevents generation and publication", cacheCalls.isEmpty && cacheCommits == 0 && cacheFailed.survivors == 0 && AppleCalendarSource.issue == "storage")

        for (name, engine) in [
            ("changed snapshot", Engine(changeOnCall: true)),
            ("revoked permission", Engine(revokeOnCall: true)),
            ("cancelled generation", Engine(cancelOnCall: true)),
            ("cancelled recovery", Engine(["b": [invalidJSON]], cancelReload: true)),
            ("failed recovery", Engine(["b": [invalidJSON]], failReload: true)),
        ] {
            reset()
            let (result, store) = await run(engine)
            check("\(name) prevents publication", await store.commits == 0 && result.survivors == 0 && LifetimeStats.calls == 0)
        }
        reset()
        let diskStore = CycleStore(); await diskStore.setResult(.diskFull)
        let (disk, diskResult) = await run(Engine(), store: diskStore)
        let diskNotes = await diskResult.saved
        check("failed storage saves no notes or lifetime verdicts", disk.diskFull && disk.survivors == 0 && LifetimeStats.calls == 0 && diskNotes.isEmpty)
        reset([])
        let (empty, emptyStore) = await run(Engine())
        let emptyCommits = await emptyStore.commits
        check("empty calendar commits complete empty coverage", empty.quietReads == 1 && emptyCommits == 1 && empty.successfulSources.contains("Apple Calendar"))
        reset()
        IterativeRun.sourceTimeCapSeconds = -1
        let (deadline, deadlineStore) = await run(Engine())
        check("deadline prevents publication", await deadlineStore.commits == 0 && deadline.survivors == 0 && AppleCalendarSource.issue == "deadline")
        reset([.init(id: "secret", title: "fixture-access-review", notes: "Password: synthetic-only-value")])
        let privateEngine = Engine()
        let (sensitive, sensitiveStore) = await run(privateEngine)
        let privateCalls = await privateEngine.calls, privateNotes = await sensitiveStore.saved
        check("credentials bypass model and never enter notes", sensitive.sensitive == 1 && privateCalls.isEmpty && privateNotes.isEmpty)
        print("Calendar regression suite complete")
    }
}
