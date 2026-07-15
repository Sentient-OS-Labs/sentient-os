//
//  PrivacyPolicyView.swift
//  Sentient OS macOS
//
//  The Privacy Policy sheet (Settings → System → How We Protect Your Data → Read More).
//  The whole policy is one screen: the one-line pledge, the two optional features that touch
//  the cloud (the opt-in E2E MCP mirror, the opt-out crash reports & analytics), and the
//  Codex CLI note. Static app-voice copy; Done or Esc closes it.
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

            prose("Sentient has two optional features that let you get more out of it without compromising your privacy:")
                .padding(.top, 16)
            bullet("An optional, **opt-in**, end-to-end encrypted cloud MCP, if you want your ChatGPT and Claude to be able to access your knowledge base. Our E2E cloud MCP is open source, too!")
                .padding(.top, 12)
            bullet("Privacy-preserving crash logs and analytics, using open-source, privacy-focused libraries (Sentry and TelemetryDeck). You can opt out of crash logs completely, and opt out of analytics (except basic anonymous usage pings). Your personal summaries, knowledge base, and files never leave your device as part of these systems.")
                .padding(.top, 10)

            prose("When you use features that depend on your Codex CLI, OpenAI's privacy policy will apply.")
                .padding(.top, 16)

            SettingsPillButton(title: "Done") { dismiss() }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 22)
        }
        .padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 24)
        .frame(width: 470)
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
