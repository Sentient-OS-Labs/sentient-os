// A reusable analysis window. Closing it only hides progress; the app owns the task.
// Doc: Documentation - Views - Home, Processing & Shared UI.md

import SwiftUI
import AppKit

struct ProcessingWindowView: View {
    static let windowID = "analysis"
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(ProcessingView.resizableDemoKey) private var resizableDemo = false

    var body: some View {
        ProcessingView { dismissWindow(id: Self.windowID) }
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
