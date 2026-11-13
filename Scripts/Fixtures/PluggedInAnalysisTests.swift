// Synthetic collaborators for the complete production coordinator and idle scheduler.
// Tests control only external inputs and async I/O; all admission and lifecycle code is production.
import Foundation
import AppKit

nonisolated enum CodexTrigger: String, Sendable {
    case onboarding, analyzeNow, overnight, pluggedInIdle
    @TaskLocal static var current: Self = .analyzeNow
}
nonisolated enum ModelBackend: String, Sendable {
    case fixture
    static var current: Self { .fixture }
    @TaskLocal static var runOverride: Self = .fixture
}
nonisolated struct CycleFailure: Error, Equatable, Sendable {
    enum Stage { case vault, deciding }
    var stage = Stage.deciding
}
nonisolated struct RunProgress: Sendable {
    var done = 0, total = 0, survivors = 0, junk = 0, sensitive = 0
    var failed = 0, parseFailures = 0, extractionFailed = 0, quietReads = 0
    var totalSeconds = 0.0
    var diskFull = false
    var sourceReadFailures: [String: String] = [:]
    mutating func mergeSourceResults(from other: Self) {}
}
struct ProcessingRequest: Sendable {
    var modelPath: String? = "fixture"
    var connectors: [Int] = []
    var fullCycle = true
    var readySelectionCount: Int? = 3
    var unavailableSources: [String: String] = [:]
    var hasSources = true
    static var next = Self()
    static func current() -> Self { next }
}
enum SourceSelection { static let minimumSelections = 3 }
enum ModelLocator { static func resolve() -> String? { nil } }
final class ModelDownload {
    enum Phase { case idle, ready }
    static let shared = ModelDownload()
    var phase = Phase.ready
    func kickIfNeeded() {}
}
enum ProactiveCycle { static let lastCycleKey = "fixture.lastCycle" }
enum VaultGenerator {
    static var vaultRoot: URL { URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("vault") }
}
enum OvernightScheduler {
    static let prodEnabledKey = "fixture.enabled", allowBatteryKey = "fixture.allowBattery"
    static let enabledKey = "fixture.developerEnabled"
    static let configuredMinutes = 180
    static let stallSeconds = 4200.0
    static func nextOccurrence(minutesSinceMidnight: Int) -> Date { Date().addingTimeInterval(86400) }
}
enum WakeHelperConfig { static let maxAwakeSeconds = 6 * 3600 }
final class PipelineActivity {
    static let shared = PipelineActivity()
    var activeRuns = 0
    var isRunning: Bool { activeRuns > 0 }
    func acquire() { activeRuns += 1 }
    func release() { activeRuns -= 1; precondition(activeRuns >= 0) }
}
enum WritingStyle { static func cancelSetupAndDrain() async {} }
enum Analytics {
    enum Tier { case core }
    static func signal(_ name: String, parameters: [String: String] = [:], tier: Tier? = nil) {}
}
enum OvernightCaution {
    enum Kind { case diskFull, stalled }
    static func record(_ kind: Kind) {}
}
nonisolated enum FixtureDefaults {
    static let suite = "sentient-idle-history-" + UUID().uuidString
    static var history: UserDefaults { UserDefaults(suiteName: suite)! }
}
nonisolated enum NativeComputerUseFailure { enum Detail: String { case fixture } }
nonisolated enum Diagnostics {
    struct Payload { var tags: [String: String]; var extra: [String: String]; var event: String }
}
nonisolated enum CrashReporting {
    enum Level { case warning }
    static func scrub(text: String) -> String { text }
    static func captureEvent(_ name: String, level: Level, tags: [String: String], fingerprint: [String]) {}
}
enum UserPresence { static var systemIdleSeconds = 0.0 }
enum TestActivity {
    static var active = 0
    static func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol {
        active += 1; return NSObject()
    }
    static func endActivity(_ activity: NSObjectProtocol) { active -= 1; precondition(active >= 0) }
}

final class WakeHelperClient {
    static let shared = WakeHelperClient()
    var active = false
    var begins = 0, ends = 0
    var blockBegin = false, blockEnd = false, beginResult = true
    var beginPending: CheckedContinuation<Bool, Never>?
    var endPending: CheckedContinuation<Bool, Never>?
    func beginAwake(timeout: Int) async -> Bool {
        begins += 1; active = true
        if blockBegin { return await withCheckedContinuation { beginPending = $0 } }
        return beginResult
    }
    func heartbeat() async -> Bool { active }
    func endAwake() async -> Bool {
        ends += 1
        if blockEnd { return await withCheckedContinuation { endPending = $0 } }
        active = false; return true
    }
    func answerBegin(_ result: Bool) { let reply = beginPending; beginPending = nil; reply?.resume(returning: result) }
    func answerEnd() { active = false; let reply = endPending; endPending = nil; reply?.resume(returning: true) }
    func reset() {
        precondition(beginPending == nil && endPending == nil)
        active = false; begins = 0; ends = 0; blockBegin = false; blockEnd = false; beginResult = true
    }
}

enum Phase { case knowledgeBase(String), deciding, researching(Int), done, failed }
final class ProcessingRun {
    nonisolated struct Result: Sendable { var progress = RunProgress(); var failure: CycleFailure?; var deviceProgress: RunProgress?; var complete = true }
    static var calls = 0
    static var pending: [CheckedContinuation<Result, Never>] = []
    static var triggers: [CodexTrigger] = []
    static var nightFlags: [Bool] = []
    static var lateProgress: (@Sendable (RunProgress) -> Void)?
    init(request: ProcessingRequest, scheduled: Bool) { Self.nightFlags.append(scheduled) }
    func execute(progress: @escaping @Sendable (RunProgress) -> Void,
                 phase: @escaping @Sendable (Phase) -> Void, onLine: @escaping @Sendable (String) -> Void) async -> Result {
        Self.calls += 1; Self.triggers.append(CodexTrigger.current)
        Self.lateProgress = progress
        progress(RunProgress(done: 1, total: 2))
        // Deliberately ignore cancellation until the fixture releases the worker. This exercises
        // ownership while actual providers or an in-flight local inference are draining.
        return await withCheckedContinuation { Self.pending.append($0) }
    }
    static func finish(_ result: Result = Result()) { precondition(!pending.isEmpty); pending.removeFirst().resume(returning: result) }
}

@main @MainActor struct Tests {
    static var checks = 0
    static var suites: [String] = []
    static let helper = WakeHelperClient.shared
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    static func until(_ ready: () -> Bool) async throws {
        for _ in 0..<400 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        fatalError("Fixture did not reach expected state")
    }
    static func defaults() -> UserDefaults {
        let name = "sentient-idle-" + UUID().uuidString
        suites.append(name)
        let d = UserDefaults(suiteName: name)!
        d.set(true, forKey: OvernightScheduler.prodEnabledKey)
        return d
    }
    static func owner(record: ProcessingPlan.Record = .init(status: .completed),
                      initial: Bool = false, lastStart: Date = Date().addingTimeInterval(-14401)) -> (ProcessingCoordinator, UserDefaults) {
        helper.reset()
        PowerState.fixtureSnapshot = .init(onAC: true, percent: 100, critical: false)
        ProcessingRequest.next = .init()
        let d = defaults()
        if !initial { ProcessingPlan.completeInitial(d, at: Date().addingTimeInterval(-86400)) }
        ProcessingPlan.save(record, to: d)
        ProcessingPlan.saveCadence(.init(lastStartedAt: lastStart), to: d)
        let c = ProcessingCoordinator(defaults: d)
        c.pluggedInEnvironmentAllowsRun = { true }
        return (c, d)
    }
    static func finish(_ c: ProcessingCoordinator, result: ProcessingRun.Result = .init()) async throws {
        ProcessingRun.finish(result)
        try await until { !c.isBusy }
        check(!helper.active && TestActivity.active == 0 && !PipelineActivity.shared.isRunning, "all run holds released")
    }
    static func main() async throws {
        // Ensure even diagnostic history uses fixture preferences. Production ledger methods are
        // covered separately below with explicit suite arguments; coordinator calls are redirected
        // by the runner to the fixture default store.
        defer {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            UserDefaults.standard.removePersistentDomain(forName: FixtureDefaults.suite)
        }
        try FileManager.default.createDirectory(at: VaultGenerator.vaultRoot, withIntermediateDirectories: true)
        try "# Fixture knowledge".write(to: VaultGenerator.vaultRoot.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let now = Date()
        let cadence = ProcessingPlan.Cadence(lastStartedAt: now)
        check(!PluggedInAnalysisScheduler.isDue(cadence, now: now.addingTimeInterval(14399.9)), "before four hours")
        check(PluggedInAnalysisScheduler.isDue(cadence, now: now.addingTimeInterval(14400)), "exact four-hour boundary")
        check(PluggedInAnalysisScheduler.isDue(cadence, now: now.addingTimeInterval(86400)), "missed windows coalesce")
        let old = try JSONDecoder().decode(ProcessingPlan.Record.self, from: Data(#"{"status":"paused","trigger":"manual"}"#.utf8))
        check(old.startedAt == nil && old.activeSeconds == nil && old.status == .paused, "old plan decodes without new fields")
        for status in [ProcessingPlan.Status.running, .requested, .awaitingIdle] {
            let saved = ProcessingPlan.Record(status: status, trigger: .pluggedInIdle, startedAt: now, activeSeconds: 99)
            let recovered = ProcessingPlan.recovered(saved)
            check(recovered.status == .awaitingIdle && recovered.startedAt == now && recovered.activeSeconds == 99, "idle recovery retains identity and budget")
        }
        check(ProcessingPlan.recovered(.init(status: .paused, trigger: .pluggedInIdle)).status == .paused, "explicit pause survives relaunch")
        check(ProcessingPlan.recovered(.init(status: .running, trigger: .onboarding), initialComplete: false).status == .paused, "initial analysis still requires explicit resume")
        for (initial, floor) in [(true, 40), (false, 25)] {
            check(PowerState.block(.init(onAC: false, percent: floor - 1, critical: false), initial: initial) == .batteryLow, "below battery floor")
            check(PowerState.block(.init(onAC: false, percent: floor, critical: false), initial: initial) == nil, "inclusive battery floor")
            check(PowerState.block(.init(onAC: false, percent: floor, critical: false), initial: initial, allowBattery: false) == .onBattery, "battery opt-out respected")
        }
        check(PowerState.shouldPause(.init(onAC: false, percent: 20, critical: false)), "reserve remains twenty percent")
        check(!PowerState.shouldPause(.init(onAC: false, percent: 21, critical: false)), "above reserve continues")
        check(PowerState.block(.init(onAC: false, percent: nil, critical: false), initial: false) == .unknown, "unreadable battery blocks overnight start")
        check(PowerState.block(.init(onAC: false, percent: 1, critical: false), initial: false, scheduled: false) == nil, "manual bypasses battery threshold")
        check(PowerState.block(.init(onAC: true, percent: 100, critical: true), initial: false, scheduled: false) == .thermal, "manual retains thermal protection")

        let futureCadence = ProcessingPlan.Cadence(lastStartedAt: now.addingTimeInterval(86400),
            lastSuccessfulStart: now.addingTimeInterval(86300), retryAfter: now.addingTimeInterval(90000))
        let corrected = futureCadence.adjustingFutureDates(to: now, maximumDelay: PluggedInAnalysisScheduler.interval)
        check(corrected.lastStartedAt == now && corrected.lastSuccessfulStart == now,
              "a clock correction cannot strand starts or night deduplication in the future")
        check(corrected.retryAfter == now.addingTimeInterval(14400), "clock correction bounds persisted retry delay")
        check(!PluggedInAnalysisScheduler.isDue(corrected, now: now.addingTimeInterval(14399))
              && PluggedInAnalysisScheduler.isDue(corrected, now: now.addingTimeInterval(14400)),
              "corrected cadence waits one interval without catch-up bursts")
        let (clockOwner, clockDefaults) = owner(lastStart: now.addingTimeInterval(86400))
        clockOwner.checkPluggedInWork(now: now)
        check(!clockOwner.isBusy && ProcessingPlan.cadence(clockDefaults).lastStartedAt == now,
              "actual admission persists repaired clock state without starting prematurely")

        // Exercise the real observer's idle predicate, including its independent one-second loop.
        let (c, d) = owner()
        let observer = PluggedInAnalysisScheduler()
        var enabled = true, interactionBusy = false
        UserPresence.systemIdleSeconds = 269.9
        observer.start(processing: c, enabled: { enabled }, interactionBusy: { interactionBusy })
        c.checkPluggedInWork()
        check(!c.isBusy, "269.9 seconds is not AFK")
        UserPresence.systemIdleSeconds = 270
        interactionBusy = true; c.checkPluggedInWork()
        check(!c.isBusy, "Sidekick/card work blocks admission")
        interactionBusy = false
        PowerState.fixtureSnapshot = .init(onAC: false, percent: 100, critical: false)
        c.checkPluggedInWork(); check(!c.isBusy, "AFK work is AC-only even at full battery")
        PowerState.fixtureSnapshot = .init(onAC: true, percent: 100, critical: false)
        let before = ProcessingRun.calls
        c.checkPluggedInWork()
        try await until { ProcessingRun.calls == before + 1 }
        let original = c.record.startedAt!
        check(c.record.trigger == .pluggedInIdle && helper.active && TestActivity.active == 1, "admitted idle run holds sleep protection")
        check(ProcessingRun.triggers.last == .pluggedInIdle && ProcessingRun.nightFlags.last == false, "daytime diagnostics and notices do not claim an overnight run")
        check(ProcessingPlan.cadence(d).lastStartedAt == original, "cadence records actual start")
        c.checkPluggedInWork(); await c.runScheduled()
        check(ProcessingRun.calls == before + 1, "simultaneous idle and overnight triggers cannot duplicate")
        UserPresence.systemIdleSeconds = 0
        c.checkPluggedInWork()
        check(c.isBusy && c.state == .stopping && c.record.status == .awaitingIdle, "returning user persists automatic suspension before drain")
        try await until { !helper.active }
        check(TestActivity.active == 0, "sleep protection released while worker drains")
        UserPresence.systemIdleSeconds = 270
        c.checkPluggedInWork()
        check(ProcessingRun.calls == before + 1, "new idle window cannot overlap draining worker")
        try await finish(c)
        check(c.record.status == .awaitingIdle, "activity suspension preserves automatic intent")
        let budget = c.record.activeSeconds!
        c.checkPluggedInWork()
        try await until { ProcessingRun.calls == before + 2 }
        check(c.record.startedAt == original && ProcessingPlan.cadence(d).lastStartedAt == original, "resume preserves original cadence")
        check(c.record.activeSeconds! >= budget, "resume retains accumulated active budget")
        UserPresence.systemIdleSeconds = 0; c.checkPluggedInWork(); c.pause()
        check(c.record.status == .paused, "explicit pause overrides automatic cancellation while draining")
        try await finish(c)
        UserPresence.systemIdleSeconds = 270; c.checkPluggedInWork()
        check(!c.isBusy && c.paused, "explicit pause never auto-resumes")
        observer.stop()
        check(c.requestNow(), "explicit resume starts manually")
        try await until { ProcessingRun.calls == before + 3 }
        check(c.record.trigger == .manual && c.record.startedAt == original, "manual resume retains logical start")
        try await finish(c)
        await c.suspend()

        let (sleeping, _) = owner()
        let sleepObserver = PluggedInAnalysisScheduler()
        UserPresence.systemIdleSeconds = 270
        var sleepEnabled = true
        sleepObserver.start(processing: sleeping, enabled: { sleepEnabled }, interactionBusy: { false })
        sleeping.checkPluggedInWork(); try await until { !ProcessingRun.pending.isEmpty }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        check(sleeping.state == .stopping, "sleep notification suspends AFK processing")
        try await finish(sleeping)
        sleeping.checkPluggedInWork(); check(!sleeping.isBusy, "no analysis is started while asleep")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        UserPresence.systemIdleSeconds = 1
        sleeping.checkPluggedInWork(); check(!sleeping.isBusy, "user wake requires a fresh idle window")
        UserPresence.systemIdleSeconds = 270
        sleeping.checkPluggedInWork(); try await until { !ProcessingRun.pending.isEmpty }
        sleepEnabled = false; sleeping.checkPluggedInWork()
        check(sleeping.state == .stopping, "disabled schedule is rechecked during work")
        try await finish(sleeping)
        sleeping.checkPluggedInWork(); check(!sleeping.isBusy, "disabled schedule cannot resume")
        sleepObserver.stop()

        // No full-run timestamp is consumed until helper setup and final conditions succeed.
        let (late, lateDefaults) = owner()
        helper.blockBegin = true
        late.checkPluggedInWork()
        try await until { helper.beginPending != nil }
        let preStart = ProcessingRun.calls
        PowerState.fixtureSnapshot = .init(onAC: false, percent: 90, critical: false)
        helper.answerBegin(true)
        try await until { !late.isBusy }
        check(ProcessingRun.calls == preStart && late.record.status == .awaitingIdle, "unplug during XPC cannot admit provider work")
        check(late.record.startedAt == nil && ProcessingPlan.cadence(lateDefaults).lastStartedAt! < now, "blocked acquisition does not consume cadence")
        check(!helper.active && TestActivity.active == 0, "late successful awake reply is released")

        let (failedHelper, failedDefaults) = owner()
        helper.beginResult = false
        failedHelper.checkPluggedInWork()
        try await until { !failedHelper.isBusy }
        check(failedHelper.record.status == .awaitingIdle && !helper.active, "failed awake acquisition is deferred and cleaned up")
        let attempts = helper.begins
        failedHelper.checkPluggedInWork()
        check(helper.begins == attempts && ProcessingPlan.cadence(failedDefaults).retryAfter! > Date(), "helper failures have bounded retry")

        let (unplugged, _) = owner()
        unplugged.checkPluggedInWork(); try await until { !ProcessingRun.pending.isEmpty }
        PowerState.fixtureSnapshot = .init(onAC: false, percent: 90, critical: false)
        unplugged.checkPluggedInWork(); try await finish(unplugged)
        check(unplugged.record.status == .awaitingIdle, "unplug preserves automatic resume intent")
        unplugged.startMonitoring()
        try await Task.sleep(for: .milliseconds(10))
        check(!unplugged.isBusy, "pending-work monitor cannot bypass AC/AFK admission")
        await unplugged.suspend()

        let (lostHold, _) = owner()
        lostHold.checkPluggedInWork(); try await until { !ProcessingRun.pending.isEmpty }
        helper.active = false; helper.beginResult = false
        lostHold.fixtureHeartbeatDue(); await lostHold.fixtureMonitor()
        check(lostHold.state == .stopping, "unrecoverable awake hold pauses automatic processing")
        try await finish(lostHold)
        check(lostHold.record.status == .awaitingIdle, "sleep protection failure stays resumable")

        let (limited, limitedDefaults) = owner(record: .init(status: .awaitingIdle, trigger: .pluggedInIdle,
                                                            startedAt: now.addingTimeInterval(-10000), activeSeconds: 21599))
        limited.checkPluggedInWork(); try await until { !ProcessingRun.pending.isEmpty }
        limited.fixtureBudget(21600); await limited.fixtureMonitor()
        check(limited.state == .stopping && limited.record.status == .failed, "accumulated ceiling stops resumed run")
        try await finish(limited)
        check(ProcessingPlan.cadence(limitedDefaults).retryAfter! > Date(), "ceiling cannot restart immediately")

        let (stalled, stalledDefaults) = owner()
        stalled.checkPluggedInWork(); try await until { !ProcessingRun.pending.isEmpty }
        stalled.fixtureStalled(); await stalled.fixtureMonitor()
        check(stalled.state == .stopping, "no-progress watchdog also protects AFK work")
        try await finish(stalled)
        check(ProcessingPlan.cadence(stalledDefaults).retryAfter! > Date(), "stalled work gets retry cooldown")

        let pendingStart = Date().addingTimeInterval(-18000)
        let (pendingNight, _) = owner(record: .init(status: .awaitingIdle, trigger: .pluggedInIdle,
                                                   startedAt: pendingStart, activeSeconds: 123))
        PowerState.fixtureSnapshot = .init(onAC: false, percent: 25, critical: false)
        let continuingNight = Task { await pendingNight.runScheduled() }
        try await Task.sleep(for: .milliseconds(20))
        check(pendingNight.isBusy && pendingNight.record.trigger == .overnight,
              "a suspended AFK run must not block the scheduled battery night")
        try await until { !ProcessingRun.pending.isEmpty }
        check(pendingNight.record.startedAt == pendingStart && pendingNight.record.activeSeconds! >= 123,
              "overnight takeover preserves logical start and awake budget")
        try await finish(pendingNight); await continuingNight.value

        let (firstNight, _) = owner(initial: true)
        firstNight.checkPluggedInWork(); check(!firstNight.isBusy, "AFK does not start initial analysis")
        PowerState.fixtureSnapshot = .init(onAC: false, percent: 39, critical: false)
        await firstNight.runScheduled(); check(!firstNight.isBusy, "initial night rejects 39 percent at coordinator boundary")
        PowerState.fixtureSnapshot = .init(onAC: false, percent: 40, critical: false)
        let night = Task { await firstNight.runScheduled() }
        try await until { !ProcessingRun.pending.isEmpty }
        check(helper.active && firstNight.record.trigger == .overnight, "initial night starts at 40 percent with awake hold")
        try await finish(firstNight); await night.value
        let (updateNight, _) = owner()
        PowerState.fixtureSnapshot = .init(onAC: false, percent: 24, critical: false)
        await updateNight.runScheduled(); check(!updateNight.isBusy, "update night rejects 24 percent")
        PowerState.fixtureSnapshot = .init(onAC: false, percent: 25, critical: false)
        let update = Task { await updateNight.runScheduled() }
        try await until { !ProcessingRun.pending.isEmpty }
        PowerState.fixtureSnapshot = .init(onAC: false, percent: 20, critical: false)
        await updateNight.fixtureMonitor(); check(updateNight.state == .stopping, "overnight stops at reserve through actual monitor")
        let nightStart = updateNight.record.startedAt
        try await finish(updateNight); await update.value
        let nightBudget = updateNight.record.activeSeconds
        updateNight.deferNight(notice: "Fixture time edit")
        check(updateNight.record.startedAt == nightStart && updateNight.record.activeSeconds == nightBudget,
              "editing a deferred night preserves its unfinished run and awake budget")
        PowerState.fixtureSnapshot = .init(onAC: true, percent: 25, critical: false)
        updateNight.checkPluggedInWork(); try await until { !ProcessingRun.pending.isEmpty }
        check(updateNight.record.trigger == .pluggedInIdle && updateNight.record.startedAt == nightStart,
              "plugged-in AFK can continue a power-paused night without resetting the start")
        try await finish(updateNight)

        let (stalledNight, stalledNightDefaults) = owner()
        let stalledNightTask = Task { await stalledNight.runScheduled() }
        try await until { !ProcessingRun.pending.isEmpty }
        stalledNight.fixtureStalled(); await stalledNight.fixtureMonitor()
        try await finish(stalledNight); await stalledNightTask.value
        stalledNight.checkPluggedInWork()
        check(!stalledNight.isBusy && ProcessingPlan.cadence(stalledNightDefaults).retryAfter! > Date(),
              "AFK handoff cannot immediately restart a stalled overnight attempt")
        check(stalledNight.record.startedAt == nil, "terminal overnight failure is not an unfinished active segment")

        let (failure, failureDefaults) = owner()
        failure.checkPluggedInWork(); try await until { !ProcessingRun.pending.isEmpty }
        try await finish(failure, result: .init(failure: CycleFailure(), complete: false))
        failure.checkPluggedInWork(now: Date().addingTimeInterval(1))
        check(!failure.isBusy && ProcessingPlan.cadence(failureDefaults).retryAfter!.timeIntervalSinceNow > 14390, "failed analysis waits four hours before retry")

        let (complete, completeDefaults) = owner()
        complete.checkPluggedInWork(); try await until { !ProcessingRun.pending.isEmpty }
        let successfulStart = complete.record.startedAt
        try await finish(complete)
        check(ProcessingPlan.cadence(completeDefaults).lastSuccessfulStart == successfulStart, "success retains start-based cadence")
        complete.checkPluggedInWork(); await complete.runScheduled()
        check(!complete.isBusy, "recent full run satisfies both automatic triggers")
        let restored = ProcessingCoordinator(defaults: completeDefaults)
        restored.pluggedInEnvironmentAllowsRun = { true }; restored.checkPluggedInWork()
        check(!restored.isBusy, "relaunch cannot reset the four-hour cooldown")

        let (cleanup, _) = owner()
        cleanup.checkPluggedInWork(); try await until { !ProcessingRun.pending.isEmpty }
        helper.blockEnd = true; ProcessingRun.finish()
        try await until { helper.endPending != nil }
        check(cleanup.isBusy && cleanup.record.status == .completed, "analysis retains ownership through helper cleanup")
        ProcessingRun.lateProgress?(RunProgress(done: 999, total: 999))
        try await Task.sleep(for: .milliseconds(10))
        check(cleanup.progress.done != 999, "late progress cannot overwrite the completed result during cleanup")
        let beforeCleanup = ProcessingRun.calls
        cleanup.checkPluggedInWork(now: Date().addingTimeInterval(86400)); cleanup.pause()
        check(ProcessingRun.calls == beforeCleanup && cleanup.record.status == .completed,
              "late idle or Pause cannot replace completed work during cleanup")
        check(!cleanup.requestNow(), "manual run also waits for helper cleanup")
        helper.answerEnd(); try await until { !cleanup.isBusy }
        check(!helper.active && TestActivity.active == 0, "delayed cleanup releases exactly its own hold")

        let (disabled, _) = owner()
        disabled.checkPluggedInWork(); try await until { !ProcessingRun.pending.isEmpty }
        disabled.cancelScheduled()
        check(disabled.state == .stopping, "disabling automatic analysis stops idle run")
        try await finish(disabled)

        let (reset, resetDefaults) = owner()
        reset.checkPluggedInWork(); try await until { !ProcessingRun.pending.isEmpty }
        let resetting = Task { await reset.reset() }
        try await until { reset.isSuspended }
        reset.checkPluggedInWork(); ProcessingRun.finish(); await resetting.value
        check(!reset.isBusy && !helper.active && !reset.initialComplete && reset.record.status == .idle, "reset drains and clears intent")
        check(resetDefaults.object(forKey: ProcessingPlan.cadenceKey) == nil, "reset removes cadence")
        check(TestActivity.active == 0 && PipelineActivity.shared.activeRuns == 0, "no leaked analysis ownership or sleep assertions")

        let (neverStarted, _) = owner()
        let previousHistory = try DiagnosticHistory.snapshot(defaults: FixtureDefaults.history).pluggedInIdle?.count ?? 0
        neverStarted.checkPluggedInWork(); neverStarted.pause()
        try await until { !neverStarted.isBusy }
        let afterHistory = try DiagnosticHistory.snapshot(defaults: FixtureDefaults.history).pluggedInIdle?.count ?? 0
        check(afterHistory == previousHistory && helper.begins == 0,
              "Pause before worker startup cannot create a dangling running diagnostic")

        let completedStart = Date().addingTimeInterval(-3600)
        let (terminalPause, terminalDefaults) = owner(record: .init(status: .completed, trigger: .manual,
                                                                   startedAt: completedStart, activeSeconds: 10))
        terminalPause.pause()
        let requestedAt = Date()
        check(terminalPause.requestNow(), "resume after pausing an already completed cycle")
        try await until { !ProcessingRun.pending.isEmpty }
        check(terminalPause.record.startedAt! >= requestedAt && ProcessingPlan.cadence(terminalDefaults).lastStartedAt! >= requestedAt,
              "a new analysis after terminal Pause gets a new four-hour anchor")
        try await finish(terminalPause); await terminalPause.suspend()

        let (latePause, _) = owner()
        latePause.checkPluggedInWork(); try await until { !ProcessingRun.pending.isEmpty }
        helper.blockEnd = true
        latePause.pluggedInEnvironmentAllowsRun = { false }
        latePause.checkPluggedInWork(); ProcessingRun.finish()
        try await until { helper.endPending != nil && latePause.state == .waiting(.idle) }
        latePause.pause()
        helper.answerEnd(); try await until { !latePause.isBusy }
        check(latePause.paused && latePause.state == .paused,
              "explicit Pause during final helper cleanup leaves a truthful paused state")

        let (lease, _) = owner()
        lease.checkPluggedInWork(); try await until { !ProcessingRun.pending.isEmpty }
        let oldID = lease.fixtureRunID
        try await finish(lease)
        check(lease.requestNow(), "start a later manual run")
        try await until { !ProcessingRun.pending.isEmpty }
        // Explicitly acquire the real production lease path for this later run.
        lease.fixtureRequireAwake()
        check(await lease.fixtureMaintain(), "later run obtains its own hold")
        await lease.fixtureRelease(for: oldID)
        check(helper.active, "stale cleanup cannot release a later run's awake hold")
        check(!(await lease.fixtureMaintain(for: oldID)), "stale heartbeat cannot join a later awake update")
        try await finish(lease); await lease.suspend()

        // New diagnostic category must neither corrupt old ledgers nor count as a night.
        let historyDefaults = defaults()
        let oldHistory = #"{"doubleTap":[],"overnight":[],"errors":[]}"#.data(using: .utf8)!
        historyDefaults.set(oldHistory, forKey: DiagnosticHistory.key)
        check(try DiagnosticHistory.snapshot(defaults: historyDefaults).pluggedInIdle?.isEmpty == true, "old history decodes")
        let historyID = DiagnosticHistory.begin(.pluggedInIdle, defaults: historyDefaults)
        DiagnosticHistory.finish(.pluggedInIdle, id: historyID, outcome: .completed, defaults: historyDefaults)
        let history = try DiagnosticHistory.snapshot(defaults: historyDefaults)
        check(history.pluggedInIdle?.last?.outcome == .completed && history.lastOvernightSuccessAt == nil
              && history.firstOvernightAttemptAt == nil && history.overnight.isEmpty, "idle history does not masquerade as overnight work")
        enabled = false
        print("PASS \(checks) plugged-in analysis lifecycle checks")
    }
}
