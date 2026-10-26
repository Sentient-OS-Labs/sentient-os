// Main window navigation: onboarding becomes Home as soon as analysis timing is chosen.
// Analysis runs in the app-owned coordinator and presents progress in its own window.
// Doc: Documentation - Views - Home, Processing & Shared UI.md

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var navigation = MainNavigation.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showDevTools = false
    @State private var startedWritingStyleSetup = false
    @State private var onboardingScale = OnboardingWindowLayout.scale(
        visibleSize: NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900))
    // Persistent custom folder roots (CustomRoots store) — added in Settings or Dev Tools,
    // watched here so Analyze Now and the Analysis popover react to edits from any window.
    @AppStorage(CustomRoots.key) private var customRootsRaw = ""
    private var customRoots: [URL] { CustomRoots.decode(customRootsRaw) }
    @State private var fdaGranted = Permissions.hasFullDiskAccess()
    // The 3-way card mode (Dev Tools → Proactive Cards…). DEFAULT: real cards + full-cycle
    // Analyze Now; .jesai/.launch swap in a hard-coded demo deck (pitch / launch-video mode).
    @AppStorage(BriefingDeck.key) private var deckRaw = BriefingDeck.defaultRaw
    private var deck: BriefingDeck { BriefingDeck(rawValue: deckRaw) ?? .real }
    /// Observe the engine choice as well as its installer, including changes in another window.
    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue
    private var computerSetup: ComputerUseSetup {
        .instance(for: .selected(for: ModelBackend(rawValue: backendRaw) ?? .chatgpt))
    }

    /// Observed for the bottom-left model-download whisper (same overlay slot).
    @State private var download = ModelDownload.shared

    /// The sources Analyze Now will process — the shared selection (folders + DB sources).
    private var selectedSources: [RunSource] {
        SourceSelection.current(fdaGranted: fdaGranted)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if !appState.hasCompletedOnboarding {
                OnboardingCanvas(scale: onboardingScale) {
                    OnboardingView { timing in
                        appState.processing.choose(timing)
                        withAnimation(.easeInOut(duration: 0.3)) { appState.hasCompletedOnboarding = true }
                        if timing == .now {
                            openWindow(id: ProcessingWindowView.windowID)
                        }
                    }
                }
                .transition(.opacity)
                // The just-updated notice, overlaid on ONBOARDING only (the home renders it in
                // its own banner slot): a mid-onboarding user may have closed a broken window,
                // and the post-update relaunch that brings it back should say why it's back.
                .overlay(alignment: .topTrailing) {
                    UpdateNoticeCapsule()
                        .padding(.trailing, 24).padding(.top, 24)
                }
            } else {
                home
                    // Secondary pages grow over the retained Home canvas. Home stays inert;
                    // its draft, scroll position and card state keep their existing lifetime.
                    .allowsHitTesting(navigation.page == .home)
                    .disabled(navigation.page != .home)
                    .accessibilityHidden(navigation.page != .home)
            }
        }
        .overlayPreferenceValue(SettingsButtonBoundsKey.self) { source in
            if appState.hasCompletedOnboarding {
                SettingsPageLayer(isPresented: navigation.page == .settings,
                                  animate: navigation.animatesSettingsTransition, source: source)
            }
        }
        .overlayPreferenceValue(KnowledgeButtonBoundsKey.self) { source in
            if appState.hasCompletedOnboarding {
                HomePageLayer(isPresented: navigation.page == .knowledge,
                              animate: navigation.animatesKnowledgeTransition, source: source,
                              sourceKind: .knowledge, retainingContent: true) {
                    if navigation.hasOpenedKnowledge {
                        KnowledgeView(isPresented: navigation.page == .knowledge,
                                      animateEntrance: navigation.animatesKnowledgeTransition)
                    }
                }
            }
        }
        .frame(minWidth: appState.hasCompletedOnboarding ? (navigation.page == .home ? 840 : 1040)
                   : OnboardingWindowLayout.minimum.width * onboardingScale,
               minHeight: appState.hasCompletedOnboarding ? (navigation.page == .home ? 680 : 800)
                   : OnboardingWindowLayout.minimum.height * onboardingScale)
        .background(OnboardingWindowFit(active: !appState.hasCompletedOnboarding) { onboardingScale = $0 })
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
        // Background setup/download whispers share Home and onboarding's bottom-left slot.
        // Secondary pages use their own status rows and keep this area clear:
        // · the model-download card (ModelDownloadWhisper) — the on-device model landing in the
        //   background while the user is elsewhere (it hides itself when onboarding's full-screen
        //   downloading view shows the same bar big);
        // · the computer-use setup line — the driver download is an unstructured background task
        //   that outlives onboarding's processing takeover (knowledge base creation, even the home
        //   in rare cases), so as long as it's actually running, this quiet line shows.
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 10) {
                if navigation.page == .home { ModelDownloadWhisper(download: download) }
                if computerSetup.isInstalling && navigation.page == .home {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                        Text("Setting up computer use in the background.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.faint)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.leading, 22).padding(.bottom, 12)
        }
        .animation(.easeInOut(duration: 0.35), value: computerSetup.isInstalling)
        .animation(.easeInOut(duration: 0.35), value: download.phase)
        .animation(.easeInOut(duration: 0.35), value: download.fullScreenVisible)
        // The mandatory update gate floats above everything (home, processing, dev sheet) — when a
        // required update is found it takes over; otherwise it draws nothing. (Updates/)
        .modifier(LifetimeUpgradePresentation())
        .overlay { UpdateGateView() }
        .background(MainWindowCloseGuard())
        .onChange(of: navigation.page) { _, page in
            if page != .home { showDevTools = false }
        }
        .onChange(of: appState.hasCompletedOnboarding) { _, completed in
            if !completed {
                showDevTools = false
                startedWritingStyleSetup = false
            }
        }
        .sheet(isPresented: $showDevTools) {
            DevToolsView()
        }
        // Existing knowledge bases get their Double Tap writing samples set up silently, once per
        // session, the first time the home is idle. The introduction sheet (WritingStyleSetupView)
        // is hidden for now. An independent Task, not this view task: generateIfNeeded marks the
        // pipeline busy, which flips the id below and would cancel its own run.
        .task(id: canStartWritingStyleSetup) {
            guard canStartWritingStyleSetup, !startedWritingStyleSetup else { return }
            startedWritingStyleSetup = true
            Task { @MainActor in
                Log("WritingStyle: silent setup started for an existing knowledge base")
                do { try await WritingStyle.generateIfNeeded() }
                catch { Log("WritingStyle: silent setup failed (\(ErrorLabel(error)))") }
            }
        }
        .onChange(of: showDevTools) { _, open in
            if !open { fdaGranted = Permissions.hasFullDiskAccess() }   // may have changed in the sheet
        }
    }

    private var canStartWritingStyleSetup: Bool {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == nil else { return false }
        #endif
        return appState.hasCompletedOnboarding && appState.processing.initialComplete && !appState.processing.isBusy
            && !appState.processing.isSuspended
            && !PipelineActivity.shared.isRunning && !appState.commandCoordinator.run.isRunning
            && !WritingStyle.exists()
            && FileManager.default.fileExists(atPath: VaultGenerator.vaultRoot.appendingPathComponent("README.md").path)
    }

    private var home: some View {
        let sources = selectedSources
        return HomeView(
            isPresented: navigation.page == .home,
            thingsUnderstood: LifetimeStats.analyzed,
            sources: .init(
                files: sources.contains { if case .files = $0 { return true } else { return false } },
                whatsapp: sources.contains { if case .whatsapp = $0 { return true } else { return false } },
                imessage: sources.contains { if case .imessage = $0 { return true } else { return false } },
                notes: sources.contains(.notes),
                whatsappAvailable: WhatsAppSource.isInstalled),
            customRoots: customRoots,
            deck: deck,
            onAnalyze: {
                if !appState.processing.isBusy && appState.processing.record.status != .requested {
                    appState.processing.requestNow()
                }
                openWindow(id: ProcessingWindowView.windowID)
            },
            onShowDevTools: { showDevTools = true })
    }
}
