// DoubleTapPane.swift
// Settings for Double Tap: autosaved reply instructions and provider-specific API key/model controls.
// DoubleTapCredentials keeps unsaved keys in view state and persists them only to Keychain on Save.
// Doc: Documentation - Settings.md

import SwiftUI
import AppKit

struct DoubleTapPane: View {
    @AppStorage(CustomInstructions.doubleTapKey) private var instructions = ""
    @AppStorage(DoubleTapProvider.key) private var providerRaw = DoubleTapProvider.sentient.rawValue
    @State private var activity = PipelineActivity.shared
    @State private var hasWritingExamples = WritingStyle.exists()

    private var provider: DoubleTapProvider { DoubleTapProvider(rawValue: providerRaw) ?? .sentient }

    var body: some View {
        SettingsPane(title: "Double Tap", whisper: "Replies in your voice, ready for you to review.") {
            VStack(alignment: .leading, spacing: 30) {
                SettingsGroup(label: "Custom instructions") {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsProse("Tell Double Tap how you like to write. You can set different preferences for texts and emails.")
                        SettingsTextBox(
                            placeholder: "e.g. Always write in lowercase when responding to texts, but not when responding to email.",
                            text: $instructions)
                            .frame(height: 112)
                            .accessibilityLabel("Double Tap custom instructions")
                        if instructions.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > CustomInstructions.doubleTapByteLimit {
                            Text("These instructions are too long. Please shorten them before using Double Tap.")
                                .font(.system(size: 11)).foregroundStyle(Theme.Ink.red)
                        } else {
                            Text("Saved automatically. Applies to every Double Tap reply.")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.Ink.label)
                        }
                    }
                }

                SettingsHairline(opacity: 0.12).padding(.vertical, -7)

                SettingsGroup(label: "Your writing style") {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsProse(PrivacyCopy.writingSamples)
                        SettingsProse(PrivacyCopy.writingSources)
                        SettingsPillButton(title: "Show writing examples in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                VaultGenerator.vaultRoot.appendingPathComponent(WritingStyle.fileName)
                            ])
                        }
                        .disabled(!hasWritingExamples)
                        if !hasWritingExamples {
                            SettingsProse("Your writing examples will appear here after Double Tap setup finishes.")
                        }
                    }
                }

                SettingsHairline(opacity: 0.12).padding(.vertical, -7)

                SettingsGroup(label: "Double Tap Inference Provider") {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("Double Tap Inference Provider", selection: $providerRaw) {
                            ForEach(DoubleTapProvider.allCases) { provider in
                                Text(provider.label).tag(provider.rawValue)
                            }
                        }
                        .pickerStyle(.menu).labelsHidden().controlSize(.large)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if provider == .sentient {
                            SettingsProse(PrivacyCopy.doubleTapCovered)
                        } else {
                            DoubleTapCredentials(provider: provider)
                                .id(provider)
                        }

                        SettingsProse(PrivacyCopy.doubleTapContext)
                        SettingsProse(provider == .sentient
                            ? "This context passes through Sentient’s relay to OpenAI."
                            : provider.hasCustomEndpoint
                            ? "This context goes directly to your configured endpoint. For local drafting, use a local model served on this Mac."
                            : "This context goes directly to your chosen \(provider.name) provider, under its policies and your account settings.")
                    }
                }
            }
        }
        .onAppear { hasWritingExamples = WritingStyle.exists() }
        .onChange(of: activity.isRunning) { _, _ in hasWritingExamples = WritingStyle.exists() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasWritingExamples = WritingStyle.exists()
        }
    }
}

private struct DoubleTapCredentials: View {
    let provider: DoubleTapProvider
    @AppStorage private var model: String
    @AppStorage private var baseURL: String
    @AppStorage private var apiRaw: String
    @State private var keyDraft = ""
    @State private var keySaved = false
    @State private var keyError: String?
    @State private var editingOtherModel = false

    init(provider: DoubleTapProvider) {
        self.provider = provider
        _model = AppStorage(wrappedValue: provider.defaultModel, provider.modelKey)
        _baseURL = AppStorage(wrappedValue: provider.defaultBaseURL, provider.baseURLKey)
        _apiRaw = AppStorage(wrappedValue: DoubleTapProvider.API.chatCompletions.rawValue, provider.apiFormatKey)
    }

    private var trimmedKey: String { keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isPreset: Bool {
        DoubleTapProvider.modelPresets.contains { provider.modelID($0.id) == model }
    }
    private var modelSelection: Binding<String> {
        Binding(get: { editingOtherModel || !isPreset ? "other" : model }, set: { value in
            editingOtherModel = value == "other"
            model = editingOtherModel ? "" : value
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if provider.hasCustomEndpoint {
                endpointFields
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(provider.requiresKey ? "\(provider.name) API key" : "API key (optional)")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.Ink.statusInk)
                HStack(spacing: 10) {
                    SecureField(keySaved ? "Enter a replacement key"
                                : provider.requiresKey ? "Enter your API key" : "Optional for keyless servers", text: $keyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(11)
                        .background(.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke, lineWidth: 1))
                        .accessibilityLabel("\(provider.name) API key")
                        .onSubmit(saveKey)
                    SettingsPillButton(title: "Save", action: saveKey)
                        .disabled(trimmedKey.isEmpty)
                }
                HStack(spacing: 7) {
                    if keySaved {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Ink.green)
                        Text("API key saved in Keychain")
                        Spacer(minLength: 10)
                        Button("Remove") {
                            if provider.removeKey() {
                                keySaved = false
                                keyDraft = ""
                                keyError = nil
                            } else {
                                keyError = "Couldn't remove the key. Unlock your Mac and try again."
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(provider.requiresKey ? "Save your API key to use \(provider.name)."
                             : "Leave empty if your server does not require an API key.")
                    }
                }
                .font(.system(size: 10.5)).foregroundStyle(Theme.Ink.label)
                if let keyError {
                    Text(keyError).font(.system(size: 11)).foregroundStyle(Theme.Ink.red)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("Model")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.Ink.statusInk)
                if provider.hasModelPresets {
                    Picker("Model", selection: modelSelection) {
                        ForEach(DoubleTapProvider.modelPresets, id: \.id) { preset in
                            Text(preset.label).tag(provider.modelID(preset.id))
                        }
                        Text("Other model…").tag("other")
                    }
                    .pickerStyle(.menu).labelsHidden().controlSize(.large)
                }
                if !provider.hasModelPresets || editingOtherModel || !isPreset {
                    inputField(provider == .openRouter ? "provider/model-id"
                               : provider == .ollama ? "e.g. gemma4:e4b" : "model-id",
                               text: $model, label: "\(provider.name) model ID")
                    SettingsProse("Enter a model ID from \(provider.name) that supports images and text replies.")
                }
                if provider.hasCustomEndpoint {
                    SettingsProse("Choose a model with enough context for your knowledge base. If you use a local server, keep it running with the model loaded. Double Tap stops after 30 seconds.")
                    Text("Saved automatically. Applies to the next Double Tap reply.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.Ink.label)
                } else {
                    SettingsProse("Usage is billed to your \(provider.name) account.")
                }
            }
        }
        .onAppear { keySaved = provider.apiKey != nil }
    }

    private var endpointFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Base URL")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.Ink.statusInk)
            inputField(provider.defaultBaseURL.isEmpty ? "https://your-endpoint.example/v1" : provider.defaultBaseURL,
                       text: $baseURL, label: "\(provider.name) base URL")
            if DoubleTapProvider.endpoint(baseURL: baseURL,
                                          api: DoubleTapProvider.API(rawValue: apiRaw) ?? .chatCompletions) == nil {
                Text("Enter a valid http:// or https:// base URL, including its API prefix (usually /v1).")
                    .font(.system(size: 11)).foregroundStyle(Theme.Ink.red)
            }
            Text("API format")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.Ink.statusInk)
                .padding(.top, 7)
            Picker("API format", selection: $apiRaw) {
                ForEach(DoubleTapProvider.API.allCases) { api in
                    Text(api.label).tag(api.rawValue)
                }
            }
            .pickerStyle(.menu).labelsHidden().controlSize(.large)
            SettingsProse("Use Chat Completions for most compatible servers, or Responses if your endpoint requires it.")
        }
    }

    private func inputField(_ placeholder: String, text: Binding<String>, label: String) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(11)
            .background(.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke, lineWidth: 1))
            .autocorrectionDisabled()
            .accessibilityLabel(label)
    }

    private func saveKey() {
        guard !trimmedKey.isEmpty else { return }
        if provider.saveKey(trimmedKey) {
            keySaved = true
            keyDraft = ""
            keyError = nil
        } else {
            keyError = "Couldn't save the key. Unlock your Mac and try again."
        }
    }
}

#Preview("Double Tap") {
    DoubleTapPane().background(Theme.bg).preferredColorScheme(.dark)
        .frame(width: 680, height: 740)
}

#Preview("Ollama provider") {
    DoubleTapCredentials(provider: .ollama)
        .padding(32).frame(width: 600)
        .background(Theme.bg).preferredColorScheme(.dark)
}
