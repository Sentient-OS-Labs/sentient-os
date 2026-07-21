//
//  AppleMailSource.swift
//  Sentient OS macOS
//
//  Reads Apple Mail's local Envelope Index — the SQLite database at
//  ~/Library/Mail/V{N}/MailData/Envelope Index that indexes every message across all
//  configured accounts. Same on-device shape as NotesSource: WAL-safe COPY → EXTRACT →
//  DELETE, one email = one Candidate through a mail-flavored triage prompt. No cloud,
//  no connector page — Mail's store is on disk, so this is a PRIVACY-FIRST on-device
//  source (unlike Gmail, which rides the Codex cloud connector).
//
//  ## V10 Schema (verified live on macOS 27 / Mail V10, 2026-07-20)
//
//  The Envelope Index schema has drifted significantly from the older V2–V7 era that
//  most reverse-engineering docs describe. Key differences measured on a live Mac:
//
//  - **No `uid` column.** Exchange/EWS accounts store a base64 `remote_id`; IMAP
//    accounts store a numeric `remote_id`. Neither maps to the `.emlx` filename.
//  - **`messages.ROWID` IS the `.emlx` filename.** Verified: ROWID 33249 →
//    `…/Inbox.mbox/…/Data/3/3/Messages/33249.emlx`. This is the reliable join key.
//  - **`messages.sender` → `addresses.ROWID` directly.** The `senders` /
//    `sender_addresses` tables exist but are a separate reputation/bucketing system;
//    the FK goes straight to `addresses`.
//  - **Dedicated `read` / `flagged` / `deleted` boolean columns** (0 or 1), NOT the
//    jwz bit-flag layout from the `.emlx` plist era. The `flags` column still exists
//    but its bit positions don't match the old spec.
//  - **Dates are Unix epoch seconds** (NOT Apple's 2001-01-01 reference date).
//    `date_received = 1784591689` → 2026-07-20. Using `timeIntervalSinceReferenceDate`
//    would yield 2057.
//  - **Mailbox URLs use three schemes:** `ews://`, `imap://`, `local://`. EWS names
//    its junk folder "Junk Email" (not "Junk") and its trash "Deleted Items".
//
//  ## Body extraction
//
//  The body lives in one `.emlx` file per message, named `{ROWID}.emlx` (or
//  `{ROWID}.partial.emlx` when attachments were split off). The on-disk layout nests
//  under per-account UUID directories with per-mailbox sub-UUIDs and optional sharding
//  (`Data/Messages/` or `Data/{N}/{N}/Messages/`), none of which are in the DB. Rather
//  than hardcode that fragile path math, we walk the store tree ONCE per run to build a
//  `ROWID → [.emlx path]` index, then resolve each message's body by dict lookup.
//
//  Body extraction is BEST-EFFORT / FAIL-CLOSED: any failure (file missing, undecoded
//  MIME, truncated) → nil body → the model judges from envelope metadata alone (the
//  same signal the Gmail connector works from). This mirrors how NotesSource handles
//  undownloaded iCloud notes.
//
//  Incrementality: one "mail" bucket; each email keyed (ItemKey) on its RECEIVED date,
//  so a re-delivered message is NOT re-summarized. High-water mark in CycleStore.
//  Deleted and Junk/Trash messages are excluded in SQL. Requires Full Disk Access.
//  Doc: Documentation/Apple Mail Source (Envelope Index).md
//

import Foundation

struct AppleMailSource: Sendable {
    let kind: SourceKind = .appleMail

    // MARK: Tunables

    /// Newest-first cap (same philosophy as NotesSource.maxNotes — triage does the filtering).
    static let maxEmails = 2_000

    /// Mailbox names to exclude — Trash, Junk, and Spam hold nothing vault-worthy and would
    /// flood the pipeline with noise. Matched case-insensitively against the last path
    /// component of the mailbox URL. Covers both IMAP ("Junk", "Deleted Messages") and
    /// EWS/Exchange ("Junk Email", "Deleted Items") naming.
    private static let excludedMailboxes: Set<String> = [
        "trash", "junk", "spam", "junk email", "junk e-mail",
        "deleted items", "deleted messages",
    ]

    /// The root of the on-disk message store (~/Library/Mail/V{N}) — the directory walked
    /// to build the ROWID → .emlx index. nil if Mail has never been used here.
    static var storeRoot: URL? {
        dbPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent() }
    }

    // MARK: Path resolution

    /// ~/Library/Mail/V{N}/MailData/Envelope Index — glob V* and pick the highest version.
    /// Returns nil if Mail has never been used on this Mac (no ~/Library/Mail directory).
    static var dbPath: String? {
        let mailDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mail")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: mailDir, includingPropertiesForKeys: nil) else { return nil }
        // V10 > V9 > V8 … — sort by the numeric suffix, descending.
        func versionNumber(_ url: URL) -> Int {
            Int(String(url.lastPathComponent.dropFirst())) ?? 0
        }
        let versionDirs = entries
            .filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("V") }
            .sorted { versionNumber($0) > versionNumber($1) }
        for v in versionDirs {
            let candidate = v.appendingPathComponent("MailData/Envelope Index")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    /// Is Apple Mail present on this Mac? (Used by the Settings chip to show/hide, same
    /// pattern as WhatsAppSource.isInstalled.)
    static var isInstalled: Bool { dbPath != nil }

    // MARK: Eligible emails (the iterative system's flat, pointer-free view)

    /// The current eligible emails for the iterative system (MailConnector). WAL-safe read
    /// of the Envelope Index + sender/subject/mailbox resolution + cap, then best-effort
    /// `.emlx` body enrichment. Keyed on **received date** (so a re-delivered message is
    /// NOT re-summarized). Newest first.
    func eligibleEmails() throws -> [Candidate] {
        guard let path = Self.dbPath else { return [] }
        let (dbURL, tempDir) = try SQLiteDB.walSafeCopy(of: path)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let reader = try SQLiteReader(path: dbURL.path)

        // Resolve the FK tables up front (small — one dict each).
        let subjects = Self.table(reader, table: "subjects", idCol: "ROWID", textCol: "subject")
        let addresses = Self.addressTable(reader)
        let mailboxes = Self.mailboxTable(reader)

        // Build the ROWID → .emlx path index ONCE, before the row scan, so per-message body
        // resolution is a dict lookup. The `.emlx` filename IS the message ROWID (verified
        // live on V10). Empty when there's no store root.
        let emlxIndex = Self.buildEMLXIndex()

        var out: [Candidate] = []
        try reader.forEachRow("""
            SELECT m.ROWID, m.date_received, m.date_sent, m.read, m.flagged,
                   m.subject, m.sender, m.mailbox
            FROM messages m
            WHERE m.deleted = 0
            ORDER BY m.date_received DESC
            LIMIT \(Self.maxEmails)
            """) { r in
            let rowid = r.int(0)

            // Resolve mailbox name + URL; skip Trash/Junk/Spam.
            let mailboxID = r.int(7)
            let mailboxName = mailboxes[mailboxID]?.name ?? "Mail"
            let mailboxURL = mailboxes[mailboxID]?.url ?? ""
            if Self.excludedMailboxes.contains(mailboxName.lowercased()) { return }

            // V10 stores dates as Unix epoch seconds (NOT Apple's 2001 reference date).
            let received = Date(timeIntervalSince1970: r.double(1))
            let sent = Date(timeIntervalSince1970: r.double(2))
            let subject = subjects[r.int(5)] ?? "(no subject)"
            // V10: messages.sender → addresses.ROWID directly (no senders/sender_addresses hop).
            let sender = addresses[r.int(6)] ?? "Unknown"

            let isRead = r.int(3) == 1
            let isFlagged = r.int(4) == 1

            // Best-effort body: resolve the .emlx by ROWID. nil ⇒ metadata-only.
            let body = Self.resolveBody(rowid: rowid, index: emlxIndex)

            let emailText = Self.formatEmail(from: sender, subject: subject,
                                             mailbox: mailboxName, received: received,
                                             sent: sent, isRead: isRead, isFlagged: isFlagged,
                                             body: body)

            out.append(Candidate(
                id: "mail:\(rowid)", kind: .appleMail,
                cursorKey: "mail", cursorValue: "",
                itemDate: received,
                metadata: [
                    "folder": mailboxName,
                    "name": subject,
                    "displayPath": "Apple Mail · \(mailboxName) · \(subject)",
                    "created": Self.dateString(received),
                    "sender": sender,
                    "mailbox": mailboxName,
                    "emailText": emailText,
                ]))
        }

        SourceHealth.checkListingCollapse(source: "appleMail", bucketKey: "mail", count: out.count)
        return out   // newest-received first (the SQL ORDER)
    }

    // MARK: FK table loaders

    /// Generic two-column FK table → dict (ROWID → text).
    private static func table(_ reader: SQLiteReader, table: String,
                              idCol: String, textCol: String) -> [Int64: String] {
        var out: [Int64: String] = [:]
        try? reader.forEachRow("SELECT \(idCol), \(textCol) FROM \(table)") { r in
            if let t = r.text(1) { out[r.int(0)] = t }
        }
        return out
    }

    /// addresses table → dict (ROWID → "Display Name <email>" or just "email").
    /// The `comment` column holds the display name; `address` holds the email.
    private static func addressTable(_ reader: SQLiteReader) -> [Int64: String] {
        var out: [Int64: String] = [:]
        try? reader.forEachRow("SELECT ROWID, address, comment FROM addresses") { r in
            let email = r.text(1) ?? ""
            let name = r.text(2) ?? ""
            if name.isEmpty || name == email {
                out[r.int(0)] = email
            } else {
                out[r.int(0)] = "\(name) <\(email)>"
            }
        }
        return out
    }

    private struct MailboxInfo { let name: String; let url: String }

    /// mailboxes table → dict (ROWID → (display name, raw URL)). The `url` column holds
    /// something like `ews://UUID/Inbox` or `imap://UUID/INBOX`; the display name is its
    /// last path component, percent-decoded. The raw URL is kept for body disambiguation.
    private static func mailboxTable(_ reader: SQLiteReader) -> [Int64: MailboxInfo] {
        var out: [Int64: MailboxInfo] = [:]
        try? reader.forEachRow("SELECT ROWID, url FROM mailboxes") { r in
            guard let url = r.text(1) else { return }
            let last = url.split(separator: "/").last.map(String.init) ?? url
            let name = last.removingPercentEncoding ?? last
            out[r.int(0)] = MailboxInfo(name: name, url: url)
        }
        return out
    }

    // MARK: .emlx body resolution (best-effort, fail-closed)

    /// Walk the store root once and map every message ROWID → the `.emlx` file(s) that
    /// carry it. The `.emlx` filename IS the message ROWID (verified on V10). A ROWID
    /// can have both a full `.emlx` and a `.partial.emlx` (attachments split off); the
    /// full one is preferred. Non-throwing — any I/O hiccup yields a partial/empty index
    /// and the pipeline simply falls back to metadata-only triage.
    private static func buildEMLXIndex() -> [Int64: [String]] {
        guard let root = storeRoot else { return [:] }
        var index: [Int64: [String]] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [:] }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isPartial = name.hasSuffix(".partial.emlx")
            guard isPartial || name.hasSuffix(".emlx") else { continue }
            // Strip the extension(s) to recover the numeric ROWID.
            var base = name
            if isPartial { base.removeLast(".partial.emlx".count) }
            else { base.removeLast(".emlx".count) }
            guard let rowid = Int64(base) else { continue }
            // A full .emlx outranks its .partial sibling; insert full first so it's preferred.
            var paths = index[rowid] ?? []
            if isPartial { paths.append(url.path) } else { paths.insert(url.path, at: 0) }
            index[rowid] = paths
        }
        return index
    }

    /// The plain-text body for one message, or nil. Resolves the file by ROWID (the
    /// `.emlx` filename), then parses the MIME body via EMLXParser. Every failure
    /// returns nil (→ metadata-only triage).
    private static func resolveBody(rowid: Int64, index: [Int64: [String]]) -> String? {
        guard rowid > 0, let candidates = index[rowid], !candidates.isEmpty else { return nil }
        // Prefer the full .emlx (index[0]) over .partial.emlx. When multiple full files
        // exist (shouldn't happen — ROWID is globally unique), try each until one parses.
        for path in candidates {
            if let body = EMLXParser.bodyText(ofFileAt: path) { return body }
        }
        return nil
    }

    // MARK: Formatting

    /// The text the triage model judges: the envelope metadata plus, when we recovered it,
    /// the message body. One email, one artifact, one verdict.
    private static func formatEmail(from sender: String, subject: String, mailbox: String,
                                    received: Date, sent: Date, isRead: Bool,
                                    isFlagged: Bool, body: String?) -> String {
        var lines = [
            "From: \(sender)",
            "Subject: \(subject)",
            "Mailbox: \(mailbox)",
            "Received: \(dateString(received))",
        ]
        // Only add sent date if it differs meaningfully from received (forwarded/delayed mail).
        if abs(received.timeIntervalSince(sent)) > 3600 {
            lines.append("Originally sent: \(dateString(sent))")
        }
        if isFlagged { lines.append("Flagged: yes") }
        lines.append("Read: \(isRead ? "yes" : "no")")
        if let body, !body.isEmpty {
            lines.append("")
            lines.append("Body:")
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy h:mm a"; f.timeZone = .current; return f
    }()
    private static func dateString(_ d: Date) -> String { df.string(from: d) }
}
