#!/usr/bin/env python3
"""Run the production notch lesson lifecycles with inert collaborators and isolated defaults."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Sentient OS macOS'
source = (APP / 'Notch Magic/CommandCoordinator.swift').read_text()
def method(signature, source=source):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

fixture = r'''
import Foundation
final class NSWindow {}
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Bool] = [:]
    func set(_ value: Bool, forKey key: String) { values[key] = value }
}
final class PhysicalNotchTap {
    enum Status { case stopped, starting, settling, ready, unavailable, stalled }
    static let shared = PhysicalNotchTap()
    var status = Status.stopped
    var refreshes = 0
    func refresh() { refreshes += 1 }
}
enum NotchWindowController {
    static var hasNotch = true
    static func builtInNotchScreen() -> Int? { hasNotch ? 1 : nil }
}
enum NotchPreferences {
    static var enabled = true
    static func physicalTapEnabled() -> Bool { enabled }
}
enum OnboardingNotchPointer {
    // PHYSICAL_TARGET
}
func Log(_ text: String) {}
enum SwirlMath { nonisolated static let startRadius = 100.0; nonisolated static let landDuration = 0.4 }
enum CaretSwirl { static let landingDelay = Duration.milliseconds(30) }
final class SwirlModel {
    enum Phase { case idle }
    var phase = Phase.idle
    func begin(orbit: Double, initialRadius: Double = 100) {}
    func transition(landing: Bool) {}
}
enum Phase { case hidden, typing, running }
final class Run {
    var isDemo = false, isRunning = false, starts = 0
    func stop() { isRunning = false }
    func startOnboardingDemo() { isDemo = true; isRunning = true; starts += 1 }
}
final class Coordinator {
    var phase = Phase.hidden
    let run = Run()
    static let notchDemoPlayedKey = "test.demo"
    var onboardingDemoArmed = false
    var onboardingDemoOwnerID: UUID?
    var onboardingDemoAction = OnboardingNotchAction.takeOver
    var onboardingDemoFired: (() -> Void)?
    weak var onboardingDemoWindow: NSWindow?
    var demoTask: Task<Void, Never>?
    var demoAnimationID: UUID?
    var onboardingActionCue = OnboardingActionCue.idle
    func setPhase(_ phase: Phase) { self.phase = phase }
    func open() { beginNotchDemo(door: "fixture") }
    // METHODS
}
@main enum Checks {
    static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label); count += 1
        }
        func waitFor(_ cue: OnboardingActionCue, _ c: Coordinator) async throws {
            for _ in 0..<300 {
                if c.onboardingActionCue == cue { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            fatalError("Missing cue: \(cue)")
        }
        for status in [PhysicalNotchTap.Status.stopped, .starting, .settling, .ready] {
            PhysicalNotchTap.shared.status = status
            check(OnboardingNotchPointer.hasPhysicalTarget, "touch lesson stays visible through sensor startup")
        }
        for status in [PhysicalNotchTap.Status.unavailable, .stalled] {
            PhysicalNotchTap.shared.status = status
            check(!OnboardingNotchPointer.hasPhysicalTarget, "sensor failure offers the keyboard fallback")
        }
        PhysicalNotchTap.shared.status = .ready
        NotchWindowController.hasNotch = false
        check(!OnboardingNotchPointer.hasPhysicalTarget, "a display without a notch uses the keyboard")
        NotchWindowController.hasNotch = true
        NotchPreferences.enabled = false
        check(!OnboardingNotchPointer.hasPhysicalTarget, "disabled physical taps use the keyboard")
        NotchPreferences.enabled = true
        let window = NSWindow(), c = Coordinator()
        var fires = 0
        c.armOnboardingNotchDemo(in: window) { fires += 1 }
        check(c.onboardingDemoArmed && c.onboardingDemoWindow === window, "film owns admission")
        c.open()
        check(c.phase == .typing && !c.run.isRunning && fires == 0, "opening does not start work")
        try await waitFor(.highlighted, c)
        check(!c.run.isRunning && fires == 0, "highlight precedes work")
        try await waitFor(.pressed, c)
        check(!c.run.isRunning && fires == 0, "press remains presentation only")
        try await waitFor(.released, c)
        check(!c.run.isRunning, "release is visible before handoff")
        try await Task.sleep(for: .milliseconds(500))
        check(fires == 1 && c.run.starts == 1 && c.run.isDemo && c.phase == .running, "one handoff after release")
        check(!c.onboardingDemoArmed && c.onboardingDemoWindow == nil && c.onboardingActionCue == .idle, "sensor and cue ownership released")
        c.disarmOnboardingNotchDemo()
        check(!c.run.isRunning, "leaving film stops scripted run")

        for cue in [OnboardingActionCue.highlighted, .pressed, .released] {
            let cancelled = Coordinator()
            cancelled.armOnboardingNotchDemo(in: window) { fires += 100 }
            cancelled.open()
            try await waitFor(cue, cancelled)
            cancelled.disarmOnboardingNotchDemo()
            try await Task.sleep(for: .milliseconds(450))
            check(cancelled.phase == .hidden && cancelled.onboardingActionCue == .idle
                && cancelled.run.starts == 0 && fires == 1, "exit cancels every animation stage")
        }
        let replay = Coordinator()
        replay.armOnboardingNotchDemo(in: window) { fires += 100 }
        replay.open()
        try await waitFor(.highlighted, replay)
        replay.armOnboardingNotchDemo(in: window) { fires += 1 }
        replay.open()
        try await waitFor(.pressed, replay)
        check(replay.onboardingActionCue == .pressed && replay.run.starts == 0 && fires == 1,
            "superseded animation cannot clear or fire the new opening")
        try await Task.sleep(for: .milliseconds(600))
        check(replay.run.starts == 1 && fires == 2, "replay fires its own handoff once")
        replay.disarmOnboardingNotchDemo()
        let reply = Coordinator(), owner = UUID()
        var drafts = 0
        reply.armOnboardingNotchDemo(id: owner, in: window, action: .magicReply, ready: false) { drafts += 1 }
        check(!reply.onboardingDemoArmed && reply.onboardingDemoOwnerID == owner, "reply entrance owns the scope without admitting taps")
        for sample in 1...2 {
            reply.setOnboardingNotchDemoReady(true, id: owner)
            reply.open()
            try await waitFor(.pressed, reply)
            check(reply.onboardingDemoAction == .magicReply && drafts == sample-1, "Magic Reply press precedes drafting")
            try await Task.sleep(for: .milliseconds(650))
            check(drafts == sample && reply.run.starts == 0 && reply.phase == .hidden, "reply handoff retracts without starting the restaurant/provider run")
            check(!reply.onboardingDemoArmed && reply.onboardingDemoOwnerID == owner && reply.onboardingDemoWindow === window,
                "reply lesson retains its owner while taps are disabled")
            reply.setOnboardingNotchDemoReady(false, id: owner)
        }
        let successor = UUID()
        reply.armOnboardingNotchDemo(id: successor, in: window, action: .magicReply) { drafts += 1 }
        reply.disarmOnboardingNotchDemo(id: owner)
        reply.setOnboardingNotchDemoReady(false, id: owner)
        check(reply.onboardingDemoArmed && reply.onboardingDemoOwnerID == successor, "old view teardown cannot cancel a newer lesson")
        reply.open()
        try await waitFor(.highlighted, reply)
        reply.disarmOnboardingNotchDemo(id: successor)
        try await Task.sleep(for: .milliseconds(1800))
        check(drafts == 2 && reply.phase == .hidden && reply.onboardingDemoOwnerID == nil, "leaving Magic Reply cancels its late draft")
        let email = OnboardingMagicReplyDemo()
        email.start(reduceMotion: true)
        for _ in 0..<200 {
            if email.phase == .waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(email.phase == .waiting && !email.replyVisible && !email.continueVisible, "one email waits for the notch action")
        email.draft(); email.draft()
        check(email.phase == .drafting && !email.continueVisible, "repeated activation cannot skip drafting")
        for _ in 0..<250 {
            if email.continueVisible { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(email.phase == .complete && email.replyVisible && email.continueVisible,
            "the first email draft directly unlocks Continue")
        email.draft()
        check(email.phase == .complete, "completed email cannot start a second example")
        email.stop()
        print("PASS: \(count) production onboarding notch and email lifecycle checks")
    }
}
'''
invitation = (APP / 'Views/Onboarding/OnboardingSidekickInvitation.swift').read_text()
fixture = fixture.replace('// PHYSICAL_TARGET', method('static var hasPhysicalTarget:', invitation))
fixture = fixture.replace('// METHODS', '\n'.join(method(sig) for sig in [
    'func armOnboardingNotchDemo(', 'func disarmOnboardingNotchDemo(', 'func setOnboardingNotchDemoReady(',
    'private func cancelOnboardingActionAnimation(', 'private func beginNotchDemo('
]))
with tempfile.TemporaryDirectory(prefix='sentient-onboarding-takeover-') as folder:
    path = Path(folder)
    (path / 'Checks.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
        '-parse-as-library', str(APP / 'Views/Onboarding/OnboardingActionCue.swift'),
        str(APP / 'Views/Onboarding/OnboardingMagicReplyDemo.swift'),
        str(path / 'Checks.swift'), '-o', str(path / 'checks')], check=True, timeout=60)
    subprocess.run([str(path / 'checks')], check=True, timeout=30)
