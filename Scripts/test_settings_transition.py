#!/usr/bin/env python3
"""Exercise complete production page reveal, geometry and route state without launching the app.

Only the unrelated Settings pane enum and Home button dependencies are stubbed.
No preferences, user data, provider calls, UI automation, or copied transition logic.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"
FIXTURE = r'''
import Foundation
import SwiftUI

struct SettingsView: View {
    enum Pane: Equatable { case sources, frontierModel, doubleTap, proactive, shareKnowledge, system, health }
    var body: some View { Color.clear }
}
enum Theme { enum Ink { static let bright = Color.white } }
extension EnvironmentValues { @Entry var sidekickReduceMotionOverride: Bool? = nil }
enum HomeWindowOpening { static func open() {} }
struct BackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

@main @MainActor struct SettingsTransitionChecks {
    typealias Geometry = SettingsTransitionGeometry
    static var checks = 0
    static var failures: [String] = []
    static let tolerance: CGFloat = 0.000001
    static func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !condition() { failures.append(description); print("FAIL: " + description) }
    }
    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        near(a.minX, b.minX) && near(a.minY, b.minY) && near(a.width, b.width) && near(a.height, b.height)
    }
    static func contains(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX <= b.minX + tolerance && a.minY <= b.minY + tolerance
            && a.maxX + tolerance >= b.maxX && a.maxY + tolerance >= b.maxY
    }
    static func same(_ a: Geometry, _ b: Geometry) -> Bool {
        near(a.frame, b.frame) && near(a.cornerRadius, b.cornerRadius)
            && near(a.anchor.x, b.anchor.x) && near(a.anchor.y, b.anchor.y)
            && near(CGFloat(a.contentOpacity), CGFloat(b.contentOpacity))
            && near(a.contentScale, b.contentScale) && near(a.contentBlur, b.contentBlur)
    }
    static func geometryChecks() {
        let size = CGSize(width: 1100, height: 820)
        let bounds = CGRect(origin: .zero, size: size)
        let button = CGRect(x: 1032, y: 18, width: 44, height: 40)
        check(Geometry.source(button, in: size) == button, "source changed the actual gear bounds")
        check(Geometry.source(nil, in: size) == nil, "missing gear anchor did not request fallback")
        check(Geometry(source: nil, canvas: size, progress: 0.5) == nil, "missing anchor produced invented reveal geometry")
        let clipped = CGRect(x: 0, y: 0, width: 20, height: 18)
        check(Geometry.source(CGRect(x: -20, y: -12, width: 40, height: 30), in: size) == clipped,
              "partially clipped source escaped canvas")
        check(Geometry.source(CGRect(x: 1090, y: 810, width: 40, height: 30), in: size)
              == CGRect(x: 1090, y: 810, width: 10, height: 10), "bottom/right source clipping failed")
        check(Geometry.source(CGRect(x: -100, y: -100, width: 1300, height: 1100), in: size) == bounds,
              "oversized source was not clipped to the canvas")
        let invalidSources: [CGRect] = [
            .zero, .null, .infinite,
            CGRect(x: size.width, y: 0, width: 40, height: 30),
            CGRect(x: -40, y: 0, width: 40, height: 30),
            CGRect(x: 10, y: size.height + 1, width: 40, height: 30),
            CGRect(x: 10, y: 10, width: 0, height: 30),
            CGRect(x: 10, y: 10, width: 30, height: 0),
            CGRect(x: CGFloat.nan, y: 10, width: 30, height: 30),
            CGRect(x: 10, y: CGFloat.infinity, width: 30, height: 30),
            CGRect(x: 10, y: 10, width: CGFloat.nan, height: 30),
            CGRect(x: 10, y: 10, width: 30, height: CGFloat.infinity)
        ]
        for (index, invalid) in invalidSources.enumerated() {
            check(Geometry.source(invalid, in: size) == nil, "invalid/outside source accepted: \(index)")
            check(Geometry(source: invalid, canvas: size, progress: 0.5) == nil,
                  "invalid/outside source fabricated mask: \(index)")
        }
        for invalid in [CGSize.zero, CGSize(width: -1, height: 820), CGSize(width: 1100, height: -1),
                        CGSize(width: 0, height: 820), CGSize(width: 1100, height: 0),
                        CGSize(width: CGFloat.nan, height: 820), CGSize(width: 1100, height: CGFloat.infinity)] {
            check(Geometry.source(button, in: invalid) == nil, "invalid canvas accepted a source")
            check(Geometry(source: button, canvas: invalid, progress: 0.5) == nil, "invalid canvas fabricated a mask")
        }
        for invalid: CGFloat in [.nan, .infinity, -.infinity] {
            check(Geometry(source: button, canvas: size, progress: invalid) == nil, "nonfinite progress accepted")
        }

        let collapsed = Geometry(source: button, canvas: size, progress: 0)!
        let expanded = Geometry(source: button, canvas: size, progress: 1)!
        check(near(collapsed.frame, button), "collapsed mask does not match button bounds")
        check(near(collapsed.cornerRadius, 20), "collapsed mask is not a capsule")
        check(collapsed.contentOpacity == 0 && collapsed.contentScale < 1 && collapsed.contentBlur > 0,
              "collapsed page content is visible or lacks subtle depth")
        check(near(expanded.frame, bounds) && expanded.cornerRadius == 0, "identity does not expose the full rectangular page")
        check(expanded.contentOpacity == 1 && expanded.contentScale == 1 && expanded.contentBlur == 0,
              "identity leaves page faded, scaled, or blurred")
        check(near(expanded.anchor.x, button.midX / size.width) && near(expanded.anchor.y, button.midY / size.height),
              "content anchor is not the source button center")
        for p: CGFloat in [-.greatestFiniteMagnitude, -1, -.leastNonzeroMagnitude] {
            check(same(Geometry(source: button, canvas: size, progress: p)!, collapsed), "negative spring overshoot escaped collapsed endpoint")
        }
        for p: CGFloat in [1.0001, 2, .greatestFiniteMagnitude] {
            check(same(Geometry(source: button, canvas: size, progress: p)!, expanded), "positive spring overshoot escaped expanded endpoint")
        }

        // Test real narrow/wide layouts plus a resize during a reveal. Geometry must use the
        // current resolved gear position, not a stale screen/window coordinate captured once.
        for canvas in [CGSize(width: 840, height: 680), CGSize(width: 1040, height: 800), size,
                       CGSize(width: 1440, height: 900), CGSize(width: 720, height: 500)] {
            let page = CGRect(origin: .zero, size: canvas)
            let gear = CGRect(x: canvas.width - 68, y: 18, width: 44, height: 40)
            let knowledge = CGRect(x: canvas.width - 230, y: 18, width: 130, height: 40)
            for source in [gear, knowledge, CGRect(x: -10, y: 10, width: 38, height: 32),
                           CGRect(x: canvas.width - 15, y: canvas.height - 15, width: 38, height: 32), page] {
                let clippedSource = Geometry.source(source, in: canvas)!
                var previous: Geometry?
                for step in 0...20 {
                    let p = CGFloat(step) / 20
                    let value = Geometry(source: source, canvas: canvas, progress: p)!
                    check(contains(page, value.frame), "intermediate reveal escaped resized canvas")
                    check(contains(value.frame, clippedSource), "intermediate reveal lost the gear origin")
                    check(value.frame.width > 0 && value.frame.height > 0 && value.cornerRadius.isFinite
                            && value.cornerRadius >= 0 && value.cornerRadius <= min(value.frame.width, value.frame.height) / 2 + tolerance,
                          "intermediate rounded mask is inverted or nonfinite")
                    check((0...1).contains(value.anchor.x) && (0...1).contains(value.anchor.y)
                            && near(value.anchor.x, clippedSource.midX / canvas.width)
                            && near(value.anchor.y, clippedSource.midY / canvas.height), "resize lost normalized source anchor")
                    check((0...1).contains(value.contentOpacity) && (0.94...1).contains(value.contentScale)
                            && (0...7).contains(value.contentBlur), "intermediate page effects exceed safe bounds")
                    if let previous {
                        check(contains(value.frame, previous.frame), "opening mask contracted mid-transition")
                        check(value.contentOpacity >= previous.contentOpacity && value.contentScale >= previous.contentScale
                                && value.contentBlur <= previous.contentBlur, "opening page effects reversed mid-transition")
                    }
                    previous = value
                }
            }
            check(near(Geometry(source: gear, canvas: canvas, progress: 0)!.frame, gear), "resize uses a stale collapsed button frame")
            check(near(Geometry(source: gear, canvas: canvas, progress: 1)!.frame, page), "resize uses stale page bounds")
        }
    }

    static func routingChecks() {
        let nav = MainNavigation()
        check(nav.page == .home && nav.previousPage == nil && !nav.animatesSettingsTransition, "fresh route invented an animation")
        nav.show(.home)
        check(nav.previousPage == nil && !nav.animatesSettingsTransition, "initial same-page request invented route history")
        nav.show(.settings, settingsPane: .proactive)
        check(nav.page == .settings && nav.previousPage == .home && nav.animatesSettingsTransition,
              "Home to Settings does not animate")
        check(nav.settingsPane == .proactive, "Settings deep link lost its pane")
        nav.show(.settings, settingsPane: .health)
        check(nav.page == .settings && nav.previousPage == .home && nav.settingsPane == .health,
              "same-page Settings request changed prior route or lost pane")
        nav.show(.home)
        check(nav.previousPage == .settings && nav.page == .home && nav.animatesSettingsTransition,
              "Settings to Home does not contract")
        nav.show(.home)
        check(nav.previousPage == .settings, "same-page Home request overwrote actual previous route")
        nav.show(.knowledge)
        check(nav.previousPage == .home && nav.hasOpenedKnowledge && !nav.animatesSettingsTransition
                && nav.animatesKnowledgeTransition, "Home to Knowledge lost its own reveal or acquired Settings animation")
        nav.show(.settings, settingsPane: .frontierModel)
        check(nav.previousPage == .knowledge && !nav.animatesSettingsTransition && !nav.animatesKnowledgeTransition && nav.settingsPane == .frontierModel,
              "Knowledge to Settings incorrectly expands from Home")
        nav.show(.knowledge)
        check(nav.previousPage == .settings && !nav.animatesSettingsTransition && !nav.animatesKnowledgeTransition, "Settings to Knowledge acquired Home animation")
        nav.show(.home)
        check(nav.previousPage == .knowledge && !nav.animatesSettingsTransition && nav.animatesKnowledgeTransition, "Knowledge to Home did not contract to its own source")

        var pending: ((Bool) -> Void)?
        var guardCalls = 0
        nav.show(.knowledge)
        nav.leaveKnowledge = { completion in guardCalls += 1; pending = completion }
        nav.show(.settings, settingsPane: .system)
        check(guardCalls == 1 && pending != nil, "Settings bypassed dirty Knowledge leave guard")
        check(nav.page == .knowledge && nav.previousPage == .home && nav.settingsPane == .frontierModel,
              "deferred request changed route or pane before approval")
        pending?(false); pending = nil
        check(nav.page == .knowledge && nav.previousPage == .home && !nav.animatesSettingsTransition,
              "cancelled Knowledge navigation changed presentation")
        check(nav.settingsPane == .frontierModel, "cancelled deep link changed Settings selection")
        nav.show(.settings, settingsPane: .system)
        pending?(true); pending = nil
        check(nav.page == .settings && nav.previousPage == .knowledge && nav.settingsPane == .system
                && !nav.animatesSettingsTransition, "approved Knowledge navigation chose wrong transition/pane")
        nav.show(.home)
        check(guardCalls == 2 && nav.animatesSettingsTransition, "Home return invoked an inactive Knowledge guard")
        var immediate: Bool?
        nav.confirmLeavingKnowledge { immediate = $0 }
        check(immediate == true && guardCalls == 2, "non-Knowledge close guard did not allow immediately")
        nav.show(.knowledge)
        nav.confirmLeavingKnowledge { immediate = $0 }
        check(guardCalls == 3 && pending != nil && nav.page == .knowledge, "close confirmation bypassed Knowledge guard")
        pending?(false); pending = nil
        check(immediate == false && nav.page == .knowledge, "cancelled close confirmation mutated navigation")
        nav.show(.knowledge)
        check(guardCalls == 3 && nav.previousPage == .home, "Knowledge no-op requested destructive leave confirmation")

        // A Save/Discard sheet can outlive teardown. Its retained completion must not
        // resurrect the destination or mutate the new session's selected Settings pane.
        nav.show(.settings, settingsPane: .health)
        let staleApproval = pending
        check(staleApproval != nil && nav.page == .knowledge, "reset fixture did not retain a deferred Knowledge approval")
        nav.reset()
        staleApproval?(true); pending = nil
        check(nav.page == .home && nav.previousPage == nil && !nav.animatesSettingsTransition,
              "reset or stale approval preserved route/animation history")
        check(nav.settingsPane == .sources && !nav.hasOpenedKnowledge && nav.leaveKnowledge == nil,
              "reset or stale approval kept previous pane or Knowledge guard")
        check(!nav.animatesKnowledgeTransition, "reset retained Knowledge animation intent")
        nav.show(.settings, settingsPane: .proactive)
        staleApproval?(true)
        check(nav.page == .settings && nav.previousPage == .home && nav.settingsPane == .proactive
                && nav.animatesSettingsTransition, "stale approval rewrote a new post-reset navigation")
        nav.reset()
        nav.finishOnboarding()
        check(nav.page == .knowledge && nav.previousPage == .home && !nav.animatesSettingsTransition,
              "onboarding Knowledge entrance acquired Settings animation")
        nav.reset()
        nav.show(.settings, settingsPane: .health)
        nav.finishOnboarding()
        check(nav.page == .settings && nav.settingsPane == .health && nav.previousPage == .home,
              "onboarding completion replaced a pending Settings deep link")
        nav.reset()
        nav.show(.home, settingsPane: .doubleTap)
        check(nav.page == .home && nav.previousPage == nil && nav.settingsPane == .doubleTap
                && !nav.animatesSettingsTransition, "pane-only request invented navigation or ignored selection")

        // Reversal is entirely route state, with no delayed completion able to navigate.
        for _ in 0..<20 {
            nav.show(.knowledge)
            check(nav.animatesKnowledgeTransition && !nav.animatesSettingsTransition, "rapid Knowledge opening chose wrong source")
            nav.show(.home)
            check(nav.animatesKnowledgeTransition && !nav.animatesSettingsTransition, "rapid Knowledge reversal lost source")
            nav.show(.settings)
            check(nav.animatesSettingsTransition && !nav.animatesKnowledgeTransition, "rapid Settings opening inherited Knowledge source")
            nav.show(.home)
            check(nav.animatesSettingsTransition && !nav.animatesKnowledgeTransition, "rapid Settings reversal lost source")
        }
        for from in [MainNavigation.Page.home, .settings, .knowledge] {
            for to in [MainNavigation.Page.home, .settings, .knowledge] where from != to {
                nav.reset(); nav.show(from); nav.show(to)
                let settings = (from == .home && to == .settings) || (from == .settings && to == .home)
                let knowledge = (from == .home && to == .knowledge) || (from == .knowledge && to == .home)
                check(nav.animatesSettingsTransition == settings && nav.animatesKnowledgeTransition == knowledge,
                      "route pair has wrong animation policy")
            }
        }
    }

    static func entranceChecks() async {
        let direct = await HomePageEntrance.wait(animate: false, reducedMotion: false)
        check(direct, "direct route incorrectly delayed/cancelled constellation")
        let reduced = await HomePageEntrance.wait(animate: true, reducedMotion: true)
        check(reduced, "Reduce Motion incorrectly cancelled immediate constellation")
        let pending = Task { await HomePageEntrance.wait(animate: true, reducedMotion: false) }
        pending.cancel()
        let cancelled = await pending.value
        check(!cancelled, "cancelled page entrance can still make hidden sky ready")
        let began = ContinuousClock.now
        let visible = await HomePageEntrance.wait(animate: true, reducedMotion: false)
        check(visible && began.duration(to: .now) >= .milliseconds(450), "constellation did not wait for page reveal")
        let nav = MainNavigation()
        nav.show(.knowledge)
        let obsolete = Task { await HomePageEntrance.wait(animate: true, reducedMotion: false) }
        nav.show(.home); obsolete.cancel()
        _ = await obsolete.value
        check(nav.page == .home, "cancelled entrance callback navigated after rapid reversal")
    }

    static func main() async {
        geometryChecks()
        routingChecks()
        await entranceChecks()
        print("\(checks - failures.count)/\(checks) Home page transition checks passed")
        if !failures.isEmpty { exit(1) }
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-settings-transition-") as temporary:
    root = Path(temporary)
    source = root / "SettingsTransitionChecks.swift"
    source.write_text(FIXTURE)
    binary = root / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library",
        str(APP / "Views/Settings/SettingsTransitionGeometry.swift"),
        str(APP / "Views/Settings/SettingsPageTransition.swift"),
        str(APP / "App/MainNavigation.swift"), str(source), "-o", str(binary),
    ], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=30)
