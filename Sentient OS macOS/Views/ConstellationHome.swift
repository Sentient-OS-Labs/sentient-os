//
//  ConstellationHome.swift
//  Sentient OS macOS
//
//  The Constellation — the app's home screen (Arch §9; design bar: UI_Inspiration/01 + the
//  HTML motion mockup). The living Orb at the center of the user's universe; four satellite
//  cards pinned (not gridded) at the corners, faintly tethered to the orb by dotted
//  constellation lines; serif-italic status over a mono-caps whisper; the Analyze Now glow
//  CTA; the trust footer on the floor; Dev Tools tucked bottom-right. Pure presentation —
//  real numbers come in through the initializer; every hard-coded showcase string lives in
//  `Demo` (search "Demo." when wiring real data).
//

import SwiftUI
import AppKit

struct ConstellationHome: View {
    /// Which sources are armed to run (drives the Sources satellite's chips).
    struct SourcesState {
        var files = true
        var whatsapp = false
        var imessage = false
        var notes = false
    }

    let thingsUnderstood: Int
    let analyzeEnabled: Bool
    let modelMissing: Bool
    let sources: SourcesState
    let onAnalyze: () -> Void
    let onOpenVault: () -> Void
    let onOpenBriefings: () -> Void
    let onShowDevTools: () -> Void

    @State private var vaultCounts: (notes: Int, domains: Int)?
    @State private var mcpCopied = false
    @State private var mcpUnavailable = false

    var body: some View {
        ZStack {
            centerColumn
            satellites
            chrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .backgroundPreferenceValue(TetherKey.self) { tethers($0) }
        .background(Theme.bg)
        .task { vaultCounts = Self.countVault() }
    }

    // MARK: Center — the orb, the status, the CTA

    private var centerColumn: some View {
        VStack(spacing: 0) {
            Orb(size: 132)
                .anchorPreference(key: TetherKey.self, value: .bounds) { ["orb": $0] }
            Text(statusLine)
                .font(.system(size: 21, design: .serif).italic())
                .foregroundStyle(C.statusInk)
                .padding(.top, 12)
            MonoCaps(statusSub, size: 10, tracking: 2.4, color: C.deepMuted)
                .padding(.top, 8)
            analyzeCTA
                .padding(.top, 22)
            if analyzeEnabled {
                MonoCaps("\(Demo.pending) pending", size: 10, tracking: 1.6, color: C.deepMuted)
                    .padding(.top, 13)
            }
            Text(whisper)
                .font(.system(size: 13.5, design: .serif).italic())
                .foregroundStyle(C.label)
                .padding(.top, 7)
        }
        .offset(y: -14)
    }

    private var statusLine: String {
        thingsUnderstood > 0 ? "All caught up." : "Ready to begin."
    }
    private var statusSub: String {
        switch thingsUnderstood {
        case 0:  "awaiting first analysis"
        case 1:  "1 thing understood"
        default: "\(thingsUnderstood.formatted()) things understood"
        }
    }
    private var whisper: String {
        modelMissing ? "The on-device model is missing — see Dev Tools"
                     : "Will run when your Mac rests"
    }

    private var analyzeCTA: some View {
        Button(action: onAnalyze) {
            Text("Analyze Now")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(analyzeEnabled ? .black : .white.opacity(0.35))
                .padding(.horizontal, 30).padding(.vertical, 11)
                .background(Capsule(style: .continuous)
                    .fill(analyzeEnabled ? Color.white : Color.white.opacity(0.08)))
                .overlay(Capsule(style: .continuous)
                    .stroke(analyzeEnabled ? .clear : Color.white.opacity(0.1), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .background(GlowHalo(active: analyzeEnabled))
        .disabled(!analyzeEnabled)
    }

    // MARK: The four satellites (exactly four, forever — doors with previews)

    private var satellites: some View {
        ZStack {
            briefingCard
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 48).padding(.top, 70)
            aisCard
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 48).padding(.top, 78)
            vaultCard
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 48).padding(.bottom, 86)
            sourcesCard
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 56).padding(.bottom, 80)
        }
    }

    /// For You's front door — sells proactive intelligence as a category (your AI worked
    /// overnight, plural, consent-gated), never one contextless headline. Opens the window.
    private var briefingCard: some View {
        SatelliteCard(id: "briefing", width: 300, rotation: -2, style: .gradientNew,
                      action: onOpenBriefings) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(C.label)
                MonoCaps("For You", size: 9.5, tracking: 2.3, color: C.label)
                NewPill()
                Spacer(minLength: 0)
            }
            Text("Let's get stuff done.")
                .font(.system(size: 21, design: .serif)).foregroundStyle(.white)
                .padding(.top, 9)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Demo.forYouTeasers, id: \.text) { t in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(t.kind.accent)
                        Text(t.text)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                    }
                }
            }
            .padding(.top, 10)
            MonoCaps(Demo.forYouFoot, size: 9, tracking: 1.6, color: C.deepMuted)
                .padding(.top, 11)
        }
    }

    private var aisCard: some View {
        SatelliteCard(id: "ais", width: 290, rotation: 1.6) {
            MonoCaps("Your AIs", size: 9.5, tracking: 2.3, color: C.label)
            (Text("Read ") + Text("\(Demo.aiNotesRead) notes").italic() + Text(" yesterday."))
                .font(.system(size: 20, design: .serif)).foregroundStyle(.white)
                .padding(.top, 8)
            HStack(spacing: 0) {
                Text("CHATGPT · ").foregroundStyle(C.label)
                Text(Demo.aiLog).foregroundStyle(C.body)
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.top, 6)
            mcpButton
                .padding(.top, 11)
        }
    }

    private var mcpButton: some View {
        Button(action: copyMCPLink) {
            HStack(spacing: 6) {
                Image(systemName: mcpCopied ? "checkmark" : "link").font(.system(size: 10))
                Text(mcpCopied ? "Copied" : mcpUnavailable ? "Mirror is off" : "Copy MCP Link")
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(mcpCopied ? C.mint : C.bright)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .overlay(Capsule().strokeBorder(Color(red: 0.165, green: 0.165, blue: 0.188), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Copies the real share URL when the mirror is on; the mirror opt-in UI itself is a
    /// later phase (onboarding step ⑨).
    private func copyMCPLink() {
        Task { @MainActor in
            if let url = await MirrorClient.shared.shareURL {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                mcpCopied = true
            } else {
                mcpUnavailable = true
            }
            try? await Task.sleep(for: .seconds(2))
            mcpCopied = false
            mcpUnavailable = false
        }
    }

    private var vaultCard: some View {
        SatelliteCard(id: "vault", width: 322, rotation: 1.4, action: onOpenVault) {
            HStack {
                MonoCaps("The Vault", size: 9.5, tracking: 2.3, color: C.label)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(C.deepMuted)
            }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(vaultHeadline)
                        .font(.system(size: 21, design: .serif)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .padding(.top, 8)
                    MonoCaps(vaultFoot, size: 9.5, tracking: 1.8, color: C.deepMuted)
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .padding(.top, 10)
                }
                Spacer(minLength: 0)
                MiniGraph().frame(width: 94, height: 58)
            }
        }
    }

    private var vaultHeadline: String {
        if let v = vaultCounts, v.notes > 0 { return "\(v.notes) notes · \(v.domains) domains" }
        return "No vault yet"
    }
    private var vaultFoot: String {
        (vaultCounts?.notes ?? 0) > 0 ? Demo.vaultFoot : "Your first analysis builds it"
    }

    /// Counts the real vault on disk (notes = .md files, domains = top-level folders).
    private static func countVault() -> (notes: Int, domains: Int)? {
        let fm = FileManager.default
        let root = VaultGenerator.vaultRoot
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        var notes = 0
        for case let url as URL in walker where url.pathExtension == "md" { notes += 1 }
        let domains = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter {
                !$0.lastPathComponent.hasPrefix(".")
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.count) ?? 0
        return (notes, domains)
    }

    private var sourcesCard: some View {
        SatelliteCard(id: "sources", width: 296, rotation: -1.8) {
            MonoCaps("Sources", size: 9.5, tracking: 2.3, color: C.label)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SourceChip("Files", on: sources.files)
                    SourceChip("WhatsApp", on: sources.whatsapp)
                    SourceChip("iMessage", on: sources.imessage)
                }
                HStack(spacing: 8) {
                    SourceChip("Notes", on: sources.notes)
                    SourceChip("Gmail", on: false, soon: true)
                }
            }
            .padding(.top, 11)
        }
    }

    // MARK: Chrome — header, trust footer, dev tools

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                OrbMark(size: 18)
                Text("Sentient OS")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                MonoCaps(Demo.synced, size: 9, tracking: 1.8, color: C.mint)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(C.mint.opacity(0.3), lineWidth: 1))
            }
            .padding(.horizontal, 28).padding(.top, 18)
            Spacer()
            ZStack {
                HStack(spacing: 8) {
                    Image(systemName: "shield").font(.system(size: 11)).foregroundStyle(C.label)
                    Text("Private by design. Your files never leave this Mac.")
                        .font(.system(size: 12)).foregroundStyle(C.label)
                }
                HStack {
                    Spacer()
                    devToolsButton
                }
                .padding(.trailing, 20)
            }
            .padding(.bottom, 16)
        }
    }

    /// DX continuity: the pre-Constellation dev cockpit, one click away (Release strip re-hides it).
    private var devToolsButton: some View {
        Button(action: onShowDevTools) {
            HStack(spacing: 5) {
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 8.5))
                Text("DEV TOOLS")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.6)
            }
            .foregroundStyle(C.deepMuted)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Tethers — the faint dotted lines that make it a constellation

    private func tethers(_ anchors: [String: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            Canvas { ctx, _ in
                guard let orbAnchor = anchors["orb"] else { return }
                let orbRect = proxy[orbAnchor]
                let orbCenter = CGPoint(x: orbRect.midX, y: orbRect.midY)
                for id in ["briefing", "ais", "vault", "sources"] {
                    guard let anchor = anchors[id] else { continue }
                    let rect = proxy[anchor]
                    var path = Path()
                    path.move(to: orbCenter)
                    path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
                    ctx.stroke(path, with: .color(.white.opacity(0.07)),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                }
            }
        }
    }
}

// MARK: - Satellite card (door-with-preview)

private struct SatelliteCard<Content: View>: View {
    enum Style { case standard, gradientNew }

    let id: String
    let width: CGFloat
    let rotation: Double
    var style: Style = .standard
    var action: (() -> Void)? = nil
    let content: Content
    @State private var hovering = false

    init(id: String, width: CGFloat, rotation: Double, style: Style = .standard,
         action: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.id = id
        self.width = width
        self.rotation = rotation
        self.style = style
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(EdgeInsets(top: 15, leading: 18, bottom: 16, trailing: 18))
            .frame(width: width, alignment: .leading)
            .background(C.cardBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(border, lineWidth: 1))
            .anchorPreference(key: TetherKey.self, value: .bounds) { [id: $0] }
            .rotationEffect(.degrees(rotation))
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture { action?() }
    }

    private var border: LinearGradient {
        switch style {
        case .standard:
            LinearGradient(colors: [.white.opacity(hovering ? 0.16 : 0.10), .white.opacity(0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .gradientNew:   // the NEW briefing wears the gradient like jewelry
            LinearGradient(colors: [Color(red: 1.00, green: 0.37, blue: 0.43).opacity(0.55),
                                    Color(red: 1.00, green: 0.76, blue: 0.44).opacity(0.35),
                                    Color(red: 0.36, green: 0.55, blue: 1.00).opacity(0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - Small pieces

private struct NewPill: View {
    var body: some View {
        Text("NEW")
            .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.6)
            .foregroundStyle(C.amber)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(C.amber.opacity(0.5), lineWidth: 1))
    }
}

private struct SourceChip: View {
    let name: String
    let on: Bool
    var soon = false

    init(_ name: String, on: Bool, soon: Bool = false) {
        self.name = name
        self.on = on
        self.soon = soon
    }

    var body: some View {
        HStack(spacing: 5) {
            if on { Text("✓").foregroundStyle(C.mint) }
            Text(name).foregroundStyle(soon ? C.deepMuted : on ? C.chipInk : .white.opacity(0.28))
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .tracking(0.8)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .overlay(Capsule().strokeBorder(C.chipBorder,
                                        style: StrokeStyle(lineWidth: 1, dash: soon ? [3, 3] : [])))
    }
}

/// The vault card's constellation thumbnail — static placeholder geometry until the live
/// graph render lands with the vault window (a later build phase).
private struct MiniGraph: View {
    private static let nodes: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
        (10, 40, 2.6), (34, 14, 3.8), (60, 30, 3.0), (84, 12, 2.4), (50, 48, 2.4)]
    private static let edges: [(Int, Int)] = [(0, 1), (1, 2), (2, 3), (1, 4), (2, 4), (0, 4)]

    var body: some View {
        Canvas { ctx, _ in
            for (a, b) in Self.edges {
                var path = Path()
                path.move(to: CGPoint(x: Self.nodes[a].x, y: Self.nodes[a].y))
                path.addLine(to: CGPoint(x: Self.nodes[b].x, y: Self.nodes[b].y))
                ctx.stroke(path, with: .color(.white.opacity(0.25)), lineWidth: 1)
            }
            for n in Self.nodes {
                ctx.fill(Path(ellipseIn: CGRect(x: n.x - n.r, y: n.y - n.r,
                                                width: n.r * 2, height: n.r * 2)),
                         with: .color(.white))
            }
        }
    }
}

/// Card + orb bounds, collected so the tether lines can be drawn from real geometry.
private struct TetherKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Palette alias & showcase data

private typealias C = Theme.Ink   // the shared editorial palette (Theme.swift)

/// Hard-coded showcase content (the investor-demo state). Every fake string lives HERE and
/// only here — wiring real data later is a search for "Demo.". The briefing + Your AIs cards
/// stay showcase until the briefings window and access-log polling land.
private enum Demo {
    static let synced = "Synced · 3:41 AM"
    static let pending = 214
    static let forYouTeasers: [(kind: Briefing.Kind, text: String)] = [
        (.overdue,  "Send your reply to Outlander VC?"),
        (.promise,  "Text Dad his running-shoe research?"),
        (.deadline, "Register you for ZFellows?"),
    ]
    static let forYouFoot = "6 offerings · one click each"
    static let aiNotesRead = 5
    static let aiLog = "Tokyo Trip, Visa…"
    static let vaultFoot = "Last night · 6 changed"
}

#Preview("Constellation — caught up") {
    ConstellationHome(thingsUnderstood: 12438, analyzeEnabled: true, modelMissing: false,
                      sources: .init(files: true, whatsapp: true, imessage: true, notes: true),
                      onAnalyze: {}, onOpenVault: {}, onOpenBriefings: {}, onShowDevTools: {})
        .frame(width: 1100, height: 760)
}

#Preview("Constellation — fresh install") {
    ConstellationHome(thingsUnderstood: 0, analyzeEnabled: true, modelMissing: false,
                      sources: .init(files: true, whatsapp: false, imessage: false, notes: false),
                      onAnalyze: {}, onOpenVault: {}, onOpenBriefings: {}, onShowDevTools: {})
        .frame(width: 1100, height: 760)
}
