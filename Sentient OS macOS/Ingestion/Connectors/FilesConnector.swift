//
//  FilesConnector.swift
//  Sentient OS macOS
//
//  Files adapter for the iterative core. One bucket per FileRoot ("file:<root.id>"), keyed on
//  (dateAdded, path). Wraps `FilesSource.eligibleFiles` (skip rules + caps) for listing and
//  `FilesSource.loadArtifact` for content. No date filtering here — IterativeRun's pointer decides
//  new-vs-done. (`since` is unused: a folder walk is cheap, so listing all eligible files and letting
//  the run filter is fine.)
//

import Foundation

struct FilesConnector: Connector {
    let kind = SourceKind.file
    let roots: [FileRoot]

    func buckets(since marks: [String: ItemKey]) throws -> [Bucket] {
        roots.compactMap { root in
            guard let source = root.source else { return nil }
            let items = source.eligibleFiles().map { c in
                (key: ItemKey(date: c.itemDate, tiebreak: c.metadata["path"] ?? c.id), item: c)
            }
            return Bucket(key: source.cursorKey, items: items)   // already newest-first
        }
    }

    func load(_ item: Candidate) throws -> Artifact {
        try FilesSource.loadArtifact(item)
    }
}
