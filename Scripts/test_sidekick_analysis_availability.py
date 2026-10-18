#!/usr/bin/env python3
"""Exercise real shortcut admission and durable analysis timing without launching the app.

Production method bodies are compiled verbatim, including the tap-pair recognizer,
onboarding guards, delayed single tap, Double Tap dispatch and analysis timing choice.
Only native input snapshots, capture/UI effects and the surrounding app shell are inert.
Hotkey defaults use process-local volatile overrides; plan writes use a unique suite.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"


def member(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def declaration(source: str, signature: str) -> str:
    return next(line for line in source.splitlines() if line.strip().startswith(signature))


FIXTURE = r'''
import Foundation

enum CodexTrigger { case onboarding, analyzeNow, overnight }
func Log(_ value: String) {}
enum AppState { static let onboardingKey = "hasCompletedOnboarding" }
enum ShortcutKey: Equatable { case rightCommand, leftCommand }
enum ShortcutPreferences { static var current = ShortcutKey.rightCommand; static var isRecording = false }
struct ShortcutActivity: Equatable {
    var keys: UInt32 = 0; var clicks: UInt32 = 0; var scrolls: UInt32 = 0
    static var current = ShortcutActivity()
    static var lastInputTime: TimeInterval = -.infinity
}
// TAP_PAIR
enum CodexAuth { static var knowledgeBaseOnly = false }
final class ComputerUseGate {
    static let shared = ComputerUseGate()
    var refreshes = 0
    func refresh() { refreshes += 1 }
}
final class DoubleTap {
    static let shared = DoubleTap()
    var isDrafting = false
    var captures = 0
    enum Result { case pasted, notAMessage, stopped, failed(String) }
    func start(completion: (Result) -> Void) { captures += 1; completion(.pasted) }
    // DOUBLE_TAP_PREFERENCES
}
enum NotchPhase: Equatable { case hidden, opening, typing, listening, transcribing, running, message, notice(String) }
final class Recovery {
    var isPending = false; var isVisible = false; var reopened = 0
    func dismiss() { isVisible = false }
    func reopen() { reopened += 1; isVisible = true }
}
final class Run { var isClearingChat = false; var isRunning = false; let recovery = Recovery() }
final class CommandCoordinator {
    let run = Run()
    var phase = NotchPhase.hidden
    var phaseToken = 0
    var hotkeyPair = ShortcutTapPair()
    var pendingSingleTap: Task<Void, Never>?
    var doubleTapDemoKeyChanged: ((Bool) -> Void)?
    var onboardingDemoArmed = false
    var messageReplyFocused = false
    enum Anchor { case mainDisplay }
    var notchAnchor = Anchor.mainDisplay
    static let needsPlusNotice = "get ChatGPT Plus to wake Sidekick"
    static let notchDemoPlayedKey = "onboarding.notchDemoPlayed"
    static let finishOnboardingNotice = "finish onboarding to use Sidekick"
    func beginNotchDemo(door: String) {}
    func routeAttention() {}
    func dismissTyping() { setPhase(.hidden) }
    func cancelCurrent() { setPhase(.hidden) }
    func flash(_ text: String, for duration: Double) { setPhase(.notice(text)) }
    func tap(_ time: TimeInterval, key: ShortcutKey = .rightCommand) {
        hotkeyTapped(key, at: time, activity: ShortcutActivity.current)
    }
    func interrupt() { interruptHotkeyGesture() }
    // COORDINATOR_METHODS
}
enum OvernightScheduler {
    // SCHEDULER_MEMBERS
}
struct RunProgress { var done = 0 }
final class ProcessingCoordinator {
    enum Timing { case now, overnight }
    enum State: Equatable { case idle, scheduled }
    let defaults: UserDefaults
    var isBusy = false
    var state = State.idle
    var requestOverride: String? = "fixture"
    var carried = RunProgress(done: 7)
    // PROCESSING_RECORD
    init(defaults: UserDefaults) { self.defaults = defaults; self.record = ProcessingPlan.read(defaults) }
    // PROCESSING_CHOOSE
}

@main enum Tests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label); checks += 1
    }
    static func until(_ ready: () -> Bool) async throws {
        for _ in 0..<200 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Expected delayed shortcut did not settle")
    }
    static func waitOutGesture() async throws {
        try await Task.sleep(for: .seconds(DoubleTap.window + 0.10))
    }
    static func configure(initial: Bool = false, doubleTap: Bool = true, onboarding: Bool = true) {
        // These overrides exist only inside this subprocess; no standard-domain writes.
        UserDefaults.standard.setVolatileDomain([
            AppState.onboardingKey: onboarding,
            ProcessingPlan.initialCompletedKey: initial ? 1_700_000_000.0 : 0.0,
            DoubleTap.enabledKey: doubleTap,
            CommandCoordinator.notchDemoPlayedKey: false,
            OvernightScheduler.minutesKey: 21 * 60 + 47,
        ], forName: UserDefaults.argumentDomain)
        ShortcutActivity.current = .init(); ShortcutActivity.lastInputTime = -.infinity
        ShortcutPreferences.isRecording = false
        ComputerUseGate.shared.refreshes = 0; DoubleTap.shared.captures = 0
        DoubleTap.shared.isDrafting = false; CodexAuth.knowledgeBaseOnly = false
    }

    static func shortcuts() async throws {
        configure()
        check(!DoubleTap.initialAnalysisComplete && DoubleTap.isEnabled, "preanalysis milestone and enabled preference remain distinct")
        let single = CommandCoordinator()
        single.tap(100)
        check(single.phase == .hidden && ComputerUseGate.shared.refreshes == 0, "first preanalysis tap waits without opening a gate or notch")
        try await until { single.phase == .typing }
        check(ComputerUseGate.shared.refreshes == 1 && DoubleTap.shared.captures == 0, "single tap opens Sidekick before any analysis finishes")

        configure()
        let earlyPair = CommandCoordinator()
        earlyPair.tap(200); earlyPair.tap(200.1)
        try await waitOutGesture()
        check(earlyPair.phase == .hidden && ComputerUseGate.shared.refreshes == 0 && DoubleTap.shared.captures == 0,
              "early double tap is consumed without Sidekick fallback, permissions or capture")

        configure(initial: true)
        check(DoubleTap.initialAnalysisComplete, "actual DoubleTap gate recognizes shipped legacy milestone key")
        let readyPair = CommandCoordinator()
        readyPair.tap(300)
        check(readyPair.phase == .opening, "postanalysis first tap enters normal opening gesture")
        readyPair.tap(300.1)
        try await waitOutGesture()
        check(DoubleTap.shared.captures == 1 && readyPair.phase == .hidden,
              "postanalysis double tap dispatches once and cancels deferred typing")

        configure(doubleTap: false)
        let optedOut = CommandCoordinator()
        optedOut.tap(400)
        check(optedOut.phase == .typing && ComputerUseGate.shared.refreshes == 1 && DoubleTap.shared.captures == 0,
              "Double Tap opt-out still opens Sidekick immediately before analysis")

        configure()
        let interrupted = CommandCoordinator()
        interrupted.tap(500); interrupted.interrupt()
        try await waitOutGesture()
        check(interrupted.phase == .hidden && ComputerUseGate.shared.refreshes == 0, "interruption cancels pending early single tap")
        let typedElsewhere = CommandCoordinator()
        typedElsewhere.tap(600); ShortcutActivity.current.keys += 1
        try await waitOutGesture()
        check(typedElsewhere.phase == .hidden && ComputerUseGate.shared.refreshes == 0,
              "intervening user input cannot have focus stolen by delayed Sidekick")

        configure()
        let running = CommandCoordinator()
        running.run.isRunning = true; running.phase = .running
        running.tap(700)
        try await waitOutGesture()
        check(running.run.isRunning && running.phase == .running && ComputerUseGate.shared.refreshes == 0,
              "early single tap never replaces or stops an already-owned Sidekick task")
        running.tap(800); running.tap(800.1)
        try await waitOutGesture()
        check(running.run.isRunning && running.phase == .running && DoubleTap.shared.captures == 0,
              "early double tap cannot disturb active task ownership")
        configure(initial: true)
        running.tap(900); running.tap(900.1)
        check(running.run.isRunning && running.phase == .running && DoubleTap.shared.captures == 1,
              "ready Double Tap remains independent of a running Sidekick task")

        configure()
        let question = CommandCoordinator()
        question.run.recovery.isPending = true
        question.tap(1_000)
        try await until { question.run.recovery.reopened == 1 }
        check(ComputerUseGate.shared.refreshes == 0, "single early tap can reopen an actual pending Sidekick question")
        configure()
        let clearing = CommandCoordinator()
        clearing.tap(1_100); clearing.run.isClearingChat = true
        try await waitOutGesture()
        check(clearing.phase == .hidden && ComputerUseGate.shared.refreshes == 0, "clear-chat lock suppresses pending early gesture")
        configure(onboarding: false)
        let notSetup = CommandCoordinator()
        notSetup.tap(1_200)
        try await waitOutGesture()
        check(notSetup.phase == .hidden && ComputerUseGate.shared.refreshes == 0, "setup completion remains required independently of initial analysis")
        configure()
        CodexAuth.knowledgeBaseOnly = true
        let planRestricted = CommandCoordinator()
        planRestricted.tap(1_300)
        try await until { if case .notice = planRestricted.phase { return true }; return false }
        check(ComputerUseGate.shared.refreshes == 0, "existing account-plan restriction survives analysis decoupling")
    }

    static func plans() throws {
        configure()
        // NSArgumentDomain also participates in named-suite reads. Remove the hotkey-only
        // milestone override so these tests inspect the suite's actual durable value.
        var overrides = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        overrides.removeValue(forKey: ProcessingPlan.initialCompletedKey)
        UserDefaults.standard.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        let name = "sentient.analysis-availability." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        check(ProcessingPlan.initialCompletedAt(defaults) == nil, "new analysis plan has no invented milestone")
        let legacy = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(legacy.timeIntervalSince1970, forKey: "scheduler.firstCycleCompletedAt")
        check(ProcessingPlan.initialCompletedAt(defaults) == legacy, "old shipped completion date survives update")
        ProcessingPlan.completeInitial(defaults, at: legacy.addingTimeInterval(500))
        check(ProcessingPlan.initialCompletedAt(defaults) == legacy, "later completions do not rewrite first completion")
        defaults.removeObject(forKey: ProcessingPlan.initialCompletedKey)
        let owner = ProcessingCoordinator(defaults: defaults)
        owner.choose(.overnight)
        let scheduled = ProcessingPlan.read(defaults)
        check(scheduled.status == .scheduled && scheduled.trigger == .overnight && scheduled.due != nil,
              "actual timing choice persists overnight intent before Home opens")
        let due = Calendar.current.dateComponents([.hour, .minute], from: scheduled.due!)
        check(due.hour == 21 && due.minute == 47, "overnight choice respects configured analysis time")
        check(owner.requestOverride == nil && owner.carried.done == 0 && owner.state == .scheduled,
              "new timing choice clears previous request/progress and exposes scheduled state")
        check(ProcessingPlan.initialCompletedAt(defaults) == nil, "scheduling first night does not unlock Double Tap")
        let reloaded = UserDefaults(suiteName: name)!
        check(ProcessingPlan.read(reloaded) == scheduled, "chosen timing survives a new defaults handle")
        owner.choose(.now)
        let requested = ProcessingPlan.read(defaults)
        check(requested.status == .requested && requested.trigger == .onboarding && requested.due == nil && owner.state == .idle,
              "run-now choice persists requested work without awaiting execution")
        check(ProcessingPlan.initialCompletedAt(defaults) == nil, "requesting now does not pretend analysis completed")
        owner.isBusy = true; owner.choose(.overnight)
        check(ProcessingPlan.read(defaults) == requested, "timing changes cannot replace a live analysis owner")
        for trigger: ProcessingPlan.Trigger in [.onboarding, .manual, .developer, .overnight] {
            let interrupted = ProcessingPlan.Record(status: .running, trigger: trigger)
            let recovered = ProcessingPlan.recovered(interrupted)
            check(recovered.status == (trigger == .overnight ? .scheduled : .requested), "interrupted work recovers according to its original trigger")
            check(recovered.trigger == trigger && recovered.notice != nil, "recovery preserves ownership and explains interruption")
        }
        for status: ProcessingPlan.Status in [.idle, .scheduled, .requested, .paused, .failed, .completed] {
            let value = ProcessingPlan.Record(status: status, trigger: .manual)
            check(ProcessingPlan.recovered(value) == value, "nonrunning analysis state stays intact on relaunch")
            ProcessingPlan.save(value, to: defaults)
            check(ProcessingPlan.initialCompletedAt(defaults) == nil, "plan status alone never establishes successful initial analysis")
        }
        ProcessingPlan.completeInitial(defaults, at: legacy)
        check(ProcessingPlan.initialCompletedAt(reloaded) == legacy, "only explicit initial completion persists unlock milestone")
    }

    static func main() async throws {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        try await shortcuts()
        try plans()
        print("PASS \(checks) Sidekick/analysis availability assertions")
    }
}
'''


def main() -> None:
    coordinator = (APP / "Notch Magic/CommandCoordinator.swift").read_text()
    double_tap = (APP / "Double Tap/DoubleTap.swift").read_text()
    gesture = (APP / "System/Shortcuts/ShortcutGesture.swift").read_text()
    processing = (APP / "Ingestion/ProcessingCoordinator.swift").read_text()
    scheduler = (APP / "Scheduling/OvernightScheduler.swift").read_text()
    methods = "\n".join(member(coordinator, signature) for signature in [
        "    private static var hasCompletedOnboarding:", "    private func interceptForOnboarding()",
        "    private func interruptHotkeyGesture()", "    private func hotkeyTapped(",
        "    private func handleSingleTap(", "    private func fireDoubleTap()",
        "    private func setPhase(",
    ])
    preferences = "\n".join([
        declaration(double_tap, "static let window:"), declaration(double_tap, "static let enabledKey"),
        member(double_tap, "    static var isEnabled:"), member(double_tap, "    static var initialAnalysisComplete:"),
    ])
    dates = "\n".join([
        declaration(scheduler, "static let minutesKey"), declaration(scheduler, "static let defaultMinutes"),
        member(scheduler, "    static var configuredMinutes:"), member(scheduler, "    static func validatedMinutes("),
        member(scheduler, "    static func nextOccurrence("),
    ])
    code = (FIXTURE.replace("// TAP_PAIR", member(gesture, "struct ShortcutTapPair"))
            .replace("// DOUBLE_TAP_PREFERENCES", preferences)
            .replace("// COORDINATOR_METHODS", methods)
            .replace("// SCHEDULER_MEMBERS", dates)
            .replace("// PROCESSING_RECORD", member(processing, "    private(set) var record: ProcessingPlan.Record"))
            .replace("// PROCESSING_CHOOSE", member(processing, "    func choose(")))
    with tempfile.TemporaryDirectory(prefix="sentient-analysis-availability-") as temporary:
        root = Path(temporary)
        fixture = root / "Availability.swift"
        fixture.write_text(code)
        executable = root / "availability-tests"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
                        "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library",
                        str(APP / "Ingestion/ProcessingPlan.swift"), str(fixture), "-o", str(executable)],
                       check=True, timeout=60)
        subprocess.run([str(executable)], check=True, timeout=20)


if __name__ == "__main__":
    main()
