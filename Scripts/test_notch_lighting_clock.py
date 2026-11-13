#!/usr/bin/env python3
"""Exercise the production lighting display link: idle, resume, detach and teardown.

Shows a tiny nonactivating test window briefly; no app data or provider is involved.
"""
from pathlib import Path
from swift_fixture import platform_plugin_flags
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS/Notch Magic"
FIXTURE = r'''@main struct ClockChecks {
 @MainActor static func main() async {
  _ = NSApplication.shared
  let clock = NotchLightingClock()
  let driver = NotchLightingClockDriver.DriverView(clock: clock)
  let window = NSWindow(contentRect: NSRect(x: 10, y: 40, width: 20, height: 20), styleMask: [.borderless], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = driver
  window.orderFrontRegardless()
  var checks = 0
  func check(_ pass: Bool, _ note: String) {
   if !pass { FileHandle.standardError.write(Data(("FAIL: " + note + "\n").utf8)) }
   precondition(pass, note); checks += 1
  }
  let initial = clock.date
  try? await Task.sleep(for: .milliseconds(150))
  check(clock.date == initial, "clock starts paused")
  driver.setPaused(false)
  try? await Task.sleep(for: .milliseconds(350))
  check(clock.date > initial, "visible active clock advances")
  driver.setPaused(true)
  let paused = clock.date
  try? await Task.sleep(for: .milliseconds(200))
  check(clock.date == paused, "paused clock has no callbacks")
  check(clock.currentDate > paused, "newly active leaves cannot sample a stale pre-pause date")
  driver.setPaused(false)
  try? await Task.sleep(for: .milliseconds(200))
  check(clock.date > paused, "clock resumes")
  window.contentView = nil
  let detached = clock.date
  try? await Task.sleep(for: .milliseconds(200))
  check(clock.date == detached, "detached view invalidates display link")
  window.contentView = driver
  try? await Task.sleep(for: .milliseconds(200))
  check(clock.date > detached, "reattached active view resumes")
  driver.stop()
  let stopped = clock.date
  try? await Task.sleep(for: .milliseconds(200))
  check(clock.date == stopped, "dismantling invalidates callbacks")
  window.orderOut(nil); window.contentView = nil
  print("PASS: \(checks) display-linked clock lifecycle checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix="sentient-lighting-clock-") as directory:
    root = Path(directory)
    source = root / "clock.swift"
    source.write_text((APP / "IslandColorTreatment.swift").read_text() + "\n" + FIXTURE)
    executable = root / "clock"
    subprocess.run(["xcrun", "swiftc", *platform_plugin_flags(), "-O", "-parse-as-library", "-swift-version", "5",
                    "-default-isolation", "MainActor", str(source), str(APP / "NotchShape.swift"),
                    "-o", str(executable)], check=True, timeout=60)
    subprocess.run([str(executable)], check=True, timeout=20)
