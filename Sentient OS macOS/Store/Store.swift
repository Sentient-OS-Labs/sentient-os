//
//  Store.swift
//  Sentient OS macOS
//
//  The single @ModelActor — the ONLY type that touches @Model objects (Arch §2.3, §6).
//  Callers hand it Sendable value types; it constructs/saves the models internally, which
//  quarantines SwiftData's non-Sendability to this one actor.
//
//  Key methods (pointer architecture — Documentation/Pointer Architecture (Kill the Ledger).md):
//   - record(artifact:verdict:summary:)  → ONE transaction: survivor summary version (junk/
//                                          sensitive save nothing) + the pointer advance
//   - cursors() / advanceCursor(_:forKey:) → the per-source pointers
//   - survivorSummaries()                → latest version per source (full vault generations)
//   - unsyncedSummaries() / markSynced(ids:) / markCorpusSynced(_:) → the updater's queue
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

/// A Sendable, read-only snapshot of ONE summary version — what the Database viewer renders.
/// We never hand live @Model objects to the UI.
struct SummaryRecord: Sendable, Identifiable {
    let id: String              // sourceID + "@" + createdAt (versions of one source stay distinct)
    let sourceID: String
    let kind: SourceKind
    let folder: String
    let title: String?
    let text: String
    let reminderFlagged: Bool
    let itemDate: Date?
    let syncedToVault: Date?
    let createdAt: Date

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

/// A Sendable survivor summary handed to Stage 2 (the cloud vault / the iterative updater).
/// `persistentID` is the exact row, so cloud jobs can stamp precisely what they consumed
/// (summaries are versioned — "stamp by sourceID" would be wrong).
struct SummaryItem: Sendable {
    let persistentID: PersistentIdentifier
    let sourceID: String
    let kind: SourceKind
    let folder: String
    let title: String?
    let text: String
    let reminderFlagged: Bool
    let itemDate: Date?
    let createdAt: Date
}

@ModelActor
actor Store {

    // MARK: The one write path

    /// Records the outcome of analyzing one artifact — ONE durable transaction:
    /// - Survivors INSERT a new `Summary` version (sourceID is not unique; our code appends
    ///   " — Edit" to the title when an older version exists). Junk/sensitive save NOTHING.
    /// - The artifact's pointer advances (`cursorKey` → `cursorValue`). For junk/sensitive the
    ///   cursor write IS the durable record — there is nothing else to save, and the pointer
    ///   simply never looks at the item again.
    func record(artifact: Artifact, verdict: Verdict, summary: SummaryDraft?) throws {
        if verdict == .survivor, let summary {
            let id = artifact.id
            let prior = (try? modelContext.fetchCount(
                FetchDescriptor<Summary>(predicate: #Predicate { $0.sourceID == id })
            )) ?? 0
            let title = (prior > 0 && summary.title != nil) ? summary.title! + " — Edit" : summary.title
            modelContext.insert(Summary(
                sourceID: id,
                kind: artifact.kind.rawValue,
                folder: artifact.metadata["folder"] ?? "",
                text: summary.text,
                title: title,
                reminderFlagged: summary.reminderFlagged,
                itemDate: artifact.itemDate,
                createdAt: Date()
            ))
        }
        upsertCursor(artifact.cursorValue, forKey: artifact.cursorKey)
        try modelContext.save()
    }

    // MARK: Pointers

    /// The full pointer map (sources read only their own keys; empty = first run ever).
    func cursors() -> [String: String] {
        let rows = (try? modelContext.fetch(FetchDescriptor<SourceCursor>())) ?? []
        var map: [String: String] = [:]
        for r in rows { map[r.key] = r.value }
        return map
    }

    func cursor(forKey key: String) -> String? {
        let descriptor = FetchDescriptor<SourceCursor>(predicate: #Predicate { $0.key == key })
        return (try? modelContext.fetch(descriptor))?.first?.value
    }

    /// Advance a pointer directly (Part II's proactive high-water mark; the pipeline goes
    /// through `record` so the advance shares the summary's transaction).
    func advanceCursor(_ value: String, forKey key: String) throws {
        upsertCursor(value, forKey: key)
        try modelContext.save()
    }

    private func upsertCursor(_ value: String, forKey key: String) {
        if let row = try? modelContext.fetch(
            FetchDescriptor<SourceCursor>(predicate: #Predicate { $0.key == key })
        ).first {
            row.value = value
            row.updatedAt = Date()
        } else {
            modelContext.insert(SourceCursor(key: key, value: value, updatedAt: Date()))
        }
    }

    // MARK: Stage 2 — the cloud vault & the iterative updater

    /// The corpus for FULL vault generations (initial gen / Regenerate): the LATEST version per
    /// source, oldest first (stable ordering → stable `#index` refs). A 50-version file
    /// contributes exactly one entry.
    func survivorSummaries() -> [SummaryItem] {
        let all = (try? modelContext.fetch(
            FetchDescriptor<Summary>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        )) ?? []
        var latest: [String: Summary] = [:]
        for s in all { latest[s.sourceID] = s }       // ascending walk → last write wins
        return latest.values
            .sorted { $0.createdAt < $1.createdAt }
            .map(item(from:))
    }

    /// The iterative updater's input queue: every version not yet folded into the vault,
    /// oldest first. Self-populating — rows are born with `syncedToVault == nil`.
    func unsyncedSummaries() -> [SummaryItem] {
        let rows = (try? modelContext.fetch(
            FetchDescriptor<Summary>(predicate: #Predicate { $0.syncedToVault == nil },
                                     sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        )) ?? []
        return rows.map(item(from:))
    }

    /// Reminder-flagged summaries newer than the proactive pointer — the judge's input
    /// (Part II §E). Oldest first; `after == nil` = never judged = everything flagged.
    func flaggedSummaries(after: Date?) -> [SummaryItem] {
        let floor = after ?? .distantPast
        let rows = (try? modelContext.fetch(
            FetchDescriptor<Summary>(predicate: #Predicate { $0.reminderFlagged && $0.createdAt > floor },
                                     sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        )) ?? []
        return rows.map(item(from:))
    }

    /// Stamp EXACTLY the rows a cloud job consumed (the updater's path). Failed/limited jobs
    /// stamp nothing — unstamped rows simply re-enter the queue (it self-heals).
    func markSynced(_ ids: [PersistentIdentifier], date: Date = Date()) {
        for id in ids {
            if let row = modelContext.model(for: id) as? Summary { row.syncedToVault = date }
        }
        try? modelContext.save()
    }

    /// Stamp the rows a FULL vault generation just represented: the exact corpus rows PLUS any
    /// older versions they supersede (same source, created no later than the corpus row).
    /// Race-safe: a version created after the corpus snapshot stays unsynced for the updater.
    func markCorpusSynced(_ corpus: [SummaryItem], date: Date = Date()) {
        var ceiling: [String: Date] = [:]
        for item in corpus { ceiling[item.sourceID] = item.createdAt }
        let unsynced = (try? modelContext.fetch(
            FetchDescriptor<Summary>(predicate: #Predicate { $0.syncedToVault == nil })
        )) ?? []
        for row in unsynced {
            if let c = ceiling[row.sourceID], row.createdAt <= c { row.syncedToVault = date }
        }
        try? modelContext.save()
    }

    private func item(from s: Summary) -> SummaryItem {
        SummaryItem(persistentID: s.persistentModelID,
                    sourceID: s.sourceID,
                    kind: SourceKind(rawValue: s.kind) ?? .file,
                    folder: s.folder,
                    title: s.title,
                    text: s.text,
                    reminderFlagged: s.reminderFlagged,
                    itemDate: s.itemDate,
                    createdAt: s.createdAt)
    }

    // MARK: Introspection (counts + the Database viewer)

    /// (distinct sources, total versions, pointer rows) — UI + debug.
    func counts() -> (sources: Int, versions: Int, cursors: Int) {
        let rows = (try? modelContext.fetch(FetchDescriptor<Summary>())) ?? []
        let cursors = (try? modelContext.fetchCount(FetchDescriptor<SourceCursor>())) ?? 0
        return (Set(rows.map(\.sourceID)).count, rows.count, cursors)
    }

    /// Every summary version as a Sendable snapshot, newest first (the Database viewer groups
    /// them into per-source version histories).
    func allSummaries() -> [SummaryRecord] {
        let rows = (try? modelContext.fetch(
            FetchDescriptor<Summary>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )) ?? []
        return rows.map { s in
            SummaryRecord(id: "\(s.sourceID)@\(s.createdAt.timeIntervalSince1970)",
                          sourceID: s.sourceID,
                          kind: SourceKind(rawValue: s.kind) ?? .file,
                          folder: s.folder,
                          title: s.title,
                          text: s.text,
                          reminderFlagged: s.reminderFlagged,
                          itemDate: s.itemDate,
                          syncedToVault: s.syncedToVault,
                          createdAt: s.createdAt)
        }
    }

    /// Wipe all persisted data (summaries + pointers). Backs the dev "Reset store" action so
    /// the pipeline re-judges everything from scratch.
    func reset() throws {
        try modelContext.delete(model: Summary.self)
        try modelContext.delete(model: SourceCursor.self)
        try modelContext.save()
    }
}
