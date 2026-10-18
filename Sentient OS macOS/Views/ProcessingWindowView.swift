// A reusable analysis window. Closing it only hides progress; the app owns the task.
// Doc: Documentation - Views - Home, Processing & Shared UI.md

import SwiftUI
import AppKit

struct ProcessingWindowView: View {
    static let windowID = "analysis"
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(ProcessingView.resizableDemoKey) private var resizableDemo = false

    var body: some View {
        ProcessingView { dismissWindow(id: Self.windowID) }
            .frame(minWidth: resizableDemo ? 1 : 640, minHeight: resizableDemo ? 1 : 650)
            .background(ProcessingWindowFocus(appState: appState))
    }
}

/// The onboarding choice opens progress visibly while leaving Home's composer ready to type.
/// Later explicit View progress requests focus the analysis window normally.
private struct ProcessingWindowFocus: NSViewRepresentable {
    let appState: AppState
    func makeNSView(context: Context) -> FocusView { FocusView(appState: appState) }
    func updateNSView(_ view: FocusView, context: Context) { view.restoreHomeIfNeeded() }

    final class FocusView: NSView {
        let appState: AppState
        private var keyObserver: NSObjectProtocol?
        init(appState: AppState) { self.appState = appState; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        deinit { if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) } }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            keyObserver = nil
            if let window {
                keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                    object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.restoreHomeIfNeeded() }
                    }
            }
            restoreHomeIfNeeded()
        }
        func restoreHomeIfNeeded() {
            guard window?.isKeyWindow == true, appState.returnHomeAfterOpeningAnalysis else { return }
            appState.returnHomeAfterOpeningAnalysis = false
            DispatchQueue.main.async { HomeWindowOpening.open() }
        }
    }
}
