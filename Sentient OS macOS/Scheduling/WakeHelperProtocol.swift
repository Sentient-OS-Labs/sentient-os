//
//  WakeHelperProtocol.swift
//  Sentient OS macOS  ·  Scheduling/
//
//  The XPC contract between the app (client) and the root "wake helper" — the SAME app binary
//  that launchd relaunches with --wake-helper (see main.swift). Deliberately tiny: the only code
//  that ever runs as root is these four operations (toggle keep-awake + schedule a wake), each
//  guarded by a deadman so a crashed app can never leave the Mac unable to sleep.
//

import Foundation

@objc protocol WakeHelperProtocol {
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
enum WakeHelperConfig {
    /// Mach service name (must equal the plist's `MachServices` key).
    static let machServiceName = "jesai.Sentient-OS-macOS.WakeHelper"
    /// LaunchDaemon plist filename in Contents/Library/LaunchDaemons/.
    static let daemonPlistName = "jesai.Sentient-OS-macOS.WakeHelper.plist"
    /// CLI flag that puts the shared binary into root helper mode.
    static let helperFlag = "--wake-helper"
    /// Code-signing requirement a client must satisfy to talk to the root helper. Bundle id +
    /// Apple anchor blocks arbitrary/other code; pin the Developer ID team for Release hardening.
    static let clientRequirement = "anchor apple generic and identifier \"jesai.Sentient-OS-macOS\""
}
