#!/usr/bin/env python3
"""Run actual Double Tap admission/feedback and native panels in an isolated fixture.

No real preferences, screenshot capture, provider requests, permissions or paste. The real
start/setup/cancel methods and both feedback panels run with inert drafting dependencies.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile
from test_sidekick_analysis_availability import member

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"
FIXTURE = r'''
import AppKit
import SwiftUI

func Log(_ text: String) {}
enum DoubleTapProvider: String { case sentient; static var current: Self { .sentient }; var model: String { "fixture" } }
enum Diagnostics {
    enum Phase: String { case capture }
    enum Event { case doubleTapFailed }
    enum Count { case deadlineMS }
    final class Operation { var phase: Phase?; init(_ name: String, doubleTapProvider: DoubleTapProvider) {} }
    @TaskLocal static var current: Operation?
    static func report(_ event: Event, phase: Phase, reason: String, source: String, counts: [Count: Int]) {}
}
enum DiagnosticHistory {
    enum Kind { case doubleTap }
    enum Outcome { case blocked, pasteDispatched, notAMessage, stopped, failed, timedOut }
    static var begins = 0
    static func begin(_ kind: Kind, provider: String, model: String?) -> UUID { begins += 1; return UUID() }
    static func finish(_ kind: Kind, id: UUID, outcome: Outcome, reason: String?, phase: String, measurements: [String: Int] = [:]) {}
}
final class DoubleTapPermissionGate {
    static let shared = DoubleTapPermissionGate()
    var calls = 0; var blocked = false
    func intercept() -> Bool { calls += 1; return blocked }
}
final class InviteProgram {
    enum Event { case doubleTap }; static let shared = InviteProgram(); func record(_ event: Event) {}
}
enum CaretLocator {
    struct Target { var point: CGPoint; var height: CGFloat }
    static func locate() -> Target { Target(point: NSEvent.mouseLocation, height: 18) }
}
final class DoubleTap {
    static var isReady = false
    static let deadline = 30.0
    var lastReport: String?
    var providerCalls = 0
    enum Result { case pasted, notAMessage, stopped, failed(String) }
    private var task: Task<Void, Never>?
    private var activeRunID: UUID?
    private var phase = Diagnostics.Phase.capture
    private var diagnosticReason: String?
    private let swirl = CaretSwirl()
    private let setupNotice = DoubleTapSetupNotice()
    var isDrafting: Bool { task != nil }
    private func perform() async -> Result { providerCalls += 1; return .pasted }
    // METHODS
}

@main enum Tests {
    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var checks = 0
        func check(_ pass: Bool, _ label: String) { precondition(pass, label); checks += 1; print("PASS " + label) }
        func pause(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }
        func notice() -> NSWindow? { NSApp.windows.first { String(describing: type(of: $0)) == "DoubleTapNoticePanel" } }
        let run = DoubleTap(), originalKey = NSApp.keyWindow
        var completions = 0
        run.start { _ in completions += 1 }
        check(run.isDrafting, "setup feedback owns the Double Tap task lock immediately")
        run.start { _ in completions += 1 }
        try await pause(1600)
        guard let panel = notice(), let host = panel.contentView else { preconditionFailure("Missing setup notice") }
        check(panel.isVisible && panel.frame.width > 300 && panel.frame.height > 40, "swirl transitions into a fully sized setup message")
        check(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain && NSApp.keyWindow === originalKey,
              "notice stays click-through and does not steal keyboard focus")
        check(completions == 0 && run.isDrafting && NSApp.windows.filter { String(describing: type(of: $0)) == "DoubleTapNoticePanel" }.count == 1,
              "repeated taps do not stack notices or release the gesture lock")
        check(run.providerCalls == 0 && DoubleTapPermissionGate.shared.calls == 0 && DiagnosticHistory.begins == 0,
              "missing setup never starts drafting, permissions or capture diagnostics")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
            }
        }
        let size = panel.frame.size
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: -200, width: 1920, height: 1080)] {
            for point in [CGPoint(x: screen.minX, y: screen.minY), CGPoint(x: screen.maxX - 1, y: screen.minY),
                          CGPoint(x: screen.maxX - 1, y: screen.maxY - 1), CGPoint(x: screen.midX, y: screen.midY)] {
                let origin = DoubleTapSetupNotice.origin(near: point, size: size, within: screen)
                check(screen.contains(CGRect(origin: origin, size: size)), "notice remains inside the pointer's display")
            }
        }
        check(DoubleTapSetupNotice.duration == .seconds(3), "message lifetime is three seconds")
        // A real live timer must dismiss the panel and unlock the next gesture.
        try await pause(2900)
        check(!panel.isVisible && !run.isDrafting && completions == 1, "feedback dismisses and completes exactly once after its timeout")
        run.start { _ in completions += 1 }
        run.cancel()
        try await pause(100)
        check(!panel.isVisible && !run.isDrafting && completions == 2, "cancelling during animation cleans up and completes once")
        run.start { _ in completions += 1 }
        try await pause(1600)
        check(panel.isVisible, "a later gesture reuses and reveals the notice")
        run.cancel()
        try await pause(100)
        check(!panel.isVisible && !run.isDrafting && completions == 3, "cancelling a visible message dismisses it promptly")
        DoubleTap.isReady = true
        DoubleTapPermissionGate.shared.blocked = true
        run.start { _ in completions += 1 }
        check(!run.isDrafting && DoubleTapPermissionGate.shared.calls == 1 && run.providerCalls == 0,
              "ready imported knowledge still requires ordinary permissions")
        DoubleTapPermissionGate.shared.blocked = false
        run.start { _ in completions += 1 }
        try await pause(100)
        check(run.providerCalls == 1 && completions == 5 && !panel.isVisible, "ready entry point reaches drafting without a setup notice")
        print("PASS \(checks) Double Tap feedback assertions")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, default=Path(tempfile.gettempdir()) / "sentient-double-tap-setup.png")
    args = parser.parse_args()
    source = (APP / "Double Tap/DoubleTap.swift").read_text()
    methods = "\n".join(member(source, signature) for signature in [
        "    func start(", "    func cancel()", "    private func showSetupRequired("])
    with tempfile.TemporaryDirectory(prefix="sentient-double-tap-feedback-") as directory:
        root = Path(directory)
        (root / "Fixture.swift").write_text(FIXTURE.replace("// METHODS", methods))
        notice = (APP / "Double Tap/DoubleTapSetupNotice.swift").read_text().split("#Preview")[0]
        (root / "Notice.swift").write_text(notice)
        executable = root / "feedback"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
                        "-parse-as-library", str(APP / "Double Tap/CaretSwirl.swift"), str(root / "Notice.swift"),
                        str(root / "Fixture.swift"), "-o", str(executable)], check=True, timeout=60)
        subprocess.run([str(executable), str(args.snapshot.resolve())], check=True, timeout=20)


if __name__ == "__main__":
    main()
