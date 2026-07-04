//
//  MenuBarView.swift
//  Sentient OS macOS
//
//  Glanceable status in the macOS menu bar. A stub today (status line + Quit) — the richer
//  dropdown ("412 / 3,000 · paused (in use)") is still to build.
//

import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.status {
        case .idle:                            Text("Sentient OS · idle")
        case .processing(let done, let total): Text("Processing \(done) / \(total)")
        case .paused(let reason):              Text("Paused — \(reason)")
        case .error(let message):              Text("Error — \(message)")
        }

        Divider()
        Button("Quit Sentient OS") { NSApplication.shared.terminate(nil) }
    }
}
