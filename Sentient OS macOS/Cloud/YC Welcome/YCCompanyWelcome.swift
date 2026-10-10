// YCCompanyWelcome.swift
// The small, public company payload used by onboarding. It contains no founder identity.
// Validates display text and restricts logos to our own curated storage bucket.
// Doc: ../../Views/Onboarding/Documentation - Onboarding.md

import Foundation

nonisolated struct YCCompanyWelcome: Decodable, Sendable, Equatable {
    let companyName: String
    let welcomeLine: String
    let logoPath: String?
    let contentVersion: Int
    var attributionLine: String? = nil

    enum CodingKeys: String, CodingKey {
        case companyName = "company_name", welcomeLine = "welcome_line"
        case logoPath = "logo_path", contentVersion = "content_version"
        case attributionLine = "attribution_line"
    }

    var isValid: Bool {
        Self.validText(companyName, maximum: 100)
            && Self.validText(welcomeLine, maximum: 180)
            && contentVersion > 0
    }

    /// Optional presentation copy must never make an otherwise valid welcome unusable.
    var displayAttributionLine: String? {
        guard let attributionLine, Self.validText(attributionLine, maximum: 140) else { return nil }
        return attributionLine
    }

    var logoURL: URL? {
        guard let logoPath, logoPath.utf8.count <= 180,
              logoPath.range(of: #"^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+\.(png|jpg|webp)$"#,
                             options: .regularExpression) != nil else { return nil }
        return MailAccountCloudConfiguration.url
            .appendingPathComponent("storage/v1/object/public/yc-company-logos")
            .appendingPathComponent(logoPath)
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0)
                || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }
    }

    /// Exact domains only: no suffix matching, guessing mailbox names, or stripping plus tags.
    static func domain(from email: String) -> String? {
        guard let email = MailAccount.normalizedEmail(email),
              let domain = email.split(separator: "@").last.map(String.init),
              domain.utf8.count <= 253, !sharedDomains.contains(domain),
              domain.range(of: #"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"#,
                           options: .regularExpression) != nil else { return nil }
        return domain
    }

    // The server independently excludes these even if a client bypasses this early exit.
    static let sharedDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com",
        "icloud.com", "me.com", "mac.com", "yahoo.com", "ymail.com", "aol.com",
        "proton.me", "protonmail.com", "pm.me", "hey.com", "fastmail.com", "mail.com",
    ]
}
