import Foundation
import SQLite3

/// Extends AX-visible messages only after two distinct visible anchors identify one local chat.
/// Connections are read-only, short-lived and bounded. No database copy or message cache is created.
nonisolated enum SummaryConversationStore {
    struct Match { let item: Int; let row: Int64; let date: Double }
    struct Continuation { let lines: [String]; let truncated: Bool }
    static func newerMessages(app: SummaryConversation.App, title: String, items: [SummaryConversation.Item],
                              database: URL? = nil) -> Continuation? {
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let path = database ?? home.appendingPathComponent(app == .whatsapp
                ? "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite" : "Library/Messages/chat.db")
            let db = try Reader(path: path.path)
            return try app == .whatsapp ? whatsapp(db, title: title, items: items) : messages(db, title: title, items: items)
        } catch { return nil } // Missing permission/schema/ambiguous identity keeps the narrower AX capture.
    }

    private static func whatsapp(_ db: Reader, title: String, items: [SummaryConversation.Item]) throws -> Continuation? {
        var candidates: [(Int64, Bool)] = []
        try db.query("SELECT Z_PK,ZSESSIONTYPE FROM ZWACHATSESSION WHERE ZPARTNERNAME=? LIMIT 8", [.text(SummaryConversation.clean(title))]) {
            candidates.append((integer($0,0),integer($0,1)==1))
        }
        var identified: [(Int64, Bool, Match)] = []
        for (chat, group) in candidates {
            var matches: [Match] = []
            try db.query("SELECT Z_PK,ZMESSAGEDATE,ZTEXT FROM ZWAMESSAGE WHERE ZCHATSESSION=? AND length(ZTEXT) BETWEEN 12 AND 32768 AND instr(?,ZTEXT)>0 ORDER BY ZMESSAGEDATE DESC LIMIT 64", [.int(chat),.text(items.map(\.text).joined(separator: "\n"))]) { row in
                let text = SummaryConversation.clean(string(row,2))
                guard !text.isEmpty else { return }
                for (index,item) in items.enumerated() where item.message && item.text.contains(", " + text + ",") {
                    matches.append(Match(item:index,row:integer(row,0),date:sqlite3_column_double(row,1)))
                }
            }
            if let last = verified(matches, items: items) { identified.append((chat,group,last)) }
        }
        guard identified.count == 1, let (chat,group,last) = identified.first else { return nil }
        var output: [String] = [], bytes = 0, count = 0, limited = false, included = Set<Int64>()
        let query = """
            SELECT m.ZMESSAGEDATE,m.ZISFROMME,m.ZTEXT,m.ZPUSHNAME,gm.ZCONTACTNAME,m.Z_PK
            FROM ZWAMESSAGE m LEFT JOIN ZWAGROUPMEMBER gm ON gm.Z_PK=m.ZGROUPMEMBER
            WHERE m.ZCHATSESSION=? AND (m.ZMESSAGEDATE>? OR (m.ZMESSAGEDATE=? AND m.Z_PK>?))
              AND length(m.ZTEXT) BETWEEN 1 AND 32768
            """
        let values: [Value] = [.int(chat),.double(last.date),.double(last.date),.int(last.row)]
        func rendered(_ row: OpaquePointer) -> String {
            let sender = integer(row,1)==1 ? "You" : [string(row,4),string(row,3),group ? "Participant" : title].first { !$0.isEmpty }!
            return line(date:sqlite3_column_double(row,0),sender:sender,text:string(row,2))
        }
        try db.query(query + " ORDER BY m.ZMESSAGEDATE,m.Z_PK LIMIT 2001", values) { row in
            count += 1
            guard bytes < 180_000, count <= 2000 else { limited = true; return }
            let text = string(row,2); bytes += text.utf8.count
            included.insert(integer(row,5)); output.append(rendered(row))
        }
        if limited {
            var tail: [String] = []
            try db.query(query + " ORDER BY m.ZMESSAGEDATE DESC,m.Z_PK DESC LIMIT 256", values) { row in
                if !included.contains(integer(row,5)) { tail.append(rendered(row)) }
            }
            if !tail.isEmpty { output += ["[Some intervening messages omitted; latest messages follow]"] + tail.reversed() }
        }
        return Continuation(lines: output, truncated: limited)
    }

    private static func messages(_ db: Reader, title: String, items: [SummaryConversation.Item]) throws -> Continuation? {
        let anchors = items.enumerated().filter { $0.element.anchor.count >= 12 }.suffix(4)
        guard Set(anchors.map { $0.element.anchor }).count >= 2 else { return nil }
        var matches: [Int64: [Match]] = [:]
        for (index,item) in anchors {
            try db.query("""
                SELECT j.chat_id,m.ROWID,m.date,m.text,m.attributedBody
                FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID
                WHERE m.ROWID>(SELECT max(ROWID)-50000 FROM message)
                  AND m.associated_message_type=0 AND m.item_type=0
                  AND (m.text=? OR (length(m.attributedBody)<131072 AND instr(m.attributedBody,CAST(? AS BLOB))>0))
                ORDER BY m.ROWID DESC LIMIT 32
                """, [.text(item.anchor),.text(item.anchor)]) { row in
                let text = body(row, text:3, blob:4)
                if SummaryConversation.clean(text) == item.anchor {
                    matches[integer(row,0),default:[]].append(Match(item:index,row:integer(row,1),date:sqlite3_column_double(row,2)))
                }
            }
        }
        let identified = matches.compactMap { chat, candidates -> (Int64,Match)? in
            verified(candidates,items:items).map { (chat,$0) }
        }
        guard identified.count == 1, let (chat,last) = identified.first else { return nil }
        guard try sameMessagesConversation(db, chat: chat, title: title) else { return nil }
        var participants = 0
        try db.query("SELECT count(*) FROM chat_handle_join WHERE chat_id=?", [.int(chat)]) { participants = Int(integer($0,0)) }
        var output: [String] = [], bytes = 0, count = 0, limited = false, included = Set<Int64>()
        let query = """
            SELECT m.date,m.is_from_me,m.text,m.attributedBody,h.id,m.ROWID
            FROM chat_message_join j JOIN message m ON m.ROWID=j.message_id LEFT JOIN handle h ON h.ROWID=m.handle_id
            WHERE j.chat_id=? AND (m.date>? OR (m.date=? AND m.ROWID>?))
              AND m.associated_message_type=0 AND m.item_type=0
              AND (length(m.text)<32769 OR length(m.attributedBody)<131072)
            """
        let values: [Value] = [.int(chat),.double(last.date),.double(last.date),.int(last.row)]
        func rendered(_ row: OpaquePointer, _ text: String) -> String {
            line(date:sqlite3_column_double(row,0)/1e9,sender:integer(row,1)==1 ? "You" : participants == 1 ? title : string(row,4),text:text)
        }
        try db.query(query + " ORDER BY m.date,m.ROWID LIMIT 2001", values) { row in
            count += 1
            guard bytes < 180_000, count <= 2000 else { limited = true; return }
            let text = body(row,text:2,blob:3)
            guard !text.isEmpty else { return }
            bytes += text.utf8.count
            included.insert(integer(row,5)); output.append(rendered(row,text))
        }
        if limited {
            var tail: [String] = []
            try db.query(query + " ORDER BY m.date DESC,m.ROWID DESC LIMIT 256", values) { row in
                let text = body(row,text:2,blob:3)
                if !included.contains(integer(row,5)), !text.isEmpty { tail.append(rendered(row,text)) }
            }
            if !tail.isEmpty { output += ["[Some intervening messages omitted; latest messages follow]"] + tail.reversed() }
        }
        return Continuation(lines: output, truncated: limited)
    }
    /// Text anchors alone are not identity: also match the active title to the chat or its contact.
    private static func sameMessagesConversation(_ db: Reader, chat: Int64, title: String) throws -> Bool {
        let wanted = SummaryConversation.clean(title).lowercased()
        var named = false
        try db.query("SELECT display_name,chat_identifier FROM chat WHERE ROWID=?", [.int(chat)]) { row in
            named = [string(row,0),string(row,1)].contains { !$0.isEmpty && SummaryConversation.clean($0).lowercased() == wanted }
        }
        if named { return true }
        var handles = Set<String>()
        try db.query("SELECT h.id FROM chat_handle_join j JOIN handle h ON h.ROWID=j.handle_id WHERE j.chat_id=?", [.int(chat)]) {
            handles.insert(contactKey(string($0,0)))
        }
        guard handles.count == 1 else { return false } // Unnamed groups need an explicit group match.
        if handles.contains(contactKey(title)) { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AddressBook")
        var files = [home.appendingPathComponent("AddressBook-v22.abcddb")]
        let sources = (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)) ?? []
        files += sources.prefix(20).map { $0.appendingPathComponent("AddressBook-v22.abcddb") }
        for file in files {
            guard let contacts = try? Reader(path: file.path, deadline: db.deadline) else { continue }
            var ids: [Int64] = []
            try? contacts.query("SELECT Z_PK,ZFIRSTNAME,ZLASTNAME,ZNICKNAME FROM ZABCDRECORD", []) { row in
                let name = [string(row,1),string(row,2)].filter { !$0.isEmpty }.joined(separator: " ")
                if [name,string(row,3)].contains(where: { !$0.isEmpty && $0.lowercased() == wanted }) { ids.append(integer(row,0)) }
            }
            for id in ids.prefix(16) {
                var match = false
                try? contacts.query("SELECT ZFULLNUMBER FROM ZABCDPHONENUMBER WHERE ZOWNER=?", [.int(id)]) { match = match || handles.contains(contactKey(string($0,0))) }
                try? contacts.query("SELECT ZADDRESS FROM ZABCDEMAILADDRESS WHERE ZOWNER=?", [.int(id)]) { match = match || handles.contains(contactKey(string($0,0))) }
                if match { return true }
            }
        }
        return false
    }
    private static func contactKey(_ value: String) -> String {
        if value.contains("@") { return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let digits = value.filter(\.isNumber)
        return digits.count >= 7 ? String(digits.suffix(10)) : value.lowercased()
    }
    /// Repeated anchor text and reversed chronology are insufficient to identify a conversation.
    static func verified(_ matches: [Match], items: [SummaryConversation.Item]) -> Match? {
        let grouped = Dictionary(grouping: matches, by: \.item)
        let unique = grouped.values.filter { $0.count == 1 }.compactMap(\.first).sorted { $0.item < $1.item }
        guard unique.count >= 2, Set(unique.map { items[$0.item].anchor }).count >= 2 else { return nil }
        guard zip(unique,unique.dropFirst()).allSatisfy({ $0.date <= $1.date && $0.row < $1.row }) else { return nil }
        return unique.last
    }
    private static func line(date: Double, sender: String, text: String) -> String {
        "[" + Date(timeIntervalSinceReferenceDate:date).ISO8601Format() + "] " + (sender.isEmpty ? "Participant" : sender) + ": " + text
    }
    private static func integer(_ row: OpaquePointer, _ column: Int32) -> Int64 { sqlite3_column_int64(row,column) }
    private static func string(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row,column).map { String(cString:$0) } ?? ""
    }
    private static func body(_ row: OpaquePointer, text: Int32, blob: Int32) -> String {
        let plain = string(row,text)
        if !plain.isEmpty { return plain }
        guard let pointer = sqlite3_column_blob(row,blob) else { return "" }
        return MessageBody.text(Data(bytes:pointer,count:Int(sqlite3_column_bytes(row,blob)))) ?? ""
    }
    enum Value { case text(String), int(Int64), double(Double) }
    enum Failure: Error { case unavailable }
    private final class Reader {
        var db: OpaquePointer?
        let deadline: Double
        init(path: String, deadline: Double = ProcessInfo.processInfo.systemUptime + 1.2) throws {
            self.deadline = deadline
            guard sqlite3_open_v2(path,&db,SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,nil) == SQLITE_OK else {
                sqlite3_close(db); db=nil; throw Failure.unavailable
            }
            sqlite3_busy_timeout(db,40)
            sqlite3_progress_handler(db,2000,{ pointer in
                guard let pointer else { return 1 }
                let reader = Unmanaged<Reader>.fromOpaque(pointer).takeUnretainedValue()
                return Task.isCancelled || ProcessInfo.processInfo.systemUptime > reader.deadline ? 1 : 0
            },Unmanaged.passUnretained(self).toOpaque())
            guard sqlite3_exec(db,"PRAGMA query_only=ON; BEGIN",nil,nil,nil) == SQLITE_OK else { throw Failure.unavailable }
        }
        deinit { sqlite3_close(db) }
        func query(_ sql: String, _ values: [Value], _ row: (OpaquePointer) throws -> Void) throws {
            try Task.checkCancellation()
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK, let statement else { throw Failure.unavailable }
            defer { sqlite3_finalize(statement) }
            for (index,value) in values.enumerated() {
                let position = Int32(index+1)
                switch value {
                case .text(let text): _ = text.withCString { sqlite3_bind_text(statement,position,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
                case .int(let integer): sqlite3_bind_int64(statement,position,integer)
                case .double(let double): sqlite3_bind_double(statement,position,double)
                }
            }
            while true {
                try Task.checkCancellation()
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW, ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.unavailable }
                try row(statement)
            }
        }
    }
}
