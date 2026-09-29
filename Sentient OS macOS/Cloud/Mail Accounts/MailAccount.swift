// MailAccount.swift
// Connected-mail metadata and validation, shared by collection, storage and the setup UI.
// Doc: Documentation - Connected Email Accounts.md

import Foundation

nonisolated struct MailAccount: Codable, Sendable, Equatable, Identifiable {
    enum Engine: String, Codable, Sendable, CaseIterable { case chatgpt, claude }
    enum Provider: String, Codable, Sendable, CaseIterable {
        case gmail, outlook
        var title: String { self == .gmail ? "Gmail" : "Outlook" }
    }
    enum Source: String, Codable, Sendable { case connectorProfile = "connector_profile", userEntered = "user_entered" }

    let engine: Engine
    let provider: Provider
    let connectionKey: String
    let email: String
    let reportedVia: Source
    let consentVersion: Int

    var id: String { "\(engine.rawValue):\(provider.rawValue):\(connectionKey)" }

    enum CodingKeys: String, CodingKey {
        case engine, provider, email
        case connectionKey = "connection_key", reportedVia = "reported_via", consentVersion = "consent_version"
    }

    init(engine: Engine, provider: Provider, connectionKey: String, email: String, reportedVia: Source) throws {
        guard let address = Self.normalizedEmail(email), (1...256).contains(connectionKey.count) else {
            throw MailAccountError.invalidAddress
        }
        self.engine = engine; self.provider = provider; self.connectionKey = connectionKey
        self.email = address; self.reportedVia = reportedVia; consentVersion = 1
    }

    static func normalizedEmail(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (3...254).contains(value.utf8.count),
              value.range(of: #"^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$"#, options: .regularExpression) != nil,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }
}

nonisolated struct MailAccountCandidate: Sendable, Identifiable {
    let engine: MailAccount.Engine
    let provider: MailAccount.Provider
    let connectionKey: String
    let email: String?
    var id: String { "\(engine.rawValue):\(provider.rawValue):\(connectionKey)" }
    func confirmed(email supplied: String? = nil) throws -> MailAccount {
        try MailAccount(engine: engine, provider: provider, connectionKey: connectionKey,
                        email: email ?? supplied ?? "", reportedVia: email == nil ? .userEntered : .connectorProfile)
    }
}

nonisolated enum MailAccountError: Error, LocalizedError {
    case invalidAddress, unavailable, timedOut, invalidResponse, keychain, signedOut, requestFailed, busy
    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter a complete email address, such as you@example.com."
        case .unavailable: "Connect your email account through your AI, then try again."
        case .timedOut: "The account check timed out. Please try again."
        case .invalidResponse: "Your AI couldn't confirm the connected account. Please try again."
        case .keychain: "Unlock your Mac so Sentient can save your account details securely."
        case .signedOut: "The saved cloud session needs attention. Try saving your email addresses again."
        case .requestFailed: "Your email addresses couldn't sync. Check your connection and try again."
        case .busy: "Another account change is finishing. Please try again."
        }
    }
}
