// Shared hosted-provider setup and allowance surface for onboarding and Settings.
// Commits the provider only after connection and runtime preparation succeed for this selection.
// Doc: Views/Settings/Documentation - Settings.md

import SwiftUI
import AppKit

struct SentientInferencePanel: View {
    @State private var setup = SentientSetup.shared
    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue
    @State private var attempt: UUID?
    @State private var operation: Task<Void, Never>?

    private var active: Bool { backendRaw == ModelBackend.sentient.rawValue }

    var body: some View {
        SettingsGroup(label: "Covered by Sentient") {
            VStack(alignment: .leading, spacing: 14) {
                SettingsProse(PrivacyCopy.sentientInference)

                if !setup.configured {
                    SettingsProse(SentientSetup.unavailableMessage)
                } else {
                    if active && setup.ready { FrontierActiveLine("Using Sentient") }
                    if let usage = setup.usage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(SentientUsagePresentation.remaining(usage.remainingSeconds))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.Ink.bright)
                            Text(SentientUsagePresentation.reset(usage.resetAt))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                        }
                        .accessibilityIdentifier("sentient.allowance")
                    }
                    if !active || !setup.ready {
                        SettingsPillButton(title: setup.preparing ? "Setting up…" : "Use Sentient for free") {
                            activate()
                        }
                        .disabled(setup.preparing || attempt != nil)
                        .accessibilityIdentifier("sentient.activate")
                    } else {
                        SettingsPillButton(title: setup.checking ? "Checking…" : "Refresh usage") {
                            Task { await setup.refresh() }
                        }
                        .disabled(setup.checking)
                    }
                    if setup.preparing { MonoWaitLine("setting up sentient…") }
                    OnboardingStatusText(setup.status)
                }

                SettingsProse(PrivacyCopy.sentientLimits)
                SettingsDetails(title: "What is shared for hosted inference") {
                    SettingsProse(PrivacyCopy.sentientContext)
                    SettingsProse(PrivacyCopy.sentientIdentity)
                    SettingsProse("Apple Mail, Apple Calendar, and supported direct connections work with Sentient. Connections supplied by your ChatGPT or Claude subscription still require that provider.")
                }
            }
        }
        .accessibilityIdentifier("sentient.provider")
        .task { await setup.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await setup.refresh() }
        }
        .onChange(of: backendRaw) { cancelActivation() }
        .onDisappear { cancelActivation() }
    }

    private func activate() {
        guard setup.configured, attempt == nil else { return }
        let selectedBackend = backendRaw
        let token = UUID()
        attempt = token
        operation = Task {
            defer { if attempt == token { attempt = nil; operation = nil } }
            let prepared = await setup.prepare()
            guard prepared, !Task.isCancelled, attempt == token,
                  backendRaw == selectedBackend, setup.configured else { return }
            backendRaw = ModelBackend.sentient.rawValue
        }
    }

    private func cancelActivation() {
        operation?.cancel()
        operation = nil
        attempt = nil
    }
}
