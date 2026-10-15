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
        Button("Check for Updates…") {
            openHome()   // the check's info card lives in the home window — make sure it's up front
            appState.update.checkForUpdatesNow(from: .home)
        }
        .disabled(ComputerUseUpgrade.shared.isBlockingInterface || !UpdateController.appUpdatesEnabled)
        Text("Version \(UpdateController.currentVersionString)")

        Divider()
        Button("Quit Sentient OS") { NSApplication.shared.terminate(nil) }
    }

    /// Share explicit reopening with Dock clicks, including minimized Home and pending setup.
    @MainActor private func openHome() {
        HomeWindowOpening.registerOpener {
            openWindow(id: SentientOSApp.homeWindowID)
        }
        HomeWindowOpening.open()
    }
}

/// The label is mounted even when no menu or regular scene has opened. Its SwiftUI environment
/// supplies home creation for setup completed after a suppressed, windowless update launch.
struct MenuBarIcon: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: OrbMark.menuBarIcon)
            .accessibilityLabel("Sentient OS")
            .onAppear {
                HomeWindowOpening.registerOpener {
                    openWindow(id: SentientOSApp.homeWindowID)
                }
                ComputerUseUpgrade.shared.registerHomeOpener {
                    openWindow(id: SentientOSApp.homeWindowID)
                }
            }
    }
}
