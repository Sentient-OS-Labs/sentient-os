//
//  WhatsAppSource.swift
//  Sentient OS macOS
//
//  Reads WhatsApp's local ChatStorage.sqlite (Arch §3.1, [MEASURED]). It's unencrypted
//  plaintext in WAL mode → we WAL-safe COPY → EXTRACT → DELETE immediately (privacy: a plaintext
//  copy of the whole chat history never lingers).
//
//  THE UNIT OF ANALYSIS IS A CONVERSATION WINDOW, not a message (see ChatWindowing.swift — the
//  windowing/formatting/limits shared with iMessage live there). Each window flows through the
//  SAME pipeline as a file: one window = one Artifact = one bouncer verdict (Triage's
//  chat-flavored prompt). The model sees the chat name, DM-vs-group, and per-message sender.
//
//  Requires Full Disk Access (Permissions.swift). Incrementality: a per-chat high-water mark
//  (max message Z_PK) per bucket "whatsapp:<jid>", held in CycleStore and advanced by IterativeRun.
//  Doc: Documentation/WhatsApp Source (ChatStorage).md.
//

import Foundation
import AppKit   // NSWorkspace — install probe (LaunchServices isn't UI-actor-isolated; safe off-main)

struct WhatsAppSource: Sendable {
    let kind: SourceKind = .whatsapp

    /// Opt-in filter: only these chat JIDs are analyzed. nil = every chat (used by the self-test dump).
    let chatJIDs: Set<String>?

    init(chatJIDs: Set<String>? = nil) { self.chatJIDs = chatJIDs }

    /// Sessions worth analyzing — a WHITELIST of DMs (0) and real groups (1), so broadcast
    /// lists (2), status (3), community homes (4), and whatever WhatsApp invents next are
    /// excluded automatically. The second clause removes community ANNOUNCEMENT channels:
    /// they're stored as ordinary type-1 groups, but always wear the community's exact
    /// ZPARTNERNAME — a name-twin of a type-4 session ([MEASURED]: the only marker in this
    /// schema; no parent-JID column exists, JID prefixes proved unreliable). Community
    /// sub-groups are indistinguishable from normal groups and deliberately stay (they're
    /// real conversations; the per-chat opt-in gates them anyway).
    /// ⚠️ The IS NOT NULL inside the subquery is load-bearing: one NULL there and SQL's
    /// NOT IN semantics silently hide EVERY group.
    /// (The row-side IS NOT NULL matters too: an unnamed group's NULL ZPARTNERNAME would make
    /// the whole NOT(...) evaluate NULL and silently hide the group.)
    private static let sessionFilter = """
        s.ZSESSIONTYPE IN (0, 1)
            AND NOT (s.ZSESSIONTYPE = 1 AND s.ZPARTNERNAME IS NOT NULL AND s.ZPARTNERNAME IN
                (SELECT ZPARTNERNAME FROM ZWACHATSESSION
                 WHERE ZSESSIONTYPE = 4 AND ZPARTNERNAME IS NOT NULL))
        """

    /// Active group members with usable names, per chat session — names unnamed groups the way
    /// WhatsApp itself does ("Aditya, Ondrej & 2 others"). ZISACTIVE excludes members who LEFT,
    /// so a shrunk group is named after who's actually in it now. Saved contact names are
    /// preferred, but [MEASURED] they're often empty STRINGS (not NULL) — the self-set profile
    /// push-name (ZWAPROFILEPUSHNAME, by member JID) is the reliable fallback, and it's what
    /// WhatsApp's own chat list shows. Two flat queries + a dict (no SQL join): no dependence
    /// on an index existing, and duplicate ZJID rows can't duplicate members. Non-throwing by
    /// design — names are a nicety; a schema oddity must degrade to "Group chat", never kill
    /// the connector.
    private static func activeMemberNames(_ reader: SQLiteReader) -> [Int64: [String]] {
        var push: [String: String] = [:]
        try? reader.forEachRow("SELECT ZJID, ZPUSHNAME FROM ZWAPROFILEPUSHNAME") { r in
            if let jid = r.text(0), let name = r.text(1) { push[jid] = name }
        }
        var out: [Int64: [String]] = [:]
        try? reader.forEachRow("""
            SELECT ZCHATSESSION, ZCONTACTNAME, ZFIRSTNAME, ZMEMBERJID
            FROM ZWAGROUPMEMBER WHERE ZISACTIVE = 1
            """) { r in
            let pushName = r.text(3).flatMap { push[$0] }
            if let n = cleanName(r.text(1)) ?? cleanName(r.text(2)) ?? cleanName(pushName) {
                out[r.int(0), default: []].append(n)
            }
        }
        return out
    }

    /// Active chats (text messages within the lookback) for the picker — newest first, with counts.
    /// Its own WAL-safe copy → query → delete.
    func listChats() throws -> [ChatInfo] {
        let (dbURL, tempDir) = try SQLiteDB.walSafeCopy(of: dbPath)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let reader = try SQLiteReader(path: dbURL.path)

        let floor = ChatWindowing.lookbackFloor.timeIntervalSinceReferenceDate
        let members = Self.activeMemberNames(reader)
        var out: [ChatInfo] = []
        try reader.forEachRow("""
            SELECT s.ZCONTACTJID, s.ZPARTNERNAME, COUNT(m.Z_PK), MAX(m.ZMESSAGEDATE), s.Z_PK
            FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON m.ZCHATSESSION = s.Z_PK
            WHERE m.ZTEXT IS NOT NULL AND length(m.ZTEXT) > 0 AND m.ZMESSAGEDATE >= \(floor)
              AND \(Self.sessionFilter)
            GROUP BY s.Z_PK
            ORDER BY MAX(m.ZMESSAGEDATE) DESC
            """) { r in
            let jid = r.text(0) ?? ""
            guard !jid.isEmpty else { return }
            out.append(ChatInfo(id: jid,
                                name: Self.displayName(r.text(1), jid: jid, members: members[r.int(4)]),
                                isGroup: jid.hasSuffix("@g.us"),
                                messageCount: Int(r.int(2)),
                                lastActive: Date(timeIntervalSinceReferenceDate: r.double(3))))
        }
        return out
    }

    /// Is the WhatsApp desktop app installed on this Mac? The connections UI hides WhatsApp
    /// entirely when it isn't — there's nothing to read, nothing to offer. A LaunchServices
    /// lookup (no Full Disk Access needed), keyed on the same bundle our group-container path
    /// assumes, so "installed" and "readable" never disagree.
    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") != nil
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

    // MARK: Eligible windows (the iterative system's flat, pointer-free view)

    /// Current conversation windows per opted-in chat, for the iterative system (WhatsAppConnector).
    /// WAL-safe read → windowing → caps (100k / 90-day). No cursor, no backfill — IterativeRun's
    /// per-chat high-water mark (highest message Z_PK) decides new-vs-done. One bucket per chat
    /// ("whatsapp:<jid>"); each window keyed by its last (max) Z_PK; newest-first.
    func eligibleWindows() throws -> [Bucket] {
        let (dbURL, tempDir) = try SQLiteDB.walSafeCopy(of: dbPath)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let reader = try SQLiteReader(path: dbURL.path)

        let members = Self.activeMemberNames(reader)
        var chats: [Int64: Chat] = [:]
        try reader.forEachRow("SELECT s.Z_PK, s.ZPARTNERNAME, s.ZCONTACTJID FROM ZWACHATSESSION s WHERE \(Self.sessionFilter)") { r in
            let jid = r.text(2) ?? ""
            chats[r.int(0)] = Chat(pk: r.int(0), jid: jid,
                                   name: Self.displayName(r.text(1), jid: jid, members: members[r.int(0)]),
                                   isGroup: jid.hasSuffix("@g.us"))
        }

        // §7.3: WhatsApp is installed but the session query returned zero rows — the classic
        // NULL-guard landmine (one NULL in the sessionFilter subquery hides EVERY group). A schema
        // change would trip this on day one.
        if Self.isInstalled, chats.isEmpty {
            CrashReporting.captureEvent("whatsapp.zero_sessions_despite_install", level: .error,
                tags: ["source": "whatsapp"], fingerprint: ["whatsapp", "zero_sessions"])
        }

        let analyzedPKs = chats.values.filter { chatJIDs == nil || chatJIDs!.contains($0.jid) }.map(\.pk)
        guard !analyzedPKs.isEmpty else {
            // Opted into specific chats but none matched a live session — filter/schema drift, not
            // the ordinary "opted into nothing" (which leaves chatJIDs empty and is silent).
            if let jids = chatJIDs, !jids.isEmpty, !chats.isEmpty {
                CrashReporting.captureEvent("whatsapp.no_opted_in_chats", level: .warning,
                    tags: ["source": "whatsapp"], fingerprint: ["whatsapp", "no_opted_in"])
            }
            return []
        }

        let floor = ChatWindowing.lookbackFloor.timeIntervalSinceReferenceDate
        var byChat: [Int64: [ChatMessage]] = [:]
        try reader.forEachRow("""
            SELECT m.Z_PK, m.ZMESSAGEDATE, m.ZISFROMME, m.ZTEXT, m.ZPUSHNAME, m.ZCHATSESSION, gm.ZCONTACTNAME, gm.ZFIRSTNAME
            FROM (SELECT * FROM ZWAMESSAGE
                  WHERE ZTEXT IS NOT NULL AND length(ZTEXT) > 0 AND ZMESSAGEDATE >= \(floor)
                        AND ZCHATSESSION IN (\(analyzedPKs.sorted().map(String.init).joined(separator: ",")))
                  ORDER BY ZMESSAGEDATE DESC LIMIT \(ChatWindowing.maxMessages)) m
            LEFT JOIN ZWAGROUPMEMBER gm ON m.ZGROUPMEMBER = gm.Z_PK
            ORDER BY m.ZCHATSESSION, m.Z_PK
            """) { r in
            guard let chat = chats[r.int(5)] else { return }
            let isFromMe = r.int(2) == 1
            byChat[r.int(5), default: []].append(ChatMessage(
                id: r.int(0),
                date: Date(timeIntervalSinceReferenceDate: r.double(1)),
                sender: isFromMe ? "Me" : Self.sender(pushName: r.text(4), memberName: r.text(6) ?? r.text(7), chat: chat),
                isFromMe: isFromMe,
                text: String((r.text(3) ?? "").prefix(ChatWindowing.maxMessageChars))))
        }

        let buckets: [Bucket] = byChat.compactMap { (chatPK, msgs) -> Bucket? in
            guard let chat = chats[chatPK] else { return nil }
            let items = ChatWindowing.windows(of: msgs).filter { !$0.isEmpty }.map { win -> (key: ItemKey, item: Candidate) in
                let cand = Candidate(
                    id: "whatsapp:c\(chatPK):\(win.first!.id)-\(win.last!.id)", kind: .whatsapp,
                    cursorKey: "whatsapp:\(chat.jid)", cursorValue: "",   // vestigial — core keys on ItemKey
                    itemDate: win.last!.date,
                    metadata: [
                        "folder": chat.name, "name": chat.name,
                        "displayPath": "WhatsApp · \(chat.name)",
                        "isGroup": chat.isGroup ? "1" : "0", "msgCount": "\(win.count)",
                        "windowText": ChatWindowing.format(chatName: chat.name, isGroup: chat.isGroup, messages: win),
                    ])
                return (key: ItemKey(rowID: win.last!.id), item: cand)
            }
            return items.isEmpty ? nil : Bucket(key: "whatsapp:\(chat.jid)", items: items.sorted { $0.key > $1.key })
        }

        // §8/R1: anomaly keys off the full listing count (windows across opted-in chats), sampled
        // every run — a collapse to zero from a healthy count is the silent-breakage tripwire.
        SourceHealth.checkListingCollapse(source: "whatsapp", bucketKey: "whatsapp",
                                          count: buckets.reduce(0) { $0 + $1.items.count })
        return buckets
    }

    // MARK: Sender labels

    private static func sender(pushName: String?, memberName: String?, chat: Chat) -> String {
        // Group: push-name → saved contact name → a clean generic. Each candidate is validated, because
        // WhatsApp stores an opaque LID blob as the "name" for some privacy-mode members — that must
        // NEVER reach a summary.
        if chat.isGroup { return cleanName(pushName) ?? cleanName(memberName) ?? "a group member" }
        return chat.name   // DM: the other party is the chat partner
    }

    /// A real display name, or nil if it's actually an opaque WhatsApp JID/LID blob. LID blobs
    /// are long, UNBROKEN base64-ish tokens (e.g. "CIW9/tAGIA…") — they never contain spaces.
    /// Anything multi-word is a real name, slashes and all ("Amrit Sanju Uncle T34/1803" is a
    /// real saved contact; rejecting on '/' alone showed the raw number instead).
    private static func cleanName(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.contains(" ") { return s }                      // multi-word → a real name
        if s.contains("/") || s.count > 24 { return nil }    // single long/slashed token → LID/JID blob
        return s
    }

    /// Phone/handle from a JID like "14155551234@s.whatsapp.net" → "14155551234" (chat-name fallback only).
    private static func handle(_ jid: String) -> String { String(jid.prefix { $0 != "@" }) }

    /// Chat display name: validated partner name → participant roll-up for unnamed groups
    /// ("Aditya & Ondrej", like WhatsApp itself) → phone handle — but NEVER an opaque @lid
    /// identifier or a raw group JID (a chat we can't name shows a clean generic instead).
    private static func displayName(_ partnerName: String?, jid: String, members: [String]?) -> String {
        if let n = cleanName(partnerName) { return n }
        if jid.hasSuffix("@g.us") { return ChatWindowing.groupName(of: members ?? []) }
        if jid.isEmpty || jid.hasSuffix("@lid") { return "Unknown chat" }
        return handle(jid)
    }
}
