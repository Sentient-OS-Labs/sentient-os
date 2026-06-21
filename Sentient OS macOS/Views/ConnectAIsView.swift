//
//  ConnectAIsView.swift
//  Sentient OS macOS
//
//  The "Connect your AIs" window — opened by the glowing CTA in the Your AIs popover. This is
//  the DEFERRED setup guide (intentionally a stub for now): the real two-step flow lands later
//   ① copy your private MCP URL and add it as a connector,
//   ② add a line to your AI's system prompt telling it to use your Sentient MCP.
//  Kept as a tasteful placeholder so the CTA opens something real, not a dead control.
//  (Uses the static OrbMark glyph, not the living Orb — the orb lives only on the empty home.)
//

import SwiftUI

struct ConnectAIsView: View {
    static let windowID = "connect-ais"

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 20) {
                OrbMark(size: 38)
                Text("Connect your AIs.")
                    .font(.system(size: 25, design: .serif).italic())
                    .foregroundStyle(Theme.Ink.statusInk)
                Text("Offer your knowledge base to ChatGPT, Claude, and every AI you use — privately, over MCP, in two simple steps.")
                    .font(.system(size: 13)).foregroundStyle(Theme.Ink.body)
                    .multilineTextAlignment(.center).lineSpacing(3.5)
                    .frame(maxWidth: 380)

                VStack(spacing: 11) {
                    step(1, "Copy your private MCP link", "Add it as a connector in ChatGPT or Claude.")
                    step(2, "Tell your AI to use it", "One line in its instructions — and it knows your whole life.")
                }
                .padding(.top, 8)

                MonoCaps("Guided setup · coming soon", size: 9, tracking: 2.0, color: Theme.Ink.deepMuted)
                    .padding(.top, 6)
            }
            .padding(44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 480, minHeight: 520)
    }

    private func step(_ n: Int, _ title: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.Ink.bright)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white)
                Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.Ink.body)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        .background(Theme.Ink.cardBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(0.06), lineWidth: 1))
    }
}

#Preview("Connect your AIs") {
    ConnectAIsView().frame(width: 520, height: 560)
}
