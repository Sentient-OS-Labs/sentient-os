//
//  Models.swift
//  Sentient OS macOS
//
//  SwiftData persistence models — the local "plumbing" store (Arch §6).
//   - LedgerEntry:  one tombstone per artifact EVER analyzed (dedup; permanent).
//   - Summary:      survivors only — the ~30-word summaries that feed the Stage-2 vault.
//   - SourceCursor: per-source resumable progress marker (one row per source kind).
//   - Verdict:      the on-device "bouncer" decision (survivor / junk / sensitive).
//
//  Only the `Store` @ModelActor (Store.swift) ever constructs or mutates these. Everything
//  else passes Sendable value types (see Sources/DataSource.swift). The vault — not this
//  DB — is the product; this is just the dedup ledger + a staging area for survivors.
//

import Foundation
import SwiftData

/// The on-device model's per-artifact verdict. Decides what survives (Arch §1.1, §5.2).
enum Verdict: Int, Codable, Sendable {
    case survivor = 0   // useful + not sensitive → tombstone + summary, enters vault (Stage 2)
    case junk      = 1   // not worth keeping      → tombstone only (summary discarded)
    case sensitive = 2   // must never leave device → tombstone only (summary discarded)
}

/// One row per artifact we've EVER analyzed — the permanent dedup tombstone.
@Model
final class LedgerEntry {
    @Attribute(.unique) var sourceID: String   // stable id, e.g. "file:/Users/…/a.pdf", "imessage:1234"
    var sourceKind: String                      // SourceKind.rawValue
    var folder: String = ""                     // files: which root it came from ("Downloads", "Desktop", a custom folder…); "" for db sources
    var signature: String                       // files: "size:mtime"; db sources: the cursor value
    var verdict: Int                            // Verdict.rawValue
    var firstSeen: Date
    var lastSeen: Date

    init(sourceID: String, sourceKind: String, folder: String = "", signature: String,
         verdict: Int, firstSeen: Date, lastSeen: Date) {
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.folder = folder
        self.signature = signature
        self.verdict = verdict
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// Survivors only — the clean summaries that get folded into the vault later (Stage 2).
@Model
final class Summary {
    @Attribute(.unique) var sourceID: String
    var text: String                  // ~30-word summary (the model writes this FIRST)
    var title: String?                // short human title (written after the summary)
    var reminderFlagged: Bool
    var syncedToVault: Date?          // nil until folded into the vault (Stage 2)
    var createdAt: Date

    init(sourceID: String, text: String, title: String? = nil,
         reminderFlagged: Bool = false, syncedToVault: Date? = nil, createdAt: Date) {
        self.sourceID = sourceID
        self.text = text
        self.title = title
        self.reminderFlagged = reminderFlagged
        self.syncedToVault = syncedToVault
        self.createdAt = createdAt
    }
}

/// One row per source kind — the cursor we advance only AFTER a durable save, so a
/// crashed overnight run resumes rather than skips (Arch §3).
@Model
final class SourceCursor {
    @Attribute(.unique) var kind: String   // SourceKind.rawValue
    var value: String                       // opaque marker (Z_PK, ROWID, mod-date, …)
    var updatedAt: Date

    init(kind: String, value: String, updatedAt: Date) {
        self.kind = kind
        self.value = value
        self.updatedAt = updatedAt
    }
}
