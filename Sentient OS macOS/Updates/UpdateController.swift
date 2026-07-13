//
//  UpdateController.swift
//  Sentient OS macOS
//
//  Owns the Sparkle updater and wires it to our own UI. Creates one SPUUpdater targeting the app's
//  main bundle, driven by SentientUpdateDriver (our OLED gate) with this object as the SPUUpdaterDelegate.
//  AppState holds one of these and calls `start()` — GUI path only (never the root wake-helper). The
//  menu bar and Settings call `checkForUpdatesNow(from:)`, tagging which window hosts the info card.
//
//  Chrome-style silent relaunch: once Sparkle has silently downloaded + staged an update, it calls our
//  `willInstallUpdateOnQuit` hook. We take over and, the moment it's SAFE (no pipeline run in flight and
//  the user isn't actively using the app), install + relaunch with zero UI — so the user never has to
//  quit. The OLED gate only surfaces for user-initiated checks or when a silent install is impossible
//  (needs an admin password, or errors).
//
//  Config (feed URL, EdDSA key, check interval) lives in Info.plist — see
//  Documentation/Auto-Update (Sparkle).md. This file is the runtime glue.
//

import AppKit
import Foundation
import Sparkle

@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {

    /// The observable state our OLED update UI (UpdateGateView) reads and drives.
    let model = UpdateModel()

    private let driver: SentientUpdateDriver
    private var updater: SPUUpdater!

    /// Sparkle's "install + relaunch now" trigger for a silently-staged update, stashed until the
    /// moment is safe (see `isSafeToRelaunch`). Set from `willInstallUpdateOnQuit`; cleared once fired.
    private var pendingInstallHandler: (() -> Void)?
    /// Polls for an idle-safe moment while an install is pending. Invalidated the instant we install.
    private var idleTimer: Timer?

    override init() {
        let model = self.model
        driver = SentientUpdateDriver(model: model)
        super.init()
        updater = SPUUpdater(hostBundle: .main,
                             applicationBundle: .main,
                             userDriver: driver,
                             delegate: self)
    }

    /// Start scheduling checks, and immediately do one silent background check so a mandatory update
    /// gates at launch. With no reachable feed this is a no-op (fail-open — nobody gets locked out).
    func start() {
        do {
            try updater.start()
            if updater.automaticallyChecksForUpdates {
                updater.checkForUpdatesInBackground()
            }
        } catch {
            Log("Sparkle: updater failed to start — \(error.localizedDescription)")
        }
    }

    /// A user-asked check (menu bar / Settings). Shows the small info card for "checking" and
    /// "you're up to date" in the originating window; escalates to the full gate if a real
    /// update is found.
    func checkForUpdatesNow(from origin: UpdateModel.CheckOrigin) {
        guard updater.canCheckForUpdates else { return }
        model.userInitiated = true
        model.checkOrigin = origin
        updater.checkForUpdates()
    }

    // MARK: - Read-only surface for Settings

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
    var lastCheckDate: Date? { updater.lastUpdateCheckDate }

    /// The installed version, formatted for display, e.g. "1.2.0 (42)".
    static var currentVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String
        if let build, build != short { return "\(short) (\(build))" }
        return short
    }

    // MARK: - SPUUpdaterDelegate

    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        if let error {
            Log("Sparkle: update cycle finished with error — \((error as NSError).localizedDescription)")
        }
    }

    /// Silent path: Sparkle has downloaded + staged an update for install-on-quit. Returning `true`
    /// makes US responsible for triggering the install — we MUST eventually call the handler, or
    /// Sparkle's update cycle stays blocked for the session. We stash it and fire it the moment it's
    /// idle-safe; if the user quits first, Sparkle installs the staged update on quit anyway.
    @objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)
    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        pendingInstallHandler = immediateInstallHandler
        scheduleInstallWhenIdle()
        return true
    }

    /// Last breath before the silent relaunch. Pipeline state is already durable (crash-safe CycleStore
    /// marks), so there's nothing extra to flush — this is just a breadcrumb.
    @objc(updaterWillRelaunchApplication:)
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Log("Sparkle: relaunching into the new version")
    }

    // MARK: - Idle-gated silent install

    /// Start (re)trying to install the staged update. Retries every 30s so a heavy/active session is
    /// caught the moment it goes quiet; also tries once immediately.
    private func scheduleInstallWhenIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.installIfSafe() }
        }
        installIfSafe()
    }

    private func installIfSafe() {
        guard let install = pendingInstallHandler, isSafeToRelaunch else { return }
        pendingInstallHandler = nil
        idleTimer?.invalidate()
        idleTimer = nil
        Log("Sparkle: idle-safe — installing staged update and relaunching silently")
        install()   // Sparkle terminates, installs, and relaunches us — zero UI.
    }

    /// Two invariants: never relaunch out from under an in-flight processing run, and never yank the
    /// app away from a user who's actively using it. Frontmost with a key window counts as "in use"
    /// unless they've been idle 5+ minutes; if we're not frontmost at all, the relaunch is invisible.
    private var isSafeToRelaunch: Bool {
        if PipelineActivity.shared.isRunning { return false }
        let appIsFrontmost = NSApp.isActive && NSApp.keyWindow != nil
        let anyInput = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType — time since any keyboard/mouse event
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return !appIsFrontmost || idleSeconds > 300
    }
}
