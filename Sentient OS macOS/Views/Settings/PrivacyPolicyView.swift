//
//  PrivacyPolicyView.swift
//  Sentient OS macOS
//
//  The Privacy Policy sheet (Settings → System → How We Protect Your Data → Read More).
//  Scrollable policy: connected-email storage, the opt-in cloud feature (the
//  zero-access-encrypted MCP mirror), the two opt-out anonymous diagnostics (crash reports · Sentry,
//  analytics · TelemetryDeck, with the analytics on/off breakdown), and the Codex CLI note.
//  Static app-voice copy; Done or Esc closes it.
//

import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Privacy Policy")
                    .display(24).foregroundStyle(.white)

                prose("Your content and your connected-account details are handled separately:")
                    .padding(.top, 14)
                Text("Your files and messages are not stored in our account database.")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    .padding(.top, 8)

                prose("Sentient has an optional feature that can let you get more out of it without compromising your privacy:")
                    .padding(.top, 16)
                bullet("An optional, **opt-in** cloud MCP so your ChatGPT and Claude can read your knowledge base. It uses **zero-access encryption**: the key is held by your Mac and your private link; the mirror stores only ciphertext. This mirror is separate from the connected-email database.")
                    .padding(.top, 12)

                bullet("**Connected email addresses:** after you confirm the addresses shown in the connection flow, Sentient stores them in **Supabase**, together with the email provider, AI engine, connection identifier and a private installation ID. Claude Gmail's address is supplied by you. Each installation can access only its own records; authorized Sentient administrators can access the database. We do not upload messages, passwords or provider access tokens to this database. Delete these records in **Settings → System → Saved email addresses**. Reset and Uninstall also delete them and require an internet connection to finish that deletion. Separate Macs have separate installation identities.")
                    .padding(.top, 12)

                prose("Sentient also runs two anonymous diagnostics, which you can turn off anytime. Neither ever carries your content:")
                    .padding(.top, 16)
                bullet("**Privacy-preserving crash logs (open-source Sentry):** structure-only reports, like counts, error types, and stack traces, that help us fix your bugs. Switch them off and they stop completely.")
                    .padding(.top, 12)
                bullet("**Privacy-preserving analytics (open-source TelemetryDeck):** anonymous usage signals, never anything personal.\n**Off:** only five usage counts still send, so we can see Sentient is being used at all: how many people use it, Sidekick fires, proactive cards (made and fired), overnight runs, and home opens; counts only.\n**On:** those five, plus a fuller anonymous picture: onboarding progress, how long features run, and sync and health signals. Always just counts and categories, and nothing can be traced back to you.")
                    .padding(.top, 12)

                prose("When your chosen AI accesses connected services, OpenAI's or Anthropic's privacy policy also applies. Saving an email address does not subscribe you to marketing or verify ownership of that address.")
                    .padding(.top, 16)

                SettingsPillButton(title: "Done") { dismiss() }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 22)
            }
            .padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 24)
            .frame(width: 600)
        }
        .frame(width: 600, height: 700)
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
