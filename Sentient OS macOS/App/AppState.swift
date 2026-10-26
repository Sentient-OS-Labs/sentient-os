//
//  AppState.swift
//  Sentient OS macOS
//
//  @Observable @MainActor global UI state: onboarding flags + live pipeline
//  status — the single source of truth the SwiftUI window and MenuBarExtra observe.
//  Only the onboarding flag is persisted (UserDefaults); everything else is live runtime state.
//

import Foundation
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class AppState {

    /// True while Uninstall.run is tearing the app down (flipped back only by a cancel). The
    /// home reads it to keep the deck empty: the teardown's defaults wipe re-publishes every
    /// @AppStorage (including the card deck's), and without this gate the home re-deals a
    /// fresh deck mid-teardown. In-memory on purpose — a persisted key would pollute the wipe.
    var isUninstalling = false

    /// Offer the missing ChatGPT login once per launch; the home action can always reopen it.
    var hasOfferedCodexSignIn = false

    /// One analysis owner and one overnight clock, independent of the app's windows.
    let processing = ProcessingCoordinator.shared
    let scheduler = OvernightScheduler()

    /// The "do this for me" brain: the right-⌘ tap-to-type hotkey (two taps → a reply draft) + the
    /// notch's mic + the one shared codex run + the notch's status phase. Both the home command bar
    /// and the hotkey drive this. (Notch Magic/)
    let commandCoordinator = CommandCoordinator()
    let sidekickPresentation = SidekickPresentation()

    /// The notch overlay window — renders the coordinator's status phase as the living notch.
    private let notch: NotchWindowController
    private var hasStartedInterface = false

    /// Drops the Dock icon whenever the home window is closed (the icon belongs to home;
    /// the menu bar item is the anchor then).
    private let dockPolicy = DockPolicy()

    /// The Sparkle auto-updater + our OLED forced-update UI. Only ever built in the GUI app (this
    /// whole object is), never the root wake-helper. Its `model` drives UpdateGateView. (Updates/)
    let update = UpdateController()

    static let onboardingKey = "hasCompletedOnboarding"   // FactoryReset clears it (the rewind)
    var hasCompletedOnboarding: Bool {
        didSet {
            if !hasCompletedOnboarding { MainNavigation.shared.reset() }
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.onboardingKey)
            if hasCompletedOnboarding, !oldValue {
                Analytics.signal("Onboarding.completed")
                if ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == nil { startAfterSetup() }
            }
        }
    }

    init() {
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingKey)
        self.notch = NotchWindowController(coordinator: commandCoordinator)

        // Headless self-tests (SENTIENT_SELFTEST) boot this whole app shell before exiting, and
        // they share the real UserDefaults — so NONE of the launch side effects may fire. Field
        // lesson (2026-07-10): a self-test instance running from a CLI build let the scheduler's
        // DEBUG helper self-install re-home the ROOT wake daemon onto the temp binary, behind a
        // very real admin-password dialog. Same convention as Notify.swift's self-test silence.
        guard ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == nil else { return }

        Task { await MailAccountCloud.shared.retryPendingSync() }
        Task { await MailAccountCloud.onboarding.retryPendingSync() }

        CuaDriver.rememberExistingInstallation()
        ComputerUseUpgrade.shared.prepareForLaunch { [weak self] in
            self?.startInterfaceIfReady()
        }
        // Every model uses Codex and the native helper for computer tasks. Begin their shared
        // background setup before model selection; login and permission grants remain separate.
        // Register the installation now so Settings, first use and Uninstall share its lifetime.
        ComputerUseSetup.current.prepareForLaunch()
        scheduler.reevaluate()   // arm if the dev setting was left on; otherwise a no-op
        if hasCompletedOnboarding { startAfterSetup() }
        // Always armed — knowledge-base-only (free/go) gating happens live at submit() inside
        // the coordinator: the notch experience still plays, the codex run just never fires.
        startInterfaceIfReady()      // the upgrade must finish before Sidekick or its notch can appear
        dockPolicy.start()           // drop the Dock icon whenever the home window closes
        update.start()               // start Sparkle + one silent launch check (gates a mandatory update)
        UpdateNotice.checkAtLaunch() // version changed since last run → macOS notif + the in-app changelog capsule
        LifetimeUpgradeAnnouncement.shared.start()
        // Diagnostics baseline for the session (structure only, see CodexDiagnostics.swift): start
        // the network monitor now so a codex failure right after a wake never reads "unknown", and
        // leave one breadcrumb saying what codex's login looks like at launch.
        Task.detached(priority: .utility) {
            NetworkSnapshot.shared.start()
            Log(CodexAuthSnapshot.read().logLine)
            // Reap computer-use daemons leaked by previous app lives — a daemon that missed the
            // lifeline EOF would otherwise hold its screen-capture stream (and CPU) forever.
            await CuaDriverHost.sweepOrphans()
        }
        // Onboarding model download: the on-device model (3.66 GB) starts pulling 2s after the
        // launch that follows the Full Disk Access grant — FDA is the one onboarding step that
        // forces a relaunch, and it lands minutes before Start Analysis needs the model, so the
        // downloading screen usually only covers the tail. Strictly an onboarding affair, and a
        // no-op whenever ModelLocator already finds a model (dev checkouts, a finished download).
        // A quit-and-relaunch mid-download resumes from the finished byte ranges, not from zero.
        if !hasCompletedOnboarding || !processing.initialComplete {
            Task {
                try? await Task.sleep(for: .seconds(2))
                if Permissions.hasFullDiskAccess() {
                    ModelDownload.shared.kickIfNeeded()
                }
            }
        }

        // Claude Code remains an engine-specific install, prepared when the user selects Claude.
        // Shared Codex/native setup above reuses compatible installations without signing in.
    }

    private func startInterfaceIfReady() {
        guard !hasStartedInterface, !ComputerUseUpgrade.shared.isBlockingInterface else { return }
        hasStartedInterface = true
        commandCoordinator.start()
        notch.start()
    }

    /// Start the analysis monitor, overnight clock, idle-only CLI updates and quiet notification
    /// permission on the first Home visit as well as subsequent launches.
    private func startAfterSetup() {
        processing.resumeMonitoring()
        scheduler.enableAfterSetup()
        CodexSetup.shared.startKeepingCurrent { [weak self] in
            self?.commandCoordinator.run.isRunning ?? true
        }
        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.provisional])
            }
        }
    }
}
