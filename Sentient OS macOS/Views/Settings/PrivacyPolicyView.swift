// PrivacyPolicyView.swift
// Scrollable policy shared by Settings and onboarding; PrivacyCopy owns the wording.
// The title and Done button remain visible while the policy scrolls.
// Doc: Documentation - Settings.md

import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Privacy Policy")
                .display(24).foregroundStyle(.white)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(PrivacyCopy.headline)
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    prose(PrivacyCopy.summary).padding(.top, 8)
                    prose(PrivacyCopy.intro).padding(.top, 12)
                    ForEach(PrivacyCopy.sections) { section in
                        Text(section.title)
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            .padding(.top, 22)
                        ForEach(section.paragraphs, id: \.self) { paragraph in
                            prose(paragraph).padding(.top, 9)
                        }
                    }
                    Link("OpenAI API data controls", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                        .font(.system(size: 12.5)).padding(.top, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(.top, 14)
            SettingsPillButton(title: "Done") { dismiss() }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 22)
        }
        .padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 24)
        .frame(width: 600, height: 650)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5)).foregroundStyle(Theme.Ink.body)
            .lineSpacing(3.5)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("Privacy Policy") {
    PrivacyPolicyView()
}
