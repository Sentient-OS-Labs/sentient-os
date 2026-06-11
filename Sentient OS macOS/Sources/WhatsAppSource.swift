//
//  WhatsAppSource.swift
//  Sentient OS macOS
//
//  DataSource over WhatsApp's local ChatStorage.sqlite (Arch §3.1, [MEASURED]). It's unencrypted
//  plaintext in WAL mode → we WAL-safe COPY → EXTRACT → DELETE immediately (privacy: a plaintext
//  copy of the whole chat history never lingers).
//
//  THE UNIT OF ANALYSIS IS A CONVERSATION WINDOW, not a message (see ChatWindowing.swift — the
//  windowing/formatting/limits shared with iMessage live there). Each window flows through the
//  SAME pipeline as a file: one window = one Artifact = one bouncer verdict (Triage's
//  chat-flavored prompt). The model sees the chat name, DM-vs-group, and per-message sender.
//
//  Requires Full Disk Access (Permissions.swift). v1 scope: backfills the lookback window;
//  dedup is ledger-based via stable window ids (like Files). A Z_PK cursor, hold-back of the
//  active tail, and slide-proof window anchoring are a Phase-4 (scheduler) hardening — see Arch §3.1.
//

import Foundation

struct WhatsAppSource: DataSource, Sendable {
    let kind: SourceKind = .whatsapp

    /// Opt-in filter: only these chat JIDs are analyzed. nil = every chat (used by the self-test dump).
    let chatJIDs: Set<String>?

    init(chatJIDs: Set<String>? = nil) { self.chatJIDs = chatJIDs }

    /// Active chats (text messages within the lookback) for the picker — newest first, with counts.
    /// Its own WAL-safe copy → query → delete.
    func listChats() throws -> [ChatInfo] {
        let (dbURL, tempDir) = try SQLiteDB.walSafeCopy(of: dbPath)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let reader = try SQLiteReader(path: dbURL.path)

        let floor = ChatWindowing.lookbackFloor.timeIntervalSinceReferenceDate
        var out: [ChatInfo] = []
        try reader.forEachRow("""
            SELECT s.ZCONTACTJID, s.ZPARTNERNAME, COUNT(m.Z_PK), MAX(m.ZMESSAGEDATE)
            FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON m.ZCHATSESSION = s.Z_PK
            WHERE m.ZTEXT IS NOT NULL AND length(m.ZTEXT) > 0 AND m.ZMESSAGEDATE >= \(floor)
            GROUP BY s.Z_PK
            ORDER BY MAX(m.ZMESSAGEDATE) DESC
            """) { r in
            let jid = r.text(0) ?? ""
            guard !jid.isEmpty else { return }
            out.append(ChatInfo(id: jid,
                                name: r.text(1) ?? Self.handle(jid),
                                isGroup: jid.hasSuffix("@g.us"),
                                messageCount: Int(r.int(2)),
                                lastActive: Date(timeIntervalSinceReferenceDate: r.double(3))))
        }
        return out
    }

    var dbPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite")
            .path
    }

    private struct Chat {
        let pk: Int64
        let jid: String           // ZCONTACTJID — the stable opt-in key
        let name: String          // ZPARTNERNAME (contact name for DMs, group name for groups)
        let isGroup: Bool         // ZCONTACTJID ends "@g.us"
    }

    // MARK: Scan — copy → query → window → delete

    func scan(since cursor: String?) throws -> [Candidate] {
        let (dbURL, tempDir) = try SQLiteDB.walSafeCopy(of: dbPath)
        defer { try? FileManager.default.removeItem(at: tempDir) }   // delete the plaintext copy immediately
        let reader = try SQLiteReader(path: dbURL.path)

        // Chat sessions → name + DM/group.
        var chats: [Int64: Chat] = [:]
        try reader.forEachRow("SELECT Z_PK, ZPARTNERNAME, ZCONTACTJID FROM ZWACHATSESSION") { r in
            let jid = r.text(2) ?? ""
            let name = r.text(1) ?? (jid.isEmpty ? "Unknown chat" : Self.handle(jid))
            chats[r.int(0)] = Chat(pk: r.int(0), jid: jid, name: name, isGroup: jid.hasSuffix("@g.us"))
        }

        // Text messages within the limits (90-day floor AND newest-200k cap — the inner
        // newest-first LIMIT applies the cap across ALL chats; the outer ORDER restores
        // per-chat ascending iteration), oldest → newest per chat.
        let floor = ChatWindowing.lookbackFloor.timeIntervalSinceReferenceDate
        var byChat: [Int64: [ChatMessage]] = [:]
        // LEFT JOIN the group-member row (indexed on Z_PK → near-free) so senders without a
        // push-name resolve to their saved contact name instead of a raw JID/LID.
        try reader.forEachRow("""
            SELECT m.Z_PK, m.ZMESSAGEDATE, m.ZISFROMME, m.ZTEXT, m.ZPUSHNAME, m.ZCHATSESSION, gm.ZCONTACTNAME, gm.ZFIRSTNAME
            FROM (SELECT * FROM ZWAMESSAGE
                  WHERE ZTEXT IS NOT NULL AND length(ZTEXT) > 0 AND ZMESSAGEDATE >= \(floor)
                  ORDER BY ZMESSAGEDATE DESC LIMIT \(ChatWindowing.maxMessages)) m
            LEFT JOIN ZWAGROUPMEMBER gm ON m.ZGROUPMEMBER = gm.Z_PK
            ORDER BY m.ZCHATSESSION, m.Z_PK
            """) { r in
            guard let chat = chats[r.int(5)] else { return }
            if let only = chatJIDs, !only.contains(chat.jid) { return }   // opt-in filter
            let isFromMe = r.int(2) == 1
            byChat[r.int(5), default: []].append(ChatMessage(
                id: r.int(0),
                date: Date(timeIntervalSinceReferenceDate: r.double(1)),
                sender: isFromMe ? "Me" : Self.sender(pushName: r.text(4),
                                                      memberName: r.text(6) ?? r.text(7),   // ZCONTACTNAME ?? ZFIRSTNAME
                                                      chat: chat),
                isFromMe: isFromMe,
                text: String((r.text(3) ?? "").prefix(ChatWindowing.maxMessageChars))))
        }

        // Window each chat to the byte budget; one window = one Artifact.
        var built: [(candidate: Candidate, last: Date)] = []
        for (chatPK, msgs) in byChat {
            guard let chat = chats[chatPK] else { continue }
            for win in ChatWindowing.windows(of: msgs) where !win.isEmpty {
                let meta: [String: String] = [
                    "folder": chat.name,                         // per-chat tag → folder pills in the viewer
                    "name": chat.name,
                    "displayPath": "WhatsApp · \(chat.name)",
                    "isGroup": chat.isGroup ? "1" : "0",         // → group vs DM bouncer prompt
                    "windowText": ChatWindowing.format(chatName: chat.name, isGroup: chat.isGroup, messages: win),
                ]
                let id = "whatsapp:c\(chatPK):\(win.first!.id)-\(win.last!.id)"
                built.append((Candidate(id: id, kind: .whatsapp, signature: "\(win.count)", metadata: meta),
                              win.last!.date))
            }
        }
        return built.sorted { $0.last > $1.last }.map(\.candidate)   // newest conversations first
    }

    func load(_ candidate: Candidate) throws -> Artifact {
        Artifact(candidate: candidate, text: candidate.metadata["windowText"] ?? "")
    }

    // MARK: Sender labels

    private static func sender(pushName: String?, memberName: String?, chat: Chat) -> String {
        // Group: push-name → saved contact name → a clean generic. Each candidate is validated, because
        // WhatsApp stores an opaque LID blob as the "name" for some privacy-mode members — that must
        // NEVER reach a summary.
        if chat.isGroup { return cleanName(pushName) ?? cleanName(memberName) ?? "a group member" }
        return chat.name   // DM: the other party is the chat partner
    }

    /// A real display name, or nil if it's actually an opaque WhatsApp JID/LID blob. Real names are
    /// short or contain spaces; LIDs are long, unbroken, and contain '/' (e.g. "CIW9/tAGIA…").
    private static func cleanName(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.contains("/") { return nil }                    // LID/JID blobs contain '/'
        if s.count > 24 && !s.contains(" ") { return nil }   // long unbroken token → not a real name
        return s
    }

    /// Phone/handle from a JID like "14155551234@s.whatsapp.net" → "14155551234" (chat-name fallback only).
    private static func handle(_ jid: String) -> String { String(jid.prefix { $0 != "@" }) }
}
