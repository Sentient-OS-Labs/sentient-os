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
//    ChatCursorState      — a chat's decoded pointer (incremental / backfill / first run)
//    ChatWindowing.windows(of:)  — greedy byte-budget batching
//    ChatWindowing.chatCandidates(...) — one chat's windows under its pointer state (the
//                                  backfill/incremental ordering logic, shared verbatim)
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

/// One chat's pointer state, decoded from its SourceCursor value (WhatsApp Z_PK / iMessage
/// ROWID — both monotonic Int64 row ids). `.backfill` carries the consumed interval [lo, hi];
/// chats are unbudgeted (remaining nil) — the rolling 90-day floor terminates the dig.
enum ChatCursorState: Sendable {
    case backfillStart                                  // no pointer yet — first run for this chat
    case backfill(BackfillCursor, hi: Int64, lo: Int64)
    case incremental(Int64)

    static func decode(_ raw: String?) -> ChatCursorState {
        if let bf = BackfillCursor.decode(raw), let hi = Int64(bf.hi), let lo = Int64(bf.lo) {
            return .backfill(bf, hi: hi, lo: lo)
        }
        if let v = raw.flatMap(Int64.init) { return .incremental(v) }
        return .backfillStart
    }

    /// Should a message row with this id be fetched under this state?
    func wants(_ id: Int64) -> Bool {
        switch self {
        case .backfillStart:                return true
        case .backfill(_, let hi, let lo):  return id > hi || id < lo
        case .incremental(let v):           return id > v
        }
    }
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

    // MARK: One chat's candidates under its pointer state (shared by WhatsApp + iMessage)

    /// Window `msgs` (ascending by row id, already state-filtered by the source's fetch) and
    /// assign each window's pointer write per the backfill contract (DataSource.swift):
    ///   now — new windows (above hi / past the plain pointer), ascending
    ///   dig — backfill descent windows, NEWEST first; each write records [window min, hi]
    ///   completion — the plain pointer value when this chat's backfill just finished
    /// `make` builds the source-specific Candidate from (window, cursorValue).
    /// `mayBeClipped`: when the connector-wide newest-`maxMessages` cap was hit, an empty dig
    /// might be the clip rather than a finished backfill — never complete on a clipped scan
    /// (the state lingers and completes on a quieter run; collapsing early would skip the
    /// chat's remaining history forever).
    static func chatCandidates(
        msgs: [ChatMessage], state: ChatCursorState, mayBeClipped: Bool,
        make: ([ChatMessage], String) -> Candidate
    ) -> (now: [Candidate], dig: [Candidate], completion: String?) {
        switch state {
        case .backfillStart:
            let wins = windows(of: msgs).filter { !$0.isEmpty }
            guard let hi = wins.last?.last?.id else { return ([], [], nil) }
            let dig = wins.reversed().map { win in
                make(win, BackfillCursor(hi: "\(hi)", lo: "\(win.first!.id)", remaining: nil).encoded)
            }
            return ([], dig, nil)

        case .backfill(let bf, let hi, let lo):
            let aboveWins = windows(of: msgs.filter { $0.id > hi }).filter { !$0.isEmpty }
            let belowWins = windows(of: msgs.filter { $0.id < lo }).filter { !$0.isEmpty }
            if belowWins.isEmpty {
                if mayBeClipped {   // dig starved by the cap, not finished — keep the state
                    let now = aboveWins.map { win in
                        make(win, BackfillCursor(hi: "\(win.last!.id)", lo: bf.lo, remaining: nil).encoded)
                    }
                    return (now, [], nil)
                }
                // Backfill over — collapse to a plain pointer; new windows proceed as
                // ordinary incrementals.
                return (aboveWins.map { make($0, "\($0.last!.id)") }, [], bf.hi)
            }
            // The dig's writes must carry the hi the now-group will have swept up to.
            let hiFinal = aboveWins.last.map { "\($0.last!.id)" } ?? bf.hi
            let now = aboveWins.map { win in
                make(win, BackfillCursor(hi: "\(win.last!.id)", lo: bf.lo, remaining: nil).encoded)
            }
            let dig = belowWins.reversed().map { win in
                make(win, BackfillCursor(hi: hiFinal, lo: "\(win.first!.id)", remaining: nil).encoded)
            }
            return (now, dig, nil)

        case .incremental:
            let wins = windows(of: msgs).filter { !$0.isEmpty }
            return (wins.map { make($0, "\($0.last!.id)") }, [], nil)
        }
    }

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
