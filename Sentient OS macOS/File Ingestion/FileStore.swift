//
//  FileStore.swift
//  Sentient OS macOS
//
//  The files-iterative system's own little database — deliberately separate from the old `Store`
//  (its own on-disk SwiftData container, so adding these models never schema-wipes the existing
//  dev DB, and the two systems can't entangle). Two models:
//
//   - FolderPointer  DURABLE. One row per file root. The processed interval [lo, hi] of the
//                    date-added timeline. `hi` = newest processed (the anchor the next ITERATIVE
//                    run starts above); `lo` = oldest processed (an INITIAL top→bottom descent
//                    slides it down). This is the ONLY state that survives a cycle.
//   - FileNote       EPHEMERAL. One survivor summary per file, wiped at the end of every cycle
//                    (the proactive button clears them). Junk/sensitive files store NOTHING — the
//                    pointer simply moves past them (zero trace).
//
//  Only this actor touches the @Model objects; callers get/pass Sendable value types (FileKey,
//  FileNoteItem). Methods: interval/setInterval/clearFolder · recordNote/notes/reminderNotes/
//  wipeAllNotes · counts.
//

import Foundation
import SwiftData

// MARK: - Models

/// DURABLE — one per file root. The processed interval as two (epoch, path) bounds.
@Model
final class FolderPointer {
    @Attribute(.unique) var key: String   // "file:<FileRoot.id>"
    var loEpoch: Double
    var loPath: String
    var hiEpoch: Double
    var hiPath: String
    var updatedAt: Date

    init(key: String, lo: FileKey, hi: FileKey, updatedAt: Date = Date()) {
        self.key = key
        self.loEpoch = lo.dateAdded.timeIntervalSince1970
        self.loPath = lo.path
        self.hiEpoch = hi.dateAdded.timeIntervalSince1970
        self.hiPath = hi.path
        self.updatedAt = updatedAt
    }

    var lo: FileKey { FileKey(dateAdded: Date(timeIntervalSince1970: loEpoch), path: loPath) }
    var hi: FileKey { FileKey(dateAdded: Date(timeIntervalSince1970: hiEpoch), path: hiPath) }
}

/// EPHEMERAL — one survivor summary for one file, this cycle only.
@Model
final class FileNote {
    var rootKey: String       // "file:<FileRoot.id>" — for the per-root clear
    var folder: String        // display label ("Downloads"…)
    var path: String
    var dateAddedEpoch: Double
    var text: String
    var title: String?
    var reminderFlagged: Bool
    var createdAt: Date

    init(rootKey: String, folder: String, path: String, dateAdded: Date,
         text: String, title: String?, reminderFlagged: Bool, createdAt: Date = Date()) {
        self.rootKey = rootKey
        self.folder = folder
        self.path = path
        self.dateAddedEpoch = dateAdded.timeIntervalSince1970
        self.text = text
        self.title = title
        self.reminderFlagged = reminderFlagged
        self.createdAt = createdAt
    }
}

/// A Sendable, read-only snapshot of one FileNote — what the VIEW SUMMARIES list and the cloud
/// calls consume (we never hand live @Model objects across actors).
struct FileNoteItem: Sendable, Identifiable {
    let id: String            // path (stable, unique within a cycle)
    let rootKey: String
    let folder: String
    let path: String
    let dateAdded: Date
    let text: String
    let title: String?
    let reminderFlagged: Bool
    let createdAt: Date

    var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + String(path.dropFirst(home.count)) : path
    }
}

// MARK: - The actor

@ModelActor
actor FileStore {

    // MARK: Pointers (durable)

    /// The processed interval for a root, or nil if it has never had an initial run.
    func interval(forKey key: String) -> (lo: FileKey, hi: FileKey)? {
        guard let row = pointerRow(key) else { return nil }
        return (row.lo, row.hi)
    }

    /// Set/advance a root's processed interval (initial sets hi then slides lo down; iterative
    /// slides hi up). Called once per processed item so a crash resumes rather than skips.
    func setInterval(forKey key: String, lo: FileKey, hi: FileKey) {
        if let row = pointerRow(key) {
            row.loEpoch = lo.dateAdded.timeIntervalSince1970; row.loPath = lo.path
            row.hiEpoch = hi.dateAdded.timeIntervalSince1970; row.hiPath = hi.path
            row.updatedAt = Date()
        } else {
            modelContext.insert(FolderPointer(key: key, lo: lo, hi: hi))
        }
        try? modelContext.save()
    }

    /// Initial reset for one root: drop its pointer AND its ephemeral notes, so a fresh
    /// top→bottom run starts from a clean slate.
    func clearFolder(rootKey: String) {
        if let row = pointerRow(rootKey) { modelContext.delete(row) }
        try? modelContext.delete(model: FileNote.self, where: #Predicate { $0.rootKey == rootKey })
        try? modelContext.save()
    }

    private func pointerRow(_ key: String) -> FolderPointer? {
        (try? modelContext.fetch(
            FetchDescriptor<FolderPointer>(predicate: #Predicate { $0.key == key })
        ))?.first
    }

    // MARK: Notes (ephemeral)

    /// Record one survivor's summary (junk/sensitive call this NOT at all — they store nothing).
    func recordNote(rootKey: String, folder: String, path: String, dateAdded: Date,
                    text: String, title: String?, reminderFlagged: Bool) {
        modelContext.insert(FileNote(rootKey: rootKey, folder: folder, path: path,
                                     dateAdded: dateAdded, text: text, title: title,
                                     reminderFlagged: reminderFlagged))
        try? modelContext.save()
    }

    /// Every current-cycle note, newest first (the VIEW SUMMARIES list + the cloud corpus).
    func notes() -> [FileNoteItem] {
        let rows = (try? modelContext.fetch(FetchDescriptor<FileNote>(
            sortBy: [SortDescriptor(\.dateAddedEpoch, order: .reverse)]))) ?? []
        return rows.map(item(from:))
    }

    /// The reminder-flagged subset (the proactive system's input).
    func reminderNotes() -> [FileNoteItem] {
        let rows = (try? modelContext.fetch(FetchDescriptor<FileNote>(
            predicate: #Predicate { $0.reminderFlagged }))) ?? []
        return rows.map(item(from:))
    }

    /// End-of-cycle wipe (fired by the proactive button) — pointers persist, notes do not.
    func wipeAllNotes() {
        try? modelContext.delete(model: FileNote.self)
        try? modelContext.save()
    }

    /// (notes, distinct folders) — for the dev UI counts.
    func counts() -> (notes: Int, folders: Int) {
        let rows = (try? modelContext.fetch(FetchDescriptor<FileNote>())) ?? []
        return (rows.count, Set(rows.map(\.folder)).count)
    }

    private func item(from n: FileNote) -> FileNoteItem {
        FileNoteItem(id: n.path, rootKey: n.rootKey, folder: n.folder, path: n.path,
                     dateAdded: Date(timeIntervalSince1970: n.dateAddedEpoch),
                     text: n.text, title: n.title, reminderFlagged: n.reminderFlagged,
                     createdAt: n.createdAt)
    }
}

// MARK: - Shared instance (its own container)

extension FileStore {
    /// The app-wide files store, backed by its OWN on-disk SwiftData store ("FileIngestion.store"
    /// in Application Support) — fully isolated from the old `Store`'s default.store. Mirrors the
    /// app's wipe-and-retry-once on an incompatible schema change (dev convenience).
    static let shared: FileStore = {
        let schema = Schema([FolderPointer.self, FileNote.self])
        let url = URL.applicationSupportDirectory.appending(path: "FileIngestion.store")
        let config = ModelConfiguration(schema: schema, url: url)
        if let container = try? ModelContainer(for: schema, configurations: config) {
            return FileStore(modelContainer: container)
        }
        // Incompatible schema → wipe this store's three files (.store / -shm / -wal) and retry once.
        for sfx in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + sfx))
        }
        guard let container = try? ModelContainer(for: schema, configurations: config) else {
            fatalError("FileStore: could not create its ModelContainer")
        }
        return FileStore(modelContainer: container)
    }()
}
