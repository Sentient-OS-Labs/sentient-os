// AppleMailEvidence.swift
// Revalidate pending Mail summaries before cloud use and local references before card execution.
// Returns sanitized summaries or structural validity, never raw email. Doc: Ingestion/Documentation - Ingestion Pipeline.md

import Foundation

enum AppleMailEvidence {
    static func validatedCloud(_ notes: [CloudNote], store: CycleStore = .shared) async -> [CloudNote] {
        guard notes.contains(where: { $0.kind == .appleMail }) else { return notes }
        let current = await validated(await store.notes(), store: store)
        let allowed = Dictionary(current.filter { $0.kind == .appleMail }.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        return notes.filter { note in
            guard note.kind == .appleMail else { return true }
            guard let accepted = allowed[note.sourceID] else { return false }
            return accepted.text == note.text && accepted.title == note.title && accepted.itemDate == note.itemDate
        }
    }
    /// Fail closed on revoked access, account deselection, a rebuilt index, an unavailable body,
    /// changed content or reclassification. The next local run can safely recreate valid notes.
    static func validated(_ notes: [CycleNoteItem], store: CycleStore = .shared) async -> [CycleNoteItem] {
        let mail = notes.filter { $0.kind == .appleMail }
        guard !mail.isEmpty else { return notes }
        let selected = AppleMailSelection.accounts
        do {
            let snapshot = try await Task.detached(priority: .utility) {
                try AppleMailSnapshot(root: AppleMailSource.root(), selected: selected)
            }.value
            var allowed = Set<String>()
            for account in selected {
                let bucket = "appleMail:" + account
                let pending = mail.filter { $0.bucketKey == bucket }
                guard !pending.isEmpty else { continue }
                let receipts = try await store.mailReceipts(bucket)
                guard let checkpoint = try await store.mailCheckpoint(bucket) else { continue }
                let rows = Dictionary(uniqueKeysWithValues: snapshot.rows.filter { $0.account == account }.map { ($0.id, $0) })
                try await Task.detached(priority: .utility) { try snapshot.indexFiles(account: account) }.value
                for note in pending {
                    guard let receipt = receipts[note.sourceID], receipt.generation == snapshot.generation,
                          let row = rows[receipt.rowID], !row.excluded else { continue }
                    let valid = await Task.detached(priority: .utility) {
                        guard let message = try? snapshot.body(row) else { return false }
                        return AppleMailSource.contentDigest(message, sent: row.sent) == receipt.contentHash
                            && AppleMailSource.identity(salt: checkpoint.salt, row: row, message: message) == receipt.identity
                    }.value
                    if valid { allowed.insert(note.sourceID) }
                }
            }
            return notes.filter { $0.kind != .appleMail || allowed.contains($0.sourceID) }
        } catch { return notes.filter { $0.kind != .appleMail } }
    }

    /// Stored cards outlive CycleNotes. Reconstruct content-free references from survivor receipts
    /// and run the same local gate; an opted-out, missing or reclassified message cannot fire.
    static func canExecute(_ references: [String], store: CycleStore = .shared) async -> Bool {
        guard !references.isEmpty else { return false }
        do {
            var referencesOnly: [CycleNoteItem] = []
            for account in AppleMailSelection.accounts {
                let bucket = "appleMail:" + account
                let receipts = try await store.mailReceipts(bucket)
                for id in references where receipts[id] != nil {
                    referencesOnly.append(CycleNoteItem(id: id, bucketKey: bucket, kind: .appleMail, sourceID: id,
                        folder: "Apple Mail", itemDate: .distantPast, text: "", title: nil, reminderFlagged: false, createdAt: .distantPast))
                }
            }
            let valid = await validated(referencesOnly, store: store)
            return Set(valid.map(\.sourceID)) == Set(references)
        } catch { return false }
    }
}
