//
//  ConnectAIsView.swift
//  Sentient OS macOS
//
//  The "Connect your AIs" window — the REAL two-step guided setup (was a stub until 2026-07-04),
//  opened by the glowing CTA in Settings → Your AIs and the home's Your AIs popover:
//   ① copy your private MCP link (masked here; the real one lands on the clipboard) and add it
//     as a connector in ChatGPT / Claude,
//   ② copy the coached system prompt (MirrorClient.systemPrompt) into the AI's instructions.
//  Closes with the magic demo line: ask it "What do you know about me?". If sharing is off, the
//  window says so and points at Settings instead of showing dead controls.
//  (Uses the static OrbMark glyph, not the living Orb — the orb lives only on the empty home.)
//

import SwiftUI
import AppKit

struct ConnectAIsView: View {
    static let windowID = "connect-ais"

    @State private var shareURL: String?
    @State private var loaded = false
    @State private var copiedLink = false
    @State private var copiedPrompt = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 20) {
                OrbMark(size: 38)
                Text("Connect your AIs.")
                    .font(.system(size: 25, design: .serif).italic())
                    .foregroundStyle(Theme.Ink.statusInk)
                Text("Offer your knowledge base to ChatGPT, Claude, and every AI you use. Private, over MCP, in two simple steps.")
                    .font(.system(size: 13)).foregroundStyle(Theme.Ink.body)
                    .multilineTextAlignment(.center).lineSpacing(3.5)
                    .frame(maxWidth: 380)

                if loaded, shareURL != nil {
                    VStack(spacing: 11) {
                        linkStep
                        promptStep
                    }
                    .padding(.top, 8)

                    Text("Then ask it: \u{201C}What do you know about me?\u{201D}")
                        .font(.serif(13, weight: .regular)).italic()
                        .foregroundStyle(Theme.Ink.body)
                        .padding(.top, 10)
                } else if loaded {
                    Text("Sharing is off. Turn on \u{201C}Offer your knowledge base to your AIs\u{201D} in Settings → Connect AIs to Knowledge first.")
                        .font(.system(size: 12)).foregroundStyle(Theme.Ink.amber)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                        .padding(.top, 12)
                }
            }
            .padding(44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 480, minHeight: 540)
        .task {
            if await MirrorClient.shared.isEnabled {
                shareURL = await MirrorClient.shared.shareURL
            }
            loaded = true
        }
    }

    // MARK: - Step 1: the private link

    private var linkStep: some View {
        step(1, "Copy your private link", "In ChatGPT or Claude, add it as a connector (Settings → Connectors).") {
            HStack(spacing: 9) {
                Text(MirrorClient.maskedURL(shareURL))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Ink.bright)
                    .lineLimit(1)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Color.white.opacity(0.03), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                SettingsPillButton(title: copiedLink ? "Copied ✓" : "Copy",
                                   tint: copiedLink ? Theme.Ink.green : Theme.Ink.bright) {
                    copy(shareURL ?? "", flag: $copiedLink)
                }
            }
        }
    }

    // MARK: - Step 2: the system prompt

    private var promptStep: some View {
        step(2, "Tell your AI to use it", "Paste this into your AI's instructions so it checks your knowledge base.") {
            SettingsPillButton(title: copiedPrompt ? "Copied ✓" : "Copy the instructions",
                               tint: copiedPrompt ? Theme.Ink.green : Theme.Ink.bright) {
                copy(MirrorClient.systemPrompt, flag: $copiedPrompt)
            }
        }
    }

    private func copy(_ text: String, flag: Binding<Bool>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flag.wrappedValue = true
        Task { try? await Task.sleep(for: .seconds(1.8)); flag.wrappedValue = false }
    }

    // MARK: - The step card

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
        .frame(width: 400, alignment: .leading)
        .background(Theme.Ink.cardBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(0.06), lineWidth: 1))
    }
}

#Preview("Connect your AIs") {
    ConnectAIsView().frame(width: 520, height: 580)
}
