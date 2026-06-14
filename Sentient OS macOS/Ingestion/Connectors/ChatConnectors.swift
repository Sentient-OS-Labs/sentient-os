//
//  ChatConnectors.swift
//  Sentient OS macOS
//
//  WhatsApp + iMessage adapters for the iterative core — one shape: per-chat buckets
//  ("whatsapp:<jid>" / "imessage:<guid>"), key `(rowID, "")` (the message row id is unique +
//  monotonic, so no tiebreak), item = a `ChatWindowing` window through the chat Triage prompt
//  (DM vs group via the `isGroup` metadata). Big windows ⇒ `maxTokens` 16384. They wrap each
//  source's `eligibleWindows()` (which reuses the existing windowing / name-resolution / decode).
//  Per-chat opt-in via the JIDs/GUIDs the dev picker supplies. Require Full Disk Access.
//

import Foundation

struct WhatsAppConnector: Connector {
    let kind = SourceKind.whatsapp
    let chatJIDs: Set<String>
    var maxTokens: Int { 16384 }

    func buckets(since marks: [String: ItemKey]) throws -> [Bucket] {
        try WhatsAppSource(chatJIDs: chatJIDs).eligibleWindows()
    }
    func load(_ item: Candidate) throws -> Artifact {
        Artifact(candidate: item, text: item.metadata["windowText"] ?? "")
    }
}

struct iMessageConnector: Connector {
    let kind = SourceKind.imessage
    let chatGUIDs: Set<String>
    var maxTokens: Int { 16384 }

    func buckets(since marks: [String: ItemKey]) throws -> [Bucket] {
        try iMessageSource(chatGUIDs: chatGUIDs).eligibleWindows()
    }
    func load(_ item: Candidate) throws -> Artifact {
        Artifact(candidate: item, text: item.metadata["windowText"] ?? "")
    }
}
