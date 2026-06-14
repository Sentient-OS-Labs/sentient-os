//
//  SelfTest_FileIter.swift
//  Sentient OS macOS
//
//  SENTIENT_SELFTEST=fileiter — a deterministic proof of the files-iterative CORE (no model, no
//  codex, in-memory store):
//    • FileKey ordering — the (dateAdded, path) tiebreak.
//    • The iterative "newer than hi" partition, with a same-second TWIN straddling the boundary
//      (the exact case the tiebreak exists for: the twin below the line is NOT reprocessed).
//    • FileStore round-trip — interval set/get, clearFolder, recordNote/notes/reminderNotes,
//      wipeAllNotes.
//    • FilesSource.eligibleFiles — keeps allowed files, skips a disallowed extension, prunes a
//      .git repo.
//  (Date ORDERING of real files can't be unit-tested — kMDItemDateAdded can't be backdated on a
//  fixture — so the dev buttons on real folders are the end-to-end check; this proves the logic.)
//

import Foundation
import SwiftData

enum SelfTestFileIter {

    static func run(emit: (String) -> Void) async {
        var passed = 0, failed = 0
        func check(_ label: String, _ cond: Bool) {
            if cond { passed += 1; emit("  ✓ \(label)") }
            else { failed += 1; emit("  ✗ FAIL — \(label)") }
        }

        emit("=== fileiter: FileKey ordering (the tiebreak) ===")
        let a = FileKey(dateAdded: Date(timeIntervalSince1970: 100), path: "/d/a.png")
        let b = FileKey(dateAdded: Date(timeIntervalSince1970: 100), path: "/d/b.png")
        let c = FileKey(dateAdded: Date(timeIntervalSince1970: 200), path: "/d/c.png")
        check("same second → path breaks the tie (a < b)", a < b)
        check("later date wins regardless of path (b < c)", b < c)
        check("twins are strictly ordered, not equal", a < b && !(b < a) && a != b)

        emit("\n=== fileiter: iterative partition (newer-than-hi, twin at the boundary) ===")
        // Previous run's newest processed = B (t100, b). Its same-second twin A (t100, a) is BELOW
        // the boundary (already done); C (t200) is genuinely new. Iterative selects keys > hi.
        let hi = b
        let newer = [a, b, c].filter { $0 > hi }.sorted()
        check("twin A (same second, path < hi) is NOT reprocessed", !newer.contains(a))
        check("the boundary file B itself is excluded", !newer.contains(b))
        check("genuinely new C is picked up, alone", newer == [c])

        emit("\n=== fileiter: FileStore round-trip (in-memory) ===")
        let store = inMemoryStore()
        let key = "file:__fileiter__"
        check("interval nil before any initial run", await store.interval(forKey: key) == nil)
        // Initial: pin hi at the newest (c), then slide lo down to the oldest (a).
        await store.setInterval(forKey: key, lo: c, hi: c)
        await store.setInterval(forKey: key, lo: a, hi: c)
        let iv = await store.interval(forKey: key)
        check("interval persists hi = c (the iterative anchor)", iv?.hi == c)
        check("interval persists lo = a (descent watermark)", iv?.lo == a)

        await store.recordNote(rootKey: key, folder: "Fix", path: "/d/a.png", dateAdded: a.dateAdded,
                               text: "summary a", title: "A", reminderFlagged: true)
        await store.recordNote(rootKey: key, folder: "Fix", path: "/d/c.png", dateAdded: c.dateAdded,
                               text: "summary c", title: "C", reminderFlagged: false)
        let notes = await store.notes()
        check("two notes recorded", notes.count == 2)
        check("notes are newest-first (c before a)", notes.first?.path == "/d/c.png")
        check("exactly one reminder-flagged", await store.reminderNotes().count == 1)

        await store.clearFolder(rootKey: key)
        check("clearFolder drops the pointer", await store.interval(forKey: key) == nil)
        check("clearFolder removes that root's notes", await store.counts().notes == 0)

        await store.recordNote(rootKey: "file:other", folder: "Other", path: "/x/y.txt",
                               dateAdded: a.dateAdded, text: "t", title: nil, reminderFlagged: false)
        check("a note under another root exists", await store.counts().notes == 1)
        await store.wipeAllNotes()
        check("wipeAllNotes empties every note (cycle end)", await store.counts().notes == 0)

        emit("\n=== fileiter: FilesSource.eligibleFiles (skip + keep) ===")
        let fm = FileManager.default
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sentient-fileiter-\(UUID().uuidString.prefix(8))")
        let repo = baseDir.appendingPathComponent("repo")
        try? fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try? "hello".data(using: .utf8)!.write(to: baseDir.appendingPathComponent("keep1.txt"))
        try? "# hi".data(using: .utf8)!.write(to: baseDir.appendingPathComponent("keep2.md"))
        try? "x".data(using: .utf8)!.write(to: baseDir.appendingPathComponent("ignore.bin"))
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: baseDir.appendingPathComponent("keep3.png"))
        try? "print('hi')".data(using: .utf8)!.write(to: repo.appendingPathComponent("code.py"))
        defer { try? fm.removeItem(at: baseDir) }

        let src = FilesSource(root: baseDir, label: "Fixture", cursorKey: "file:__fileiter_fix__")
        let names = Set(src.eligibleFiles()
            .compactMap { $0.metadata["path"] }
            .map { URL(fileURLWithPath: $0).lastPathComponent })
        emit("  eligible: \(names.sorted())")
        check("keeps the 3 allowed files", names == ["keep1.txt", "keep2.md", "keep3.png"])
        check("skips the disallowed extension (.bin)", !names.contains("ignore.bin"))
        check("prunes the .git repo (code.py never seen)", !names.contains("code.py"))

        emit("\n=== fileiter: \(passed) passed · \(failed) failed ===")
    }

    /// A throwaway in-memory FileStore so the proof never touches the real on-disk store.
    private static func inMemoryStore() -> FileStore {
        let schema = Schema([FolderPointer.self, FileNote.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: config)
        return FileStore(modelContainer: container)
    }
}
