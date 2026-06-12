//
//  Models.swift
//  Sentient OS macOS
//
//  SwiftData persistence models — the local "plumbing" store (Arch §6, pointer architecture).
//   - Summary:      survivors only, VERSIONED — every (re-)analysis inserts a new row.
//   - SourceCursor: one row per pointer key — "processed everything up to HERE".
//   - Verdict:      the on-device "bouncer" decision (survivor / junk / sensitive).
//
//  There is NO ledger and NO tombstones (June 11 pointer rewrite): junk and sensitive items
//  leave ZERO trace — judged on-device, discarded, gone. "What's new?" is answered by the
//  per-source pointers, not by diffing against a permanent list of the past.
//
//  Only the `Store` @ModelActor (Store.swift) ever constructs or mutates these. Everything
//  else passes Sendable value types (see Sources/DataSource.swift). The vault — not this
//  DB — is the product; this is the pointer store + a staging area for survivor summaries.
//  Doc: Documentation/Pointer Architecture (Kill the Ledger).md
//

import Foundation
import SwiftData

/// The on-device model's per-artifact verdict. Survivors get a Summary row; junk/sensitive
/// save NOTHING (the pointer simply moves past them).
enum Verdict: Int, Codable, Sendable {
    case survivor = 0   // useful + not sensitive → summary row, enters the vault (Stage 2)
    case junk      = 1   // not worth keeping      → zero trace
    case sensitive = 2   // must never leave device → zero trace
}

/// One survivor summary VERSION. `sourceID` is deliberately NOT unique — re-analyzing an
/// edited artifact INSERTS a new row (our code appends " — Edit" to the title), because the
/// cloud model benefits from seeing the evolution. `survivorSummaries()` collapses to
/// latest-per-source for full vault generations; the iterative updater consumes every
/// unsynced version (`syncedToVault == nil` — rows are born unsynced, so the updater's
/// queue populates itself with zero extra bookkeeping).
@Model
final class Summary {
    var sourceID: String
    var kind: String                  // SourceKind.rawValue — the vault prompt's source-trust tiers key on it
    var folder: String                // files: root label ("Downloads"…); chats: chat name; notes: folder
    var text: String                  // ~30-word summary (the model writes this FIRST)
    var title: String?                // short human title (written after the summary)
    var reminderFlagged: Bool
    var itemDate: Date?               // the artifact's OWN date (file date / newest message / note mod-date)
    var syncedToVault: Date?          // nil until folded into the vault — the updater's input queue
    var createdAt: Date

    init(sourceID: String, kind: String, folder: String, text: String, title: String? = nil,
         reminderFlagged: Bool = false, itemDate: Date? = nil, syncedToVault: Date? = nil,
         createdAt: Date) {
        self.sourceID = sourceID
        self.kind = kind
        self.folder = folder
        self.text = text
        self.title = title
        self.reminderFlagged = reminderFlagged
        self.itemDate = itemDate
        self.syncedToVault = syncedToVault
        self.createdAt = createdAt
    }
}

/// One row per pointer key — "I have processed everything up to HERE." Advanced only after a
/// durable save (the cursor write IS the durable record for junk/sensitive, which save nothing
/// else), so a crashed run resumes rather than skips.
///
/// Keys in use:
///   "file:<FileRoot.id>"   per folder root, value "epochSeconds|path" (path = same-second tiebreak)
///   "whatsapp:<jid>"       per opted-in chat, value = highest consumed Z_PK
///   "imessage:<guid>"      per opted-in chat, value = highest consumed ROWID
///   "notes"                value "modEpochSeconds|noteUUID"
///   "proactive"            judged-summaries high-water mark (createdAt epoch), Part II §E
@Model
final class SourceCursor {
    @Attribute(.unique) var key: String
    var value: String
    var updatedAt: Date

    init(key: String, value: String, updatedAt: Date) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }
}
