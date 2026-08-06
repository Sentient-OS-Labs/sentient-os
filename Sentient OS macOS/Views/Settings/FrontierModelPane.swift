//
//  FrontierModelPane.swift
//  Sentient OS macOS
//
//  Settings → Frontier Model Choice: which frontier engine powers the cloud ~10% of Sentient
//  (the on-device model does the rest). A thin wrapper over the SHARED FrontierEnginePicker
//  (the pills + per-engine panels onboarding's choose-your-frontier-model step renders too);
//  what's Settings' own here is the pane chrome and the ChatGPT panel — activate directly with
//  Use ChatGPT, and point at Permissions & Health for login/plan (onboarding embeds the live
//  login instead). Writes ModelBackend/CustomProvider (the one source of truth); everything
//  applies to the very next run, no restart.
//

import SwiftUI

struct FrontierModelPane: View {

    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue

    private var backend: ModelBackend { ModelBackend(rawValue: backendRaw) ?? .chatgpt }

    var body: some View {
        SettingsPane(title: "Frontier Model Choice",
                     whisper: "Sentient's on-device model does about 90% of the thinking. This is the engine behind the last 10%.") {
            VStack(alignment: .leading, spacing: 26) {
                SettingsProse("Everything Sentient reads stays on this Mac. For the heavy cloud reasoning, the knowledge base, the morning cards, Sidekick, it taps one frontier model of your choosing: your ChatGPT subscription, your Claude plan (coming soon), or a model endpoint of your own.")

                FrontierEnginePicker {
                    chatgptPanel
                }
            }
        }
    }

    // MARK: - ChatGPT (Settings' own panel — login honesty lives in Permissions & Health)

    private var chatgptPanel: some View {
        SettingsGroup(label: "Your ChatGPT") {
            VStack(alignment: .leading, spacing: 14) {
                SettingsProse("ChatGPT sign-in authenticates Codex model access. It does not import ChatGPT conversations, memories, custom instructions, projects, or files. Gmail and Calendar are separate sources you explicitly enable.")
                if backend == .chatgpt {
                    FrontierActiveLine("Sentient is running on your ChatGPT.")
                    SettingsProse("Login and plan live in Permissions & Health.")
                } else {
                    SettingsPillButton(title: "Use ChatGPT") {
                        backendRaw = ModelBackend.chatgpt.rawValue
                    }
                }
            }
        }
    }
}

#Preview("Frontier Model Choice") {
    FrontierModelPane()
        .background(Theme.bg)
        .frame(width: 720, height: 820)
}
