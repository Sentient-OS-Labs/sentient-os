#!/usr/bin/env python3
"""Compile real personal-setup migration, admission, scheduler policy, relaunch and reset.
All preferences are an in-memory UserDefaults double. Services, permission/relaunch actions,
model downloads, cloud calls and destructive reset collaborators are inert; no app is launched.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Sentient OS macOS'


def member(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


progress = (APP / 'App/PersonalSetupProgress.swift').read_text()
plan = (APP / 'Ingestion/ProcessingPlan.swift').read_text()
app = (APP / 'App/AppState.swift').read_text()
scheduler = (APP / 'Scheduling/OvernightScheduler.swift').read_text()
processing = (APP / 'Ingestion/ProcessingCoordinator.swift').read_text()
relaunch = (APP / 'System/SafeAppRelaunch.swift').read_text()
reset = (APP / 'Ingestion/FactoryReset.swift').read_text()
selection = (APP / 'Sources/SourceSelection.swift').read_text()

fixture = r'''
import Foundation
import Observation

// Shadow Foundation.UserDefaults so even production default arguments are process-local.
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    func string(forKey key: String) -> String? { values[key] as? String }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func dictionaryRepresentation() -> [String: Any] { values }
}
enum CodexTrigger { case onboarding, analyzeNow, overnight }
struct RunProgress { var done = 0 }
struct ProcessingRequest {}
enum Analytics { static func signal(_ value: String) {} }
@MainActor enum ModelBackend { case chatgpt, claude; static var current = Self.chatgpt }
@MainActor enum ClaudeAuth {
    static var held = false
    static var pending: CheckedContinuation<Void, Never>?
    static func refresh() async {
        if held { await withCheckedContinuation { pending = $0 } }
    }
    static func release() { pending?.resume(); pending = nil; held = false }
}
final class MainNavigation {
    static let shared = MainNavigation(); var approves=true
    func reset() {}
    func confirmLeavingKnowledge(_ completion: (Bool)->Void) { completion(approves) }
}
enum SourceSelection {
    static let minimumSelections = 3
    static let folderMigrationKey = "sources.explicitFolderConsent.v1"
    static let pendingProtectedSourceKey = "sources.pendingProtectedSource"
    static let folderKeys = ["dbg.run.downloads", "dbg.run.desktop", "dbg.run.documents"]
    static var selectionCount = 3
// FOLDER_MIGRATION
}
@MainActor final class ProcessingCoordinator {
    static let shared = ProcessingCoordinator()
    enum Timing: String { case now, overnight }
    enum State { case idle, scheduled }
    var state = State.idle
    var defaults: UserDefaults { .standard }
    var record = ProcessingPlan.Record() { didSet { ProcessingPlan.save(record, to: defaults) } }
    var isBusy = false, isSuspended = false, initialComplete = false
    var hasPendingFirstNight: Bool { !initialComplete && record.status == .scheduled }
    var requestOverride: ProcessingRequest?
    var carried = RunProgress()
    var resumed = 0
    var resumeSawComplete = false
    func suspend() async { isSuspended = true }
    func resumeMonitoring() {
        isSuspended = false; resumed += 1
        resumeSawComplete = PersonalSetupProgress.isComplete()
    }
    func reset() async { record = .init(); initialComplete = false }
// CHOOSE
}
@MainActor final class OvernightScheduler {
    static let enabledKey = "dbg.scheduler.enabled", prodEnabledKey = "scheduler.enabled"
    static let setupEnabledKey = "scheduler.enabledAfterSetup", autoEnableFiredKey = "scheduler.autoEnableFired"
    static let firstCycleAtKey = ProcessingPlan.initialCompletedKey
    static var configuredMinutes: Int { 180 }
    var processing: ProcessingCoordinator { .shared }
    var needsSchedulerSetup = false
    var reevaluations = 0
    func reevaluate() { reevaluations += 1 }
    static func nextOccurrence(minutesSinceMidnight: Int) -> Date { Date(timeIntervalSince1970: 1_000) }
// SCHEDULER_POLICY
}
@MainActor final class AppState {
    static let onboardingKey = PersonalSetupProgress.homeKey
    var isUninstalling = false
    var hasCompletedFirstSidekickTask = false
    var homePreparation: Task<Void, Never>?
    let processing = ProcessingCoordinator.shared
    let scheduler = OvernightScheduler()
    let commandCoordinator = Coordinator()
    @MainActor final class Coordinator { let run = Run() }
    @MainActor final class Run {
        var isRunning = false
        var canSavePermissionWaitForRelaunch=false
        func savePermissionWaitForRelaunch() async -> Bool {false}
        let conversation = SidekickConversation.shared
        func stop() { isRunning = false }
        func stopAndDrain() async -> Bool { true }
    }
    init() { hasCompletedOnboarding = false; hasCompletedPersonalSetup = false }
// APP_PROPERTIES
// APP_POLICY
}
@MainActor final class SidekickConversation {
    static let shared = SidekickConversation()
    var draft = "", replyReference: String? = nil, generation: UUID? = UUID()
    func beginMaintenance() -> Bool { true }
    func endMaintenance() {}
    func reset(defaults: UserDefaults) throws {}
    func drainBackgroundWork() async {}
}
@MainActor final class CodexSetup {
    static let shared = CodexSetup()
    var installing = false, preparing = false
    func startKeepingCurrent(_ busy: () -> Bool) {}
}
@MainActor final class ClaudeSetup { static let shared = ClaudeSetup(); var installing = false, preparing = false }
@MainActor final class ComputerUseSetup { static let current = ComputerUseSetup(); var isInstalling = false }
@MainActor final class PipelineActivity { static let shared = PipelineActivity(); var isRunning = false }
@MainActor final class DoubleTap { static let shared = DoubleTap(); var isDrafting = false }
@MainActor final class FixtureApplication {
    static let shared=FixtureApplication(); var requests=0
    func terminate(_ sender:Any?) { requests+=1 }
}
@MainActor var NSApp:FixtureApplication { FixtureApplication.shared }
@MainActor enum PermissionRelaunchHandoff {
    enum Failure:Error {case notReady}
    static var fails=false
    static var commits=0
    @MainActor final class Ticket {
        var isReady=true
        func commit() throws { if !isReady {throw Failure.notReady};PermissionRelaunchHandoff.commits+=1 }
        func cancel() {isReady=false}
    }
    static func prepare() async throws -> Ticket {if fails {throw Failure.notReady};return Ticket()}
}
enum PermissionRelaunchDraft {
    struct Snapshot { let text: String; let reply: String?; let generation: UUID? }
    enum Failure: Error { case fixture }
    static var fails = false
    static var saved: Snapshot?
    static func save(_ snapshot: Snapshot) throws { if fails { throw Failure.fixture }; saved = snapshot }
    static func clear() { saved = nil }
}
enum PermissionWaitDraft { static func clear() {} }
enum SidekickInstructionStore { static func resetLearning() {} }
@MainActor final class NativePermissionCheck { static let shared = NativePermissionCheck(); var isChecking=false; func close() async {} }
@MainActor final class ComputerUseDoctor { static let shared = ComputerUseDoctor(); var isRunning=false; func clear(defaults: UserDefaults) async {} }
@MainActor enum HostedConnectorSetup {
    static var active = false
    static func beginTeardown() async { active = true }
    static func endTeardown() { active = false }
}
@MainActor final class DirectMCPConnections {
    static let shared = DirectMCPConnections(); var fails = false
    enum Failure: Error { case fixture }
    func removeAll() async throws { if fails { throw Failure.fixture } }
}
@MainActor final class CycleStore { static let shared = CycleStore(); func wipeEverything() async {} }
enum Diagnostics {
    enum Event { case cleanupFailed }; enum Phase { case reset }
    static func report(_ event: Event, phase: Phase, reason: String, error: Error) {}
    static func removeForCleanup(_ url: URL, phase: Phase, reason: String) {}
}
enum VaultGenerator { static let vaultRoot = URL(fileURLWithPath: "/unused-fixture") }
enum ProactiveCycle { static func resetAll() {} }
enum OutlookCalendarToolPolicy { static let pendingDirectory = URL(fileURLWithPath: "/unused-fixture") }
enum LifetimeStats { static func reset() {} }
@MainActor final class MirrorClient { static let shared = MirrorClient(); func deleteRemote() async throws {} }
enum CodexAuth {
    static let kbOnlyKey = "plan.kbOnly", assertedPlusKey = "plan.assertedPlus"
    static var knowledgeBaseOnly: Bool { UserDefaults.standard.bool(forKey: kbOnlyKey) }
}
enum ComputerUseGate { static let micSpeechOfferedKey = "mic" }
enum HealthCaution { static let nativeComputerUseEverReadyKey = "native"; static let computerUseEverReadyKey = "legacy" }
enum SidekickHistory { static func reset() {} }
enum SourceHealth { static let readStatusKey = "health" }
enum AppleMailHealth { static let key = "mail", needsRetryKey = "mail.retry" }
enum AppleCalendarSource { static let issueKey = "calendar" }
@MainActor final class ComputerUseUpgrade { static let shared = ComputerUseUpgrade(); func reset() {} }
enum SidekickDiagnostics {
    enum Stage { case reset }; enum Reason { case writeFailed, timeout }; enum Source { case reset }
    static func failure(_ stage: Stage, reason: Reason, source: Source) {}
}
enum DiagnosticHistory { static func reset(defaults: UserDefaults) {} }
func Log(_ message: String) {}
'''
fixture = fixture.replace('// FOLDER_MIGRATION', member(selection, 'static func migrateLegacyFolderDefaults('))
fixture = fixture.replace('// CHOOSE', member(processing, 'func choose('))
fixture = fixture.replace('// SCHEDULER_POLICY', '\n'.join(member(scheduler, s) for s in ('var isEnabled:', 'func enableAfterSetup(')))
fixture = fixture.replace('// APP_PROPERTIES', '\n'.join(member(app, s) for s in ('var hasCompletedPersonalSetup:', 'var hasCompletedOnboarding:')))
fixture = fixture.replace('// APP_POLICY', '\n'.join(member(app, s) for s in ('private func startAfterHome(', 'func finishPersonalSetup(')))

checks = r'''
extension SafeAppRelaunch { func fixtureWait() async { await preparation?.value } }
@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); count += 1; print("PASS " + message); fflush(stdout)
        }
        let d = UserDefaults.standard
        func clear() { d.values = [:] }
        clear()
        check(!PersonalSetupProgress.migrate(defaults: d) && !PersonalSetupProgress.isComplete(defaults: d)
            && !d.bool(forKey: PersonalSetupProgress.homeKey), "fresh migration creates no completion or Home admission")
        SourceSelection.migrateLegacyFolderDefaults(hadPersonalSetup: false, defaults: d)
        check(SourceSelection.folderKeys.allSatisfy { !d.bool(forKey: $0) }, "fresh migration has no implicit local sources")
        for step in [0, 1, 2, 3, 4, 8] {
            clear(); d.set(step, forKey: "onboarding.step")
            let legacy = PersonalSetupProgress.migrate(defaults: d)
            check(!legacy && !PersonalSetupProgress.isComplete(defaults: d)
                && d.bool(forKey: PersonalSetupProgress.homeKey) == (step >= 2), "legacy step \(step) migrates Home without inventing personal setup")
        }
        clear(); d.set(true, forKey: PersonalSetupProgress.homeKey); d.set(false, forKey: "dbg.run.desktop")
        let legacy = PersonalSetupProgress.migrate(defaults: d)
        SourceSelection.migrateLegacyFolderDefaults(hadPersonalSetup: legacy, defaults: d)
        check(legacy && PersonalSetupProgress.isComplete(defaults: d) && !d.bool(forKey: "dbg.run.desktop")
            && d.bool(forKey: "dbg.run.downloads"), "legacy completed Home preserves setup and explicit folder opt-out")
        for status in [ProcessingPlan.Status.requested, .scheduled, .running, .paused, .failed, .completed] {
            clear(); ProcessingPlan.save(.init(status: status), to: d)
            check(PersonalSetupProgress.migrate(defaults: d) && PersonalSetupProgress.isComplete(defaults: d),
                  "explicit legacy \(status.rawValue) analysis intent preserves personal setup")
        }
        clear(); d.set(123.0, forKey: ProcessingPlan.initialCompletedKey)
        check(PersonalSetupProgress.migrate(defaults: d), "existing initial-analysis milestone is authoritative migration evidence")
        clear(); PersonalSetupProgress.migrate(defaults: d)
        d.set(true, forKey: PersonalSetupProgress.homeKey)
        check(!PersonalSetupProgress.migrate(defaults: d) && !PersonalSetupProgress.isComplete(defaults: d),
              "new Home completion cannot be reinterpreted as legacy source consent on second launch")
        PersonalSetupProgress.begin(defaults: d)
        d.set(PersonalSetupProgress.Stage.timing.rawValue, forKey: PersonalSetupProgress.stageKey)
        check(!PersonalSetupProgress.isComplete(defaults: d) && ProcessingPlan.read(d).status == .idle,
              "opening or leaving setup at timing never requests analysis")
        check(!PersonalSetupProgress.consumeRelaunchResume(defaults: d), "ordinary quit does not reopen optional setup")
        d.set(true, forKey: PersonalSetupProgress.resumeKey)
        check(PersonalSetupProgress.consumeRelaunchResume(defaults: d) && !PersonalSetupProgress.consumeRelaunchResume(defaults: d),
              "explicit relaunch resume is consumed exactly once")
        PersonalSetupProgress.recordSuccessfulTask(defaults: d)
        check(d.bool(forKey: PersonalSetupProgress.firstTaskKey) && ProcessingPlan.read(d).status == .idle,
              "successful Sidekick task unlocks invitation without starting analysis")
        clear()
        PersonalSetupProgress.migrate(defaults: d)
        d.set(true, forKey: PersonalSetupProgress.homeKey)
        ProcessingPlan.save(.init(status: .requested, trigger: .onboarding), to: d)
        check(!PersonalSetupProgress.migrate(defaults: d) && ProcessingPlan.read(d).status == .requested,
              "crash between chosen intent and setup milestone retains the explicit request without inventing completion")
        clear()
        ModelBackend.current = .claude
        ClaudeAuth.held = true
        let waitingApp = AppState()
        let beforeRefresh = waitingApp.processing.resumed
        waitingApp.hasCompletedOnboarding = true
        let preparation = waitingApp.homePreparation
        while ClaudeAuth.pending == nil { await Task.yield() }
        check(waitingApp.processing.resumed == beforeRefresh,
              "persisted Claude analysis waits for current account metadata without blocking Home")
        waitingApp.hasCompletedOnboarding = false
        ClaudeAuth.release()
        await preparation?.value
        check(waitingApp.processing.resumed == beforeRefresh && waitingApp.homePreparation == nil,
              "reset during account refresh cannot revive analysis monitoring")
        waitingApp.hasCompletedOnboarding = true
        await waitingApp.homePreparation?.value
        check(waitingApp.processing.resumed == beforeRefresh + 1 && waitingApp.homePreparation == nil,
              "successful account refresh admits monitoring and releases its startup owner")
        waitingApp.hasCompletedOnboarding = false
        ModelBackend.current = .chatgpt
        clear()
        let app = AppState()
        app.hasCompletedOnboarding = true
        await app.homePreparation?.value
        check(!app.scheduler.isEnabled && !app.hasCompletedPersonalSetup && ProcessingPlan.read(d).status == .idle,
              "new Home starts no schedule or analysis intent")
        d.set(true, forKey: OvernightScheduler.enabledKey)
        d.set(true, forKey: OvernightScheduler.prodEnabledKey)
        check(!app.scheduler.isEnabled, "stale scheduler switches cannot start work before personal setup")
        d.removeObject(forKey: OvernightScheduler.enabledKey)
        d.removeObject(forKey: OvernightScheduler.prodEnabledKey)
        SourceSelection.selectionCount = 2
        check(!app.finishPersonalSetup(.now) && ProcessingPlan.read(d).status == .idle,
              "last-moment source loss rejects setup completion without persisting work")
        SourceSelection.selectionCount = 3; app.processing.isBusy = true
        check(!app.finishPersonalSetup(.now), "setup cannot replace active analysis")
        app.processing.isBusy = false
        check(app.finishPersonalSetup(.now) && app.processing.record.status == .requested
            && app.processing.resumeSawComplete && !app.scheduler.isEnabled,
              "run-now persists intent then setup completion before monitoring, without scheduling")
        app.processing.record = .init()
        check(app.finishPersonalSetup(.overnight) && app.processing.record.status == .scheduled
            && app.scheduler.isEnabled, "explicit overnight choice creates durable first-night intent")
        app.processing.initialComplete = true; app.processing.record = .init()
        d.set(false, forKey: OvernightScheduler.prodEnabledKey)
        app.scheduler.enableAfterSetup()
        check(!app.scheduler.isEnabled, "explicit scheduler opt-out survives repeated setup calls")
        SafeAppRelaunch.shared.configure(app)
        app.commandCoordinator.run.isRunning = true
        check(!SafeAppRelaunch.shared.relaunchForPersonalSetup() && NSApp.requests == 0,
              "permission relaunch refuses an active Sidekick task")
        app.commandCoordinator.run.isRunning = false
        app.processing.isBusy = true
        check(!SafeAppRelaunch.shared.canRelaunch, "permission relaunch waits for analysis to drain")
        app.processing.isBusy = false; CodexSetup.shared.installing = true
        check(!SafeAppRelaunch.shared.canRelaunch, "permission relaunch preserves active installation")
        CodexSetup.shared.installing = false
        NativePermissionCheck.shared.isChecking=true
        check(!SafeAppRelaunch.shared.canRelaunch, "permission relaunch waits for active capability proof")
        NativePermissionCheck.shared.isChecking=false
        MainNavigation.shared.approves=false
        check(SafeAppRelaunch.shared.relaunchForPersonalSetup(), "restart request resolves the Knowledge leave guard")
        await SafeAppRelaunch.shared.fixtureWait()
        check(NSApp.requests == 0 && SafeAppRelaunch.shared.canRelaunch,"declined Knowledge leave never spawns a restart")
        MainNavigation.shared.approves=true
        PermissionRelaunchHandoff.fails=true
        _=SafeAppRelaunch.shared.relaunchForPersonalSetup()
        await SafeAppRelaunch.shared.fixtureWait()
        check(NSApp.requests == 0 && SafeAppRelaunch.shared.canRelaunch,"helper preparation failure keeps the app open and retryable")
        PermissionRelaunchHandoff.fails=false;PermissionRelaunchDraft.fails=true
        _=SafeAppRelaunch.shared.relaunchForPersonalSetup()
        await SafeAppRelaunch.shared.fixtureWait()
        check(NSApp.requests == 0 && SafeAppRelaunch.shared.canRelaunch,
              "draft-save failure leaves the app running and permits a retry")
        PermissionRelaunchDraft.fails = false
        app.commandCoordinator.run.conversation.draft = "unsent fixture"
        check(SafeAppRelaunch.shared.relaunchForPersonalSetup(),"safe relaunch begins asynchronous preparation")
        await SafeAppRelaunch.shared.fixtureWait()
        check(NSApp.requests == 1 && PermissionRelaunchHandoff.commits == 0
            && PermissionRelaunchDraft.saved?.text == "unsent fixture" && d.bool(forKey: PersonalSetupProgress.resumeKey),
              "safe relaunch saves draft and resume before quit but never commits before final approval")
        app.commandCoordinator.run.isRunning=true
        check(!SafeAppRelaunch.shared.approveTermination() && PermissionRelaunchHandoff.commits == 0,
              "new Sidekick work during preparation cancels pending restart")
        app.commandCoordinator.run.isRunning=false
        check(SafeAppRelaunch.shared.canRelaunch && !d.bool(forKey:PersonalSetupProgress.resumeKey),"cancelled restart stays retryable without a surprise resume")
        _=SafeAppRelaunch.shared.relaunchForPersonalSetup()
        await SafeAppRelaunch.shared.fixtureWait()
        check(SafeAppRelaunch.shared.approveTermination() && PermissionRelaunchHandoff.commits == 1,"only final termination approval commits restart")
        SafeAppRelaunch.shared.cancelPendingRelaunch()
        _=SafeAppRelaunch.shared.relaunchPreservingDraft()
        await SafeAppRelaunch.shared.fixtureWait()
        check(!d.bool(forKey:PersonalSetupProgress.resumeKey) && PermissionRelaunchDraft.saved?.text == "unsent fixture",
              "generic permission restart preserves draft without reopening personal setup")
        SafeAppRelaunch.shared.cancelPendingRelaunch()
        d.set("imessage", forKey: SourceSelection.pendingProtectedSourceKey)
        d.set(true, forKey: "dbg.run.downloads")
        d.set(false, forKey: "dbg.run.desktop")
        d.set(true, forKey: "mcp.mirror.enabled")
        DirectMCPConnections.shared.fails = true
        check(!(await FactoryReset.run(appState: app, defaults: d)) && app.hasCompletedPersonalSetup,
              "failed destructive reset does not claim setup was cleared")
        DirectMCPConnections.shared.fails = false
        check(await FactoryReset.run(appState: app, defaults: d), "actual reset orchestration succeeds with inert services")
        check(!PersonalSetupProgress.isComplete(defaults: d) && !app.hasCompletedPersonalSetup
            && !app.hasCompletedOnboarding && ProcessingPlan.read(d).status == .idle && !app.scheduler.isEnabled,
              "reset clears setup, Home, completion and scheduling intent")
        check(d.bool(forKey: "dbg.run.downloads") && !d.bool(forKey: "dbg.run.desktop")
            && d.bool(forKey: "mcp.mirror.enabled"), "reset preserves explicit source and sharing choices")
        check(d.object(forKey: SourceSelection.pendingProtectedSourceKey) == nil,
              "reset clears pending source permission UI without erasing selected sources")
        check(!PersonalSetupProgress.migrate(defaults: d), "reset migration marker prevents accidental legacy setup restoration")
        print("Personal setup flow: \(count) checks passed")
    }
}
'''

source = '\n'.join((fixture, progress, plan, member(relaunch, '@MainActor @Observable\nfinal class SafeAppRelaunch'), reset, checks))
with tempfile.TemporaryDirectory(prefix='sentient-personal-setup-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
