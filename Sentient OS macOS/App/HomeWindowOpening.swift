// Opens Home for explicit Dock and menu-bar requests, giving pending computer-use setup priority.
// registerOpener(_:) bridges SwiftUI's scene action; open() restores or creates Home; windowAttached(_:)
// completes a pending creation without letting repeated clicks create duplicate windows.
// Doc: Documentation - App Shell.md

import AppKit

@MainActor
enum HomeWindowOpening {
    private static var createHome: (@MainActor () -> Void)?
    private static var pendingRequest = false
    private static var isCreatingHome = false

    /// The menu-bar label registers even when a silent update launches without any regular scene.
    static func registerOpener(_ action: @escaping @MainActor () -> Void) {
        createHome = action
        if pendingRequest { presentCurrentPage() }
    }

    static func open() {
        MainNavigation.shared.show(.home)
        presentCurrentPage()
    }

    static func open(_ page: MainNavigation.Page, settingsPane: SettingsView.Pane? = nil) {
        MainNavigation.shared.show(page, settingsPane: settingsPane)
        presentCurrentPage()
    }

    /// Bring forward the one main window without replacing a pending deep link or editor prompt.
    static func presentCurrentPage() {
        #if DEBUG
        Log("Home open: setup pending=\(ComputerUseUpgrade.shared.isBlockingInterface)")
        #endif
        guard !ComputerUseUpgrade.shared.isBlockingInterface else {
            pendingRequest = false
            ComputerUseUpgrade.shared.maybePresent()
            return
        }

        if let home = NSApp.windows.first(where: SentientOSApp.isHomeWindow) {
            pendingRequest = false
            isCreatingHome = false
            present(home)
            return
        }

        pendingRequest = true
        guard let createHome, !isCreatingHome else { return }
        isCreatingHome = true
        // Promote BEFORE creating/activating, rather than waiting for DockPolicy's key notification.
        NSApp.setActivationPolicy(.regular)
        createHome()
        NSApp.activate()
    }

    static func windowAttached(_ window: NSWindow) {
        guard SentientOSApp.isHomeWindow(window) else { return }
        isCreatingHome = false
        guard pendingRequest else { return }
        pendingRequest = false
        // Let SwiftUI finish attaching its content before asking the new window to take focus.
        Task { @MainActor [weak window] in
            guard let window, NSApp.windows.contains(where: { $0 === window }),
                  !ComputerUseUpgrade.shared.isBlockingInterface else { return }
            present(window)
        }
    }

    private static func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }
}
