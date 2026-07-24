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

    /// High-level what's-happening-right-now, surfaced in the window + menu bar.
    enum Status: Equatable {
        case idle
        case processing(done: Int, total: Int)
        case paused(reason: String)
        case error(String)
    }

    var status: Status = .idle

    /// True while Uninstall.run is tearing the app down (flipped back only by a cancel). The
    /// home reads it to keep the deck empty: the teardown's defaults wipe re-publishes every
    /// @AppStorage (including the card deck's), and without this gate the home re-deals a
    /// fresh deck mid-teardown. In-memory on purpose — a persisted key would pollute the wipe.
    var isUninstalling = false

    /// The in-app scheduler — only ever runs while the app is alive (DEV TOOLS "Scheduled run").
    let scheduler = OvernightScheduler()

    /// The "do this for me" brain: the right-⌘ hold-to-talk hotkey + voice + the one shared codex run
    /// + the notch's status phase. Both the home command bar and the hotkey drive this. (Notch Magic/)
    let commandCoordinator = CommandCoordinator()

    /// The notch overlay window — renders the coordinator's status phase as the living notch.
    private let notch: NotchWindowController

    /// Drops the Dock icon whenever the home window is closed (the icon belongs to home;
    /// the menu bar item is the anchor then).
    private let dockPolicy = DockPolicy()

    /// The Sparkle auto-updater + our OLED forced-update UI. Only ever built in the GUI app (this
    /// whole object is), never the root wake-helper. Its `model` drives UpdateGateView. (Updates/)
    let update = UpdateController()

    static let onboardingKey = "hasCompletedOnboarding"   // FactoryReset clears it (the rewind)
    var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.onboardingKey)
            if hasCompletedOnboarding, !oldValue { Analytics.signal("Onboarding.completed") }
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

        scheduler.reevaluate()   // arm if the dev setting was left on; otherwise a no-op
        scheduler.maybeAutoEnable()   // 14h after initial: flip the overnight scheduler on (or arm the timer)
        // Always armed — knowledge-base-only (free/go) gating happens live at submit() inside
        // the coordinator: the notch experience still plays, the codex run just never fires.
        commandCoordinator.start()   // arm right-⌘ hold-to-talk + warm the speech model
        notch.start()                // raise the notch overlay window
        dockPolicy.start()           // drop the Dock icon whenever the home window closes
        update.start()               // start Sparkle + one silent launch check (gates a mandatory update)
        UpdateNotice.checkAtLaunch() // version changed since last run → macOS notif + the in-app changelog capsule
        // A silent auto-update relaunch opens no window, so DockPolicy's open/close notifications
        // never fire — evaluate once (next runloop tick, after launch settles) so the Dock icon
        // drops to match the windowless launch instead of lingering with nothing behind it.
        if UpdateNotice.suppressHomeThisLaunch {
            Task { dockPolicy.reevaluate() }
        }

        // Notifications, banked silently: PROVISIONAL authorization shows NO prompt — macOS just
        // grants quiet Notification Center delivery and lists us in Settings → Notifications (the
        // user sees at most the passive "Sentient OS can send you notifications" notice). Asked
        // lazily after onboarding so that notice never lands mid-flow; the explicit alerts
        // upgrade stays in Settings → Health's "Allow…". Only fires while status is untouched —
        // a real Allow/Deny is never overridden.
        if hasCompletedOnboarding {
            Task {
                let center = UNUserNotificationCenter.current()
                let status = await center.notificationSettings().authorizationStatus
                let names = ["notDetermined", "denied", "authorized", "provisional", "ephemeral"]
                let label = names.indices.contains(status.rawValue) ? names[status.rawValue] : "\(status.rawValue)"
                Log("Notifications: launch status = \(label)")
                if status == .notDetermined {
                    _ = try? await center.requestAuthorization(options: [.provisional])
                    Log("Notifications: banked provisional (quiet) authorization")
                }
            }
        }

        // Onboarding model download: the on-device model (3.66 GB) starts pulling 2s after the
        // launch that follows the Full Disk Access grant — FDA is the one onboarding step that
        // forces a relaunch, and it lands minutes before Start Analysis needs the model, so the
        // downloading screen usually only covers the tail. Strictly an onboarding affair, and a
        // no-op whenever ModelLocator already finds a model (dev checkouts, a finished download).
        // A quit-and-relaunch mid-download resumes from the finished byte ranges, not from zero.
        if !hasCompletedOnboarding {
            Task {
                try? await Task.sleep(for: .seconds(2))
                if Permissions.hasFullDiskAccess() {
                    ModelDownload.shared.kickIfNeeded()
                }
            }
        }

        // First launch (onboarding not yet completed): kick off the codex CLI install silently in
        // the background, 1s after launch, while the user reads the intro slides. A USED codex
        // setup on this Mac (~/.codex/auth.json or config.toml — codex writes those once it's
        // actually run) means never auto-install over it at launch — those setups get their CLI
        // update from the onboarding codex screen's kick instead (the installer doubles as the
        // updater). The bare ~/.codex folder is NOT proof: an install interrupted mid-download
        // (the FDA relaunch) leaves one behind, and skipping on it would strand onboarding
        // without codex. A quit-and-relaunch mid-onboarding re-runs the installer, which is safe
        // (update in place). Login + computer-use stay interactive, later in the flow.
        if !hasCompletedOnboarding {
            Task {
                try? await Task.sleep(for: .seconds(1))
                let fm = FileManager.default
                let codexDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
                if fm.fileExists(atPath: codexDir.appendingPathComponent("auth.json").path)
                    || fm.fileExists(atPath: codexDir.appendingPathComponent("config.toml").path) {
                    Log("Onboarding: ~/.codex is a real setup — skipping the background codex install")
                    return
                }
                // OpenAI's installer fails transiently (its GitHub-JSON parsing flaps per request),
                // so one attempt isn't enough. The retry policy + the give-up flag live in
                // CodexSetup.ensureInstalled — ONE source of truth the onboarding screen drives too;
                // a give-up surfaces the "install it yourself" panel on the codex screen.
                await CodexSetup.shared.ensureInstalled()
            }
        }
    }
}
