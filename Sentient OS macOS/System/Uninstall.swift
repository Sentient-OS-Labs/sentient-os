//
//  Uninstall.swift
//  Sentient OS macOS  ·  System/
//
//  The one full teardown — FactoryReset's strict superset, driven by Settings → System →
//  Uninstall Sentient (UninstallView). Removes Sentient's active installation data:
//  the root wake helper (+ its /Library files), the cloud mirror copy AND the Keychain identity,
//  the knowledge base, the on-device model + the cua driver (both under the swept SentientOS
//  root), the cycle store, the login item, the legacy 1.x Automation TCC row, caches, and the
//  whole defaults domain. Every step is best-effort and idempotent, so a crash or relaunch
//  mid-way just re-runs cleanly (post-wipe the app lands in onboarding).
//
//  Deliberately NOT touched: the .app bundle itself (the gone screen asks the user to drag it to
//  the Trash — decided 2026-07-10), ALL of ~/.codex (config.toml, any 1.x-era computer-use
//  payload, and the user's own codex login stay), the retired Bundled Codex directory (older
//  releases may have made it the backing store for a standalone login), the Desktop gift keepsakes, and the
//  SIP-protected system TCC rows. A destructive sequence must never drift — change it HERE only.
//
//  Key members: Stage (the sheet's whisper per step) · run(appState:progress:helperDecision:)
//  (the teardown) · finishAndQuit() (the gone screen's Quit + post-exit sweeper).
//

import Foundation
import AppKit
import Darwin

enum Uninstall {
    static var lastFailure: String?

    /// The user-facing teardown stages, in run order — the farewell sheet renders each `whisper`
    /// (the mono-caps voice) while its stage runs. The helper goes FIRST: it's the only stage that
    /// can ask for the user's password (and be declined), so a cancel there aborts the uninstall
    /// before anything irreversible has happened.
    enum Stage: CaseIterable {
        case helper, cloud, keychain, knowledge, model, traces
        var whisper: String {
            switch self {
            case .helper:    return "STANDING DOWN THE WAKE HELPER"
            case .cloud:     return "REMOVING THE CLOUD COPY"
            case .keychain:  return "CLEARING YOUR KEYCHAIN KEY"
            case .knowledge: return "ERASING YOUR KNOWLEDGE BASE"
            case .model:     return "REMOVING THE ON-DEVICE MODEL"
            case .traces:    return "SWEEPING THE LAST TRACES"
            }
        }
    }

    /// The sheet's answer when the helper's admin prompt is declined.
    enum HelperChoice { case retry, skip, cancel }

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "jesai.Sentient-OS-macOS" }

    /// The full teardown. `progress` fires on the main actor before each stage so the sheet can
    /// render its whisper; `helperDecision` is asked ONLY when the root admin prompt is declined
    /// (Try Again / Skip / Cancel). Returns false on cancellation or an incomplete Keychain
    /// cleanup. `lastFailure` distinguishes partial cleanup from a canceled admin prompt.
    @MainActor
    @discardableResult
    static func run(appState: AppState? = nil,
                    progress: @escaping @MainActor (Stage) -> Void = { _ in },
                    helperDecision: @escaping @MainActor () async -> HelperChoice = { .skip }) async -> Bool {
        lastFailure = nil
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

        // Request knowledge-mirror deletion while its credential remains. Contact records are
        // retained remotely; only their local snapshot and credentials are removed.
        progress(.cloud)
        await HostedConnectorSetup.beginTeardown()
        defer { HostedConnectorSetup.endTeardown() }
        do {
            try await MailAccountCloud.shared.forgetLocalState()
            try await MailAccountCloud.onboarding.forgetLocalState()
        }
        catch {
            Diagnostics.report(.cleanupFailed, phase: .uninstall, reason: "contact_credentials", error: error)
            lastFailure = "Uninstall paused because local contact credentials couldn't be removed. Unlock your Mac and retry."
            appState?.isUninstalling = false
            return false
        }
        try? await MirrorClient.shared.deleteRemote()
        await beat()

        progress(.keychain)
        guard DoubleTapProvider.destroyKeys() else {
            lastFailure = "Uninstall paused because your Double Tap API keys couldn't be removed from Keychain. Unlock your Mac and retry."
            appState?.isUninstalling = false
            return false
        }
        do { try await DirectMCPConnections.shared.removeAll() }
        catch {
            Diagnostics.report(.cleanupFailed, phase: .uninstall, reason: "connector_credentials", error: error)
            Log("Uninstall: direct-connection Keychain cleanup needs retry")
            lastFailure = "Uninstall paused because saved app connections couldn't be removed from Keychain. Unlock your Mac and retry to finish removing Sentient."
            appState?.isUninstalling = false
            return false
        }
        MirrorClient.destroyKeychainIdentity()
        CustomProvider.destroy()   // the frontier-model choice + its endpoint API key
        ClaudeAuth.destroy()       // OUR cached Claude identity only — ~/.claude, the Keychain
                                   // login, and the claude binary are the user's own Claude
                                   // Code and stay untouched (the same posture as ~/.codex)
        await beat()

        progress(.knowledge)
        await CycleStore.shared.wipeEverything()     // close out SwiftData cleanly before its files go
        Diagnostics.removeForCleanup(VaultGenerator.vaultRoot, phase: .uninstall, reason: "vault")
        VaultGenerator.sweepOrphanStaging(keeping: nil)
        await beat()

        progress(.model)
        await CodexSetup.shared.cancelInstallation()
        await ComputerUseSetup.cancelAll()
        await CuaDriverHost.shared.stop()
        do {
            let lease = FileManager.default.fileExists(atPath: CodexRuntime.root.path)
                ? try CodexRuntime.FileLock(CodexRuntime.root.appendingPathComponent(".runtime.lock"), exclusive: true) : nil
            defer { lease?.unlock() }
            try await OpenAIComputerUse.stopOwnedHelper()
            try removeSupportFiles(at: URL.sentientSupport)
        } catch {
            Diagnostics.report(.cleanupFailed, phase: .uninstall, reason: "runtime", error: error)
            lastFailure = "Uninstall paused because Sentient's runtime is still in use or couldn't be removed. Finish active tasks and retry."
            appState?.isUninstalling = false
            return false
        }
        await beat()

        progress(.traces)
        await Permissions.resetAutomationForUninstall()
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        for sub in ["Caches/\(bundleID)", "HTTPStorages/\(bundleID)", "WebKit/\(bundleID)",
                    "Saved Application State/\(bundleID).savedState", "Logs/SentientOS"] {
            Diagnostics.removeForCleanup(library.appendingPathComponent(sub, isDirectory: true), phase: .uninstall, reason: "app_cache")
        }
        // Every setting, flag, and latch at once — LAST, so a live observer can't re-persist a key.
        d.removePersistentDomain(forName: bundleID)
        d.synchronize()
        await beat()

        Log("Uninstall: cleanup attempts finished; individual failures are reported")
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
        let stragglers = ["\(home)/Library/Preferences/\(bundleID).plist",
                          "\(home)/Library/Caches/\(bundleID)",
                          "\(home)/Library/Saved Application State/\(bundleID).savedState"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 2\n" + postExitCleanupScript, "sentient-uninstall",
                       URL.sentientSupport.path, retiredRuntimeDirectoryName] + stragglers
        try? p.run()
        exit(0)
    }

    // Preserve this entire retired subtree without opening it or checking a standalone home.
    // Its old auth.json may still back a compatibility link created by a previous release.
    static let retiredRuntimeDirectoryName = "Bundled Codex"

    static func removeSupportFiles(at support: URL) throws {
        var info = stat()
        guard lstat(support.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
        }
        let fm = FileManager.default
        for child in try fm.contentsOfDirectory(at: support, includingPropertiesForKeys: [], options: []) {
            guard child.lastPathComponent != retiredRuntimeDirectoryName else { continue }
            try fm.removeItem(at: child)
        }
        // rmdir cannot descend into or remove preserved data, including files recreated during exit.
        if rmdir(support.path) != 0, errno != ENOTEMPTY, errno != EEXIST, errno != ENOENT {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Paths are positional arguments, never shell source. Skip the retired name before even
    /// checking its file type; an old shared credential must survive both cleanup passes.
    static let postExitCleanupScript = #"""
    support=$1
    retired=$2
    shift 2
    if [ -L "$support" ]; then exit 1; fi
    if [ -d "$support" ]; then
        for entry in "$support"/* "$support"/.[!.]* "$support"/..?*; do
            [ "${entry##*/}" = "$retired" ] && continue
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            rm -rf -- "$entry"
        done
        rmdir "$support" 2>/dev/null || :
    fi
    for entry in "$@"; do
        rm -rf -- "$entry"
    done
    """#

    /// A short breath between stages so each whisper is readable — the work itself is near-instant,
    /// and a label vanishing mid-word reads as a glitch, not a considered teardown.
    private static func beat() async { try? await Task.sleep(for: .milliseconds(500)) }
}
