// MailAccountCollection.swift
// Collects and queues email addresses when the connected mailbox starts processing.
// Missing connections and unknown addresses are skipped without a popup or manual entry.
// Doc: Documentation - Connected Email Accounts.md

import Foundation

nonisolated enum MailAccountCollection {
    enum Outcome: Sendable {
        case noConnection, noAddress, saved, pending
    }

    static func collect(engine: MailAccount.Engine, provider: MailAccount.Provider? = nil) async throws -> Outcome {
        let candidates: [MailAccountCandidate]
        do { candidates = try await MailAccountProbe.discover(engine: engine, provider: provider) }
        catch {
            try Task.checkCancellation()
            return .noConnection
        }
        try Task.checkCancellation()
        let accounts = candidates.compactMap(\.detectedAccount)
        guard !accounts.isEmpty else { return .noAddress }
        // Connector details are used only during discovery. Persist and send addresses alone.
        let synced = try await MailAccountCloud.shared.save(accounts.map(\.email))
        return synced ? .saved : .pending
    }
}
