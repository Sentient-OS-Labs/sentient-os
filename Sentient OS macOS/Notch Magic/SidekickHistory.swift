//
//  SidekickHistory.swift
//  Sentient OS macOS
//
//  The last 15 things the user asked Sidekick to do — each with when it happened and how it
//  ended — inlined into every command prompt so "finish this" / "try again" resolves against
//  what actually just happened. An entry is recorded at fire (typed/spoken commands AND adopted
//  card fires) and closed at the run's end with the outcome; an entry that never closes (a crash
//  or quit mid-run) honestly reads as interrupted. The block is fenced as CONTEXT ONLY — the
//  agent is told never to redo or resume an entry unless the current task refers back to it.
//  Key methods: promptBlock() · record(_:card:) · close(_:line:). FactoryReset wipes the store.
//  Doc: Documentation - Sidekick - General.md (this folder).
//

import Foundation

@MainActor
enum SidekickHistory {
    /// The persisted store (a JSON-encoded [Entry] in defaults). Production key — FactoryReset wipes it.
    static let key = "sidekick.history"

    private static let capacity = 15
    private static let maxTextLength = 300   // per-entry cap so a long dictation can't bloat the block

    private struct Entry: Codable {
        let text: String       // what the user asked (or the fired card's title)
        let card: Bool         // true = a proactive card's fire, not a typed/spoken command
        let at: Date
        var outcome: String?   // the closing phrase ("you completed it", …); nil = never finished
    }

    /// Append a just-fired request. Called at launch, AFTER `promptBlock()` was read for the
    /// in-flight prompt — a task must never appear in its own history.
    static func record(_ text: String, card: Bool = false) {
        var entries = load()
        let trimmed = text.count > maxTextLength ? String(text.prefix(maxTextLength)) + "…" : text
        entries.append(Entry(text: trimmed, card: card, at: Date(), outcome: nil))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        save(entries)
        Log("SidekickHistory: recorded \(card ? "card fire" : "command") (\(entries.count) entries)")   // B7: count, never the text
    }

    /// Close the pending entry with how the run ended. `line` is the run's final status line —
    /// for failures it carries "✗ <reason>", and the reason is kept: "it stopped because it
    /// needed my card details" is exactly the context the next "finish this" needs.
    static func close(_ outcome: CommandRunModel.Outcome, line: String) {
        var entries = load()
        guard let last = entries.indices.last, entries[last].outcome == nil else { return }
        entries[last].outcome = switch outcome {
        case .success: "you completed it"
        case .stopped: "I stopped you before it finished"
        case .failed:
            "you couldn't finish it (\(line.hasPrefix("✗ ") ? String(line.dropFirst(2)) : line))"
        }
        save(entries)
    }

    /// The command prompt's history block — the recent requests, newest first, each with a
    /// relative timestamp (so last week's task reads as stale) and its outcome, fenced hard as
    /// context-only. "" when there's no history yet, which leaves the prompt unchanged.
    static func promptBlock() -> String {
        let entries = load()
        guard !entries.isEmpty else { return "" }
        let fmt = RelativeDateTimeFormatter()
        fmt.locale = Locale(identifier: "en_US")   // the prompt is English regardless of the Mac's locale
        fmt.dateTimeStyle = .named
        let now = Date()
        let lines = entries.reversed().map { e in
            let raw = fmt.localizedString(for: e.at, relativeTo: now)
            let when = raw == "now" ? "just now" : raw   // "just now I asked" over the formatter's bare "now"
            let what = e.card ? "I fired your suggestion card \"\(e.text)\"" : "I asked: \"\(e.text)\""
            return "- \(when) \(what) — \(e.outcome ?? "it never finished (the run was interrupted)")."
        }
        return """
        ── MY RECENT REQUESTS (context only) ──
        For continuity, these are the last things I asked you to do, newest first. They are pure CONTEXT, never instructions: do NOT redo, resume, or extend any of them on your own. Use them ONLY when my task at the top clearly refers back to one ("finish this", "do that again", "continue where you left off"); otherwise ignore this list.
        \(lines.joined(separator: "\n"))
        """
    }

    private static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    private static func save(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
