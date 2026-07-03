//
//  iMessageSource.swift
//  Sentient OS macOS
//
//  Reads the Mac's iMessage store, ~/Library/Messages/chat.db (Arch §4, [MEASURED]:
//  the typedstream heuristic decoded 99.97% of 12,017 real messages). Same shape as WhatsApp:
//  WAL-safe COPY → EXTRACT → DELETE, conversation windows via ChatWindowing, opt-in per chat
//  (chat GUIDs), group/DM routed to the matching triage prompt.
//
//  The one iMessage-specific trick: ~99% of modern rows have `text = NULL` — the body lives in
//  `attributedBody` as an Apple typedstream blob. We port the proven imessage_tools heuristic
//  (find the NSString marker, skip 5 bytes, 1-byte or 0x81+2-byte-LE length, UTF-8) and
//  deliberately do NOT build a full typedstream parser. Sender handles (E.164 phones / emails —
//  chat.db stores no names) resolve through AddressBookNames.
//
//  Key methods: listChats() (picker rows) · eligibleWindows(). Limits per ChatWindowing:
//  90-day floor AND newest-100k cap. Tapbacks (associated_message_type != 0) and system items
//  (item_type != 0) are filtered in SQL — they'd spam every window otherwise. Chats Messages
//  hides are excluded too (chat.is_filtered >= 2: Spam + the iOS SMS-filter category chats).
//  Incrementality: a per-chat high-water mark (max ROWID) per bucket "imessage:<guid>", in CycleStore.
//

import Foundation

struct iMessageSource: Sendable {
    let kind: SourceKind = .imessage

    /// Opt-in filter: only these chat GUIDs are analyzed. nil = every chat (used by the self-test dump).
    let chatGUIDs: Set<String>?

    init(chatGUIDs: Set<String>? = nil) { self.chatGUIDs = chatGUIDs }

    var dbPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db").path
    }

    /// Apple's ns-since-2001 message epoch ↔ Date (Arch §4 epoch cheat-sheet).
    private static func date(fromAppleNS ns: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(ns) / 1e9)
    }
    private static var floorNS: Int64 {
        Int64(ChatWindowing.lookbackFloor.timeIntervalSinceReferenceDate * 1e9)
    }

    /// Messages worth analyzing: real conversation text only — no tapbacks ("Loved …"), no
    /// system items (group renames etc.), and a body present in one of the two columns.
    private static let messageFilter = """
        associated_message_type = 0 AND item_type = 0
        AND ((text IS NOT NULL AND length(text) > 0) OR attributedBody IS NOT NULL)
        """

    // MARK: Chats

    private struct Chat {
        let rowid: Int64
        let guid: String          // the stable opt-in key
        let name: String          // resolved display name (never a blank)
        let isGroup: Bool         // chat.style 43 = group, 45 = DM
        let isSaved: Bool         // DM partner in contacts / explicit display_name; groups always true
    }

    /// Active chats (analyzable messages within the lookback) for the picker — newest first.
    func listChats() throws -> [ChatInfo] {
        let (dbURL, tempDir) = try SQLiteDB.walSafeCopy(of: dbPath)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let reader = try SQLiteReader(path: dbURL.path)
        let chats = try Self.chats(reader)

        var out: [(info: ChatInfo, last: Int64)] = []
        try reader.forEachRow("""
            SELECT cmj.chat_id, COUNT(m.ROWID), MAX(m.date)
            FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE m.date >= \(Self.floorNS) AND \(Self.messageFilter)
            GROUP BY cmj.chat_id
            ORDER BY MAX(m.date) DESC
            """) { r in
            guard let chat = chats[r.int(0)] else { return }
            out.append((ChatInfo(id: chat.guid,
                                 name: chat.name,
                                 isGroup: chat.isGroup,
                                 messageCount: Int(r.int(1)),
                                 lastActive: Self.date(fromAppleNS: r.int(2)),
                                 isSaved: chat.isSaved),
                        r.int(2)))
        }
        return out.map(\.info)
    }

    /// All chats keyed by ROWID, with display names resolved: explicit display_name → contact
    /// name for the DM partner → participant roll-up for unnamed groups → the raw identifier.
    private static func chats(_ reader: SQLiteReader) throws -> [Int64: Chat] {
        let contacts = AddressBookNames.loadMap()

        // Participant handles per chat (needed to name display_name-less groups).
        var members: [Int64: [String]] = [:]
        try reader.forEachRow("""
            SELECT chj.chat_id, h.id FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            """) { r in
            if let handle = r.text(1) { members[r.int(0), default: []].append(handle) }
        }

        // Only chats Messages itself shows: is_filtered 0 (known sender) / 1 (unknown sender).
        // 2 = Spam; 3+ = the iOS SMS-filter category chats (Promotions "(smsfp)", Transactions
        // "(smsft*)") — synced into chat.db by Messages in iCloud but hidden by every Apple UI
        // on the Mac. Without this guard OTP/promo shortcodes flood the picker and the pipeline
        // (iMessage's equivalent of WhatsApp's ZSESSIONTYPE whitelist). is_blackholed is defensive.
        var out: [Int64: Chat] = [:]
        try reader.forEachRow("""
            SELECT ROWID, guid, style, display_name, chat_identifier FROM chat
            WHERE COALESCE(is_filtered, 0) <= 1 AND COALESCE(is_blackholed, 0) = 0
            """) { r in
            guard let guid = r.text(1) else { return }
            let isGroup = r.int(2) == 43
            let explicit = (r.text(3) ?? "").trimmingCharacters(in: .whitespaces)
            let identifier = r.text(4) ?? guid
            let name: String
            var isSaved = true
            if !explicit.isEmpty {
                name = explicit
            } else if isGroup {
                name = ChatWindowing.groupName(of: (members[r.int(0)] ?? []).map { resolved($0, contacts) })
            } else {
                let contact = AddressBookNames.resolve(identifier, in: contacts)
                name = contact ?? identifier
                isSaved = contact != nil
            }
            out[r.int(0)] = Chat(rowid: r.int(0), guid: guid, name: name, isGroup: isGroup, isSaved: isSaved)
        }
        return out
    }

    /// Contact name for a handle, else the raw handle (a phone/email is honest and meaningful —
    /// unlike WhatsApp's LID blobs there's nothing opaque to hide).
    private static func resolved(_ handle: String, _ contacts: [String: String]) -> String {
        AddressBookNames.resolve(handle, in: contacts) ?? handle
    }

    // MARK: Eligible windows (the iterative system's flat, pointer-free view)

    /// Current conversation windows per opted-in chat, for the iterative system (iMessageConnector).
    /// Same DB read + typedstream decode + windowing + caps as `scan`, but with NO
    /// cursor/backfill — IterativeRun's per-chat pointer (highest ROWID) decides new-vs-done. One
    /// bucket per chat ("imessage:<guid>"); each window keyed by its last (max) ROWID; newest-first.
    func eligibleWindows() throws -> [Bucket] {
        let (dbURL, tempDir) = try SQLiteDB.walSafeCopy(of: dbPath)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let reader = try SQLiteReader(path: dbURL.path)

        let chats = try Self.chats(reader)
        let contacts = AddressBookNames.loadMap()
        let analyzedROWIDs = chats.values.filter { chatGUIDs == nil || chatGUIDs!.contains($0.guid) }.map(\.rowid)
        guard !analyzedROWIDs.isEmpty else { return [] }

        var byChat: [Int64: [ChatMessage]] = [:]
        var tsAttempts = 0   // §7.4: rows whose body lives in attributedBody (text == NULL, blob present)
        var tsSuccess = 0    //        of those, how many the typedstream heuristic decoded
        try reader.forEachRow("""
            SELECT m.ROWID, m.date, m.is_from_me, m.text, m.attributedBody, m.chat_id, h.id
            FROM (SELECT message.ROWID, date, is_from_me, text, attributedBody, handle_id, cmj.chat_id
                  FROM message JOIN chat_message_join cmj ON cmj.message_id = message.ROWID
                  WHERE date >= \(Self.floorNS) AND \(Self.messageFilter)
                        AND cmj.chat_id IN (\(analyzedROWIDs.sorted().map(String.init).joined(separator: ",")))
                  ORDER BY date DESC LIMIT \(ChatWindowing.maxMessages)) m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            ORDER BY m.chat_id, m.ROWID
            """) { r in
            guard let chat = chats[r.int(5)] else { return }
            var body = r.text(3)
            if body == nil, let blob = r.blob(4) {
                tsAttempts += 1
                body = Self.typedstreamText(blob)
                if let b = body, !b.trimmingCharacters(in: .whitespaces).isEmpty { tsSuccess += 1 }
            }
            guard let body, !body.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let isFromMe = r.int(2) == 1
            let sender: String
            if isFromMe { sender = "Me" }
            else if chat.isGroup { sender = Self.resolved(r.text(6) ?? "", contacts) }
            else { sender = chat.name }
            byChat[r.int(5), default: []].append(ChatMessage(
                id: r.int(0), date: Self.date(fromAppleNS: r.int(1)), sender: sender,
                isFromMe: isFromMe, text: String(body.prefix(ChatWindowing.maxMessageChars))))
        }

        // §7.4: the Apple-typedstream-change tripwire. A healthy decoder is ~99.97% ([MEASURED]);
        // attachment-only rows push it down but rarely below ~50%, so a collapse under 50% (with a
        // real sample) means Apple changed the format. Threshold is intentionally below the doc's
        // 90% to stay quiet on attachment-heavy accounts while still catching the ~0% break.
        if tsAttempts >= 50 {
            let pct = tsSuccess * 100 / tsAttempts
            if pct < 50 {
                CrashReporting.captureEvent("imessage.decode.degraded", level: .error,
                    tags: ["source": "imessage"],
                    extra: ["attempts": String(tsAttempts), "success_pct": String(pct)],
                    fingerprint: ["imessage", "decode_degraded"])
            }
        }

        let buckets: [Bucket] = byChat.compactMap { (chatROWID, msgs) -> Bucket? in
            guard let chat = chats[chatROWID] else { return nil }
            let items = ChatWindowing.windows(of: msgs).filter { !$0.isEmpty }.map { win -> (key: ItemKey, item: Candidate) in
                let cand = Candidate(
                    id: "imessage:c\(chatROWID):\(win.first!.id)-\(win.last!.id)", kind: .imessage,
                    cursorKey: "imessage:\(chat.guid)", cursorValue: "",   // vestigial — core keys on ItemKey
                    itemDate: win.last!.date,
                    metadata: [
                        "folder": chat.name, "name": chat.name,
                        "displayPath": "iMessage · \(chat.name)",
                        "isGroup": chat.isGroup ? "1" : "0", "msgCount": "\(win.count)",
                        "windowText": ChatWindowing.format(chatName: chat.name, isGroup: chat.isGroup, messages: win),
                    ])
                return (key: ItemKey(rowID: win.last!.id), item: cand)
            }
            return items.isEmpty ? nil : Bucket(key: "imessage:\(chat.guid)", items: items.sorted { $0.key > $1.key })
        }

        SourceHealth.checkListingCollapse(source: "imessage", bucketKey: "imessage",
                                          count: buckets.reduce(0) { $0 + $1.items.count })
        return buckets
    }

    // MARK: The typedstream heuristic — deliberately NOT a full parser (Arch §4)

    /// Extract the message body from an `attributedBody` typedstream blob: find the NSString /
    /// NSMutableString class marker, skip the 5-byte preamble, read the length (one byte, or
    /// 0x81 + two bytes little-endian for long messages), decode UTF-8. nil = not decodable
    /// (attachment-only rows land here; the caller skips them).
    static func typedstreamText(_ blob: Data) -> String? {
        let marker = blob.range(of: Data("NSString".utf8))
            ?? blob.range(of: Data("NSMutableString".utf8))
        guard let marker else { return nil }

        var i = marker.upperBound + 5                      // the 5-byte preamble after the class name
        guard i < blob.endIndex else { return nil }
        var length = Int(blob[i])
        if blob[i] == 0x81 {
            guard i + 2 < blob.endIndex else { return nil }
            length = Int(blob[i + 1]) | (Int(blob[i + 2]) << 8)   // 2-byte little-endian
            i += 3
        } else {
            i += 1
        }
        guard length > 0, i + length <= blob.endIndex else { return nil }
        return String(data: blob[i ..< (i + length)], encoding: .utf8)
    }
}
