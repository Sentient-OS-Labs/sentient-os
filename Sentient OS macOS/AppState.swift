//
//  AppState.swift
//  Sentient OS macOS
//
//  @Observable @MainActor global UI state (Arch §2.3): onboarding flags + live pipeline
//  status — the single source of truth the SwiftUI window and MenuBarExtra observe.
//  Only the onboarding flag is persisted (UserDefaults); everything else is live runtime state.
//

import Foundation
import SwiftUI

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

    private static let onboardingKey = "hasCompletedOnboarding"
    var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.onboardingKey) }
    }

    init() {
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingKey)
        self.notch = NotchWindowController(coordinator: commandCoordinator)
        scheduler.reevaluate()   // arm if the dev setting was left on; otherwise a no-op
        commandCoordinator.start()   // arm right-⌘ hold-to-talk + warm the speech model
        notch.start()                // raise the notch overlay window
    }
}
