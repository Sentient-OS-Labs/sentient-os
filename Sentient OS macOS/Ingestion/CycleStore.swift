//
//  CycleStore.swift
//  Sentient OS macOS
//
//  The iterative system's database — connector-agnostic, with its OWN on-disk container (isolated
//  from the old `Store`, so its models never schema-wipe the old dev DB). Three models:
//
//   - BucketPointer  DURABLE. One row per BUCKET (folder root / chat / "notes"). Normally the
//                    HIGH-WATER MARK — everything ≤ (order, tiebreak) is done, everything newer is
//                    new. During a bucket's FIRST run it also carries a FLOOR (the oldest item done
//                    so far, sinking one item at a time) so a crash mid-descent RESUMES below the
//                    floor instead of restarting; the floor collapses into the mark once the descent
//                    reaches the bottom. Mail carries its own versioned Int64 frontiers.
//   - AppleMailReceipt DURABLE. Opaque identity and content digest for accepted Mail only.
//                    Prevents duplicate summaries and revalidates later uses. No rejected ledger.
//   - CycleNote      EPHEMERAL. One survivor summary, wiped at cycle end (the proactive button).
//                    Junk/sensitive store nothing. `kind` + `sourceID` carry the cloud's trust tag.
//
//  Only this actor touches the @Models; callers pass Sendable value types (ItemKey, CycleNoteItem).
//  Every per-item commit reports a `CommitOutcome`: a FULL DISK comes back as `.diskFull` so the run
//  stops at the first one (every later item would fail the same way and be lost); any other store
//  failure is retried once, logged, and reported to Sentry once per kind per session, never per item.
//

import Foundation
import SwiftData

// MARK: - Models

/// DURABLE — one per bucket.
///
/// • Everyday state: `(order, tiebreak)` is the HIGH-WATER MARK (everything ≤ it is done); `floor` is nil.
/// • First-run state, while filling newest→oldest: `(order, tiebreak)` holds the TOP (the newest item
///   this first run covers — fixed for the whole descent), and `floor` is the oldest item done so far,
///   sinking one item at a time. Everything between floor and top is done; the descent continues below
///   the floor. A non-nil floor is the single tell that a first run is mid-flight — so a crash resumes
///   (below the floor) instead of restarting. On reaching the bottom the floor collapses to nil,
///   leaving `(order, tiebreak)` as a normal high-water mark.
@Model
final class BucketPointer {
    @Attribute(.unique) var bucketKey: String     // "file:<root.id>" / "notes" / "whatsapp:<jid>"
    var order: Double
    var tiebreak: String
    var floorOrder: Double?                        // non-nil ⇒ first run in progress (this is the FLOOR)
    var floorTiebreak: String?
    var updatedAt: Date
    /// Hosted-read provenance. Nil on existing/local buckets; a new origin requires backfill.
    var mcpReadOrigin: String? = nil
    /// Versioned Int64 Mail traversal state. Nil for every pre-existing source.
    var appleMailState: Data? = nil

    init(bucketKey: String, mark: ItemKey, floor: ItemKey? = nil, updatedAt: Date = Date()) {
        self.bucketKey = bucketKey
        self.order = mark.order
        self.tiebreak = mark.tiebreak
        self.floorOrder = floor?.order
        self.floorTiebreak = floor?.tiebreak
        self.updatedAt = updatedAt
    }
    var mark: ItemKey { ItemKey(order: order, tiebreak: tiebreak) }
    var floor: ItemKey? {
        guard let floorOrder else { return nil }
        return ItemKey(order: floorOrder, tiebreak: floorTiebreak ?? "")
    }
}

/// Only accepted messages have durable identity receipts. Rejected mail leaves no identity ledger.
@Model
final class AppleMailReceipt {
    @Attribute(.unique) var identity: String
    var bucketKey: String
    var contentHash: String
    var generation: String
    var rowID: Int64
    var messageKey: String? = nil
    init(identity: String, bucketKey: String, contentHash: String, generation: String, rowID: Int64, messageKey: String? = nil) {
        self.identity = identity; self.bucketKey = bucketKey; self.contentHash = contentHash
        self.generation = generation; self.rowID = rowID
        self.messageKey = messageKey
    }
}

struct AppleMailReceiptValue: Sendable {
    let identity: String
    let contentHash: String
    let generation: String
    let rowID: Int64
    var messageKey: String? = nil
}

/// EPHEMERAL — one survivor summary for one item, this cycle only.
@Model
final class CycleNote {
    var bucketKey: String
    var kind: String           // SourceKind.rawValue — the cloud's source-trust tiers key on it
    var sourceID: String       // "file:<path>" / "notes:<uuid>" / chat id — for the cloud's locSrc
    var folder: String         // display tag
    var itemDateEpoch: Double
    var text: String
    var title: String?
    var reminderFlagged: Bool
    var createdAt: Date

    init(bucketKey: String, kind: SourceKind, sourceID: String, folder: String, itemDate: Date,
         text: String, title: String?, reminderFlagged: Bool, createdAt: Date = Date()) {
        self.bucketKey = bucketKey
        self.kind = kind.rawValue
        self.sourceID = sourceID
        self.folder = folder
        self.itemDateEpoch = itemDate.timeIntervalSince1970
        self.text = text
        self.title = title
        self.reminderFlagged = reminderFlagged
        self.createdAt = createdAt
    }
}

/// A Sendable snapshot of one CycleNote — what VIEW SUMMARIES + the cloud calls consume. Codable so
/// a whole summary set can be exported/imported between devs (computed props below aren't stored).
struct CycleNoteItem: Codable, Sendable, Identifiable {
    let id: String             // sourceID (unique within a cycle)
    let bucketKey: String
    let kind: SourceKind
    let sourceID: String
    let folder: String
    let itemDate: Date
    let text: String
    let title: String?
    let reminderFlagged: Bool
    let createdAt: Date

    /// On-disk path for file artifacts (sourceID is "file:/abs/path"); nil for DB/chat sources.
    var filePath: String? { sourceID.hasPrefix("file:") ? String(sourceID.dropFirst(5)) : nil }
    var displayName: String {
        if let p = filePath { return URL(fileURLWithPath: p).lastPathComponent }
        return title ?? folder
    }
    var displayPath: String {
        guard sourceID.hasPrefix("file:") else { return folder }
        let p = String(sourceID.dropFirst(5))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + String(p.dropFirst(home.count)) : p
    }
}

/// The JSON shape for exporting/importing a summary set between devs (a debug tool — e.g. share a
/// rich CycleStore so a co-founder can build proactive against real context). Notes ONLY: pointers
/// are never exported (a dev's high-water marks are meaningless — and harmful — on another machine).
struct SummaryExport: Codable, Sendable {
    var version = 1
    var exportedAt = Date()
    var notes: [CycleNoteItem]
}

/// The survivor fields for one processed item, handed to an atomic per-item commit (note + marker in
/// ONE save). nil at a call site = a non-survivor (junk / sensitive / failed) — the marker still
/// advances past it, but no note is kept (zero trace).
struct NoteDraft: Sendable {
    let kind: SourceKind
    let sourceID: String
    let folder: String
    let itemDate: Date
    let text: String
    let title: String?
    let reminderFlagged: Bool
}

// MARK: - The actor

@ModelActor
actor CycleStore {
    private var calendarSnapshotReady = false
    func invalidateCalendarSnapshot() { calendarSnapshotReady = false }

    func mailCheckpoint(_ bucketKey: String) throws -> AppleMailCheckpoint? {
        guard let data = try fetchRow(bucketKey)?.appleMailState else { return nil }
        let state = try JSONDecoder().decode(AppleMailCheckpoint.self, from: data)
        guard (1...2).contains(state.version) else { throw AppleMailError.unsupportedSchema }
        return state
    }

    func mailReceipts(_ bucketKey: String) throws -> [String: AppleMailReceiptValue] {
        let rows = try modelContext.fetch(FetchDescriptor<AppleMailReceipt>(predicate: #Predicate { $0.bucketKey == bucketKey }))
        return Dictionary(uniqueKeysWithValues: rows.map { r in
            (r.identity, AppleMailReceiptValue(identity: r.identity, contentHash: r.contentHash, generation: r.generation, rowID: r.rowID, messageKey: r.messageKey))
        })
    }

    /// Summary, survivor receipt, rejected-summary removal and ALL progress commit together.
    /// `remove` is used when a formerly accepted message becomes excluded or disappears.
    func commitMail(bucketKey: String, state: AppleMailCheckpoint, note: NoteDraft? = nil,
                    receipt: AppleMailReceiptValue? = nil, remove: Set<String> = []) -> CommitOutcome {
        guard let data = try? JSONEncoder().encode(state) else { return .failed }
        let replacing = remove.union(note.map { [$0.sourceID] } ?? [])
        return commit(bucketKey: bucketKey, note: note, prepare: {
            for id in replacing {
                let notes = try self.modelContext.fetch(FetchDescriptor<CycleNote>(predicate: #Predicate { $0.sourceID == id && $0.bucketKey == bucketKey }))
                for n in notes { self.modelContext.delete(n) }
            }
            for id in remove {
                let receipts = try self.modelContext.fetch(FetchDescriptor<AppleMailReceipt>(predicate: #Predicate { $0.identity == id }))
                for r in receipts { self.modelContext.delete(r) }
            }
            if let receipt {
                let id = receipt.identity
                let existing = try self.modelContext.fetch(FetchDescriptor<AppleMailReceipt>(predicate: #Predicate { $0.identity == id })).first
                if let existing, !remove.contains(id) {
                    existing.contentHash = receipt.contentHash; existing.generation = receipt.generation; existing.rowID = receipt.rowID
                    existing.messageKey = receipt.messageKey
                } else {
                    self.modelContext.insert(AppleMailReceipt(identity: receipt.identity, bucketKey: bucketKey,
                        contentHash: receipt.contentHash, generation: receipt.generation, rowID: receipt.rowID, messageKey: receipt.messageKey))
                }
            }
        }, apply: { r in r.appleMailState = data; r.updatedAt = Date() }, make: {
            let r = BucketPointer(bucketKey: bucketKey, mark: ItemKey(order: 0, tiebreak: ""))
            r.appleMailState = data; return r
        })
    }

    #if DEBUG
    /// Narrow fault seam for the real transaction test; never applies to non-MCP commits.
    private var failNextHostedCommit = false
    func failNextMCPCommitForTesting() { failNextHostedCommit = true }
    #endif

    // MARK: Pointers (durable)

    /// The high-water mark for a bucket, or nil if it's never run.
    func pointer(_ bucketKey: String) -> ItemKey? { row(bucketKey)?.mark }

    /// Unlike the UI convenience fetch, a failed ingestion checkpoint read must propagate.
    func mcpCheckpoint(_ bucketKey: String) throws -> (mark: ItemKey, origin: String?)? {
        guard let r = try fetchRow(bucketKey) else { return nil }
        return (r.mark, r.mcpReadOrigin)
    }

    /// A bucket's full durable state, or nil if it's never run: the high-water mark (or, mid-first-run,
    /// the TOP), plus the FLOOR when a first run is mid-descent. A non-nil floor ⇒ resume that descent
    /// (strictly below the floor) rather than restart. IterativeRun reads this to pick per-bucket mode.
    func pointerState(_ bucketKey: String) -> (mark: ItemKey, floor: ItemKey?)? {
        guard let r = row(bucketKey) else { return nil }
        return (r.mark, r.floor)
    }

    /// Per-bucket hints handed to connectors for efficient `> mark` listing. A bucket mid-first-run
    /// (floor set) is OMITTED so its connector returns its FULL set — the descent needs items BELOW
    /// its top, which a `> mark` hint would hide. IterativeRun still filters/advances authoritatively.
    func connectorMarks() -> [String: ItemKey] {
        let rows: [BucketPointer]
        do { rows = try modelContext.fetch(FetchDescriptor<BucketPointer>()) }
        catch {
            Diagnostics.report(.storeReadFailed, phase: .read, reason: "connector_marks", error: error)
            return [:]
        }
        return Dictionary(rows.filter { $0.floor == nil }.map { ($0.bucketKey, $0.mark) },
                          uniquingKeysWith: { a, _ in a })
    }

    /// Set a bucket's mark directly (used by the Gmail cloud leg, which stamps a run-time pointer and
    /// has no on-device descent). On-device runs use the atomic `advance` / `sinkFloor` instead.
    @discardableResult
    func setPointer(_ bucketKey: String, _ mark: ItemKey) -> CommitOutcome {
        commit(bucketKey: bucketKey, note: nil, apply: { r in
            r.order = mark.order; r.tiebreak = mark.tiebreak; r.updatedAt = Date()
        }, make: {
            BucketPointer(bucketKey: bucketKey, mark: mark)
        })
    }

    /// Initial reset for one bucket: drop its pointer AND its ephemeral notes (fresh top→bottom).
    func clearBucket(_ bucketKey: String) {
        if let r = row(bucketKey) { modelContext.delete(r) }
        do {
            try modelContext.delete(model: CycleNote.self, where: #Predicate { $0.bucketKey == bucketKey })
            try modelContext.save()
        } catch { modelContext.rollback(); report(error, op: "clear_bucket") }
    }

    /// Throwing fetch — lets write paths tell "no row exists" apart from "the fetch failed" (B9). A
    /// swallowed failure here is what let the insert-branch fire on a row that DID exist, colliding on
    /// the @unique key and losing the mark forever.
    private func fetchRow(_ bucketKey: String) throws -> BucketPointer? {
        try modelContext.fetch(
            FetchDescriptor<BucketPointer>(predicate: #Predicate { $0.bucketKey == bucketKey })
        ).first
    }

    /// The scheme prefix of a bucketKey ("whatsapp" / "imessage" / "file" / "notes") — the only part
    /// safe to log: the full key carries a chat's phone-number JID or a user file path, and every
    /// Log() line ships to Sentry as a Release breadcrumb.
    nonisolated static func scheme(_ bucketKey: String) -> Substring { bucketKey.prefix(while: { $0 != ":" }) }

    /// Read-only convenience (pointer / pointerState). A failed fetch degrades to nil (re-listing),
    /// but is now surfaced instead of silently swallowed.
    private func row(_ bucketKey: String) -> BucketPointer? {
        do { return try fetchRow(bucketKey) }
        catch {
            Log("CycleStore.row(\(Self.scheme(bucketKey))) fetch failed: \(ErrorLabel(error))")
            report(error, op: "fetch")
            return nil
        }
    }

    // MARK: Failure reporting

    /// What a per-item commit did. `.diskFull` is the one outcome the RUN must act on: stop now,
    /// nothing after this can be saved. `.failed` is any other store failure (already retried once,
    /// logged, reported); the mark for that one item wasn't persisted, so it simply reprocesses next
    /// run, and the run continues.
    enum CommitOutcome: Sendable { case saved, diskFull, failed }

    /// Store failure kinds (domain + code) already reported to Sentry this process. A full disk or a
    /// wedged store fails EVERY item the same way; one event per kind is the signal, hundreds are noise
    /// (and each `capture(error)` used to snapshot every thread on the caller). Structure only.

    private func report(_ error: Error, op: String) {
        let ns = error as NSError
        CrashReporting.captureEvent("store.commit_failed", level: .error,
            tags: Diagnostics.errorFields(error).merging(["op": op]) { _, new in new },
            fingerprint: ["store", "commit_failed", op, Diagnostics.errorFields(error)["error_domain"] ?? "application", String(ns.code)])
    }

    /// The collision-safe update-or-insert for a bucket's pointer, committing an optional survivor
    /// note in the SAME save (the crash-safety atomicity). B9: a fetch or save failure no longer
    /// swallows the mark — on failure we roll back, then retry as an explicit update of the row that
    /// actually exists (the unique-collision case), so a bucket can't reprocess forever. A FULL DISK
    /// is the exception: no retry (it would fail identically), no per-item Sentry event; the caller
    /// gets `.diskFull` and stops the run (a run that grinds on burns the whole night's engine time
    /// on results it can't keep, then repeats it the next night; field-found 2026-08-15).
    private func commit(bucketKey: String, note: NoteDraft?,
                        prepare: (() throws -> Void)? = nil,
                        apply: (BucketPointer) -> Void, make: () -> BucketPointer) -> CommitOutcome {
        func attempt() throws {
            try prepare?()
            if let note { insertNote(bucketKey: bucketKey, note: note) }
            if let r = try fetchRow(bucketKey) { apply(r) }
            else { modelContext.insert(make()) }
            try modelContext.save()
        }
        do { try attempt(); return .saved }
        catch {
            modelContext.rollback()
            if DiskSpace.isDiskFull(error) {
                Log("CycleStore.commit(\(Self.scheme(bucketKey))) failed: disk full — mark NOT persisted; the run must stop")
                return .diskFull
            }
            Log("CycleStore.commit(\(Self.scheme(bucketKey))) failed: \(ErrorLabel(error)) — rolling back, retrying as update")
            report(error, op: "commit")
            do {
                try attempt()   // the row that DOES exist now takes the update path
                return .saved
            } catch {
                modelContext.rollback()
                if DiskSpace.isDiskFull(error) { return .diskFull }
                Log("CycleStore.commit(\(Self.scheme(bucketKey))) recovery failed: \(ErrorLabel(error)) — mark NOT persisted this item")
                report(error, op: "commit_retry")
                return .failed
            }
        }
    }

    // MARK: Notes (ephemeral)

    func recordNote(bucketKey: String, kind: SourceKind, sourceID: String, folder: String,
                    itemDate: Date, text: String, title: String?, reminderFlagged: Bool) {
        insertNote(bucketKey: bucketKey,
                   note: NoteDraft(kind: kind, sourceID: sourceID, folder: folder, itemDate: itemDate,
                                   text: text, title: title, reminderFlagged: reminderFlagged))
        do { try modelContext.save() }
        catch { modelContext.rollback(); report(error, op: "record_note") }
    }

    private func insertNote(bucketKey: String, note: NoteDraft) {
        modelContext.insert(CycleNote(bucketKey: bucketKey, kind: note.kind, sourceID: note.sourceID,
                                      folder: note.folder, itemDate: note.itemDate, text: note.text,
                                      title: note.title, reminderFlagged: note.reminderFlagged))
    }

    // MARK: Atomic per-item commits (the crash-safety core — note + marker in ONE save)

    /// EVERYDAY (iterative) — record an optional survivor note AND advance the high-water bookmark to
    /// `mark`, in one save. No gap between the two writes ⇒ a crash can never leave a note without its
    /// bookmark (which would re-summarize the item into a duplicate). Clears any floor.
    func advance(bucketKey: String, note: NoteDraft?, to mark: ItemKey) -> CommitOutcome {
        commit(bucketKey: bucketKey, note: note, apply: { r in
            r.order = mark.order; r.tiebreak = mark.tiebreak
            r.floorOrder = nil; r.floorTiebreak = nil; r.updatedAt = Date()
        }, make: {
            BucketPointer(bucketKey: bucketKey, mark: mark)
        })
    }

    /// Commit a whole hosted read: every accepted window, its boundary and origin together.
    /// Explicit initial reads replace old notes only inside this successful transaction.
    /// Automatic backfills preserve pending notes from earlier cycles or origins.
    func commitMCPRead(bucketKey: String, notes: [NoteDraft], through mark: ItemKey,
                       origin: String, replaceNotes: Bool) -> CommitOutcome {
        commit(bucketKey: bucketKey, note: nil, prepare: {
            if replaceNotes {
                // Batch delete executes outside the pending object changes. Delete fetched
                // objects so a failed save can roll back the entire replacement.
                let previous = try self.modelContext.fetch(FetchDescriptor<CycleNote>(
                    predicate: #Predicate { $0.bucketKey == bucketKey }))
                for note in previous { self.modelContext.delete(note) }
            }
            for note in notes { self.insertNote(bucketKey: bucketKey, note: note) }
            #if DEBUG
            if self.failNextHostedCommit {
                self.failNextHostedCommit = false
                throw CocoaError(.fileWriteOutOfSpace)
            }
            #endif
        }, apply: { r in
            r.order = mark.order; r.tiebreak = mark.tiebreak
            r.floorOrder = nil; r.floorTiebreak = nil
            r.mcpReadOrigin = origin; r.updatedAt = Date()
        }, make: {
            let r = BucketPointer(bucketKey: bucketKey, mark: mark)
            r.mcpReadOrigin = origin
            return r
        })
    }

    /// A complete local calendar snapshot replaces pending summaries and its coverage checkpoint
    /// together, including an empty result. A crash never publishes half a schedule. Rejected event
    /// IDs and raw content are absent from both the notes and the checkpoint.
    func commitCalendarSnapshot(_ snapshot: AppleCalendarSource.Snapshot, notes: [NoteDraft]) -> CommitOutcome {
        // Cancellation may arrive while the caller is waiting to enter this actor. Keep
        // earlier notes hidden and leave the persisted snapshot untouched in that case.
        calendarSnapshotReady = false
        guard !Task.isCancelled else { return .failed }
        let key = AppleCalendarSource.bucketKey
        let mark = ItemKey(order: snapshot.capturedAt.timeIntervalSince1970, tiebreak: snapshot.coverage.encoded)
        let result = commit(bucketKey: key, note: nil, prepare: {
            guard AppleCalendarSource.isEnabled, snapshot.coverage.matchesSelection else {
                throw AppleCalendarSource.ReadError.changed
            }
            let previous = try self.modelContext.fetch(FetchDescriptor<CycleNote>(
                predicate: #Predicate { $0.bucketKey == key }))
            for note in previous { self.modelContext.delete(note) }
            for note in notes + [snapshot.marker] { self.insertNote(bucketKey: key, note: note) }
        }, apply: { r in
            r.order = mark.order; r.tiebreak = mark.tiebreak
            r.floorOrder = nil; r.floorTiebreak = nil; r.mcpReadOrigin = nil; r.updatedAt = Date()
        }, make: { BucketPointer(bucketKey: key, mark: mark) })
        calendarSnapshotReady = result == .saved
        return result
    }

    /// FIRST RUN (initial descent) — record an optional survivor note AND sink the floor to `floor`
    /// (top stays fixed), in one save. Creates the row with `top` on the first step. A crash leaves an
    /// honest floor → the next run resumes strictly below it.
    func sinkFloor(bucketKey: String, note: NoteDraft?, top: ItemKey, floor: ItemKey) -> CommitOutcome {
        commit(bucketKey: bucketKey, note: note, apply: { r in
            r.order = top.order; r.tiebreak = top.tiebreak
            r.floorOrder = floor.order; r.floorTiebreak = floor.tiebreak; r.updatedAt = Date()
        }, make: {
            BucketPointer(bucketKey: bucketKey, mark: top, floor: floor)
        })
    }

    /// FIRST RUN done — collapse: clear the floor, leaving `(order, tiebreak)` (the top) as a normal
    /// high-water mark. From here the bucket is in everyday mode. (Mutates an existing row only — no
    /// insert — so it can't hit the unique-collision path; still capture a swallowed save, since a
    /// stuck floor would re-run the descent and re-summarize already-done items.)
    func collapseFloor(_ bucketKey: String) {
        do {
            if let r = try fetchRow(bucketKey) { r.floorOrder = nil; r.floorTiebreak = nil; r.updatedAt = Date() }
            try modelContext.save()
        } catch {
            Log("CycleStore.collapseFloor(\(Self.scheme(bucketKey))) failed: \(ErrorLabel(error))")
            report(error, op: "collapse_floor")
        }
    }

    /// Every current-cycle note, newest first (VIEW SUMMARIES + the cloud corpus).
    func notes() -> [CycleNoteItem] {
        let rows: [CycleNote]
        do { rows = try modelContext.fetch(FetchDescriptor<CycleNote>(sortBy: [SortDescriptor(\.itemDateEpoch, order: .reverse)])) }
        catch {
            Diagnostics.report(.storeReadFailed, phase: .read, reason: "cycle_notes", error: error)
            return []
        }
        let calendarMark = pointer(AppleCalendarSource.bucketKey)
        let calendarAllowed = calendarSnapshotReady && AppleCalendarSource.isEnabled
            && calendarMark.flatMap { AppleCalendarSource.Coverage.decode($0.tiebreak) }?.matchesSelection == true
        return rows.filter { $0.kind != SourceKind.appleCalendar.rawValue || calendarAllowed }.map(item(from:))
    }

    /// End-of-cycle wipe (fired by the proactive button) — pointers persist, notes do not.
    func wipeAllNotes() {
        do {
            try modelContext.delete(model: CycleNote.self)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            Diagnostics.report(.cleanupFailed, phase: .reset, reason: "wipeAllNotes", error: error)
        }
    }

    /// Clear only the corpus actually consumed. Mail notes withheld after lost access or a
    /// temporary body failure remain pending for a later validated cycle.
    func wipeNotes(sourceIDs: Set<String>) {
        do {
            let notes = try modelContext.fetch(FetchDescriptor<CycleNote>())
            for note in notes where sourceIDs.contains(note.sourceID) { modelContext.delete(note) }
            try modelContext.save()
        } catch { modelContext.rollback(); report(error, op: "wipe_consumed") }
    }

    /// Factory reset — delete EVERY pointer and EVERY note (the dev "Reset everything" button pairs
    /// this with wiping the vault). After this, the next run is a fresh first run for every bucket.
    func wipeEverything() {
        do {
            try modelContext.delete(model: AppleMailReceipt.self)
            try modelContext.delete(model: CycleNote.self)
            try modelContext.delete(model: BucketPointer.self)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            Diagnostics.report(.cleanupFailed, phase: .reset, reason: "wipeEverything", error: error)
        }
    }

    /// Bulk-insert notes from an export file (dev cross-pollination — share a rich summary set with a
    /// co-founder). Preserves each note's original createdAt + itemDate so proactive's recency windows
    /// stay faithful to the source timeline. `replace` wipes existing notes first. Pointers are NEVER
    /// touched — an import carries summaries only, so the importer's own processing state is unaffected.
    func importNotes(_ items: [CycleNoteItem], replace: Bool) {
        if replace { try? modelContext.delete(model: CycleNote.self) }
        for it in items {
            modelContext.insert(CycleNote(
                bucketKey: it.bucketKey, kind: it.kind, sourceID: it.sourceID,
                folder: it.folder, itemDate: it.itemDate, text: it.text,
                title: it.title, reminderFlagged: it.reminderFlagged, createdAt: it.createdAt))
        }
        try? modelContext.save()
    }

    /// (notes, distinct buckets) — for the dev UI counts.
    func counts() -> (notes: Int, buckets: Int) {
        let n = (try? modelContext.fetch(FetchDescriptor<CycleNote>())) ?? []
        return (n.count, Set(n.map(\.bucketKey)).count)
    }

    private func item(from n: CycleNote) -> CycleNoteItem {
        CycleNoteItem(id: n.sourceID, bucketKey: n.bucketKey,
                      kind: SourceKind(rawValue: n.kind) ?? .file, sourceID: n.sourceID,
                      folder: n.folder, itemDate: Date(timeIntervalSince1970: n.itemDateEpoch),
                      text: n.text, title: n.title, reminderFlagged: n.reminderFlagged, createdAt: n.createdAt)
    }
}

// MARK: - Shared instance (its own container)

extension CycleStore {
    /// The app-wide iterative store, backed by its OWN on-disk store ("IterativeCycle.store" under
    /// the namespaced `SentientOS` root in Application Support). A migration/open failure must
    /// preserve the existing data for recovery, never silently delete the database.
    #if DEBUG
    @TaskLocal static var acceptanceStore: CycleStore?
    #endif

    static var shared: CycleStore {
        #if DEBUG
        if let acceptanceStore { return acceptanceStore }
        #endif
        return persistentStore
    }

    private static let persistentStore: CycleStore = {
        let schema = Schema([BucketPointer.self, CycleNote.self, AppleMailReceipt.self])
        let url = URL.sentientSupport.appending(path: "IterativeCycle.store")
        let config = ModelConfiguration(schema: schema, url: url)
        do {
            let container = try ModelContainer(for: schema, configurations: config)
            return CycleStore(modelContainer: container)
        } catch {
            Log("CycleStore: unable to open the existing store (\(ErrorLabel(error))); data preserved")
            fatalError("CycleStore: unable to open its ModelContainer; existing data was preserved")
        }
    }()
}
