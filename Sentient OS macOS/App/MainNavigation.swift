// In-window navigation, shared by Home, menu commands, notifications, and setup recovery.
// The route is intentionally session-only: each normal launch starts at Home.

import SwiftUI

@MainActor
@Observable
final class MainNavigation {
    static let shared = MainNavigation()

    enum Page: Equatable { case home, settings, knowledge }
    private(set) var page: Page = .home
    private(set) var previousPage: Page?
    var settingsPane: SettingsView.Pane = .sources
    private(set) var hasOpenedKnowledge = false

    /// Only Home exchanges expand/contract from a Home control. Direct secondary-page
    /// routes keep their existing immediate presentation and never invent a source animation.
    var animatesSettingsTransition: Bool {
        (previousPage == .home && page == .settings)
            || (previousPage == .settings && page == .home)
    }

    var animatesKnowledgeTransition: Bool {
        (previousPage == .home && page == .knowledge)
            || (previousPage == .knowledge && page == .home)
    }

    /// Knowledge owns its editor and decides whether Save / Discard / Cancel is needed.
    /// External navigation (Dock, menu bar, notifications) uses the same guard as its Home button.
    @ObservationIgnored var leaveKnowledge: ((@escaping (Bool) -> Void) -> Void)?
    @ObservationIgnored private var resetToken = UUID()

    func show(_ page: Page, settingsPane: SettingsView.Pane? = nil) {
        let token = resetToken
        let proceed = { [self] in
            guard resetToken == token else { return }
            if let settingsPane { self.settingsPane = settingsPane }
            if page == .knowledge { hasOpenedKnowledge = true }
            if self.page != page { previousPage = self.page }
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
        resetToken = UUID()
        leaveKnowledge = nil
        previousPage = nil
        page = .home
        settingsPane = .sources
        hasOpenedKnowledge = false
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
