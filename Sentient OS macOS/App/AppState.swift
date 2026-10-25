//
//  AppState.swift
//  Sentient OS macOS
//
//  @Observable @MainActor global UI state: onboarding flags + live pipeline
//  status — the single source of truth the SwiftUI window and MenuBarExtra observe.
//  Home admission and personal-setup milestones are persisted separately in UserDefaults.
//

import Foundation
import SwiftUI

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
    @ObservationIgnored private var firstTaskObserver: NSObjectProtocol?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    @ObservationIgnored private var homePreparation: Task<Void, Never>?

    var hasCompletedPersonalSetup: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedPersonalSetup, forKey: PersonalSetupProgress.completedKey)
            if hasCompletedPersonalSetup && !oldValue { Analytics.signal("Onboarding.completed") }
        }
    }
    var hasCompletedFirstSidekickTask: Bool {
        didSet { UserDefaults.standard.set(hasCompletedFirstSidekickTask, forKey: PersonalSetupProgress.firstTaskKey) }
    }

    /// Drops the Dock icon whenever the home window is closed (the icon belongs to home;
    /// the menu bar item is the anchor then).
    private let dockPolicy = DockPolicy()

    /// The Sparkle auto-updater + our OLED forced-update UI. Only ever built in the GUI app (this
    /// whole object is), never the root wake-helper. Its `model` drives UpdateGateView. (Updates/)
    let update = UpdateController()

    static let onboardingKey = PersonalSetupProgress.homeKey
    var hasCompletedOnboarding: Bool {
        didSet {
            if !hasCompletedOnboarding {
                MainNavigation.shared.reset()
                homePreparation?.cancel()
                homePreparation = nil
            }
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.onboardingKey)
            if hasCompletedOnboarding, !oldValue {
                Analytics.signal("Onboarding.homeReached")
                if ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == nil { startAfterHome() }
            }
        }
    }

    init() {
        let isTesting = ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] != nil
        if !isTesting {
            let legacySetup = PersonalSetupProgress.migrate()
            SourceSelection.migrateLegacyFolderDefaults(hadPersonalSetup: legacySetup)
        }
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingKey)
        self.hasCompletedPersonalSetup = PersonalSetupProgress.isComplete()
        self.hasCompletedFirstSidekickTask = UserDefaults.standard.bool(forKey: PersonalSetupProgress.firstTaskKey)
        self.notch = NotchWindowController(coordinator: commandCoordinator)

        SafeAppRelaunch.shared.configure(self)
        if !isTesting, let saved = PermissionRelaunchDraft.take() {
            let conversation = commandCoordinator.run.conversation
            if let generation = conversation.generation, saved.generation == generation,
               conversation.draft.isEmpty, conversation.replyReference == nil {
                conversation.draft = saved.text
                conversation.replyReference = saved.reply
                PermissionRelaunchDraft.clear()
            } else if let generation = conversation.generation, let savedGeneration = saved.generation,
                      generation != savedGeneration {
                // An explicit history reset invalidates old reply references and old drafts.
                PermissionRelaunchDraft.clear()
            }
            // A transient store-open failure leaves the private handoff intact for recovery.
        }
        if !isTesting, let saved = PermissionWaitDraft.read() {
            let conversation = commandCoordinator.run.conversation
            if let generation = conversation.generation, saved.generation == generation,
               conversation.draft.isEmpty, conversation.replyReference == nil {
                conversation.draft = saved.text
                conversation.replyReference = saved.reply
                try? PermissionWaitDraft.clear(matching: saved.runID)
            } else if let generation = conversation.generation, saved.generation != generation {
                try? PermissionWaitDraft.clear(matching: saved.runID)
            }
        }
        firstTaskObserver = NotificationCenter.default.addObserver(forName: PersonalSetupProgress.firstTaskCompleted,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hasCompletedFirstSidekickTask = true }
            }

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
        if hasCompletedOnboarding { startAfterHome() }
        else { scheduler.reevaluate() }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.hasCompletedOnboarding, !self.isUninstalling,
                          self.homePreparation == nil, ModelBackend.current == .claude else { return }
                    self.startAfterHome()
                }
            }
        // The introduction's isolated demo and ordinary post-model Sidekick share the notch.
        startInterfaceIfReady()      // the upgrade must finish before Sidekick or its notch can appear
        dockPolicy.start()           // drop the Dock icon whenever the home window closes
        update.start()               // start Sparkle + one silent launch check (gates a mandatory update)
        UpdateNotice.checkAtLaunch() // version changed since last run → macOS notif + the in-app changelog capsule
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
        // Model files are ordinary app-owned Application Support data. Prepare them during the
        // introduction; neither Home nor Sidekick waits for this resumable background transfer.
        if !hasCompletedOnboarding || !processing.initialComplete {
            Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !isUninstalling, !processing.isSuspended else { return }
                ModelDownload.shared.kickIfNeeded()
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

    /// Home starts monitoring only persisted analysis intent. Scheduling is explicitly chosen
    /// later; entering Home never installs wake, enables login, or requests notification access.
    private func startAfterHome() {
        CodexSetup.shared.startKeepingCurrent { [weak self] in
            self?.commandCoordinator.run.isRunning ?? true
        }
        homePreparation?.cancel()
        homePreparation = Task { [weak self] in
            // Claude Code's login is shared and can change while Sentient is closed. Establish
            // its current local identity before admitting persisted analysis; no model or source
            // content is requested, and Home/Sidekick remain usable during this status check.
            if ModelBackend.current == .claude { _ = await ClaudeAuth.refresh() }
            guard let self, !Task.isCancelled else { return }
            defer { homePreparation = nil }
            guard hasCompletedOnboarding, !isUninstalling, !processing.isSuspended else { return }
            processing.resumeMonitoring()
            scheduler.reevaluate()
        }
    }

    /// Save analysis intent before the milestone, so a crash between writes is recoverable.
    @discardableResult
    func finishPersonalSetup(_ timing: ProcessingCoordinator.Timing) -> Bool {
        guard hasCompletedOnboarding, !isUninstalling, !processing.isBusy, !processing.isSuspended,
              SourceSelection.selectionCount >= SourceSelection.minimumSelections else { return false }
        processing.choose(timing)
        PersonalSetupProgress.finish()
        hasCompletedPersonalSetup = true
        if timing == .overnight { scheduler.enableAfterSetup() }
        processing.resumeMonitoring()
        scheduler.reevaluate()
        return true
    }
}
