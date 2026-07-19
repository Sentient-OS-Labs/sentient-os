//
//  PrivacyPolicyView.swift
//  Sentient OS macOS
//
//  The Privacy Policy sheet (Settings → System → How We Protect Your Data → Read More).
//  The whole policy is one screen: the one-line pledge, the one opt-in cloud feature (the
//  zero-access-encrypted MCP mirror), the two opt-out anonymous diagnostics (crash reports · Sentry,
//  analytics · TelemetryDeck, with the analytics on/off breakdown), and the Codex CLI note.
//  Static app-voice copy; Done or Esc closes it.
//

import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Privacy Policy")
                .display(24).foregroundStyle(.white)

            prose("Unlike most privacy policies, ours can be summarized in one line:")
                .padding(.top, 14)
            Text("We don't collect your private info, ever.")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                .padding(.top, 8)

            prose("Sentient has an optional feature that can let you get more out of it without compromising your privacy:")
                .padding(.top, 16)
            bullet("An optional, **opt-in** cloud MCP so your ChatGPT and Claude can read your knowledge base. It uses **zero-access encryption**: the key is held only by your Mac and your private link, never on our servers, which hold nothing but ciphertext they have no key to unlock. Hack them and there's nothing to read. And the whole cloud backend is open source, so you never have to take our word for it.")
                .padding(.top, 12)

            prose("Sentient also runs two anonymous diagnostics, which you can turn off anytime. Neither ever carries your content:")
                .padding(.top, 16)
            bullet("**Privacy-preserving crash logs (open-source Sentry):** structure-only reports, like counts, error types, and stack traces, that help us fix your bugs. Switch them off and they stop completely.")
                .padding(.top, 12)
            bullet("**Privacy-preserving analytics (open-source TelemetryDeck):** anonymous usage signals, never anything personal.\n**Off:** only five usage counts still send, so we can see Sentient is being used at all: how many people use it, Sidekick fires, proactive cards (made and fired), overnight runs, and home opens; counts only.\n**On:** those five, plus a fuller anonymous picture: onboarding progress, how long features run, and sync and health signals. Always just counts and categories, and nothing can be traced back to you.")
                .padding(.top, 12)

            prose("When you use features that depend on your Codex CLI, OpenAI's privacy policy will apply.")
                .padding(.top, 16)

            SettingsPillButton(title: "Done") { dismiss() }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 22)
        }
        .padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 24)
        .frame(width: 600)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5)).foregroundStyle(Theme.Ink.body)
            .lineSpacing(3.5)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A quiet bullet line; the text is a literal, so **bold** renders inline.
    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("•").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.42))
            Text(text)
                .font(.system(size: 12.5)).foregroundStyle(Theme.Ink.body)
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Privacy Policy") {
    PrivacyPolicyView()
}
