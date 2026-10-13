//
//  SiYuanConnector.swift
//  Sentient OS macOS
//
//  SiYuan adapter for the iterative core. A SINGLE bucket ("siyuan") across every workspace, keyed
//  on (updated, "siyuan:<doc-id>") — updated-date so an edited note IS re-summarized; the doc ID is
//  the tiebreak. One note = one item, through the FILE Triage prompt (a note is a document the user
//  wrote). Wraps `SiYuanSource.eligibleNotes`; the body is rendered at list time, so `load` just
//  wraps it. Needs no Full Disk Access: workspaces are ordinary folders.
//

import Foundation

struct SiYuanConnector: Connector {
    let kind = SourceKind.siyuan

    func buckets(since marks: [String: ItemKey]) throws -> [Bucket] {
        let items = SiYuanSource().eligibleNotes().map { c in
            (key: ItemKey(date: c.itemDate, tiebreak: c.id), item: c)   // c.id = "siyuan:<doc-id>" (unique)
        }
        return [Bucket(key: "siyuan", items: items)]   // single bucket, newest-updated first
    }

    func load(_ item: Candidate) throws -> Artifact {
        Artifact(candidate: item, text: item.metadata["noteText"] ?? "")
    }
}
