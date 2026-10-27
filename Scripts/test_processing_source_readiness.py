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

fixture = r'''
import Foundation

enum Verdict { case survivor, junk }
enum CodexTrigger { case onboarding, analyzeNow, overnight }
struct CycleFailure: Error, Equatable {}
protocol Connector {}
struct FixtureConnector: Connector {}
struct RunSource {
    static func connectors(from sources: [RunSource]) -> [any Connector] { sources.isEmpty ? [] : [FixtureConnector()] }
}
enum ModelBackend { case chatgpt, claude, custom; static var current: Self = .chatgpt }
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
    final class Operation { var hasFailure = false }
    static var current: Operation? = nil
    static func withOperation<T>(_ name: String, _ work: () async -> T) async -> T { await work() }
}
enum ProactiveCyclePhase { case done }
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
enum OvernightCaution { enum Kind { case diskFull }; static func record(_ value: Kind) {} }
enum VaultGenerator { static var vaultRoot = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Knowledge") }
'''

run_class = '\n'.join(member(run, signature) for signature in (
    'struct Result',
    'func execute(progress:',
    'private func recordConnectionOutcome(',
))
run_fixture = r'''
@MainActor final class ProcessingRun {
    let request: ProcessingRequest
    let scheduled: Bool
    var unavailableConnectors: Set<String>
    var mode: IterativeRun.Mode { request.mode }
    init(request: ProcessingRequest, scheduled: Bool) {
        self.request = request; self.scheduled = scheduled; unavailableConnectors = request.unavailableConnectorSlugs
    }
    func runGmailLeg(base: RunProgress, yield: (RunProgress) -> Void) async -> RunProgress {
        var p = base; p.finishSourceRead(name: "Gmail", label: "fixture", summary: "safe summary", items: 1); return p
    }
    func runCalendarLeg(base: RunProgress, yield: (RunProgress) -> Void) async -> RunProgress {
        var p = base; p.finishSourceRead(name: "Calendar", label: "fixture", summary: nil, items: 0); return p
    }
    func runMCPLeg(base: RunProgress, yield: (RunProgress) -> Void) async -> RunProgress { base }
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
        check(!coordinator.initialComplete && coordinator.record.notice?.contains("iMessage") == true,
              "partial source failures remain actionable even after useful knowledge was saved")
        coordinator.finish(empty, request: cloud)
        check(coordinator.initialComplete && ProcessingPlan.initialCompletedAt(defaults) != nil,
              "successful retry with actual knowledge completes the initial milestone")
        let milestone = ProcessingPlan.initialCompletedAt(defaults)
        coordinator.finish(partial, request: tooFew)
        check(coordinator.initialComplete && ProcessingPlan.initialCompletedAt(defaults) == milestone,
              "later permission loss preserves the existing completion milestone and retry notice")
        var parseFailure = RunProgress(); parseFailure.parseFailures = 1
        check(!ProcessingRun.Result(progress: parseFailure).complete, "malformed output cannot masquerade as completed analysis")
        try ChatSelectionReadError.validate(selected: [], available: [])
        try ChatSelectionReadError.validate(selected: ["kept"], available: ["kept", "other"])
        var missing = false
        do { try ChatSelectionReadError.validate(selected: ["kept", "gone"], available: ["kept"]) }
        catch { missing = true; check(!error.localizedDescription.contains("gone"), "missing-chat error does not expose identifiers") }
        check(missing, "stale selected chat IDs fail rather than returning a false empty source")
        print("Processing source readiness checks passed")
    }
}
'''

source = '\n'.join((fixture, progress, plan, member(chats, 'nonisolated enum ChatSelectionReadError'),
                    member(run, 'struct ProcessingRequest'), run_fixture, coordinator_fixture, checks))
with tempfile.TemporaryDirectory(prefix='sentient-processing-readiness-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check'), str(path)], check=True)
