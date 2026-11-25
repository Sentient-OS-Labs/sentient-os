// Remembers exact accepted inputs after knowledge publication, across retries and relaunches.
// Version 2 supports multiple versions of one source; version 1 is read conservatively in place.
// Doc: Documentation - Proactive Intelligence.md

import Foundation
import CryptoKit
import Darwin

nonisolated struct VaultMergeCheckpoint: Sendable {
    typealias Input = VaultInput

    enum Failure: String, Error, LocalizedError {
        case invalidInput, invalidFingerprint, unsafeStorage, checkpointTooLarge
        var errorDescription: String? {
            "The knowledge base was updated, but its recovery checkpoint could not be saved."
        }
    }

    private struct Snapshot: Codable {
        let version: Int
        let inputIDs: [String]
        let inputDigest: String
        let vaultFingerprint: String
        let wholeInputCount: Int?
    }

    private struct LegacySnapshot: Decodable {
        let version: Int
        let inputHashes: [String: String]
        let inputDigest: String
        let vaultFingerprint: String
        let wholeInputCount: Int?
    }

    let file: URL
    private static let maximumBytes = 2 * 1_024 * 1_024
    private static let maximumInputs = 10_000

    init(file: URL = URL.sentientSupport.appendingPathComponent("proactive-vault-merge.json")) {
        self.file = file
    }

    /// Only exact versions are covered. A changed/new version cannot invalidate unrelated coverage.
    func coveredInputIDs(in inputs: [Input], vaultFingerprint: String) -> Set<String> {
        guard VaultInput.validIdentity(vaultFingerprint), let data = load(),
              let current = try? VaultInput.identities(inputs) else { return [] }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == 2 {
            guard snapshot.vaultFingerprint == vaultFingerprint,
                  VaultInput.validIdentity(snapshot.inputDigest),
                  snapshot.inputIDs.count <= Self.maximumInputs,
                  Set(snapshot.inputIDs).count == snapshot.inputIDs.count,
                  snapshot.inputIDs.allSatisfy(VaultInput.validIdentity) else { return [] }
            if let count = snapshot.wholeInputCount {
                guard count > Self.maximumInputs, snapshot.inputIDs.isEmpty,
                      current.count == count, Self.aggregate(current) == snapshot.inputDigest else { return [] }
                return current
            }
            guard !snapshot.inputIDs.isEmpty, Self.aggregate(Set(snapshot.inputIDs)) == snapshot.inputDigest else { return [] }
            return current.intersection(snapshot.inputIDs)
        }
        return legacyCoverage(data, inputs: inputs, vaultFingerprint: vaultFingerprint)
    }

    /// The caller supplies identities from the corpus actually consumed by the writer, including
    /// any previously covered inputs. Source IDs alone cannot prove which version was processed.
    func recordSuccessfulMerge(inputs: [Input], consumedInputIDs: Set<String>,
                               resultingVaultFingerprint: String) throws {
        guard VaultInput.validIdentity(resultingVaultFingerprint) else { throw Failure.invalidFingerprint }
        guard !consumedInputIDs.isEmpty else { return }
        guard consumedInputIDs.isSubset(of: try VaultInput.identities(inputs)) else { throw Failure.invalidInput }
        let wholeStage = consumedInputIDs.count > Self.maximumInputs
        let snapshot = Snapshot(version: 2, inputIDs: wholeStage ? [] : consumedInputIDs.sorted(),
                                inputDigest: Self.aggregate(consumedInputIDs),
                                vaultFingerprint: resultingVaultFingerprint,
                                wholeInputCount: wholeStage ? consumedInputIDs.count : nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumBytes else { throw Failure.checkpointTooLarge }
        try validateStorage()
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Remove only after successful queue cleanup, or on explicit reset.
    func clear() throws {
        var metadata = stat()
        guard file.path.withCString({ lstat($0, &metadata) }) == 0 else {
            if errno == ENOENT { return }
            throw Failure.unsafeStorage
        }
        try FileManager.default.removeItem(at: file)
    }

    private func load() -> Data? {
        guard (try? validateStorage()) != nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? Int, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: file), data.count <= Self.maximumBytes else { return nil }
        return data
    }

    private func legacyCoverage(_ data: Data, inputs: [Input], vaultFingerprint: String) -> Set<String> {
        guard let snapshot = try? JSONDecoder().decode(LegacySnapshot.self, from: data), snapshot.version == 1,
              snapshot.vaultFingerprint == vaultFingerprint,
              snapshot.inputHashes.count <= Self.maximumInputs,
              snapshot.inputHashes.allSatisfy({ VaultInput.validIdentity($0.key) && VaultInput.validIdentity($0.value) }),
              VaultInput.validIdentity(snapshot.inputDigest) else { return [] }
        if let count = snapshot.wholeInputCount {
            guard count > Self.maximumInputs, snapshot.inputHashes.isEmpty else { return [] }
            var hashes: [String: String] = [:]
            for input in inputs {
                guard let identity = try? input.identity() else { return [] }
                let key = Self.sourceHash(input.sourceID)
                // The old whole-stage digest could only have been written for an unambiguous set.
                if let previous = hashes[key], previous != identity { return [] }
                hashes[key] = identity
            }
            guard hashes.count == count, Self.legacyAggregate(hashes) == snapshot.inputDigest else { return [] }
            return Set(hashes.values)
        }
        guard !snapshot.inputHashes.isEmpty,
              Self.legacyAggregate(snapshot.inputHashes) == snapshot.inputDigest else { return [] }
        return Set(inputs.compactMap { input in
            guard let identity = try? input.identity(), snapshot.inputHashes[Self.sourceHash(input.sourceID)] == identity else { return nil }
            return identity
        })
    }

    private func validateStorage() throws {
        guard file.isFileURL else { throw Failure.unsafeStorage }
        let parent = file.deletingLastPathComponent().standardizedFileURL
        var directory = stat()
        guard parent.path.withCString({ lstat($0, &directory) }) == 0,
              directory.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeStorage }
        var existing = stat()
        if file.path.withCString({ lstat($0, &existing) }) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1 else { throw Failure.unsafeStorage }
        } else if errno != ENOENT { throw Failure.unsafeStorage }
    }

    private static func aggregate(_ identities: Set<String>) -> String {
        var digest = SHA256()
        for identity in identities.sorted() { digest.update(data: Data(identity.utf8)) }
        return hex(digest.finalize())
    }

    private static func legacyAggregate(_ hashes: [String: String]) -> String {
        var digest = SHA256()
        for key in hashes.keys.sorted() {
            digest.update(data: Data(key.utf8)); digest.update(data: Data(hashes[key]!.utf8))
        }
        return hex(digest.finalize())
    }

    private static func sourceHash(_ value: String) -> String { hex(SHA256.hash(data: Data(value.utf8))) }
    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
