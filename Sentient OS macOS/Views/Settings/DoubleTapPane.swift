// DoubleTapPane.swift
// Settings for Double Tap: autosaved reply instructions and provider-specific API key/model controls.
// DoubleTapCredentials keeps unsaved keys in view state and persists them only to Keychain on Save.
// Doc: Documentation - Settings.md

import SwiftUI

struct DoubleTapPane: View {
    @AppStorage(CustomInstructions.doubleTapKey) private var instructions = ""
    @AppStorage(DoubleTapProvider.key) private var providerRaw = DoubleTapProvider.sentient.rawValue

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
                            SettingsProse("Sentient OS covers your drafts. No API key needed.")
                        } else {
                            DoubleTapCredentials(provider: provider)
                                .id(provider)
                        }

                        SettingsProse(provider == .sentient
                            ? "Your screenshot, knowledge base, and instructions are sent through Sentient's relay to OpenAI to draft your reply."
                            : "Your screenshot, knowledge base, and instructions are sent directly to \(provider.name) to draft your reply.")
                    }
                }
            }
        }
    }
}

private struct DoubleTapCredentials: View {
    let provider: DoubleTapProvider
    @AppStorage private var model: String
    @State private var keyDraft = ""
    @State private var keySaved = false
    @State private var keyError: String?
    @State private var editingOtherModel = false

    init(provider: DoubleTapProvider) {
        self.provider = provider
        _model = AppStorage(wrappedValue: provider.defaultModel, provider.modelKey)
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
            VStack(alignment: .leading, spacing: 9) {
                Text("\(provider.name) API key")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.Ink.statusInk)
                HStack(spacing: 10) {
                    SecureField(keySaved ? "Enter a replacement key" : "Enter your API key", text: $keyDraft)
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
                        Text("Save your API key to use \(provider.name).")
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
                Picker("Model", selection: modelSelection) {
                    ForEach(DoubleTapProvider.modelPresets, id: \.id) { preset in
                        Text(preset.label).tag(provider.modelID(preset.id))
                    }
                    Text("Other model…").tag("other")
                }
                .pickerStyle(.menu).labelsHidden().controlSize(.large)
                if editingOtherModel || !isPreset {
                    TextField(provider == .openRouter ? "provider/model-id" : "model-id", text: $model)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(11)
                        .background(.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke, lineWidth: 1))
                        .autocorrectionDisabled()
                        .accessibilityLabel("\(provider.name) model ID")
                    SettingsProse("Enter a model ID from \(provider.name) that supports images and text replies.")
                }
                SettingsProse("Usage is billed to your \(provider.name) account.")
            }
        }
        .onAppear { keySaved = provider.apiKey != nil }
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
