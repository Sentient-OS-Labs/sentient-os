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
import AppKit

// Entry point is main.swift (the binary doubles as the root wake helper) — so no @main here.
struct SentientOSApp: App {
    @State private var appState = AppState()

    /// Scene id for the primary home window, so the menu bar's "Open Sentient OS" can reopen/focus it.
    static let homeWindowID = "home"

    /// True when `window` is the home WindowGroup's window. SwiftUI suffixes the scene id on the
    /// NSWindow identifier ("home-AppWindow-1"), so match the id exactly or as a prefix.
    static func isHomeWindow(_ window: NSWindow) -> Bool {
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == homeWindowID || raw.hasPrefix(homeWindowID + "-")
    }

    // To add a headless self-test, restore the one-line hook here — see
    // Documentation/Self-Testing (Eval Harness).md (the `Self Tests - Temp/` folder is kept empty).

    var body: some Scene {
        WindowGroup(id: Self.homeWindowID) {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)   // Sentient OS is dark-only — no light mode
                .task { await VaultCloud.pushIfDirty() }   // catch up a mirror sync deferred by an earlier quit/failure
        }
        .windowStyle(.hiddenTitleBar)            // OLED black runs edge-to-edge; no gray trim
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 880)   // the proactive home's canvas
        // Always present the home at launch: after a quit with only Settings open, state
        // restoration would otherwise bring back JUST the Settings window — an app with no home.
        .defaultLaunchBehavior(.presented)

        // Every auxiliary window below carries .restorationBehavior(.disabled): the home is the
        // app's ONLY launch surface, so macOS window restoration must never reopen a stray
        // Settings/Knowledge/dev window at launch. This can't be handled by sweeping files —
        // on macOS 26 the restoration record lives outside the app's reach (~/Library/Saved
        // Application State is gone entirely), field-proven by the post-uninstall relaunch
        // resurrecting the Settings window (2026-07-11).

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
        .restorationBehavior(.disabled)

        // The Knowledge reader is its OWN resizable window (native traffic-light controls, closed
        // with the red button) — an Obsidian-style browser over the on-disk markdown vault.
        // Single-instance; `openWindow` brings it up. Title is intentionally blank: the in-app
        // serif "Knowledge" header is the title, so we don't want the native titlebar repeating it.
        Window("", id: KnowledgeView.windowID) {
            KnowledgeView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 720)
        .restorationBehavior(.disabled)

        // Settings — its own window, opened from the home's top-bar gear. Two-pane layout
        // (sidebar + pane), so it wants a wider canvas than the old single-column placeholder.
        Window("", id: SettingsView.windowID) {
            SettingsView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 940, height: 660)
        .restorationBehavior(.disabled)

        // Connect your AIs — the guided setup (per-AI video steps + the sharing toggle), opened
        // by the glow CTAs in the Give-AIs-Knowledge popover and Settings pane of the same name.
        Window("", id: ConnectAIsView.windowID) {
            ConnectAIsView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 900)
        .restorationBehavior(.disabled)

        // Overnight Processing — the dev cockpit for the 3am scheduler (helper approval, launch-at-
        // login, 18h auto-enable, manual arm). Opened from DEV TOOLS → "Overnight Processing…".
        Window("Overnight Processing", id: OvernightDevView.windowID) {
            OvernightDevView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 780)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarView()
                .environment(appState)
                .preferredColorScheme(.dark)
        } label: {
            Image(nsImage: OrbMark.menuBarIcon)   // the home's ring+dot mark, as a template
                .accessibilityLabel("Sentient OS")
        }
    }
}
