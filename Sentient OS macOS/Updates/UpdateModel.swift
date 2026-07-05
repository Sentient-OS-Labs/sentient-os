//
//  UpdateModel.swift
//  Sentient OS macOS
//
//  The observable bridge between Sparkle's update flow and our OLED forced-update UI. Sparkle's
//  custom user driver (SentientUpdateDriver) pushes state in through the `began…/found…/…` methods
//  and stashes its reply/acknowledge closures here; the SwiftUI gate (UpdateGateView) reads `phase`
//  and calls `installNow()/dismissInfo()/quit()` to fire those closures back. One live update flow
//  at a time. Owned by UpdateController. Doc: Documentation/Auto-Update (Sparkle).md
//

import SwiftUI
import AppKit
import Sparkle

@MainActor
@Observable
final class UpdateModel {

    /// Where the update flow is right now — drives the whole UI.
    enum Phase: Equatable {
        case idle
        case checking                         // user asked; waiting on the feed
        case upToDate                         // user asked; nothing newer
        case found(version: String)           // a mandatory update is available — the gate
        case downloading(fraction: Double?)   // nil = indeterminate (no content-length yet)
        case extracting(fraction: Double)
        case installing
        case failed(message: String, duringUpdate: Bool)
    }

    /// Which surface to present over the app, if any.
    enum Surface: Equatable { case none, gate, info }

    private(set) var phase: Phase = .idle

    /// Was the in-flight check user-triggered? Governs whether "checking"/"up to date"/"check
    /// failed" surface a small info card (yes) or stay silent (a background check finding nothing).
    var userInitiated = false

    // Download byte accounting (feeds the determinate progress bar).
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0

    // Sparkle callbacks we stash to fire on a user action.
    private var reply: ((SPUUserUpdateChoice) -> Void)?
    private var acknowledge: (() -> Void)?
    private var cancelCheck: (() -> Void)?

    /// True once an update has actually been offered/started (found → installing) — used to decide
    /// whether a Sparkle error is a gate-blocking update failure or just a quiet check failure.
    var isMidUpdate: Bool {
        switch phase {
        case .found, .downloading, .extracting, .installing: return true
        default: return false
        }
    }

    /// The full-screen mandatory gate, a small dismissible info card, or nothing. A failure DURING
    /// an update keeps the gate (the app still can't be trusted on the old version); a failed plain
    /// check only shows the info card, and only when the user asked.
    var surface: Surface {
        switch phase {
        case .idle:
            return .none
        case .found, .downloading, .extracting, .installing:
            return .gate
        case .failed(_, let duringUpdate):
            return duringUpdate ? .gate : (userInitiated ? .info : .none)
        case .checking, .upToDate:
            return userInitiated ? .info : .none
        }
    }

    // MARK: - Driver → model (called by SentientUpdateDriver on the main thread)

    func beganCheck(cancel: @escaping () -> Void) {
        cancelCheck = cancel
        phase = .checking
    }

    func foundUpdate(version: String, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        clearClosures()
        self.reply = reply
        phase = .found(version: version)
    }

    func notFound(acknowledge: @escaping () -> Void) {
        clearClosures()
        self.acknowledge = acknowledge
        phase = .upToDate
    }

    func failed(_ message: String, duringUpdate: Bool, acknowledge: (() -> Void)?) {
        clearClosures()
        self.acknowledge = acknowledge
        phase = .failed(message: message, duringUpdate: duringUpdate)
    }

    func downloadStarted() {
        expectedBytes = 0
        receivedBytes = 0
        phase = .downloading(fraction: nil)
    }

    func expected(bytes: UInt64) {
        expectedBytes = bytes
        receivedBytes = 0
    }

    func received(bytes: UInt64) {
        receivedBytes &+= bytes
        if expectedBytes > 0 {
            phase = .downloading(fraction: min(1.0, Double(receivedBytes) / Double(expectedBytes)))
        }
    }

    func extractingStarted() { phase = .extracting(fraction: 0) }
    func extracting(_ fraction: Double) { phase = .extracting(fraction: max(0, min(1, fraction))) }
    func installingNow() { phase = .installing }

    /// Sparkle tore the flow down (aborted or finished). Back to a blank slate.
    func reset() {
        clearClosures()
        phase = .idle
    }

    // MARK: - UI → model (called by UpdateGateView)

    /// The one mandatory action: begin (or resume) the install. Optimistically flips to the
    /// downloading state so the tap feels instant; Sparkle then drives the real progress.
    func installNow() {
        guard let reply else { return }
        self.reply = nil
        phase = .downloading(fraction: nil)
        reply(.install)
    }

    /// Dismiss the small info card (up-to-date / a plain check failure / cancel an in-flight check).
    func dismissInfo() {
        acknowledge?()
        cancelCheck?()
        clearClosures()
        phase = .idle
    }

    func quit() { NSApplication.shared.terminate(nil) }

    private func clearClosures() {
        reply = nil
        acknowledge = nil
        cancelCheck = nil
    }
}
