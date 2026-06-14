//
//  NotesConnector.swift
//  Sentient OS macOS
//
//  Apple Notes adapter for the iterative core. A SINGLE bucket ("notes"), keyed on
//  (createdDate, "notes:<uuid>") — created-date so an edited note is NOT re-summarized; the uuid
//  is the tiebreak. One note = one item, through the FILE Triage prompt (a note is a document the
//  user wrote). Wraps `NotesSource.eligibleNotes` (WAL-safe read + gunzip/protobuf decode + cap);
//  the body is already decoded at list time, so `load` just wraps it. Requires Full Disk Access.
//

import Foundation

struct NotesConnector: Connector {
    let kind = SourceKind.notes

    func buckets(since marks: [String: ItemKey]) throws -> [Bucket] {
        let items = try NotesSource().eligibleNotes().map { c in
            (key: ItemKey(date: c.itemDate, tiebreak: c.id), item: c)   // c.id = "notes:<uuid>" (unique)
        }
        return [Bucket(key: "notes", items: items)]   // single bucket, newest-created first
    }

    func load(_ item: Candidate) throws -> Artifact {
        Artifact(candidate: item, text: item.metadata["noteText"] ?? "")
    }
}
