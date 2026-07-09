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

    /// The in-app scheduler — only ever runs while the app is alive (DEV TOOLS "Scheduled run").
    let scheduler = OvernightScheduler()

    /// The "do this for me" brain: the right-⌘ hold-to-talk hotkey + voice + the one shared codex run
    /// + the notch's status phase. Both the home command bar and the hotkey drive this. (Notch Magic/)
    let commandCoordinator = CommandCoordinator()

    /// The notch overlay window — renders the coordinator's status phase as the living notch.
    private let notch: NotchWindowController

    /// The Sparkle auto-updater + our OLED forced-update UI. Only ever built in the GUI app (this
    /// whole object is), never the root wake-helper. Its `model` drives UpdateGateView. (Updates/)
    let update = UpdateController()

    private static let onboardingKey = "hasCompletedOnboarding"
    var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.onboardingKey)
            if hasCompletedOnboarding, !oldValue { Analytics.signal("Onboarding.completed") }
        }
    }

    init() {
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingKey)
        self.notch = NotchWindowController(coordinator: commandCoordinator)
        scheduler.reevaluate()   // arm if the dev setting was left on; otherwise a no-op
        scheduler.maybeAutoEnable()   // 18h after initial: flip the overnight scheduler on (or arm the timer)
        if CodexAuth.knowledgeBaseOnly {
            // Free/go knowledge-base-only mode: Sidekick runs computer use through codex, and
            // that quota doesn't exist on these plans — the hotkey never arms.
            Log("Sidekick: knowledge-base-only plan — hotkey not armed")
        } else {
            commandCoordinator.start()   // arm right-⌘ hold-to-talk + warm the speech model
        }
        notch.start()                // raise the notch overlay window
        update.start()               // start Sparkle + one silent launch check (gates a mandatory update)

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

        // First launch (onboarding not yet completed): kick off the codex CLI install silently in
        // the background, 1s after launch, while the user reads the intro slides. A USED codex
        // setup on this Mac (~/.codex/auth.json or config.toml — codex writes those once it's
        // actually run) means never auto-install over it. The bare ~/.codex folder is NOT proof:
        // an install interrupted mid-download (the FDA relaunch) leaves one behind, and skipping
        // on it would strand onboarding without codex. installCodex() additionally no-ops when
        // the binary is found, so a quit-and-relaunch mid-onboarding just re-checks. Login +
        // computer-use stay interactive, later in the flow.
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
                // OpenAI's installer fails transiently (its GitHub-JSON parsing flaps per
                // request), so one attempt isn't enough: retry with a 10s gap while the user is
                // still on the slides/perms. A retried flap usually succeeds on the next try.
                for attempt in 1...4 {
                    await CodexSetup.shared.installCodex()
                    if CodexSetup.shared.installed { return }
                    Log("Onboarding: codex install attempt \(attempt) failed — retrying in 10s")
                    try? await Task.sleep(for: .seconds(10))
                }
                Log("Onboarding: codex install still failing after 4 attempts — the login screen's re-kick is the remaining net")
            }
        }
    }
}
