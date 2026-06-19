//
//  Sentient_OS_macOSApp.swift
//  Sentient OS macOS
//
//  @main app shell. Presents the main window (Constellation ⟷ processing), the For You and
//  Knowledge windows, and an always-present MenuBarExtra. The live store is CycleStore
//  (Ingestion/CycleStore.swift), reached directly by the views — the app shell owns no store.
//

import SwiftUI

@main
struct SentientOSApp: App {
    @State private var appState = AppState()

    init() {
        #if DEBUG
        SelfTest.runIfRequested()   // headless prompt/output dump when SENTIENT_SELFTEST is set (exits if so)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)   // Sentient OS is dark-only — no light mode
                .task { await VaultCloud.pushIfDirty() }   // catch up a mirror sync deferred by an earlier quit/failure
        }
        .windowStyle(.hiddenTitleBar)            // OLED black runs edge-to-edge; no gray trim
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 760)   // the Constellation's intended canvas

        // For You — the briefings ("offerings") window. Its own scene; the Constellation's
        // briefing satellite and (later) the menu bar open it.
        Window("", id: BriefingsView.windowID) {
            BriefingsView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 800)

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

        MenuBarExtra("Sentient OS", systemImage: "brain.head.profile") {
            MenuBarView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
    }
}
