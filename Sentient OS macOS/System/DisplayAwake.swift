//
//  DisplayAwake.swift
//  Sentient OS macOS
//
//  Keeps the SCREEN powered on for the lifetime of a foreground processing run, so the long
//  first ingest isn't cut short by macOS dimming the display and idle-sleeping the Mac while
//  real work is happening. This is the polite, no-root, no-entitlement path a video player
//  uses: `ProcessInfo.beginActivity(.idleDisplaySleepDisabled)` → hold the token → `endActivity`.
//  Keeping the display on implicitly blocks system idle-sleep too, so this covers both.
//
//  NB: this is intentionally NOT the WakeHelper's `pmset disablesleep` (that needs root, only
//  stops SYSTEM sleep, and exists for the headless 3am lid-shut case). This one is foreground-only.
//
//  begin()/end() are idempotent; `deinit` releases as a backstop.
//

import Foundation

final class DisplayAwake {
    private var token: NSObjectProtocol?

    /// Keep the display powered on. Safe to call twice — the second call is a no-op.
    func begin(reason: String) {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled], reason: reason)
        Log("DisplayAwake: holding the screen awake — \(reason)")
    }

    /// Release the hold; the display resumes its normal idle timer. Idempotent.
    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
        Log("DisplayAwake: released — screen may sleep normally again")
    }

    deinit { end() }
}
