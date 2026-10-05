// AppleMailSource.swift
// Read-only Mail index snapshots, account discovery, metadata exclusions and body resolution.
// No Mail automation, network, attachment extraction, or credential access.
// Doc: Sources/Documentation - Sources - Local (Files, WhatsApp, iMessage, Notes).md

import Foundation
import SQLite3
import CryptoKit

nonisolated enum AppleMailError: Error { case access, unsupportedSchema, database, busy, filesystem, missingBody }

nonisolated struct AppleMailAccount: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
}

nonisolated struct AppleMailRow: Sendable {
    let id: Int64
    let account: String
    let messageID: String
    let date: Date
    let excluded: Bool
    let sent: Bool
    /// Junk may be read for an ephemeral preview; deleted messages and drafts may not.
    let previewJunk: Bool

    init(id: Int64, account: String, messageID: String, date: Date, excluded: Bool, sent: Bool, previewJunk: Bool = false) {
        self.id = id; self.account = account; self.messageID = messageID; self.date = date
        self.excluded = excluded; self.sent = sent; self.previewJunk = previewJunk
    }
}

/// All queries run against a private temporary SQLite backup. A bounded backup gives a transactionally
/// consistent view while Mail writes its WAL; neither immutable mode nor file copying is safe here.
nonisolated final class AppleMailSnapshot: @unchecked Sendable {
    private var db: OpaquePointer?
    let root: URL
    let generation: String
    let accounts: [AppleMailAccount]
    let rows: [AppleMailRow]
    private var files: [String: [Int64: [URL]]] = [:]

    init(root: URL, selected: Set<String>? = nil) throws {
        self.root = root
        let index = root.appendingPathComponent("MailData/Envelope Index")
        db = try Self.backup(index.path)
        do {
            try Self.validate(db)
            generation = try Self.query(db, "SELECT value FROM properties WHERE key='UUID'").first?.first ?? ""
            guard !generation.isEmpty else { throw AppleMailError.unsupportedSchema }
            let boxes = try Self.query(db, "SELECT ROWID,url FROM mailboxes")
            var mailboxAccounts: [Int64: String] = [:], deniedBoxes = Set<Int64>(), hiddenBoxes = Set<Int64>(), sentBoxes = Set<Int64>()
            var found = Set<String>()
            for box in boxes {
                guard let id = Int64(box[0]), let url = URL(string: box[1]), let host = url.host,
                      UUID(uuidString: host) != nil else { continue }
                let account = host.uppercased()
                mailboxAccounts[id] = account; found.insert(account)
                let segments = url.pathComponents.map { $0.removingPercentEncoding?.lowercased() ?? $0.lowercased() }
                if segments.contains(where: Self.excludedMailbox) { deniedBoxes.insert(id) }
                if segments.contains(where: Self.hiddenMailbox) { hiddenBoxes.insert(id) }
                if segments.contains(where: { ["sent", "sent mail", "sent messages"].contains($0) }) { sentBoxes.insert(id) }
            }
            let labels = Self.accountLabels(found)
            accounts = found.sorted().enumerated().map { offset, id in
                AppleMailAccount(id: id, name: labels[id] ?? "Local Mail account \(offset + 1) · \(id.prefix(4))")
            }
            if selected?.isEmpty == true { rows = []; sqlite3_close(db); db = nil; return }
            var memberships: [Int64: Set<Int64>] = [:]
            try Self.forEach(db, "SELECT message_id,mailbox_id FROM labels UNION SELECT message,mailbox FROM server_messages UNION SELECT sm.message,sl.label FROM server_labels sl JOIN server_messages sm ON sm.ROWID=sl.server_message") { pair in
                if let message = Int64(pair[0]), let box = Int64(pair[1]) { memberships[message, default: []].insert(box) }
            }
            var indexed: [AppleMailRow] = []
            try Self.forEach(db, """
                SELECT m.ROWID,m.mailbox,COALESCE(g.message_id_header,''),COALESCE(NULLIF(m.date_sent,0),m.date_received,0),
                       m.deleted,COALESCE(g.model_category,0),
                       EXISTS(SELECT 1 FROM server_messages s WHERE s.message=m.ROWID AND
                         (s.deleted!=0 OR s.draft!=0)),
                       COALESCE(m.unsubscribe_type,0),COALESCE(m.list_id_hash,0),
                       EXISTS(SELECT 1 FROM server_messages s WHERE s.message=m.ROWID AND s.junk_level>0)
                FROM messages m LEFT JOIN message_global_data g ON g.ROWID=m.global_message_id
                ORDER BY m.ROWID DESC
                """) { r in
                guard let id = Int64(r[0]), let box = Int64(r[1]), let account = mailboxAccounts[box],
                      selected == nil || selected!.contains(account) else { return }
                let labels = memberships[id, default: []].union([box])
                let hidden = r[4] != "0" || r[6] != "0" || !labels.isDisjoint(with: hiddenBoxes)
                let junk = r[5] == "3" || r[7] != "0" || r[8] != "0" || r[9] != "0" || !labels.isDisjoint(with: deniedBoxes)
                indexed.append(AppleMailRow(id: id, account: account, messageID: r[2],
                    date: Date(timeIntervalSince1970: Double(r[3]) ?? 0),
                    excluded: hidden || junk, sent: !labels.isDisjoint(with: sentBoxes),
                    previewJunk: junk && !hidden))
            }
            // Duplicate physical copies are not independent privacy decisions. If a copy is in
            // Junk/Promotions, exclude all copies of that Message-ID in the same account.
            let deniedIDs = Set(indexed.filter { $0.excluded && !$0.messageID.isEmpty }.map { $0.account + "\u{0}" + $0.messageID })
            let hiddenIDs = Set(indexed.filter { $0.excluded && !$0.previewJunk && !$0.messageID.isEmpty }.map { $0.account + "\u{0}" + $0.messageID })
            rows = indexed.map { r in
                let key = r.account + "\u{0}" + r.messageID
                let excluded = r.excluded || deniedIDs.contains(key)
                let hidden = (r.excluded && !r.previewJunk) || hiddenIDs.contains(key)
                return AppleMailRow(id: r.id, account: r.account, messageID: r.messageID, date: r.date,
                    excluded: excluded, sent: r.sent, previewJunk: excluded && !hidden)
            }
            sqlite3_close(db); db = nil
        } catch { sqlite3_close(db); db = nil; throw error }
    }

    /// Both Mail and account metadata are read from consistent connection-private backups.
    private static func backup(_ path: String) throws -> OpaquePointer {
        var source: OpaquePointer?, destination: OpaquePointer?
        guard sqlite3_open_v2(path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(source); throw AppleMailError.access
        }
        defer { sqlite3_close(source) }
        // SQLite deletes this temporary database on close; the bounded pager can spill to disk.
        guard sqlite3_open_v2("", &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let destination else { sqlite3_close(destination); throw AppleMailError.database }
        do {
            guard sqlite3_exec(destination, "PRAGMA temp_store=FILE; PRAGMA cache_size=-8192; PRAGMA secure_delete=ON;", nil, nil, nil) == SQLITE_OK,
                  let copy = sqlite3_backup_init(destination, "main", source, "main") else { throw AppleMailError.database }
            let deadline = Date().addingTimeInterval(8)
            var status: Int32
            repeat {
                status = sqlite3_backup_step(copy, 256)
                if status == SQLITE_BUSY || status == SQLITE_LOCKED { Thread.sleep(forTimeInterval: 0.02) }
            } while [SQLITE_OK, SQLITE_BUSY, SQLITE_LOCKED].contains(status) && Date() < deadline
            let finish = sqlite3_backup_finish(copy)
            guard status == SQLITE_DONE, finish == SQLITE_OK else { throw AppleMailError.busy }
            return destination
        } catch { sqlite3_close(destination); throw error }
    }

    private static func hiddenMailbox(_ component: String) -> Bool {
        ["trash", "bin", "deleted messages", "deleted items", "draft", "drafts", "corbeille",
         "brouillons", "papierkorb", "entwürfe", "papelera", "borradores", "cestino", "bozze",
         "lixo", "rascunhos", "prullenmand", "concepten", "ゴミ箱", "下書き", "草稿", "废纸篓",
         "휴지통", "임시보관함"].contains(component)
    }

    private static func excludedMailbox(_ component: String) -> Bool {
        // Known localizations and Gmail categories. Unknown names are additionally protected by
        // server flags, Apple's category, MIME headers and the local semantic triage.
        let words: Set<String> = ["junk", "junk mail", "junk e-mail", "spam", "trash", "bin", "deleted messages",
            "deleted items", "draft", "drafts", "promotions", "category_promotions", "bulk mail",
            "indésirables", "courrier indésirable", "corbeille", "brouillons", "papierkorb", "entwürfe",
            "werbung", "unerwünscht", "correo no deseado", "papelera", "borradores", "cestino", "bozze",
            "lixo", "rascunhos", "reclame", "ongewenst", "prullenmand", "concepten", "迷惑メール", "ゴミ箱",
            "下書き", "垃圾邮件", "垃圾郵件", "草稿", "废纸篓", "스팸", "휴지통", "임시보관함"]
        return words.contains(component)
    }

    /// Display metadata only, joined by the exact Mail account UUID. Some Mail records are
    /// children of an Internet Account. Never query credentials, tokens, or account properties,
    /// and never forward these UI labels to cloud account discovery or writing-style collection.
    private static func accountLabels(_ ids: Set<String>) -> [String: String] {
        let safeIDs = ids.filter { UUID(uuidString: $0) != nil }
        guard !safeIDs.isEmpty else { return [:] }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Accounts/Accounts4.sqlite").path
        guard let accountsDB = try? backup(path) else { return [:] }
        defer { sqlite3_close(accountsDB) }
        // UUID validation above restricts the interpolation to hex digits and hyphens.
        let identifiers = safeIDs.map { "'\($0)'" }.joined(separator: ",")
        let sql = """
            SELECT upper(a.ZIDENTIFIER),
                   COALESCE(NULLIF(a.ZUSERNAME,''),NULLIF(p.ZUSERNAME,''),''),
                   COALESCE(NULLIF(a.ZACCOUNTDESCRIPTION,''),NULLIF(p.ZACCOUNTDESCRIPTION,''),'')
            FROM ZACCOUNT a LEFT JOIN ZACCOUNT p ON p.Z_PK=a.ZPARENTACCOUNT
            WHERE upper(a.ZIDENTIFIER) IN (\(identifiers))
            """
        guard let rows = try? query(accountsDB, sql) else { return [:] }
        var names: [String: String] = [:]
        for row in rows {
            let values = [row[2], row[1]].filter { !$0.isEmpty }
            let unique = values.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if !unique.isEmpty { names[row[0]] = unique.joined(separator: " · ") }
        }
        return names
    }

    private static func validate(_ db: OpaquePointer?) throws {
        let required: [String: Set<String>] = [
            "messages": ["ROWID", "mailbox", "global_message_id", "date_sent", "date_received", "deleted", "unsubscribe_type", "list_id_hash"],
            "mailboxes": ["ROWID", "url"], "properties": ["key", "value"],
            "message_global_data": ["ROWID", "message_id_header", "model_category"],
            "server_messages": ["ROWID", "message", "mailbox", "deleted", "draft", "junk_level"],
            "labels": ["message_id", "mailbox_id"], "server_labels": ["server_message", "label"]]
        for (table, columns) in required {
            let actual = Set(try query(db, "PRAGMA table_info(\(table))").map { $0[1].lowercased() })
            guard Set(columns.map { $0.lowercased() }).isSubset(of: actual) else { throw AppleMailError.unsupportedSchema }
        }
    }

    private static func query(_ db: OpaquePointer?, _ sql: String) throws -> [[String]] {
        var rows: [[String]] = []
        try forEach(db, sql) { rows.append($0) }
        return rows
    }

    private static func forEach(_ db: OpaquePointer?, _ sql: String, body: ([String]) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw AppleMailError.database }
        defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try body((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw AppleMailError.database }
    }

    /// Build an ephemeral file locator, pruning attachment trees and all symbolic links.
    func indexFiles(account: String) throws {
        guard UUID(uuidString: account) != nil else { throw AppleMailError.filesystem }
        let directory = root.appendingPathComponent(account)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return false }) else { throw AppleMailError.filesystem }
        var mapping: [Int64: [URL]] = [:]
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true || file.lastPathComponent == "Attachments" {
                enumerator.skipDescendants(); continue
            }
            guard values.isRegularFile == true, file.pathExtension == "emlx",
                  let id = Int64(file.lastPathComponent.split(separator: ".").first ?? "") else { continue }
            mapping[id, default: []].append(file)
        }
        guard !failed else { throw AppleMailError.filesystem }
        files[account] = mapping
    }

    func body(_ row: AppleMailRow, includeJunkPreview: Bool = false) throws -> AppleMailMIME.Message {
        guard !row.excluded || (includeJunkPreview && row.previewJunk) else { throw AppleMailMIME.Failure.excluded }
        let matches = files[row.account]?[row.id] ?? []
        var lastError: Error = AppleMailError.missingBody
        for url in matches.sorted(by: { !$0.lastPathComponent.contains(".partial.") && $1.lastPathComponent.contains(".partial.") }) {
            do {
                // Recheck immediately before opening; Mail may move or replace a file after listing.
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard resolved == url.standardizedFileURL,
                      resolved.path.hasPrefix(root.appendingPathComponent(row.account).path + "/") else { throw AppleMailError.filesystem }
                let message = try AppleMailMIME.read(url, expectedMessageID: row.messageID, includeJunkPreview: includeJunkPreview)
                return message
            } catch AppleMailMIME.Failure.excluded { throw AppleMailMIME.Failure.excluded }
            catch { lastError = error }
        }
        throw lastError
    }
}

nonisolated enum AppleMailSource {
    // Bump when triage/privacy policy changes so earlier acceptances are re-evaluated locally.
    static let classificationVersion = 1
    static func root() throws -> URL {
        let mail = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
        let versions = try FileManager.default.contentsOfDirectory(at: mail, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent.hasPrefix("V") && Int($0.lastPathComponent.dropFirst()) != nil }
            .sorted { Int($0.lastPathComponent.dropFirst())! > Int($1.lastPathComponent.dropFirst())! }
        guard let root = versions.first else { throw AppleMailError.access }
        return root
    }
    static func accounts() throws -> [AppleMailAccount] { try AppleMailSnapshot(root: root(), selected: []).accounts }
    /// Body and decoded attribution only; the cap includes headers as well as body text.
    static func artifact(row: AppleMailRow, identity: String, message: AppleMailMIME.Message) -> Artifact {
        let candidate = Candidate(id: identity, kind: .appleMail, itemDate: row.date,
                                  metadata: ["folder": "Apple Mail", "sent": row.sent ? "1" : "0",
                                             "junkPreview": row.excluded || AppleMailMIME.excluded(message.headers) ? "1" : "0"])
        let header = ["from", "to", "subject", "date"].map {
            "\($0): \(AppleMailMIME.prefixUTF8(AppleMailMIME.decodedHeader(message.headers[$0, default: ""]), limit: 1000))"
        }.joined(separator: "\n")
        let text = AppleMailMIME.prefixUTF8(header + "\n\n" + message.text, limit: AppleMailConnector.maximumInputBytes)
        return Artifact(candidate: candidate, text: text)
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func identity(salt: String, row: AppleMailRow, message: AppleMailMIME.Message) -> String {
        "appleMail:" + digest([salt, row.account, row.messageID, message.headers["from", default: ""],
            message.headers["date", default: ""], message.headers["subject", default: ""]].joined(separator: "\u{0}"))
    }
    static func messageKey(salt: String, row: AppleMailRow) -> String {
        digest([salt, row.account, row.messageID].joined(separator: "\u{0}"))
    }
    static func contentDigest(_ message: AppleMailMIME.Message, sent: Bool) -> String {
        digest([String(classificationVersion), message.text, String(sent)] .joined(separator: "\u{0}") + "\u{0}" +
            ["from", "to", "subject", "date"].map { message.headers[$0, default: ""] }.joined(separator: "\u{0}"))
    }
}
