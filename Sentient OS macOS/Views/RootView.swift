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
    @Environment(\.openWindow) private var openWindow
    @State private var isProcessing = false
    @State private var showDevTools = false
    // Persistent custom folder roots (CustomRoots store) — added in Settings or Dev Tools,
    // watched here so Analyze Now and the Analysis popover react to edits from any window.
    @AppStorage(CustomRoots.key) private var customRootsRaw = ""
    private var customRoots: [URL] { CustomRoots.decode(customRootsRaw) }
    @State private var fdaGranted = Permissions.hasFullDiskAccess()
    @AppStorage("dev.proactive.realCards") private var realCards = true   // DEFAULT: real cards + full-cycle Analyze Now (dev toggle OFF = the investor demo deck)
    // Cloud sources — same flags the scheduler reads, so Analyze Now processes exactly what an
    // overnight run would (a no-op until Gmail/Calendar are actually connected + selected).
    @AppStorage("dbg.gmail.connected")    private var gmailConnected = false
    @AppStorage("dbg.run.gmail")          private var runGmail = false
    @AppStorage("dbg.calendar.connected") private var calendarConnected = false
    @AppStorage("dbg.run.calendar")       private var runCalendar = false

    // Resolved at launch (env → bundle → App Support → repo root); nil = model not on this Mac.
    private static let modelPath = ModelLocator.resolve()

    /// The sources Analyze Now will process — the shared selection (folders + DB sources).
    private var selectedSources: [RunSource] {
        SourceSelection.current(fdaGranted: fdaGranted)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if !appState.hasCompletedOnboarding {
                // First launch → onboarding, whose finished first analysis calls this closure.
                // The finale (every plan): onboarding dissolves into the home, then the Knowledge
                // window (the Constellation) assembles on top — the user's first sight of their
                // knowledge base, before the cards (or the free-plan preview message) behind it.
                OnboardingView {
                    withAnimation(.easeInOut(duration: 0.3)) { appState.hasCompletedOnboarding = true }
                    Task {
                        try? await Task.sleep(for: .seconds(0.6))   // let the home settle first
                        openWindow(id: KnowledgeView.windowID)
                    }
                }
                .transition(.opacity)
            } else if isProcessing, let modelPath = Self.modelPath {
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
        // The mandatory update gate floats above everything (home, processing, dev sheet) — when a
        // required update is found it takes over; otherwise it draws nothing. (Updates/)
        .overlay { UpdateGateView() }
        .sheet(isPresented: $showDevTools) {
            DevToolsView()
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
