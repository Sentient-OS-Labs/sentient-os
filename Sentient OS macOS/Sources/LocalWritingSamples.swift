//
// LocalWritingSamples.swift
// Reads unabridged outgoing text from recent one-to-one chats using disposable DB snapshots.
// iMessage() and whatsApp() share contact selection and preserve every sample verbatim, each
// with the name of the person it went to when the Mac knows them.
// Doc: Documentation - Sources - Local (Files, WhatsApp, iMessage, Notes).md
//

import Foundation

nonisolated enum LocalWritingSamples {
    static let peopleLimit = 6
    static let messagesLimit = 5

    /// One outgoing message and who it went to: a contact name, else the handle itself.
    struct Sample: Equatable, Sendable {
        let recipient: String
        let text: String
    }

    private struct Contact {
        var rows: [Int64]
        var lastActive: Double
        let name: String
    }
    private enum Finished: Error { case reading }

    /// Multiple SMS/iMessage conversations with the same handle count as one person. `names` is
    /// the Mac's Contacts map (AddressBookNames.loadMap); a handle nobody saved stays a handle.
    static func iMessage(path: String, names: [String: String]) throws -> [Sample] {
        let (copy, directory) = try SQLiteDB.walSafeCopy(of: path, requireCompleteWAL: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try SQLiteReader(path: copy.path)
        var contacts: [String: Contact] = [:]
        try reader.forEachRow("""
            SELECT c.ROWID, c.guid, c.chat_identifier, MAX(m.date)
            FROM chat c JOIN chat_message_join j ON j.chat_id = c.ROWID
            JOIN message m ON m.ROWID = j.message_id
            WHERE c.style = 45 AND COALESCE(c.is_filtered, 0) <= 1
              AND COALESCE(c.is_blackholed, 0) = 0
              AND m.associated_message_type = 0 AND m.item_type = 0
            GROUP BY c.ROWID
            """) { row in
            guard let handle = row.text(2), !handle.isEmpty else { return }
            let key = handle.lowercased()
            var contact = contacts[key]
                ?? Contact(rows: [], lastActive: 0, name: AddressBookNames.resolve(handle, in: names) ?? handle)
            contact.rows.append(row.int(0))
            contact.lastActive = max(contact.lastActive, row.double(3))
            contacts[key] = contact
        }
        return try collect(contacts) { contact in
            var samples: [String] = []
            do {
                try reader.forEachRow("""
                    SELECT DISTINCT m.ROWID, m.date, m.text, m.attributedBody
                    FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID
                    WHERE j.chat_id IN (\(contact.rows.sorted().map(String.init).joined(separator: ",")))
                      AND m.is_from_me = 1 AND m.associated_message_type = 0 AND m.item_type = 0
                    ORDER BY m.date DESC, m.ROWID DESC
                    """) { row in
                    try Task.checkCancellation()
                    let plain = row.text(2)
                    let body = plain?.isEmpty == false ? plain : row.blob(3).flatMap(iMessageSource.typedstreamText)
                    guard let body, usable(body) else { return }
                    samples.append(body)
                    if samples.count == messagesLimit { throw Finished.reading }
                }
            } catch Finished.reading { }
            return samples
        }
    }

    /// WhatsApp stores the contact's name beside the chat; an unnamed chat keeps its phone handle.
    static func whatsApp(path: String) throws -> [Sample] {
        let (copy, directory) = try SQLiteDB.walSafeCopy(of: path, requireCompleteWAL: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try SQLiteReader(path: copy.path)
        var contacts: [String: Contact] = [:]
        try reader.forEachRow("""
            SELECT s.Z_PK, s.ZCONTACTJID, MAX(m.ZMESSAGEDATE), s.ZPARTNERNAME
            FROM ZWACHATSESSION s JOIN ZWAMESSAGE m ON m.ZCHATSESSION = s.Z_PK
            WHERE s.ZSESSIONTYPE = 0
            GROUP BY s.Z_PK
            """) { row in
            guard let jid = row.text(1),
                  jid.hasSuffix("@s.whatsapp.net") || jid.hasSuffix("@lid") else { return }
            let name = WhatsAppSource.cleanName(row.text(3))
                ?? (jid.hasSuffix("@lid") ? "Unknown contact" : WhatsAppSource.handle(jid))
            var contact = contacts[jid] ?? Contact(rows: [], lastActive: 0, name: name)
            contact.rows.append(row.int(0))
            contact.lastActive = max(contact.lastActive, row.double(2))
            contacts[jid] = contact
        }
        return try collect(contacts) { contact in
            var samples: [String] = []
            try reader.forEachRow("""
                SELECT ZTEXT FROM ZWAMESSAGE
                WHERE ZCHATSESSION IN (\(contact.rows.sorted().map(String.init).joined(separator: ",")))
                  AND ZISFROMME = 1 AND ZMESSAGETYPE = 0
                  AND ZTEXT IS NOT NULL AND length(trim(ZTEXT)) > 0
                ORDER BY ZMESSAGEDATE DESC, Z_PK DESC LIMIT \(messagesLimit)
                """) { row in
                try Task.checkCancellation()
                if let body = row.text(0), usable(body) { samples.append(body) }
            }
            return samples
        }
    }

    private static func collect(_ contacts: [String: Contact], read: (Contact) throws -> [String]) throws -> [Sample] {
        var result: [Sample] = [], count = 0
        let ordered = contacts.sorted {
            $0.value.lastActive == $1.value.lastActive ? $0.key < $1.key : $0.value.lastActive > $1.value.lastActive
        }
        for (_, contact) in ordered {
            try Task.checkCancellation()
            let texts = try read(contact)
            guard !texts.isEmpty else { continue } // A received-only conversation is not a writing sample.
            result += texts.map { Sample(recipient: contact.name, text: $0) }
            count += 1
            if count == peopleLimit { break }
        }
        return result
    }

    private static func usable(_ body: String) -> Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{fffc}"))).isEmpty
    }
}
