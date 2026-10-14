//
//  SiYuanConnector.swift
//  Sentient OS macOS
//
//  SiYuan adapter for the iterative core. One bucket per workspace-scoped document, keyed on its
//  updated date so an edited note IS re-summarized. A newly discovered old note gets its own initial
//  run rather than falling behind another note's checkpoint. One note = one item, through the FILE
//  Triage prompt (a note is a document the user wrote). Wraps `SiYuanSource.eligibleNotes`;
//  the body is rendered at list time, so `load` just
//  wraps it. Needs no Full Disk Access: workspaces are ordinary folders.
//

import Foundation

struct SiYuanConnector: Connector {
    let kind = SourceKind.siyuan
    private let source: SiYuanSource

    init(source: SiYuanSource = SiYuanSource()) { self.source = source }

    func buckets(since marks: [String: ItemKey]) throws -> [Bucket] {
        source.eligibleNotes().map { c in
            Bucket(key: c.id, items: [(key: ItemKey(date: c.itemDate, tiebreak: c.id), item: c)])
        }
    }

    func load(_ item: Candidate) throws -> Artifact {
        Artifact(candidate: item, text: item.metadata["noteText"] ?? "")
    }
}
