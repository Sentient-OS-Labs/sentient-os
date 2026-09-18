// Keeps regular app scenes empty and hidden until the computer-use upgrade finishes.
// WindowAttachment registers each NSWindow before display; the upgrade coordinator owns
// reopening it. Doc: Documentation - Permission Gate & Guide.md

import AppKit
import SwiftUI

struct ComputerUseWindowGuard: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        Group {
            if ComputerUseUpgrade.shared.isBlockingInterface {
                Color.clear
            } else {
                content
            }
        }
        .background(WindowAttachment {
            openWindow(id: SentientOSApp.homeWindowID)
        })
    }

    private struct WindowAttachment: NSViewRepresentable {
        let openHome: @MainActor () -> Void

        func makeNSView(context: Context) -> AttachmentView {
            let view = AttachmentView()
            view.openHome = openHome
            return view
        }

        func updateNSView(_ nsView: AttachmentView, context: Context) {
            nsView.openHome = openHome
            nsView.registerWindow()
        }

        final class AttachmentView: NSView {
            var openHome: (@MainActor () -> Void)?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                registerWindow()
            }

            func registerWindow() {
                guard let window, let openHome else { return }
                ComputerUseUpgrade.shared.register(window: window, openHome: openHome)
            }
        }
    }
}
