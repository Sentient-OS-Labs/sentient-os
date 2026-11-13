#!/usr/bin/env python3
"""Exercise the production sensor owner with inert hardware and isolated lifecycle events."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
import AppKit

enum Fixture {
    static var locked = false
    static var allowsTaps = false
}
final class FixtureApplication { var isActive = true }
let NSApp: FixtureApplication? = FixtureApplication()
final class NSScreen {
    static var screens = [NSScreen()]
    let displayID: Int = 1
}
func CGDisplayIsBuiltin(_ display: Int) -> UInt32 { 1 }
func CGSessionCopyCurrentDictionary() -> CFDictionary? {
    ["CGSSessionScreenIsLocked": Fixture.locked] as CFDictionary
}
enum PhysicalTapClock { static var now = 100.0 }
enum NotchPreferences {
    static var enabled = true
    static var sensitivity = 1.1
    static func physicalTapEnabled() -> Bool { enabled }
    static func physicalTapThreshold() -> Double { sensitivity }
}
extension Notification.Name {
    static let physicalNotchTapChanged = Notification.Name("fixture.physicalTapChanged")
}
final class PhysicalTapSensor {
    enum Status { case stopped, starting, settling, ready, unavailable, stalled }
    static var current: PhysicalTapSensor!
    let onTap: (Double, UInt64) -> Void
    let onStatus: (Status, UInt64) -> Void
    var configurations = 0
    var generation: UInt64 = 0
    var enabled = false
    init(onTap: @escaping (Double, UInt64) -> Void, onStatus: @escaping (Status, UInt64) -> Void) {
        self.onTap = onTap
        self.onStatus = onStatus
        Self.current = self
    }
    func configure(enabled: Bool, sensitivity: Double, generation: UInt64) {
        configurations += 1
        self.enabled = enabled
        self.generation = generation
    }
    func acceptsDelivery(at time: Double, generation: UInt64) -> Bool {
        enabled && generation == self.generation
    }
    func drainForTermination() {}
}

@main enum Tests {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(10)) }
        let owner = PhysicalNotchTap(), film = UUID(), successor = UUID()
        var delivered = 0
        owner.setWarmup(true, owner: film)
        owner.start(allowed: { Fixture.allowsTaps }, onTap: { delivered += 1 })
        let sensor = PhysicalTapSensor.current!
        check(owner.isEnabled && sensor.configurations == 1, "intro warms hardware before the lesson")
        sensor.onStatus(.ready, sensor.generation)
        try await settle()
        sensor.onTap(PhysicalTapClock.now, sensor.generation)
        try await settle()
        check(delivered == 0, "warmup never dispatches a tap")
        check(owner.status == .ready, "warmup publishes readiness")

        // Queue a warmup gesture, then arm the lesson before main-actor delivery.
        sensor.onTap(PhysicalTapClock.now, sensor.generation)
        PhysicalTapClock.now += 0.1
        Fixture.allowsTaps = true
        owner.refresh()
        try await settle()
        check(delivered == 0, "a queued intro tap cannot answer the lesson")
        check(sensor.configurations == 1 && owner.status == .ready, "arming retains the warm sensor baseline")
        sensor.onTap(PhysicalTapClock.now, sensor.generation)
        try await settle()
        check(delivered == 1, "a fresh lesson tap dispatches")

        Fixture.allowsTaps = false
        owner.refresh()
        sensor.onTap(PhysicalTapClock.now, sensor.generation)
        try await settle()
        check(delivered == 1 && sensor.configurations == 1, "between lessons hardware stays warm and taps are ignored")
        owner.setWarmup(true, owner: successor)
        owner.setWarmup(false, owner: film)
        owner.setWarmup(false, owner: film)
        check(owner.isEnabled && sensor.configurations == 1, "old film teardown preserves a successor's warmup")

        NSApp!.isActive = false
        owner.refresh()
        check(!owner.isEnabled, "background intro releases hardware")
        NSApp!.isActive = true
        owner.refresh()
        check(owner.isEnabled, "foreground intro resumes warmup")
        let beforeSleep = sensor.generation
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        check(!owner.isEnabled, "sleep stops warmup")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        check(owner.isEnabled && sensor.generation != beforeSleep, "wake starts a fresh sensor generation")
        Fixture.allowsTaps = true
        owner.refresh()
        sensor.onTap(PhysicalTapClock.now, beforeSleep)
        try await settle()
        check(delivered == 1, "pre-sleep callbacks remain invalid")
        Fixture.allowsTaps = false
        owner.refresh()

        Fixture.locked = true
        owner.refresh()
        check(!owner.isEnabled, "locked screen stops warmup")
        Fixture.locked = false
        owner.refresh()
        owner.beginCalibration()
        check(!owner.isEnabled && owner.isCalibrating, "calibration owns hardware exclusively")
        owner.endCalibration()
        check(owner.isEnabled, "warmup resumes after calibration")
        let beforeSensitivity = sensor.configurations
        NotchPreferences.sensitivity = 1.4
        owner.refresh()
        check(sensor.configurations == beforeSensitivity + 1, "sensitivity changes reach the sensor")
        NotchPreferences.enabled = false
        owner.refresh()
        check(!owner.isEnabled, "disabled physical taps suppress warmup")
        NotchPreferences.enabled = true
        NSScreen.screens = []
        owner.refresh()
        check(!owner.isEnabled, "warmup requires an open built-in display")
        NSScreen.screens = [NSScreen()]
        owner.refresh()
        owner.setWarmup(false, owner: successor)
        check(!owner.isEnabled, "leaving the last film releases hardware")

        Fixture.allowsTaps = true
        owner.refresh()
        check(owner.isEnabled, "normal post-onboarding use starts hardware")
        owner.setWarmup(true, owner: film)
        let beforeRelease = sensor.configurations
        owner.setWarmup(false, owner: film)
        check(owner.isEnabled && sensor.configurations == beforeRelease, "film cleanup preserves active normal use")
        owner.stop()
        check(!owner.isEnabled && !sensor.enabled, "shutdown releases hardware")
        Fixture.allowsTaps = false
        owner.start(allowed: { Fixture.allowsTaps }, onTap: {})
        check(!owner.isEnabled, "shutdown clears warmup ownership")
        owner.stop()
        print("PASS: \(checks) physical tap warmup and admission checks")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-tap-warmup-") as directory:
    root = Path(directory)
    fixture = root / "Warmup.swift"
    fixture.write_text(FIXTURE)
    binary = root / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-parse-as-library", str(ROOT / "Sentient OS macOS/Notch Magic/PhysicalNotchTap.swift"),
        str(fixture), "-o", str(binary),
    ], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=20)
