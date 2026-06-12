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
//  THE POINTER CONTRACT (June 11 pointer rewrite + June 12 backfill — Documentation/Pointer
//  Architecture…): every candidate names the cursor it advances (`cursorKey` → `cursorValue`).
//  The pipeline processes candidates in scan order and advances each candidate's cursor only
//  after its durable save — a crash resumes exactly where it stopped. Ordering per cursorKey:
//   - Key has a PLAIN pointer → incremental: candidates ascend (oldest first), pointer sweeps up.
//   - Key has NO pointer → BACKFILL (first run for that key): candidates DESCEND (newest first —
//     the user watches it understand NOW, not 2019), and each cursorValue is a `BackfillCursor`
//     encoding the consumed interval [lo, hi]. New items arriving mid-backfill sit above `hi`
//     and are emitted FIRST (ascending) on later runs, before the descent resumes below `lo`.
//   - scan() reports finished backfills via `ScanResult.completions`; the pipeline collapses
//     those keys to plain pointers before processing.
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

    /// Same candidate with a different pointer write — backfill encodings depend on each item's
    /// position in the consumption order, so sources assign them after selection/sorting.
    func replacingCursorValue(_ value: String) -> Candidate {
        Candidate(id: id, kind: kind, cursorKey: cursorKey, cursorValue: value,
                  itemDate: itemDate, metadata: metadata)
    }
}

/// What one scan hands the pipeline: the candidates to process (in consumption order) plus any
/// backfills the scan discovered to be FINISHED (budget spent or nothing left below `lo`) —
/// `completions` maps cursorKey → the final plain pointer value, applied before processing.
struct ScanResult: Sendable {
    var candidates: [Candidate]
    var completions: [String: String] = [:]
}

/// A key's pointer value while its first run (the backfill) is still in flight: the consumed
/// region is the closed interval **[lo, hi]** instead of "everything ≤ pointer".
///   hi — the newest consumed value; new items land above it and move it up. Becomes the plain
///        pointer when the backfill completes.
///   lo — the descent watermark ("dug down to here"); resuming digs strictly below it.
///   remaining — descent budget left (files/notes honor their connector cap as a TOTAL across
///        interrupted runs); nil for chats, where the rolling 90-day floor terminates the dig.
/// Stored JSON-encoded in the same SourceCursor.value string — a `{` prefix is unambiguous
/// (plain values always start with a digit), so the Store/Pipeline stay encoding-blind.
struct BackfillCursor: Codable, Sendable {
    var hi: String
    var lo: String
    var remaining: Int?

    /// nil input (no pointer yet) or a plain value both decode to nil — only an in-flight
    /// backfill returns a value.
    static func decode(_ raw: String?) -> BackfillCursor? {
        guard let raw, raw.hasPrefix("{") else { return nil }
        return try? JSONDecoder().decode(BackfillCursor.self, from: Data(raw.utf8))
    }

    var encoded: String {
        String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? ""
    }

    /// Assign backfill encodings to a newest-first descent batch (files + notes — the budgeted
    /// sources): each item's write records the consumed interval [its value, hi] plus the budget
    /// left after it. The item that spends the last of the budget writes the plain `hi` pointer —
    /// completing the backfill in its own durable transaction.
    static func descent(_ kept: [Candidate], hi: String, budget: Int) -> [Candidate] {
        kept.enumerated().map { i, c in
            let left = budget - (i + 1)
            return c.replacingCursorValue(
                left <= 0 ? hi : BackfillCursor(hi: hi, lo: c.cursorValue, remaining: left).encoded)
        }
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
    /// map (a source reads only its own keys; missing key = backfill = everything, connector
    /// caps still apply). Candidate ordering per cursorKey follows the contract above:
    /// incremental keys ascend, backfilling keys descend (new-above-hi items first, ascending).
    func scan(since cursors: [String: String]) throws -> ScanResult
    /// Expensive content extraction for a candidate the pipeline chose to process.
    func load(_ candidate: Candidate) throws -> Artifact
}
