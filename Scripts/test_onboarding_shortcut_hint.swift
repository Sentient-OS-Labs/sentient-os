// Compile with OnboardingShortcutHint.swift, ShortcutKey.swift, ShortcutGesture.swift
// and ShortcutPreferences.swift. No application, event monitor or real preferences are used.
import AppKit
import SwiftUI

// Rendering uses the real palette in the signed app; this keeps the logic test standalone.
enum GlowHalo { static let stops: [Color] = [.orange, .pink, .purple, .blue] }

@main struct Checks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        let idle = ShortcutActivity(keys: 0, clicks: 0, scrolls: 0)
        let left = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | UInt(ShortcutKey.leftCommand.deviceBit))
        let right = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | UInt(ShortcutKey.rightCommand.deviceBit))
        func event(_ detector: inout OnboardingWrongCommandTap, _ flags: NSEvent.ModifierFlags,
                   at time: Double, key: ShortcutKey = .leftCommand, activity: ShortcutActivity? = nil,
                   lastInput: Double = -.infinity, eligible: Bool = true, mouse: Bool = false) -> Bool {
            detector.flagsChanged(keyCode: key.keyCode, flags: flags, at: time,
                activity: activity ?? idle, lastInputTime: lastInput, eligible: eligible, mouseIsDown: mouse)
        }
        var tap = OnboardingWrongCommandTap()
        check(!event(&tap, left, at: 10), "A down edge alone is not a mistaken tap")
        check(event(&tap, [], at: 10.1), "A standalone left Command tap gives one hint")
        check(!event(&tap, [], at: 10.2), "Duplicate releases do not repeat feedback")
        _ = event(&tap, right, at: 11, key: .rightCommand)
        check(!event(&tap, [], at: 11.1, key: .rightCommand), "Correct Command never gives a correction")
        _ = event(&tap, left, at: 12)
        tap.interrupt() // A local keyDown, such as Command-C, is never inspected or consumed.
        check(!event(&tap, [], at: 12.1), "Keyboard combinations do not flash the hint")
        _ = event(&tap, left, at: 13)
        check(!event(&tap, [], at: 13.1, activity: .init(keys: 1, clicks: 0, scrolls: 0)), "Input counters reject intervening typing")
        _ = event(&tap, left, at: 14)
        check(!event(&tap, [], at: 14.1, lastInput: 14.05), "Delayed input cannot look like a standalone tap")
        _ = event(&tap, left.union(.shift), at: 15)
        check(!event(&tap, [], at: 15.1), "Other held modifiers suppress the hint")
        _ = event(&tap, left.union(right), at: 16)
        check(!event(&tap, [], at: 16.1), "Both Command keys are not an accidental left tap")
        _ = event(&tap, left, at: 17, mouse: true)
        check(!event(&tap, [], at: 17.1), "Modified mouse gestures are ignored")
        _ = event(&tap, left, at: 18)
        check(!event(&tap, left, at: 18.2), "A held modifier cannot repeat")
        check(!event(&tap, [], at: 18.6), "A long hold is not treated as a tap")
        _ = event(&tap, left.union(.capsLock), at: 19)
        check(event(&tap, [.capsLock], at: 19.1), "Latched Caps Lock does not prevent a real tap")
        _ = event(&tap, left, at: 20)
        tap.reset()
        check(!event(&tap, [], at: 20.1), "Focus loss or detachment discards the partial tap")
        _ = event(&tap, left, at: 21, eligible: false)
        check(!event(&tap, [], at: 21.1), "An ineligible window never arms a tap")
        _ = event(&tap, left, at: 22)
        check(!event(&tap, [], at: 22.1, eligible: false), "Losing eligibility before release cancels it")

        let hint = OnboardingShortcutHint()
        hint.flash(); check(!hint.isActive, "Hidden instructions cannot flash")
        hint.activate(); hint.flash()
        check(hint.isActive && hint.pulseCount == 1, "Visible instruction starts one sweep")
        let began = hint.began!
        check(hint.progress(at: began) == 0 && hint.progress(at: began + 1) == 1, "Sweep has a one-second duration")
        try await Task.sleep(for: .milliseconds(200))
        hint.flash()
        check(hint.began == began && hint.pulseCount == 1, "A mistaken double tap coalesces without restarting")
        try await Task.sleep(for: .milliseconds(950))
        check(!hint.isActive, "Feedback expires on its own")
        hint.flash()
        try await Task.sleep(for: .milliseconds(500))
        hint.clear(); hint.flash()
        try await Task.sleep(for: .milliseconds(600))
        check(hint.isActive, "An old expiry cannot clear a newer sweep")
        hint.deactivate()
        check(!hint.isActive && !hint.acceptsInput, "Leaving the instruction clears both input and animation")
        hint.flash()
        check(!hint.isActive, "A late callback cannot revive a removed instruction")
        print("PASS: \(checks) onboarding wrong-key gesture and feedback checks")
    }
}
