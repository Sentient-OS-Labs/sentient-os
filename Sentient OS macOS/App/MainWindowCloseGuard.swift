// Preserve Knowledge's unsaved-edits prompt for the red close button and ⌘W, while forwarding
// all other delegate behavior to SwiftUI's window delegate (restoration, sizing, and lifecycle).

import AppKit
import SwiftUI

struct MainWindowCloseGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> AttachmentView { AttachmentView() }
    func updateNSView(_ view: AttachmentView, context: Context) { view.attach() }
    static func dismantleNSView(_ view: AttachmentView, coordinator: ()) { view.detach() }

    final class AttachmentView: NSView {
        private var proxy: CloseDelegate?
        private weak var attachedWindow: NSWindow?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== attachedWindow { detach() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            guard let window, !(window.delegate is CloseDelegate) else { return }
            let delegate = CloseDelegate(original: window.delegate)
            attachedWindow = window
            proxy = delegate
            window.delegate = delegate
        }

        func detach() {
            if let attachedWindow, attachedWindow.delegate === proxy {
                attachedWindow.delegate = proxy?.original
            }
            attachedWindow = nil
            proxy = nil
        }
    }

    final class CloseDelegate: NSObject, NSWindowDelegate {
        fileprivate weak var original: NSWindowDelegate?

        init(original: NSWindowDelegate?) { self.original = original }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? { original }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let navigation = MainNavigation.shared
            guard navigation.page == .knowledge, let leave = navigation.leaveKnowledge else {
                return original?.windowShouldClose?(sender) ?? true
            }
            leave { [weak self, weak sender] approved in
                guard approved, let sender,
                      self?.original?.windowShouldClose?(sender) != false else { return }
                sender.close()
            }
            return false
        }
    }
}
