//
//  Uninstall.swift
//  Sentient OS macOS  ·  System/
//
//  The one full teardown — FactoryReset's strict superset, driven by Settings → System →
//  Uninstall Sentient (UninstallView). Removes EVERYTHING Sentient ever created on this Mac:
//  the root wake helper (+ its /Library files), the cloud mirror copy AND the Keychain identity,
//  the knowledge base, the on-device model, the cycle store, the login item, the TCC Automation
//  grant, caches, and the whole defaults domain. Every step is best-effort and idempotent, so a
//  crash or relaunch mid-way just re-runs cleanly (post-wipe the app lands in onboarding).
//
//  Deliberately NOT touched: the .app bundle itself (the gone screen asks the user to drag it to
//  the Trash — decided 2026-07-10), ALL of ~/.codex (the computer-use payload, config.toml, and
//  the user's own codex login stay), the Desktop gift keepsakes, and the SIP-protected system
//  TCC rows. A destructive sequence must never drift — change it HERE only.
//
//  Key members: Stage (the sheet's whisper per step) · run(appState:progress:helperDecision:)
//  (the teardown) · finishAndQuit() (the gone screen's Quit + post-exit sweeper).
//

import Foundation
import AppKit

enum Uninstall {

    /// The user-facing teardown stages, in run order — the farewell sheet renders each `whisper`
    /// (the mono-caps voice) while its stage runs. The helper goes FIRST: it's the only stage that
    /// can ask for the user's password (and be declined), so a cancel there aborts the uninstall
    /// before anything irreversible has happened.
    enum Stage: CaseIterable {
        case helper, cloud, keychain, knowledge, model, traces
        var whisper: String {
            let key: String.LocalizationValue = switch self {
            case .helper:    "STANDING DOWN THE WAKE HELPER"
            case .cloud:     "REMOVING THE CLOUD COPY"
            case .keychain:  "CLEARING YOUR KEYCHAIN KEY"
            case .knowledge: "ERASING YOUR KNOWLEDGE BASE"
            case .model:     "REMOVING THE ON-DEVICE MODEL"
            case .traces:    "SWEEPING THE LAST TRACES"
            }
            return String(localized: key, locale: AppLanguage.resolvedLocale)
        }
    }

    /// The sheet's answer when the helper's admin prompt is declined.
    enum HelperChoice { case retry, skip, cancel }

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "jesai.Sentient-OS-macOS" }

    /// The full teardown. `progress` fires on the main actor before each stage so the sheet can
    /// render its whisper; `helperDecision` is asked ONLY when the root admin prompt is declined
    /// (Try Again / Skip / Cancel). Returns false iff the user cancelled at that prompt — before
    /// anything irreversible ran, with the scheduler flags restored.
    @MainActor
    @discardableResult
    static func run(appState: AppState? = nil,
                    progress: @escaping @MainActor (Stage) -> Void = { _ in },
                    helperDecision: @escaping @MainActor () async -> HelperChoice = { .skip }) async -> Bool {
        Analytics.countUninstall()   // fire-and-forget; the teardown never waits on the network
        appState?.isUninstalling = true   // the home clears its cards + won't re-deal off the defaults wipe

        // Quiet the scheduler FIRST so nothing re-arms a wake while the daemon comes down. The
        // flags are snapshotted so a cancel at the password prompt restores them untouched.
        let d = UserDefaults.standard
        let schedulerFlags = (dev: d.bool(forKey: OvernightScheduler.enabledKey),
                              prod: d.bool(forKey: OvernightScheduler.prodEnabledKey))
        d.removeObject(forKey: OvernightScheduler.enabledKey)
        d.removeObject(forKey: OvernightScheduler.prodEnabledKey)
        appState?.scheduler.needsSchedulerSetup = false
        appState?.scheduler.reevaluate()   // flags gone → stops the loop + cancels the armed wake

        // The root daemon — the ONLY stage that can be declined, so it runs before anything
        // irreversible. One native password prompt tears down the plist, the armed wake, and the
        // root-owned /Library files (WakeHelperInstaller.uninstallAsync, the installer's mirror).
        progress(.helper)
        helperLoop: while !(await WakeHelperInstaller.uninstallAsync()) {
            switch await helperDecision() {
            case .retry:
                continue helperLoop
            case .skip:
                Log("Uninstall: wake helper left in place (admin prompt skipped)")
                break helperLoop
            case .cancel:
                if schedulerFlags.dev { d.set(true, forKey: OvernightScheduler.enabledKey) }
                if schedulerFlags.prod { d.set(true, forKey: OvernightScheduler.prodEnabledKey) }
                appState?.scheduler.reevaluate()
                appState?.isUninstalling = false   // the home re-deals its deck
                Log("Uninstall: cancelled at the admin prompt — nothing removed")
                return false
            }
        }
        await WakeHelperClient.shared.unregister()   // the dev-cockpit SMAppService path, if ever used
        await LoginItem.disable()
        await beat()

        // The cloud copy dies while the Keychain password still exists to authorize the DELETE.
        progress(.cloud)
        try? await MirrorClient.shared.deleteRemote()
        await beat()

        progress(.keychain)
        MirrorClient.destroyKeychainIdentity()
        await beat()

        progress(.knowledge)
        await CycleStore.shared.wipeEverything()     // close out SwiftData cleanly before its files go
        try? FileManager.default.removeItem(at: VaultGenerator.vaultRoot)
        VaultGenerator.sweepOrphanStaging(keeping: nil)
        await beat()

        progress(.model)
        try? FileManager.default.removeItem(at: URL.sentientSupport)   // model + download staging + the store
        await beat()

        progress(.traces)
        Permissions.revokeComputerUseAutomation()
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        for sub in ["Caches/\(bundleID)", "HTTPStorages/\(bundleID)", "WebKit/\(bundleID)",
                    "Saved Application State/\(bundleID).savedState", "Logs/SentientOS"] {
            try? FileManager.default.removeItem(at: library.appendingPathComponent(sub, isDirectory: true))
        }
        // Every setting, flag, and latch at once — LAST, so a live observer can't re-persist a key.
        d.removePersistentDomain(forName: bundleID)
        d.synchronize()
        await beat()

        Log("Uninstall: removed wake helper + cloud copy + keychain identity + knowledge base + model + store + caches + TCC grant + defaults · left the .app, ~/.codex, and gift keepsakes untouched")
        return true
    }

    /// The gone screen's Quit: spawn a detached sweeper for the files the DYING process itself can
    /// resurrect on the way out (cfprefsd re-writing the preferences plist, SwiftData flushing store
    /// files into a recreated support dir, the saved-state write at quit), then hard-exit. The
    /// sweeper outlives us (it reparents to launchd), so the last traces die a beat after we do.
    /// ⚠️ `exit(0)`, NOT `NSApp.terminate`: graceful termination is exactly wrong after a full
    /// wipe — it invites the frameworks to write state back, and SwiftUI's scene teardown can
    /// wedge behind the presented farewell sheet, leaving a zombie app the user can't quit
    /// (field-seen 2026-07-11). There is deliberately nothing left to clean up; just die.
    @MainActor
    static func finishAndQuit() -> Never {
        Log("Uninstall: goodbye — spawning the post-exit sweeper and exiting")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let stragglers = ["\(home)/Library/Application Support/SentientOS",
                          "\(home)/Library/Preferences/\(bundleID).plist",
                          "\(home)/Library/Caches/\(bundleID)",
                          "\(home)/Library/Saved Application State/\(bundleID).savedState"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 2; rm -rf " + stragglers.map { "'\($0)'" }.joined(separator: " ")]
        try? p.run()
        exit(0)
    }

    /// A short breath between stages so each whisper is readable — the work itself is near-instant,
    /// and a label vanishing mid-word reads as a glitch, not a considered teardown.
    private static func beat() async { try? await Task.sleep(for: .milliseconds(500)) }
}
