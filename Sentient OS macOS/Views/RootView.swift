//
//  RootView.swift
//  Sentient OS macOS
//
//  The main window's switchboard: the proactive HomeView (idle) ⟷ the full-screen
//  ProcessingView takeover (today they cross-fade). RootView owns the analyze/source state and
//  feeds HomeView its live context; Analyze Now (in the home's Analysis popover) runs whatever
//  the dev source picker has armed (SourceSelection). The picker + all debug controls live in
//  DevToolsView, a sheet reached from the Analysis popover's DEV TOOLS link.
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var isProcessing = false
    @State private var showDevTools = false
    @State private var customRoots: [URL] = []   // session-only custom folders (dev picker)
    @State private var fdaGranted = Permissions.hasFullDiskAccess()
    @AppStorage("dev.proactive.realCards") private var realCards = false   // real cards + full-cycle Analyze Now
    // Cloud sources — same flags the scheduler reads, so Analyze Now processes exactly what an
    // overnight run would (a no-op until Gmail/Calendar are actually connected + selected).
    @AppStorage("dbg.gmail.connected")    private var gmailConnected = false
    @AppStorage("dbg.run.gmail")          private var runGmail = false
    @AppStorage("dbg.calendar.connected") private var calendarConnected = false
    @AppStorage("dbg.run.calendar")       private var runCalendar = false

    // Resolved at launch (env → bundle → App Support → repo root); nil = model not on this Mac.
    private static let modelPath = ModelLocator.resolve()

    /// The sources Analyze Now will process — the dev picker's selection (folders + DB sources).
    private var selectedSources: [RunSource] {
        SourceSelection.current(customRoots: customRoots, fdaGranted: fdaGranted)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if isProcessing, let modelPath = Self.modelPath {
                // Same engine + UI as the dev "start on device" buttons; .auto = backfill new
                // buckets, catch up the rest. (Gmail is a dev-tools leg; the home button is on-device.)
                ProcessingView(modelPath: modelPath,
                               connectors: RunSource.connectors(from: selectedSources),
                               mode: .auto,
                               runGmail: gmailConnected && runGmail,
                               runCalendar: calendarConnected && runCalendar,
                               fullCycle: realCards) {   // real mode → read + knowledge base + proactive + wipe
                    withAnimation(.easeInOut(duration: 0.3)) { isProcessing = false }
                    appState.scheduler.maybeAutoEnable()   // a full cycle may have just stamped "initial done" → arm the 18h clock
                }
                .transition(.opacity)
            } else {
                home.transition(.opacity)
            }
        }
        .frame(minWidth: 1040, minHeight: 800)
        .sheet(isPresented: $showDevTools) {
            DevToolsView(customRoots: $customRoots)
        }
        .onChange(of: showDevTools) { _, open in
            if !open { fdaGranted = Permissions.hasFullDiskAccess() }   // may have changed in the sheet
        }
    }

    private var home: some View {
        let sources = selectedSources
        return HomeView(
            thingsUnderstood: LifetimeStats.analyzed,
            sources: .init(
                files: sources.contains { if case .files = $0 { return true } else { return false } },
                whatsapp: sources.contains { if case .whatsapp = $0 { return true } else { return false } },
                imessage: sources.contains { if case .imessage = $0 { return true } else { return false } },
                notes: sources.contains(.notes),
                whatsappAvailable: WhatsAppSource.isInstalled),
            customRoots: customRoots,
            modelMissing: Self.modelPath == nil,
            realCards: realCards,
            onAnalyze: { withAnimation(.easeInOut(duration: 0.3)) { isProcessing = true } },
            onShowDevTools: { showDevTools = true })
    }
}
