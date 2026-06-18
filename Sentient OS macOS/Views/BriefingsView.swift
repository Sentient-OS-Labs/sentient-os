//
//  BriefingsView.swift
//  Sentient OS macOS
//
//  The For You window — "The Offerings". The orb deals the briefing cards onto the black
//  with staggered physics; they settle into a loose scatter (placed, not gridded). Each card
//  is an OFFER the user can fire (BriefingCard plays the agentic theater, then the card
//  flies away), flick-dismiss with drag physics (the scatter reflows), or expand into a full
//  typeset letter. A faint reminders strip + trust footer hold the floor; the empty state
//  whispers "Your AI looks out for you."
//
//  Doc: Documentation/Briefings Window (For You).md · Demo content + the CodexCLI seam:
//  Briefing.swift.
//

import SwiftUI
import AppKit

struct BriefingsView: View {
    static let windowID = "foryou"

    @State private var model = ForYouModel()
    // The letter layer is ALWAYS mounted and driven purely by opacity/scale from plain
    // @State — view INSERTION (`if let` overlays) can miss a redraw on macOS hidden-titlebar
    // windows (the "appears only after a resize" bug); opacity changes cannot.
    @State private var letter: Briefing?
    @State private var letterShown = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.bg.ignoresSafeArea()

                Group {
                    header
                    scatter(geo)
                    bottomStrip
                    if model.entries.isEmpty { emptyState.transition(.opacity) }
                }
                .blur(radius: letterShown ? 7 : 0)
                .opacity(letterShown ? 0.4 : 1)

                letterLayer(geo)
            }
        }
        .frame(minWidth: 1020, minHeight: 720)
        .background(Theme.bg)
        .onAppear {                        // every visit starts fresh: sealed envelope, full deal
            letter = nil
            letterShown = false
            model.beginVisit()
        }
        .animation(.easeInOut(duration: 0.5), value: model.entries.isEmpty)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                OrbMark(size: 15)
                MonoCaps("For You", size: 10, tracking: 2.6, color: Theme.Ink.label)
            }
            Text(greeting)
                .font(.system(size: 30, design: .serif).italic())
                .foregroundStyle(Theme.Ink.statusInk)
            MonoCaps(Demo.readLine(count: model.entries.count), size: 9.5, tracking: 2.2,
                     color: Theme.Ink.deepMuted)
        }
        .padding(.leading, 36).padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Up late" : hour < 12 ? "Good morning"
                 : hour < 18 ? "Good afternoon" : "Good evening"
        return "\(part), \(Demo.name)."
    }

    // MARK: The scatter

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

    /// Organic slot positions per population — pinned, not gridded; reflows as cards leave.
    private static func slots(count: Int, in size: CGSize) -> [CGPoint] {
        let f: [(CGFloat, CGFloat)]
        switch count {
        case 6...: f = [(0.21, 0.40), (0.50, 0.36), (0.79, 0.40), (0.21, 0.74), (0.50, 0.78), (0.79, 0.74)]
        case 5:    f = [(0.22, 0.40), (0.50, 0.37), (0.78, 0.40), (0.34, 0.75), (0.66, 0.75)]
        case 4:    f = [(0.28, 0.40), (0.72, 0.40), (0.28, 0.75), (0.72, 0.75)]
        case 3:    f = [(0.24, 0.57), (0.50, 0.51), (0.76, 0.57)]
        case 2:    f = [(0.35, 0.55), (0.65, 0.55)]
        default:   f = [(0.50, 0.55)]
        }
        return f.map { CGPoint(x: $0.0 * size.width, y: $0.1 * size.height) }
    }

    // MARK: Floor — reminders whisper + trust footer

    private var bottomStrip: some View {
        VStack(spacing: 9) {
            MonoCaps(Demo.reminders, size: 9, tracking: 1.6, color: Theme.Ink.deepMuted)
            HStack(spacing: 8) {
                Image(systemName: "shield").font(.system(size: 11)).foregroundStyle(Theme.Ink.label)
                Text("Private by design. Your files never leave this Mac.")
                    .font(.system(size: 12)).foregroundStyle(Theme.Ink.label)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            OrbMark(size: 26)
            Text("All quiet.")
                .font(.system(size: 22, design: .serif).italic())
                .foregroundStyle(Theme.Ink.statusInk)
            MonoCaps("Your AI looks out for you", size: 9.5, tracking: 2.4, color: Theme.Ink.deepMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    /// Bumped per window visit — in-flight Tasks from a previous visit check it and bail,
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

    /// Fire the offer. THE CODEX SEAM: real execution replaces the scripted loop below with
    /// `CodexCLI.shared.run(...)` on `briefing.codexPrompt`, streaming JSONL events into the
    /// same `working(n)` lines. The demo plays the briefing's hard-coded theater.
    func run(_ id: String) {
        guard let e = entry(id), e.phase == .offer, e.b.offer != nil else { return }
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

// MARK: - Demo data (the window's own showcase strings — cards live in Briefing.demo)

private enum Demo {
    static let name = "Jesai"   // later: the vault portrait's first name
    static let reminders = "Reminders · EWOR call — Daniel Dippold, Fri 11 AM · ZFellows — 8 days · Workout — tonight 8 PM"
    static func readLine(count: Int) -> String {
        "While you slept, I read 1,704 things · \(count) offering\(count == 1 ? "" : "s")"
    }
}

#Preview("For You — the offerings") {
    BriefingsView()
        .frame(width: 1180, height: 800)
}
