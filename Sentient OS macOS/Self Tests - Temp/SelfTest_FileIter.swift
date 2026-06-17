//
//  SelfTest_FileIter.swift
//  Sentient OS macOS
//
//  SENTIENT_SELFTEST=fileiter — a deterministic proof of the iterative CORE through the Files
//  connector (no model, no codex, in-memory store):
//    • ItemKey ordering — the (order, tiebreak) tiebreak.
//    • The iterative "newer than mark" partition, with a same-order TWIN at the boundary.
//    • CycleStore round-trip — pointer set/get, clearBucket, recordNote/notes/wipeAllNotes.
//    • FilesConnector.buckets — keeps allowed files, skips a disallowed extension, prunes a .git repo.
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

        emit("=== fileiter: ItemKey ordering (the tiebreak) ===")
        let a = ItemKey(date: Date(timeIntervalSince1970: 100), tiebreak: "/d/a.png")
        let b = ItemKey(date: Date(timeIntervalSince1970: 100), tiebreak: "/d/b.png")
        let c = ItemKey(date: Date(timeIntervalSince1970: 200), tiebreak: "/d/c.png")
        check("same order → tiebreak decides (a < b)", a < b)
        check("later order wins regardless of tiebreak (b < c)", b < c)
        check("twins are strictly ordered, not equal", a < b && !(b < a) && a != b)

        emit("\n=== fileiter: iterative partition (newer-than-mark, twin at the boundary) ===")
        // Previous run's mark = B. Its same-order twin A (tiebreak < mark) is already done; C is new.
        let mark = b
        let newer = [a, b, c].filter { $0 > mark }.sorted()
        check("twin A (same order, tiebreak < mark) is NOT reprocessed", !newer.contains(a))
        check("the boundary mark B itself is excluded", !newer.contains(b))
        check("genuinely new C is picked up, alone", newer == [c])

        emit("\n=== fileiter: CycleStore round-trip (in-memory) ===")
        let store = inMemoryStore()
        let bucket = "file:__fileiter__"
        check("pointer nil before any initial run", await store.pointer(bucket) == nil)
        await store.setPointer(bucket, a)
        await store.setPointer(bucket, c)
        check("pointer persists the high-water mark (c)", await store.pointer(bucket) == c)

        await store.recordNote(bucketKey: bucket, kind: .file, sourceID: "file:/d/a.png", folder: "Fix",
                               itemDate: Date(timeIntervalSince1970: 100), text: "summary a", title: "A", reminderFlagged: false)
        await store.recordNote(bucketKey: bucket, kind: .file, sourceID: "file:/d/c.png", folder: "Fix",
                               itemDate: Date(timeIntervalSince1970: 200), text: "summary c", title: "C", reminderFlagged: false)
        let notes = await store.notes()
        check("two notes recorded", notes.count == 2)
        check("notes are newest-first (c before a)", notes.first?.sourceID == "file:/d/c.png")

        await store.clearBucket(bucket)
        check("clearBucket drops the pointer", await store.pointer(bucket) == nil)
        check("clearBucket removes that bucket's notes", await store.counts().notes == 0)

        await store.recordNote(bucketKey: "file:other", kind: .file, sourceID: "file:/x/y.txt", folder: "Other",
                               itemDate: Date(timeIntervalSince1970: 100), text: "t", title: nil, reminderFlagged: false)
        check("a note under another bucket exists", await store.counts().notes == 1)
        await store.wipeAllNotes()
        check("wipeAllNotes empties every note (cycle end)", await store.counts().notes == 0)

        emit("\n=== fileiter: FilesConnector.buckets (skip + keep) ===")
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

        let connector = FilesConnector(roots: [.custom(baseDir)])
        let items = ((try? connector.buckets(since: [:])) ?? []).flatMap { $0.items }
        let names = Set(items.compactMap { $0.item.metadata["path"] }
            .map { URL(fileURLWithPath: $0).lastPathComponent })
        emit("  eligible: \(names.sorted())")
        check("keeps the 3 allowed files", names == ["keep1.txt", "keep2.md", "keep3.png"])
        check("skips the disallowed extension (.bin)", !names.contains("ignore.bin"))
        check("prunes the .git repo (code.py never seen)", !names.contains("code.py"))

        emit("\n=== fileiter: \(passed) passed · \(failed) failed ===")
    }

    /// A throwaway in-memory CycleStore so the proof never touches the real on-disk store.
    private static func inMemoryStore() -> CycleStore {
        let schema = Schema([BucketPointer.self, CycleNote.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: config)
        return CycleStore(modelContainer: container)
    }
}
