#!/usr/bin/env python3
"""Exercise the actual outside-click handler without sending global input or running Sidekick."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'Sentient OS macOS/Notch Magic/NotchWindowController.swift').read_text()
a = source.index('    private func notchMouseDown(at location: NSPoint)')
b = source.index("    /// The event's own screen-coord location", a)
handler = source[a:b].replace('private func', 'func', 1)
fixture = r'''
import AppKit
enum Phase { case hidden, opening, typing, message, recovery, listening, transcribing, running }
final class Panel { var isVisible = true; var keys = 0; func makeKey() { keys += 1 } }
final class Recovery { var dismissals = 0, focused = false; func dismiss() { dismissals += 1 }; func setFocused(_ value: Bool) { focused = value } }
final class Run { let recovery = Recovery() }
final class Press { var isTracking = false }
final class Coordinator {
 var phase = Phase.typing, typingDismissals = 0, messageDismissals = 0, cancellations = 0
 let run = Run(), notchPress = Press()
 func dismissTyping() { typingDismissals += 1; phase = .hidden }
 func dismissMessagePreview() { messageDismissals += 1; phase = .hidden }
 func cancelCurrent() -> Bool { cancellations += 1; phase = .hidden; return true }
}
final class Controller {
 var panel: Panel? = Panel()
 let coordinator = Coordinator()
 var inside = false
 func cursorOverSilhouette(at point: NSPoint) -> Bool { inside }
 // HANDLER
}
@main struct Test {
 static func main() {
  _ = NSApplication.shared
  let screen = NSScreen.screens[0].frame
  let point = NSPoint(x: screen.midX, y: screen.midY)
  var checks = 0
  func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
  let typing = Controller(); typing.notchMouseDown(at: point)
  check(typing.coordinator.phase == .hidden && typing.coordinator.typingDismissals == 1, "first click dismisses synchronously")
  let message = Controller(); message.coordinator.phase = .message; message.notchMouseDown(at: point)
  check(message.coordinator.messageDismissals == 1, "reading preview dismisses without a key-window dependency")
  let recovery = Controller(); recovery.coordinator.phase = .recovery; recovery.inside = true; recovery.notchMouseDown(at: point)
  check(recovery.panel?.keys == 1 && recovery.coordinator.run.recovery.focused, "inside question click still focuses")
  recovery.inside = false; recovery.notchMouseDown(at: point)
  check(recovery.coordinator.run.recovery.dismissals == 1, "outside question click dismisses")
  for phase in [Phase.opening, .listening, .transcribing] {
   let c = Controller(); c.coordinator.phase = phase; c.notchMouseDown(at: point)
   check(c.coordinator.cancellations == 1, "pending input can be dismissed")
  }
  let held = Controller(); held.coordinator.phase = .listening; held.coordinator.notchPress.isTracking = true; held.notchMouseDown(at: point)
  check(held.coordinator.cancellations == 0, "held voice gesture retains release-to-send")
  let working = Controller(); working.coordinator.phase = .running; working.notchMouseDown(at: point)
  check(working.coordinator.cancellations == 0 && working.coordinator.phase == .running, "ordinary work clicks never stop the agent")
  let inside = Controller(); inside.inside = true; inside.notchMouseDown(at: point)
  check(inside.coordinator.phase == .typing, "inside prompt click stays open")
  let probe = Controller(); probe.notchMouseDown(at: NSPoint(x: 1_000_000, y: 1_000_000))
  check(probe.coordinator.phase == .typing, "off-display automation probe is ignored")
  probe.panel?.isVisible = false; probe.notchMouseDown(at: point)
  check(probe.coordinator.phase == .typing, "hidden panel does not intercept outside clicks")
  print("PASS: \(checks) notch click-away routing checks")
 }
}
'''.replace('// HANDLER', handler)
with tempfile.TemporaryDirectory(prefix='sentient-click-away-') as directory:
    path = Path(directory)
    (path / 'test.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
                    '-parse-as-library', str(path / 'test.swift'), '-o', str(path / 'test')], check=True, timeout=60)
    subprocess.run([str(path / 'test')], check=True, timeout=20)
