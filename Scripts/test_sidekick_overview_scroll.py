#!/usr/bin/env python3
"""Compile the real policy/probe and exercise deterministic inputs and owned quiet timers.

No app launch, event injection, provider, windows, monitors, credentials or permissions.
"""
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sentient OS macOS/Views/Sidekick/SidekickOverviewScroll.swift"
FIXTURE = r'''
import AppKit
import Foundation

@main enum OverviewScrollTests {
    typealias Policy = SidekickOverviewScrollPolicy
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fatalError("FAIL: " + name) }
        checks += 1
    }
    static func progress(_ decision: Policy.Decision, _ expected: Double, _ label: String) {
        guard case .progress(let value) = decision else { fatalError("FAIL: " + label + " did not report progress") }
        check(abs(value - expected) < 0.000001, label)
    }
    static func input(_ y: Double, x: Double = 0, at time: Double = 0, inverted: Bool = false,
                      precise: Bool = true, phase: NSEvent.Phase = .changed, momentum: NSEvent.Phase = [],
                      enabled: Bool = true, ownWindow: Bool = true, view: Bool = true, active: Bool = true) -> Policy.Input {
        .init(timestamp: time, deltaX: x, deltaY: y, inverted: inverted, precise: precise,
              phase: phase, momentumPhase: momentum, enabled: enabled,
              ownWindow: ownWindow, insideView: view, insideActiveRect: active)
    }
    static func policyChecks() {
        var p = Policy()
        check(Policy.preciseThreshold == 140 && Policy.wheelThreshold == 3, "deliberate commit distance changed")
        progress(p.handle(input(40, phase: .began)), 40, "first motion tracks finger")
        progress(p.handle(input(40, at: 0.1)), 80, "continued motion tracks cumulative distance")
        progress(p.handle(input(-30, at: 0.2)), 50, "reversal lowers visible progress without resetting")
        check(p.handle(input(90, at: 0.3)) == .collapse && p.consuming, "exact140 threshold commits once")
        check(p.handle(input(20, at: 0.31, enabled: false)) == .consume, "disabled Home consumes committed continuation")
        check(p.handle(input(0, at: 0.32, phase: .ended, enabled: false)) == .consume, "finger lift retains momentum latch")
        check(p.handle(input(35, at: 0.33, phase: [], momentum: .began, enabled: false, active: false)) == .consume,
              "momentum tail remains consumed after active geometry changes")
        check(p.handle(input(20, at: 5, phase: [], momentum: .changed, enabled: false)) == .consume,
              "explicit momentum lifetime survives gaps")
        check(p.handle(input(0, at: 5.1, phase: [], momentum: .ended, enabled: false)) == .consume && !p.consuming,
              "terminal momentum event consumed then releases")
        check(p.handle(input(-20, at: 5.2, enabled: false)) == .passThrough, "later conversation scroll passes")

        for inverted in [false, true] {
            p.reset(); let up = inverted ? -70.0 : 70.0
            progress(p.handle(input(up, inverted: inverted, phase: .began)), 70, "physical up normalizes preference")
            progress(p.handle(input(-up / 2, at: 0.1, inverted: inverted)), 35, "physical reversal normalizes preference")
            check(p.handle(input(up * 1.5, at: 0.2, inverted: inverted)) == .collapse, "normalized gesture reaches140")
            p.reset()
            check(p.handle(input(-up * 4, inverted: inverted, phase: .began)) == .passThrough && !p.consuming,
                  "downward input cannot initiate collapse")
        }
        p.reset()
        for index in 0..<20 { check(p.handle(input(1, x: 0.3, at: Double(index) * 0.03)) == .passThrough, "jitter not accumulated") }
        progress(p.handle(input(139, at: 0.6)), 139, "jitter did not prime threshold")
        check(p.handle(input(-0.4, at: 0.61)) == .consume && p.distance == 139, "tiny reverse jitter keeps current position")
        check(p.handle(input(2, at: 0.62)) == .collapse, "deliberate movement commits after jitter")

        p.reset(); _ = p.handle(input(70))
        progress(p.handle(input(-100, at: 0.1)), 0, "reversal clamps at zero without negative pull")
        check(p.handle(input(-20, at: 0.2)) == .passThrough && p.distance == 0, "further downward scroll released")
        progress(p.handle(input(20, at: 0.3)), 20, "fresh upward movement follows full reversal")
        check(p.handle(input(15, x: 40, at: 0.4)) == .settle && p.distance == 0, "horizontal intent settles partial pull")
        check(p.handle(input(100, x: 100, at: 0.5)) == .passThrough, "unclaimed diagonal passes")
        progress(p.handle(input(20, at: 0.6)), 20, "horizontal intent did not prime future gesture")

        for terminal: NSEvent.Phase in [.ended, .cancelled] {
            p.reset(); _ = p.handle(input(60, phase: .began))
            check(p.handle(input(0, at: 0.1, phase: terminal)) == .settle && p.distance == 0 && !p.consuming,
                  "partial gesture end/cancel requests spring settle")
            check(p.handle(input(0, at: 0.2, phase: terminal)) == .passThrough, "terminal event does not settle twice")
        }
        p.reset(); _ = p.handle(input(60, phase: .began))
        check(p.quietDeadline == nil && p.settleIfQuiet(at: 10) == .passThrough && p.distance == 60,
              "finger pause does not expire partial phased progress")
        check(p.handle(input(0, at: 10, phase: .stationary)) == .consume && p.distance == 60,
              "stationary fingers preserve live progress")
        progress(p.handle(input(20, at: 100)), 80, "long finger pause resumes from same live distance")
        check(p.handle(input(60, at: 100.1)) == .collapse, "paused gesture reaches original total")
        check(p.settleIfQuiet(at: 200) == .passThrough && p.consuming, "active committed finger gesture does not time out")
        check(p.handle(input(0, at: 201, phase: .cancelled, enabled: false)) == .consume && !p.consuming,
              "explicit cancellation releases a paused committed gesture")

        p.reset()
        progress(p.handle(input(1, precise: false, phase: [])), 140.0 / 3, "first coarse unit maps to distance")
        progress(p.handle(input(1, at: 0.1, precise: false, phase: [])), 280.0 / 3, "second coarse unit tracks distance")
        progress(p.handle(input(-1, at: 0.2, precise: false, phase: [])), 140.0 / 3, "coarse reversal tracks distance")
        check(p.handle(input(2, at: 0.3, precise: false, phase: [])) == .collapse, "coalesced wheel units reach threshold")
        check(p.handle(input(1, at: 0.4, precise: false, phase: [], enabled: false)) == .consume, "committed wheel tail swallowed")
        let committedDeadline = p.quietDeadline!
        check(p.settleIfQuiet(at: committedDeadline) == .passThrough && !p.consuming, "quiet releases completed wheel latch without visual settle")
        for amount in [3.0, 100.0, .greatestFiniteMagnitude] {
            p.reset(); check(p.handle(input(amount, precise: false, phase: [])) == .collapse, "large finite coalesced wheel input clamps safely")
            check(p.handle(input(amount, at: 0.1, precise: false, phase: [])) == .consume, "coalesced burst commits only once")
        }
        p.reset()
        for i in 0..<10 { check(p.handle(input(0.2, at: Double(i) * 0.02, precise: false, phase: [])) == .passThrough, "coarse jitter not accumulated") }
        progress(p.handle(input(2, at: 0.2, precise: false, phase: [])), 280.0 / 3, "coarse jitter did not prime progress")
        check(p.handle(input(1, at: 0.3, precise: false, phase: [])) == .collapse, "three actual coarse units commit")
        p.reset(); check(p.handle(input(-3, inverted: true, precise: false, phase: [])) == .collapse, "inverted coarse wheel normalizes direction")

        for precise in [false, true] {
            p.reset(); _ = p.handle(input(precise ? 60 : 1, precise: precise, phase: []))
            let deadline = p.quietDeadline!
            check(p.settleIfQuiet(at: deadline - 0.001) == .passThrough && p.distance > 0, "quiet timer does not settle early")
            check(p.settleIfQuiet(at: deadline) == .settle && p.distance == 0 && p.quietDeadline == nil,
                  "phase-less partial input settles at quiet deadline without another event")
            check(p.settleIfQuiet(at: deadline + 1) == .passThrough, "quiet settle occurs once")
        }
        p.reset(); _ = p.handle(input(60, phase: []))
        progress(p.handle(input(20, at: 0.4, phase: [])), 20, "quiet gap starts fresh progress if timer has not run yet")
        let deadline = p.quietDeadline
        check(p.handle(input(0, at: 0.5, phase: [])) == .consume && p.quietDeadline == deadline,
              "zero phase-less events cannot extend quiet deadline forever")
        p.reset(); _ = p.handle(input(100))
        progress(p.handle(input(1, at: 0.1, precise: false, phase: [])), 140.0 / 3, "device switch starts new mapped progress")

        p.reset()
        for momentum: NSEvent.Phase in [.began, .changed, .ended, .cancelled] {
            check(p.handle(input(200, at: 0.1, phase: [], momentum: momentum)) == .passThrough,
                  "unclaimed momentum never initiates live progress or collapse")
        }
        _ = p.handle(input(60, at: 0.2))
        check(p.handle(input(200, at: 0.3, phase: [], momentum: .began)) == .settle && !p.consuming,
              "momentum after a partial pull settles without committing")
        for phase: NSEvent.Phase in [.began, .mayBegin] {
            p.reset(); _ = p.handle(input(140, phase: .began))
            check(p.handle(input(0, at: 0.1, phase: phase, enabled: false)) == .passThrough && !p.consuming,
                  "new physical gesture releases old committed tail")
        }
        p.reset(); _ = p.handle(input(60))
        check(p.handle(input(0, at: 0.1, phase: .mayBegin)) == .settle, "new mayBegin settles stale partial motion")

        for blocked in [input(100, enabled: false), input(100, ownWindow: false), input(100, view: false), input(100, active: false)] {
            p.reset(); check(p.handle(blocked) == .passThrough && !p.consuming, "disabled/outside/unowned input cannot start gesture")
            _ = p.handle(input(60)); check(p.handle(blocked) == .settle && p.distance == 0,
                                         "leaving usable geometry settles partial gesture")
        }
        p.reset(); _ = p.handle(input(140))
        check(p.handle(input(10, at: 0.1, ownWindow: false)) == .passThrough && !p.consuming, "another window releases latch without capture")
        p.reset(); _ = p.handle(input(140))
        check(p.handle(input(10, at: 0.1, view: false)) == .passThrough && !p.consuming, "outside full view releases latch")
        p.reset(); _ = p.handle(input(60))
        check(p.discardProgress() && p.distance == 0 && p.quietDeadline == nil, "geometry invalidates partial motion")
        check(!p.discardProgress(), "geometry has no duplicate settle without motion")
        _ = p.handle(input(140)); check(!p.discardProgress() && p.consuming, "geometry retains committed-tail consumption")
        check(p.handle(input(10, at: 0.1, enabled: false, active: false)) == .consume, "committed tail survives hidden-card geometry")
        p.reset(); _ = p.handle(input(60, at: 10))
        check(p.handle(input(10, at: 9)) == .settle && p.distance == 0, "backward time clears partial state")
        for malformed in [input(.nan), input(.infinity), input(1, x: .nan), input(1, at: .infinity)] {
            p.reset(); _ = p.handle(input(60))
            check(p.handle(malformed) == .settle && p.distance == 0, "nonfinite input settles partial motion")
            _ = p.handle(input(140))
            check(p.handle(malformed) == .passThrough && !p.consuming, "nonfinite input cannot trap scrolling")
        }
        p.reset(); check(p.handle(input(.greatestFiniteMagnitude)) == .collapse, "huge finite precise delta clamps at threshold")
    }
    static func runTimers(for seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01))) }
    }
    static func probeChecks() async throws {
        let rect = NSRect(x: 0, y: 0, width: 800, height: 600)
        let view = SidekickOverviewScroll.Probe(frame: rect)
        var distances: [Double] = [], settled = 0, collapsed = 0
        func configure(_ enabled: Bool = true, _ area: CGRect = NSRect(x: 0, y: 0, width: 800, height: 600)) {
            view.configure(enabled: enabled, activeRect: area, onProgress: { distances.append($0) },
                           onSettle: { settled += 1 }, onCollapse: { collapsed += 1 })
        }
        configure()
        check(view.isFlipped && !view.acceptsFirstResponder && view.hitTest(.zero) == nil,
              "probe never takes hit tests or keyboard focus")
        check(view.consume(input(40, phase: .began)), "progress consumes native event")
        check(view.consume(input(40, at: 0.1)), "progress continuation consumed")
        check(view.consume(input(-30, at: 0.2)), "reverse progress consumed")
        check(distances == [40,80,50] && settled == 0 && collapsed == 0, "probe callbacks deliver exact live/reverse distances")
        check(!view.consume(input(0, at: 0.3, phase: .ended)) && settled == 1, "partial end calls settle without trapping event")
        _ = view.consume(input(140, at: 1, phase: .began))
        check(collapsed == 1 && distances == [40,80,50], "commit emits only collapse callback")
        configure(false, .zero)
        check(view.consume(input(20, at: 1.1, phase: [], momentum: .began, enabled: false, active: false)), "probe preserves committed tail after configuration change")
        _ = view.consume(input(0, at: 1.2, phase: [], momentum: .ended, enabled: false))
        configure(); _ = view.consume(input(60, at: 2, phase: .began))
        configure(true, NSRect(x: 10, y: 10, width: 700, height: 500))
        check(settled == 1 && view.policy.distance == 0, "configure must not synchronously mutate SwiftUI state")
        try await Task.sleep(for: .milliseconds(20))
        check(settled == 2, "geometry reset settles after updateNSView stack")
        _ = view.consume(input(60, at: 3, phase: .began)); configure(false)
        check(settled == 2, "disable settle is deferred")
        configure(); _ = view.consume(input(20, at: 4, phase: .began))
        try await Task.sleep(for: .milliseconds(20))
        check(settled == 2 && view.policy.distance == 20, "new live input cancels stale deferred settle")
        configure(false); view.detach()
        try await Task.sleep(for: .milliseconds(20))
        check(settled == 2 && view.policy.distance == 0, "detach cancels pending SwiftUI callback")

        configure(); let start = ProcessInfo.processInfo.systemUptime
        _ = view.consume(input(1, at: start, precise: false, phase: []))
        _ = view.consume(input(1, at: start + 0.001, precise: false, phase: []))
        runTimers(for: 0.45)
        check(settled == 3 && view.policy.distance == 0 && view.policy.quietDeadline == nil,
              "single replaced quiet timer settles wheel burst without another event")
        runTimers(for: 0.1)
        check(settled == 3, "replaced quiet timers never deliver duplicate settle")
        _ = view.consume(input(1, at: ProcessInfo.processInfo.systemUptime, precise: false, phase: []))
        view.detach(); runTimers(for: 0.45)
        check(settled == 3 && !view.policy.consuming, "detach cancels timer and leaves no callback")
        configure(true, .infinite)
        check(view.activeRect == .zero, "invalid active geometry is disabled safely")
        view.detach()
    }
    static func main() async throws {
        policyChecks()
        try await probeChecks()
        print("Sidekick overview scroll: \(checks) checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="sentient-overview-scroll-") as temporary:
    directory = Path(temporary)
    fixture = directory / "Fixture.swift"
    fixture.write_text(FIXTURE)
    binary = directory / "overview-scroll-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
        "-target", platform.machine() + "-apple-macosx15.4",
        "-strict-concurrency=complete", "-warnings-as-errors", "-enable-upcoming-feature", "MemberImportVisibility",
        "-enable-upcoming-feature", "NonisolatedNonsendingByDefault", str(SOURCE), str(fixture), "-o", str(binary),
    ], check=True, cwd=ROOT, timeout=60)
    subprocess.run([str(binary)], check=True, cwd=directory, timeout=15)
