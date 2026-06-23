//
//  HomeView.swift
//  Sentient OS macOS
//
//  THE HOME — the app's main surface, and the product itself: Proactive Intelligence. You
//  open Sentient straight into this. The morning run (1 min after wake) leaves a scatter of
//  SUGGESTION CARDS here — each one the AI already did the work for ("Should I send it for
//  you?"); clicking is the user's fire (Privacy Constitution: we offer, they fire). A command
//  bar at the foot lets you ask it to DO anything (computer / browser use).
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
    var analyzeEnabled: Bool = false
    var modelMissing: Bool = false
    var onAnalyze: () -> Void = {}
    var onShowDevTools: () -> Void = {}

    @Environment(\.openWindow) private var openWindow

    @State private var model = ForYouModel()
    // The letter layer is ALWAYS mounted and driven purely by opacity/scale from plain
    // @State — view INSERTION (`if let` overlays) can miss a redraw on macOS hidden-titlebar
    // windows (the "appears only after a resize" bug); opacity changes cannot.
    @State private var letter: Briefing?
    @State private var letterShown = false
    @State private var showAnalysis = false
    @State private var showYourAIs = false

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
            model.beginVisit()
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: model.entries.isEmpty)
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
            NavItem(title: "Knowledge") { openWindow(id: DatabaseView.windowID) }
            NavItem(icon: "gearshape") { openWindow(id: SettingsView.windowID) }
        }
        .padding(.horizontal, 30).padding(.top, 18)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(greeting)
                .font(.system(size: 30, design: .serif).italic())
                .foregroundStyle(Theme.Ink.statusInk)
            MonoCaps(Demo.readLine, size: 9.5, tracking: 2.2, color: Theme.Ink.deepMuted)
        }
        .padding(.leading, 30)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Up late" : hour < 12 ? "Good morning"
                 : hour < 18 ? "Good afternoon" : "Good evening"
        return "\(part), \(Demo.name)."
    }

    private var analysisPopover: some View {
        AnalysisPopover(thingsUnderstood: thingsUnderstood, sources: sources,
                        analyzeEnabled: analyzeEnabled, modelMissing: modelMissing,
                        syncedLabel: Demo.synced, pending: Demo.pending,
                        onAnalyze: { showAnalysis = false; onAnalyze() })
            .preferredColorScheme(.dark)
    }

    private var yourAIsPopover: some View {
        YourAIsPopover(notesRead: Demo.aiNotesRead, logLine: Demo.aiLog,
                       onConnect: { showYourAIs = false; openWindow(id: ConnectAIsView.windowID) })
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
            PromptBar { text, mode in
                // The command bar fires the user's OWN typed task through codex — computer use OR
                // browser use, where the mode is just a word swapped into the prompt. See
                // ForYouModel.fireCommand / commandPrompt.
                Task.detached(priority: .utility) { await ForYouModel.fireCommand(text, mode: mode) }
            }
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
                           onOffer: {
                               closeLetter()
                               model.run(b.id)   // the theater plays out on the card
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
        var phase: BriefingPhase
        var dealt = false
        var flight: CGSize?       // set = the card is flying off-screen
        var id: String { b.id }
    }

    var entries: [Entry] = []
    /// Bumped per appearance — in-flight Tasks from a previous visit check it and bail,
    /// so a re-deal can never be mutated by stale theater/dismiss timers.
    private var visit = 0

    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    private func update(_ id: String, _ mutate: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&entries[i])
    }

    /// A fresh visit: full demo deck, welcome re-sealed, letter closed — then the orb deals
    /// the cards with staggered springs from above the header.
    func beginVisit() {
        visit += 1
        let v = visit
        entries = Briefing.demo.map { Entry(b: $0, phase: $0.kind == .welcome ? .sealed : .offer) }
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

    /// Fire the offer. THE CODEX SEAM: most cards play the briefing's hard-coded `workLog`
    /// theater, but the Anthos card is wired LIVE — it actually runs `CodexCLI.shared.run(...)`
    /// on its `codexPrompt` (via `fireLiveCodex`, a real Gmail-MCP send) while the theater plays
    /// for show; the real outcome is logged. Streaming JSONL into `working(n)` is the next step.
    func run(_ id: String) {
        guard let e = entry(id), e.phase == .offer, e.b.offer != nil else { return }
        let v = visit

        // THE CODEX SEAM — LIVE for the Anthos + Charles cards: actually run `codex exec` on the
        // card's codexPrompt (real CodexCLI.run, with the user's Gmail MCP in scope, so the reply
        // truly sends). The scripted theater below still plays for visual feedback; the real run
        // happens in the background and its outcome is logged. (Charles replies-all into the real
        // "EWOR | Introducing Jesai & Charles" thread — see its codexPrompt.) Other cards stay
        // pure demo — their prompts would attempt bogus sends.
        if e.b.id == "anthos" || e.b.id == "charles", let prompt = e.b.codexPrompt {
            Task.detached(priority: .utility) { await Self.fireLiveCodex(prompt) }
        }

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

    /// Live CODEX SEAM (Anthos + Charles cards): run the card's codexPrompt through the real
    /// `codex exec` spine. The user's Gmail MCP rides the CodexCLI defaults; `bypassApprovals`
    /// lets the connector's approval-gated `send_email` actually fire headless. Outcome → `Log()`
    /// (tail /tmp/sentient-dev.log).
    nonisolated static func fireLiveCodex(_ prompt: String) async {
        Log("Home/codex: firing live codex exec (Gmail MCP send)…")
        do {
            var inv = CodexCLI.Invocation(prompt: prompt)
            inv.effort = .high                  // gpt-5.5 → high
            inv.bypassApprovals = true          // hosted Gmail send_email is approval-gated → it
                                                // auto-cancels headless unless we bypass approvals
            inv.timeout = 300

            let env = try await CodexCLI.shared.run(inv)
            Log("Home/codex: ✓ finished in \(env.durationMS ?? -1)ms (\(env.numTurns ?? -1) turns) — \(env.result)")
            Log("Home/codex: --- full JSONL (debug) ---\n\(env.raw)\n--- end JSONL ---")
        } catch {
            Log("Home/codex: ✗ failed — \(error)")
        }
    }

    /// The command bar's send button — fire the user's OWN typed task through codex, picking the
    /// agent channel by the toggle. Computer use vs browser use is ONLY a word in the prompt
    /// ("Using <mode.promptPhrase>, …"); both run the same `codex exec` (gpt-5.5, bypass sandbox)
    /// via `CodexCLI.runAgentCommand`, which streams its play-by-play to the console. → `Log()`.
    /// (Computer use is the WIP CLI path.)
    nonisolated static func fireCommand(_ text: String, mode: AgentMode) async {
        // Computer use spawns codex, which drives Codex's helper over an Apple Event macOS attributes
        // to US — so the FIRST computer-use run surfaces a one-time "Sentient OS wants to control
        // Codex Computer Use" consent prompt (Terminal/Warp already hold this grant). Just run it;
        // codex raises the prompt itself. Approve it once via the command bar or DEV TOOLS →
        // PERMISSIONS and every later run sails through.
        let prompt = commandPrompt(task: text, mode: mode)
        Log("──────── 🤖 \(mode.label.uppercased()) · command bar ────────")
        Log("CMD: launching codex exec (gpt-5.5 · \(mode.promptPhrase) · bypass sandbox)…")
        Log("CMD: prompt ↓\n\(prompt)")
        Log("──────────────── live codex output ↓ ────────────────")
        let started = Date()
        do {
            let output = try await CodexCLI.shared.runAgentCommand(prompt) { line in
                Log("CMD │ \(line)")     // streams each codex line to the Xcode console live
            }
            let secs = Int(Date().timeIntervalSince(started))
            Log("──────── 🤖 \(mode.label.uppercased()) ✓ DONE in \(secs)s ────────")
            Log("CMD: final → \(output.suffix(1200))")
        } catch {
            let secs = Int(Date().timeIntervalSince(started))
            Log("──────── 🤖 \(mode.label.uppercased()) ✗ FAILED after \(secs)s ────────")
            Log("CMD: \(error)")
        }
    }

    /// Build the command-bar prompt, mirroring the verified-working CLI command: the toggle swaps
    /// `mode.promptPhrase` ("computer use" / "browser use"); the typed task fills the rest; and the
    /// knowledge-base path (resolved from `~`, never hardcoded) rides along so the agent can ground
    /// the task in the user's life.
    nonisolated static func commandPrompt(task: String, mode: AgentMode) -> String {
        """
        Using \(mode.promptPhrase), \(task)

        My knowledge base is at '\(VaultGenerator.vaultRoot.path)'.
        """
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
    var onFling: (CGSize) -> Void

    @State private var drag: CGSize = .zero

    var body: some View {
        let j = Self.jitter(entry.id)
        BriefingCard(briefing: entry.b, phase: entry.phase,
                     onOffer: onOffer, onDetail: onDetail, onOpenEnvelope: onOpenEnvelope)
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
    var onOffer: () -> Void
    var onClose: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                MonoCaps(briefing.kicker, size: 10, tracking: 2.2, color: briefing.kind.accent)
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
                OfferButton(label: offer, accent: briefing.kind.accent, action: onOffer)
                    .padding(.top, 16)
            }
        }
        .padding(28)
        .background(Theme.Ink.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(briefing.kind == .welcome ? BriefingCard.welcomeGradient
                          : LinearGradient(colors: [briefing.kind.accent.opacity(0.45), .white.opacity(0.06)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                          lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 40, y: 18)
    }

    @ViewBuilder
    private var paragraphs: some View {
        let parts = (briefing.letter ?? briefing.body).components(separatedBy: "\n\n")
        ForEach(Array(parts.enumerated()), id: \.offset) { item in
            let text = item.element.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("✦ ") {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("✦").font(.system(size: 12)).foregroundStyle(briefing.kind.accent)
                    Text(Self.inline(String(text.dropFirst(2))))
                        .font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.84)).lineSpacing(4.5)
                }
            } else {
                Text(Self.inline(text))
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.84)).lineSpacing(5)
            }
        }
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
                .fill(LinearGradient(colors: [briefing.kind.accent, briefing.kind.accent.opacity(0.15)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    MonoCaps(briefing.draftLabel ?? "Draft", size: 9, tracking: 2.0, color: Theme.Ink.label)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft, forType: .string)
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
                Text(draft)
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.88)).lineSpacing(4)
                    .textSelection(.enabled)
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
    static let name = "Jesai"   // later: the vault portrait's first name
    static let readLine = "While you slept, I read 1,704 things"
    static let synced = "Synced · 3:41 AM"
    static let pending = 214
    static let aiNotesRead = 5
    static let aiLog = "Tokyo Trip, Visa…"
}

#Preview("Home — the suggestions") {
    HomeView(thingsUnderstood: 3339,
             sources: .init(files: true, whatsapp: true, imessage: true, notes: true),
             analyzeEnabled: true, modelMissing: false)
        .frame(width: 1180, height: 880)
}
