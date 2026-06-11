//
//  ChatWindowing.swift
//  Sentient OS macOS
//
//  Shared machinery for the chat sources (WhatsApp + iMessage — the second use case that earned
//  this extraction). A chat source's unit of analysis is a CONVERSATION WINDOW, not a message:
//  a run of messages from ONE chat, time-ordered, sized by a UTF-8 BYTE budget, flowing through
//  the pipeline as one Artifact. Key pieces:
//    ChatMessage          — one decoded message, normalized across sources
//    ChatInfo             — a row for the opt-in chat picker
//    ChatWindowing.windows(of:)  — greedy byte-budget batching
//    ChatWindowing.format(...)   — frames a window for the model (chat name, group/DM,
//                                  "you sent N of M" participation anchor, per-message senders)
//  Limits (TODO plan): chat connectors read the last `lookbackDays` 90 days OR the newest
//  `maxMessages` 100k messages per connector — whichever cuts first.
//

import Foundation

/// One decoded chat message, normalized across sources. `sender` is the display label the model
/// sees — "Me" for the user, a resolved contact/push name, or a clean generic ("a group member");
/// raw handles/JIDs must be resolved or cleaned by the source BEFORE constructing this.
struct ChatMessage: Sendable {
    let id: Int64          // source row id (WhatsApp Z_PK / iMessage ROWID) → stable window ids
    let date: Date
    let sender: String
    let isFromMe: Bool
    let text: String       // capped at ChatWindowing.maxMessageChars by the source
}

/// A chat as shown in the opt-in picker — active within the lookback, with how busy it's been.
/// `id` is the source's stable opt-in key (WhatsApp JID / iMessage chat GUID).
struct ChatInfo: Sendable, Identifiable {
    let id: String
    let name: String
    let isGroup: Bool
    let messageCount: Int
    let lastActive: Date
}

enum ChatWindowing {
    // MARK: Limits — shared by every chat connector
    static let lookbackDays = 90
    static let maxMessages = 100_000       // newest-first cap, summed across the connector's chats

    // We size a window by its UTF-8 BYTE count, NOT chars (and NOT a chars→tokens guess). A
    // byte-level tokenizer emits at most ONE token per byte, so bytes are a HARD upper bound on
    // tokens — a window can never overflow the model's token budget, even for emoji / CJK /
    // multilingual chats where characters wildly under-count tokens. (That mismatch is what made
    // the model "go quiet": a 26k-char window tokenized to 18.6k tokens, >2× an 8,192 budget.)
    //
    // 12,000 is sized from measurement (June 11 `tokens` self-test, 24 real windows across 14
    // chats): real chat runs ~2.4 bytes/token (min 2.05), so a full window is ~5k tokens typical
    // — and even the adversarial worst case (1 token/byte) fits the chat engine's 16,384
    // maxNumTokens with room for the group prompt template (1,567 tokens measured) + reply.
    // The old 5,000 left ~83% of the context empty and paid that fixed template cost once per
    // ~30 messages. Quality, not token math, is the gate on raising this further — more
    // speakers per window = more attribution risk for a 4B judge.
    static let maxWindowBytes = 12_000
    static let maxMessageChars = 1_000     // cap a single pasted-essay message so it can't dominate a window

    /// The 90-day floor as a Date (sources convert to their own epoch/units for SQL).
    static var lookbackFloor: Date { Date().addingTimeInterval(-Double(lookbackDays) * 86_400) }

    // MARK: Windowing — per chat, time-ordered, greedy up to the byte budget

    static func windows(of msgs: [ChatMessage]) -> [[ChatMessage]] {
        var out: [[ChatMessage]] = []
        var cur: [ChatMessage] = []
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
    private static func msgBytes(_ m: ChatMessage) -> Int { m.text.utf8.count + 28 }   // + date/sender label overhead

    // MARK: Formatting — frame the window for the model

    static func format(chatName: String, isGroup: Bool, messages: [ChatMessage]) -> String {
        let mine = messages.lazy.filter(\.isFromMe).count
        var out = "Chat: \"\(chatName)\" (\(isGroup ? "group" : "direct message"))\n"
        out += "In this slice, you (\"Me\") sent \(mine) of \(messages.count) messages.\n"
        for m in messages { out += "[\(dateString(m.date))] \(m.sender): \(m.text)\n" }
        return out
    }

    /// "Alex, Sam & 2 others" — display name for a group without an explicit one, synthesized
    /// from its CURRENT participants (both chat sources use this; members who left are excluded
    /// by the caller).
    static func groupName(of participants: [String]) -> String {
        switch participants.count {
        case 0:  return "Group chat"
        case 1:  return participants[0]
        case 2:  return "\(participants[0]) & \(participants[1])"
        default: return "\(participants[0]), \(participants[1]) & \(participants.count - 2) others"
        }
    }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f
    }()
    private static func dateString(_ d: Date) -> String { df.string(from: d) }
}
