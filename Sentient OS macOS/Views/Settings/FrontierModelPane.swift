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

    @State private var tab: FrontierEngineTab = .chatgpt

    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue

    private var backend: ModelBackend { ModelBackend(rawValue: backendRaw) ?? .chatgpt }

    var body: some View {
        SettingsPane(title: "Frontier Model Choice",
                     whisper: "Choose the AI behind your knowledge, suggestions, and Sidekick.") {
            VStack(alignment: .leading, spacing: 26) {
                FrontierEnginePicker(tab: $tab) {
                    chatgptPanel
                }
                SettingsDetails(title: "How your models work together") {
                    SettingsProse(PrivacyCopy.frontierDetail)
                    SettingsProse(PrivacyCopy.customProvider)
                }
            }
        }
    }

    // MARK: - ChatGPT (Settings' own panel — login honesty lives in Permissions & Health)

    private var chatgptPanel: some View {
        SettingsGroup(label: "ChatGPT") {
            VStack(alignment: .leading, spacing: 14) {
                SettingsProse("Use your ChatGPT subscription for knowledge, morning suggestions, and Sidekick.")
                if backend == .chatgpt {
                    HStack {
                        FrontierActiveLine("Using ChatGPT")
                        Spacer()
                        SettingsPillButton(title: "Manage account") {
                            MainNavigation.shared.show(.settings, settingsPane: .health)
                        }
                    }
                } else {
                    SettingsPillButton(title: "Use ChatGPT") {
                        backendRaw = ModelBackend.chatgpt.rawValue
                        // The commitment moment — the lazy codex install fires here (a
                        // detection-first no-op when the CLI already exists).
                        Task {
                            await CodexSetup.shared.ensureInstalled()
                            guard backendRaw == ModelBackend.chatgpt.rawValue else { return }
                            await ComputerUseSetup.instance(for: .openAI).install()
                        }
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
