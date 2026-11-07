// Optional personal-context setup lives in its own window, so Home, the notch, and a live
// Sidekick conversation keep their lifetime while connections and permissions are chosen.
import SwiftUI
import AppKit

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
                        problem = "Choose three sources, finish overnight wake and launch-at-login setup, and wait for any current analysis to finish."
                        return
                    }
                    dismissWindow(id: Self.windowID)
                    openWindow(id: ProcessingWindowView.windowID)
                }, isProcessing: appState.processing.isBusy)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: 700, minHeight: 560)
        .background(Theme.bg).preferredColorScheme(.dark)
        .background(PersonalSetupWindowFit())
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

private struct PersonalSetupWindowFit: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            for name in [NSWindow.didChangeScreenNotification, NSApplication.didChangeScreenParametersNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name,
                    object: name == NSWindow.didChangeScreenNotification ? window : nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fit() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.fit() }
        }
        private func fit() {
            guard let window, !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
            let available = screen.visibleFrame
            let width = min(window.frame.width, available.width)
            let x = min(max(window.frame.minX, available.minX), available.maxX - width)
            let frame = NSRect(x: x, y: available.minY, width: width, height: available.height)
            if window.frame != frame { window.setFrame(frame, display: true) }
        }
        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }
}
