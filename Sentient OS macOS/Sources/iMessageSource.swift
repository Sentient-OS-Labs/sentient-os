//
//  iMessageSource.swift
//  Sentient OS macOS
//
//  DataSource over the Mac's iMessage store, ~/Library/Messages/chat.db (Arch §4, [MEASURED]:
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
//  Key methods: listChats() (picker rows) · scan(since:) · load(_:). Limits per ChatWindowing:
//  90-day floor AND newest-100k cap. Tapbacks (associated_message_type != 0) and system items
//  (item_type != 0) are filtered in SQL — they'd spam every window otherwise. Incrementality:
//  a per-chat ROWID pointer ("imessage:<guid>" in SourceCursor) + a one-hour tail hold-back.
//

import Foundation

struct iMessageSource: DataSource, Sendable {
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
                                 lastActive: Self.date(fromAppleNS: r.int(2))),
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

        var out: [Int64: Chat] = [:]
        try reader.forEachRow("SELECT ROWID, guid, style, display_name, chat_identifier FROM chat") { r in
            guard let guid = r.text(1) else { return }
            let isGroup = r.int(2) == 43
            let explicit = (r.text(3) ?? "").trimmingCharacters(in: .whitespaces)
            let identifier = r.text(4) ?? guid
            let name: String
            if !explicit.isEmpty {
                name = explicit
            } else if isGroup {
                name = ChatWindowing.groupName(of: (members[r.int(0)] ?? []).map { resolved($0, contacts) })
            } else {
                name = resolved(identifier, contacts)
            }
            out[r.int(0)] = Chat(rowid: r.int(0), guid: guid, name: name, isGroup: isGroup)
        }
        return out
    }

    /// Contact name for a handle, else the raw handle (a phone/email is honest and meaningful —
    /// unlike WhatsApp's LID blobs there's nothing opaque to hide).
    private static func resolved(_ handle: String, _ contacts: [String: String]) -> String {
        AddressBookNames.resolve(handle, in: contacts) ?? handle
    }

    // MARK: Scan — copy → query → decode → window → delete

    /// Pointer (June 11 rewrite + June 12 backfill): ONE cursor per opted-in chat — key
    /// "imessage:<guid>", value = the highest consumed `ROWID` (or a BackfillCursor while the
    /// chat's first run is in flight) — plus a one-hour tail hold-back. Per-chat (not one
    /// global ROWID pointer) because chats interleave in ROWID space; see WhatsAppSource.scan
    /// for the full rationale. Ordering: incremental windows ascend per chat; a chat's first
    /// run digs newest-window-first, with every chat's NEW windows emitted before any dig.
    func scan(since cursors: [String: String]) throws -> ScanResult {
        let (dbURL, tempDir) = try SQLiteDB.walSafeCopy(of: dbPath)
        defer { try? FileManager.default.removeItem(at: tempDir) }   // delete the plaintext copy immediately
        let reader = try SQLiteReader(path: dbURL.path)

        let chats = try Self.chats(reader)
        let contacts = AddressBookNames.loadMap()

        // Opt-in filtering happens INSIDE the capped query: the newest-`maxMessages` budget
        // must be spent on the chats we'll actually analyze, not eaten by busy non-opted ones.
        let analyzedROWIDs = chats.values
            .filter { chatGUIDs == nil || chatGUIDs!.contains($0.guid) }
            .map(\.rowid)
        guard !analyzedROWIDs.isEmpty else { return ScanResult(candidates: []) }

        // Each analyzed chat's pointer state (no row = backfill start = everything qualifies).
        var states: [Int64: ChatCursorState] = [:]
        for chat in chats.values {
            states[chat.rowid] = ChatCursorState.decode(cursors["imessage:\(chat.guid)"])
        }
        let tailFloorNS = Int64(Date().addingTimeInterval(-sourceFreshnessHoldBack)
            .timeIntervalSinceReferenceDate * 1e9)

        // Messages within the limits (90-day floor AND newest-`maxMessages` cap over the
        // analyzed chats; the outer ORDER restores per-chat ascending iteration), decoded
        // text ?? typedstream, grouped per chat.
        var byChat: [Int64: [ChatMessage]] = [:]
        var fetched = 0   // raw rows the capped query returned (cap hit = a dig may be starved)
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
            fetched += 1
            guard let chat = chats[r.int(5)] else { return }
            guard states[chat.rowid]?.wants(r.int(0)) ?? true else { return }   // already consumed
            guard r.int(1) <= tailFloorNS else { return }                       // tail hold-back

            let body = r.text(3) ?? r.blob(4).flatMap(Self.typedstreamText)
            guard let body, !body.trimmingCharacters(in: .whitespaces).isEmpty else { return }

            let isFromMe = r.int(2) == 1
            let sender: String
            if isFromMe { sender = "Me" }
            else if chat.isGroup { sender = Self.resolved(r.text(6) ?? "", contacts) }
            else { sender = chat.name }   // DM: the other party is the chat partner

            byChat[r.int(5), default: []].append(ChatMessage(
                id: r.int(0),
                date: Self.date(fromAppleNS: r.int(1)),
                sender: sender,
                isFromMe: isFromMe,
                text: String(body.prefix(ChatWindowing.maxMessageChars))))
        }

        // Window each chat to the byte budget; one window = one Artifact. The shared
        // ChatWindowing.chatCandidates applies the chat's pointer state (incremental ascend /
        // backfill descent / completion).
        let mayBeClipped = fetched >= ChatWindowing.maxMessages
        var perChat: [(lastActive: Date, now: [Candidate], dig: [Candidate])] = []
        var completions: [String: String] = [:]
        for (chatROWID, msgs) in byChat {
            guard let chat = chats[chatROWID] else { continue }
            let (now, dig, completion) = ChatWindowing.chatCandidates(
                msgs: msgs, state: states[chatROWID] ?? .backfillStart, mayBeClipped: mayBeClipped
            ) { win, cursorValue in
                Candidate(id: "imessage:c\(chatROWID):\(win.first!.id)-\(win.last!.id)",
                          kind: .imessage,
                          cursorKey: "imessage:\(chat.guid)",
                          cursorValue: cursorValue,
                          itemDate: win.last!.date,
                          metadata: [
                              "folder": chat.name,                 // per-chat tag → folder pills in the viewer
                              "name": chat.name,
                              "displayPath": "iMessage · \(chat.name)",
                              "isGroup": chat.isGroup ? "1" : "0", // → group vs DM bouncer prompt
                              "msgCount": "\(win.count)",
                              "windowText": ChatWindowing.format(chatName: chat.name, isGroup: chat.isGroup, messages: win),
                          ])
            }
            if let completion { completions["imessage:\(chat.guid)"] = completion }
            if !(now.isEmpty && dig.isEmpty) { perChat.append((msgs.last!.date, now, dig)) }
        }
        // A backfilling chat with NO fetched messages has nothing above hi and nothing left
        // below lo (within the floor) — its backfill is over. Never collapse on a clipped scan.
        if !mayBeClipped {
            for chat in chats.values where chatGUIDs?.contains(chat.guid) ?? true {
                if case .backfill(let bf, _, _) = states[chat.rowid] ?? .backfillStart,
                   byChat[chat.rowid] == nil {
                    completions["imessage:\(chat.guid)"] = bf.hi
                }
            }
        }
        // Every chat's NEW windows first (what's happening now), then the backfill digs —
        // active chats first within each group.
        let ordered = perChat.sorted { $0.lastActive > $1.lastActive }
        return ScanResult(candidates: ordered.flatMap(\.now) + ordered.flatMap(\.dig),
                          completions: completions)
    }

    func load(_ candidate: Candidate) throws -> Artifact {
        Artifact(candidate: candidate, text: candidate.metadata["windowText"] ?? "")
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
