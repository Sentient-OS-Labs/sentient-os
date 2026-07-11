//
//  ConnectAIsView.swift
//  Sentient OS macOS
//
//  The "Connect your AIs" window — the guided setup, opened by the glow CTAs in Settings →
//  Your AIs and the home's Your AIs popover. Owns the whole story:
//   · sharing OFF → the single glowing "Connect your AIs" CTA (enables the mirror + first push,
//     then the guide assembles in place); a quiet MCP ON/OFF pill top-right mirrors the state
//     and flips it off behind the same confirm-and-delete alert Settings uses.
//   · sharing ON → per-AI tabs (ChatGPT · Claude · Other AIs). ChatGPT/Claude each show two
//     portrait video steps side by side: ① paste the private MCP link (masked; the real one
//     lands on the clipboard), ② copy the coached system prompt (MirrorClient.systemPrompt) —
//     with a take-me-there link under each card (GuideSpec URLs are placeholders until the real
//     deep links land). Other AIs is the compact no-video pair of the same two steps.
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
        case chatgpt = "ChatGPT"
        case claude = "Claude"
        case other = "Other AIs"
        var id: String { rawValue }
    }

    @State private var tab: AITab = .chatgpt
    @State private var enabled = false
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
                if loaded {
                    if enabled { guide } else { connectPitch }
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            if loaded { sharingPill.padding(16) }
        }
        .frame(minWidth: 820, minHeight: 880)
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

    // MARK: - Sharing off: the one glowing object in the window

    private var connectPitch: some View {
        VStack(spacing: 0) {
            GlowButton(title: busy ? "Connecting…" : "Connect your AIs",
                       systemImage: "link", glowIntensity: 0.5) { connect() }
                .frame(width: 280)
                .padding(.top, 40)
            MonoCaps("Private · no account · delete anytime",
                     size: 8.5, tracking: 1.6, color: Theme.Ink.deepMuted)
                .padding(.top, 22)
            if let errorLine {
                Text(errorLine)
                    .font(.system(size: 11)).foregroundStyle(Theme.Ink.amber)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .padding(.top, 14)
            }
        }
    }

    // MARK: - Sharing on: the per-AI guide

    private var guide: some View {
        VStack(spacing: 0) {
            tabSwitcher.padding(.top, 26)
            ZStack {
                switch tab {
                case .chatgpt: videoPair(Self.chatgptGuide)
                case .claude:  videoPair(Self.claudeGuide)
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

    /// One AI's guide content: captions + the take-me-there destinations under each card.
    private struct GuideSpec {
        let name: String
        let videoPrefix: String
        let linkCaption: String
        let promptCaption: String
        let connectorsURL: String
        let instructionsLabel: String
        let instructionsURL: String
    }

    // ⚠️ The two URLs per AI are PLACEHOLDERS (the AI's home) until the real deep links to the
    // connector / instructions screens land — swap them here, nothing else changes.
    private static let chatgptGuide = GuideSpec(
        name: "ChatGPT", videoPrefix: "connect-chatgpt",
        linkCaption: "In ChatGPT: Settings → Connectors → Create, then paste your link.",
        promptCaption: "In ChatGPT: Settings → Personalization → Custom instructions, then paste.",
        connectorsURL: "https://chatgpt.com",
        instructionsLabel: "Open ChatGPT's instructions",
        instructionsURL: "https://chatgpt.com")
    private static let claudeGuide = GuideSpec(
        name: "Claude", videoPrefix: "connect-claude",
        linkCaption: "In Claude: Settings → Connectors → Add custom connector, then paste your link.",
        promptCaption: "In Claude: Settings → Profile → your preferences, then paste.",
        connectorsURL: "https://claude.ai",
        instructionsLabel: "Open Claude's preferences",
        instructionsURL: "https://claude.ai")

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

    /// ChatGPT / Claude: the two video steps side by side, a take-me-there link under each.
    private func videoPair(_ g: GuideSpec) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 12) {
                videoStep(1, "Paste your private link",
                          video: "\(g.videoPrefix)-1", caption: g.linkCaption) { linkRow }
                StepLink(title: "Open \(g.name)'s connectors", urlString: g.connectorsURL)
            }
            VStack(spacing: 12) {
                videoStep(2, "Tell \(g.name) to use it",
                          video: "\(g.videoPrefix)-2", caption: g.promptCaption) { promptButton }
                StepLink(title: g.instructionsLabel, urlString: g.instructionsURL)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .transition(.opacity)
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
    private func videoStep<Controls: View>(_ n: Int, _ title: String, video: String, caption: String,
                                           @ViewBuilder controls: () -> Controls) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StepVideo(resource: video)
            MonoCaps("Step \(n)", size: 9, tracking: 2.2, color: Theme.Ink.label)
                .padding(.top, 14)
            Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white)
                .padding(.top, 6)
            controls().padding(.top, 10)
            Text(caption).font(.system(size: 11.5)).foregroundStyle(Theme.Ink.body)
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
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white)
                controls()
                Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.Ink.body)
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

    // MARK: - The sharing pill (top-right): state at a glance, off behind the confirm

    private var sharingPill: some View {
        Button {
            if enabled { confirmOff = true } else { connect() }
        } label: {
            HStack(spacing: 5) {
                if busy { ProgressView().controlSize(.mini) }
                else { Circle().fill(enabled ? Theme.Ink.green : Theme.Ink.deepMuted).frame(width: 6, height: 6) }
                Text(enabled ? "MCP ON" : "MCP OFF")
            }
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced)).tracking(1.4)
            .foregroundStyle(enabled ? Theme.Ink.green : Theme.Ink.label)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .overlay(Capsule().strokeBorder((enabled ? Theme.Ink.green : Theme.Ink.label).opacity(0.3), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    // MARK: - MirrorClient plumbing (the SAME path Settings + the popover drive)

    @MainActor private func refresh() async {
        enabled = await MirrorClient.shared.isEnabled
        shareURL = await MirrorClient.shared.shareURL
        loaded = true
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
                withAnimation(.easeOut(duration: 0.35)) { enabled = true }
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
            withAnimation(.easeOut(duration: 0.3)) { enabled = false }
            busy = false
        }
    }
}

// MARK: - The take-me-there link (under each video card)

/// A quiet inline link that opens the AI's own screen in the browser — body ink, brightens on
/// hover, the small arrow marking it as a door out of the app.
private struct StepLink: View {
    let title: String
    let urlString: String
    @State private var hover = false

    var body: some View {
        Button {
            if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hover ? Theme.Ink.bright : Theme.Ink.body)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        // The frame matches the recordings' shape (908×1080 portrait) so aspect-fill never crops;
        // keep new clips at this aspect.
        .aspectRatio(908.0 / 1080.0, contentMode: .fit)
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
