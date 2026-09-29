// DoubleTapProvider.swift
// Double Tap's saved provider, per-provider model, and Keychain credentials. Read fresh per run.
// Keeps the original route values and OpenAI Keychain account so existing choices survive.
// Doc: Documentation - Double Tap.md

import Foundation

enum DoubleTapProvider: String, CaseIterable, Identifiable {
    case sentient = "relay"
    case openAI = "directKey"
    case openRouter = "openRouter"

    static let key = "doubletap.route"
    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .sentient
    }

    var id: String { rawValue }
    var label: String {
        switch self {
        case .sentient: "Covered by Sentient OS"
        case .openAI: "OpenAI API"
        case .openRouter: "OpenRouter API"
        }
    }
    var name: String {
        switch self {
        case .sentient: "Sentient OS"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        }
    }
    var endpoint: URL? {
        switch self {
        case .sentient: nil
        case .openAI: URL(string: "https://api.openai.com/v1/responses")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1/responses")!
        }
    }
    var apiKeyAccount: String? {
        switch self {
        case .sentient: nil
        case .openAI: "doubletap.openai.apiKey"
        case .openRouter: "doubletap.openrouter.apiKey"
        }
    }
    var apiKey: String? {
        guard let account = apiKeyAccount,
              let value = Keychain.read(account)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    var modelKey: String { "doubletap.\(self == .openRouter ? "openrouter" : "openai").model" }
    var defaultModel: String { modelID("gpt-6-sol") }
    var model: String {
        guard self != .sentient else { return "gpt-6-sol" } // The relay owns its model.
        return (UserDefaults.standard.string(forKey: modelKey) ?? defaultModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func modelID(_ openAIModel: String) -> String {
        self == .openRouter ? "openai/\(openAIModel)" : openAIModel
    }

    static let modelPresets: [(id: String, label: String)] = [
        ("gpt-6-sol", "GPT-6 Sol"),
        ("gpt-6-astra", "GPT-6 Astra"),
        ("gpt-6-luna", "GPT-6 Luna"),
    ]

    @discardableResult
    func saveKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account = apiKeyAccount, !trimmed.isEmpty else { return false }
        return Keychain.set(account, trimmed)
    }

    @discardableResult
    func removeKey() -> Bool {
        guard let account = apiKeyAccount else { return true }
        return Keychain.delete(account)
    }

    /// Uninstall only. A knowledge-base rebuild preserves these setup choices.
    static func destroyKeys() -> Bool {
        let openAI = Self.openAI.removeKey()
        let openRouter = Self.openRouter.removeKey()
        return openAI && openRouter
    }
}
