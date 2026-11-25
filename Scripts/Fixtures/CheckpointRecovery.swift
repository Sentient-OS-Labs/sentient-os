// Synthetic providers for the real ingestion/store/proactive-cycle regression suite.
// All filesystem and preference access is confined to the runner's temporary fixture root.
import Foundation
import SwiftData

nonisolated enum Fixture {
    static let root = URL(fileURLWithPath: CommandLine.arguments[2])
    static let state = State()
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var counters: [String: Int] = [:]
        private var options = Set<String>()
        func count(_ name: String) -> Int { lock.withLock { counters[name, default: 0] } }
        func increment(_ name: String) { lock.withLock { counters[name, default: 0] += 1 } }
        func set(_ name: String, _ enabled: Bool) { lock.withLock { if enabled { options.insert(name) } else { options.remove(name) } } }
        func has(_ name: String) -> Bool { lock.withLock { options.contains(name) } }
        func take(_ name: String) -> Bool { lock.withLock { options.remove(name) != nil } }
    }
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message); state.increment("checks"); print("PASS " + message)
    }
}
nonisolated final class UserDefaults: @unchecked Sendable {
    static let standard = UserDefaults()
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func set(_ value: Any, forKey key: String) { lock.withLock { values[key] = value } }
    func removeObject(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
    func string(forKey key: String) -> String? { lock.withLock { values[key] as? String } }
}
extension URL { nonisolated static var sentientSupport: URL { Fixture.root } }
nonisolated struct AppleMailCheckpoint: Codable { var version = 2 }
nonisolated enum AppleMailError: Error { case unsupportedSchema }
nonisolated enum AppleMailHealth { static let key = "fixture.mail" }
nonisolated enum AppleCalendarSource {
    static let bucketKey = "apple-calendar"
    static let isEnabled = false
    struct Coverage: Codable, Equatable {
        var encoded: String { "fixture" }; var matchesSelection: Bool { false }
        static func decode(_ value: String) -> Self? { nil }
    }
    struct Snapshot: Sendable {
        let capturedAt: Date; let coverage: Coverage
        var marker: NoteDraft { fatalError("Calendar is outside this fixture") }
        func partialMarker(pending: Int) -> NoteDraft { fatalError("Calendar is outside this fixture") }
    }
    enum ReadError: Error { case changed }
    enum Issue { case model }; static func recordIssue(_ issue: Issue? = nil) {}
}
nonisolated struct CalendarRetryCache: Codable {
    var version = 1; var coverage: AppleCalendarSource.Coverage
    mutating func validate(against: AppleCalendarSource.Snapshot) {}
}
nonisolated enum DiskSpace {
    static let runFloor: Int64 = 0
    static func available() -> Int64? { nil }
    static func isDiskFull(_ error: Error) -> Bool { (error as NSError).code == NSFileWriteOutOfSpaceError }
}
nonisolated enum Diagnostics {
    final class Operation: @unchecked Sendable { var hasFailure: Bool { Fixture.state.has("diagnosticFailed") } }
    static let current: Operation? = Operation()
    enum Event { case storeReadFailed, cleanupFailed, sourceReadFailed, sourceReadDegraded, ingestionSkipped, engineReloadFailed, cycleIncomplete, vaultFailed, modelOutputInvalid }
    enum Phase { case read, reset, enumerate, complete, reload, extract, generate, publish, judge, prepare }
    enum Count { case failed, skipped, attempted }
    enum Flag { case partial }
    static func report(_ event: Event, phase: Phase, reason: String = "", error: Error? = nil, source: String? = nil,
                       counts: [Count: Int] = [:], flags: [Flag: Bool] = [:], terminal: Bool = false) { Fixture.state.set("diagnosticFailed", true) }
    static func errorFields(_ error: Error) -> [String: String] { [:] }
    static func isExpected(_ error: Error) -> Bool { false }
    static func withOperation(_ name: String, _ body: () async -> CycleFailure?) async -> CycleFailure? { await body() }
    static func withOperation<T>(_ name: String, propagatesFailure: Bool = true,
                                 _ body: () async -> T) async -> T { await body() }
}
nonisolated enum CrashReporting {
    enum Level { case error, warning }
    static func captureEvent(_ name: String, level: Level, tags: [String: String] = [:], extra: [String: String] = [:], fingerprint: [String] = []) { Fixture.state.set("diagnosticFailed", true) }
    static func diagnosticBreadcrumb(_ name: String, data: [String: String]) {}
}
nonisolated enum Analytics {
    enum Tier { case core }
    static func signal(_ name: String, parameters: [String: String] = [:], floatValue: Double? = nil, tier: Tier? = nil) { Fixture.state.increment(name) }
}
nonisolated enum SourceHealth {
    static func checkListingCollapse(source: String, bucketKey: String, count: Int) {}
    static func recordReadOutcome(source: String, outcome: String) {}
    static func recordTriage(source: String, failed: Bool) {}
    static func recordExtraction(succeeded: Bool, format: String) {}
    static func checkExtractionRate() {}
}
nonisolated enum PipelineActivity { static func begin() {}; static func end() {} }
nonisolated enum Permissions { static func reportProbe() { fatalError("Only selected synthetic file sources may run") } }
nonisolated enum ModelLocator { static func resolve() -> String? { "synthetic" } }
nonisolated enum Verdict: Sendable { case survivor, junk, sensitive }
nonisolated enum LifetimeStats { static func bump(_ verdict: Verdict) {} }
nonisolated struct ChatSelectionReadError: Error {}
nonisolated enum Triage {
    enum Reason { case valid, parseFailed, emptySummary }
    struct Decision { let verdict: Verdict; let reason: Reason; let title: String; let summary: String }
    static func prompt(for artifact: Artifact, currentDate: Date) -> String { artifact.id }
    static func decide(_ text: String, for artifact: Artifact) -> Decision {
        .init(verdict: Fixture.state.has("junk") ? .junk : .survivor, reason: .valid,
              title: "Synthetic summary", summary: "Safe synthetic project context")
    }
}
actor Engine {
    struct Reply { let text: String; let totalTime: Double }
    enum Failure: Error { case synthetic }
    init(modelPath: String, maxNumTokens: Int) {}
    func load() async throws {}; func unload() async {}; func reload() async throws {}
    func generate(prompt: String, imageData: Data?) async throws -> Reply {
        Fixture.state.increment("inferences")
        if Fixture.state.has("slow") { try await Task.sleep(for: .seconds(30)) }
        if Fixture.state.has("inferenceFailure") { throw Failure.synthetic }
        return .init(text: "synthetic", totalTime: 0)
    }
}
struct AppleMailConnector: Connector {
    let kind = SourceKind.appleMail
    func buckets(since: [String: ItemKey]) throws -> [Bucket] { fatalError("No mail access") }
    func load(_ item: Candidate) throws -> Artifact { fatalError("No mail access") }
}
struct AppleCalendarConnector: Connector {
    let kind = SourceKind.appleCalendar
    func buckets(since: [String: ItemKey]) throws -> [Bucket] { fatalError("No calendar access") }
    func load(_ item: Candidate) throws -> Artifact { fatalError("No calendar access") }
}
extension IterativeRun {
    func runMail(_ c: AppleMailConnector, engine: Engine, onProgress: @Sendable (RunProgress) -> Void) async -> RunProgress { fatalError("No mail access") }
    func runCalendar(_ c: AppleCalendarConnector, engine: Engine, onProgress: @Sendable (RunProgress) -> Void) async -> RunProgress { fatalError("No calendar access") }
}
nonisolated enum MCPSource { enum MCPError: Error { case connectionChanged, storageFailure } }
nonisolated enum GoogleSourceRead { enum Failure: Error { case storage } }
nonisolated enum CodexFailureReason: String, Sendable { case unknown; static func classify(_ error: Error) -> Self { .unknown } }
nonisolated enum ModelBackend { case chatgpt, sentient; @TaskLocal static var current = Self.chatgpt }
nonisolated enum CodexAuth { static let knowledgeBaseOnly = false }
nonisolated enum AppleMailEvidence { static func validated(_ notes: [CycleNoteItem]) async -> [CycleNoteItem] { notes } }
nonisolated enum Notify { static func connectorsUnavailable(_ slugs: Set<String>) async {} }
nonisolated enum ProcessingPlan { static func initialCompletedAt() -> Date? { nil }; static func completeInitial(_ defaults: UserDefaults) { Fixture.state.increment("initialCompleted") } }
nonisolated enum WritingStyle { static func exists() -> Bool { true }; static func collect() async throws -> String { "" }; static func publishIfNeeded(_ content: String) throws {} }
nonisolated enum OvernightCaution { enum Kind: Sendable { case unexpected, diskFull }; static func classify(_ error: Error) async -> Kind? { nil }; static func record(_ kind: Kind?) {}; static func clear() {} }
nonisolated enum CalendarContext {
    struct Result: Sendable { var hasOutlookEvents = false; var outlookComplete = false; var text: String?; var includesOutlook = false }
    static let outlookEnabled = false
    static func fetch(excluding: Set<String>) async throws -> Result { Result() }
}
actor GiftLetter {
    static let shared = GiftLetter()
    static func needsWelcome() -> Bool { false }; static func latest() -> String? { nil }
    static func retire() {}; static func clear() {}
    func generate(onLine: (@Sendable (String) -> Void)?) async throws -> String { "" }
}
nonisolated enum VaultGenerator {
    enum Progress: Sendable { case folding(part: Int, of: Int) }
    static var vaultRoot: URL { Fixture.root.appendingPathComponent("Vault") }
}
actor VaultCloud {
    static let shared = VaultCloud()
    private(set) var lastConsumedInputIDs = Set<String>()
    func update(notes: [CloudNote], onProgress: @Sendable (VaultGenerator.Progress) -> Void,
                onLine: (@Sendable (String) -> Void)?) async throws -> Int {
        if Fixture.state.has("writerFailure") { throw Engine.Failure.synthetic }
        Fixture.state.increment("writes")
        let root = VaultGenerator.vaultRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Synthetic published knowledge".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        lastConsumedInputIDs = try VaultInput.identities(notes.map(\.vaultInput))
        if Fixture.state.take("newVersionDuringWrite") {
            let first = notes[0]
            await CycleStore.shared.recordNote(bucketKey: "later", kind: first.kind, sourceID: first.sourceID,
                folder: first.folder, itemDate: Date(timeIntervalSince1970: 9), text: "New unconsumed version",
                title: first.title, reminderFlagged: false)
        }
        return notes.count
    }
    func create(notes: [CloudNote], onProgress: @Sendable (VaultGenerator.Progress) -> Void,
                onLine: (@Sendable (String) -> Void)?) async throws -> Int { try await update(notes: notes, onProgress: onProgress, onLine: onLine) }
    static func pushIfDirty() async { Fixture.state.increment("mirror") }
}
nonisolated struct ActionItem: Sendable { enum Urgency: Sendable { case high, medium, low } }
nonisolated struct ReadyAction: Sendable { let id = "fixture"; let urgency = ActionItem.Urgency.high; var calendarContextOnly: Bool? = false }
nonisolated struct ReadyResult: Sendable { let ready: [ReadyAction]; let dropped: [String] }
actor Proactive {
    static let shared = Proactive()
    enum ProError: Error { case noRecent, synthetic }
    static func clear() {}; static func recent(from notes: [CloudNote]) -> [CloudNote] { notes }
    func findActionItems(from notes: [CloudNote], calendarContext: String?, allowCalendarOnly: Bool,
                         calendarContextScoped: Bool, onLine: (@Sendable (String) -> Void)?) async throws -> [ActionItem] {
        Fixture.state.increment("judges")
        if Fixture.state.take("judgeFailure") { throw ProError.synthetic }
        return [ActionItem()]
    }
}
actor ProactiveResearch {
    static let shared = ProactiveResearch(); static let maxReady = 5
    static func latest() -> ReadyResult? { nil }; static func saveLatest(_ result: ReadyResult) {}; static func clear() {}
    func researchAndPrepare(items: [ActionItem], notes: [CloudNote], calendarContext: String?, calendarContextScoped: Bool,
                            persistResult: Bool, unavailableConnectors: Set<String>, onLine: (@Sendable (String) -> Void)?) async throws -> ReadyResult {
        Fixture.state.increment("research"); return .init(ready: [ReadyAction()], dropped: [])
    }
}
nonisolated func Log(_ text: String) {}
nonisolated func ErrorLabel(_ error: Error) -> String { String(describing: type(of: error)) }
