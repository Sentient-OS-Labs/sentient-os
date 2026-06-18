//
//  NotesSource.swift
//  Sentient OS macOS
//
//  Reads Apple Notes' local store, NoteStore.sqlite (Arch §4, [MEASURED]: the
//  gunzip → protobuf 2→3→2 recipe decoded 100% of real notes — 249 in research, 87/87 on a
//  live Mac during this build). One note = one Artifact through the file-flavored triage
//  prompt — no windows, no picker; the newest-1000 cap + triage do the filtering.
//
//  The note body is DOUBLE-wrapped: gzip outside (magic 1f 8b 08), protobuf inside. We gunzip
//  via the Compression framework, then walk the protobuf wire format down fields 2 → 3 → 2 —
//  deliberately NOT a schema-aware protobuf parser. Fail-closed: anything undecodable is
//  skipped, never fed garbled to the model.
//
//  Incrementality (June 11 pointer rewrite): one "notes" pointer, "(modEpochSeconds|UUID)" —
//  an edited note's mod-date moves past it and the note re-summarizes as a new version.
//  Locked (ZISPASSWORDPROTECTED) and deleted (ZMARKEDFORDELETION) notes are skipped in SQL.
//  Requires Full Disk Access. Key methods: eligibleNotes() · decodeBody(_:).
//

import Foundation
import Compression

struct NotesSource: Sendable {
    let kind: SourceKind = .notes

    // MARK: Tunables
    static let maxNotes = 1_000            // newest-first cap (TODO-plan connector limits)
    static let maxContentChars = 8_000     // same cap as file extraction

    var dbPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
            .path
    }

    // MARK: Eligible notes (the iterative system's flat, pointer-free view)

    /// The current eligible notes for the iterative system (NotesConnector). Same decode + cap as
    /// `scan`, but keyed on **creation date** (so an edited note is NOT re-summarized — created-date
    /// never moves), with NO cursor/backfill/hold-back — IterativeRun's pointer decides new-vs-done.
    /// Each Candidate's `itemDate` IS its creation date (so ItemKey = (createdDate, "notes:<uuid>")).
    /// Newest-created first. Reuses `decodeBody` (fail-closed: undecodable → skipped).
    func eligibleNotes() throws -> [Candidate] {
        let (dbURL, tempDir) = try SQLiteDB.walSafeCopy(of: dbPath)
        defer { try? FileManager.default.removeItem(at: tempDir) }   // delete the plaintext copy immediately
        let reader = try SQLiteReader(path: dbURL.path)

        var folders: [Int64: String] = [:]
        try reader.forEachRow("SELECT Z_PK, ZTITLE2 FROM ZICCLOUDSYNCINGOBJECT WHERE ZTITLE2 IS NOT NULL") { r in
            if let t = r.text(1) { folders[r.int(0)] = t }
        }

        var out: [Candidate] = []
        try reader.forEachRow("""
            SELECT o.ZIDENTIFIER, o.ZTITLE1,
                   COALESCE(o.ZCREATIONDATE3, o.ZCREATIONDATE2, o.ZCREATIONDATE1, o.ZCREATIONDATE) AS created,
                   o.ZFOLDER, d.ZDATA
            FROM ZICCLOUDSYNCINGOBJECT o JOIN ZICNOTEDATA d ON o.ZNOTEDATA = d.Z_PK
            WHERE o.ZISPASSWORDPROTECTED IS NOT 1 AND o.ZMARKEDFORDELETION IS NOT 1
            ORDER BY created DESC LIMIT \(Self.maxNotes)
            """) { r in
            guard let id = r.text(0) else { return }
            guard let blob = r.blob(4), let decoded = Self.decodeBody(blob) else { return }   // fail-closed
            let body = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }                                                 // attachment-only / blank

            let title = r.text(1) ?? String(body.prefix(40))
            let folder = folders[r.int(3)] ?? "Notes"
            let created = Date(timeIntervalSinceReferenceDate: r.double(2))

            out.append(Candidate(
                id: "notes:\(id)", kind: .notes,
                cursorKey: "notes", cursorValue: "",   // vestigial — the iterative core keys on ItemKey
                itemDate: created,
                metadata: [
                    "folder": folder,
                    "name": title,
                    "displayPath": "Apple Notes · \(folder) · \(title)",
                    "created": Self.dateString(created),
                    "noteText": String(body.prefix(Self.maxContentChars)),
                ]))
        }
        return out   // newest-created first (the SQL ORDER)
    }

    // MARK: Body decode — gunzip, then protobuf fields 2 → 3 → 2

    /// ZICNOTEDATA.ZDATA → the note's plain text. nil = not decodable (skip the note).
    static func decodeBody(_ zdata: Data) -> String? {
        guard let raw = gunzip(zdata),
              let document = firstMessage(field: 2, in: raw),
              let note = firstMessage(field: 3, in: document),
              let textBytes = firstMessage(field: 2, in: note) else { return nil }
        return String(data: textBytes, encoding: .utf8)
    }

    /// Minimal gzip unwrap: validate the magic, skip the header (+ optional FLG fields), then
    /// raw-DEFLATE inflate via the Compression framework (COMPRESSION_ZLIB = raw deflate; the
    /// 8-byte gzip trailer past end-of-stream is ignored by the decoder).
    private static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 0x08 else { return nil }
        let flags = data[3]
        var i = 10
        if flags & 0x04 != 0 {                                   // FEXTRA: 2-byte LE length + payload
            guard i + 2 <= data.count else { return nil }
            let xlen = Int(data[i]) | (Int(data[i + 1]) << 8)
            i += 2 + xlen
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 { // FNAME, FCOMMENT: NUL-terminated
            while i < data.count, data[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }                          // FHCRC
        guard i < data.count else { return nil }
        return inflateRaw(data.subdata(in: i..<data.count))
    }

    private static func inflateRaw(_ src: Data) -> Data? {
        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }

        return src.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) -> Data? in
            let srcPtr = rawBuf.bindMemory(to: UInt8.self).baseAddress!
            // No default init in Swift; compression_stream_init resets the fields anyway,
            // so the real src pointer is assigned after init.
            var stream = compression_stream(dst_ptr: dst, dst_size: chunk,
                                            src_ptr: srcPtr, src_size: src.count, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
            defer { compression_stream_destroy(&stream) }
            stream.src_ptr = srcPtr
            stream.src_size = src.count
            var out = Data()
            while true {
                stream.dst_ptr = dst
                stream.dst_size = chunk
                switch compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)) {
                case COMPRESSION_STATUS_OK:
                    out.append(dst, count: chunk - stream.dst_size)
                case COMPRESSION_STATUS_END:
                    out.append(dst, count: chunk - stream.dst_size)
                    return out
                default:
                    return nil
                }
            }
        }
    }

    /// The first length-delimited occurrence of `field` in a protobuf message — a minimal
    /// wire-format walk (varints + length-delimited; fixed32/64 skipped), no schema needed.
    private static func firstMessage(field want: Int, in buf: Data) -> Data? {
        var i = buf.startIndex
        func varint() -> UInt64? {
            var value: UInt64 = 0, shift: UInt64 = 0
            while i < buf.endIndex, shift <= 63 {
                let b = buf[i]; i += 1
                value |= UInt64(b & 0x7F) << shift; shift += 7
                if b & 0x80 == 0 { return value }
            }
            return nil
        }
        while i < buf.endIndex {
            guard let key = varint() else { return nil }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:                                       // varint
                guard varint() != nil else { return nil }
            case 1:                                       // fixed64
                guard i + 8 <= buf.endIndex else { return nil }
                i += 8
            case 2:                                       // length-delimited
                guard let len64 = varint(), let len = Int(exactly: len64),
                      len >= 0, i + len <= buf.endIndex else { return nil }
                if field == want { return buf[i ..< i + len] }
                i += len
            case 5:                                       // fixed32
                guard i + 4 <= buf.endIndex else { return nil }
                i += 4
            default:                                      // groups/unknown → bail (fail-closed)
                return nil
            }
        }
        return nil
    }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
    }()
    private static func dateString(_ d: Date) -> String { df.string(from: d) }
}
