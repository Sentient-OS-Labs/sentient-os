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
//  Analysis ▾ and Your AIs ▾ (glanceable popovers, HomePopovers.swift) · Knowledge and
//  Settings (their own windows). Status lives inside Analysis, never cluttering the home.
//
//  WHEN THERE ARE NO CARDS, the living Orb blooms into the vacated center with "I'm here to
//  help." — the orb appears ONLY here (its one home), turning the empty state into a launchpad
//  that hands your eye straight to the command bar. (Retired ConstellationHome; harvested orb +
//  sources + AIs + vault stats into this surface and its popovers.)
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
    var realCards: Bool = false        // true → show real proactive cards from latest(); false → the demo deck
    var onAnalyze: () -> Void = {}
    var onShowDevTools: () -> Void = {}

    @Environment(\.openWindow) private var openWindow
    @Environment(AppState.self) private var appState

    @State private var model = ForYouModel()
    // The letter layer is ALWAYS mounted and driven purely by opacity/scale from plain
    // @State — view INSERTION (`if let` overlays) can miss a redraw on macOS hidden-titlebar
    // windows (the "appears only after a resize" bug); opacity changes cannot.
    @State private var letter: Briefing?
    @State private var letterShown = false
    @State private var showAnalysis = false
    @State private var showYourAIs = false
    @State private var showWhatsAppPicker = false
    @State private var showIMessagePicker = false
    @State private var showGmailConnect = false
    @State private var showCalendarConnect = false

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
                    if model.entries.isEmpty {
                        emptyState.transition(.scale(scale: 0.86).combined(with: .opacity))
                    }
                    bottomDock
                    chrome                     // on top → the nav stays clickable
                    devToolsOverlay
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
            model.beginVisit(realCards: realCards)
        }
        .onChange(of: realCards) { _, v in model.beginVisit(realCards: v) }   // toggle flip → re-deal
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
        .sheet(isPresented: $showGmailConnect) { GmailConnectSheet() }
        .sheet(isPresented: $showCalendarConnect) { CalendarConnectSheet() }
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
            NavItem(title: "Analysis", dot: Theme.Ink.mint) { showAnalysis = true }
                .popover(isPresented: $showAnalysis) { analysisPopover }
            NavItem(title: "Your AIs") { showYourAIs = true }
                .popover(isPresented: $showYourAIs) { yourAIsPopover }
            NavItem(title: "Knowledge") { openWindow(id: KnowledgeView.windowID) }
            NavItem(icon: "gearshape") { openWindow(id: SettingsView.windowID) }
        }
        .padding(.horizontal, 30).padding(.top, 18)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(greeting)
                .font(.system(size: 30, design: .serif).italic())
                .foregroundStyle(Theme.Ink.statusInk)
            MonoCaps(readLine, size: 9.5, tracking: 2.2, color: Theme.Ink.deepMuted)
        }
        .padding(.leading, 30)
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
    /// Avadhani" → "Jesai"), falling back to the (capitalized) short login name, then to nothing
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
                        syncedLabel: syncedLabel, pending: realCards ? 0 : Demo.pending,
                        onAnalyze: { showAnalysis = false; onAnalyze() },
                        onPickWhatsApp: { showAnalysis = false; showWhatsAppPicker = true },
                        onPickIMessage: { showAnalysis = false; showIMessagePicker = true },
                        onPickGmail: { showAnalysis = false; showGmailConnect = true },
                        onPickCalendar: { showAnalysis = false; showCalendarConnect = true },
                        customRoots: customRoots)
            .preferredColorScheme(.dark)
    }

    /// Real mode: the actual last-cycle stamp; demo mode: the showcase string.
    private var syncedLabel: String {
        guard realCards else { return Demo.synced }
        guard let d = UserDefaults.standard.object(forKey: ProactiveCycle.lastCycleKey) as? Date else {
            return "Not yet analyzed"
        }
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return "Synced · \(f.string(from: d))"
    }

    private var yourAIsPopover: some View {
        YourAIsPopover()   // self-contained: toggles the real MCP mirror + copies the link / system prompt
            .preferredColorScheme(.dark)
    }

    // MARK: The scatter (the suggestion cards)

    private func scatter(_ geo: GeometryProxy) -> some View {
        let slots = Self.slots(count: model.entries.count, in: geo.size)
        return ZStack {
            ForEach(Array(model.entries.enumerated()), id: \.element.id) { item in
                DealtCard(
                    entry: item.element,
                    slot: slots[min(item.offset, slots.count - 1)],
                    dealFrom: CGPoint(x: geo.size.width / 2, y: -160),
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
    /// the zone.)
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
                .font(.system(size: 22, design: .serif).italic())
                .foregroundStyle(Theme.Ink.statusInk)
                .offset(y: -8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -8)
        .allowsHitTesting(false)
    }

    /// A discreet DEV TOOLS handle pinned bottom-right (DX continuity from the old home; the
    /// Phase-6 Release strip re-hides it). Opens the DevToolsView sheet via RootView.
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

    // MARK: Floor — the command bar + trust footer

    private var bottomDock: some View {
        VStack(spacing: 16) {
            PromptBar(onSend: { text, mode in appState.commandCoordinator.submit(text, mode: mode, source: .promptBar) },
                      onStop: { appState.commandCoordinator.stop() },
                      isRunning: appState.commandCoordinator.run.isRunning,
                      statusLine: appState.commandCoordinator.run.statusLine)
            HStack(spacing: 8) {
                Image(systemName: "shield").font(.system(size: 11)).foregroundStyle(Theme.Ink.label)
                Text("Private by design. Your files never leave this Mac.")
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
                           onCommitEdit: { model.applyEdit(b.id, content: $0) },
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
                if let dot { Circle().fill(dot).frame(width: 5, height: 5).opacity(0.9) }
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .medium)) }
                if let title { Text(title).font(.system(size: 12.5, weight: .medium)) }
            }
            .foregroundStyle(hover ? .white : Theme.Ink.body)
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
    /// "I'm here to help."). Demo mode → the investor deck (welcome re-sealed). Then the orb deals the
    /// cards with staggered springs from above the header.
    func beginVisit(realCards: Bool) {
        visit += 1
        let v = visit
        runTasks.values.forEach { $0.cancel() }; runTasks.removeAll()
        if realCards {
            var built: [Entry] = []
            // The day-one welcome "gift" leads the deck as a sealed envelope (generated from the user's
            // own knowledge base by the proactive cycle; absent until that's run once).
            if let gift = GiftLetter.latest() {
                built.append(Entry(b: Briefing(fromGiftMarkdown: gift), action: nil, phase: .sealed))
            }
            let ready = ProactiveResearch.latest()?.ready ?? []
            built.append(contentsOf: ready.map { Entry(b: Briefing(from: $0), action: $0, phase: .offer) })
            entries = built
        } else {
            entries = Briefing.demo.map { Entry(b: $0, action: nil, phase: $0.kind == .welcome ? .sealed : .offer) }
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

    /// The welcome envelope opened: the card lives on un-sealed (the view opens the letter).
    func unsealWelcome() {
        guard let e = entries.first(where: { $0.b.kind == .welcome }) else { return }
        update(e.id) { $0.phase = .offer }
    }

    /// Fire the offer. A REAL card runs its action through the executor for real (live-streamed, with
    /// STOP); a demo card plays the briefing's hard-coded `workLog` theater for visual feedback.
    func run(_ id: String) {
        guard let e = entry(id), e.phase == .offer, e.b.offer != nil else { return }
        if let action = e.action { runReal(id, action); return }   // real card → fire for real
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
    private func runReal(_ id: String, _ action: PreparedAction) {
        let v = visit
        update(id) { $0.phase = .working(0); $0.liveLines = [] }
        let task = Task {
            let progress: @Sendable (String) -> Void = { line in
                Task { @MainActor in
                    guard self.visit == v else { return }
                    self.appendLine(id, line)
                }
            }
            let outcome = await ProactiveExecutor.shared.fire(action, progress: progress)
            guard self.visit == v, !Task.isCancelled else { return }
            switch outcome {
            case .fired:
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { self.update(id) { $0.phase = .done } }
                self.removeFromLatest(id)
                try? await Task.sleep(for: .seconds(2.6))
                guard self.visit == v else { return }
                self.dismiss(id, toward: CGSize(width: CGFloat.random(in: 250...520),
                                                height: -CGFloat.random(in: 350...560)))
            case .notFireable(let m), .failed(let m):
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
    func stopRun(_ id: String) {
        runTasks[id]?.cancel(); runTasks[id] = nil
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

    /// Apply an edited draft to a card (its `preparedContent`) and persist it, so the fire sends it.
    func applyEdit(_ id: String, content: String) {
        update(id) {
            guard let old = $0.action else { return }
            $0.action = Self.replacingContent(old, with: content)
        }
        guard var result = ProactiveResearch.latest() else { return }
        result = ReadyResult(ready: result.ready.map { $0.id == id ? Self.replacingContent($0, with: content) : $0 },
                             dropped: result.dropped)
        ProactiveResearch.saveLatest(result)
    }

    /// Drop a fired card from the persisted `latest` so a re-deal (next visit) won't show it again.
    private func removeFromLatest(_ id: String) {
        guard let result = ProactiveResearch.latest() else { return }
        ProactiveResearch.saveLatest(ReadyResult(ready: result.ready.filter { $0.id != id },
                                                 dropped: result.dropped))
    }

    /// A copy of a PreparedAction with new `preparedContent` (the rest unchanged).
    private static func replacingContent(_ a: PreparedAction, with content: String) -> PreparedAction {
        PreparedAction(title: a.title, method: a.method, target: a.target, urgency: a.urgency,
                       dueDate: a.dueDate, status: a.status, verification: a.verification,
                       cardSummary: a.cardSummary, preparedContent: content, executionRecipe: a.executionRecipe,
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
                     liveLines: entry.liveLines, onStop: entry.action != nil ? onStop : nil)
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
    var onCommitEdit: (String) -> Void = { _ in }    // persist the edited draft (so it's what fires)
    var onOffer: () -> Void
    var onClose: () -> Void

    @State private var copied = false
    @State private var editedDraft = ""        // the live editor text
    @State private var savedDraft = ""         // the last COMMITTED text — drift from editedDraft = unsaved edits

    /// There are unsaved edits to commit.
    private var isDirty: Bool { editable && editedDraft != savedDraft }

    /// Commit the current draft so it persists + is what fires.
    private func commitEdit() {
        onCommitEdit(editedDraft)
        savedDraft = editedDraft
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
            }
            Text(briefing.title)
                .font(.system(size: 30, design: .serif)).foregroundStyle(.white)
                .padding(.top, 8)

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
                    .padding(.top, 16)
            }
        }
        .padding(28)
        .background(Theme.Ink.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(briefing.kind == .welcome ? BriefingCard.welcomeGradient
                          : LinearGradient(colors: [briefing.accent.opacity(0.45), .white.opacity(0.06)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                          lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 40, y: 18)
        // Seed the editor from THIS card's live content — on first appear AND every time a different
        // briefing opens. The letter layer is always-mounted and REUSED across cards (stable identity),
        // so .onAppear fires only once; without the .onChange a second card would show the first card's
        // draft. editedDraft + savedDraft start equal (a freshly-opened card has no unsaved edits).
        .onAppear { editedDraft = liveDraft; savedDraft = liveDraft }
        .onChange(of: briefing.id) { _, _ in editedDraft = liveDraft; savedDraft = liveDraft; copied = false }
    }

    /// The letter body, rendered line-by-line. Supports the editorial Markdown subset our letters use:
    /// `##`/`###` section headings, `✦ ` accent bullets, a closing sign-off line, and plain paragraphs
    /// (with `**bold**` inline). A blank line is a paragraph break. (`# H1` is promoted to the card
    /// title upstream, but we still render one defensively.)
    @ViewBuilder
    private var paragraphs: some View {
        let lines = (briefing.letter ?? briefing.body).components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                letterBlock(raw.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    @ViewBuilder
    private func letterBlock(_ line: String) -> some View {
        if line.isEmpty {
            Color.clear.frame(height: 2)                              // a paragraph break
        } else if line.hasPrefix("### ") {
            Text(Self.inline(String(line.dropFirst(4))))             // soulful subhead (serif italic)
                .font(.system(size: 16, design: .serif).italic())
                .foregroundStyle(.white.opacity(0.92))
                .padding(.top, 6)
        } else if line.hasPrefix("## ") {
            MonoCaps(String(line.dropFirst(3)).uppercased(), size: 10, tracking: 2.2,
                     color: briefing.accent.opacity(0.95))           // section whisper (mono-caps)
                .padding(.top, 12)
        } else if line.hasPrefix("# ") {
            Text(Self.inline(String(line.dropFirst(2))))             // a stray title, defensive
                .font(.system(size: 22, design: .serif)).foregroundStyle(.white)
                .padding(.top, 4)
        } else if let bullet = Self.bulletText(line) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("✦").font(.system(size: 12)).foregroundStyle(briefing.accent)
                Text(Self.inline(bullet))
                    .font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.84)).lineSpacing(4.5)
            }
        } else if Self.isSignoff(line) {
            Text(Self.inline(line))                                  // "-- Your Sentient"
                .font(.system(size: 13, design: .serif).italic())
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 10)
        } else {
            Text(Self.inline(line))
                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.84)).lineSpacing(5)
        }
    }

    /// "✦ …" (tolerating a stray word-joiner / nbsp the model sometimes slips in) → the bullet's text;
    /// nil if the line isn't a bullet.
    private static func bulletText(_ line: String) -> String? {
        guard line.first == "✦" else { return nil }
        let rest = line.dropFirst().drop { $0 == " " || $0 == "\t" || $0 == "\u{2060}" || $0 == "\u{00A0}" }
        return rest.isEmpty ? nil : String(rest)
    }

    /// A closing line like "-- Your Sentient" / "— your Sentient" (line-start only, so inline em-dashes
    /// mid-paragraph aren't mistaken for a sign-off).
    private static func isSignoff(_ line: String) -> Bool {
        line.hasPrefix("--") || line.hasPrefix("—") || line.hasPrefix("– ")
    }

    /// Inline-markdown parse (**bold** etc.) so letters can carry a skimmable bold rail.
    private static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
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
                    if editable {
                        Image(systemName: "pencil").font(.system(size: 8.5)).foregroundStyle(briefing.accent.opacity(0.9))
                    }
                    Spacer()
                    // Save — explicit so the user KNOWS the edit is persisted + is what fires. "Save"
                    // (accent) when there are unsaved edits; "Saved" (mint, disabled) when in sync.
                    if editable {
                        Button(action: commitEdit) {
                            HStack(spacing: 5) {
                                Image(systemName: isDirty ? "square.and.arrow.down" : "checkmark").font(.system(size: 9.5))
                                Text(isDirty ? "Save" : "Saved").font(.system(size: 11, weight: isDirty ? .semibold : .regular))
                            }
                            .foregroundStyle(isDirty ? briefing.accent : Theme.Ink.mint)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!isDirty)
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
                        .foregroundStyle(copied ? Theme.Ink.mint : Theme.Ink.bright)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if editable {
                    TextEditor(text: $editedDraft)
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.92)).lineSpacing(4)
                        .tint(briefing.accent)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90, maxHeight: 300)
                } else {
                    Text(draft)
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.88)).lineSpacing(4)
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

// MARK: - Demo data (the home's own showcase strings — cards live in Briefing.demo)

private enum Demo {
    static let synced = "Synced · 3:41 AM"
    static let pending = 214
}

#Preview("Home — the suggestions") {
    HomeView(thingsUnderstood: 3339,
             sources: .init(files: true, whatsapp: true, imessage: true, notes: true),
             modelMissing: false)
        .frame(width: 1180, height: 880)
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
