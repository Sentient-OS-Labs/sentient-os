//
//  SelfTest_NotesIter.swift
//  Sentient OS macOS
//
//  SENTIENT_SELFTEST=notesiter — runs the REAL NotesConnector against the live Notes DB and checks
//  structural invariants: a single "notes" bucket, every item .notes, ids unique + "notes:<uuid>",
//  bodies non-empty, keys strictly ordered (no dup keys) and newest-created first, load() returns
//  the decoded body. Needs Full Disk Access + some notes; reports "skipped" gracefully without them.
//  (The generic core itself — ItemKey/CycleStore/partition — is covered by `fileiter`.)
//

import Foundation

enum SelfTestNotesIter {

    static func run(emit: (String) -> Void) async {
        var passed = 0, failed = 0
        func check(_ label: String, _ cond: Bool) {
            if cond { passed += 1; emit("  ✓ \(label)") }
            else { failed += 1; emit("  ✗ FAIL — \(label)") }
        }

        emit("=== notesiter: NotesConnector against the live Notes DB ===")
        let connector = NotesConnector()
        let buckets: [Bucket]
        do { buckets = try connector.buckets(since: [:]) }
        catch {
            emit("  ⚠️ couldn't read NoteStore.sqlite (\(error)) — grant Full Disk Access to this build.")
            emit("\n=== notesiter: skipped (no DB access) ===")
            return
        }

        check("at most one bucket (single \"notes\" bucket)", buckets.count <= 1)
        guard let bucket = buckets.first, !bucket.items.isEmpty else {
            emit("  (0 notes — empty store or no Full Disk Access. Structural checks skipped.)")
            emit("\n=== notesiter: \(passed) passed · \(failed) failed (0 items) ===")
            return
        }
        check("bucket key is \"notes\"", bucket.key == "notes")

        let items = bucket.items
        emit("  \(items.count) notes")
        check("every item kind == .notes", items.allSatisfy { $0.item.kind == .notes })
        check("ids are unique and \"notes:<uuid>\"",
              Set(items.map { $0.item.id }).count == items.count
              && items.allSatisfy { $0.item.id.hasPrefix("notes:") })
        check("every body is non-empty", items.allSatisfy { !($0.item.metadata["noteText"] ?? "").isEmpty })

        let keysSorted = items.map(\.key).sorted()
        check("keys strictly ordered when sorted (no dup keys)",
              zip(keysSorted, keysSorted.dropFirst()).allSatisfy { $0.0 < $0.1 })
        let keys = items.map(\.key)
        check("listed newest-created first (descending)",
              zip(keys, keys.dropFirst()).allSatisfy { $0.0 > $0.1 })

        if let first = items.first {
            let art = try? connector.load(first.item)
            check("load() returns the decoded body", (art?.text?.isEmpty == false))
        }

        emit("\n=== notesiter: \(passed) passed · \(failed) failed ===")
    }
}
