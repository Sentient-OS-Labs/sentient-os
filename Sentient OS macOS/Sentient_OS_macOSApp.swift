//
//  Sentient_OS_macOSApp.swift
//  Sentient OS macOS
//
//  @main app shell (Arch §2.3). Builds the one shared SwiftData ModelContainer, hands it to
//  the Store @ModelActor, and presents two scenes: the main window (onboarding/dashboard)
//  and an always-present MenuBarExtra (glanceable overnight status).
//

import SwiftUI
import SwiftData

@main
struct SentientOSApp: App {
    @State private var appState = AppState()
    private let store: Store

    init() {
        #if DEBUG
        SelfTest.runIfRequested()   // headless prompt/output dump when SENTIENT_SELFTEST is set (exits if so)
        #endif

        // One container for the whole app; only `Store` ever touches it (Arch §2.3).
        func makeContainer() throws -> ModelContainer {
            try ModelContainer(for: LedgerEntry.self, Summary.self, SourceCursor.self)
        }
        do {
            self.store = Store(modelContainer: try makeContainer())
        } catch {
            // Dev convenience: an incompatible schema change → wipe the store and retry once.
            let base = URL.applicationSupportDirectory
            for name in ["default.store", "default.store-shm", "default.store-wal"] {
                try? FileManager.default.removeItem(at: base.appending(path: name))
            }
            guard let container = try? makeContainer() else {
                fatalError("Failed to create SwiftData ModelContainer: \(error)")
            }
            self.store = Store(modelContainer: container)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .environment(appState)
                .preferredColorScheme(.dark)   // Sentient OS is dark-only — no light mode
        }
        .windowResizability(.contentMinSize)

        // The knowledge inspector is its OWN resizable window (native traffic-light controls,
        // closed with the red button) — not a sheet. Single-instance; `openWindow` brings it up.
        // Title is intentionally blank: the in-app serif "Knowledge" header is the title, so we
        // don't want the native titlebar repeating it.
        Window("", id: DatabaseView.windowID) {
            DatabaseView(store: store)
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
