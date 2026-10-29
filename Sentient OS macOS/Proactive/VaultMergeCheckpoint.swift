// A completed knowledge merge survives failures in the later decide/research stages. This file
// stores hashes only; CycleStore retains the actual summaries until the whole cycle succeeds.

import Foundation
import CryptoKit
import Darwin

nonisolated struct VaultMergeCheckpoint: Sendable {
    struct Input: Sendable {
        let sourceID: String
        let kind: String
        let folder: String
        let title: String?
        let text: String
        let itemDate: Date?

        init(sourceID: String, kind: String, folder: String, title: String?, text: String, itemDate: Date?) {
            self.sourceID = sourceID; self.kind = kind; self.folder = folder
            self.title = title; self.text = text; self.itemDate = itemDate
        }
    }

    enum Failure: Error, LocalizedError {
        case invalidInput, invalidFingerprint, unsafeStorage, checkpointTooLarge
        var errorDescription: String? {
            "The knowledge base was updated, but its recovery checkpoint could not be saved."
        }
    }

    private struct Snapshot: Codable {
        let version: Int
        /// Source identities are hashed too: local paths and mail IDs are not persisted here.
        let inputHashes: [String: String]
        let inputDigest: String
        let vaultFingerprint: String
    }

    let file: URL
    private static let maximumBytes = 2 * 1_024 * 1_024
    private static let maximumInputs = 10_000

    init(file: URL = URL.sentientSupport.appendingPathComponent("proactive-vault-merge.json")) {
        self.file = file
    }

    /// Fail closed on missing, corrupt, incompatible, or stale checkpoints. Newly arrived or edited
    /// inputs remain unmerged; a source is covered only when its entire accepted input still matches.
    func coveredSourceIDs(in inputs: [Input], vaultFingerprint: String) -> Set<String> {
        guard Self.validHash(vaultFingerprint), let snapshot = load(),
              snapshot.vaultFingerprint == vaultFingerprint,
              let current = try? Self.hashes(inputs) else { return [] }
        return Set(inputs.compactMap { input in
            let key = Self.hash(Data(input.sourceID.utf8))
            return snapshot.inputHashes[key] == current[key] ? input.sourceID : nil
        })
    }

    /// Call immediately after a successful atomic vault replacement. Include previously covered IDs
    /// when another batch is merged; otherwise a retry could remerge the earlier batch. Record again
    /// after intentional app-owned vault mutations (writing samples) using the new fingerprint.
    /// Only IDs actually consumed by VaultCloud, plus earlier covered IDs, may be passed here.
    func recordSuccessfulMerge(inputs: [Input], consumedSourceIDs: Set<String>,
                               resultingVaultFingerprint: String) throws {
        guard Self.validHash(resultingVaultFingerprint) else { throw Failure.invalidFingerprint }
        // Empty consumed IDs never replace a useful recovery checkpoint.
        guard !consumedSourceIDs.isEmpty else { return }
        let selected = inputs.filter { consumedSourceIDs.contains($0.sourceID) }
        guard Set(selected.map(\.sourceID)) == consumedSourceIDs else { throw Failure.invalidInput }
        let hashes = try Self.hashes(selected)
        let snapshot = Snapshot(version: 1, inputHashes: hashes, inputDigest: Self.aggregate(hashes),
                                vaultFingerprint: resultingVaultFingerprint)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumBytes else { throw Failure.checkpointTooLarge }
        try validateStorage()
        // Foundation writes a sibling temporary file and atomically renames it. An interrupted save
        // leaves either the preceding complete checkpoint or the next complete checkpoint.
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Remove after CycleStore's successful wipe, and on reset. A missing file is already cleared.
    func clear() throws {
        var metadata = stat()
        guard file.path.withCString({ lstat($0, &metadata) }) == 0 else {
            if errno == ENOENT { return }
            throw Failure.unsafeStorage
        }
        // Unlinking a symlink does not follow it or delete its target.
        try FileManager.default.removeItem(at: file)
    }

    private func load() -> Snapshot? {
        guard (try? validateStorage()) != nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? Int, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: file), data.count <= Self.maximumBytes,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1, !snapshot.inputHashes.isEmpty,
              snapshot.inputHashes.count <= Self.maximumInputs,
              snapshot.inputHashes.allSatisfy({ Self.validHash($0.key) && Self.validHash($0.value) }),
              Self.validHash(snapshot.vaultFingerprint),
              snapshot.inputDigest == Self.aggregate(snapshot.inputHashes) else { return nil }
        return snapshot
    }

    private func validateStorage() throws {
        guard file.isFileURL else { throw Failure.unsafeStorage }
        let parent = file.deletingLastPathComponent().standardizedFileURL
        var directory = stat()
        guard parent.path.withCString({ lstat($0, &directory) }) == 0,
              directory.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeStorage }
        // The parent is app-owned. Permit system ancestor aliases such as /tmp in fixture storage,
        // but not a symlink replacing the parent or checkpoint itself.
        var existing = stat()
        if file.path.withCString({ lstat($0, &existing) }) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1 else { throw Failure.unsafeStorage }
        } else if errno != ENOENT { throw Failure.unsafeStorage }
    }

    private static func hashes(_ inputs: [Input]) throws -> [String: String] {
        guard inputs.count <= maximumInputs else { throw Failure.checkpointTooLarge }
        var result: [String: String] = [:]
        for input in inputs {
            guard !input.sourceID.isEmpty, input.itemDate?.timeIntervalSince1970.isFinite != false else {
                throw Failure.invalidInput
            }
            let key = hash(Data(input.sourceID.utf8))
            var digest = SHA256()
            for value in [Optional(input.sourceID), input.kind, input.folder, input.title, input.text,
                          input.itemDate.map { String($0.timeIntervalSince1970.bitPattern, radix: 16) }] {
                if let value {
                    let bytes = Data(value.utf8)
                    digest.update(data: Data("\(bytes.count):".utf8)); digest.update(data: bytes)
                } else { digest.update(data: Data("nil:".utf8)) }
            }
            let value = hex(digest.finalize())
            if let previous = result[key], previous != value { throw Failure.invalidInput }
            result[key] = value
        }
        return result
    }

    private static func aggregate(_ hashes: [String: String]) -> String {
        var digest = SHA256()
        for key in hashes.keys.sorted() {
            digest.update(data: Data(key.utf8)); digest.update(data: Data(hashes[key]!.utf8))
        }
        return hex(digest.finalize())
    }

    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func hash(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
