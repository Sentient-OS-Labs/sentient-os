#!/usr/bin/env python3
"""Exercise the production modifier monitor with deterministic input, without capturing audio."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Sentient OS macOS'
FIXTURE = r'''
import AppKit

enum ShortcutPreferences { static var isRecording = false }
@main struct Tests {
    @MainActor static func main() {
        var checks = 0
        func check(_ value: Bool, _ text: String) { precondition(value, text); checks += 1 }
        let idle = ShortcutActivity(keys: 0, clicks: 0, scrolls: 0)
        let typed = ShortcutActivity(keys: 1, clicks: 0, scrolls: 0)
        for key in ShortcutKey.allCases {
            let generic: NSEvent.ModifierFlags = [.leftCommand, .rightCommand].contains(key) ? .command
                : [.leftOption, .rightOption].contains(key) ? .option : .control
            let flags = NSEvent.ModifierFlags(rawValue: generic.rawValue | UInt(key.deviceBit))
            let monitor = SidekickHotkeyMonitor()
            monitor.setKeys([key])
            var taps = 0, holds = 0, sends = 0, cancels = 0
            var accepted = true
            monitor.onTap = { received, _, _ in check(received == key, "configured tap key"); taps += 1 }
            monitor.onHold = { received in check(received == key, "configured hold key"); holds += 1; return accepted }
            monitor.onHoldEnd = { _, send in if send { sends += 1 } else { cancels += 1 } }
            func down(_ time: Double, activity: ShortcutActivity? = nil) {
                monitor.flagsForTesting(key: key, flags: flags, at: time, activity: activity ?? idle)
            }
            func up(_ time: Double, activity: ShortcutActivity? = nil, lastInput: Double = -.infinity) {
                monitor.flagsForTesting(key: key, flags: [], at: time, activity: activity ?? idle, lastInputTime: lastInput)
            }
            func tick(_ time: Double, activity: ShortcutActivity? = nil, pressed: Bool = true,
                      lastInput: Double = -.infinity, mouse: Int = 0, recording: Bool = false) {
                monitor.holdForTesting(at: time, flags: generic, activity: activity ?? idle,
                    pressedKeys: pressed ? nil : [], lastInputTime: lastInput, mouseButtons: mouse, recording: recording)
            }
            down(1); tick(1.24); up(1.24)
            check(taps == 1 && holds == 0, "short press remains a tap")
            down(2); up(2.1); down(2.2); up(2.3)
            check(taps == 3 && holds == 0, "two quick presses remain two taps for Double Tap")
            down(3); tick(3.25); tick(3.30); up(3.35); up(3.4)
            check(holds == 1 && sends == 1 && taps == 3, "qualified hold sends once and never emits a tap")
            down(4); tick(4.25); tick(5); up(5.1)
            check(holds == 2 && sends == 2, "long hold remains active until release")
            down(6); tick(6.2, activity: typed); tick(6.3, activity: typed); up(6.4, activity: typed)
            check(holds == 2 && taps == 3, "Command combinations suppress both hold and tap")
            down(7); tick(7.3, lastInput: 7.1); up(7.4, lastInput: 7.1)
            check(holds == 2, "delayed keyboard activity suppresses hold")
            down(8); tick(8.25); tick(8.3, activity: typed); up(8.4, activity: typed)
            check(cancels == 1 && sends == 2, "typing after activation cancels without sending")
            down(9); tick(9.25); up(9.4, activity: typed)
            check(cancels == 2 && sends == 2, "release checks activity even between timer ticks")
            down(10); tick(10.25); tick(10.3, pressed: false); monitor.reconcileForTesting(pressedKeys: []); up(10.4)
            check(cancels == 3 && sends == 2, "missed key-up cancels instead of sending")
            down(11); tick(11.25); tick(11.3, recording: true); up(11.4)
            check(cancels == 4, "shortcut recording cancels an active hold")
            down(12); tick(12.25); monitor.setKeys([]); up(12.4)
            check(cancels == 5 && sends == 2, "rebinding cancels the old gesture")
            monitor.setKeys([key]); accepted = false
            let oldTaps = taps, oldHolds = holds
            down(13); tick(13.25); tick(14); up(14.1)
            check(holds == oldHolds + 1 && taps == oldTaps && sends == 2,
                  "denied voice admission consumes the hold without retrying or becoming a tap")
            accepted = true
            down(15); tick(15.25); monitor.stop()
            check(cancels == 6, "stopping the monitor cancels voice")
            monitor.setKeys([key])
            let previousTaps = taps
            down(16); tick(16.1, pressed: false); up(16.11)
            check(taps == previousTaps + 1, "poll before queued key-up preserves a short tap")
            down(17); tick(17.25); tick(17.3, pressed: false); up(17.31)
            check(sends == 3, "poll before queued key-up preserves hold release")
            monitor.stop()
            monitor.setKeys([key])
            let peer: ShortcutKey
            switch key {
            case .leftCommand: peer = .rightCommand
            case .rightCommand: peer = .leftCommand
            case .leftOption: peer = .rightOption
            case .rightOption: peer = .leftOption
            case .leftControl: peer = .rightControl
            case .rightControl: peer = .leftControl
            }
            let previousHolds = holds
            down(18)
            monitor.holdForTesting(at: 18.3, flags: generic, activity: idle, pressedKeys: [key, peer])
            up(18.4)
            check(holds == previousHolds, "both sides of a modifier cannot qualify as a standalone hold")
            monitor.stop()
        }
        print("PASS: \(checks) modifier push-to-talk checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-hotkey-hold-') as directory:
    root = Path(directory)
    source = root / 'fixture.swift'
    source.write_text(FIXTURE)
    binary = root / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
                    '-DDEBUG', '-parse-as-library', str(source),
                    str(APP / 'System/Shortcuts/ShortcutKey.swift'),
                    str(APP / 'System/Shortcuts/ShortcutGesture.swift'),
                    str(APP / 'Notch Magic/SidekickHotkeyMonitor.swift'), '-o', str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=20)
