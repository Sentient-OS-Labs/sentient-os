//
//  UpdateNotice.swift
//  Sentient OS macOS
//
//  The "Sentient just updated" seam, in two halves:
//  · The WINDOWLESS-RELAUNCH FLAG — UpdateController stamps `recordSilentRelaunch()` the
//    instant an idle-gated silent install fires (the user wasn't in the app), and the NEW
//    version consumes it as `suppressHomeThisLaunch`: the home WindowGroup launches
//    `.suppressed`, so a background auto-update never shoves the window at someone who was
//    just living with Sentient in the menu bar. User-initiated updates (the OLED gate) and
//    mid-onboarding relaunches never suppress — those users should see the app come back.
//  · The UPDATE NOTICE — `checkAtLaunch()` diffs the persisted last-run version against the
//    running one; a change fires the "Sentient just updated." macOS notification (so the
//    relaunch Dock bounce is always explained) and arms the persistent in-app capsule
//    (UpdateNoticeCapsule, "Read the changelog"), which survives until the user dismisses it.
//

import AppKit
import Foundation

@MainActor
enum UpdateNotice {

    /// Written by the OLD version at its last breath (value = its own version string); consumed
    /// once by the new version at scene build.
    private static let suppressKey = "update.suppressHomeOnRelaunch"
    /// The armed in-app notice (value = the new version string). Persists until dismissed, so a
    /// menu-bar user who opens the home days after a silent update still sees it.
    private static let noticeKey = "update.notice"
    /// The version this app last ran as — the diff that detects EVERY update path (silent
    /// relaunch, install-on-quit, even a manual reinstall).
    private static let lastRunVersionKey = "app.lastRunVersion"

    static let changelogURL = URL(string: "https://github.com/Sentient-OS-Labs/sentient-os/releases/latest")!

    /// Called by UpdateController right before a SILENT (idle-gated) install relaunches the app.
    /// Only ever recorded after onboarding: a mid-onboarding user may have closed a broken
    /// onboarding window, and the post-update relaunch should bring it back fixed.
    static func recordSilentRelaunch() {
        guard UserDefaults.standard.bool(forKey: AppState.onboardingKey) else { return }
        UserDefaults.standard.set(UpdateController.currentVersionString, forKey: suppressKey)
    }

    /// True exactly on the launch that follows a silent auto-update — the home window stays
    /// suppressed. The stored value is the OLD version: if it matches the running one the
    /// install never actually landed (a failed swap relaunched the same build), and the window
    /// presents normally rather than silently vanishing on a normal launch.
    static let suppressHomeThisLaunch: Bool = {
        let defaults = UserDefaults.standard
        guard let oldVersion = defaults.string(forKey: suppressKey) else { return false }
        defaults.removeObject(forKey: suppressKey)
        return oldVersion != UpdateController.currentVersionString
    }()

    /// Launch-time version diff (AppState.init, after the self-test guard). A changed version
    /// means an update landed: fire the macOS notification and arm the in-app capsule. The
    /// first-ever launch just records — a fresh install is not an update.
    static func checkAtLaunch() {
        let defaults = UserDefaults.standard
        let current = UpdateController.currentVersionString
        let last = defaults.string(forKey: lastRunVersionKey)
        defaults.set(current, forKey: lastRunVersionKey)
        guard let last, last != current else { return }
        Log("Update: version changed \(last) → \(current) — arming the just-updated notice")
        defaults.set(current, forKey: noticeKey)
        Task { await Notify.now(title: "Sentient just updated.", body: "Now running version \(shortVersion).") }
    }

    /// The armed notice's version — nil when none. Views read this on appearance (the same
    /// pull-on-appear pattern as OvernightCaution.latest()).
    static var pending: String? { UserDefaults.standard.string(forKey: noticeKey) }

    static func dismiss() { UserDefaults.standard.removeObject(forKey: noticeKey) }

    /// "Read the changelog" — the latest GitHub release; opening it retires the notice.
    static func openChangelog() {
        NSWorkspace.shared.open(changelogURL)
        dismiss()
    }

    private static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
