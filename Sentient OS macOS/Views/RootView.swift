//
//  RootView.swift
//  Sentient OS macOS
//
//  The main window's switchboard: the proactive HomeView (idle) ⟷ the full-screen
//  ProcessingView takeover (today they cross-fade). RootView owns the analyze/source state and
//  feeds HomeView its live context; Analyze Now (in the home's Analysis popover) runs whatever
//  the dev source picker has armed (SourceSelection). The picker + all debug controls live in
//  DevToolsView, a sheet reached from the home's DEV TOOLS handle (DEBUG builds only).
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
    // The 3-way card mode (Dev Tools → Proactive Cards…). DEFAULT: real cards + full-cycle
    // Analyze Now; .jesai/.launch swap in a hard-coded demo deck (pitch / launch-video mode).
    @AppStorage(BriefingDeck.key) private var deckRaw = BriefingDeck.defaultRaw
    private var deck: BriefingDeck { BriefingDeck(rawValue: deckRaw) ?? .real }
    // Cloud sources — same flags the scheduler reads, so Analyze Now processes exactly what an
    // overnight run would (a no-op until Gmail/Calendar are actually connected + selected).
    @AppStorage("dbg.gmail.connected")    private var gmailConnected = false
    @AppStorage("dbg.run.gmail")          private var runGmail = false
    @AppStorage("dbg.calendar.connected") private var calendarConnected = false
    @AppStorage("dbg.run.calendar")       private var runCalendar = false

    // Resolved at launch (env → bundle → App Support → repo root); nil = model not on this Mac.
    // State, not a static let: onboarding's model download can land the file mid-session, and
    // the finish closure below re-resolves so the home's Analyze Now works without a relaunch.
    @State private var modelPath = ModelLocator.resolve()

    /// Observed for the global "setting up computer use" whisper (the overlay below).
    @State private var codex = CodexSetup.shared

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
                    modelPath = ModelLocator.resolve()   // the onboarding download may have just landed it
                    withAnimation(.easeInOut(duration: 0.3)) { appState.hasCompletedOnboarding = true }
                    // The first full cycle just stamped "initial done" — arm the 18h clock NOW.
                    // (The app lives in the menu bar and rarely relaunches, so waiting for the
                    // next launch tick could delay auto-enable by days.)
                    appState.scheduler.maybeAutoEnable()
                    Task {
                        try? await Task.sleep(for: .seconds(0.6))   // let the home settle first
                        openWindow(id: KnowledgeView.windowID)
                    }
                }
                .transition(.opacity)
            } else if isProcessing, let modelPath {
                // Same engine + UI as the dev "start on device" buttons; .auto = backfill new
                // buckets, catch up the rest. (Gmail is a dev-tools leg; the home button is on-device.)
                ProcessingView(modelPath: modelPath,
                               connectors: RunSource.connectors(from: selectedSources),
                               mode: .auto,
                               runGmail: gmailConnected && runGmail,
                               runCalendar: calendarConnected && runCalendar,
                               fullCycle: deck == .real) {   // real mode → read + knowledge base + proactive + wipe
                    withAnimation(.easeInOut(duration: 0.3)) { isProcessing = false }
                    appState.scheduler.maybeAutoEnable()   // a full cycle may have just stamped "initial done" → arm the 18h clock
                }
                .transition(.opacity)
            } else {
                home.transition(.opacity)
            }
        }
        .frame(minWidth: 1040, minHeight: 800)
        // Core tier: the home window came up (fires once per window instantiation — launch opens it
        // automatically; anything later is a deliberate menu-bar/Dock reopen, hence the trigger
        // param). Sidekick-only users who never look at home are exactly who this measures.
        // Onboarding appearances don't count; the SDK's session signals cover day one.
        .onAppear {
            guard appState.hasCompletedOnboarding else { return }
            let sinceBoot = Date().timeIntervalSince(Analytics.bootTime)
            Analytics.signal("Home.opened",
                             parameters: ["trigger": sinceBoot < 5 ? "launch" : "reopen"], tier: .core)
        }
        // The computer-use setup whisper — screen-agnostic on purpose: the bootstrap is an
        // unstructured background task that outlives onboarding's processing takeover (knowledge
        // base creation, even the home in rare cases), so as long as it's actually running, this
        // quiet line rides the bottom of WHATEVER screen is up. Keyed to the live shared engine
        // state, so dev/Settings-triggered setups surface it too.
        .overlay(alignment: .bottomLeading) {
            if codex.settingUpComputerUse {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("Setting up Codex computer use in the background.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                }
                .padding(.leading, 22).padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: codex.settingUpComputerUse)
        // The mandatory update gate floats above everything (home, processing, dev sheet) — when a
        // required update is found it takes over; otherwise it draws nothing. (Updates/)
        .overlay { UpdateGateView(host: .home) }
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
            modelMissing: modelPath == nil,
            deck: deck,
            onAnalyze: { withAnimation(.easeInOut(duration: 0.3)) { isProcessing = true } },
            onShowDevTools: { showDevTools = true })
    }
}
