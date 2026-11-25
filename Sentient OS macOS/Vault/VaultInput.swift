// Identifies an exact accepted summary for writer resume, merge recovery and queue cleanup.
// Different versions of one source remain distinct; identical inputs share one content-free ID.
// Doc: Documentation - Knowledge Base (Vault).md

import Foundation
import CryptoKit

nonisolated struct VaultInput: Sendable {
    let sourceID: String
    let kind: String
    let folder: String
    let title: String?
    let text: String
    let itemDate: Date?

    enum Failure: String, Error, LocalizedError {
        case invalidSourceID, invalidDate
        var errorDescription: String? {
            "The saved analysis inputs could not be verified. Your progress is saved."
        }
    }

    /// This encoding also matches the value hashes in version-1 merge checkpoints.
    func identity() throws -> String {
        guard !sourceID.isEmpty else { throw Failure.invalidSourceID }
        guard itemDate?.timeIntervalSince1970.isFinite != false else { throw Failure.invalidDate }
        var digest = SHA256()
        for value in [Optional(sourceID), kind, folder, title, text,
                      itemDate.map { String($0.timeIntervalSince1970.bitPattern, radix: 16) }] {
            if let value {
                let bytes = Data(value.utf8)
                digest.update(data: Data("\(bytes.count):".utf8))
                digest.update(data: bytes)
            } else { digest.update(data: Data("nil:".utf8)) }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func identities(_ inputs: [Self]) throws -> Set<String> {
        Set(try inputs.map { try $0.identity() })
    }

    static func validIdentity(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
