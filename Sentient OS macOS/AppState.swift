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

    private static let onboardingKey = "hasCompletedOnboarding"
    var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.onboardingKey) }
    }

    init() {
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingKey)
    }
}
