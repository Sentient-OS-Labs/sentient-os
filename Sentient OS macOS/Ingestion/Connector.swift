//
//  Connector.swift
//  Sentient OS macOS
//
//  The connector abstraction for the iterative system. A connector is DUMB: it lists its current
//  work-items per BUCKET (each with an ItemKey), and loads one for the model. ALL pointer logic
//  (initial/iterative, advancing, crash-resume) lives in IterativeRun — never in a connector.
//
//  Work payload + content reuse the existing `Candidate` / `Artifact` value types (DataSource.swift):
//  a connector emits `(ItemKey, Candidate)` pairs; IterativeRun calls `load(Candidate) → Artifact →
//  Triage`. (Candidate's `cursorKey`/`cursorValue` are vestigial here — the old backfill cursor is
//  gone; only ItemKey + bucketKey matter.)
//
//  Buckets are the pointer namespace: files → "file:<root.id>" (per folder) · notes → "notes"
//  (single) · chats → "whatsapp:<jid>" / "imessage:<guid>" (per chat).
//

import Foundation

struct Bucket: Sendable {
    let key: String                                  // pointer namespace
    let items: [(key: ItemKey, item: Candidate)]     // newest-first
}

protocol Connector: Sendable {
    var kind: SourceKind { get }
    /// Engine KV-cache size for this connector's items (chats feed big windows → `ChatWindowing.kvCacheTokens`; default 4096).
    var maxTokens: Int { get }

    /// Current eligible work-items per bucket, newest-first. `marks` = the current per-bucket pointer
    /// (a query HINT only — a connector MAY use it to read efficiently, e.g. chats' `WHERE rowid >
    /// mark`; IterativeRun still filters/advances authoritatively, so returning extra items is
    /// harmless). For an initial run the run passes `[:]` ⇒ return everything (still connector-capped).
    func buckets(since marks: [String: ItemKey]) throws -> [Bucket]

    /// Expensive content for one item → Artifact for Triage.
    func load(_ item: Candidate) throws -> Artifact
}

extension Connector {
    var maxTokens: Int { 4096 }
}
