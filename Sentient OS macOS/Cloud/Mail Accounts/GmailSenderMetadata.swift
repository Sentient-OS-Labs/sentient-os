// GmailSenderMetadata.swift
// Reads a single sending-address candidate from Gmail's metadata-only search response.
// Empty, ambiguous, failed or malformed results skip address collection.
// Doc: Documentation - Connected Email Accounts.md

import Foundation

nonisolated enum GmailSenderMetadata {
    static var searchArguments: [String: Any] {
        ["query": "in:sent", "pageSize": 1, "view": "THREAD_VIEW_METADATA_ONLY"]
    }

    static func email(from result: [String: Any]) -> String? {
        guard result["isError"] as? Bool != true else { return nil }
        // Current Claude returns both a JSON string and structuredContent. Prefer the typed
        // payload so the same thread is not counted twice; never scrape addresses out of prose.
        let payload: [String: Any]?
        if let structured = result["structuredContent"] ?? result["structured_content"] {
            payload = structured as? [String: Any]
        } else if let text = result["content"] as? String {
            payload = object(text)
        } else if let blocks = result["content"] as? [[String: Any]] {
            let objects = blocks.compactMap { block -> [String: Any]? in
                guard block["type"] as? String == "text", let text = block["text"] as? String else { return nil }
                return object(text)
            }
            payload = objects.count == 1 ? objects.first : nil
        } else { payload = nil }
        guard let payload, payload["isError"] as? Bool != true,
              let threads = payload["threads"] as? [[String: Any]], threads.count <= 1 else { return nil }

        var senders = Set<String>()
        for thread in threads {
            guard let messages = thread["messages"] as? [[String: Any]] else { return nil }
            for message in messages {
                // Refuse automatic inference if a future server ignores metadata-only mode.
                for key in ["plaintextBody", "htmlBody", "subject", "snippet"] {
                    if let value = message[key], !(value is NSNull), (value as? String) != "" { return nil }
                }
                guard let labels = message["labelIds"] as? [String] else { return nil }
                guard labels.contains("SENT") else { continue }
                guard let sender = message["sender"] as? String, let email = address(sender) else { return nil }
                senders.insert(email)
                if senders.count > 1 { return nil }
            }
        }
        return senders.count == 1 ? senders.first : nil
    }

    private static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func address(_ sender: String) -> String? {
        guard !sender.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let value = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        if let email = MailAccount.normalizedEmail(value) { return email }
        // Handle a single RFC-style "Display Name <address>" without accepting address lists.
        guard value.last == ">", value.filter({ $0 == "<" }).count == 1,
              value.filter({ $0 == ">" }).count == 1, let opening = value.firstIndex(of: "<"),
              !value[..<opening].contains("@") else { return nil }
        return MailAccount.normalizedEmail(String(value[value.index(after: opening)..<value.index(before: value.endIndex)]))
    }
}
