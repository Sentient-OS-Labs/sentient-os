//
//  FileKey.swift
//  Sentient OS macOS
//
//  A file's position in the "date added" timeline: a (dateAdded, path) pair with a TOTAL order.
//  Date added alone isn't unique — a batch of files can share the same second (e.g. two
//  screenshots saved at 9:29 PM) — so the path is the tiebreak. That makes every file a DISTINCT
//  point, so the per-folder pointer (FolderPointer) can name EXACTLY one boundary file and
//  "is this file past the line?" is never ambiguous when a folder is re-scanned on a later run.
//
//  Used by FolderPointer (the processed interval [lo, hi]) and FileRun (direction-sorting the
//  eligible files: initial descends from hi, iterative ascends above hi).
//

import Foundation

struct FileKey: Comparable, Codable, Sendable, Hashable {
    let dateAdded: Date
    let path: String

    /// Order by date added, then by path for the same-second tiebreak.
    static func < (a: FileKey, b: FileKey) -> Bool {
        a.dateAdded == b.dateAdded ? a.path < b.path : a.dateAdded < b.dateAdded
    }
}
