//
//  DataSource.swift
//  Sentient OS macOS
//
//  The ONE abstraction (Arch §2.2). Two-phase, so expensive content extraction is gated by
//  the dedup ledger:
//    scan(since:) -> [Candidate]   // cheap: enumerate items (stat only), NO content
//    load(_:)     -> Artifact      // expensive: extract text/image for a chosen candidate
//  Candidate & Artifact are Sendable value types; live @Model objects never cross actors.
//
//  NOTE: the WAL-safe DB-copy helper (Arch §3.5) lands in Phase 3 with the first DB source.
//

import Foundation

/// The four local sources. `rawValue` is what we persist in the ledger/cursor tables.
enum SourceKind: String, Codable, Sendable, CaseIterable {
    case file
    case whatsapp
    case imessage
    case notes
}

/// Cheap dedup unit produced by `scan` — enough to decide "already processed?" without
/// reading file contents. `metadata` carries light context (displayPath, name, created…).
struct Candidate: Sendable, Identifiable {
    let id: String                    // stable source id → LedgerEntry.sourceID
    let kind: SourceKind
    let signature: String             // files: "size:mtime"; db sources: the cursor value
    let cursor: String                // progress marker (Files dedup via ledger, not cursor)
    let metadata: [String: String]

    init(id: String, kind: SourceKind, signature: String,
         cursor: String = "", metadata: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.signature = signature
        self.cursor = cursor
        self.metadata = metadata
    }
}

/// A loaded item = a Candidate plus its extracted content (text and/or image bytes).
struct Artifact: Sendable, Identifiable {
    let id: String
    let kind: SourceKind
    let signature: String
    let cursor: String
    let text: String?                 // extracted text (nil for image-only artifacts)
    let imageData: Data?              // downsized image bytes → the vision model
    let metadata: [String: String]

    init(id: String, kind: SourceKind, signature: String, cursor: String = "",
         text: String? = nil, imageData: Data? = nil, metadata: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.signature = signature
        self.cursor = cursor
        self.text = text
        self.imageData = imageData
        self.metadata = metadata
    }

    /// Build an Artifact from its Candidate plus extracted content.
    init(candidate: Candidate, text: String? = nil, imageData: Data? = nil) {
        self.init(id: candidate.id, kind: candidate.kind, signature: candidate.signature,
                  cursor: candidate.cursor, text: text, imageData: imageData,
                  metadata: candidate.metadata)
    }
}

protocol DataSource {
    var kind: SourceKind { get }
    /// Cheap enumeration of items present/new since the cursor — NO content extraction.
    func scan(since cursor: String?) throws -> [Candidate]
    /// Expensive content extraction for a candidate the pipeline chose to process.
    func load(_ candidate: Candidate) throws -> Artifact
}
