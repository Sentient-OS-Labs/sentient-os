//
//  Proactive.swift
//  Sentient OS macOS
//
//  Proactive Intelligence — its OWN module + trigger (Arch §6), sequenced AFTER a knowledge-base
//  build/update, never concurrently. This is PART 1 of 3: the JUDGE.
//
//  The proactive pipeline runs in three steps, each its own prompt: PART 1 (this file) finds the top
//  action items, PART 2 researches/verifies them (Gmail MCP + web + the knowledge base), PART 3 acts.
//  PART 1 is deliberately SUMMARIES-ONLY and hermetic: the cloud model (Codex, gpt-5.5, high effort)
//  reads ONLY the last 7 days of survivor summaries from EVERY source — files, WhatsApp, iMessage,
//  Apple Notes, Calendar, Gmail — over stdin (no file/web/MCP tools), and returns the up-to-5 most
//  important, most time-sensitive ACTION ITEMS (ranked, `--output-schema`). The deep grounding against
//  the vault and live sources is PART 2's job, not this one. PART 1 only FINDS and RANKS — it does not
//  verify, write, schedule, or notify. Dev-button-triggered for now (the scheduler calls it later).
//
//  Key methods:
//   - findActionItems(from:now:)  → [ActionItem]   (windows to 7 days of summaries, runs Codex)
//
//  Doc: Documentation/Proactive Intelligence (Judge).md
//

import Foundation

/// One thing the judge decided is worth the user's attention. Sendable value type — the later
/// tiers (reminders / briefings) and the For You UI consume these.
struct ActionItem: Sendable, Identifiable, Codable {
    let title: String          // short, specific headline (≤ ~8 words)
    let action: String         // concretely what the user should do or be aware of
    let importance: String     // WHY it matters to THIS user — the dots the model connected
    let dueDate: String?       // the real relevant date in plain words, or nil if none
    let sources: [String]      // the evidence: summary titles / vault notes it drew on
    let urgency: Urgency       // for ranking + later scheduling

    enum Urgency: String, Sendable, Codable { case high, medium, low }

    var id: String { title }
}

actor Proactive {

    static let shared = Proactive()

    /// How far back the judge looks. PART 1 casts a WIDER net (up to 8 candidates); PART 2 verifies
    /// them against the live world and prunes to the strongest ≤5 — that's where scarcity = taste.
    static let lookbackDays = 7
    static let maxItems = 8

    enum ProError: LocalizedError {
        case noRecent
        case usageLimit(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .noRecent:          return "No summaries in the last \(Proactive.lookbackDays) days — nothing for the proactive judge to consider."
            case .usageLimit(let m): return "Your AI hit its usage limit — try again later. (\(m.prefix(160)))"
            case .failed(let m):     return m
            }
        }
    }

    // MARK: Summary windowing (shared with PART 2 so both reason over the SAME corpus)

    /// The last-`lookbackDays` summaries, newest first — the exact window the judge reasons over, and
    /// the same background PART 2 now gets. Defined once here so the windowing can never drift.
    static func recent(from notes: [CloudNote], now: Date = Date()) -> [CloudNote] {
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        func itemDate(_ n: CloudNote) -> Date { n.itemDate ?? .distantPast }
        return notes.filter { itemDate($0) >= cutoff }.sorted { itemDate($0) > itemDate($1) }
    }

    /// Render summaries as the numbered prompt block both parts show:
    /// `#n · [source] location · date` then `title — summary`.
    static func summaryLines(_ notes: [CloudNote]) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        return notes.enumerated().map { i, n in
            let (loc, src) = VaultGenerator.locSrc(kind: n.kind, folder: n.folder, sourceID: n.sourceID)
            let when = n.itemDate.map { df.string(from: $0) } ?? "undated"
            let title = (n.title?.isEmpty == false) ? n.title! : "(untitled)"
            return "#\(i + 1) · [\(src)] \(loc) · \(when)\n\(title) — \(n.text)"
        }.joined(separator: "\n\n")
    }

    // MARK: The judge

    /// Find the top action items across the last week of summaries. PART 1 is summaries-only and
    /// hermetic — no file/web/MCP tools (PART 2 does the deep research). Returns the ranked list; it
    /// does not verify, write, or notify. Throws on no-recent / usage-limit / failure so the caller
    /// can surface a clear status.
    func findActionItems(from notes: [CloudNote], now: Date = Date(),
                         calendarContext: String? = nil) async throws -> [ActionItem] {
        // 1. Window the summaries to the last N days (shared with PART 2 via Self.recent).
        let recent = Self.recent(from: notes, now: now)
        guard !recent.isEmpty else { throw ProError.noRecent }

        // 2. One hermetic Codex call: summaries over stdin, NO tools. A neutral empty scratch dir is
        //    the cwd so even read-only file tools have nothing to find — the model judges from the
        //    summaries ALONE (the vault / Gmail / web research is PART 2's job).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentient-proactive-judge", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        var inv = CodexCLI.Invocation(prompt: Self.prompt(recent: recent, now: now, calendarContext: calendarContext))
        inv.feature = "proactive"
        inv.effort = .high                  // gpt-5.5 → high (this judgment is the product)
        inv.sandbox = .readOnly             // never writes or acts
        inv.cwd = scratch.path              // neutral empty dir — nothing to read
        inv.webSearch = false               // summaries-only; web research is PART 2
        inv.includeUserConfig = false       // hermetic — no user MCP servers (Gmail is PART 2)
        inv.outputSchema = Self.schema
        inv.timeout = 1_200                 // deep reasoning can run long

        Log("Proactive.judge: \(recent.count) summaries in the last \(Self.lookbackDays)d → asking Codex (summaries-only, hermetic)…")
        do {
            let env = try await CodexCLI.shared.run(inv)
            let items = Array(Self.parse(env.result).prefix(Self.maxItems))
            Log("Proactive.judge: ✅ \(items.count) action item(s) (turns \(env.numTurns ?? -1), \(env.outputTokens ?? -1) out-tokens)")
            for (i, it) in items.enumerated() {
                Log("  #\(i + 1) [\(it.urgency.rawValue)\(it.dueDate.map { " · due \($0)" } ?? "")] \(it.title)\n      → \(it.action)\n      why: \(it.importance)\n      src: \(it.sources.joined(separator: " | "))")
            }
            Self.saveLatest(items)
            return items
        } catch let CodexCLI.CLIError.usageLimit(message, _) {
            throw ProError.usageLimit(message)
        } catch {
            throw ProError.failed("\(error)")
        }
    }

    // MARK: Last-run persistence (for the dev "VIEW ACTION ITEMS" viewer)

    private static let latestKey = "proactive.latestActionItems"

    /// Persist the most recent judge run's items (Codable → UserDefaults JSON) so the dev viewer can
    /// show them in detail without re-running — and across app launches.
    static func saveLatest(_ items: [ActionItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: latestKey)
        }
    }

    /// The most recent judge run's items (empty if it never ran). Sync — UserDefaults is thread-safe.
    static func latest() -> [ActionItem] {
        guard let data = UserDefaults.standard.data(forKey: latestKey),
              let items = try? JSONDecoder().decode([ActionItem].self, from: data) else { return [] }
        return items
    }

    // MARK: Output schema (the `--output-schema` contract)

    private static let schema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "action_items":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{\
    "title":{"type":"string"},\
    "action":{"type":"string"},\
    "importance":{"type":"string"},\
    "due_date":{"type":"string"},\
    "sources":{"type":"array","items":{"type":"string"}},\
    "urgency":{"type":"string","enum":["high","medium","low"]}},\
    "required":["title","action","importance","due_date","sources","urgency"]}}},\
    "required":["action_items"]}
    """

    // MARK: Tolerant parse (output-schema makes `result` the JSON; still fence-safe)

    private static func parse(_ result: String) -> [ActionItem] {
        let span: String
        if let s = result.firstIndex(of: "{"), let e = result.lastIndex(of: "}"), s < e {
            span = String(result[s...e])
        } else { span = result }
        guard let data = span.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = obj["action_items"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let title = (d["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let due = (d["due_date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ActionItem(
                title: title,
                action: (d["action"] as? String) ?? "",
                importance: (d["importance"] as? String) ?? "",
                dueDate: (due?.isEmpty == false) ? due : nil,
                sources: (d["sources"] as? [String]) ?? [],
                urgency: ActionItem.Urgency(rawValue: (d["urgency"] as? String)?.lowercased() ?? "medium") ?? .medium)
        }
    }

    // MARK: The prompt — accuracy-first, detailed (the judgment IS the product)

    private static func prompt(recent: [CloudNote], now: Date, calendarContext: String?) -> String {
        let today = todayString(now)

        // The user's LIVE calendar (last 7 days + next 24h, ALL events), pre-fetched as text so PART 1
        // stays tool-free/hermetic. Only present when Calendar is connected (CalendarConnect.fetch…).
        let calendarBlock: String = {
            guard let ctx = calendarContext?.trimmingCharacters(in: .whitespacesAndNewlines), !ctx.isEmpty else { return "" }
            return """

            ## THE USER'S LIVE CALENDAR (every event — last 7 days + next 24 hours)
            This is the user's actual calendar right now (not a summary). Use it to ground \
            time-sensitivity: spot a commitment that's now imminent, a meeting to prepare for, a thing \
            someone proposed that a free slot makes possible, or a deadline tied to an event. It is \
            context, not a checklist — surface an item only when it genuinely deserves attention.

            \(ctx)

            """
        }()

        return """
        You are the **Proactive Intelligence** engine of Sentient OS — the single most important part \
        of the product. You live on the user's own Mac and you ALONE have read their entire digital \
        life: their files, their WhatsApp and iMessage, their Apple Notes, their Calendar, and their \
        email. No other AI on Earth sees across all of it. Your job right now is to use that unfair \
        advantage to surface the handful of things that genuinely deserve the user's attention — the \
        highest-impact, most time-sensitive ACTION ITEMS — at a level that makes them feel like they \
        have a world-class chief of staff who knows them better than anyone alive.

        This is a NO-COMPROMISE feature. One brilliant, perfectly-timed action item builds more trust \
        than a hundred summaries; one wrong one — a hallucinated deadline, someone else's task \
        mistaken for the user's, or generic noise dressed up as urgent — destroys it. The bar is the \
        highest possible — top-0.1%-in-the-world judgment. ACCURACY and TASTE beat coverage every \
        single time. When in doubt, leave it out.

        Today is \(today).

        ## YOUR EDGE IS BREADTH — you see every source at once
        Everyone else's AI is trapped inside one app. You are not. These summaries span the user's \
        ENTIRE digital life at once — files, WhatsApp, iMessage, Apple Notes, Calendar, and email. \
        That lets you notice when separate signals are actually about the SAME thing and connect them:
        - The user wrote a to-do in Apple Notes → a message or email shows it's now due or unblocked → \
        that's one action item, not two.
        - Someone proposes a time in iMessage → a calendar summary shows the user is free → "reply yes \
        and put it on the calendar."
        - A saved file / bookmark (a form, an application, an event) → a deadline stated or implied in \
        another summary → "complete it before it closes."
        - A renewal / confirmation email → another summary shows the user actually relies on that \
        thing → it's a real action, not inbox noise.

        Connect these when they're genuinely there — but don't strain to manufacture links. A strong \
        item that lives in a single summary is every bit as valid as one that spans several.

        IMPORTANT — your scope: you DETECT and RANK from these summaries ALONE. A separate research \
        step runs AFTER you and verifies each item you pick against the live sources (Gmail, the web) \
        and the user's knowledge base — correcting details and dropping anything already done. So you \
        do NOT need to be perfectly certain or fully grounded here; that's handled next. But you must \
        NOT pad: only the genuinely strongest candidates earn a slot.

        ## YOUR INPUT: the last 7 days of summaries
        The last \(lookbackDays) days of summaries (at the end of this message) are your ONLY input, \
        from EVERY source — files, WhatsApp, iMessage, Apple Notes, Calendar, and Gmail. Each line is \
        `#<n> · [source] location · date` then `Title — summary`. Scan EVERY source thoroughly — a \
        promise made in WhatsApp, a to-do written in Notes, a deadline implied by a saved file, a \
        request in iMessage can each be exactly as important as anything in email. Do NOT force a \
        spread and do NOT penalize any source: just surface the genuinely best items, whatever they \
        happen to be. If the strongest items all turn out to be email, that's completely fine. Judge \
        from these summaries alone — you have no other tools here.

        ## What an ACTION ITEM is
        Something the user should DO, DECIDE, PREPARE FOR, or BE AWARE OF soon — concrete, time-relevant, \
        and ideally something Sentient can ACT ON for them. Sentient can already take REAL action: send \
        an email through their Gmail, add an event to their calendar, drive their MAC directly via \
        computer use (register/RSVP/buy/fill a form on a logged-in website, send a WhatsApp/iMessage, \
        act in a native app like Notion), or research and write something up. \
        Favor items that map onto one of those — but a purely informational "you should be aware of \
        this" is still valid when it genuinely matters. Your job here is DETECTION + framing: identify \
        the item and the EXACT next action. Do not perform anything; just detect and frame (a later \
        step verifies, prepares, and fires).

        ## Examples of the kinds to look for
        (Illustrative and HYPOTHETICAL — learn the SHAPE, NOT these specific details. They generalize \
        to any person, topic, and tool. Do not look for these exact scenarios; find the real ones in \
        THIS user's summaries.)

        - **Overdue reply awaiting the user.** A contact emailed days ago asking the user to do \
        something — an intro, a blurb, a decision — and nothing in the summaries shows a reply yet. \
        ACTION: "Reply to <person> about <thing>." Signals: the email summary.
        - **Cross-tool meeting request.** Someone proposes a time over iMessage/WhatsApp; a calendar \
        summary shows the user is free then. ACTION: "Reply to confirm and add it to the calendar." \
        Signals: the message summary + the calendar summary.
        - **A promise the user made.** In a chat summary the user said they'd send / research / share \
        something. ACTION: "Send what you promised." Signals: the chat summary (+ any summary showing \
        it's ready).
        - **A deadline with a form to complete.** A saved-file or email summary is about an \
        application, registration, or renewal that closes soon. ACTION: "Complete the registration \
        before it closes." Signals: the file / email summary + the stated deadline.
        - **A renewal / expiry / payment.** A reminder email or saved-document summary points to \
        something expiring (a domain, subscription, membership, document). ACTION: "Renew or cancel \
        before <date>." Signals: the email / file summary.
        - **A to-do the user wrote themselves.** A Notes summary holds a task, and another summary \
        shows it's now due or unblocked. ACTION: surface it with the concrete next step. Signals: the \
        Notes summary + the corroborating summary.
        - **A plan forming across people.** A group-chat summary shows people brainstorming something \
        (a trip, an event, a decision). ACTION: "A plan is forming — <the concrete next step>." \
        Signals: the group-chat summary(ies).

        These are starting patterns, not a checklist — the biggest wins are the connections across \
        summaries that no template predicted.

        ## Hard accuracy rules (non-negotiable)
        - NEVER invent a date, name, fact, or deadline. If there's no real date, set `due_date` to "".
        - Every action item MUST trace to real evidence in the summaries — and you must cite that \
        evidence in `sources`.
        - NO raw private specifics (card / account numbers, passwords, exact medical or financial \
        figures).
        - A confident wrong item is far worse than a missed one.

        ## Rank, then cut
        Rank by (impact to THIS user) × (time-sensitivity) × (how clearly actionable it is). Return AT \
        MOST \(maxItems) candidates. A later step verifies each one against the live world and keeps \
        only the ~5 strongest, so it's fine to surface a slightly wider set of GENUINE candidates here \
        — but still NEVER pad: return FEWER (even zero) if there aren't that many worth surfacing. Pick \
        the genuinely strongest items regardless of which source they come from — do NOT force a \
        spread; a deep, well-evidenced single-source item beats a shallow one every time.

        ## Output
        Return ONLY the structured object defined by the output schema — no prose around it. For each \
        action item:
        - **title** — a short, specific, human headline (≤ ~8 words), like a great notification.
        - **action** — the EXACT next step, addressed to the user ("Reply to…", "Register for…", \
        "Send the…", "Renew…"), written as something ready to execute.
        - **importance** — WHY this matters to THIS user right now, and explicitly NAME THE DOTS YOU \
        CONNECTED: which summaries/sources, and what each one contributed. This is where your \
        reasoning must visibly show.
        - **due_date** — the real relevant date in plain words ("June 20, 2026", "this Friday"), or "" \
        if there genuinely is none.
        - **sources** — the concrete summaries behind the item, each by name (e.g. "WhatsApp · Dad", \
        "Notes · running gear", "Calendar", "Gmail · <subject>"). Cite the provenance here.
        - **urgency** — "high", "medium", or "low".

        \(calendarBlock)The last \(lookbackDays) days of summaries follow.

        ---

        \(Self.summaryLines(recent))
        """
    }

    private static func todayString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .none; return f.string(from: d)
    }
}
