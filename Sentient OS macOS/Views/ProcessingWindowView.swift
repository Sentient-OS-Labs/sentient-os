// A reusable analysis window. Closing it only hides progress; the app owns the task.
// Doc: Documentation - Views - Home, Processing & Shared UI.md

import SwiftUI
import AppKit

struct ProcessingWindowView: View {
    static let windowID = "analysis"
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(ProcessingView.resizableDemoKey) private var resizableDemo = false

    var body: some View {
        Group {
            if !appState.hasCompletedPersonalSetup && !appState.processing.initialComplete
                && appState.processing.record.status == .idle && !resizableDemo {
                VStack(spacing: 22) {
                    Text("Make Sentient personal").display(26)
                    Text("Choose three sources before your first analysis. You can keep using Sidekick while you set up.")
                        .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 440)
                    GlowButton(title: "Finish setup", systemImage: "arrow.right") {
                        openWindow(id: PersonalSetupView.windowID)
                        dismissWindow(id: Self.windowID)
                    }.frame(width: 230)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            } else {
                ProcessingView { dismissWindow(id: Self.windowID) }
            }
        }
            .frame(minWidth: resizableDemo ? 1 : 640, minHeight: resizableDemo ? 1 : 650)
            .background(ProcessingWindowFocus())
    }
}

/// An explicitly opened progress window takes focus after SwiftUI finishes attaching it.
private struct ProcessingWindowFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusView { FocusView() }
    func updateNSView(_ view: FocusView, context: Context) {}

    final class FocusView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let window, self?.window === window,
                      !ComputerUseUpgrade.shared.isBlockingInterface else { return }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
