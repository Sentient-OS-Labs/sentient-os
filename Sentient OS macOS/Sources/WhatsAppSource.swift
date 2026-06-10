//
//  WhatsAppSource.swift
//  Sentient OS macOS
//
//  DataSource over WhatsApp's local ChatStorage.sqlite (Arch §3.1, [MEASURED]). It's unencrypted
//  plaintext in WAL mode → we WAL-safe COPY → EXTRACT → DELETE immediately (privacy: a plaintext
//  copy of the whole chat history never lingers).
//
//  THE UNIT OF ANALYSIS IS A CONVERSATION WINDOW, not a message. A single message is meaningless
//  alone ("ok", "haha", "5pm?"); meaning lives in the conversation. So we batch a run of messages
//  from ONE chat, in time order, up to the model's context budget (~8k-token windows), and each
//  window flows through the SAME pipeline as a file: one window = one Artifact = one bouncer
//  verdict (Triage's chat-flavored prompt). The vast majority of chat is ephemeral → junk; the
//  rare keeper → one summary. The model sees the chat name, DM-vs-group, and per-message sender.
//
//  Requires Full Disk Access (Permissions.swift). v1 scope: backfills the last `lookbackDays`;
//  dedup is ledger-based via stable window ids (like Files). A Z_PK cursor, hold-back of the
//  active tail, and slide-proof window anchoring are a Phase-4 (scheduler) hardening — see Arch §3.1.
//

import Foundation

struct WhatsAppSource: DataSource, Sendable {
    let kind: SourceKind = .whatsapp

    /// Opt-in filter: only these chat JIDs are analyzed. nil = every chat (used by the self-test dump).
    let chatJIDs: Set<String>?

    init(chatJIDs: Set<String>? = nil) { self.chatJIDs = chatJIDs }

    /// A chat as shown in the opt-in picker — active within the lookback, with how busy it's been.
    struct ChatInfo: Sendable, Identifiable {
        let jid: String
        let name: String
        let isGroup: Bool
        let messageCount: Int
        let lastActive: Date
        var id: String { jid }
    }

    /// Active chats (text messages within the lookback) for the picker — newest first, with counts.
    /// Its own WAL-safe copy → query → delete.
    func listChats() throws -> [ChatInfo] {
        let (dbURL, tempDir) = try SQLiteDB.walSafeCopy(of: dbPath)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let reader = try SQLiteReader(path: dbURL.path)

        let floor = Date().addingTimeInterval(-Double(Self.lookbackDays) * 86_400).timeIntervalSinceReferenceDate
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
            out.append(ChatInfo(jid: jid,
                                name: r.text(1) ?? Self.handle(jid),
                                isGroup: jid.hasSuffix("@g.us"),
                                messageCount: Int(r.int(2)),
                                lastActive: Date(timeIntervalSinceReferenceDate: r.double(3))))
        }
        return out
    }

    // MARK: Tunables
    static let lookbackDays = 31
    // We size a window by its UTF-8 BYTE count, NOT chars (and NOT a chars→tokens guess). A
    // byte-level tokenizer emits at most ONE token per byte, so bytes are a HARD upper bound on
    // tokens — a window can never overflow the model's token budget, even for emoji / CJK /
    // multilingual chats where characters wildly under-count tokens. (That mismatch is what made
    // the model "go quiet": a 26k-char window tokenized to 18.6k tokens, >2× the 8,192 budget.)
    // ~5,000 bytes ⇒ ≤ ~5k tokens, leaving comfortable room for the prompt + reply inside 8,192.
    static let maxWindowBytes = 5_000
    static let maxMessageChars = 1_000     // cap a single pasted-essay message so it can't dominate a window

    var dbPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite")
            .path
    }

    // MARK: Decoded rows
    private struct Msg {
        let pk: Int64
        let date: Date
        let isFromMe: Bool
        let text: String
        let pushName: String?     // ZWAMESSAGE.ZPUSHNAME — the sender's display name, right on the message
        let memberName: String?   // ZWAGROUPMEMBER contact/first name (group senders without a push-name)
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

        // Text messages within the lookback, grouped per chat, oldest → newest.
        let floor = Date().addingTimeInterval(-Double(Self.lookbackDays) * 86_400).timeIntervalSinceReferenceDate
        var byChat: [Int64: [Msg]] = [:]
        // LEFT JOIN the group-member row (indexed on Z_PK → near-free) so senders without a
        // push-name resolve to their saved contact name instead of a raw JID/LID.
        try reader.forEachRow("""
            SELECT m.Z_PK, m.ZMESSAGEDATE, m.ZISFROMME, m.ZTEXT, m.ZPUSHNAME, m.ZCHATSESSION, gm.ZCONTACTNAME, gm.ZFIRSTNAME
            FROM ZWAMESSAGE m
            LEFT JOIN ZWAGROUPMEMBER gm ON m.ZGROUPMEMBER = gm.Z_PK
            WHERE m.ZTEXT IS NOT NULL AND length(m.ZTEXT) > 0 AND m.ZMESSAGEDATE >= \(floor)
            ORDER BY m.ZCHATSESSION, m.Z_PK
            """) { r in
            byChat[r.int(5), default: []].append(Msg(
                pk: r.int(0),
                date: Date(timeIntervalSinceReferenceDate: r.double(1)),
                isFromMe: r.int(2) == 1,
                text: String((r.text(3) ?? "").prefix(Self.maxMessageChars)),
                pushName: r.text(4),
                memberName: r.text(6) ?? r.text(7)))   // ZCONTACTNAME ?? ZFIRSTNAME
        }

        // Window each chat to the char budget; one window = one Artifact.
        var built: [(candidate: Candidate, last: Date)] = []
        for (chatPK, msgs) in byChat {
            guard let chat = chats[chatPK] else { continue }
            if let only = chatJIDs, !only.contains(chat.jid) { continue }   // opt-in filter
            for win in Self.windows(of: msgs) where !win.isEmpty {
                let meta: [String: String] = [
                    "folder": chat.name,                         // per-chat tag → folder pills in the viewer
                    "name": chat.name,
                    "displayPath": "WhatsApp · \(chat.name)",
                    "isGroup": chat.isGroup ? "1" : "0",         // → group vs DM bouncer prompt
                    "windowText": Self.format(chat: chat, messages: win),
                ]
                let id = "whatsapp:c\(chatPK):\(win.first!.pk)-\(win.last!.pk)"
                built.append((Candidate(id: id, kind: .whatsapp, signature: "\(win.count)", metadata: meta),
                              win.last!.date))
            }
        }
        return built.sorted { $0.last > $1.last }.map(\.candidate)   // newest conversations first
    }

    func load(_ candidate: Candidate) throws -> Artifact {
        Artifact(candidate: candidate, text: candidate.metadata["windowText"] ?? "")
    }

    // MARK: Windowing — per chat, time-ordered, greedy up to the char budget

    private static func windows(of msgs: [Msg]) -> [[Msg]] {
        var out: [[Msg]] = []
        var cur: [Msg] = []
        var bytes = 0
        for m in msgs {
            let b = msgBytes(m)
            if !cur.isEmpty && bytes + b > maxWindowBytes { out.append(cur); cur = []; bytes = 0 }
            cur.append(m); bytes += b
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// UTF-8 byte size of a formatted line — the upper bound on its token count.
    private static func msgBytes(_ m: Msg) -> Int { m.text.utf8.count + 28 }   // + date/sender label overhead

    // MARK: Formatting — frame the window for the model

    private static func format(chat: Chat, messages: [Msg]) -> String {
        let mine = messages.lazy.filter(\.isFromMe).count
        var out = "Chat: \"\(chat.name)\" (\(chat.isGroup ? "group" : "direct message"))\n"
        out += "In this slice, you (\"Me\") sent \(mine) of \(messages.count) messages.\n"
        for m in messages { out += "[\(dateString(m.date))] \(sender(m, chat: chat)): \(m.text)\n" }
        return out
    }

    private static func sender(_ m: Msg, chat: Chat) -> String {
        if m.isFromMe { return "Me" }
        // Group: push-name → saved contact name → a clean generic. Each candidate is validated, because
        // WhatsApp stores an opaque LID blob as the "name" for some privacy-mode members — that must
        // NEVER reach a summary.
        if chat.isGroup { return cleanName(m.pushName) ?? cleanName(m.memberName) ?? "a group member" }
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

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f
    }()
    private static func dateString(_ d: Date) -> String { df.string(from: d) }
}
