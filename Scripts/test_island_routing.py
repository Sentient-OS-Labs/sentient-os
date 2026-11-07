#!/usr/bin/env python3
"""Exercise actual island press routing without a microphone or global input events."""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS/Notch Magic'
source = (APP / 'CommandCoordinator.swift').read_text()
def method(signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

fixture = r'''
import AppKit
import Foundation
enum NotchAnchor: Equatable { case mainDisplay, builtInNotch, display(CGDirectDisplayID) }
enum NotchPhase { case hidden, typing, message, listening }
enum NotchPreferences { static var enabled = true; static func clickEnabled() -> Bool { enabled } }
final class Recovery { var isPending = false }
final class Run { var isRunning = false, isClearingChat = false, hasDeliveredFinalAnswer = false; let recovery = Recovery() }
final class Coordinator {
    var notchButtonAvailable = true, onboardingDemoArmed = false
    static var hasCompletedOnboarding = true
    var phase = NotchPhase.hidden, notchAnchor = NotchAnchor.mainDisplay
    let run = Run()
    let notchPress: NotchPressGesture
    var voices = 0, releases = 0
    init(_ press: NotchPressGesture) { notchPress = press }
    func beginDictation() -> Bool { voices += 1; phase = .listening; return true }
    func finishListening(send: Bool = true) { releases += 1 }
    func openNotchInput(anchor: NotchAnchor, door: String) { notchAnchor = anchor; phase = .typing }
    // METHODS
}
@main struct Tests {
    static func main() {
        var time = 0.0, checks = 0
        let press = NotchPressGesture(location: { NSPoint(x: 100, y: 100) }, buttons: { 1 }, uptime: { time })
        let c = Coordinator(press)
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        for anchor in [NotchAnchor.display(77), .display(92), .builtInNotch] {
            c.phase = .hidden
            c.notchMouseDown(anchor: anchor)
            time += 0.1; press.releaseForTesting()
            check(c.phase == .typing && c.notchAnchor == anchor, "tap stays on clicked display")
            c.phase = .hidden
            let before = c.voices
            c.notchMouseDown(anchor: anchor)
            time += 0.3; press.tickForTesting()
            check(c.phase == .listening && c.notchAnchor == anchor && c.voices == before + 1,
                  "qualified hold starts voice on clicked display")
            let released = c.releases
            press.releaseForTesting()
            check(c.releases == released + 1, "release finalizes voice exactly once")
        }
        c.phase = .message
        c.notchMouseDown(anchor: .display(77)); time += 0.3; press.tickForTesting()
        check(c.phase == .listening && c.notchAnchor == .display(77), "hold from a response starts voice on that display")
        press.releaseForTesting()
        c.phase = .hidden; c.notchButtonAvailable = false
        check(!c.beginNotchDictation(anchor: .display(77)), "disabled affordance cannot start voice")
        c.notchButtonAvailable = true; c.run.recovery.isPending = true
        check(!c.beginNotchDictation(anchor: .display(77)), "pending recovery blocks competing voice capture")
        print("PASS: \(checks) island tap/hold display routing checks")
    }
}
'''
fixture = fixture.replace('// METHODS', '\n'.join(method(s) for s in [
    'func beginNotchDictation(', 'func notchMouseDown(', 'func notchClicked(']))
with tempfile.TemporaryDirectory(prefix='sentient-island-routing-') as directory:
    root = Path(directory)
    (root / 'test.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-D', 'DEBUG', '-swift-version', '5', '-default-isolation', 'MainActor',
                    '-parse-as-library', str(APP / 'NotchPressGesture.swift'), str(root / 'test.swift'),
                    '-o', str(root / 'test')], check=True, timeout=60)
    subprocess.run([str(root / 'test')], check=True, timeout=20)
