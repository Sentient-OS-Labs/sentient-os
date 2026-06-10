//
//  SQLiteDB.swift
//  Sentient OS macOS
//
//  Minimal read access for the database sources (WhatsApp / iMessage / Notes), plus the
//  WAL-safe copy (Arch §3.5). The live DBs are open by their owning apps in WAL mode, so we
//  NEVER read them in place: copy the DB + its `-wal`/`-shm` siblings into a fresh temp dir,
//  read the copy, and delete it. For the DB sources we delete it *immediately* after extraction
//  so a plaintext copy of someone's messages never lingers on disk.
//
//  Shared by all three DB sources (the first real second-use-case that justifies a helper).
//

import Foundation
import SQLite3

enum SQLiteDB {
    enum DBError: Error, CustomStringConvertible {
        case missingFile(String)
        case open(String)
        case prepare(String)
        var description: String {
            switch self {
            case .missingFile(let p): return "Database not found at: \(p) (is the app installed / Full Disk Access granted?)"
            case .open(let m):        return "SQLite open failed: \(m)"
            case .prepare(let m):     return "SQLite prepare failed: \(m)"
            }
        }
    }

    /// WAL-safe copy of a live DB (+ `-wal`/`-shm`) into a brand-new temp dir. Returns the copy's
    /// URL and the temp dir. The caller MUST delete `dir` when done (the DB sources do it the
    /// instant extraction finishes).
    static func walSafeCopy(of dbPath: String) throws -> (db: URL, dir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { throw DBError.missingFile(dbPath) }

        let dir = fm.temporaryDirectory.appendingPathComponent("sentientos-db-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let name = URL(fileURLWithPath: dbPath).lastPathComponent
        let dst = dir.appendingPathComponent(name)
        try fm.copyItem(atPath: dbPath, toPath: dst.path)
        for sib in ["-wal", "-shm"] where fm.fileExists(atPath: dbPath + sib) {
            try? fm.copyItem(atPath: dbPath + sib, toPath: dst.path + sib)
        }
        return (dst, dir)
    }
}

/// A thin SQLite connection for reading one copied DB. Single-threaded use; closes on deinit.
/// Opened read-WRITE on the *temp copy* (not the original) so SQLite can transparently replay the
/// copied `-wal` — the most reliable way to see the very latest rows.
final class SQLiteReader {
    private var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db); db = nil
            throw SQLiteDB.DBError.open(msg)
        }
    }
    deinit { sqlite3_close(db) }

    /// Run a read query, invoking `row` for each result row in order. (We interpolate only our own
    /// numeric literals into SQL — no untrusted input — so no bind params are needed.)
    func forEachRow(_ sql: String, _ row: (Row) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteDB.DBError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { try row(Row(stmt!)) }
    }

    /// Typed, index-based column access for one row.
    struct Row {
        private let stmt: OpaquePointer
        init(_ s: OpaquePointer) { stmt = s }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func text(_ i: Int32) -> String? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
    }
}
