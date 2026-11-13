// Native shell for ephemeral reading windows. Content owns its copy,
// retry and permission actions; the window owns focus, stable sizing and keyboard dismissal.
// Doc: Documentation - Views - Home, Processing & Shared UI.md
import AppKit
import SwiftUI

@MainActor final class ReadingPanel: NSPanel {
    var onDismiss: (() -> Void)?
    init(title: String, identifier: String, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        isRestorable = false
        self.title = title; titleVisibility = .hidden; titlebarAppearsTransparent = true
        isReleasedWhenClosed = false; hidesOnDeactivate = false; isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false; isMovableByWindowBackground = true
        level = .floating; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false; backgroundColor = .clear
        appearance = NSAppearance(named: .darkAqua)
        contentMinSize = NSSize(width: 360, height: 260)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(button)?.isHidden = true }
    }
    func install<Content: View>(_ view: Content) {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        // Window geometry must remain independent of a native text document's height.
        host.sizingOptions = []; host.wantsLayer = true; host.autoresizingMask = [.width, .height]
        contentView = host
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 || (event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && event.charactersIgnoringModifiers == "w") {
            onDismiss?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
