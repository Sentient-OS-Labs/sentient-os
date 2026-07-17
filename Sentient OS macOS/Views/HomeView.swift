//
//  HomeView.swift
//  Sentient OS macOS
//
//  THE HOME — the app's main surface, and the product itself: Proactive Intelligence. You
//  open Sentient straight into this. The morning run (1 min after wake) leaves a scatter of
//  SUGGESTION CARDS here — each one the AI already did the work for ("Should I send it for
//  you?"); clicking is the user's fire (Privacy Constitution: we offer, they fire). A command
//  bar at the foot lets you ask it to DO anything (computer use).
//
//  The chrome is deliberately quiet: a wordmark, and four doors at the top-right —
//  Analysis ▾ and Give AIs Knowledge ▾ (glanceable popovers, HomePopovers.swift) · Knowledge and
//  Settings (their own windows). Status lives inside Analysis, never cluttering the home.
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
//  Doc: Documentation/Home — Proactive Intelligence (For You).md · cards + the CodexCLI seam:
//  Briefing.swift.
//

import SwiftUI
import AppKit

struct HomeView: View {
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

    @State private var model = ForYouModel()
    // The letter layer is ALWAYS mounted and driven purely by opacity/scale from plain
    // @State — view INSERTION (`if let` overlays) can miss a redraw on macOS hidden-titlebar
    // windows (the "appears only after a resize" bug); opacity changes cannot.
    @State private var letter: Briefing?
    @State private var letterShown = false
    @State private var showAnalysis = false
    @State private var showShareKnowledge = false
    @State private var showWhatsAppPicker = false
    @State private var showIMessagePicker = false
    @State private var showGmailConnect = false
    @State private var showCalendarConnect = false
    /// The morning-after caution (last night's scheduled run hit a known snag) — nil = no banner.
    @State private var caution: OvernightCaution.Record?
    /// The LIVE health issue (essential perms · codex · computer use) — HealthCaution's ladder;
    /// nil = healthy or muted. Outranks the morning-after caution in the banner slot.
    @State private var liveIssue: HealthCaution.Issue?

    // Chat selections the Analysis popover's WhatsApp/iMessage chips pick into (same keys as SourceSelection).
    @AppStorage("dbg.whatsapp.chats") private var whatsappCSV = ""
    @AppStorage("dbg.run.whatsapp")   private var runWhatsApp = false
    @AppStorage("dbg.imessage.chats") private var imessageCSV = ""
    @AppStorage("dbg.run.imessage")   private var runIMessage = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.bg.ignoresSafeArea()

                Group {
                    scatter(geo)
                    if kbOnly {
                        // The preview note is ALWAYS on the free home — the gift envelope (the
                        // only card this home can ever hold) perches above it, never in front:
                        // the pitch must not hide behind a fling.
                        previewState
                    } else if model.entries.isEmpty {
                        emptyState.transition(.scale(scale: 0.86).combined(with: .opacity))
                    }
                    bottomDock
                    chrome                     // on top → the nav stays clickable
                    cautionBanner              // the morning-after caution, in the blank top-right
                    #if DEBUG
                    devToolsOverlay
                    #endif
                }
                .blur(radius: letterShown ? 7 : 0)
                .opacity(letterShown ? 0.4 : 1)

                letterLayer(geo)
            }
        }
        .frame(minWidth: 1040, minHeight: 800)
        .background(Theme.bg)
        .onAppear {                        // every appearance starts fresh: sealed envelope, full deal
            letter = nil
            letterShown = false
            model.coordinator = appState.commandCoordinator
            if !appState.isUninstalling { model.beginVisit(deck: deck) }
            planUpgraded = previewUpgraded ?? (kbOnly && CodexAuth.currentPlan()?.tier == .full)
            caution = OvernightCaution.latest()
            probeHealth()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may just have fixed something in System Settings (or a cycle cleared last
            // night's caution) — re-probe so the banner melts away the moment they return.
            withAnimation(.easeInOut(duration: 0.25)) { caution = OvernightCaution.latest() }
            probeHealth()
        }
        .onChange(of: deck) { _, v in
            // The teardown's defaults wipe re-publishes the deck key — never re-deal mid-uninstall.
            guard !appState.isUninstalling else { return }
            model.beginVisit(deck: v)                               // mode flip → re-deal
        }
        .onChange(of: appState.isUninstalling) { _, tearing in
            // Uninstall began → take every card off the table; a cancel deals them back in.
            if tearing { withAnimation(.easeInOut(duration: 0.3)) { model.clear() } }
            else { model.beginVisit(deck: deck) }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: model.entries.isEmpty)
        .sheet(isPresented: $showWhatsAppPicker) {
            ChatPicker(sourceName: "WhatsApp", loadChats: { try WhatsAppSource().listChats() },
                       initialSelection: Set(whatsappCSV.split(separator: ",").map(String.init))) { sel in
                whatsappCSV = sel.sorted().joined(separator: ","); runWhatsApp = !sel.isEmpty
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
    }

    // MARK: Chrome — the top-bar nav + the editorial greeting

    private var chrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            header.padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            OrbMark(size: 17)
            Text("Sentient OS")
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            NavItem(title: "Analysis", dot: Theme.Ink.green) { showAnalysis = true }
                .popover(isPresented: $showAnalysis) { analysisPopover }
            NavItem(title: "Knowledge") { openWindow(id: KnowledgeView.windowID) }
            NavItem(title: "Give AIs Knowledge") { showShareKnowledge = true }
                .popover(isPresented: $showShareKnowledge) { shareKnowledgePopover }
            NavItem(icon: "gearshape") { openWindow(id: SettingsView.windowID) }
        }
        .padding(.horizontal, 30).padding(.top, 18)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(greeting)
                .display(27)
                .foregroundStyle(Theme.Ink.statusInk)
            MonoCaps(readLine, size: 9.5, tracking: 2.2, color: Theme.Ink.deepMuted)
        }
        .padding(.leading, 30)
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
    // the session (a lower rung may then surface), while the amber ✕ clears the record.

    private var cautionBanner: some View {
        Group {
            if let issue = liveIssue {
                CautionCapsule(message: issue.message, accent: Theme.Ink.red, showsSettings: true,
                               onOpenSettings: openHealthSettings,
                               onDismiss: {
                                   HealthCaution.dismiss(issue)
                                   withAnimation(.easeInOut(duration: 0.25)) { liveIssue = nil }
                                   probeHealth()   // the muted kind may have been hiding a lower rung
                               })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let caution {
                CautionCapsule(message: caution.kind.message,
                               showsSettings: caution.kind == .loggedOut,
                               onOpenSettings: openHealthSettings,
                               onDismiss: {
                                   OvernightCaution.clear()
                                   withAnimation(.easeInOut(duration: 0.25)) { self.caution = nil }
                               })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing, 30).padding(.top, 64)
    }

    /// Land directly on Permissions & Health — every banner's fix lives there; never strand the
    /// user on the default pane.
    private func openHealthSettings() {
        SettingsView.requestedPane = .health
        openWindow(id: SettingsView.windowID)
    }

    /// Run HealthCaution's ladder off the main thread of thought: cheap sync probes, plus a
    /// cached codex login check (forced fresh while a codex banner is up, so a fix clears on the
    /// very next foreground). Quiet on pitch decks (demo cards must never share the stage with a
    /// red capsule) and on the free home (HealthCaution guards kbOnly too — defense in depth).
    private func probeHealth() {
        guard deck == .real, !kbOnly else { return }
        Task {
            let issue = await HealthCaution.probe(forceCodexRecheck: liveIssue?.kindKey == "codex")
            withAnimation(.easeInOut(duration: 0.25)) { liveIssue = issue }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Up late" : hour < 12 ? "Good morning"
                 : hour < 18 ? "Good afternoon" : "Good evening"
        let name = Self.macFirstName
        return name.isEmpty ? "\(part)." : "\(part), \(name)."
    }

    /// The mono whisper under the greeting — the REAL lifetime count of things analyzed
    /// (`thingsUnderstood`, from LifetimeStats), not a hardcoded number.
    private var readLine: String {
        let n = thingsUnderstood
        guard n > 0 else { return "Ready to read your life" }
        return "I've read \(n.formatted()) thing\(n == 1 ? "" : "s") so far"
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

    private var shareKnowledgePopover: some View {
        ShareKnowledgePopover()   // self-contained: toggles the real MCP mirror + copies the link / system prompt
            .preferredColorScheme(.dark)
    }

    // MARK: The scatter (the suggestion cards)

    private func scatter(_ geo: GeometryProxy) -> some View {
        // kb-only: the lone gift envelope gets a fixed top-center perch (the preview note owns
        // the center beneath it). Any other population falls back to the normal scatter.
        let slots = (kbOnly && model.entries.count == 1)
            ? [CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.24)]
            : Self.slots(count: model.entries.count, in: geo.size)
        return ZStack {
            ForEach(Array(model.entries.enumerated()), id: \.element.id) { item in
                DealtCard(
                    entry: item.element,
                    slot: slots[min(item.offset, slots.count - 1)],
                    dealFrom: CGPoint(x: geo.size.width / 2, y: -160),
                    fireDimmed: appState.commandCoordinator.run.isRunning
                        && item.element.action?.method == .computer,
                    onOffer: { model.run(item.element.id) },
                    onDetail: { openLetter(item.element.b) },
                    onOpenEnvelope: {
                        model.unsealWelcome()
                        openLetter(item.element.b)
                    },
                    onStop: { model.stopRun(item.element.id) },
                    onFling: { model.dismiss(item.element.id, toward: $0) })
            }
        }
    }

    /// Organic slot positions per population, laid into the CARD ZONE — the band between the
    /// top chrome (nav + greeting) and the command-bar dock. The two rows cluster toward the
    /// vertical centre with a tight, deliberate gap (one composed spread, not two stranded rows)
    /// and a gentle stagger. Pinned, not gridded; reflows as cards leave. (y-fraction is WITHIN
    /// the zone.) Convention: the LAST slot of every population is the rightmost/lowest one —
    /// the welcome gift envelope always rides last in the deck, so that slot is its perch.
    private static func slots(count: Int, in size: CGSize) -> [CGPoint] {
        let top = size.height * 0.20
        let bottom = size.height * 0.86
        let h = bottom - top
        let f: [(CGFloat, CGFloat)]
        switch count {
        case 6...: f = [(0.21, 0.24), (0.50, 0.20), (0.79, 0.20),
                        (0.21, 0.72), (0.50, 0.70), (0.79, 0.66)]
        case 5:    f = [(0.22, 0.22), (0.50, 0.14), (0.78, 0.19), (0.34, 0.68), (0.66, 0.68)]
        case 4:    f = [(0.28, 0.22), (0.72, 0.22), (0.30, 0.68), (0.70, 0.68)]
        case 3:    f = [(0.24, 0.46), (0.50, 0.32), (0.76, 0.46)]
        case 2:    f = [(0.35, 0.44), (0.65, 0.44)]
        default:   f = [(0.50, 0.42)]
        }
        return f.map { CGPoint(x: $0.0 * size.width, y: top + $0.1 * h) }
    }

    // MARK: The empty state — the orb's one home

    private var emptyState: some View {
        VStack(spacing: 14) {
            Orb(size: 118)
            Text("I'm here to help.")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.Ink.statusInk)
                .offset(y: -8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -8)
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
                previewRow("command", "Sidekick anywhere: hold right \u{2318} and just say it")
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
        SettingsView.requestedPane = .system
        openWindow(id: SettingsView.windowID)
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
        VStack(spacing: 16) {
            if !kbOnly {   // knowledge-base-only mode: computer use has no quota — no command bar
                PromptBar(onSend: { text, mode in appState.commandCoordinator.submit(text, mode: mode, source: .promptBar) },
                          onStop: { appState.commandCoordinator.stop() },
                          isRunning: appState.commandCoordinator.run.isRunning,
                          statusLine: appState.commandCoordinator.run.statusLine)
            }
            HStack(spacing: 8) {
                Image(systemName: "shield").font(.system(size: 11)).foregroundStyle(Theme.Ink.label)
                Text("Private by design.")
                    .font(.system(size: 12)).foregroundStyle(Theme.Ink.label)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 16)
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
                               && model.entry(b.id)?.action?.method == .computer,
                           onCommitEdit: { model.applyEdit(b.id, content: $0, recipient: $1) },
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

// MARK: - The caution capsule (rendered by cautionBanner — amber for the morning-after event,
// red for a live HealthCaution issue)

private struct CautionCapsule: View {
    let message: String
    var accent: Color = Theme.Ink.amber
    var showsSettings = false
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HealthDot(color: accent)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Ink.statusInk)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if showsSettings {
                SettingsPillButton(title: "Open Settings", action: onOpenSettings)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Ink.label)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: 480, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(accent.opacity(0.28), lineWidth: 1))
    }
}

#Preview("Caution capsules") {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(alignment: .trailing, spacing: 14) {
            CautionCapsule(message: OvernightCaution.Kind.loggedOut.message, showsSettings: true,
                           onOpenSettings: {}, onDismiss: {})
            CautionCapsule(message: OvernightCaution.Kind.noInternet.message,
                           onOpenSettings: {}, onDismiss: {})
            CautionCapsule(message: OvernightCaution.Kind.usageLimit.message,
                           onOpenSettings: {}, onDismiss: {})
            CautionCapsule(message: HealthCaution.Issue.permissions([.fullDiskAccess]).message,
                           accent: Theme.Ink.red, showsSettings: true,
                           onOpenSettings: {}, onDismiss: {})
            CautionCapsule(message: HealthCaution.Issue.permissions([.fullDiskAccess, .launchAtLogin]).message,
                           accent: Theme.Ink.red, showsSettings: true,
                           onOpenSettings: {}, onDismiss: {})
            CautionCapsule(message: HealthCaution.Issue.codexSignedOut.message,
                           accent: Theme.Ink.red, showsSettings: true,
                           onOpenSettings: {}, onDismiss: {})
            CautionCapsule(message: HealthCaution.Issue.computerUseBroken(payloadGone: true).message,
                           accent: Theme.Ink.red, showsSettings: true,
                           onOpenSettings: {}, onDismiss: {})
        }
        .padding(40)
    }
    .frame(width: 620, height: 560)
    .preferredColorScheme(.dark)
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
                if let dot { Circle().fill(dot).frame(width: 5, height: 5).opacity(0.9) }
                if let icon { Image(systemName: icon).font(.system(size: 17, weight: .bold)) }
                if let title { Text(title).font(.system(size: 13.5, weight: .medium)) }
            }
            .foregroundStyle(hover ? .white : Theme.Ink.bright)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(hover ? 0.06 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
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
    /// app-wide one-task lock. A computer-use card fire ADOPTS its run (lighting the notch and
    /// locking out Sidekick/the bar/other cards); gmail/calendar/research fires ignore it.
    weak var coordinator: CommandCoordinator?
    /// Bumped per appearance — in-flight Tasks from a previous visit check it and bail,
    /// so a re-deal can never be mutated by stale theater/dismiss timers.
    private var visit = 0
    /// Live real-card fires, keyed by card id, so a card's STOP can cancel exactly its run.
    private var runTasks: [String: Task<Void, Never>] = [:]

    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    private func update(_ id: String, _ mutate: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&entries[i])
    }

    /// A fresh visit. Real mode → the verified cards from the latest proactive run (empty → the orb's
    /// "I'm here to help."). Demo modes → the picked hard-coded deck (welcome re-sealed). Then the orb
    /// deals the cards with staggered springs from above the header.
    func beginVisit(deck: BriefingDeck) {
        visit += 1
        let v = visit
        runTasks.values.forEach { $0.cancel() }; runTasks.removeAll()
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
            Task {
                try? await Task.sleep(for: .seconds(0.25 + Double(i) * 0.11))
                guard self.visit == v else { return }
                withAnimation(.spring(response: 0.62, dampingFraction: 0.74)) {
                    self.update(e.id) { $0.dealt = true }
                }
            }
        }
    }

    /// Uninstall's quiet home: cancel any running theater and take every card off the table.
    func clear() {
        visit += 1
        runTasks.values.forEach { $0.cancel() }; runTasks.removeAll()
        entries.removeAll()
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
        if let action = e.action {   // real card → fire for real (behind the first-use permission gate)
            // The app-wide one-task lock (computer use only): while ANY task owns the run — a
            // Sidekick/command-bar run or another card — a new fire can't start (the CTA is
            // dimmed; this is the backstop for a click that lands anyway). Gmail/Calendar
            // connector writes and research are exempt: quiet card-only, concurrent is fine.
            if action.method == .computer, coordinator?.run.isRunning == true {
                Log("card fire blocked — a task is already running (one at a time)")
                return
            }
            if ComputerUseGate.shared.intercept({ [weak self] in self?.runReal(id, action) }) { return }
            runReal(id, action)
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

    /// Fire a REAL card: route its action through the executor, stream codex's play-by-play into the
    /// card (replacing the demo theater), and on success fly it away + drop it from the persisted set
    /// so a re-deal won't show it again. `ProactiveExecutor.fire` reads `action.preparedContent`, so a
    /// draft the user edited in the letter is exactly what gets sent.
    ///
    /// A computer-use fire is also ADOPTED by the notch (`beginExternalRun`): the shared run lights
    /// up (the one-task lock engages), the card's lines tee into it, and every exit — success,
    /// failure, ANY stop — completes the adoption exactly once, here, when `fire` unwinds (it
    /// always returns, even cancelled). `beginExternalRun`'s refusal doubles as the re-check for a
    /// fire the permission gate held while another task started.
    private func runReal(_ id: String, _ action: PreparedAction) {
        let v = visit
        let external = action.method == .computer
        if external {
            guard let coordinator,
                  coordinator.beginExternalRun(
                      caption: entry(id)?.b.title ?? "Working on your Mac…",
                      onStopRequest: { [weak self] in self?.stopRun(id) })
            else { Log("card fire blocked at launch — a task already owns the run"); return }
        }
        update(id) { $0.phase = .working(0); $0.liveLines = [] }
        let task = Task {
            let progress: @Sendable (String) -> Void = { line in
                Task { @MainActor in
                    guard self.visit == v else { return }
                    self.appendLine(id, line)                                  // the card (raw)
                    if external { self.coordinator?.run.externalPush(line) }   // the notch (cleaned)
                }
            }
            let outcome = await ProactiveExecutor.shared.fire(action, progress: progress)
            let adopted = external ? self.coordinator?.run : nil
            guard self.visit == v, !Task.isCancelled else {
                adopted?.completeExternal(.stopped, line: "■ stopped")   // any stop/re-deal lands here
                return
            }
            switch outcome {
            case .fired:
                adopted?.completeExternal(.success, line: "✓ done")
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { self.update(id) { $0.phase = .done } }
                self.removeFromLatest(id)
                try? await Task.sleep(for: .seconds(2.6))
                guard self.visit == v else { return }
                self.dismiss(id, toward: CGSize(width: CGFloat.random(in: 250...520),
                                                height: -CGFloat.random(in: 350...560)))
            case .notFireable(let m), .failed(let m):
                adopted?.completeExternal(.failed, line: "✗ \(String(m.prefix(160)))")
                self.appendLine(id, "✗ \(m)")
                try? await Task.sleep(for: .seconds(1.4))
                guard self.visit == v else { return }
                withAnimation { self.update(id) { $0.phase = .offer } }   // back to offer — edit + retry
            }
            self.runTasks[id] = nil
        }
        runTasks[id] = task
    }

    /// STOP a live real-card run: cancel the codex process (CodexCLI honors it) and return to offer.
    /// Reached from the card's STOP directly and, for an adopted run, from the notch/bar/hotkey via
    /// `onStopRequest` — the guard makes a second arrival a no-op (one cancel is enough; the
    /// adoption completes from the fire's unwind in runReal, never here).
    func stopRun(_ id: String) {
        guard let task = runTasks[id] else { return }
        task.cancel(); runTasks[id] = nil
        withAnimation { update(id) { $0.liveLines.append("■ stopped"); $0.phase = .offer } }
    }

    /// Append one live line to a real card (dedup consecutive duplicates; cap the buffer).
    private func appendLine(_ id: String, _ line: String) {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        update(id) {
            guard $0.liveLines.last != t else { return }   // item.started + .completed can repeat
            $0.liveLines.append(t)
            if $0.liveLines.count > 40 { $0.liveLines.removeFirst($0.liveLines.count - 40) }
        }
    }

    /// Apply an edited draft + recipient to a card and persist them, so the fire sends exactly this
    /// content to exactly this "To:".
    func applyEdit(_ id: String, content: String, recipient: String) {
        update(id) {
            guard let old = $0.action else { return }
            $0.action = Self.replacing(old, content: content, recipient: recipient)
        }
        guard let result = ProactiveResearch.latest() else { return }
        ProactiveResearch.saveLatest(ReadyResult(
            ready: result.ready.map { $0.id == id ? Self.replacing($0, content: content, recipient: recipient) : $0 },
            dropped: result.dropped))
    }

    /// Drop a fired card from the persisted `latest` so a re-deal (next visit) won't show it again.
    private func removeFromLatest(_ id: String) {
        guard let result = ProactiveResearch.latest() else { return }
        ProactiveResearch.saveLatest(ReadyResult(ready: result.ready.filter { $0.id != id },
                                                 dropped: result.dropped))
    }

    /// A copy of a PreparedAction with new `preparedContent` + `recipient` (the rest unchanged).
    private static func replacing(_ a: PreparedAction, content: String, recipient: String) -> PreparedAction {
        PreparedAction(title: a.title, method: a.method, target: a.target, urgency: a.urgency,
                       dueDate: a.dueDate, status: a.status, verification: a.verification,
                       cardSummary: a.cardSummary, preparedContent: content, executionRecipe: a.executionRecipe,
                       recipient: recipient,
                       buttonText: a.buttonText, detailLabel: a.detailLabel, sources: a.sources,
                       reviewNote: a.reviewNote)
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
            }
        }
    }
}

// MARK: - One dealt card: position + jitter + drag/flick physics

private struct DealtCard: View {
    let entry: ForYouModel.Entry
    let slot: CGPoint
    let dealFrom: CGPoint
    var fireDimmed: Bool = false       // one task at a time: another task is running → the CTA waits
    var onOffer: () -> Void
    var onDetail: () -> Void
    var onOpenEnvelope: () -> Void
    var onStop: () -> Void
    var onFling: (CGSize) -> Void

    @State private var drag: CGSize = .zero

    var body: some View {
        let j = Self.jitter(entry.id)
        BriefingCard(briefing: entry.b, phase: entry.phase,
                     onOffer: onOffer, onDetail: onDetail, onOpenEnvelope: onOpenEnvelope,
                     liveLines: entry.liveLines, onStop: entry.action != nil ? onStop : nil,
                     fireDimmed: fireDimmed)
            .rotationEffect(.degrees(j.rot + drag.width / 24))
            .scaleEffect(entry.dealt ? 1 : 0.7)
            .position(entry.dealt ? CGPoint(x: slot.x + j.dx, y: slot.y + j.dy) : dealFrom)
            .offset(x: drag.width + (entry.flight?.width ?? 0),
                    y: drag.height + (entry.flight?.height ?? 0))
            .opacity(entry.flight != nil ? 0 : (entry.dealt ? 1 : 0))
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

    /// Stable per-card scatter personality (offset + rotation) from the briefing id.
    private static func jitter(_ id: String) -> (dx: CGFloat, dy: CGFloat, rot: Double) {
        var h = UInt64(5381)
        for b in id.utf8 { h = (h &* 33) ^ UInt64(b) }
        let r1 = Double(h % 1000) / 1000
        let r2 = Double((h >> 10) % 1000) / 1000
        let r3 = Double((h >> 20) % 1000) / 1000
        return (CGFloat(r1 * 20 - 10), CGFloat(r2 * 16 - 8), r3 * 5.2 - 2.6)
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
        .onChange(of: editedDraft) { _, _ in if isDirty { everEdited = true; scheduleAutoSave() } }
        .onChange(of: editedRecipient) { _, _ in if isDirty { everEdited = true; scheduleAutoSave() } }
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
            Log("GiftShareImage: save failed — \(error)")
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
