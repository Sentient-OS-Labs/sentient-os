#!/usr/bin/env python3
"""Exercise actual production analysis admission, execution boundaries and completion policy.
All sources, providers, model reads and proactive operations are synthetic. Preferences use a
unique suite, and knowledge artifacts live only inside the temporary fixture directory.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'


def member(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


run = (APP / 'Ingestion/ProcessingRun.swift').read_text()
coordinator = (APP / 'Ingestion/ProcessingCoordinator.swift').read_text()
progress = (APP / 'Ingestion/RunProgress.swift').read_text()
plan = (APP / 'Ingestion/ProcessingPlan.swift').read_text()
chats = (APP / 'Sources/ChatWindowing.swift').read_text()
gmail = (APP / 'Sources/GmailConnect.swift').read_text()
connector_failure = (APP / 'Sources/ConnectorReadFailure.swift').read_text()

fixture = r'''
import Foundation

enum Verdict { case survivor, junk }
enum CodexTrigger { case onboarding, analyzeNow, overnight }
struct CycleFailure: Error, Equatable {
    enum Stage { case vault, deciding, preparing }
    var message = ""
    var kind: OvernightCaution.Kind? = nil
    var stage: Stage = .vault
    var reason: CodexFailureReason? = nil
}
protocol Connector {}
struct FixtureConnector: Connector {}
struct RunSource {
    static func connectors(from sources: [RunSource]) -> [any Connector] { sources.isEmpty ? [] : [FixtureConnector()] }
}
enum ModelBackend { case chatgpt, claude, custom, sentient; static var current: Self = .chatgpt }
enum ClaudeAuth {
    static var requiresVerification = false
    static var rejectDuringGmail = false
    struct LoginRequired: LocalizedError { var errorDescription: String? { "Fixture sign-in required" } }
}
enum ConnectorCensus {
    static var identity: String? = "fixture"
    static var outcomes: [(String, ModelBackend, Bool)] = []
    static func readinessAccountIdentity(for backend: ModelBackend) -> String? { identity }
    static func recordReadOutcome(slug: String, backend: ModelBackend, connected: Bool) {
        outcomes.append((slug, backend, connected))
    }
}
enum ModelLocator {
    static var calls = 0
    static func resolve() -> String? { calls += 1; return nil }
}
enum SourceSelection {
    static let minimumSelections = 3
    static var local: [RunSource] = []
    static var gmail = true, calendar = true
    struct Ready { let slug: String }
    static var readyConnectors = [Ready(slug: "drive")]
    static var unavailableSourceMessages: [String: String] = [:]
    static var unavailableConnectorSlugs: Set<String> = []
    static func current() -> [RunSource] { local }
    static func hostedSourceReady(_ source: String) -> Bool { source == "gmail" ? gmail : calendar }
    static func hostedSourceCanAttempt(_ source: String) -> Bool { hostedSourceReady(source) }
    static var connectorsToAttempt: [Ready] { readyConnectors }
    static var selectionCount: Int { local.count + (gmail ? 1 : 0) + (calendar ? 1 : 0) + readyConnectors.count }
}
enum Diagnostics {
    enum Event { case sourceReadFailed }
    enum Phase { case read }
    final class Operation { var hasFailure = false }
    static var current: Operation? = nil
    static func withOperation<T>(_ name: String, _ work: () async -> T) async -> T { await work() }
    static func report(_ event: Event, phase: Phase, reason: String, error: Error, source: String) {}
}
enum SourceHealth {
    static var outcomes: [(String, String)] = []
    static func recordReadOutcome(source: String, outcome: String) { outcomes.append((source, outcome)) }
}
enum CodexFailureReason {
    case usageLimit, other, notLoggedIn
    static func classify(_ error: Error) -> Self { error is ProviderLimit ? .usageLimit : .other }
}
struct ProviderLimit: Error {}
struct AuthenticationFailure: Error {}
struct UnsafeProviderFailure: LocalizedError {
    var errorDescription: String? { "provider-secret user@example.invalid /private/mail/thread-123" }
}
enum ConnectorReadFailure {
    // GMAIL_FAILURE
    static func isConnectionFailure(_ error: Error) -> Bool { error is AuthenticationFailure }
}
enum DiskSpace {
    static func isDiskFull(_ error: Error) -> Bool { (error as NSError).code == NSFileWriteOutOfSpaceError }
}
func Log(_ message: String) {}
func ErrorLabel(_ error: Error) -> String { String(describing: type(of: error)) }
enum GmailConnect {
    // GMAIL_PROGRESS
    // GMAIL_ERROR
    static var events: [Progress] = []
    static var failure: Error?
    static var modes: [String] = []
    static func runInitial(onProgress: @Sendable @escaping (Progress) -> Void) async throws -> Int {
        modes.append("initial"); return try await read(onProgress)
    }
    static func runIterative(onProgress: @Sendable @escaping (Progress) -> Void) async throws -> Int {
        modes.append("iterative"); return try await read(onProgress)
    }
    private static func read(_ yield: @Sendable (Progress) -> Void) async throws -> Int {
        for event in events { yield(event) }
        if ClaudeAuth.rejectDuringGmail { ClaudeAuth.requiresVerification = true }
        if let failure { throw failure }
        return 0
    }
}
final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RunProgress] = []
    func append(_ value: RunProgress) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var snapshots: [RunProgress] { lock.lock(); defer { lock.unlock() }; return values }
}
enum ProactiveCyclePhase { case done, failed(CycleFailure) }
final class ProactiveCycle {
    static let shared = ProactiveCycle()
    var calls = 0
    var excluded: Set<String> = []
    func run(scheduled: Bool, unavailableConnectors: Set<String>, progress: (ProactiveCyclePhase) -> Void,
             onLine: (String) -> Void) async -> CycleFailure? {
        calls += 1; excluded = unavailableConnectors; return nil
    }
}
struct IterativeRun {
    enum Mode { case auto, initial, iterative }
    let modelPath: String
    static var calls = 0
    static var next = RunProgress()
    func run(_ connectors: [any Connector], mode: Mode, onProgress: (RunProgress) -> Void) async -> RunProgress {
        Self.calls += 1; onProgress(Self.next); return Self.next
    }
}
enum PowerState {
    enum Block: String { case thermal, unknown, onBattery, batteryLow }
    struct Snapshot {}
    static let initialBatteryFloor = 40, iterativeBatteryFloor = 20
    static var blocked: Block? = nil
    static func block(_ value: Snapshot, initial: Bool, allowBattery: Bool, scheduled: Bool) -> Block? { blocked }
}
enum OvernightScheduler { static let allowBatteryKey = "battery" }
enum OvernightCaution { enum Kind { case diskFull, loggedOut }; static func record(_ value: Kind) {} }
enum VaultGenerator { static var vaultRoot = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Knowledge") }
'''.replace('// GMAIL_FAILURE', member(connector_failure, 'enum GmailFailure:')).replace(
    '// GMAIL_PROGRESS', member(gmail, 'enum Progress:')).replace('// GMAIL_ERROR', member(gmail, 'enum GmailError:'))

run_class = '\n'.join(member(run, signature) for signature in (
    'struct Result',
    'func execute(progress:',
    'private func recordConnectionOutcome(',
    'private func claudeLoginFailure(',
    'private func runGmailLeg(',
))
run_fixture = r'''
@MainActor final class ProcessingRun {
    let request: ProcessingRequest
    let scheduled: Bool
    var unavailableConnectors: Set<String>
    static var calendarCalls = 0, mcpCalls = 0
    var mode: IterativeRun.Mode { request.mode }
    init(request: ProcessingRequest, scheduled: Bool) {
        self.request = request; self.scheduled = scheduled; unavailableConnectors = request.unavailableConnectorSlugs
    }
    func runCalendarLeg(base: RunProgress, yield: (RunProgress) -> Void) async -> RunProgress {
        Self.calendarCalls += 1
        var p = base; p.finishSourceRead(name: "Calendar", label: "fixture", summary: nil, items: 0); return p
    }
    func runMCPLeg(base: RunProgress, yield: (RunProgress) -> Void) async -> RunProgress { Self.mcpCalls += 1; return base }
    func recordOutcomeForTest(slug: String, connected: Bool) { recordConnectionOutcome(slug: slug, connected: connected) }
// RUN_MEMBERS
}
'''.replace('// RUN_MEMBERS', run_class)

# Exercise the exact final-result branch: the only substituted inputs are source results,
# synthetic knowledge-file presence and schedule state; milestone writes use the real plan store.
completion = coordinator[coordinator.index('        // A successful empty source read'):coordinator.index('        if let diagnosticID {\n            DiagnosticHistory.finish(.overnight, id: diagnosticID,\n                outcome: complete')]
coordinator_fixture = r'''
@MainActor final class ProcessingCoordinator {
    let defaults: UserDefaults
    var initialComplete = false
    var record = ProcessingPlan.Record()
    var state: State = .idle
    var activeRequest: ProcessingRequest?
    var batteryFloor: Int { initialComplete ? 20 : 40 }
    var power = PowerState.Snapshot()
    init(defaults: UserDefaults) { self.defaults = defaults }
    static func scheduleLabel(_ date: Date) -> String { "fixture" }
    func admits(_ request: ProcessingRequest) -> Wait? { admission(request, scheduled: false) }
    func finish(_ result: ProcessingRun.Result, request: ProcessingRequest) {
        let scheduled = defaults.bool(forKey: "fixture.scheduled")
// COMPLETION
    }
// COORDINATOR_MEMBERS
}
'''.replace('// COMPLETION', completion).replace('// COORDINATOR_MEMBERS', '\n'.join(member(coordinator, signature) for signature in (
    'enum State:', 'enum Wait:', 'var statusLine:', 'var waitingDetail:',
    'private func admission(', 'private func sourceAdmissionNotice(', 'private func detail(', 'private static func knowledgeExists(',
)))

checks = r'''
@main struct Test {
    @MainActor static func main() async throws {
        func check(_ value: Bool, _ message: String) { precondition(value, message); print("PASS " + message) }
        let suiteName = "sentient-processing-readiness-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = ProcessingCoordinator(defaults: defaults)
        let cloud = ProcessingRequest.current()
        check(cloud.readySelectionCount == 3 && cloud.connectors.isEmpty && cloud.modelPath == nil && ModelLocator.calls == 0,
              "cloud-only production snapshot has three sources without resolving a local model")
        for backend in [ModelBackend.chatgpt, .claude] {
            ModelBackend.current = backend; ConnectorCensus.identity = "account-A"; ConnectorCensus.outcomes = []
            let owned = ProcessingRun(request: .current(), scheduled: false)
            ConnectorCensus.identity = "account-B"
            owned.recordOutcomeForTest(slug: "gmail", connected: true)
            check(ConnectorCensus.outcomes.isEmpty, "read from previous provider account cannot certify its replacement")
            ConnectorCensus.identity = "account-A"
            owned.recordOutcomeForTest(slug: "gmail", connected: true)
            check(ConnectorCensus.outcomes.count == 1, "same provider account can certify its successful source read")
            ConnectorCensus.identity = nil
            let unknown = ProcessingRun(request: .current(), scheduled: false)
            unknown.recordOutcomeForTest(slug: "gmail", connected: true)
            check(ConnectorCensus.outcomes.count == 1, "unknown provider identity cannot certify a production connection")
        }
        ModelBackend.current = .chatgpt; ConnectorCensus.identity = "fixture"
        check(coordinator.admits(cloud) == nil, "three cloud sources admit first analysis without model")
        var tooFew = cloud; tooFew.readySelectionCount = 2
        check(coordinator.admits(tooFew) == .sources, "first production run requires three ready selections")
        coordinator.initialComplete = true
        check(coordinator.admits(tooFew) == nil, "completed users may run fewer selected sources")
        coordinator.initialComplete = false
        var explicit = tooFew; explicit.readySelectionCount = nil
        check(coordinator.admits(explicit) == nil, "explicit dev or fixture requests retain their deliberate override")
        var local = cloud; local.connectors = [FixtureConnector()]
        check(coordinator.admits(local) == .model, "usable local sources wait for their model")
        var mixed = cloud
        mixed.unavailableSources = ["iMessage": "Restore access or remove this source."]
        mixed.unavailableConnectorSlugs = ["gmail"]
        let partial = await ProcessingRun(request: mixed, scheduled: false).execute(progress: { _ in }, phase: { _ in }, onLine: { _ in })
        check(!partial.complete && partial.progress.sourceReadFailures["iMessage"] != nil,
              "an unavailable selected source survives healthy cloud legs as an incomplete result")
        check(partial.progress.successfulSources.contains("Gmail") && ProactiveCycle.shared.calls == 1,
              "healthy source work still reaches the knowledge tail during partial analysis")
        check(ProactiveCycle.shared.excluded.contains("gmail"), "unavailable provider is excluded from proactive fetches")
        check(IterativeRun.calls == 0, "cloud-only execution never runs the on-device model")
        let beforeAuthFailure = ProactiveCycle.shared.calls
        ModelBackend.current = .claude; ClaudeAuth.requiresVerification = true
        let authFailure = await ProcessingRun(request: cloud, scheduled: true).execute(progress: { _ in }, phase: { _ in }, onLine: { _ in })
        check(authFailure.failure?.kind == .loggedOut && authFailure.progress.successfulSources.isEmpty
            && ProactiveCycle.shared.calls == beforeAuthFailure, "Claude rejection stops before source reads and knowledge publication")
        ClaudeAuth.requiresVerification = false; ClaudeAuth.rejectDuringGmail = true
        let midReadFailure = await ProcessingRun(request: cloud, scheduled: false).execute(progress: { _ in }, phase: { _ in }, onLine: { _ in })
        check(midReadFailure.failure?.kind == .loggedOut && midReadFailure.progress.successfulSources.contains("Gmail")
            && !midReadFailure.progress.successfulSources.contains("Calendar") && ProactiveCycle.shared.calls == beforeAuthFailure,
              "new Claude rejection preserves completed source progress and prevents later cloud legs")
        ClaudeAuth.rejectDuringGmail = false; ModelBackend.current = .sentient
        let hosted = await ProcessingRun(request: cloud, scheduled: false).execute(progress: { _ in }, phase: { _ in }, onLine: { _ in })
        check(hosted.failure == nil && ProactiveCycle.shared.calls == beforeAuthFailure + 1,
              "subscription rejection does not block the hosted backend")
        ModelBackend.current = .chatgpt; ClaudeAuth.requiresVerification = false
        let missingModel = await ProcessingRun(request: local, scheduled: false).execute(progress: { _ in }, phase: { _ in }, onLine: { _ in })
        check(!missingModel.complete && missingModel.progress.sourceReadFailures["On-device sources"] != nil,
              "direct execution cannot silently skip local connectors with a missing model")
        let empty = ProcessingRun.Result(progress: RunProgress())
        coordinator.finish(empty, request: cloud)
        check(!coordinator.initialComplete && ProcessingPlan.initialCompletedAt(defaults) == nil
            && coordinator.record.notice?.contains("context") == true, "empty first analysis cannot complete without actual knowledge")
        let root = VaultGenerator.vaultRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("README.md"))
        coordinator.finish(empty, request: cloud)
        check(!coordinator.initialComplete, "empty README cannot certify initial knowledge")
        try "# Synthetic user context".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        coordinator.finish(partial, request: cloud)
        check(coordinator.initialComplete && ProcessingPlan.initialCompletedAt(defaults) != nil
            && coordinator.record.notice?.contains("iMessage") == true,
              "useful knowledge completes initial setup on the first pass while source failures remain actionable")
        let firstPassMilestone = ProcessingPlan.initialCompletedAt(defaults)
        coordinator.finish(empty, request: cloud)
        check(coordinator.initialComplete && ProcessingPlan.initialCompletedAt(defaults) == firstPassMilestone,
              "one-second no-work retry cannot be needed to create or replace the initial milestone")
        let milestone = ProcessingPlan.initialCompletedAt(defaults)
        coordinator.finish(partial, request: tooFew)
        check(coordinator.initialComplete && ProcessingPlan.initialCompletedAt(defaults) == milestone,
              "later permission loss preserves the existing completion milestone and retry notice")
        var parseFailure = RunProgress(); parseFailure.parseFailures = 1
        check(!ProcessingRun.Result(progress: parseFailure).complete, "malformed output cannot masquerade as completed analysis")
        func resetMilestone() {
            defaults.removeObject(forKey: ProcessingPlan.initialCompletedKey)
            coordinator.initialComplete = false
        }
        for progress in [parseFailure, { var p = RunProgress(); p.failed = 1; p.extractionFailed = 1; return p }(),
                         { var p = RunProgress(); p.mailDeferred = 1; p.mailIncomplete = true; return p }()] {
            resetMilestone()
            coordinator.finish(.init(progress: progress), request: cloud)
            check(coordinator.initialComplete && coordinator.record.notice != nil,
                  "skipped items or deferred Mail cannot withhold already-published personal knowledge")
        }
        resetMilestone()
        coordinator.finish(.init(progress: RunProgress(), hadDiagnostics: true), request: cloud)
        check(coordinator.initialComplete, "diagnostic warnings cannot veto a usable published knowledge base")
        for stage in [CycleFailure.Stage.deciding, .preparing] {
            resetMilestone()
            coordinator.finish(.init(progress: RunProgress(), failure: CycleFailure(stage: stage)), request: cloud)
            check(coordinator.initialComplete && coordinator.record.status == .failed,
                  "later proactive failure preserves knowledge readiness and still reports its own failure")
        }
        resetMilestone()
        coordinator.finish(.init(progress: RunProgress(), failure: CycleFailure(stage: .vault)), request: cloud)
        check(!coordinator.initialComplete && coordinator.record.status == .failed,
              "failed knowledge publication never certifies the first analysis")
        var diskFull = RunProgress(); diskFull.diskFull = true
        coordinator.finish(.init(progress: diskFull), request: cloud)
        check(!coordinator.initialComplete && coordinator.state == .diskFull,
              "storage failure still blocks initial completion")
        var localOnly = cloud; localOnly.fullCycle = false
        coordinator.finish(empty, request: localOnly)
        check(!coordinator.initialComplete, "local-only developer pass cannot certify a full analysis")
        try " \n\t".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        coordinator.finish(empty, request: cloud)
        check(!coordinator.initialComplete, "whitespace placeholder does not certify personal knowledge")
        try ChatSelectionReadError.validate(selected: [], available: [])
        try ChatSelectionReadError.validate(selected: ["kept"], available: ["kept", "other"])
        var missing = false
        do { try ChatSelectionReadError.validate(selected: ["kept", "gone"], available: ["kept"]) }
        catch { missing = true; check(!error.localizedDescription.contains("gone"), "missing-chat error does not expose identifiers") }
        check(missing, "stale selected chat IDs fail rather than returning a false empty source")

        // These are committed-window notifications, not successful model responses.
        // test_gmail_import_recovery verifies the real disk transaction precedes notification;
        // here the actual ProcessingRun consumer and RunProgress decide counts and presentation.
        func scenario(_ events: [GmailConnect.Progress], error: Error? = nil,
                      request: ProcessingRequest) async -> (ProcessingRun.Result, [RunProgress]) {
            GmailConnect.events = events; GmailConnect.failure = error; GmailConnect.modes = []
            SourceHealth.outcomes = []; ConnectorCensus.outcomes = []
            ProactiveCycle.shared.calls = 0; ProactiveCycle.shared.excluded = []
            ProcessingRun.calendarCalls = 0; ProcessingRun.mcpCalls = 0
            let capture = ProgressCapture()
            let result = await ProcessingRun(request: request, scheduled: false).execute(
                progress: { capture.append($0) }, phase: { _ in }, onLine: { _ in })
            return (result, capture.snapshots)
        }
        var gmailOnly = cloud; gmailOnly.runCalendar = false; gmailOnly.mcpSlugs = []
        let saved: GmailConnect.Progress = .windowDone(total: 4, label: "week 1", summary: "Saved weekly context",
                                                       threads: 3, completed: 1, keptSoFar: 1)
        let started: GmailConnect.Progress = .windowStart(total: 4, label: "week 1", prompt: "bounded week 1")
        let later: GmailConnect.Progress = .windowStart(total: 4, label: "week 2", prompt: "bounded week 2")
        let quiet: GmailConnect.Progress = .windowDone(total: 4, label: "week 2", summary: nil,
                                                       threads: 0, completed: 2, keptSoFar: 1)
        let anotherSaved: GmailConnect.Progress = .windowDone(total: 4, label: "week 3", summary: "Another saved context",
                                                              threads: 2, completed: 3, keptSoFar: 2)
        var withLocal = gmailOnly; withLocal.connectors = [FixtureConnector()]; withLocal.modelPath = "synthetic"
        withLocal.mode = .initial
        IterativeRun.next = RunProgress(); IterativeRun.next.total = 5; IterativeRun.next.done = 5
        IterativeRun.next.survivors = 2; IterativeRun.next.quietReads = 1; IterativeRun.next.junk = 1
        let (partialGmail, partialUpdates) = await scenario([started, saved, later, quiet, anotherSaved],
            error: GmailConnect.GmailError.incomplete(failed: 1, saved: 2), request: withLocal)
        check(partialGmail.progress.total == 9 && partialGmail.progress.done == 8
            && partialGmail.progress.survivors == 4 && partialGmail.progress.quietReads == 2
            && partialGmail.progress.junk == 1 && partialGmail.progress.failed == 1,
              "partial Gmail counts only persisted windows, adds quiet coverage, and preserves local counts")
        check(!partialGmail.complete && !partialGmail.progress.successfulSources.contains("Gmail")
            && partialGmail.progress.sourceReadFailures["Gmail"]?.contains("saved 2 email summaries") == true,
              "partial Gmail preserves saved count while keeping the source retryable")
        check(partialUpdates.contains { $0.lastPrompt == "bounded week 2" && $0.done == 6
            && $0.lastSummary == "Saved weekly context" && $0.sourceRead?.status == .summarized },
              "starting another Gmail worker retains the previously saved summary card")
        check(partialUpdates.contains { $0.done == 7 && $0.quietReads == 2
            && $0.lastSummary == "Saved weekly context" && $0.sourceRead?.status == .summarized },
              "a quiet Gmail window cannot erase the preceding useful summary")
        check(ProactiveCycle.shared.calls == 1 && SourceHealth.outcomes.last?.1 == "incomplete"
            && GmailConnect.modes == ["initial"],
              "partial Gmail still reaches knowledge publication and records incomplete source health")
        let (quietGmail, _) = await scenario([
            .windowStart(total: 2, label: "quiet 1", prompt: "quiet first"),
            .windowDone(total: 2, label: "quiet 1", summary: nil, threads: 0, completed: 1, keptSoFar: 0),
            .windowStart(total: 2, label: "quiet 2", prompt: "quiet second"),
            .windowDone(total: 2, label: "quiet 2", summary: nil, threads: 0, completed: 2, keptSoFar: 0)
        ], request: gmailOnly)
        check(quietGmail.complete && quietGmail.progress.done == 2 && quietGmail.progress.quietReads == 2
            && quietGmail.progress.junk == 0 && quietGmail.progress.survivors == 0
            && quietGmail.progress.lastVerdict == nil && quietGmail.progress.sourceRead?.status == .quiet,
              "successful empty Gmail windows count as quiet coverage, never junk or failed reads")
        check(SourceHealth.outcomes.last?.1 == "ok" && GmailConnect.modes == ["iterative"],
              "automatic Gmail uses resumable reading and successful quiet coverage certifies source health")
        let (authGmail, _) = await scenario([started, saved], error: AuthenticationFailure(), request: gmailOnly)
        check(authGmail.progress.survivors == 1 && authGmail.progress.done == 1 && !authGmail.complete
            && authGmail.progress.sourceReadFailures["Gmail"] == "Reconnect Gmail to retry this source.",
              "auth loss after a saved Gmail window preserves the saved count and requests reconnect")
        check(ProactiveCycle.shared.calls == 1 && ProactiveCycle.shared.excluded.contains("gmail")
            && ConnectorCensus.outcomes.last?.2 == false && SourceHealth.outcomes.last?.1 == "connector_auth",
              "Gmail auth failure excludes further Gmail fetches while saved work reaches the knowledge tail")
        let (unsafeGmail, _) = await scenario([started, saved], error: UnsafeProviderFailure(), request: gmailOnly)
        check(unsafeGmail.progress.lastSummary?.contains("Saved summaries are kept") == true
            && unsafeGmail.progress.lastSummary?.contains("provider-secret") == false
            && unsafeGmail.progress.sourceReadFailures["Gmail"]?.contains("user@example") == false
            && unsafeGmail.progress.lastVerdict == nil && unsafeGmail.progress.lastPrompt == nil
            && unsafeGmail.progress.survivors == 1 && unsafeGmail.progress.failed == 1,
              "unexpected Gmail failure shows safe recovery text without raw provider output or a junk verdict")
        for error: Error in [ConnectorReadFailure.GmailFailure.accountLimit, ProviderLimit()] {
            let (limitedGmail, _) = await scenario([started, saved], error: error, request: gmailOnly)
            check(limitedGmail.progress.survivors == 1 && !limitedGmail.complete
                && limitedGmail.progress.sourceReadFailures["Gmail"]?.contains("limit resets") == true
                && SourceHealth.outcomes.last?.1 == "usage_limit" && ConnectorCensus.outcomes.isEmpty,
                  "Gmail account or model usage limit keeps saved progress and never requests reconnect")
        }
        let (fullDiskGmail, _) = await scenario([started, saved],
            error: CocoaError(.fileWriteOutOfSpace), request: cloud)
        check(fullDiskGmail.progress.diskFull && !fullDiskGmail.complete
            && fullDiskGmail.progress.survivors == 1 && fullDiskGmail.progress.done == 1
            && fullDiskGmail.progress.sourceReadFailures["Gmail"]?.contains("disk space") == true,
              "Gmail storage failure keeps prior saves visible and returns the disk-full result")
        check(ProcessingRun.calendarCalls == 0 && ProcessingRun.mcpCalls == 0 && ProactiveCycle.shared.calls == 0,
              "Gmail disk-full halts Calendar, remaining connectors, and knowledge publication")
        let (noWorkGmail, _) = await scenario([], request: gmailOnly)
        check(noWorkGmail.complete && noWorkGmail.progress.successfulSources.contains("Gmail")
            && noWorkGmail.progress.done == 0 && SourceHealth.outcomes.last?.1 == "ok",
              "same-second Gmail no-work success clears source readiness without inventing summaries")
        print("Processing source readiness checks passed")
    }
}
'''

source = '\n'.join((fixture, progress, plan, member(chats, 'nonisolated enum ChatSelectionReadError'),
                    member(run, 'struct ProcessingRequest'), member(run, 'private nonisolated final class ProgressBox'),
                    run_fixture, coordinator_fixture, checks))
with tempfile.TemporaryDirectory(prefix='sentient-processing-readiness-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check'), str(path)], check=True)
