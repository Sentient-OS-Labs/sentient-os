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
enum Analytics { static func signal(_ text: String) {} }
enum CodexAuth { static var knowledgeBaseOnly = false }
enum LoginItem { static var isEnabled = true; static func enable() {} }
enum Diagnostics {
    enum Kind { case wakeMissed }
    enum Phase { case begin }
    enum Count { case elapsedMS }
    static func report(_ kind: Kind, phase: Phase, reason: String, counts: [Count: Int], cooldown: Int) {}
}
final class SchedulerLog { func line(_ text: String) {} }
final class WakeHelperClient {
    enum Health { case ready, requiresApproval }
    static let shared = WakeHelperClient()
    var isReady = true
    var armed: [Date] = []
    var holdNextArm = false
    var pending: CheckedContinuation<Bool, Never>?
    func healthProbe() async -> Health { .ready }
    func cancelAllWakes() async -> Bool { true }
    func cancelWake() async -> Bool { true }
    func armWake(at date: Date) async -> Bool {
        armed.append(date)
        if holdNextArm {
            holdNextArm = false
            return await withCheckedContinuation { pending = $0 }
        }
        return true
    }
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
extension OvernightScheduler {
    // Pipeline replacement only: a controlled long-running job to detect accidental cancellation.
    func runNight(log: SchedulerLog) async {}
    func simulateRunningNight() {
        loopTask = Task { try? await Task.sleep(for: .seconds(30)) }
    }
    var runWasCancelled: Bool { loopTask?.isCancelled ?? true }
}

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
            OvernightScheduler.nextOccurrence(minutesSinceMidnight: minutes, after: now, calendar: calendar)
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

        let helper = WakeHelperClient.shared
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
        check(!d.bool(forKey: OvernightScheduler.enabledKey), "no developer toggle needed")
        d.set(second, forKey: OvernightScheduler.minutesKey)
        scheduler.commit()
        try await until { helper.armed.count == 2 && scheduler.nextWakeAt != nil }
        let selected = Calendar.current.dateComponents([.hour, .minute], from: scheduler.nextWakeAt!)
        check(selected.hour! * 60 + selected.minute! == second, "time edit interrupts waiting and re-arms promptly")

        helper.holdNextArm = true
        d.set(first, forKey: OvernightScheduler.minutesKey)
        scheduler.commit()
        try await until { helper.pending != nil }
        d.set(third, forKey: OvernightScheduler.minutesKey)
        scheduler.commit()
        helper.pending!.resume(returning: true); helper.pending = nil
        try await until { helper.armed.count == 4 && scheduler.nextWakeAt != nil }
        let latest = Calendar.current.dateComponents([.hour, .minute], from: scheduler.nextWakeAt!)
        check(latest.hour! * 60 + latest.minute! == third, "edit during in-flight arm wins without stale wake")
        d.set(false, forKey: OvernightScheduler.prodEnabledKey)
        scheduler.reevaluate()
        try await Task.sleep(for: .milliseconds(30))
        check(scheduler.nextWakeAt == nil && scheduler.statusLine == "off", "disable still clears scheduled state")

        d.set(true, forKey: OvernightScheduler.prodEnabledKey)
        let running = OvernightScheduler()
        running.simulateRunningNight()
        let count = helper.armed.count
        d.set(first, forKey: OvernightScheduler.minutesKey)
        running.commit()
        try await Task.sleep(for: .milliseconds(30))
        check(!running.runWasCancelled && helper.armed.count == count, "editing time never cancels active overnight work")
        d.set(false, forKey: OvernightScheduler.prodEnabledKey); running.reevaluate()
        print("PASS: \(checks) notch preferences, local/DST time, reschedule race, and active-run checks")
    }
}
'''


def main():
    source = (APP / "Scheduling/OvernightScheduler.swift").read_text()
    # Compile the entire production control half, including commit/start/stop/loop. The
    # heavy analysis pipeline below runNight is outside this test's scope and replaced above.
    control = source[:source.index("    /// One night, raced against the stall watchdog.")]
    time_helpers = source[source.index("    // MARK: - Time helpers"):source.index("/// The night's progress pulse")]
    source = (control + time_helpers).replace("UserDefaults.standard", "Fixture.defaults")
    notch = (APP / "Notch Magic/NotchWindowController.swift").read_text()
    methods = []
    for signature in ["private static func isInteractive(", "private func hoverMouseMoved(", "private func updateMousePassthrough("]:
        start = notch.index(signature)
        opening = notch.index("{", start)
        depth = 1
        end = opening + 1
        while depth:
            depth += (notch[end] == "{") - (notch[end] == "}")
            end += 1
        methods.append(notch[start:end].replace("private ", "", 1))
    support = SUPPORT.replace("// PRODUCTION_POINTER_METHODS", "\n".join(methods))
    with tempfile.TemporaryDirectory(prefix="sentient-wake-settings-") as temporary:
        root = Path(temporary)
        fixture = root / "SettingsTests.swift"
        fixture.write_text(support + source + TESTS)
        executable = root / "settings-tests"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
                        "-parse-as-library", str(APP / "Notch Magic/NotchPreferences.swift"),
                        str(fixture), "-o", str(executable)], check=True, timeout=60)
        subprocess.run([str(executable)], check=True, timeout=15)


if __name__ == "__main__":
    main()
