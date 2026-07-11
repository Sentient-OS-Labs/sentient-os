//
//  MenuBarView.swift
//  Sentient OS macOS
//
//  Glanceable status in the macOS menu bar. A stub today (Open + status line + Quit) — the richer
//  dropdown ("412 / 3,000 · paused (in use)") is still to build.
//

import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Sentient OS") { openHome() }

        Divider()
        switch appState.status {
        case .idle:                            Text("Sentient OS · idle")
        case .processing(let done, let total): Text("Processing \(done) / \(total)")
        case .paused(let reason):              Text("Paused · \(reason)")
        case .error(let message):              Text("Error · \(message)")
        }

        Divider()
        Button("Check for Updates…") { appState.update.checkForUpdatesNow() }
        Text("Version \(UpdateController.currentVersionString)")

        Divider()
        Button("Quit Sentient OS") { NSApplication.shared.terminate(nil) }
    }

    /// Bring the proactive home window to the front — focus it if it's open, otherwise reopen it
    /// (a red-button close destroys the WindowGroup's window, so it must be recreated).
    @MainActor private func openHome() {
        // We may be .accessory (Dock icon hidden because no window is up). Restore .regular BEFORE
        // opening/activating so the window takes focus and the Dock icon reappears cleanly — the
        // DockPolicy observer would do it on didBecomeKey, but that lands too late for activate().
        NSApp.setActivationPolicy(.regular)
        if let home = NSApp.windows.first(where: { SentientOSApp.isHomeWindow($0) }) {
            home.makeKeyAndOrderFront(nil)
            home.orderFrontRegardless()
        } else {
            openWindow(id: SentientOSApp.homeWindowID)
        }
        NSApp.activate()
    }
}
