//
//  Sentient_OS_macOSApp.swift
//  Sentient OS macOS
//
//  @main app shell. The main window IS the proactive home (HomeView ⟷ processing takeover);
//  Knowledge, Settings, and Connect-your-AIs each open as their own window; plus an
//  always-present MenuBarExtra. The live store is CycleStore (Ingestion/CycleStore.swift),
//  reached directly by the views — the app shell owns no store.
//

import SwiftUI

@main
struct SentientOSApp: App {
    @State private var appState = AppState()

    // To add a headless self-test, restore the one-line hook here — see
    // Documentation/Self-Testing (Eval Harness).md (the `Self Tests - Temp/` folder is kept empty).

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)   // Sentient OS is dark-only — no light mode
                .task { await VaultCloud.pushIfDirty() }   // catch up a mirror sync deferred by an earlier quit/failure
        }
        .windowStyle(.hiddenTitleBar)            // OLED black runs edge-to-edge; no gray trim
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 880)   // the proactive home's canvas

        // PROACTIVE · EXECUTE — the dev window for PART 3 (the executor). Lists the real
        // ready-to-fire actions from the latest research+prepare run, each with a working FIRE
        // button. Opened from DEV TOOLS; a normal titled window so it's obviously closable.
        Window("Proactive · Execute", id: ProactiveExecuteView.windowID) {
            ProactiveExecuteView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 820)

        // The knowledge inspector is its OWN resizable window (native traffic-light controls,
        // closed with the red button) — not a sheet. Single-instance; `openWindow` brings it up.
        // Title is intentionally blank: the in-app serif "Knowledge" header is the title, so we
        // don't want the native titlebar repeating it.
        Window("", id: DatabaseView.windowID) {
            DatabaseView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 720)

        // Settings — its own window, opened from the home's top-bar gear.
        Window("", id: SettingsView.windowID) {
            SettingsView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 560, height: 620)

        // Connect your AIs — opened by the glowing CTA in the Your AIs popover (setup guide is
        // a deferred stub for now).
        Window("", id: ConnectAIsView.windowID) {
            ConnectAIsView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 560)

        MenuBarExtra("Sentient OS", systemImage: "brain.head.profile") {
            MenuBarView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
    }
}
