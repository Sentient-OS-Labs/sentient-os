//
//  ConnectAIsView.swift
//  Sentient OS macOS
//
//  The "Connect your AIs" window — the guided setup, opened by the glow CTAs in Settings →
//  Your AIs and the home's Your AIs popover. Owns the whole story:
//   · sharing OFF → the guide itself opens first (a 1-second crisp peek, inert), then blurs
//     under a transparent veil carrying the consent ask: "Connect your AIs?", the trust pillars
//     (zero-access encryption, open-source server, delete anytime), a glowing "Yes, use the cloud MCP"
//     (enables the mirror + first push, blur releases in place) and a "Not now" that closes the
//     window. No MCP pill while off.
//   · sharing ON → per-AI tabs (ChatGPT · Claude · Other AIs), plus a quiet MCP ON toggle
//     top-right (carrying the last synced time) that flips sharing off behind the
//     confirm-and-delete alert; turning off brings the veil straight back.
//     ChatGPT/Claude show their
//     GuideSpec's portrait video steps side by side (ChatGPT three: developer mode → paste the
//     private MCP link → paste the system prompt; Claude two: link → prompt), each with a
//     take-me-there deep link above the card. The masked link + Copy and the coached
//     MirrorClient.systemPrompt ride the cards; Other AIs is the compact no-video pair.
//  Tutorial clips load from the bundle by name — connect-chatgpt-1/2.mp4, connect-claude-1/2.mp4;
//  a missing file renders a quiet glass placeholder, so the recordings can land later with zero
//  code changes. Closes with the magic demo line: ask it "What do you know about me?".
//  (Uses the static OrbMark glyph, not the living Orb — the orb lives only on the empty home.)
//

import SwiftUI
import AppKit
import AVFoundation

struct ConnectAIsView: View {
    static let windowID = "connect-ais"

    private enum AITab: String, CaseIterable, Identifiable {
        case claude = "Claude"
        case chatgpt = "ChatGPT"
        case other = "Other AIs"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss

    @State private var tab: AITab = .claude
    @State private var enabled = false
    @State private var veiled = false   // sharing off: the blur + consent overlay (after the 1s peek)
    @State private var shareURL: String?
    @State private var loaded = false
    @State private var busy = false
    @State private var confirmOff = false
    @State private var errorLine: String?
    @State private var copiedLink = false
    @State private var copiedPrompt = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if loaded { guide }
            }
            .padding(.horizontal, 40).padding(.vertical, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .blur(radius: veiled ? 34 : 0)
            .saturation(veiled ? 0.7 : 1)   // mute the blurred cards so the veil reads calm
            .allowsHitTesting(enabled)   // the peek is a teaser, not a playground
            if veiled { connectVeil.transition(.opacity) }
        }
        .overlay(alignment: .topTrailing) {
            if loaded && enabled { sharingPill.padding(16) }
        }
        .frame(minWidth: 1100, minHeight: 880)
        .task { await refresh() }
        .alert("Stop sharing your knowledge base?", isPresented: $confirmOff) {
            Button("Keep Sharing", role: .cancel) {}
            Button("Stop & Delete Cloud Copy", role: .destructive) { disconnect() }
        } message: {
            Text("The cloud copy is deleted immediately and your AIs lose access. Your knowledge base stays safe on this Mac, and turning sharing back on restores the same link.")
        }
    }

    // MARK: - Header (unchanged voice: orb glyph, display line, the pitch)

    private var header: some View {
        VStack(spacing: 20) {
            OrbMark(size: 38)
            Text("Connect your AIs.")
                .display(25)
                .foregroundStyle(Theme.Ink.statusInk)
            Text("Offer your knowledge base to ChatGPT, Claude, and every AI you use. Private, over MCP, in two simple steps.")
                .font(.system(size: 13)).foregroundStyle(Theme.Ink.body)
                .multilineTextAlignment(.center).lineSpacing(3.5)
                .frame(maxWidth: 420)
        }
    }

    // MARK: - Sharing off: the veil — a translucent scrim over the blurred guide, carrying the
    // consent ask. Not a pitch that assumes yes: the question, where the data actually goes
    // (trust pillars, same story Settings tells), an explicit yes, and a real "Not now".
    // Connect releases the blur in place; Not now closes the window.

    private var connectVeil: some View {
        ZStack {
            // Deep enough that the inks (tuned for OLED black) sit right; the blurred guide
            // survives as a faint glow, not a bright wall the grays melt into.
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 0) {
                OrbMark(size: 38)
                Text("Connect your AIs?")
                    .display(25)
                    .foregroundStyle(Theme.Ink.statusInk)
                    .padding(.top, 20)
                Text("Sentient built your knowledge base right here on this Mac. Want to offer it to ChatGPT, Claude, and every AI you use?")
                    .font(.system(size: 13)).foregroundStyle(Theme.Ink.body)
                    .multilineTextAlignment(.center).lineSpacing(3.5)
                    .frame(maxWidth: 440)
                    .padding(.top, 20)
                VStack(alignment: .leading, spacing: 10) {
                    veilPillar("lock.fill", "Zero-access encryption. Your knowledge base is sealed on this Mac with a key only your Mac and your private link hold; our servers store nothing but ciphertext, with no key beside it. Hack them and there is nothing to unlock.")
                    veilPillar("chevron.left.forwardslash.chevron.right", "The server in between is open source. Everything's verifiable.")
                    veilPillar("key.fill", "No account. Turn it off anytime and the cloud copy is deleted on the spot.")
                }
                .frame(width: 440)
                .padding(.top, 28)
                GlowButton(title: busy ? "Connecting…" : "Yes, use the cloud MCP",
                           systemImage: "link", glowIntensity: 0.5) { connect() }
                    .frame(width: 280)
                    .padding(.top, 36)
                Button {
                    dismiss()
                } label: {
                    Text("Not now")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.Ink.label)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                .disabled(busy)
                .padding(.top, 16)
                if let errorLine {
                    Text(errorLine)
                        .font(.system(size: 11)).foregroundStyle(Theme.Ink.amber)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                        .padding(.top, 14)
                }
            }
            .padding(.horizontal, 40)
        }
        .contentShape(Rectangle())   // swallow clicks so the blurred guide stays inert
    }

    /// One trust pillar on the veil (the same shape as Settings → Give AIs Knowledge's pillars,
    /// so the story reads identically wherever the user meets it).
    private func veilPillar(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Ink.green.opacity(0.8))
                .frame(width: 15)
            Text(text)
                .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.body)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sharing on: the per-AI guide

    private var guide: some View {
        VStack(spacing: 0) {
            tabSwitcher.padding(.top, 26)
            ZStack {
                switch tab {
                case .chatgpt: videoRow(Self.chatgptGuide)
                case .claude:  videoRow(Self.claudeGuide)
                case .other:   otherPair
                }
            }
            .padding(.top, 20)
            .animation(.easeOut(duration: 0.22), value: tab)
            Text("Then ask it: \u{201C}What do you know about me?\u{201D}")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Ink.body)
                .padding(.top, 24)
        }
    }

    /// One card of an AI's guide: the take-me-there link above it, the video, the copy control.
    private struct GuideStep {
        enum Control { case none, link, prompt }
        let title: String
        let caption: String
        let linkLabel: String
        let linkURL: String
        let control: Control
    }

    /// One AI's guide: its cards in order (videos load as "<videoPrefix>-<n>.mp4"), at the
    /// recordings' own aspect so aspect-fill never crops.
    private struct GuideSpec {
        let name: String
        let videoPrefix: String
        let videoAspect: CGFloat
        let steps: [GuideStep]
    }

    private static let chatgptGuide = GuideSpec(
        name: "ChatGPT", videoPrefix: "connect-chatgpt", videoAspect: 996.0 / 1080.0,
        steps: [
            GuideStep(title: "Turn on developer mode",
                      caption: "Settings → Security and login → Developer mode, switch it on.",
                      linkLabel: "Open ChatGPT's security settings",
                      linkURL: "https://chatgpt.com/plugins#settings/Security",
                      control: .none),
            GuideStep(title: "Paste your private link",
                      caption: "Plugins → New Plugin: name it Sentient OS, paste your link as the Server URL, No Auth, then Create.",
                      linkLabel: "Open ChatGPT's plugins",
                      linkURL: "https://chatgpt.com/plugins#settings/Connectors?create-connector=true&redirectAfter=%2Fplugins",
                      control: .link),
            GuideStep(title: "Tell ChatGPT to use it",
                      caption: "Settings → Personalization → Custom instructions, then paste.",
                      linkLabel: "Open ChatGPT's instructions",
                      linkURL: "https://chatgpt.com/plugins#settings/Personalization",
                      control: .prompt),
        ])
    private static let claudeGuide = GuideSpec(
        name: "Claude", videoPrefix: "connect-claude", videoAspect: 916.0 / 1080.0,
        steps: [
            GuideStep(title: "Paste your private link",
                      caption: "Settings → Connectors → Add custom connector, then paste your link.",
                      linkLabel: "Open Claude's connectors",
                      linkURL: "https://claude.ai/new#settings/customize-connectors",
                      control: .link),
            GuideStep(title: "Tell Claude to use it",
                      caption: "Settings → General → Instructions for Claude, then paste.",
                      linkLabel: "Open Claude's instructions",
                      linkURL: "https://claude.ai/new#settings/general",
                      control: .prompt),
        ])

    private var tabSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(AITab.allCases) { t in
                Button { tab = t } label: {
                    Text(t.rawValue)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tab == t ? .black : Theme.Ink.chipInk)
                        .padding(.horizontal, 18).padding(.vertical, 7)
                        .background(Capsule().fill(tab == t ? Color.white : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
    }

    /// ChatGPT / Claude: the guide's video steps side by side, a take-me-there link above each.
    private func videoRow(_ g: GuideSpec) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(g.steps.enumerated()), id: \.offset) { i, s in
                VStack(alignment: .leading, spacing: 12) {
                    StepLink(title: s.linkLabel, urlString: s.linkURL)
                    videoStep(i + 1, s.title, video: "\(g.videoPrefix)-\(i + 1)",
                              aspect: g.videoAspect, caption: s.caption) {
                        stepControl(s.control)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .transition(.opacity)
    }

    @ViewBuilder private func stepControl(_ c: GuideStep.Control) -> some View {
        switch c {
        case .link:   linkRow
        case .prompt: promptButton
        case .none:   EmptyView()
        }
    }

    /// Other AIs: the same two steps, compact, no videos.
    private var otherPair: some View {
        VStack(spacing: 11) {
            step(1, "Copy your private link",
                 "Add it as a connector wherever your AI takes MCP servers.") { linkRow }
            step(2, "Tell your AI to use it",
                 "Paste this into its instructions so it checks your knowledge base.") { promptButton }
            MonoCaps("Works with any AI that speaks MCP",
                     size: 8.5, tracking: 1.6, color: Theme.Ink.deepMuted)
                .padding(.top, 10)
        }
        .transition(.opacity)
    }

    // MARK: - The two shared controls (every tab pastes the same two things)

    private var linkRow: some View {
        HStack(spacing: 9) {
            Text(MirrorClient.maskedURL(shareURL))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.Ink.bright)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Color.white.opacity(0.03), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
            SettingsPillButton(title: copiedLink ? "Copied ✓" : "Copy",
                               tint: copiedLink ? Theme.Ink.green : Theme.Ink.bright) {
                copy(shareURL ?? "", flag: $copiedLink)
            }
        }
    }

    private var promptButton: some View {
        SettingsPillButton(title: copiedPrompt ? "Copied ✓" : "Copy the instructions",
                           tint: copiedPrompt ? Theme.Ink.green : Theme.Ink.bright) {
            copy(MirrorClient.systemPrompt, flag: $copiedPrompt)
        }
    }

    private func copy(_ text: String, flag: Binding<Bool>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flag.wrappedValue = true
        Task { try? await Task.sleep(for: .seconds(1.8)); flag.wrappedValue = false }
    }

    // MARK: - The step cards

    /// A video step (ChatGPT / Claude tabs): clip on top, whisper + title + controls + caption below.
    private func videoStep<Controls: View>(_ n: Int, _ title: String, video: String, aspect: CGFloat,
                                           caption: String,
                                           @ViewBuilder controls: () -> Controls) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StepVideo(resource: video, aspect: aspect)
            MonoCaps("Step \(n)", size: 9, tracking: 2.2, color: Theme.Ink.label)
                .padding(.top, 14)
            Text(LocalizedStringKey(stringLiteral: title)).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white)
                .padding(.top, 6)
            controls().padding(.top, 10)
            Text(LocalizedStringKey(stringLiteral: caption)).font(.system(size: 11.5)).foregroundStyle(Theme.Ink.body)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 330, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Ink.cardBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.white.opacity(0.06), lineWidth: 1))
    }

    /// A compact numbered step (the Other AIs tab).
    private func step<Controls: View>(_ n: Int, _ title: String, _ sub: String,
                                      @ViewBuilder controls: () -> Controls) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.Ink.bright)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringKey(stringLiteral: title)).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white)
                controls()
                Text(LocalizedStringKey(stringLiteral: sub)).font(.system(size: 11.5)).foregroundStyle(Theme.Ink.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 430, alignment: .leading)
        .background(Theme.Ink.cardBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(0.06), lineWidth: 1))
    }

    // MARK: - The sharing toggle (top-right, sharing ON only): synced state at a glance, with a
    // real switch — off goes through the confirm. While sharing is off the window shows no
    // toggle — the veil IS the state.

    private var sharingPill: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.mini) }
            Text(verbatim: pillLabel)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced)).tracking(1.4)
                .foregroundStyle(Theme.Ink.green)
                .textCase(.uppercase)
            // The setter never writes `enabled` itself — flipping off only raises the confirm,
            // so "Keep Sharing" leaves the switch on; disconnect() is what actually turns it off.
            Toggle("", isOn: Binding(
                get: { enabled },
                set: { requested in if !requested { confirmOff = true } }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .tint(Theme.Ink.green)
                .disabled(busy)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .overlay(Capsule().strokeBorder(Theme.Ink.green.opacity(0.3), lineWidth: 1))
    }

    /// The synced stamp (the last successful push) answers "is my AIs' copy current?" at a
    /// glance; no stamp = enabled but not yet pushed.
    private var pillLabel: String {
        let locale = AppLanguage.resolvedLocale
        guard let pushed = MirrorClient.lastPush else {
            return String(localized: "MCP ON", locale: locale)
        }
        return String(localized: "MCP ON · SYNCED \(pushed.glanceStamp)", locale: locale)
    }

    // MARK: - MirrorClient plumbing (the SAME path Settings + the popover drive)

    @MainActor private func refresh() async {
        enabled = await MirrorClient.shared.isEnabled
        shareURL = await MirrorClient.shared.shareURL
        loaded = true
        // Sharing off: EVERY open gets the ritual — land crisp for a second, then draw the veil.
        // The window's state survives close/reopen, so the veil is reset by hand (instantly,
        // no animation) before the peek; otherwise a second open would start already veiled.
        if !enabled {
            veiled = false
            try? await Task.sleep(for: .seconds(1))
            guard !enabled else { return }
            withAnimation(.easeInOut(duration: 0.7)) { veiled = true }
        }
    }

    private func connect() {
        guard !busy else { return }
        busy = true; errorLine = nil
        Task { @MainActor in
            do {
                _ = try await MirrorClient.shared.enable()
                // First fill is best-effort: no vault yet / a transient push failure just means
                // the next cycle (or the on-launch catch-up) syncs it.
                do { try await MirrorClient.shared.push(); VaultActivity.shared.vaultDirty = false }
                catch {}
                shareURL = await MirrorClient.shared.shareURL
                withAnimation(.easeOut(duration: 0.5)) { enabled = true; veiled = false }
            } catch {
                errorLine = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            busy = false
        }
    }

    private func disconnect() {
        guard !busy else { return }
        busy = true; errorLine = nil
        Task { @MainActor in
            await MirrorClient.shared.disable()
            // The veil returns immediately — no peek; the CTA is the off state's only exit.
            withAnimation(.easeOut(duration: 0.4)) { enabled = false; veiled = true }
            busy = false
        }
    }
}

// MARK: - The take-me-there link (under each video card)

/// The take-me-there bubble above each card — a quiet capsule pill (glassy fill, hairline ring)
/// that opens the AI's own screen in the browser; the small arrow marks it as a door out of the
/// app. Brightens on hover, same family as the cards' copy pills.
private struct StepLink: View {
    let title: String
    let urlString: String
    @State private var hover = false

    var body: some View {
        Button {
            if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 5) {
                Text(LocalizedStringKey(stringLiteral: title))
                Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hover ? .white : Theme.Ink.bright)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(hover ? 0.08 : 0.04)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - The tutorial clip

/// A looping, muted tutorial clip loaded from the bundle by resource name. Until the Screen
/// Studio recordings land, a missing file renders a quiet glass placeholder, so the window
/// ships now and the .mp4s drop in later with zero code changes.
private struct StepVideo: View {
    let resource: String   // e.g. "connect-chatgpt-1" → connect-chatgpt-1.mp4 in the bundle
    let aspect: CGFloat    // the recordings' own shape (GuideSpec.videoAspect) so fill never crops

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: resource, withExtension: "mp4") {
                LoopingVideo(url: url)
            } else {
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.025))
                    Image(systemName: "play.circle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.16))
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.white.opacity(0.07), lineWidth: 1))
    }
}

/// AVPlayerLayer in an NSView — chromeless, muted, seamlessly looping (AVPlayerLooper).
private struct LoopingVideo: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        let player = AVQueuePlayer()
        player.isMuted = true
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        player.play()
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {}

    static func dismantleNSView(_ view: PlayerView, coordinator: Coordinator) {
        view.playerLayer.player?.pause()
        coordinator.looper = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var looper: AVPlayerLooper? }

    final class PlayerView: NSView {
        let playerLayer = AVPlayerLayer()
        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError("unused") }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)   // no stretchy implicit animation on resize
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

#Preview("Connect your AIs") {
    ConnectAIsView().frame(width: 920, height: 760)
}
