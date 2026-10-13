//
//  WakeHelperProtocol.swift
//  Sentient OS macOS  ·  Scheduling/
//
//  The XPC contract between the app (client) and the root "wake helper" — the SAME app binary
//  that launchd relaunches in helper mode (see main.swift). The narrow API controls sleep,
//  schedules wakes, and maintains only Sentient’s own helper files. Wake operations are
//  guarded by a deadman so a crashed app can never leave the Mac unable to sleep.
//

import Foundation

@objc protocol WakeHelperProtocol {
    /// Verify readiness and retire the legacy daemon after native approval. Never prompts.
    func prepare(withReply reply: @escaping (Bool) -> Void)
    /// Restore sleep and remove only our wake/state before the app unregisters this daemon.
    func prepareForRemoval(withReply reply: @escaping (Bool) -> Void)
    /// Re-enable operations only when the user cancels an incomplete uninstall.
    func cancelRemoval(withReply reply: @escaping (Bool) -> Void)

    /// Diagnostics use the signed GUI client's choice and anonymous UUID, never root's defaults.
    func configureDiagnostics(enabled: Bool, anonymousID: String, withReply reply: @escaping () -> Void)

    /// Keep the Mac awake (root `pmset disablesleep 1`) and start a deadman timer. If the app
    /// stops calling `heartbeat()` within `timeoutSeconds`, the helper resets disablesleep itself.
    func beginAwake(timeoutSeconds: Int, withReply reply: @escaping (Bool) -> Void)
    /// Feed the deadman — the app calls this every ~60s while a run is in progress.
    func heartbeat(withReply reply: @escaping (Bool) -> Void)
    /// Stop keeping awake (root `pmset disablesleep 0`) and cancel the deadman. Idempotent.
    func endAwake(withReply reply: @escaping (Bool) -> Void)
    /// Schedule a one-time system wake at a wall-clock time (epoch seconds). Idempotent — re-arming
    /// the same time never piles up duplicate wakes.
    func armWake(atEpoch epoch: Double, withReply reply: @escaping (Bool) -> Void)
    /// Cancel the wake we last armed. Also invoked automatically when the app's connection drops
    /// (quit / crash / force-quit), so a Mac with Sentient closed never wakes on a stale schedule.
    func cancelWake(withReply reply: @escaping (Bool) -> Void)
    /// Wipe EVERY scheduled wake (clean slate) — backs the "Done" button so finalizing a time leaves
    /// exactly one timer with no duplicates. (System maintenance wakes are auto-rescheduled by macOS.)
    func cancelAllWakes(withReply reply: @escaping (Bool) -> Void)
}

/// Shared constants — the names here MUST match the LaunchDaemon plist we install in the bundle.
nonisolated enum WakeHelperConfig {
    /// Mach service name (must equal the plist's `MachServices` key).
    static let machServiceName = "jesai.Sentient-OS-macOS.WakeHelper.Managed"
    /// LaunchDaemon plist filename in Contents/Library/LaunchDaemons/.
    static let daemonPlistName = "jesai.Sentient-OS-macOS.WakeHelper.Managed.plist"
    /// CLI flag that puts the shared binary into root helper mode.
    static let helperFlag = "--wake-helper-managed"
    // Keep the old entry point working until the newly approved daemon can retire it.
    static let legacyHelperFlag = "--wake-helper"
    static let legacyServiceName = "jesai.Sentient-OS-macOS.WakeHelper"
    static let legacyPlistPath = "/Library/LaunchDaemons/\(legacyServiceName).plist"
    /// The absolute awake ceiling: no matter what the app does (even alive and heartbeating), the
    /// helper force-restores normal sleep this long after `beginAwake`. The last net under the
    /// deadman — a wedged-but-heartbeating run can never hold a Mac awake past this.
    static let maxAwakeSeconds = 6 * 3600
}
