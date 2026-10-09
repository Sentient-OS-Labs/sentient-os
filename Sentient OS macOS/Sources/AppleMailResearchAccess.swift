// Explicit raw-email research access, separate from local knowledge analysis selections.
// Captures revocable account leases; changing access invalidates prepared research evidence.
// Doc: Sources/Documentation - Sources - Local (Files, WhatsApp, iMessage, Notes).md

import Foundation

nonisolated enum AppleMailResearchAccess {
    static let key = "sources.appleMail.researchAccounts"
    private static let revisionKey = "sources.appleMail.researchRevision"

    struct Scope: Codable, Sendable, Equatable {
        let accounts: Set<String>
        let revision: String
    }

    static var scope: Scope? {
        let saved = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let accounts = saved.intersection(AppleMailSelection.accounts)
        guard !accounts.isEmpty, let revision = UserDefaults.standard.string(forKey: revisionKey) else { return nil }
        return Scope(accounts: accounts, revision: revision)
    }

    static func save(accounts: Set<String>) {
        let accounts = Set(accounts.compactMap { UUID(uuidString: $0)?.uuidString })
        if Set(UserDefaults.standard.stringArray(forKey: key) ?? []) != accounts {
            UserDefaults.standard.set(UUID().uuidString, forKey: revisionKey)
            UserDefaults.standard.set(accounts.sorted(), forKey: key)
        }
    }

    static func permits(_ captured: Scope) -> Bool {
        guard let current = scope else { return false }
        return current == captured
    }
}
