//
//  HomeView.swift
//  Sentient OS macOS
//
//  THE HOME — the app's main surface, and the product itself: Proactive Intelligence. You
//  open Sentient straight into this. The morning run (1 min after wake) leaves a spread of
//  SUGGESTION CARDS here — each one the AI already did the work for ("Should I send it for
//  you?"); clicking is the user's fire (Privacy Constitution: we offer, they fire). A command
//  bar at the foot lets you ask it to DO anything (computer use).
//
//  The chrome is deliberately quiet: a wordmark, conversation search, Analysis, Knowledge
//  and Settings. Optional AI connections live inside Knowledge. Status lives inside Analysis.
//
//  WHEN THERE ARE NO CARDS, the living Orb blooms into the vacated center with "I'm here to
//  help." — the orb appears ONLY here (its one home), turning the empty state into a launchpad
//  that hands your eye straight to the command bar. (Retired ConstellationHome; harvested orb +
//  sources + AIs + vault stats into this surface and its popovers.)
//
//  KNOWLEDGE-BASE-ONLY MODE (free/go plans, CodexAuth.knowledgeBaseOnly): cards never come and
//  the command bar hides — the preview note under the orb (upgrade CTA + Reset jump) is ALWAYS
//  on this home. The gift envelope (the only card the free home can hold) perches top-center
//  above the compact note; flinging the letter blooms the note into the full center. Once the
//  plan claim reads Plus it becomes the reset-and-rebuild celebration.
//
//  Doc: Views/Documentation - Views - Home, Processing & Shared UI.md · cards + the CodexCLI seam:
//  Briefing.swift.
//

import SwiftUI
import AppKit

struct HomeView: View {
    var isPresented = true

    // Live context from RootView (the analyze/source switchboard).
    var thingsUnderstood: Int = 0
    var sources: HomeSources = .init()
    var customRoots: [URL] = []        // session folders from RootView — shown in the Analysis popover, like Dev Tools
    var modelMissing: Bool = false
    var deck: BriefingDeck = .jesai    // .real → real proactive cards from latest(); .jesai/.launch → a demo deck
    var previewKBOnly = false          // preview-only: force the knowledge-base-only state
    var onAnalyze: () -> Void = {}
    var onShowDevTools: () -> Void = {}

    /// Free/go knowledge-base-only mode: no cards ever come, the command bar hides (computer use
    /// burns quota these plans don't have), and the empty state carries the preview message.
    private var kbOnly: Bool { previewKBOnly || CodexAuth.knowledgeBaseOnly }
    var previewUpgraded: Bool? = nil   // preview-only: force the upgraded/not-upgraded note
    /// A kbOnly user whose claim now reads full — they upgraded (codex's own 8-day refresh, the
    /// Health pane's Re-check, or the crossroads all re-mint it). Re-read every appearance, so
    /// the preview note flips to the "reset & rebuild" celebration without any push machinery.
    @State private var planUpgraded = false

    @Environment(\.openWindow) private var openWindow
    @Environment(AppState.self) private var appState

    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    private var reducedMotion: Bool { motionOverride ?? systemReducedMotion }
    private var presentation: SidekickPresentation { appState.sidekickPresentation }
    private var model: ForYouModel { presentation.cards }
    private var conversation: SidekickConversation { appState.commandCoordinator.run.conversation }
    private var inConversation: Bool { !kbOnly && presentation.surface == .conversation }
    @State private var overviewPage = 0
    @State private var overviewPull: Double = 0
    @State private var gatheringFromScroll = false
    @State private var chromeHeight: CGFloat = 140
    @State private var overviewDockTop: CGFloat = 0
    @State private var cardSizes: [String: CGSize] = [:]
    @State private var proactiveDockFrame = CGRect(x: 160, y: 18, width: 126, height: 34)
    // The letter layer is ALWAYS mounted and driven purely by opacity/scale from plain
    // @State — view INSERTION (`if let` overlays) can miss a redraw on macOS hidden-titlebar
    // windows (the "appears only after a resize" bug); opacity changes cannot.
    @State private var letter: Briefing?
    @State private var letterShown = false
    @State private var showAnalysis = false
    @State private var showWhatsAppPicker = false
    @State private var showIMessagePicker = false
    @State private var showGmailConnect = false
    @State private var showCalendarConnect = false
    @State private var showAppleMailPicker = false
    @State private var codex = CodexSetup.shared
    @State private var showCodexSignIn = false
    @State private var dismissedCodexSignInReminder = false
    /// The morning-after caution (last night's scheduled run hit a known snag) — nil = no banner.
    @State private var caution: OvernightCaution.Record?
    /// Kept separately from whole-cycle failures: successfully processing the other sources
    /// must not erase a skipped connector. AppStorage also updates a visible home after 3 AM.
    @AppStorage(ConnectorCaution.key) private var connectorCautionData = Data()
    /// The LIVE health issue (essential perms · codex · computer use) — HealthCaution's ladder;
    /// nil = healthy or muted. Outranks the morning-after caution in the banner slot.
    @State private var liveIssue: HealthCaution.Issue?
    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue
    private var computerSetup: ComputerUseSetup {
        .instance(for: .selected(for: ModelBackend(rawValue: backendRaw) ?? .chatgpt))
    }

    // Chat selections the Analysis popover's WhatsApp/iMessage chips pick into (same keys as SourceSelection).
    @AppStorage("dbg.whatsapp.chats") private var whatsappCSV = ""
    @AppStorage("dbg.run.whatsapp")   private var runWhatsApp = false
    @AppStorage("dbg.imessage.chats") private var imessageCSV = ""
    @AppStorage("dbg.run.imessage")   private var runIMessage = false

    private var homeCanvas: some View {
        GeometryReader { geo in
            let layout = overviewLayout(in: geo.size)
            ZStack {
                SidekickAtmosphere(focused: presentation.composerFocused,
                                   sendPulse: presentation.sendPulse,
                                   active: isPresented && presentation.windowActive && !presentation.textSelected && !presentation.isScrolling && overviewPull == 0)

                SidekickGlassGroup {
                    ZStack {
                        scatter(geo, layout: layout)
                        if kbOnly {
                            // The preview note is ALWAYS on the free home — the gift envelope (the
                            // only card this home can ever hold) perches above it, never in front:
                            // the pitch must not hide behind a fling.
                            previewState
                        } else if model.entries.isEmpty {
                            emptyState.opacity(inConversation ? 0 : 1)
                                .blur(radius: inConversation && !reducedMotion ? 9 : 0)
                                .scaleEffect(inConversation && !reducedMotion ? 0.94 : 1)
                        }
                        VStack(spacing: 0) {
                            Color.clear.frame(height: kbOnly ? 130 : (inConversation && hasCriticalCaution ? max(128, chromeHeight + 8) : 86))
                            if !kbOnly {
                                SidekickTranscript(conversation: conversation, coordinator: appState.commandCoordinator,
                                                   presentation: presentation,
                                                   active: isPresented && presentation.windowActive && inConversation)
                                    .opacity(inConversation ? 1 : 0)
                                    .blur(radius: !inConversation && !reducedMotion ? 10 : 0)
                                    .offset(y: !inConversation && !reducedMotion ? 30 : 0)
                                    .animation(reducedMotion ? .easeOut(duration: 0.14)
                                        : .smooth(duration: 0.35).delay(inConversation ? 0.16 : 0), value: inConversation)
                                    .allowsHitTesting(inConversation)
                                    .disabled(!inConversation)
                                    .accessibilityElement(children: inConversation ? .contain : .ignore)
                                    .accessibilityHidden(!inConversation)
                            } else { Spacer() }
                            VStack(spacing: 0) {
                                if !kbOnly && !inConversation {
                                    conversationPeek.padding(.horizontal, 38).padding(.bottom, 13)
                                        .transition(SidekickStyle.entrance(reducedMotion))
                                }
                                bottomDock
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("sidekick-home")).minY } action: { value in
                                if !inConversation { overviewDockTop = value }
                            }
                        }
                        chrome(in: geo.size)       // on top → the nav stays clickable
                        #if DEBUG
                        devToolsOverlay
                        #endif
                    }
                }
                .blur(radius: letterShown ? 7 : 0)
                .opacity(letterShown ? 0.4 : 1)

                letterLayer(geo)
            }
            .background {
                SidekickOverviewScroll(
                    enabled: isPresented && !kbOnly && !inConversation
                        && !letterShown && !showAnalysis,
                    activeRect: layout.region, onProgress: followOverviewScroll,
                    onSettle: settleOverviewScroll, onCollapse: dockOverviewFromScroll)
            }
            .onChange(of: layout.pageCount) { _, count in overviewPage = min(overviewPage, count - 1) }
        }
    }

    private var observedHome: some View {
        homeCanvas
        .frame(minWidth: 840, minHeight: 680)
        .coordinateSpace(name: "sidekick-home")
        .background(SidekickStyle.base)
        .preferredColorScheme(.dark)
        .tint(SidekickStyle.accent)
        .background(SidekickWindowPresence { active in
            presentation.windowActive = active
            updateConversationVisibility()
        })
        .animation(SidekickStyle.motion(reducedMotion), value: inConversation)
        .onAppear {                        // every appearance starts fresh: sealed envelope, full deal
            letter = nil
            letterShown = false
            model.coordinator = appState.commandCoordinator
            appState.commandCoordinator.run.proactiveCards = { [weak model] in
                model?.sidekickActions ?? []
            }
            if !appState.isUninstalling { model.ensureVisit(deck: deck) }
            presentation.visit(conversation: conversation, running: appState.commandCoordinator.run.isRunning,
                               pending: appState.commandCoordinator.run.recovery.isPending)
            updateConversationVisibility()
            planUpgraded = previewUpgraded ?? (kbOnly && CodexAuth.currentPlan()?.tier == .full)
            caution = OvernightCaution.latest()
            probeHealth()
        }
        .onDisappear { conversation.isVisible = false }
        .onChange(of: presentation.surface) { _, surface in
            if surface == .suggestions { overviewPull = 0; gatheringFromScroll = false }
            updateConversationVisibility()
        }
        .onChange(of: model.entries.map(\.id)) { _, ids in
            cardSizes = cardSizes.filter { ids.contains($0.key) }
        }
        .onChange(of: conversation.navigationRequest) { _, id in
            if id != nil { showConversation() }
        }
        .onChange(of: appState.commandCoordinator.run.recovery.content?.id) { _, id in
            if id != nil && isPresented && presentation.windowActive { showConversation() }
        }
        .onChange(of: appState.commandCoordinator.run.isRunning) { _, running in
            if !running { model.reconcileFinishedRuns() }
            else { showConversation() }
        }
        .onChange(of: isPresented) { _, visible in
            updateConversationVisibility()
            if !visible { overviewPull = 0; presentation.clearChatConfirmationShown = false }
            if visible {
                model.ensureVisit(deck: deck)
                presentation.visit(conversation: conversation, running: appState.commandCoordinator.run.isRunning,
                                   pending: appState.commandCoordinator.run.recovery.isPending)
                planUpgraded = previewUpgraded ?? (kbOnly && CodexAuth.currentPlan()?.tier == .full)
                caution = OvernightCaution.latest()
                probeHealth()
            } else {
                showAnalysis = false
                showCodexSignIn = false
            }
        }
    }

    private var lifecycleHome: some View {
        observedHome
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == nil {
                Task { await MailAccountCloud.shared.retryPendingSync() }
            }
            // The user may just have fixed something in System Settings (or a cycle cleared last
            // night's caution) — re-probe so the banner melts away the moment they return.
            withAnimation(.easeInOut(duration: 0.25)) { caution = OvernightCaution.latest() }
            probeHealth()
            Task { await refreshCodexSignIn() }
        }
        .task(id: canCheckCodexSignIn) { await refreshCodexSignIn() }
        .onChange(of: canOfferCodexSignIn) { _, _ in offerCodexSignInIfNeeded() }
        .onChange(of: codex.loggedIn) { _, signedIn in
            if signedIn {
                showCodexSignIn = false
                dismissedCodexSignInReminder = false
                probeHealth(forceCodexRecheck: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            guard !appState.isUninstalling else { return }
            model.ensureVisit(deck: deck)
        }
        .onChange(of: deck) { _, v in
            // The teardown's defaults wipe re-publishes the deck key — never re-deal mid-uninstall.
            guard !appState.isUninstalling else { return }
            model.beginVisit(deck: v)                               // mode flip → re-deal
        }
        .onChange(of: computerSetup.ready) { _, _ in probeHealth() }
        .onChange(of: computerSetup.isInstalling) { _, _ in probeHealth() }
        .onChange(of: ComputerUseGate.shared.automation) { _, _ in probeHealth() }
        .onChange(of: backendRaw) { _, _ in
            if backendRaw != ModelBackend.chatgpt.rawValue { showCodexSignIn = false }
            probeHealth()
        }
        .onChange(of: appState.isUninstalling) { _, tearing in
            // Uninstall began → take every card off the table; a cancel deals them back in.
            if tearing {
                showCodexSignIn = false
                withAnimation(.easeInOut(duration: 0.3)) { model.clear() }
            }
            else { model.beginVisit(deck: deck) }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: model.entries.isEmpty)
    }

    var body: some View {
        lifecycleHome
        .sheet(isPresented: $showWhatsAppPicker) {
            ChatPicker(sourceName: "WhatsApp", loadChats: { try WhatsAppSource().listChats() },
                       initialSelection: Set(whatsappCSV.split(separator: ",").map(String.init))) { sel in
                whatsappCSV = sel.sorted().joined(separator: ","); runWhatsApp = !sel.isEmpty
            }
        }
        .sheet(isPresented: $showAppleMailPicker) {
            AppleMailPicker(initialSelection: AppleMailSelection.accounts) { accounts in
                UserDefaults.standard.set(accounts.sorted().joined(separator: ","), forKey: AppleMailSelection.key)
            }
        }
        .sheet(isPresented: $showIMessagePicker) {
            ChatPicker(sourceName: "iMessage", loadChats: { try iMessageSource().listChats() },
                       initialSelection: Set(imessageCSV.split(separator: ",").map(String.init))) { sel in
                imessageCSV = sel.sorted().joined(separator: ","); runIMessage = !sel.isEmpty
            }
        }
        // Gmail / Calendar connect sheets — the SAME sheets Dev Tools opens (connect / select / remove).
        .sheet(isPresented: $showGmailConnect) { CloudConnectSheet(.gmail) }
        .sheet(isPresented: $showCalendarConnect) { CloudConnectSheet(.calendar) }
        .sheet(isPresented: $showCodexSignIn, onDismiss: {
            Task { await refreshCodexSignIn() }
        }) { ChatGPTSignInSheet() }
    }

    // MARK: Chrome — the top-bar nav + the editorial greeting

    private func chrome(in size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            HStack(alignment: .top, spacing: 24) {
                header
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Clear the cards' path as a direct pull approaches the greeting.
                    // Opacity follows the same gesture and restores on a partial reversal.
                    .opacity(inConversation ? 0 : (reducedMotion ? 1 : max(0, 1 - overviewPull / 60)))
                    .blur(radius: inConversation && !reducedMotion ? 6 : 0)
                    .offset(y: reducedMotion ? 0 : (inConversation ? -8 : -min(8, overviewPull * 0.15)))
                    .allowsHitTesting(false).accessibilityHidden(inConversation)
                if !inConversation || hasCriticalCaution {
                    cautionBanner.frame(maxWidth: min(480, size.width * 0.48))
                }
            }.padding(.horizontal, 30).padding(.top, 25)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { value in
            chromeHeight = value
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            SidekickMark(size: 18, illuminated: true)
            Text("Sentient OS")
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
            if !kbOnly { proactiveDock }
            Spacer()
            if !kbOnly && inConversation {
                SidekickToolbarIconButton(symbol: "magnifyingglass") {
                    withAnimation(SidekickStyle.motion(reducedMotion)) {
                        presentation.searchShown.toggle()
                    }
                }
                    .help("Search conversation").accessibilityLabel("Search conversation")
                    .accessibilityIdentifier("sidekick.search")
                    .keyboardShortcut("f", modifiers: .command)
                SidekickClearChatButton(coordinator: appState.commandCoordinator, presentation: presentation)
            }
            NavItem(title: "Analysis", icon: "waveform.path", dot: Theme.Ink.green) { showAnalysis = true }
                .popover(isPresented: $showAnalysis) { analysisPopover }
            NavItem(title: "Knowledge", icon: "books.vertical") { HomeWindowOpening.open(.knowledge) }
                .anchorPreference(key: KnowledgeButtonBoundsKey.self, value: .bounds) { $0 }
            NavItem(icon: "gearshape") { HomeWindowOpening.open(.settings) }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("navigation.settings")
                .help("Settings (⌘,)")
                .anchorPreference(key: SettingsButtonBoundsKey.self, value: .bounds) { $0 }
        }
        .padding(.horizontal, 30).padding(.top, 18)
    }

    private var proactiveDock: some View {
        ZStack {
            // Keep the destination stable while the cards are out, without rendering glass.
            Color.clear
            if inConversation {
                Button {
                    withAnimation(SidekickStyle.motion(reducedMotion)) { presentation.surface = .suggestions }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "square.stack.3d.up")
                        Text("Proactive")
                        if !model.entries.isEmpty {
                            Text("\(model.entries.count)").font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.white.opacity(0.08), in: Capsule())
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .sidekickGlass(radius: 15, prominent: true)
                }
                .buttonStyle(SidekickPressStyle())
                .accessibilityIdentifier("sidekick.proactive")
                .transition(reducedMotion ? .opacity : .asymmetric(
                    insertion: .scale(scale: 0.85).combined(with: .opacity)
                        .animation(.smooth(duration: 0.22).delay(0.28)),
                    removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
        }
        .frame(width: 126, height: 34)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("sidekick-home")) } action: { proactiveDockFrame = $0 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(greeting)
                .display(27)
                .foregroundStyle(Theme.Ink.statusInk)
            Text(model.entries.isEmpty ? "A little help, whenever you need it." : "A few things to make your day easier.")
                .font(.system(size: 12.5)).foregroundStyle(SidekickStyle.secondary)
        }
    }

    // MARK: The caution banner (one slot, most severe first)
    //
    // The blank space beside the greeting holds AT MOST ONE capsule. A LIVE issue outranks
    // history: HealthCaution's ladder (an essential permission off · codex gone/signed out ·
    // computer use regressed) renders red, because the product is broken RIGHT NOW; otherwise
    // the morning-after caution renders amber (last night's UNATTENDED run hit a knowable snag —
    // OvernightCaution recorded it at ProactiveCycle's choke point; the next fully successful
    // cycle clears it on its own). Both roads lead to Settings → Permissions & Health. Live
    // issues re-probe on foreground and melt away when fixed; ✕ mutes a live issue's kind for
    // the session (a lower rung may then surface), while the amber ✕ clears the record. Below
    // both: skipped-connector warnings from the last completed KB pass, then the green
    // just-updated notice (UpdateNotice) with its changelog link. Good news
    // never outranks something broken.

    private var hasCriticalCaution: Bool {
        (needsCodexSignIn && !dismissedCodexSignInReminder) || liveIssue != nil
            || computerSetup.updateNotice == .failed || caution != nil
            || !ConnectorCaution.items(from: connectorCautionData).isEmpty
    }

    private var cautionBanner: some View {
        Group {
            if needsCodexSignIn && !dismissedCodexSignInReminder {
                CautionCapsule(message: "Sign in to ChatGPT to keep Sentient working for you.",
                               accent: Theme.Ink.amber, actionTitle: "Sign in",
                               onAction: presentCodexSignIn,
                               onDismiss: {
                                   dismissedCodexSignInReminder = true
                                   HealthCaution.dismiss(.codexSignedOut)
                                   if case .codexSignedOut? = liveIssue { liveIssue = nil }
                               })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let issue = liveIssue {
                CautionCapsule(message: issue.message, accent: Theme.Ink.red,
                               actionTitle: "Open Settings", onAction: openHealthSettings,
                               onDismiss: {
                                   HealthCaution.dismiss(issue)
                                   withAnimation(.easeInOut(duration: 0.25)) { liveIssue = nil }
                                   probeHealth()   // the muted kind may have been hiding a lower rung
                               })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if computerSetup.updateNotice == .updating || computerSetup.updateNotice == .failed {
                computerUseUpdateNotice
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let caution {
                CautionCapsule(message: caution.message,
                               actionTitle: cautionAction(caution.kind)?.title,
                               onAction: cautionAction(caution.kind)?.run ?? {},
                               onDismiss: {
                                   OvernightCaution.clear()
                                   withAnimation(.easeInOut(duration: 0.25)) { self.caution = nil }
                               })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let connector = ConnectorCaution.items(from: connectorCautionData).first {
                CautionCapsule(message: connector.message,
                               actionTitle: "Open Settings", onAction: openSourceSettings,
                               onDismiss: {
                                   withAnimation(.easeInOut(duration: 0.25)) {
                                       ConnectorCaution.dismiss(connector.slug)
                                   }
                               })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if computerSetup.updateNotice == .ready {
                computerUseUpdateNotice
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                ZStack(alignment: .topTrailing) {
                    UpdateNoticeCapsule()
                    // The offer waits until update notices are dismissed and the home is
                    // active. Keeping it here also postpones it behind every caution above.
                    if isPresented && deck == .real && !letterShown && !showAnalysis {
                        InviteBanner()
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: connectorCautionData)
        .animation(.easeInOut(duration: 0.25), value: computerSetup.updateNotice)
    }

    private var computerUseUpdateNotice: some View {
        ComputerUseUpdateNotice(state: computerSetup.updateNotice,
                             progress: computerSetup.progress,
                             onRetry: {
                                 let setup = computerSetup
                                 Task { await setup.install(force: true) }
                             },
                             onDismiss: computerSetup.dismissUpdateNotice)
    }

    /// The amber caution's one-click fix, where there is one: a signed-out codex is fixed in
    /// Permissions & Health; a full disk in System Settings' Storage pane. Weather kinds (offline,
    /// usage limit) have nothing to click.
    private func cautionAction(_ kind: OvernightCaution.Kind) -> (title: String, run: () -> Void)? {
        switch kind {
        case .loggedOut: return ("Open Settings", openHealthSettings)
        case .diskFull:  return ("Manage Storage", { DiskSpace.openStorageSettings() })
        case .connectorAuth:   // the fix lives on the engine's own connectors page
            return ("Sign In Again", { NSWorkspace.shared.open(ConnectorCensus.directoryURL) })
        case .noInternet, .usageLimit, .inputTooLarge, .stalled: return nil
        }
    }

    /// Land directly on Permissions & Health — every banner's fix lives there; never strand the
    /// user on the default pane.
    private func openHealthSettings() {
        HomeWindowOpening.open(.settings, settingsPane: .health)
    }

    private func openSourceSettings() {
        HomeWindowOpening.open(.settings, settingsPane: .sources)
    }

    /// Run HealthCaution's ladder off the main thread of thought: cheap sync probes, plus a
    /// cached codex login check (forced fresh while a codex banner is up, so a fix clears on the
    /// very next foreground). Quiet on pitch decks (demo cards must never share the stage with a
    /// red capsule) and on the free home (HealthCaution guards kbOnly too — defense in depth).
    private func probeHealth(forceCodexRecheck: Bool = false) {
        guard deck == .real, !kbOnly else { return }
        Task {
            let issue = await HealthCaution.probe(forceCodexRecheck: forceCodexRecheck || liveIssue?.kindKey == "codex")
            withAnimation(.easeInOut(duration: 0.25)) { liveIssue = issue }
        }
    }

    // A private login starts unknown. Wait for Codex installation before checking it,
    // then offer sign-in once per app session; closing and reopening Home never re-prompts.
    private var canCheckCodexSignIn: Bool {
        appState.hasCompletedOnboarding && !appState.isUninstalling && isPresented && deck == .real
            && backendRaw == ModelBackend.chatgpt.rawValue
            && codex.installed && !codex.preparing && !codex.installing
            && ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == nil
    }

    private var needsCodexSignIn: Bool {
        canCheckCodexSignIn && codex.loginStatusChecked && !codex.loggedIn
    }

    private var canOfferCodexSignIn: Bool {
        needsCodexSignIn && !appState.hasOfferedCodexSignIn
            && !letterShown && !showAnalysis
            && !showWhatsAppPicker && !showIMessagePicker && !showGmailConnect && !showCalendarConnect && !showAppleMailPicker
    }

    private func refreshCodexSignIn() async {
        guard canCheckCodexSignIn else { return }
        await codex.refreshLoginStatus()
        guard !Task.isCancelled, canCheckCodexSignIn else { return }
        offerCodexSignInIfNeeded()
    }

    private func offerCodexSignInIfNeeded() {
        guard canOfferCodexSignIn, NSApplication.shared.isActive else { return }
        presentCodexSignIn()
    }

    private func presentCodexSignIn() {
        guard needsCodexSignIn else { return }
        appState.hasOfferedCodexSignIn = true
        showCodexSignIn = true
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Up late" : hour < 12 ? "Good morning"
                 : hour < 18 ? "Good afternoon" : "Good evening"
        let name = Self.macFirstName
        return name.isEmpty ? "\(part)." : "\(part), \(name)."
    }

    /// The user's first name from their macOS account — full name's first word (e.g. "Jesai
    /// Tarun" → "Jesai"), falling back to the (capitalized) short login name, then to nothing
    /// (the greeting just drops the name). Resolved once per launch; no account, no network.
    static let macFirstName: String = {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = full.split(separator: " ").first, !first.isEmpty { return String(first) }
        let login = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return login.isEmpty ? "" : login.capitalized
    }()

    private var analysisPopover: some View {
        AnalysisPopover(thingsUnderstood: thingsUnderstood, sources: sources,
                        modelMissing: modelMissing,
                        lastRun: lastRunLabel,
                        onAnalyze: { showAnalysis = false; onAnalyze() },
                        onPickWhatsApp: { showAnalysis = false; showWhatsAppPicker = true },
                        onPickIMessage: { showAnalysis = false; showIMessagePicker = true },
                        onPickGmail: { showAnalysis = false; showGmailConnect = true },
                        onPickAppleMail: { showAnalysis = false; showAppleMailPicker = true },
                        onPickCalendar: { showAnalysis = false; showCalendarConnect = true },
                        customRoots: customRoots)
            .preferredColorScheme(.dark)
    }

    /// The Analysis popover's "Last run:" value — the real last-cycle stamp (day spelled out once
    /// it's no longer today's); demo mode: the showcase string.
    private var lastRunLabel: String {
        guard deck == .real else { return Demo.lastRun }
        guard let d = UserDefaults.standard.object(forKey: ProactiveCycle.lastCycleKey) as? Date else {
            return "not yet"
        }
        return d.glanceStamp
    }

    // MARK: Suggestions — measured, spacious rows that gather into their dock

    private func overviewLayout(in size: CGSize) -> SidekickOverviewLayout {
        let entries = Array(model.entries.prefix(6))
        let width = SidekickOverviewLayout.width(for: size, count: entries.count)
        let heights = entries.map { entry -> CGFloat in
            guard let measured = cardSizes[entry.id], abs(measured.width - width) < 1 else { return 220 }
            return measured.height
        }
        return SidekickOverviewLayout(size: size, top: chromeHeight + 16,
            bottom: (overviewDockTop > 0 ? overviewDockTop : size.height - 184) - 10,
            heights: heights, requestedPage: overviewPage)
    }

    private func scatter(_ geo: GeometryProxy, layout: SidekickOverviewLayout) -> some View {
        let availableHeight = layout.region.height - SidekickOverviewLayout.pagerHeight
        let width = kbOnly ? BriefingCard.width : layout.cardWidth
        return ZStack {
            ForEach(Array(model.entries.prefix(6).enumerated()), id: \.element.id) { item in
                DealtCard(
                    entry: item.element,
                    slot: kbOnly ? CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.24) : layout.positions[item.offset],
                    dealFrom: CGPoint(x: geo.size.width / 2, y: chromeHeight - 20),
                    gathered: inConversation, gatherPoint: CGPoint(x: proactiveDockFrame.midX, y: proactiveDockFrame.midY),
                    scrollPull: overviewPull, interactiveGather: gatheringFromScroll,
                    cardWidth: width, onPage: kbOnly || layout.visibleRange.contains(item.offset),
                    order: item.offset % layout.capacity, reducedMotion: reducedMotion,
                    previewBodyLines: availableHeight < 185 ? 2 : (availableHeight < 220 ? 3 : 5),
                    previewTitleLines: availableHeight < 185 ? 1 : (availableHeight < 220 ? 2 : 3),
                    measured: { value in if cardSizes[item.element.id] != value { cardSizes[item.element.id] = value } },
                    fireDimmed: appState.commandCoordinator.run.isRunning
                        && item.element.action.map { ProactiveExecutor.isFireable($0) } == true,
                    onOffer: { model.run(item.element.id) },
                    onDetail: { openLetter(item.element.b) },
                    onOpenEnvelope: {
                        // The flap finishes asynchronously. Dismissing it during that
                        // animation must not reopen the removed card's letter.
                        guard let current = model.entry(item.element.id),
                              current.flight == nil else { return }
                        model.unsealWelcome()
                        openLetter(current.b)
                    },
                    onStop: { model.stopRun(item.element.id) },
                    onOpenConversation: showConversation,
                    onFling: { model.dismiss(item.element.id, toward: $0) })
            }
            if !kbOnly && !inConversation && layout.pageCount > 1 {
                HStack(spacing: 4) {
                    Button { turnSuggestions(to: layout.page - 1) } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Circle())
                    }.disabled(layout.page == 0).accessibilityLabel("Previous suggestions")
                    ForEach(0..<layout.pageCount, id: \.self) { page in
                        Button { turnSuggestions(to: page) } label: {
                            Capsule().fill(.white.opacity(page == layout.page ? 0.7 : 0.22))
                                .frame(width: page == layout.page ? 17 : 5, height: 5)
                                .frame(width: 28, height: 44).contentShape(Rectangle())
                        }.accessibilityLabel("Suggestions page \(page + 1) of \(layout.pageCount)")
                    }
                    Button { turnSuggestions(to: layout.page + 1) } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Circle())
                    }.disabled(layout.page + 1 == layout.pageCount).accessibilityLabel("Next suggestions")
                }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(SidekickStyle.secondary)
                .buttonStyle(SuggestionPageButtonStyle())
                .position(x: geo.size.width / 2, y: layout.region.maxY - SidekickOverviewLayout.pagerHeight / 2)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(!inConversation)
        .accessibilityHidden(inConversation)
    }

    private func turnSuggestions(to page: Int) {
        withAnimation(reducedMotion ? .easeOut(duration: 0.14) : .smooth(duration: 0.28)) { overviewPage = page }
    }

    // MARK: The empty state — the orb's one home

    private var emptyState: some View {
        VStack(spacing: 14) {
            SidekickMark(size: 48, illuminated: true).padding(.bottom, 20)
            Text("What can I take off your hands?")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.Ink.statusInk)
                .offset(y: -8)
            Text("Your context is already here. Pick up anywhere.")
                .font(.system(size: 13)).foregroundStyle(SidekickStyle.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -35)
        .allowsHitTesting(false)
    }

    // MARK: The knowledge-base-only preview state (free/go plans)

    /// The free-plan home: the orb and, where the cards would live, an honest, nicely-set
    /// note — the knowledge base is real and theirs; the LIVING Sentient needs Plus. Not a
    /// card: quiet centered text under the orb. The upgrade CTA carries this screen's one glow
    /// (the command bar is hidden here, so the jewelry budget is free). ALWAYS mounted on the
    /// kb-only home: while the gift envelope perches top-center the block rides compact and
    /// low (feature rows tucked away); once the letter is flung it blooms into the full,
    /// centered note. Once the claim reads Plus, it becomes the reset-and-rebuild celebration.
    private var previewState: some View {
        let envelopePresent = !model.entries.isEmpty
        return VStack(spacing: 0) {
            Orb(size: envelopePresent ? 84 : 104)
            if planUpgraded { upgradedNote } else { previewNote(compact: envelopePresent) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: envelopePresent ? 128 : -18)   // envelope above → the block waits lower
    }

    @ViewBuilder private func previewNote(compact: Bool) -> some View {
        Text("This is a preview of Sentient.")
            .display(24)
            .foregroundStyle(Theme.Ink.statusInk)
            .padding(.top, 16)
        Text("Your knowledge base is built, private, and yours to explore.\nThe living Sentient uses your ChatGPT Plus:")
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .padding(.top, 10)
        if !compact {   // the feature rows return once the envelope is gone
            VStack(alignment: .leading, spacing: 11) {
                previewRow("sunrise", "Mornings where things worth doing arrive already done")
                previewRow("command", "Sidekick anywhere: tap right \u{2318} and tell it what to do")
                previewRow("moon.stars", "A knowledge base that keeps learning, night after night")
            }
            .padding(.top, 20)
        }
        HStack(spacing: 14) {
            GlowButton(title: "Get ChatGPT Plus", systemImage: "arrow.up.forward",
                       glowIntensity: 0.5, action: { NSWorkspace.shared.open(CodexAuth.upgradeURL) })
                .frame(width: 250)
            QuietPillButton(title: "Reset Sentient…", action: openSystemPane)
        }
        .padding(.top, compact ? 22 : 28)
        Text("Upgraded? Reset rebuilds your knowledge with Gmail, Calendar, and the full engine.")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.faint)
            .padding(.top, 12)
    }

    /// The claim reads Plus now — the one job left is the reset, so it gets the glow.
    @ViewBuilder private var upgradedNote: some View {
        Text("You're on Plus. Time to go live.")
            .display(24)
            .foregroundStyle(Theme.Ink.statusInk)
            .padding(.top, 16)
        Text("Reset Sentient and it rebuilds your knowledge with Gmail and Calendar,\nthen keeps it alive: proactive mornings, Sidekick, learning night after night.")
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .padding(.top, 10)
        GlowButton(title: "Reset & Rebuild", systemImage: "arrow.clockwise",
                   glowIntensity: 0.5, action: openSystemPane)
            .frame(width: 250)
            .padding(.top, 28)
    }

    private func openSystemPane() {
        HomeWindowOpening.open(.settings, settingsPane: .system)
    }

    private func previewRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Ink.label)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.78))
        }
    }

    /// A discreet DEV TOOLS handle pinned bottom-right (DX continuity from the old home).
    /// Opens the DevToolsView sheet via RootView. Compile-gated out of Release entirely —
    /// this is DevToolsView's ONLY opener, so the sheet is unreachable in Release too.
    #if DEBUG
    private var devToolsOverlay: some View {
        Button(action: onShowDevTools) {
            HStack(spacing: 5) {
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 8.5))
                Text("DEV TOOLS")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.6)
            }
            .foregroundStyle(Theme.Ink.deepMuted)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(0.6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 22).padding(.bottom, 13)
    }
    #endif

    // MARK: Floor — the command bar + trust footer

    private var bottomDock: some View {
        VStack(spacing: 10) {
            if !kbOnly {
                SidekickComposer(coordinator: appState.commandCoordinator, presentation: presentation,
                                 isPresented: isPresented, onAccepted: showConversation)
                    .frame(maxWidth: 744)
            }
            HStack(spacing: 5) {
                Image(systemName: "lock.shield").font(.system(size: 9))
                Text("Private by design.").font(.system(size: 10))
            }.foregroundStyle(SidekickStyle.secondary.opacity(0.62))
        }
        .padding(.horizontal, 38).padding(.top, 8).padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    private var conversationPeek: some View {
        Button(action: showConversation) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(.white.opacity(0.055)).frame(width: 32, height: 32)
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(conversation.messages.isEmpty ? "Sidekick’s ready to take over your work." : "Continue the conversation")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(SidekickStyle.ink)
                    if let last = conversation.previewMessage {
                        Text(peekText(last.event))
                            .font(.system(size: 11)).foregroundStyle(SidekickStyle.secondary).lineLimit(1)
                    } else if conversation.messages.isEmpty {
                        Text("Ready to work across your computer. Just say the word.").font(.system(size: 11)).foregroundStyle(SidekickStyle.secondary)
                    }
                }
                Spacer(minLength: 0)
                if conversation.unreadCount > 0 {
                    Circle().fill(SidekickStyle.accent).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .top) { LinearGradient(colors: [.clear, .white.opacity(0.13), .clear], startPoint: .leading, endPoint: .trailing).frame(height: 1).padding(.horizontal, 22) }
            .frame(maxWidth: 722)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SidekickPressStyle())
        .accessibilityLabel(conversation.messages.isEmpty ? "Open Sidekick" : "Expand conversation history")
        .accessibilityIdentifier("sidekick.expandHistory")
    }

    private func peekText(_ event: SidekickConversationEvent) -> AttributedString {
        let text = String(event.text.prefix(600)).replacingOccurrences(of: "\n", with: " ")
        guard event.kind == .assistantMessage else { return AttributedString(text) }
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func showConversation() {
        withAnimation(SidekickStyle.motion(reducedMotion)) {
            gatheringFromScroll = false
            presentation.surface = .conversation
            overviewPull = 0
        }
    }

    private func followOverviewScroll(_ distance: Double) {
        guard !inConversation else { return }
        // A trackpad is direct manipulation. Do not ease behind the user's fingers.
        withTransaction(Transaction(animation: nil)) { overviewPull = distance }
    }

    private func settleOverviewScroll() {
        guard !inConversation else { return }
        withAnimation(reducedMotion ? .easeOut(duration: 0.14) : .spring(response: 0.34, dampingFraction: 0.86)) {
            overviewPull = 0
        }
    }

    private func dockOverviewFromScroll() {
        withAnimation(SidekickStyle.motion(reducedMotion)) {
            gatheringFromScroll = true
            presentation.surface = .conversation
            // Gathered geometry ignores this value, so the existing presentation position
            // flows straight into the dock rather than returning to the resting card slot.
            overviewPull = 0
        }
    }
    private func updateConversationVisibility() {
        let visible = isPresented && presentation.windowActive && inConversation
        if conversation.isVisible != visible { conversation.isVisible = visible }
        if visible && appState.commandCoordinator.run.recovery.isVisible { appState.commandCoordinator.run.recovery.dismiss() }
    }

    // MARK: The expanded letter (always-mounted layer; see the note at the top)

    private func letterLayer(_ geo: GeometryProxy) -> some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
                .onTapGesture { closeLetter() }
            if let b = letter {
                LetterView(briefing: b,
                           phase: model.entry(b.id)?.phase ?? .offer,
                           editable: model.entry(b.id)?.action != nil && b.draft != nil,   // real action card
                           // The LIVE content for THIS card (reflects any prior edit) — seeds the editor
                           // per briefing so a reused letter view never shows the previous card's draft.
                           liveDraft: model.entry(b.id)?.action?.preparedContent ?? b.draft ?? "",
                           liveRecipient: model.entry(b.id)?.action?.recipient ?? "",
                           fireDimmed: appState.commandCoordinator.run.isRunning
                               && model.entry(b.id)?.action.map { ProactiveExecutor.isFireable($0) } == true,
                           onCommitEdit: { model.applyEdit(b.id, content: $0, recipient: $1) },
                           onLiveEdit: { model.updateDraft(b.id, content: $0, recipient: $1) },
                           onOffer: {
                               closeLetter()
                               model.run(b.id)   // real card → fires for real; demo → theater
                           },
                           onClose: closeLetter)
                    .frame(width: 660)
                    .frame(maxHeight: geo.size.height * 0.86)
                    .scaleEffect(letterShown ? 1 : 0.94)
            }
        }
        .opacity(letterShown ? 1 : 0)
        .allowsHitTesting(letterShown)
    }

    private func openLetter(_ b: Briefing) {
        letter = b   // content lands while the layer is still invisible
        withAnimation(.easeInOut(duration: 0.32)) { letterShown = true }
    }

    private func closeLetter() {
        withAnimation(.easeInOut(duration: 0.26)) { letterShown = false }
    }
}

// MARK: - Top-bar nav item

private struct NavItem: View {
    var title: String? = nil
    var icon: String? = nil
    var dot: Color? = nil
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: title == nil ? 22 : 14.5, weight: .semibold))
                        .overlay(alignment: .bottomTrailing) {
                            if let dot {
                                Circle().fill(dot).frame(width: 4, height: 4)
                                    .overlay(Circle().stroke(Color.black, lineWidth: 1))
                                    .offset(x: 2, y: 2)
                            }
                        }
                }
                if let title { Text(title).font(.system(size: 13.5, weight: .medium)) }
            }
            .foregroundStyle(hover ? .white : Theme.Ink.bright)
            .padding(.horizontal, 11).frame(minHeight: 40)
            .background(Capsule().fill(.white.opacity(hover ? 0.07 : (title == nil ? 0.035 : 0))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// Generous targets with quiet, local feedback; page indicators stay visually small.
private struct SuggestionPageButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        SuggestionPageButtonBody(configuration: configuration, enabled: enabled)
    }
    private struct SuggestionPageButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let enabled: Bool
        @State private var hover = false
        var body: some View {
            configuration.label
                .foregroundStyle(.white.opacity(enabled ? (hover ? 0.95 : 0.65) : 0.22))
                .background(Capsule().fill(.white.opacity(enabled && hover ? 0.07 : 0)))
                .opacity(configuration.isPressed ? 0.65 : 1)
                .onHover { hover = $0 }
        }
    }
}

// MARK: - The model (deal · run · dismiss)

@MainActor @Observable
final class ForYouModel {
    struct Entry: Identifiable {
        let b: Briefing
        var action: PreparedAction?   // real card → the action to fire (mutable: edits update it); demo → nil
        var phase: BriefingPhase
        var dealt = false
        var flight: CGSize?           // set = the card is flying off-screen
        var liveLines: [String] = []  // real card → codex's live play-by-play
        var id: String { b.id }
    }

    var entries: [Entry] = []
    /// The app-lifetime command coordinator (HomeView sets it on appear) — the notch and the
    /// app-wide one-task lock. Every executable card adopts the shared conversation run;
    /// its setup, progress, questions and result all belong to chat.
    weak var coordinator: CommandCoordinator?
    /// Bumped per appearance — in-flight Tasks from a previous visit check it and bail,
    /// so a re-deal can never be mutated by stale theater/dismiss timers.
    private var visit = 0
    private var loadedDeck: BriefingDeck?
    private var loadedBriefing: Date?
    func ensureVisit(deck: BriefingDeck) {
        let stamp = UserDefaults.standard.object(forKey: ProactiveCycle.lastCycleKey) as? Date
        if loadedDeck != deck || (stamp != loadedBriefing && draftPreviews.isEmpty && coordinator?.run.isRunning != true) {
            beginVisit(deck: deck)
        }
    }
    /// Editor values waiting for the existing autosave. Keep them separate from the saved
    /// action so reading Sidekick context cannot change the editor's identity or its fields.
    private var draftPreviews: [String: (content: String, recipient: String)] = [:]

    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    /// Exactly the visible, pending real cards. Never resurrect dismissed cards from the
    /// saved deck or turn a demo/gift into an executable suggestion. Preserve display order.
    var sidekickActions: [PreparedAction] {
        entries.compactMap { entry in
            guard entry.dealt, entry.flight == nil, entry.phase == .offer,
                  let action = entry.action else { return nil }
            guard let draft = draftPreviews[entry.id] else { return action }
            return Self.replacing(action, content: draft.content, recipient: draft.recipient)
        }
    }

    private func update(_ id: String, _ mutate: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&entries[i])
    }

    /// A fresh visit. Real mode → the verified cards from the latest proactive run (empty → the orb's
    /// "I'm here to help."). Demo modes → the picked hard-coded deck (welcome re-sealed). Then the orb
    /// deals the cards with staggered springs from above the header.
    func beginVisit(deck: BriefingDeck) {
        loadedDeck = deck
        loadedBriefing = UserDefaults.standard.object(forKey: ProactiveCycle.lastCycleKey) as? Date
        visit += 1
        let v = visit
        draftPreviews.removeAll()
        switch deck {
        case .real:
            // Each card's accent is a shade from its method's color family, cycled by the card's
            // order among its method-mates — a deck of three computer-use cards gets three greens.
            var methodCounts: [PreparedAction.Method: Int] = [:]
            var built: [Entry] = (ProactiveResearch.latest()?.ready ?? []).map { action in
                let variant = methodCounts[action.method, default: 0]
                methodCounts[action.method] = variant + 1
                return Entry(b: Briefing(from: action, variant: variant), action: action, phase: .offer)
            }
            // The day-one welcome "gift" rides LAST as a sealed envelope (generated from the user's
            // own knowledge base by the proactive cycle; absent until that's run once) — last in
            // the deck = the bottom-right scatter slot, the envelope's fixed perch in every mode.
            if let gift = GiftLetter.latest() {
                built.append(Entry(b: Briefing(fromGiftMarkdown: gift), action: nil, phase: .sealed))
            }
            entries = built
        case .jesai, .launch:
            // Both demo decks keep their welcome card LAST for the same bottom-right perch.
            let cards = deck == .launch ? Briefing.launchDemo : Briefing.jesaiDemo
            entries = cards.map { Entry(b: $0, action: nil, phase: $0.kind == .welcome ? .sealed : .offer) }
        }
        for (i, e) in entries.enumerated() {
            if coordinator?.run.externalCardID == e.id { update(e.id) { $0.phase = .working(0) } }
            Task {
                try? await Task.sleep(for: .seconds(0.25 + Double(i) * 0.11))
                guard self.visit == v else { return }
                withAnimation(.spring(response: 0.62, dampingFraction: 0.74)) {
                    self.update(e.id) { $0.dealt = true }
                }
            }
        }
    }

    /// Uninstall's quiet home: invalidate theater timers and take every card off the table.
    func clear() {
        visit += 1
        entries.removeAll()
        draftPreviews.removeAll()
    }

    /// The welcome envelope opened: the card lives on un-sealed (the view opens the letter).
    func unsealWelcome() {
        guard let e = entries.first(where: { $0.b.kind == .welcome }) else { return }
        update(e.id) { $0.phase = .offer }
    }

    /// Fire the offer. A REAL card runs its action through the executor for real (live-streamed, with
    /// STOP); a demo card plays the briefing's hard-coded `workLog` theater for visual feedback.
    func run(_ id: String) {
        guard let e = entry(id), e.phase == .offer, e.b.offer != nil else { return }
        if let action = e.action {
            guard ProactiveExecutor.isFireable(action), coordinator?.run.isRunning != true else { return }
            // Include a live edit even if its debounced persistence has not fired yet.
            let reviewed = draftPreviews[id].map {
                Self.replacing(action, content: $0.content, recipient: $0.recipient)
            } ?? action
            runReal(id, reviewed)
            return
        }
        let v = visit

        Task {
            withAnimation(.easeInOut(duration: 0.3)) { update(id) { $0.phase = .working(0) } }
            for n in 1...e.b.workLog.count {
                try? await Task.sleep(for: .seconds(n == 1 ? 0.55 : Double.random(in: 0.7...1.15)))
                guard self.visit == v else { return }
                withAnimation(.easeOut(duration: 0.22)) { update(id) { $0.phase = .working(n) } }
            }
            try? await Task.sleep(for: .seconds(0.8))
            guard self.visit == v else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { update(id) { $0.phase = .done } }
            try? await Task.sleep(for: .seconds(3.0))
            guard self.visit == v else { return }
            dismiss(id, toward: CGSize(width: CGFloat.random(in: 250...520),
                                       height: -CGFloat.random(in: 350...560)))
        }
    }

    /// Persist the selected request and open chat before any setup or execution awaits.
    /// The app-owned run keeps the exact reviewed artifact and executor policy; the card
    /// is only a suggestion, never a second progress surface or owner of the running task.
    private func runReal(_ id: String, _ action: PreparedAction, retryContext: String = "") {
        let v = visit
        guard ProactiveExecutor.isFireable(action), let coordinator,
              coordinator.beginExternalRun(
                  caption: action.title,
                  request: SidekickCardContext.taskSnapshot(action),
                  retryContext: retryContext,
                  onRetry: { guidance in self.runReal(id, action, retryContext: retryContext + guidance) },
                  onStopRequest: { [weak self] in self?.stopRun(id) }) else { return }
        let adoptedRun = coordinator.run
        let generation = adoptedRun.runID
        let interaction = adoptedRun.interaction
        update(id) { $0.phase = .working(0); $0.liveLines = [] }
        adoptedRun.conversation.requestNavigation()
        InviteProgram.shared.record(.proactive)
        let task = Task {
            let progress: @Sendable (String) -> Void = { line in
                Task { @MainActor in adoptedRun.externalPush(line, runID: generation) }
            }
            let outcome: ProactiveExecutor.Outcome
            do {
                // Validate before setup, then let the executor recheck immediately before acting.
                if let issue = await ProactiveExecutor.mailEvidenceIssue(action) {
                    outcome = .notFireable(issue)
                } else {
                    try Task.checkCancellation()
                    try await ComputerUseGate.shared.waitUntilReady()
                    try Task.checkCancellation()
                    outcome = await SidekickInteraction.$current.withValue(interaction) {
                        await ProactiveExecutor.shared.fire(action, progress: progress)
                    }
                }
            } catch {
                guard adoptedRun.runID == generation else { return }
                let stopped = Task.isCancelled || error is CancellationError || error is ComputerUseGate.SetupCancelled
                let message = (error as? LocalizedError)?.errorDescription ?? "Sidekick couldn’t finish setup. Try again."
                if !stopped { Log("card setup failed — \(ErrorLabel(error))") }
                adoptedRun.completeExternal(stopped ? .stopped : .failed,
                    line: stopped ? "■ stopped" : "✗ \(message)", runID: generation)
                if self.visit == v { withAnimation { self.update(id) { $0.phase = .offer } } }
                return
            }
            guard adoptedRun.runID == generation else { return }
            guard !Task.isCancelled else {
                adoptedRun.completeExternal(.stopped, line: "■ stopped", runID: generation)
                if self.visit == v { withAnimation { self.update(id) { $0.phase = .offer } } }
                return
            }
            switch outcome {
            case .fired(let answer):
                self.removeFromLatest(id)
                adoptedRun.completeExternal(.success, line: "✓ done", finalText: answer, runID: generation)
                guard self.visit == v else { return }
                // The answer lives in chat. Retire the consumed suggestion without a second
                // completion presentation when the user reopens the proactive dock.
                self.entries.removeAll { $0.id == id }
                self.draftPreviews[id] = nil
            case .notFireable(let message), .failed(let message):
                adoptedRun.completeExternal(.failed, line: "✗ \(message)", runID: generation)
                if self.visit == v { withAnimation { self.update(id) { $0.phase = .offer } } }
            }
        }
        adoptedRun.ownExternalTask(task, cardID: id)
    }

    /// STOP a live real-card run: cancel the codex process (CodexCLI honors it) and return to offer.
    /// Reached from the card's STOP directly and, for an adopted run, from the notch/bar/hotkey via
    /// `onStopRequest` — the guard makes a second arrival a no-op (one cancel is enough; the
    /// adoption completes from the fire's unwind in runReal, never here).
    func stopRun(_ id: String) {
        if let run = coordinator?.run, run.isExternal, run.externalCardID == id {
            run.stop(); return
        }
    }

    /// Apply an edited draft + recipient to a card and persist them, so the fire sends exactly this
    /// content to exactly this "To:".
    func applyEdit(_ id: String, content: String, recipient: String) {
        update(id) {
            guard let old = $0.action else { return }
            $0.action = Self.replacing(old, content: content, recipient: recipient)
        }
        draftPreviews[id] = nil
        guard let result = ProactiveResearch.latest() else { return }
        ProactiveResearch.saveLatest(ReadyResult(
            ready: result.ready.map { $0.id == id ? Self.replacing($0, content: content, recipient: recipient) : $0 },
            dropped: result.dropped))
    }

    /// Keep the in-memory draft current on every edit; persistence remains debounced.
    /// A notch request during editing must see the same response and recipient as the user.
    func updateDraft(_ id: String, content: String, recipient: String) {
        guard entry(id)?.action != nil else { return }
        draftPreviews[id] = (content, recipient)
    }

    /// Drop a fired card from the persisted `latest` so a re-deal (next visit) won't show it again.
    private func removeFromLatest(_ id: String) {
        guard let result = ProactiveResearch.latest() else { return }
        ProactiveResearch.saveLatest(ReadyResult(ready: result.ready.filter { $0.id != id },
                                                 dropped: result.dropped))
    }

    /// A newly mounted Home observes the same app-owned task. Reconcile persisted results
    /// when it ends, even when its original view/model is no longer the visible one.
    func reconcileFinishedRuns() {
        guard let latest = ProactiveResearch.latest() else { return }
        let current = Set(latest.ready.map(\.id))
        entries.removeAll { $0.action != nil && !current.contains($0.id) }
        for entry in entries where entry.action != nil {
            if case .working = entry.phase { update(entry.id) { $0.phase = .offer } }
        }
    }

    /// A copy of a PreparedAction with new `preparedContent` + `recipient` (the rest unchanged).
    /// Copy the full value so content edits preserve routing, identity and operation metadata.
    private static func replacing(_ a: PreparedAction, content: String, recipient: String) -> PreparedAction {
        var copy = a
        copy.preparedContent = content
        copy.recipient = recipient
        return copy
    }

    /// Send a card flying along `v` (a flick's predicted translation), then reflow the scatter.
    func dismiss(_ id: String, toward v: CGSize) {
        guard entry(id) != nil else { return }
        let token = visit
        let mag = max(hypot(v.width, v.height), 1)
        let flight = CGSize(width: v.width / mag * 1200, height: v.height / mag * 1200)
        withAnimation(.easeIn(duration: 0.38)) { update(id) { $0.flight = flight } }
        Task {
            try? await Task.sleep(for: .seconds(0.42))
            guard self.visit == token else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
                entries.removeAll { $0.id == id }
                draftPreviews[id] = nil
            }
        }
    }
}

// MARK: - One dealt card: readable spread + dock morph + drag/flick physics

private struct DealtCard: View {
    let entry: ForYouModel.Entry
    let slot: CGPoint
    let dealFrom: CGPoint
    var gathered = false
    var gatherPoint = CGPoint.zero
    var scrollPull = 0.0
    var interactiveGather = false
    var cardWidth: CGFloat = BriefingCard.width
    var onPage = true
    var order = 0
    var reducedMotion = false
    var previewBodyLines = 5
    var previewTitleLines = 3
    var measured: (CGSize) -> Void = { _ in }
    var fireDimmed: Bool = false       // one task at a time: another task is running → the CTA waits
    var onOffer: () -> Void
    var onDetail: () -> Void
    var onOpenEnvelope: () -> Void
    var onStop: () -> Void
    var onOpenConversation: () -> Void
    var onFling: (CGSize) -> Void

    @State private var drag: CGSize = .zero

    private var pullProgress: CGFloat {
        reducedMotion ? 0 : min(1, max(0, scrollPull / SidekickOverviewScrollPolicy.preciseThreshold))
    }
    private var pulledSlot: CGPoint {
        CGPoint(x: slot.x, y: slot.y - (reducedMotion ? 0 : scrollPull))
    }

    var body: some View {
        BriefingCard(briefing: entry.b, phase: entry.phase,
                     onOffer: onOffer, onDetail: onDetail, onOpenEnvelope: onOpenEnvelope,
                     liveLines: entry.liveLines, onStop: entry.action != nil ? onStop : nil,
                     onOpenConversation: entry.action != nil ? onOpenConversation : nil,
                     fireDimmed: fireDimmed, cardWidth: cardWidth,
                     previewBodyLines: previewBodyLines, previewTitleLines: previewTitleLines,
                     onDismiss: { onFling(CGSize(width: -100, height: -300)) })
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { measured($0) }
            .rotationEffect(.degrees(gathered ? 0 : drag.width / 30))
            .scaleEffect(gathered && !reducedMotion ? 0.035 : (entry.dealt ? 1 - 0.08 * pullProgress : 0.92))
            .position(gathered && !reducedMotion ? gatherPoint : (entry.dealt ? pulledSlot : dealFrom))
            .blur(radius: reducedMotion ? 0 : (gathered ? 3 : (onPage ? 0 : 4)))
            .animation(reducedMotion ? .easeOut(duration: 0.14) : .spring(response: interactiveGather ? 0.42 : 0.60, dampingFraction: 0.86)
                .delay(interactiveGather ? 0 : Double(order) * 0.025), value: gathered)
            .offset(x: drag.width + (entry.flight?.width ?? 0),
                    y: drag.height + (entry.flight?.height ?? 0))
            .opacity(gathered || !onPage || entry.flight != nil ? 0 : (entry.dealt ? 1 : 0))
            .animation(reducedMotion ? .easeOut(duration: 0.14) : .easeOut(duration: 0.18)
                .delay(gathered ? (interactiveGather ? 0.12 : 0.25 + Double(order) * 0.025) : 0), value: gathered)
            .animation(.easeInOut(duration: reducedMotion ? 0.14 : 0.22), value: onPage)
            .accessibilityElement(children: .contain)
            .allowsHitTesting(onPage && !gathered && entry.dealt && entry.flight == nil)
            .accessibilityHidden(!onPage || gathered || !entry.dealt || entry.flight != nil)
            .accessibilityIdentifier("sidekick.suggestion.\(entry.id)")
            // simultaneous, NOT .gesture: a plain ancestor DragGesture can win macOS click
            // arbitration and eat the card's buttons ("read it again", the envelope).
            .simultaneousGesture(DragGesture(minimumDistance: 12)
                .onChanged { drag = $0.translation }
                .onEnded { g in
                    let p = g.predictedEndTranslation
                    if hypot(p.width, p.height) > 320 {
                        onFling(p)                       // flick → the model flies it away
                    } else {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { drag = .zero }
                    }
                })
    }

}

// MARK: - The typeset letter (expanded view)

private struct LetterView: View {
    let briefing: Briefing
    let phase: BriefingPhase
    var editable: Bool = false                       // real card with a draft → the draft is editable
    var liveDraft: String = ""                       // THIS card's current content (seeds the editor)
    var liveRecipient: String = ""                   // THIS card's "To:" (seeds the recipient field); "" = no recipient
    var fireDimmed: Bool = false                     // one task at a time: another task is running → the CTA waits
    var onCommitEdit: (String, String) -> Void = { _, _ in }   // persist (edited draft, edited recipient) → what fires
    var onLiveEdit: (String, String) -> Void = { _, _ in }     // current editor values for Sidekick context
    var onOffer: () -> Void
    var onClose: () -> Void

    @State private var copied = false
    @State private var editedDraft = ""        // the live editor text
    @State private var savedDraft = ""         // the last COMMITTED text — drift from editedDraft = unsaved edits
    @State private var editedRecipient = ""    // the live "To:" text
    @State private var savedRecipient = ""     // the last COMMITTED "To:"
    @State private var saveTask: Task<Void, Never>?   // in-flight debounced auto-save
    @State private var everEdited = false      // the user has edited THIS opening — flips "✎ Editable" to the save status
    @State private var giftSaved = false       // the welcome letter's keepsake PNG landed on the Desktop

    /// This card sends a message to someone, so it shows an editable "To:" (the model filled a recipient).
    private var hasRecipient: Bool { !liveRecipient.isEmpty }

    /// A research briefing (it reads as a letter, not a working draft) — the only expanded note that
    /// gets the letter-paper dress. The gift keeps its own; drafts stay working documents.
    private var isResearchNote: Bool { briefing.kind != .welcome && briefing.letter != nil }

    /// The card's page: dog-eared letter paper for a research note, the plain rounded card otherwise.
    private var pageShape: AnyShape {
        isResearchNote ? AnyShape(LetterPaper())
                       : AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Auto-save is pending (unsaved edits still settling). Drives the ambient "Saving…" status.
    private var isDirty: Bool { editable && (editedDraft != savedDraft || editedRecipient != savedRecipient) }

    /// Commit the current draft + recipient so they persist + are what fires. Cancels any pending debounce.
    private func commitEdit() {
        saveTask?.cancel()
        onCommitEdit(editedDraft, editedRecipient)
        savedDraft = editedDraft
        savedRecipient = editedRecipient
    }

    /// Debounced auto-save: commit ~0.3s after the user stops typing (live, without write-spam).
    private func scheduleAutoSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            commitEdit()
        }
    }

    private func editChanged() {
        guard editable else { return }
        onLiveEdit(editedDraft, editedRecipient)
        if isDirty {
            everEdited = true
            scheduleAutoSave()
        } else {
            saveTask?.cancel()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                MonoCaps(briefing.kicker, size: 10, tracking: 2.2, color: briefing.accent)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Ink.label)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)   // Esc closes
                .padding(.trailing, isResearchNote ? 24 : 0)   // clear of the paper's folded corner
            }
            Text(briefing.title)
                .font(.system(size: 30, design: .serif)).foregroundStyle(.white)
                .padding(.top, 8)
            if isResearchNote {   // the letterhead rule: a hairline of the card's accent, fading out
                LinearGradient(colors: [briefing.accent.opacity(0.5), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
                    .padding(.top, 14)
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    paragraphs
                    if let draft = briefing.draft { draftBlock(draft) }
                }
                .padding(.top, 18)
                .padding(.bottom, 4)
            }

            if let offer = briefing.offer, phase == .offer {
                OfferButton(label: offer, accent: briefing.accent, action: {
                    if editable { commitEdit() }   // fire what's shown — commit any unsaved edit first
                    onOffer()
                })
                    .disabled(fireDimmed)
                    .opacity(fireDimmed ? 0.45 : 1)
                    .animation(.easeInOut(duration: 0.25), value: fireDimmed)
                    .padding(.top, 16)
            }
            if briefing.kind == .welcome { giftFooter.padding(.top, 16) }
        }
        .padding(28)
        // A research note is a piece of letter paper: the page's top-right corner is dog-eared
        // (LetterPaper cuts it, LetterPaperFold lies on the page). Every other card keeps the
        // plain rounded card.
        .background(Theme.Ink.cardBG, in: pageShape)
        .overlay(alignment: .topTrailing) { if isResearchNote { LetterPaperFold() } }
        .overlay {
            let border = briefing.kind == .welcome ? BriefingCard.welcomeGradient
                : LinearGradient(colors: [briefing.accent.opacity(0.45), .white.opacity(0.06)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)
            if isResearchNote {
                LetterPaper().strokeBorder(border, lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(border, lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 40, y: 18)
        // Seed the editor from THIS card's live content — on first appear AND every time a different
        // briefing opens. The letter layer is always-mounted and REUSED across cards (stable identity),
        // so .onAppear fires only once; without the .onChange a second card would show the first card's
        // draft. editedDraft + savedDraft start equal (a freshly-opened card has no unsaved edits).
        .onAppear { editedDraft = liveDraft; savedDraft = liveDraft; editedRecipient = liveRecipient; savedRecipient = liveRecipient }
        // A different card opened: cancel any pending auto-save (it belongs to the OLD card's closure)
        // and reseed. edited + saved start equal — a freshly-opened card has no unsaved edits.
        .onChange(of: briefing.id) { _, _ in
            saveTask?.cancel(); editedDraft = liveDraft; savedDraft = liveDraft
            editedRecipient = liveRecipient; savedRecipient = liveRecipient; copied = false
            giftSaved = false; everEdited = false
        }
        // Every keystroke (draft OR recipient) reschedules the debounced commit, so edits persist without a Save click.
        .onChange(of: editedDraft) { _, _ in editChanged() }
        .onChange(of: editedRecipient) { _, _ in editChanged() }
        .onDisappear { saveTask?.cancel() }
    }

    /// The letter body — the shared editorial-Markdown renderer (LetterBody), so the expanded letter
    /// and the saved share image draw the exact same thing.
    private var paragraphs: some View {
        LetterBody(text: briefing.letter ?? briefing.body, accent: briefing.accent,
                   neutral: isResearchNote)
    }

    /// The welcome letter's keepsake row: "Save to Desktop" (a poster PNG of the gift, revealed in
    /// Finder so sharing is one drag) + the quiet why ("it will be cleared soon" — the gift retires
    /// when the next cycle replaces the deck).
    private var giftFooter: some View {
        HStack(spacing: 14) {
            if giftSaved {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 10.5, weight: .semibold))
                    Text("Saved to your Desktop").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Theme.Ink.green)
                .padding(.vertical, 8)
            } else {
                OfferButton(label: "Save to Desktop", accent: briefing.accent,
                            icon: "square.and.arrow.down", action: saveGift)
            }
            Text("Your gift will be cleared from the home screen soon.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.label)
            Spacer(minLength: 0)
        }
    }

    private func saveGift() {
        do {
            let url = try GiftShareImage.save(briefing: briefing)
            withAnimation(.easeInOut(duration: 0.2)) { giftSaved = true }
            NSWorkspace.shared.activateFileViewerSelecting([url])   // sharing = one drag from here
        } catch {
            Log("GiftShareImage: save failed — \(ErrorLabel(error))")
        }
    }

    /// "Subject: X" opening line + the body after it; nil when the draft doesn't open with one.
    /// The draft STRING stays the single verbatim artifact — this only splits it for display.
    private static func splitSubject(_ draft: String) -> (subject: String, body: String)? {
        let lines = draft.components(separatedBy: "\n")
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.lowercased().hasPrefix("subject:") else { return nil }
        let subject = String(first.dropFirst("subject:".count)).trimmingCharacters(in: .whitespaces)
        var rest = Array(lines.dropFirst())
        while rest.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { rest.removeFirst() }
        return (subject, rest.joined(separator: "\n"))
    }

    /// The Subject field, derived from `editedDraft` — edits recombine into the one draft string,
    /// so auto-save, Copy, and what fires all keep seeing the complete artifact.
    private var draftSubject: Binding<String> {
        Binding(get: { Self.splitSubject(editedDraft)?.subject ?? "" },
                set: { editedDraft = "Subject: \($0)\n\n\(Self.splitSubject(editedDraft)?.body ?? "")" })
    }

    /// The body editor's text — the part after the Subject line when one exists, the whole draft otherwise.
    private var draftBody: Binding<String> {
        Binding(get: { Self.splitSubject(editedDraft)?.body ?? editedDraft },
                set: { newBody in
                    if let subject = Self.splitSubject(editedDraft)?.subject {
                        editedDraft = "Subject: \(subject)\n\n\(newBody)"
                    } else {
                        editedDraft = newBody
                    }
                })
    }

    private func draftBlock(_ draft: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
                .fill(LinearGradient(colors: [briefing.accent, briefing.accent.opacity(0.15)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 14) {
                    MonoCaps(briefing.draftLabel ?? "Draft", size: 9, tracking: 2.0, color: Theme.Ink.label)
                    Spacer()
                    // The edit affordance + auto-save status, in one quiet slot. Fresh card:
                    // "✎ Editable" (an invitation — "Saved" before any edit means nothing to a
                    // user). Typing: "Saving…" (muted). Edit landed: "✓ Saved" (green — YOUR
                    // change is what fires). Edits persist on their own; this is never a button.
                    if editable {
                        HStack(spacing: 5) {
                            if isDirty {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9.5))
                                Text("Saving…").font(.system(size: 11))
                            } else if everEdited {
                                Image(systemName: "checkmark").font(.system(size: 9.5))
                                Text("Saved").font(.system(size: 11))
                            } else {
                                Image(systemName: "pencil").font(.system(size: 9.5))
                                Text("Editable").font(.system(size: 11))
                            }
                        }
                        .foregroundStyle(!isDirty && everEdited ? Theme.Ink.green : Theme.Ink.label)
                        .animation(.easeInOut(duration: 0.2), value: isDirty)
                        .animation(.easeInOut(duration: 0.2), value: everEdited)
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(editable ? editedDraft : draft, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9.5))
                            Text(copied ? "Copied" : "Copy").font(.system(size: 11))
                        }
                        .foregroundStyle(copied ? Theme.Ink.green : Theme.Ink.bright)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                // "To:" — WHO this message goes to. Shown only for cards that send to a person; editable
                // (the executor sends to exactly this), so a wrong recipient is visible and correctable.
                if hasRecipient {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        MonoCaps("To", size: 9, tracking: 2.0, color: Theme.Ink.label)
                        if editable {
                            TextField("", text: $editedRecipient)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.92))
                                .tint(briefing.accent)
                        } else {
                            Text(editedRecipient.isEmpty ? liveRecipient : editedRecipient)
                                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.92))
                                .textSelection(.enabled)
                        }
                    }
                    Rectangle().fill(.white.opacity(0.07)).frame(height: 1)   // hairline between "who" and "what"
                }
                // "Subject:" — an email draft opens with a Subject line; it composes like a real
                // email (its own field row) while the draft string that FIRES stays one verbatim
                // artifact (subject edits recombine into it). Drafts without one are untouched.
                let split = Self.splitSubject(editable ? editedDraft : draft)
                if let split {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        MonoCaps("Subject", size: 9, tracking: 2.0, color: Theme.Ink.label)
                        if editable {
                            TextField("", text: draftSubject)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.92))
                                .tint(briefing.accent)
                        } else {
                            Text(split.subject)
                                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.92))
                                .textSelection(.enabled)
                        }
                    }
                    Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                }
                // A computer-use PLAN speaks in the machine's voice: mono step lines, airy leading,
                // step numbers in quiet grey — PlanEditor (an NSTextView bridge; SwiftUI's TextEditor
                // can't style ranges and falls back to Courier for mono besides). Messages, emails,
                // and events keep the composer prose. Both ride the same draftBody binding.
                if editable {
                    if briefing.isPlan {
                        PlanEditor(text: draftBody, accent: briefing.accent)
                    } else {
                        TextEditor(text: draftBody)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineSpacing(4)
                            .tint(briefing.accent)
                            .scrollContentBackground(.hidden)
                            .scrollIndicators(.never)   // the legacy always-on scroller is clutter; the wheel still scrolls
                            .frame(minHeight: 56, maxHeight: 300)   // a short message shouldn't float in empty box
                    }
                } else {
                    Text(split?.body ?? draft)
                        .font(briefing.isPlan ? Font(NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
                                              : .system(size: 13))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineSpacing(briefing.isPlan ? 9 : 4)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}

// MARK: - Demo data (the home's own showcase strings — cards live in Briefing.jesaiDemo/.launchDemo)

private enum Demo {
    static let lastRun = "3:41 AM"
}

#Preview("Home — the suggestions") {
    HomeView(thingsUnderstood: 3339,
             sources: .init(files: true, whatsapp: true, imessage: true, notes: true),
             modelMissing: false)
        .frame(width: 1180, height: 880)
}

#Preview("Home — launch demo deck") {
    HomeView(thingsUnderstood: 3339,
             sources: .init(files: true, whatsapp: true, imessage: true, notes: true),
             modelMissing: false,
             deck: .launch)
        .frame(width: 1180, height: 880)
}

#Preview("Home — knowledge-base-only (free plan)") {
    HomeView(thingsUnderstood: 1704,
             sources: .init(files: true),
             modelMissing: false,
             deck: .real,
             previewKBOnly: true,
             previewUpgraded: false)
        .frame(width: 1180, height: 880)
}

#Preview("Home — kb-only, upgrade detected") {
    HomeView(thingsUnderstood: 1704,
             sources: .init(files: true),
             modelMissing: false,
             deck: .real,
             previewKBOnly: true,
             previewUpgraded: true)
        .frame(width: 1180, height: 880)
}

#Preview("Research letter") {
    let sample = """
    ## Who she is
    **Priya Iyer, Partner at Northbeam Capital**; leads early-stage consumer AI. Ex-product at Dropbox. Writes $500K to $1.5M first checks.

    ## Lead with
    - Traction: **2,500 waitlist signups in 24 hours** from one Reddit post, zero marketing spend.
    - Moat: the full on-device pipeline runs on real data today; cloud clones burn roughly $200 per user just to read a life in.
    - Momentum: YC S26 and a16z Speedrun interviews, and a live term conversation with Premise.vc.

    ## Likely questions
    1. Why won't Apple do this? Walled garden: Apple Intelligence can't read WhatsApp or act across apps; **Sentient does both**.
    2. Business model? Free consumer wedge; AGPL dual-licensing for enterprise later.
    3. Round status? Use the Premise interest as gentle heat, not a hammer.

    ## Decide before the call
    Whether you'd take a $500K check on the terms Premise floated, or hold for a priced round after launch.
    """
    let action = PreparedAction(
        title: "Prep notes for tomorrow's call with Priya",
        method: .research, target: "", urgency: .medium,
        dueDate: "Tuesday, July 14, 10:30 AM", status: .confirmed,
        verification: "", cardSummary: "", preparedContent: sample,
        executionRecipe: "none", buttonText: "", detailLabel: "read the brief",
        sources: [], reviewNote: "")
    return ZStack { Color.black.ignoresSafeArea()
        LetterView(briefing: Briefing(from: action), phase: .offer,
                   onOffer: {}, onClose: {})
            .frame(width: 560)
            .padding(40)
    }
}

#Preview("Computer plan letter") {
    let steps = """
    1. Open the browser to canva.com/settings/billing-and-teams (already logged in).
    2. Under Canva Pro, click Cancel trial.
    3. If asked for a reason, pick 'I don't use it enough'.
    4. Decline any pause, discount, or free-month offers.
    5. Confirm the cancellation.
    6. Verify the page shows Pro ending July 15 with no renewal.
    """
    let action = PreparedAction(
        title: "Cancel Canva Pro before Wednesday's charge",
        method: .computer, target: "Canva", urgency: .high,
        dueDate: "Wednesday, July 15", status: .updated,
        verification: "",
        cardSummary: "Your Canva Pro trial converts to $15/month on Wednesday; this cancels it from your logged-in account before the charge.",
        preparedContent: steps,
        executionRecipe: "Start in the user's default browser at canva.com/settings/billing-and-teams.",
        buttonText: "Cancel it before the charge?", detailLabel: "read the plan",
        sources: [], reviewNote: "")
    return ZStack { Color.black.ignoresSafeArea()
        LetterView(briefing: Briefing(from: action), phase: .offer,
                   editable: true, liveDraft: steps,
                   onOffer: {}, onClose: {})
            .frame(width: 560)
            .padding(40)
    }
}

#Preview("Gift letter") {
    let sample = """
    # The System Builder's Map

    I just analyzed your entire digital life to understand you. So much stands out :)
    ### Something you might not know about yourself

    **Your real pattern is turning recurring ambiguity into reusable systems.**
    In IB Math AA HL you built decision-tree guides; for Jacob you made timetables, exam calendars, and custom AI prompts. Sentient OS is the same reflex at startup scale.

    ## Also noticed

    ✦ Your breakout projects keep starting from Apple-shaped constraints: Writing Tools as an Apple Intelligence port, iPadOS on iPhone, and Sentient's on-device layer.
    ✦ You care about assistants having the right operating manual: you maintain tailored prompts across ChatGPT, Claude, Gemini, and Perplexity.
    ✦ Your public credibility is unusually concrete: 30,000+ Writing Tools users, 28+ publications, WIRED coverage, and a 2025 UMass Tech Challenge win.

    -- Your Sentient
    """
    return ZStack { Color.black.ignoresSafeArea()
        LetterView(briefing: Briefing(fromGiftMarkdown: sample), phase: .offer,
                   onOffer: {}, onClose: {})
            .frame(width: 560)
            .padding(40)
    }
}
