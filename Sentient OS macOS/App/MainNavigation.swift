// In-window navigation, shared by Home, menu commands, notifications, and setup recovery.
// The route is intentionally session-only: each normal launch starts at Home.

import SwiftUI

@MainActor
@Observable
final class MainNavigation {
    static let shared = MainNavigation()

    enum Page: Equatable { case home, settings, knowledge }
    private(set) var page: Page = .home
    var settingsPane: SettingsView.Pane = .sources
    private(set) var hasOpenedKnowledge = false

    /// Knowledge owns its editor and decides whether Save / Discard / Cancel is needed.
    /// External navigation (Dock, menu bar, notifications) uses the same guard as its Home button.
    @ObservationIgnored var leaveKnowledge: ((@escaping (Bool) -> Void) -> Void)?

    func show(_ page: Page, settingsPane: SettingsView.Pane? = nil) {
        let proceed = { [self] in
            if let settingsPane { self.settingsPane = settingsPane }
            if page == .knowledge { hasOpenedKnowledge = true }
            self.page = page
        }
        if self.page == .knowledge, page != .knowledge, let leaveKnowledge {
            leaveKnowledge { approved in if approved { proceed() } }
        } else {
            proceed()
        }
    }

    func confirmLeavingKnowledge(_ completion: @escaping (Bool) -> Void) {
        if page == .knowledge, let leaveKnowledge { leaveKnowledge(completion) }
        else { completion(true) }
    }

    func reset() {
        leaveKnowledge = nil
        page = .home
        settingsPane = .sources
        hasOpenedKnowledge = false
    }

    /// Keep a notification's destination if one arrived during onboarding.
    func finishOnboarding() {
        if page == .home { show(.knowledge) }
    }
}

/// The same prominent way home on every secondary page.
struct HomeNavigationButton: View {
    var action: () -> Void = { HomeWindowOpening.open() }

    var body: some View {
        Button(action: action) {
            Label("Home", systemImage: "arrow.left")
        }
        .buttonStyle(BackButtonStyle())
        .help("Return to Home")
        .accessibilityIdentifier("navigation.home")
    }
}
