// DoubleTapProvider.swift
// Double Tap's saved provider, endpoint/API format, model, and Keychain credentials. Read fresh per run.
// Keeps the original route values and OpenAI Keychain account so existing choices survive.
// Doc: Documentation - Double Tap.md

import Foundation

enum DoubleTapProvider: String, CaseIterable, Identifiable {
    case sentient = "relay"
    case openAI = "directKey"
    case openRouter = "openRouter"
    case ollama = "ollama"
    case lmStudio = "lmstudio"
    case custom = "custom"

    enum API: String, CaseIterable, Identifiable {
        case chatCompletions
        case responses

        var id: String { rawValue }
        var label: String { self == .responses ? "Responses" : "Chat Completions" }
        var path: String { self == .responses ? "responses" : "chat/completions" }
    }

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
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .custom: "OpenAI-compatible API"
        }
    }
    var name: String {
        switch self {
        case .sentient: "Sentient OS"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .custom: "Custom API"
        }
    }

    var hasCustomEndpoint: Bool { self == .ollama || self == .lmStudio || self == .custom }
    var requiresKey: Bool { self == .openAI || self == .openRouter }
    var hasModelPresets: Bool { self == .openAI || self == .openRouter }
    var baseURLKey: String { "doubletap.\(storageID).baseURL" }
    var apiFormatKey: String { "doubletap.\(storageID).api" }
    var api: API {
        guard hasCustomEndpoint else { return .responses }
        return API(rawValue: UserDefaults.standard.string(forKey: apiFormatKey) ?? "") ?? .chatCompletions
    }
    var defaultBaseURL: String {
        switch self {
        case .ollama: "http://127.0.0.1:11434/v1"
        case .lmStudio: "http://127.0.0.1:1234/v1"
        default: ""
        }
    }
    var baseURL: String {
        (UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var endpoint: URL? {
        switch self {
        case .sentient: nil
        case .openAI: URL(string: "https://api.openai.com/v1/responses")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1/responses")!
        case .ollama, .lmStudio, .custom: Self.endpoint(baseURL: baseURL, api: api)
        }
    }

    /// Accept a base URL or a full route, preserving proxy prefixes. Reject malformed URLs
    /// before capturing a screenshot; credentials belong in Keychain, never in the URL.
    static func endpoint(baseURL: String, api: API) -> URL? {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.contains(where: \.isWhitespace),
              var parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        for format in API.allCases where parts.path.hasSuffix("/" + format.path) {
            parts.path.removeLast(format.path.count + 1)
            break
        }
        parts.path += "/" + api.path
        return parts.url
    }

    var apiKeyAccount: String? {
        switch self {
        case .sentient: nil
        case .openAI: "doubletap.openai.apiKey"
        case .openRouter: "doubletap.openrouter.apiKey"
        case .ollama, .lmStudio, .custom: "doubletap.\(storageID).apiKey"
        }
    }
    var apiKey: String? {
        guard let account = apiKeyAccount,
              let value = Keychain.read(account)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private var storageID: String {
        switch self {
        case .sentient, .openAI: "openai"
        case .openRouter: "openrouter"
        case .ollama, .lmStudio, .custom: rawValue
        }
    }
    var modelKey: String { "doubletap.\(storageID).model" }
    var defaultModel: String { hasCustomEndpoint ? "" : modelID("gpt-6-sol") }
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
        // Attempt every deletion even if one Keychain operation fails.
        let results = allCases.map { $0.removeKey() }
        return results.allSatisfy { $0 }
    }
}
