//
//  DataSource.swift
//  Sentient OS macOS
//
//  The ONE abstraction (Arch §2.2). Two-phase, so expensive content extraction is gated by
//  the per-source pointers:
//    scan(since:) -> [Candidate]   // cheap: enumerate items PAST the pointers, NO content
//    load(_:)     -> Artifact      // expensive: extract text/image for a chosen candidate
//  Candidate & Artifact are Sendable value types; live @Model objects never cross actors.
//
//  THE POINTER CONTRACT (June 11 pointer rewrite — Documentation/Pointer Architecture…):
//  every candidate names the cursor it advances (`cursorKey` → `cursorValue`). The pipeline
//  processes candidates in scan order and advances each candidate's cursor only after its
//  durable save — so scan() MUST return candidates ascending per cursorKey (oldest first).
//  A crash resumes exactly where it stopped; pointer nil = "everything" = the initial run.
//

import Foundation

/// The four local sources. `rawValue` is what we persist on summaries and in cursor keys.
enum SourceKind: String, Codable, Sendable, CaseIterable {
    case file
    case whatsapp
    case imessage
    case notes
}

/// Freshness hold-back shared by every source: items newer than this are left for the NEXT
/// run, so a document mid-editing-session / an actively-flowing conversation / a note being
/// typed isn't summarized between keystrokes. Pointers never advance past `now − holdBack`
/// by construction (held-back items are never candidates).
let sourceFreshnessHoldBack: TimeInterval = 3_600

/// Cheap unit produced by `scan` — enough to order and process without reading content.
/// `metadata` carries light context (displayPath, name, created…).
struct Candidate: Sendable, Identifiable {
    let id: String                    // stable source id, e.g. "file:/Users/…/a.pdf"
    let kind: SourceKind
    let cursorKey: String             // which pointer this item advances when durably saved
    let cursorValue: String           // the pointer value after this item is consumed
    let itemDate: Date                // the artifact's OWN date (drives ordering + Summary.itemDate)
    let metadata: [String: String]

    init(id: String, kind: SourceKind, cursorKey: String, cursorValue: String,
         itemDate: Date, metadata: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.cursorKey = cursorKey
        self.cursorValue = cursorValue
        self.itemDate = itemDate
        self.metadata = metadata
    }
}

/// A loaded item = a Candidate plus its extracted content (text and/or image bytes).
struct Artifact: Sendable, Identifiable {
    let id: String
    let kind: SourceKind
    let cursorKey: String
    let cursorValue: String
    let itemDate: Date
    let text: String?                 // extracted text (nil for image-only artifacts)
    let imageData: Data?              // downsized image bytes → the vision model
    let metadata: [String: String]

    /// Build an Artifact from its Candidate plus extracted content.
    init(candidate: Candidate, text: String? = nil, imageData: Data? = nil) {
        self.id = candidate.id
        self.kind = candidate.kind
        self.cursorKey = candidate.cursorKey
        self.cursorValue = candidate.cursorValue
        self.itemDate = candidate.itemDate
        self.text = text
        self.imageData = imageData
        self.metadata = candidate.metadata
    }
}

protocol DataSource {
    var kind: SourceKind { get }
    /// Enumerate items past the pointers — NO content extraction. `cursors` is the full pointer
    /// map (a source reads only its own keys; empty map = initial run = everything, connector
    /// caps still apply). Returned candidates MUST be ascending per cursorKey (see contract above).
    func scan(since cursors: [String: String]) throws -> [Candidate]
    /// Expensive content extraction for a candidate the pipeline chose to process.
    func load(_ candidate: Candidate) throws -> Artifact
}
