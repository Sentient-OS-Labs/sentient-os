//
//  Store.swift
//  Sentient OS macOS
//
//  The single @ModelActor — the ONLY type that touches @Model objects (Arch §2.3, §6).
//  Callers hand it Sendable value types; it constructs/saves the models internally, which
//  quarantines SwiftData's non-Sendability to this one actor.
//
//  Key methods:
//   - hasSeen(_:)                       → dedup check ("already analyzed?")
//   - save(artifact:verdict:summary:)   → tombstone always; Summary row only for survivors
//   - cursor(for:) / advanceCursor(_:for:) → per-source resumable progress
//   - counts()                          → ledger/summary totals (UI + debug self-test)
//

import Foundation
import SwiftData

/// A Sendable description of a survivor's summary, handed to the Store to persist.
/// (We never pass live `@Model` objects across actor boundaries.)
struct SummaryDraft: Sendable {
    var text: String
    var title: String?
    var reminderFlagged: Bool

    init(text: String, title: String? = nil, reminderFlagged: Bool = false) {
        self.text = text
        self.title = title
        self.reminderFlagged = reminderFlagged
    }
}

/// A Sendable, read-only snapshot of one analyzed artifact (ledger row + its survivor summary,
/// if any) — what the Database viewer renders. We never hand live @Model objects to the UI.
struct RecordSnapshot: Sendable, Identifiable {
    var id: String { sourceID }
    let sourceID: String
    let kind: SourceKind
    let folder: String          // files: which root it came from ("Downloads", …); "" for db sources
    let verdict: Verdict
    let signature: String
    let firstSeen: Date
    let lastSeen: Date
    let summary: String?        // survivors only
    let title: String?
    let reminderFlagged: Bool
    let createdAt: Date?

    /// On-disk path for file artifacts (sourceID is "file:/abs/path"); nil for DB sources.
    var filePath: String? { sourceID.hasPrefix("file:") ? String(sourceID.dropFirst(5)) : nil }
    var displayName: String {
        if let p = filePath { return URL(fileURLWithPath: p).lastPathComponent }
        return folder.isEmpty ? sourceID : folder      // DB sources: the chat/source name
    }
    var displayPath: String {
        guard let p = filePath else { return folder.isEmpty ? sourceID : folder }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

/// A Sendable survivor summary handed to Stage 2 (the cloud vault, Arch §8). Joins each `Summary`
/// (text/title/reminder) to its `LedgerEntry` source tags (folder/kind). Never a live @Model.
struct SummaryItem: Sendable {
    let sourceID: String
    let kind: SourceKind
    let folder: String
    let title: String?
    let text: String
    let reminderFlagged: Bool
}

@ModelActor
actor Store {

    // MARK: Dedup

    /// Has this artifact ever been analyzed (survivor, junk, or sensitive)?
    func hasSeen(_ sourceID: String) -> Bool {
        let target = sourceID
        let descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.sourceID == target })
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Filter candidates to those NOT yet in the ledger, or whose signature changed
    /// (new/modified items). Used before expensive extraction + inference so we never
    /// redo work. Candidates from one source are a single kind; we load that kind's
    /// ledger once and diff in memory.
    func newOrChanged(_ candidates: [Candidate]) -> [Candidate] {
        guard let kind = candidates.first?.kind.rawValue else { return [] }
        let entries = (try? modelContext.fetch(
            FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.sourceKind == kind })
        )) ?? []
        var seen: [String: String] = [:]
        for e in entries { seen[e.sourceID] = e.signature }
        return candidates.filter { seen[$0.id] != $0.signature }
    }

    // MARK: Save

    /// Records the outcome of analyzing one artifact.
    /// - Always upserts a `LedgerEntry` tombstone (the permanent dedup record).
    /// - Writes/updates a `Summary` row **only** for survivors; junk & sensitive are discarded
    ///   to a tombstone only (Arch §1.1). Caller guarantees `summary != nil` for `.survivor`.
    func save(artifact: Artifact, verdict: Verdict, summary: SummaryDraft?) throws {
        let now = Date()
        let id = artifact.id
        let folder = artifact.metadata["folder"] ?? ""   // which root this file came from (Arch §3.4)

        // Upsert the ledger tombstone.
        if let entry = try modelContext.fetch(
            FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.sourceID == id })
        ).first {
            entry.signature = artifact.signature
            entry.folder = folder
            entry.verdict = verdict.rawValue
            entry.lastSeen = now
        } else {
            modelContext.insert(LedgerEntry(
                sourceID: id,
                sourceKind: artifact.kind.rawValue,
                folder: folder,
                signature: artifact.signature,
                verdict: verdict.rawValue,
                firstSeen: now,
                lastSeen: now
            ))
        }

        // Survivors also get a Summary row; junk/sensitive never do.
        if verdict == .survivor, let summary {
            if let row = try modelContext.fetch(
                FetchDescriptor<Summary>(predicate: #Predicate { $0.sourceID == id })
            ).first {
                row.text = summary.text
                row.title = summary.title
                row.reminderFlagged = summary.reminderFlagged
            } else {
                modelContext.insert(Summary(
                    sourceID: id,
                    text: summary.text,
                    title: summary.title,
                    reminderFlagged: summary.reminderFlagged,
                    createdAt: now
                ))
            }
        }

        try modelContext.save()
    }

    // MARK: Cursors

    /// The last durable progress marker for a source (nil = never run → process everything).
    func cursor(for kind: SourceKind) -> String? {
        let raw = kind.rawValue
        let descriptor = FetchDescriptor<SourceCursor>(predicate: #Predicate { $0.kind == raw })
        return (try? modelContext.fetch(descriptor))?.first?.value
    }

    /// Advance a source's cursor — call ONLY after a durable save, so a crashed run
    /// resumes rather than skips (Arch §3).
    func advanceCursor(_ value: String, for kind: SourceKind) throws {
        let raw = kind.rawValue
        if let cursor = try modelContext.fetch(
            FetchDescriptor<SourceCursor>(predicate: #Predicate { $0.kind == raw })
        ).first {
            cursor.value = value
            cursor.updatedAt = Date()
        } else {
            modelContext.insert(SourceCursor(kind: raw, value: value, updatedAt: Date()))
        }
        try modelContext.save()
    }

    // MARK: Introspection (counts for UI / debug self-test)

    func counts() -> (ledger: Int, summaries: Int) {
        let ledger = (try? modelContext.fetchCount(FetchDescriptor<LedgerEntry>())) ?? 0
        let summaries = (try? modelContext.fetchCount(FetchDescriptor<Summary>())) ?? 0
        return (ledger, summaries)
    }

    /// Wipe all persisted data (ledger + summaries + cursors). Backs the debug "Reset store"
    /// action so the pipeline re-judges the same files from scratch.
    func reset() throws {
        try modelContext.delete(model: LedgerEntry.self)
        try modelContext.delete(model: Summary.self)
        try modelContext.delete(model: SourceCursor.self)
        try modelContext.save()
    }

    /// All analyzed artifacts as Sendable snapshots (newest first), joined with their summaries.
    func allRecords() -> [RecordSnapshot] {
        let entries = (try? modelContext.fetch(
            FetchDescriptor<LedgerEntry>(sortBy: [SortDescriptor(\.lastSeen, order: .reverse)])
        )) ?? []
        let summaries = (try? modelContext.fetch(FetchDescriptor<Summary>())) ?? []
        var byID: [String: Summary] = [:]
        for s in summaries { byID[s.sourceID] = s }

        return entries.map { e in
            let s = byID[e.sourceID]
            return RecordSnapshot(
                sourceID: e.sourceID,
                kind: SourceKind(rawValue: e.sourceKind) ?? .file,
                folder: e.folder,
                verdict: Verdict(rawValue: e.verdict) ?? .junk,
                signature: e.signature,
                firstSeen: e.firstSeen,
                lastSeen: e.lastSeen,
                summary: s?.text,
                title: s?.title,
                reminderFlagged: s?.reminderFlagged ?? false,
                createdAt: s?.createdAt
            )
        }
    }

    // MARK: Stage 2 — the cloud vault (Arch §8)

    /// All survivor summaries as Sendable value types, joined to their source tags, oldest first
    /// (stable ordering → stable `#index` refs). This is the cloud vault's raw material.
    func survivorSummaries() -> [SummaryItem] {
        let summaries = (try? modelContext.fetch(
            FetchDescriptor<Summary>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        )) ?? []
        let entries = (try? modelContext.fetch(FetchDescriptor<LedgerEntry>())) ?? []
        var meta: [String: (folder: String, kind: String)] = [:]
        for e in entries { meta[e.sourceID] = (e.folder, e.sourceKind) }
        return summaries.map { s in
            let m = meta[s.sourceID]
            return SummaryItem(
                sourceID: s.sourceID,
                kind: SourceKind(rawValue: m?.kind ?? "file") ?? .file,
                folder: m?.folder ?? "",
                title: s.title,
                text: s.text,
                reminderFlagged: s.reminderFlagged
            )
        }
    }

    /// Stamp every not-yet-synced survivor as folded into the vault (Stage-2 bookkeeping). v1 does
    /// a full rebuild, so this is just a marker for future incremental sync.
    func markAllSurvivorsSynced(date: Date = Date()) {
        let rows = (try? modelContext.fetch(
            FetchDescriptor<Summary>(predicate: #Predicate { $0.syncedToVault == nil })
        )) ?? []
        for r in rows { r.syncedToVault = date }
        try? modelContext.save()
    }
}
