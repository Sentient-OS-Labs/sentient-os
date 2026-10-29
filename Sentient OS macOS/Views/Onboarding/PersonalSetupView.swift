// Optional personal-context setup lives in its own window, so Home, the notch, and a live
// Sidekick conversation keep their lifetime while connections and permissions are chosen.
import SwiftUI

struct PersonalSetupView: View {
    static let windowID = "personal-setup"
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var problem: String?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Button {
                        dismissWindow(id: Self.windowID)
                        HomeWindowOpening.open()
                    } label: { Label("Back to Home", systemImage: "arrow.left") }
                        .buttonStyle(BackButtonStyle())
                    Spacer()
                    MonoCaps("PERSONAL SETUP", size: 9, tracking: 1.8, color: Theme.faint)
                }
                .padding(.horizontal, 25).padding(.top, 18).padding(.bottom, 10)
                if let problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Theme.Ink.amber)
                        .padding(.horizontal, 30).padding(.bottom, 8)
                        .accessibilityIdentifier("personalSetup.problem")
                }
                OnboardingReadyView(onStart: { timing in
                    guard appState.finishPersonalSetup(timing) else {
                        problem = "Choose three available sources and wait for any current analysis to finish, then try again."
                        return
                    }
                    dismissWindow(id: Self.windowID)
                    if timing == .now { openWindow(id: ProcessingWindowView.windowID) }
                }, isProcessing: appState.processing.isBusy)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: 700, minHeight: 560)
        .background(Theme.bg).preferredColorScheme(.dark)
        .accessibilityIdentifier("personalSetup.window")
        .onAppear {
            guard appState.hasCompletedOnboarding else {
                dismissWindow(id: Self.windowID)
                HomeWindowOpening.open()
                return
            }
            PersonalSetupProgress.begin()
            _ = PersonalSetupProgress.consumeRelaunchResume()
        }
        .allowsHitTesting(appState.hasCompletedOnboarding)
    }
}
