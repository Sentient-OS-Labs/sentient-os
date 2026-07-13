//
//  CycleStore.swift
//  Sentient OS macOS
//
//  The iterative system's database — connector-agnostic, with its OWN on-disk container (isolated
//  from the old `Store`, so its models never schema-wipe the old dev DB). Two models:
//
//   - BucketPointer  DURABLE. One row per BUCKET (folder root / chat / "notes"). Normally the
//                    HIGH-WATER MARK — everything ≤ (order, tiebreak) is done, everything newer is
//                    new. During a bucket's FIRST run it also carries a FLOOR (the oldest item done
//                    so far, sinking one item at a time) so a crash mid-descent RESUMES below the
//                    floor instead of restarting; the floor collapses into the mark once the descent
//                    reaches the bottom. The ONLY state that survives a cycle.
//   - CycleNote      EPHEMERAL. One survivor summary, wiped at cycle end (the proactive button).
//                    Junk/sensitive store nothing. `kind` + `sourceID` carry the cloud's trust tag.
//
//  Only this actor touches the @Models; callers pass Sendable value types (ItemKey, CycleNoteItem).
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

    // MARK: Pointers (durable)

    /// The high-water mark for a bucket, or nil if it's never run.
    func pointer(_ bucketKey: String) -> ItemKey? { row(bucketKey)?.mark }

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
        let rows = (try? modelContext.fetch(FetchDescriptor<BucketPointer>())) ?? []
        return Dictionary(rows.filter { $0.floor == nil }.map { ($0.bucketKey, $0.mark) },
                          uniquingKeysWith: { a, _ in a })
    }

    /// Set a bucket's mark directly (used by the Gmail cloud leg, which stamps a run-time pointer and
    /// has no on-device descent). On-device runs use the atomic `advance` / `sinkFloor` instead.
    func setPointer(_ bucketKey: String, _ mark: ItemKey) {
        commit(bucketKey: bucketKey, note: nil, apply: { r in
            r.order = mark.order; r.tiebreak = mark.tiebreak; r.updatedAt = Date()
        }, make: {
            BucketPointer(bucketKey: bucketKey, mark: mark)
        })
    }

    /// Initial reset for one bucket: drop its pointer AND its ephemeral notes (fresh top→bottom).
    func clearBucket(_ bucketKey: String) {
        if let r = row(bucketKey) { modelContext.delete(r) }
        try? modelContext.delete(model: CycleNote.self, where: #Predicate { $0.bucketKey == bucketKey })
        try? modelContext.save()
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
            CrashReporting.capture(error)
            return nil
        }
    }

    /// The collision-safe update-or-insert for a bucket's pointer, committing an optional survivor
    /// note in the SAME save (the crash-safety atomicity). B9: a fetch or save failure no longer
    /// swallows the mark — on failure we roll back, then retry as an explicit update of the row that
    /// actually exists (the unique-collision case), so a bucket can't reprocess forever.
    private func commit(bucketKey: String, note: NoteDraft?,
                        apply: (BucketPointer) -> Void, make: () -> BucketPointer) {
        func attempt() throws {
            if let note { insertNote(bucketKey: bucketKey, note: note) }
            if let r = try fetchRow(bucketKey) { apply(r) }
            else { modelContext.insert(make()) }
            try modelContext.save()
        }
        do { try attempt() }
        catch {
            Log("CycleStore.commit(\(Self.scheme(bucketKey))) failed: \(ErrorLabel(error)) — rolling back, retrying as update")
            CrashReporting.capture(error)
            modelContext.rollback()
            do {
                if let note { insertNote(bucketKey: bucketKey, note: note) }
                if let r = try fetchRow(bucketKey) { apply(r) }
                else { modelContext.insert(make()) }   // genuinely no row → last-resort insert
                try modelContext.save()
            } catch {
                modelContext.rollback()
                Log("CycleStore.commit(\(Self.scheme(bucketKey))) recovery failed: \(ErrorLabel(error)) — mark NOT persisted this item")
                CrashReporting.capture(error)
            }
        }
    }

    // MARK: Notes (ephemeral)

    func recordNote(bucketKey: String, kind: SourceKind, sourceID: String, folder: String,
                    itemDate: Date, text: String, title: String?, reminderFlagged: Bool) {
        insertNote(bucketKey: bucketKey,
                   note: NoteDraft(kind: kind, sourceID: sourceID, folder: folder, itemDate: itemDate,
                                   text: text, title: title, reminderFlagged: reminderFlagged))
        try? modelContext.save()
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
    func advance(bucketKey: String, note: NoteDraft?, to mark: ItemKey) {
        commit(bucketKey: bucketKey, note: note, apply: { r in
            r.order = mark.order; r.tiebreak = mark.tiebreak
            r.floorOrder = nil; r.floorTiebreak = nil; r.updatedAt = Date()
        }, make: {
            BucketPointer(bucketKey: bucketKey, mark: mark)
        })
    }

    /// FIRST RUN (initial descent) — record an optional survivor note AND sink the floor to `floor`
    /// (top stays fixed), in one save. Creates the row with `top` on the first step. A crash leaves an
    /// honest floor → the next run resumes strictly below it.
    func sinkFloor(bucketKey: String, note: NoteDraft?, top: ItemKey, floor: ItemKey) {
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
            CrashReporting.capture(error)
        }
    }

    /// Every current-cycle note, newest first (VIEW SUMMARIES + the cloud corpus).
    func notes() -> [CycleNoteItem] {
        let rows = (try? modelContext.fetch(FetchDescriptor<CycleNote>(
            sortBy: [SortDescriptor(\.itemDateEpoch, order: .reverse)]))) ?? []
        return rows.map(item(from:))
    }

    /// End-of-cycle wipe (fired by the proactive button) — pointers persist, notes do not.
    func wipeAllNotes() {
        try? modelContext.delete(model: CycleNote.self)
        try? modelContext.save()
    }

    /// Factory reset — delete EVERY pointer and EVERY note (the dev "Reset everything" button pairs
    /// this with wiping the vault). After this, the next run is a fresh first run for every bucket.
    func wipeEverything() {
        try? modelContext.delete(model: CycleNote.self)
        try? modelContext.delete(model: BucketPointer.self)
        try? modelContext.save()
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
    /// the namespaced `SentientOS` root in Application Support). Wipe-and-retry-once on an
    /// incompatible schema change (dev convenience).
    static let shared: CycleStore = {
        let schema = Schema([BucketPointer.self, CycleNote.self])
        let url = URL.sentientSupport.appending(path: "IterativeCycle.store")
        let config = ModelConfiguration(schema: schema, url: url)
        if let container = try? ModelContainer(for: schema, configurations: config) {
            return CycleStore(modelContainer: container)
        }
        for sfx in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + sfx))
        }
        guard let container = try? ModelContainer(for: schema, configurations: config) else {
            fatalError("CycleStore: could not create its ModelContainer")
        }
        return CycleStore(modelContainer: container)
    }()
}
