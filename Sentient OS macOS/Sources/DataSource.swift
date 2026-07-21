//
//  DataSource.swift
//  Sentient OS macOS
//
//  The Sendable value types the iterative reading pipeline passes around — `Candidate` (a cheap,
//  content-free work item) and `Artifact` (a Candidate plus its extracted text/image). Each source
//  lists its current work as `Candidate`s via its `eligible…()` method (wrapped by a Connector —
//  Ingestion/Connector.swift); IterativeRun loads the chosen ones into `Artifact`s for Triage. Live
//  @Model objects never cross actors — only these value types do.
//
//  (The old two-phase `DataSource.scan/load` protocol + its `ScanResult`/`BackfillCursor` machinery
//  were removed when the connector/IterativeRun system became the only pipeline — the per-bucket
//  high-water mark in CycleStore is the entire pointer story now.)
//

import Foundation

/// The sources. `rawValue` is what we persist on summaries (the cloud's source-trust tiers key on
/// it). `file`/`whatsapp`/`imessage`/`notes`/`appleMail` are read on-device; `gmail` and
/// `calendar` are the CLOUD sources — fetched + summarized through the user's Codex connectors
/// (no on-device read), see GmailConnect / CalendarConnect.
enum SourceKind: String, Codable, Sendable, CaseIterable {
    case file
    case whatsapp
    case imessage
    case notes
    case appleMail
    case gmail
    case calendar
}

/// A cheap, content-free unit of work, produced by a source's `eligible…()` listing — enough to
/// order and identify an item without reading its content. `metadata` carries light context
/// (displayPath, name, created, windowText/noteText, isGroup…). The iterative core keys on `id` plus
/// the connector's `ItemKey`; `cursorKey`/`cursorValue` are vestigial (sources still set them, but
/// nothing reads them — they can be dropped in a later sweep).
///
/// `fingerprint` is an optional content marker (e.g. "mtime|size" for files). When set, IterativeRun
/// checks it against a durable registry of previously-processed items — if it matches, the model
/// call is skipped. This is defense-in-depth against ItemKey drift: a file's addedToDirectoryDate
/// can refresh on macOS (iCloud sync, Spotlight, app rewrites) even when its content is byte-
/// identical, which would otherwise push it past the high-water mark and re-summarize it.
struct Candidate: Sendable, Identifiable {
    let id: String                    // stable source id, e.g. "file:/Users/…/a.pdf"
    let kind: SourceKind
    let cursorKey: String             // vestigial
    let cursorValue: String           // vestigial
    let itemDate: Date                // the artifact's OWN date (drives ordering + the summary's date)
    let metadata: [String: String]
    let fingerprint: String?          // optional content marker — if matched, skip the model call

    init(id: String, kind: SourceKind, cursorKey: String = "", cursorValue: String = "",
         itemDate: Date, metadata: [String: String] = [:], fingerprint: String? = nil) {
        self.id = id
        self.kind = kind
        self.cursorKey = cursorKey
        self.cursorValue = cursorValue
        self.itemDate = itemDate
        self.metadata = metadata
        self.fingerprint = fingerprint
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
