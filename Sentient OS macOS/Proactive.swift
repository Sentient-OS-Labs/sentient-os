//
//  Proactive.swift
//  Sentient OS macOS
//
//  Proactive Intelligence (Part II §E) — flagship feature #2, riding the day's-end run.
//   1. Selection: reminder-flagged summaries newer than the "proactive" pointer (a createdAt
//      high-water mark in SourceCursor — judged once, no bookkeeping tables, re-runs never
//      re-judge).
//   2. The judge: ONE Sonnet call, no tools, structured output — which of these (if any)
//      genuinely deserve the user's attention. The taste law lives in the prompt AND in code:
//      at most ONE non-skip decision survives per run.
//   3. Tier 1 (remind): a scheduled macOS notification. Past/unparseable time → fire now.
//      Tier 2 (brief): a second, agentic call — vault context + WebSearch → ONE briefing .md
//      into the Briefings folder (OUTSIDE the vault: briefings are For You artifacts, not the
//      user's knowledge base — they must never ride the mirror push). Never auto-send.
//
//  Failures never block the updater or the mirror push: everything is caught here; worst
//  case the pointer doesn't advance and tomorrow re-judges.
//
//  Doc: Documentation/Days-End Job (Living System).md
//

import Foundation

/// Where For You artifacts live — `~/Library/Application Support/SentientOS/Briefings/`
/// [STARTING POINT], deliberately outside the vault. The For You UI just lists this folder.
enum Briefings {
    static var dir: URL {
        let d = URL.applicationSupportDirectory
            .appendingPathComponent("SentientOS/Briefings", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// All briefings, newest first (by filename — they're date-prefixed — then mtime).
    static func list() -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        return files.filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

enum Proactive {

    struct Outcome: Sendable {
        var judged = 0
        var reminders = 0
        var briefings = 0
        var note: String?    // surfaced in the dev status line
    }

    private static let cursorKey = "proactive"
    private static let judgeSchema = """
        {"type":"object","properties":{"decisions":{"type":"array","items":{"type":"object",\
        "properties":{"kind":{"type":"string","enum":["remind","brief","skip"]},\
        "time":{"type":["string","null"]},"text":{"type":"string"},\
        "reason":{"type":"string"}},"required":["kind","text"]}}},"required":["decisions"]}
        """

    /// Judge the new reminder-flagged summaries and act on at most ONE. Never throws — the
    /// day's-end run must finish (and push) regardless of what happens here.
    static func run(store: Store) async -> Outcome {
        var out = Outcome()
        do {
            // 1) Selection past the pointer (createdAt high-water mark). Stored in Date's
            // NATIVE representation (seconds since 2001) — an epoch conversion would round-trip
            // lossily and let the newest judged item leak past the strict `>` next run.
            let after = (await store.cursor(forKey: cursorKey)).flatMap(Double.init)
                .map { Date(timeIntervalSinceReferenceDate: $0) }
            let flagged = await store.flaggedSummaries(after: after)
            guard !flagged.isEmpty else { return out }
            out.judged = flagged.count

            // 2) The judge — one structured-output Sonnet call, no tools.
            var inv = ClaudeCLI.Invocation(prompt: Self.judgePrompt(flagged))
            inv.model = .sonnet
            inv.jsonSchema = judgeSchema
            inv.timeout = 300
            let envelope = try await ClaudeCLI.shared.run(inv)
            let decisions = Self.parseDecisions(envelope.result)

            // The taste cap, enforced in CODE: the prompt requests restraint, this guarantees
            // it — take the first non-skip decision, drop the rest.
            if let act = decisions.first(where: { $0.kind != "skip" }) {
                switch act.kind {
                case "remind":
                    let when = act.time.flatMap(Self.parseISO) ?? Date()
                    await Notify.schedule(at: when, title: "Sentient OS", body: act.text)
                    out.reminders = 1
                    Log("Proactive: scheduled reminder @ \(when) — \(act.text.prefix(80))")
                case "brief":
                    if await Self.writeBriefing(task: act.text) {
                        out.briefings = 1
                        await Notify.now(title: "A briefing is ready for you",
                                         body: String(act.text.prefix(120)))
                    }
                default: break
                }
            } else {
                Log("Proactive: judged \(flagged.count) flagged items — nothing worth surfacing (taste).")
            }

            // 3) Advance the pointer — these items are judged, never re-judged.
            if let newest = flagged.map(\.createdAt).max() {
                try await store.advanceCursor("\(newest.timeIntervalSinceReferenceDate)", forKey: cursorKey)
            }
        } catch {
            // Pointer not advanced → tomorrow re-judges. Never blocks the updater/push.
            out.note = "proactive failed: \(error)"
            Log("Proactive: ⚠️ \(error) — pointer not advanced, tomorrow re-judges.")
        }
        return out
    }

    // MARK: Tier 2 — the agentic briefing

    /// Research/draft the task with vault context + WebSearch and land ONE .md in Briefings.
    private static func writeBriefing(task: String) async -> Bool {
        let date = ISO8601DateFormatter.dateOnly.string(from: Date())
        let slug = task.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.prefix(6).joined(separator: "-")
        let file = Briefings.dir.appendingPathComponent("\(date) — \(slug.isEmpty ? "briefing" : slug).md")

        var inv = ClaudeCLI.Invocation(prompt: """
            You are preparing a morning briefing for the user of Sentient OS — a private, \
            personal-intelligence app. Your working directory is their personal knowledge \
            vault: explore it (Glob/Grep/Read) for context about who they are and what this \
            task means to them. Use WebSearch for anything that needs current information.

            THE TASK: \(task)

            Write ONE polished markdown briefing to this exact path:
            \(file.path)

            Shape: a clear title; the payoff up front (the answer, the plan, or the ready-to-use \
            draft); supporting details below; sources/links at the end. Warm, concise, zero \
            filler — something the user is delighted to wake up to. If the task involves a \
            message or email, DRAFT it ready-to-paste — but NEVER send anything on the user's \
            behalf; you offer, they fire.

            When the briefing is written, reply with one line: DONE.
            """)
        inv.model = .sonnet
        inv.allowedTools = ["Read", "Glob", "Grep", "WebSearch", "Write"]
        inv.cwd = VaultGenerator.vaultRoot.path
        inv.addDirs = [Briefings.dir.path]
        inv.timeout = 900
        do {
            _ = try await ClaudeCLI.shared.run(inv)
            return FileManager.default.fileExists(atPath: file.path)
        } catch {
            Log("Proactive: briefing agent failed — \(error)")
            return false
        }
    }

    // MARK: Judge prompt + parsing

    private static func judgePrompt(_ items: [SummaryItem]) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        var lines: [String] = []
        for (i, s) in items.enumerated() {
            let when = s.itemDate.map { df.string(from: $0) } ?? "unknown"
            lines.append("#\(i + 1) · item date: \(when) · noticed: \(df.string(from: s.createdAt))\n\((s.title ?? "Untitled")) — \(s.text)")
        }
        return """
        You are the proactive-intelligence judge for Sentient OS, a private personal-AI app. \
        While reading the user's new files and messages, the on-device model flagged the items \
        below as *potential* reminders. Decide which — if any — genuinely deserve the user's \
        attention. Right now it is \(df.string(from: Date())).

        THE TASTE LAW (non-negotiable): most days the right answer is NOTHING. At most ONE item \
        may surface per day — scarcity is the taste. Only genuinely time-sensitive, personally \
        actionable items qualify: the user's own deadline, appointment, renewal, booking window, \
        or dated commitment that is still in the future and still actionable. Stale items, \
        vague intentions, other people's schedules, and public event dates the user merely saw \
        → "skip".

        For each item return one decision object:
        - "skip" — the default, for almost everything.
        - "remind" — worth a single, well-timed macOS notification. Set "time" to the ideal \
        ISO-8601 delivery moment (future, e.g. the evening before a deadline) and "text" to the \
        notification body: specific, warm, ≤140 characters (e.g. "Tickets for the concert you \
        screenshotted go on sale tomorrow at 5 PM.").
        - "brief" — RARE: only when acting on it needs research or drafting the user would love \
        to wake up to (e.g. "research the Lisbon trip the user is planning and present options", \
        "draft the overdue reply to the landlord"). Set "text" to a one-line task description \
        for the researcher agent.

        Always include "reason" (one short sentence). Return decisions for ALL items, in order.

        THE FLAGGED ITEMS:

        \(lines.joined(separator: "\n\n"))
        """
    }

    struct Decision: Sendable {
        let kind: String
        let time: String?
        let text: String
    }

    static func parseDecisions(_ result: String) -> [Decision] {
        // --json-schema makes `result` the JSON object itself; tolerate fenced/prefixed output.
        let span: String
        if let start = result.firstIndex(of: "{"), let end = result.lastIndex(of: "}"), start < end {
            span = String(result[start...end])
        } else { span = result }
        guard let data = span.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = obj["decisions"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let kind = d["kind"] as? String, let text = d["text"] as? String else { return nil }
            return Decision(kind: kind, time: d["time"] as? String, text: text)
        }
    }

    private static func parseISO(_ s: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return withFrac.date(from: s) ?? plain.date(from: s)
    }
}

private extension ISO8601DateFormatter {
    /// "2026-06-11" — briefing filename prefix.
    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}
