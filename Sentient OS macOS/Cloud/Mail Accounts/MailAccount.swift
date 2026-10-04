// MailAccount.swift
// Transient connector discovery and address validation. Connector details are never serialized
// into the feedback contact list; collection passes only resolved email strings to storage.
// Doc: Documentation - Connected Email Accounts.md

import Foundation

nonisolated struct MailAccount: Sendable, Equatable, Identifiable {
    enum Engine: String, Codable, Sendable, CaseIterable { case chatgpt, claude }
    enum Provider: String, Codable, Sendable, CaseIterable {
        case gmail, outlook
        var title: String { self == .gmail ? "Gmail" : "Outlook" }
    }
    enum Source: String, Codable, Sendable {
        case connectorProfile = "connector_profile"
        case sentMailMetadata = "sent_mail_metadata"
    }

    let engine: Engine
    let provider: Provider
    let connectionKey: String
    let email: String
    let reportedVia: Source

    var id: String { "\(engine.rawValue):\(provider.rawValue):\(connectionKey)" }

    init(engine: Engine, provider: Provider, connectionKey: String, email: String, reportedVia: Source) throws {
        guard let address = Self.normalizedEmail(email), (1...256).contains(connectionKey.count) else {
            throw MailAccountError.invalidAddress
        }
        guard reportedVia != .sentMailMetadata || (engine == .claude && provider == .gmail) else {
            throw MailAccountError.invalidResponse
        }
        self.engine = engine; self.provider = provider; self.connectionKey = connectionKey
        self.email = address; self.reportedVia = reportedVia
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
    let reportedVia: MailAccount.Source

    init(engine: MailAccount.Engine, provider: MailAccount.Provider, connectionKey: String,
         email: String?, reportedVia: MailAccount.Source = .connectorProfile) {
        self.engine = engine; self.provider = provider; self.connectionKey = connectionKey
        self.email = email; self.reportedVia = reportedVia
    }

    var id: String { "\(engine.rawValue):\(provider.rawValue):\(connectionKey)" }
    var detectedAccount: MailAccount? {
        guard let email else { return nil }
        return try? MailAccount(engine: engine, provider: provider, connectionKey: connectionKey,
                                email: email, reportedVia: reportedVia)
    }
}

nonisolated enum MailAccountError: Error, LocalizedError {
    case invalidAddress, unavailable, timedOut, invalidResponse, keychain, signedOut, requestFailed, busy
    var errorDescription: String? {
        switch self {
        case .invalidAddress: "A valid email address couldn't be detected."
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
