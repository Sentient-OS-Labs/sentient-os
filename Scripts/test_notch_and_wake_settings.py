#!/usr/bin/env python3
"""Run real scheduling/control methods with isolated defaults and an in-memory wake helper.

No application launch, actual wake scheduling, root helper, or user preference changes.
Only the overnight processing pipeline is replaced; schedule edits/loop/clock logic is production.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"

SUPPORT = r'''
import Foundation
import Observation
import AppKit

nonisolated enum Fixture {
    static let suite = "ai.sentient.wake-settings-test." + UUID().uuidString
    static let defaults = UserDefaults(suiteName: suite)!
}
nonisolated func Log(_ text: String) {}
enum Analytics { static func signal(_ text: String, parameters: [String: String] = [:]) {} }
enum CodexAuth { static var knowledgeBaseOnly = false }
enum LoginItem { static var isEnabled = true }
enum AppState { static let onboardingKey = "fixture.onboarded" }
enum WakeHelperConfig { static let maxAwakeSeconds = 7200 }
enum CodexTrigger { case onboarding, analyzeNow, overnight }
enum ModelBackend: String { case chatgpt; static let current = Self.chatgpt }
enum DiagnosticHistory {
    enum Kind { case overnight }
    enum Outcome { case blocked }
    static func begin(_ kind: Kind, provider: String) -> UUID { UUID() }
    static func finish(_ kind: Kind, id: UUID, outcome: Outcome, reason: String) {}
}
final class SchedulerLog { func line(_ text: String) {} }
final class WakeHelperClient {
    enum Health { case ready, requiresApproval }
    static let shared = WakeHelperClient()
    var armed: [Date] = []
    var effectiveWakes = Set<Date>()
    private var trackedWake: Date?
    var holdNextArm = false
    var pending: CheckedContinuation<Bool, Never>?
    var broadCancels = 0
    var awakeHeld = false
    var endAwakeCalls = 0
    func healthProbe() async -> Health { .ready }
    func cancelAllWakes() async -> Bool { broadCancels += 1; effectiveWakes.removeAll(); trackedWake = nil; return true }
    func cancelWake() async -> Bool {
        if let trackedWake { effectiveWakes.remove(trackedWake) }
        trackedWake = nil
        return true
    }
    func endAwake() async -> Bool { endAwakeCalls += 1; awakeHeld = false; return true }
    func armWake(at date: Date) async -> Bool {
        armed.append(date)
        let result: Bool
        if holdNextArm {
            holdNextArm = false
            // Like non-cancellable XPC, this can apply a wake after its caller is cancelled.
            result = await withCheckedContinuation { pending = $0 }
        } else { result = true }
        if result { effectiveWakes.insert(date); trackedWake = date }
        return result
    }
}
struct ProcessingRequest { static func current() -> Self { Self() } }
struct RunProgress {}
final class ProcessingCoordinator {
    static let shared = ProcessingCoordinator()
    enum Timing { case now, overnight }
    enum State { case idle, scheduled }
    enum Block: String { case battery }
    enum Wait { case power(Block), model, sources }
    var record = ProcessingPlan.Record() { didSet { ProcessingPlan.save(record, to: Fixture.defaults) } }
    var state = State.idle
    var initialComplete = true
    var isBusy = false
    var isSuspended = false
    var paused: Bool { record.status == .paused }
    var hasPendingFirstNight: Bool { !initialComplete && record.status == .scheduled }
    var requestOverride: ProcessingRequest?
    var carried = RunProgress()
    var task: Task<Void, Never>?
    var finishContinuation: CheckedContinuation<Void, Never>?
    var runsStarted = 0
    static func scheduleLabel(_ date: Date) -> String { "fixture schedule" }
    private func admission(_ request: ProcessingRequest, scheduled: Bool) -> Wait? { nil }
    private func detail(for wait: Wait) -> String { "fixture admission" }
    private func begin(_ request: ProcessingRequest) {
        isBusy = true; record.status = .running; record.due = nil
        WakeHelperClient.shared.awakeHeld = true
        task = Task {
            runsStarted += 1
            await withCheckedContinuation { finishContinuation = $0 }
            isBusy = false; record.status = .completed
            WakeHelperClient.shared.awakeHeld = false
            task = nil
        }
    }
    func finishOwnedRun() {
        let continuation = finishContinuation; finishContinuation = nil
        continuation?.resume()
    }
    // PRODUCTION_PROCESSING_CONTROL_METHODS
}

// Replace screen geometry and panel IO, while compiling actual production hover/passthrough methods.
enum NotchPhase { case hidden, opening, typing, running, listening, transcribing, recovery, message }
final class PointerPanel { var ignoresMouseEvents = true }
final class PointerRecovery { func setHovering(_ value: Bool) {} }
final class PointerRun { let recovery = PointerRecovery() }
final class PointerCoordinator {
    var phase = NotchPhase.hidden
    var notchButtonAvailable = true
    let run = PointerRun()
    func setMessagePreviewHovering(_ value: Bool) {}
}
final class PointerProbe {
    let coordinator = PointerCoordinator()
    var panel: PointerPanel? = PointerPanel()
    var hovering = false
    var notchClickEnabled = true
    var cursorInside = true
    var mouseTimerInterval = 0.0
    static let pollFar = 0.1
    let nearZone = NSRect(x: 0, y: 0, width: 100, height: 40)
    var hoverEntryRect = NSRect(x: 0, y: 0, width: 100, height: 40)
    func retuneMouseTimer() {}
    func beginHover() { hovering = true }
    func endHover() { hovering = false; panel?.ignoresMouseEvents = true }
    func cursorNearNotch() -> Bool { cursorInside }
    func cursorOverSilhouette() -> Bool { cursorInside }
    func cursorStillHovering() -> Bool { cursorInside }
    // PRODUCTION_POINTER_METHODS
}
'''

TESTS = r'''
@main enum Tests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { fatalError("FAIL: " + label) }
        checks += 1
    }
    static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out waiting for scheduler")
    }
    static func main() async throws {
        let d = Fixture.defaults
        defer { d.removePersistentDomain(forName: Fixture.suite) }
        check(NotchPreferences.clickEnabled(in: d), "existing installs retain clickable notch")
        d.set(false, forKey: NotchPreferences.clickEnabledKey)
        check(!NotchPreferences.clickEnabled(in: d), "idle notch click opt-out persists")
        d.set(true, forKey: NotchPreferences.clickEnabledKey)
        check(NotchPreferences.clickEnabled(in: d), "click affordance can be restored")
        let pointer = PointerProbe()
        pointer.notchClickEnabled = false
        pointer.hoverMouseMoved(at: NSPoint(x: 50, y: 10))
        pointer.updateMousePassthrough()
        check(!pointer.hovering && pointer.panel!.ignoresMouseEvents, "disabled idle notch passes clicks to other apps")
        for phase in [NotchPhase.typing, .running, .listening, .transcribing, .message, .recovery] {
            pointer.coordinator.phase = phase
            pointer.cursorInside = true; pointer.updateMousePassthrough()
            check(!pointer.panel!.ignoresMouseEvents, "expanded notch remains interactive with idle clicks disabled")
            pointer.cursorInside = false; pointer.updateMousePassthrough()
            check(pointer.panel!.ignoresMouseEvents, "outside expanded notch remains click-through")
        }
        pointer.coordinator.phase = .hidden; pointer.cursorInside = true
        pointer.notchClickEnabled = true
        pointer.hoverMouseMoved(at: NSPoint(x: 50, y: 10)); pointer.updateMousePassthrough()
        check(pointer.hovering && !pointer.panel!.ignoresMouseEvents, "enabled idle notch still opens on hover/click")

        check(OvernightScheduler.configuredMinutes == 180, "fresh install remains at 3 AM")
        d.set(267, forKey: "dbg.scheduler.minutes")
        check(OvernightScheduler.configuredMinutes == 267, "legacy configured wake time preserved")
        for value in [-1, 1440, Int.max] {
            d.set(value, forKey: OvernightScheduler.minutesKey)
            check(OvernightScheduler.configuredMinutes == 180, "invalid stored times fall back safely")
        }
        for value in [0, 1, 1439] {
            d.set(value, forKey: OvernightScheduler.minutesKey)
            check(OvernightScheduler.configuredMinutes == value, "full day supported")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        func next(_ minutes: Int, _ now: Date) -> Date {
            OvernightScheduler.nextOccurrence(minutesSinceMidnight: minutes, now: now, calendar: calendar)
        }
        check(next(180, date(2026, 10, 18, 1)) == date(2026, 10, 18, 3), "later today")
        check(next(180, date(2026, 10, 18, 4)) == date(2026, 10, 19, 3), "passed time goes to tomorrow")
        check(next(180, date(2026, 10, 18, 3)) == date(2026, 10, 19, 3), "no immediate repeat at exact scheduled time")
        check(next(0, date(2026, 12, 31, 23, 59)) == date(2027, 1, 1, 0), "midnight and year rollover")
        check(next(150, date(2026, 3, 8, 0)) == date(2026, 3, 8, 3), "missing DST hour uses next valid time")
        check(next(150, date(2026, 3, 8, 4)) == date(2026, 3, 9, 2, 30), "day after gap returns to chosen time")
        let firstFall = next(90, date(2026, 11, 1, 0))
        check(calendar.timeZone.secondsFromGMT(for: firstFall) == -7 * 3600, "fall-back uses first occurrence")
        check(next(90, firstFall) == date(2026, 11, 2, 1, 30), "fall-back does not run twice")

        d.set(true, forKey: AppState.onboardingKey)
        let helper = WakeHelperClient.shared
        let processing = ProcessingCoordinator.shared
        let scheduler = OvernightScheduler()
        scheduler.commit()
        try await Task.sleep(for: .milliseconds(30))
        check(helper.armed.isEmpty, "saving while disabled does not arm or enable scheduler")

        d.set(true, forKey: OvernightScheduler.prodEnabledKey)
        let nowParts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let first = ((nowParts.hour! * 60 + nowParts.minute!) + 60) % 1440
        let second = (first + 60) % 1440
        let third = (second + 60) % 1440
        d.set(first, forKey: OvernightScheduler.minutesKey)
        scheduler.commit()
        try await until { scheduler.nextWakeAt != nil }
        check(helper.armed.count == 1, "production-only enabled setting arms")
        check(helper.effectiveWakes == [scheduler.nextWakeAt!], "exactly one owned wake initially armed")
        check(!d.bool(forKey: OvernightScheduler.enabledKey), "no developer toggle needed")
        d.set(second, forKey: OvernightScheduler.minutesKey)
        scheduler.commit()
        try await until { helper.armed.count == 2 && scheduler.nextWakeAt != nil }
        let selected = Calendar.current.dateComponents([.hour, .minute], from: scheduler.nextWakeAt!)
        check(selected.hour! * 60 + selected.minute! == second, "time edit interrupts waiting and re-arms promptly")
        check(helper.effectiveWakes == [scheduler.nextWakeAt!], "changing time removes the previous physical wake")

        helper.holdNextArm = true
        d.set(first, forKey: OvernightScheduler.minutesKey)
        scheduler.commit()
        try await until { helper.pending != nil }
        d.set(third, forKey: OvernightScheduler.minutesKey)
        scheduler.commit()
        try await Task.sleep(for: .milliseconds(30))
        check(helper.armed.count == 3, "new arm waits for old in-flight XPC arm to drain")
        helper.pending!.resume(returning: true); helper.pending = nil
        try await until { helper.armed.count == 4 && scheduler.nextWakeAt != nil }
        let latest = Calendar.current.dateComponents([.hour, .minute], from: scheduler.nextWakeAt!)
        check(latest.hour! * 60 + latest.minute! == third, "edit during in-flight arm wins without stale wake")
        check(helper.effectiveWakes == [scheduler.nextWakeAt!], "late old arm is removed before newest arm")
        d.set(false, forKey: OvernightScheduler.prodEnabledKey)
        scheduler.reevaluate()
        try await Task.sleep(for: .milliseconds(30))
        check(scheduler.nextWakeAt == nil && scheduler.statusLine == "off", "disable still clears scheduled state")


        // Rapid off/on also drains old helper IO before cancel/re-arm can overlap.
        d.set(true, forKey: OvernightScheduler.prodEnabledKey)
        helper.holdNextArm = true
        scheduler.reevaluate()
        try await until { helper.pending != nil }
        let heldArms = helper.armed.count
        d.set(false, forKey: OvernightScheduler.prodEnabledKey); scheduler.reevaluate()
        d.set(third, forKey: OvernightScheduler.minutesKey)
        d.set(true, forKey: OvernightScheduler.prodEnabledKey); scheduler.reevaluate()
        try await Task.sleep(for: .milliseconds(30))
        check(helper.armed.count == heldArms, "off/on cannot bypass previous arm drain")
        helper.pending!.resume(returning: true); helper.pending = nil
        try await until { scheduler.nextWakeAt != nil }
        check(helper.effectiveWakes == [scheduler.nextWakeAt!], "off/on leaves only the current owned wake")
        d.set(false, forKey: OvernightScheduler.prodEnabledKey); scheduler.reevaluate()
        try await until { helper.effectiveWakes.isEmpty }

        // The actual coordinator choice/defer methods honor the custom time, including
        // pending first analysis for knowledge-base-only users with production toggle off.
        processing.initialComplete = false
        CodexAuth.knowledgeBaseOnly = true
        d.set(first, forKey: OvernightScheduler.minutesKey)
        processing.choose(.overnight)
        let chosen = Calendar.current.dateComponents([.hour, .minute], from: processing.record.due!)
        check(chosen.hour! * 60 + chosen.minute! == first, "first-night choice uses configured clock time")
        processing.record.notice = "Preserve the existing notice"
        let oldDue = processing.record.due
        d.set(second, forKey: OvernightScheduler.minutesKey)
        scheduler.commit()
        try await until { scheduler.nextWakeAt != nil }
        let pending = Calendar.current.dateComponents([.hour, .minute], from: processing.record.due!)
        check(pending.hour! * 60 + pending.minute! == second && processing.record.due != oldDue,
              "commit updates persisted pending first-night due before scheduler reads it")
        check(ProcessingPlan.read(d).due == processing.record.due, "rescheduled due is durable")
        check(processing.record.notice == "Preserve the existing notice", "reschedule retains pending notice")
        check(!d.bool(forKey: OvernightScheduler.prodEnabledKey) && scheduler.nextWakeAt == processing.record.due,
              "pending first night re-arms without enabling production toggle")
        processing.record.status = .idle; scheduler.reevaluate()
        try await until { helper.effectiveWakes.isEmpty }
        processing.initialComplete = true; CodexAuth.knowledgeBaseOnly = false

        // Use production runScheduled: the new owner creates and awaits independent work.
        d.set(true, forKey: OvernightScheduler.prodEnabledKey)
        processing.record = .init(status: .scheduled, trigger: .overnight, due: Date().addingTimeInterval(-0.1))
        let running = OvernightScheduler()
        running.reevaluate()
        try await until { processing.finishContinuation != nil }
        let owned = processing.task!
        let started = processing.runsStarted, count = helper.armed.count
        d.set(first, forKey: OvernightScheduler.minutesKey)
        running.commit()
        try await Task.sleep(for: .milliseconds(30))
        check(!owned.isCancelled && processing.isBusy && processing.runsStarted == started,
              "editing schedule never cancels or duplicates ProcessingCoordinator work")
        check(helper.awakeHeld && helper.endAwakeCalls == 0, "schedule edit preserves active analysis awake lease")
        check(helper.armed.count == count, "replacement scheduler waits for its previous analysis await to drain")
        processing.finishOwnedRun()
        try await until { !processing.isBusy && running.nextWakeAt != nil }
        let afterRun = Calendar.current.dateComponents([.hour, .minute], from: running.nextWakeAt!)
        check(afterRun.hour! * 60 + afterRun.minute! == first, "new selected clock arms after ongoing analysis completes")
        check(processing.runsStarted == started && !owned.isCancelled, "rescheduling retained one uncancelled analysis owner")
        check(helper.effectiveWakes == [running.nextWakeAt!], "post-analysis scheduler owns one physical wake")
        d.set(false, forKey: OvernightScheduler.prodEnabledKey); running.reevaluate()
        try await until { helper.effectiveWakes.isEmpty }
        check(helper.broadCancels == 0, "rescheduling never clears other applications' wake events")
        print("PASS: \(checks) notch preferences, local/DST time, reschedule race, and active-run checks")
    }
}
'''


def method(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    source = (APP / "Scheduling/OvernightScheduler.swift").read_text()
    # Compile the full new scheduling owner, replacing only its log sink/defaults.
    # ProcessingCoordinator's actual choice/defer/runScheduled methods are compiled too;
    # heavy processing and the OS awake helper are inert independent owned-task fixtures.
    source = source[:source.index("/// Persistent scheduler log")].replace("UserDefaults.standard", "Fixture.defaults")
    plan = (APP / "Ingestion/ProcessingPlan.swift").read_text().replace("= .standard", "= Fixture.defaults")
    owner = (APP / "Ingestion/ProcessingCoordinator.swift").read_text()
    controls = [method(owner, signature) for signature in ["func choose(", "func runScheduled(", "func deferNight("]]
    notch = (APP / "Notch Magic/NotchWindowController.swift").read_text()
    methods = [method(notch, signature).replace("private ", "", 1) for signature in [
        "private static func isInteractive(", "private func hoverMouseMoved(", "private func updateMousePassthrough("]]
    support = SUPPORT.replace("// PRODUCTION_POINTER_METHODS", "\n".join(methods))
    support = support.replace("// PRODUCTION_PROCESSING_CONTROL_METHODS", "\n".join(controls))
    with tempfile.TemporaryDirectory(prefix="sentient-wake-settings-") as temporary:
        root = Path(temporary)
        fixture = root / "SettingsTests.swift"
        fixture.write_text(support + plan + source + TESTS)
        executable = root / "settings-tests"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
                        "-parse-as-library", str(APP / "Notch Magic/NotchPreferences.swift"),
                        str(fixture), "-o", str(executable)], check=True, timeout=60)
        subprocess.run([str(executable)], check=True, timeout=15)


if __name__ == "__main__":
    main()
