//
//  Proactive.swift
//  Sentient OS macOS
//
//  Proactive Intelligence — its OWN module + trigger (Arch §6), sequenced AFTER a knowledge-base
//  build/update, never concurrently. This is STEP 1: the JUDGE.
//
//  Once the initial pass has produced summaries and the vault exists, the cloud model (Codex,
//  gpt-5.5, high effort, READ-ONLY) reads BOTH (a) the last 7 days of survivor summaries from
//  EVERY source — files, WhatsApp, iMessage, Apple Notes, Gmail — and (b) the live knowledge base
//  in its working directory, connects the dots across them, and returns the up-to-5 most important,
//  most time-sensitive ACTION ITEMS (ranked, `--output-schema`). It only FINDS and RANKS — it does
//  not write, schedule, or notify (tier-1 reminders / tier-2 briefings come next). Dev-button-
//  triggered for now (the scheduler calls the same entry point later).
//
//  Key methods:
//   - findActionItems(from:now:)  → [ActionItem]   (windows to 7 days, requires the vault, runs Codex)
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

    /// How far back the judge looks, and the most items it will ever surface (scarcity = taste).
    static let lookbackDays = 7
    static let maxItems = 5

    enum ProError: LocalizedError {
        case noVault
        case noRecent
        case usageLimit(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .noVault:           return "No knowledge base on disk yet — build it first (the judge needs both the summaries AND the vault)."
            case .noRecent:          return "No summaries in the last \(Proactive.lookbackDays) days — nothing for the proactive judge to consider."
            case .usageLimit(let m): return "Your AI hit its usage limit — try again later. (\(m.prefix(160)))"
            case .failed(let m):     return m
            }
        }
    }

    // MARK: The judge

    /// Find the top action items across the last week of summaries + the live vault. Read-only:
    /// returns the ranked list; it does not wipe, write, or notify. Throws on no-vault / no-recent /
    /// usage-limit / failure so the caller can surface a clear status.
    func findActionItems(from notes: [CloudNote], now: Date = Date()) async throws -> [ActionItem] {
        // 1. Window the summaries to the last N days (each note carries its own item date).
        let cutoff = now.addingTimeInterval(-Double(Self.lookbackDays) * 86_400)
        func itemDate(_ n: CloudNote) -> Date { n.itemDate ?? .distantPast }
        let recent: [CloudNote] = notes
            .filter { itemDate($0) >= cutoff }
            .sorted { itemDate($0) > itemDate($1) }            // newest first
        guard !recent.isEmpty else { throw ProError.noRecent }

        // 2. The vault must exist — the judge MUST use both inputs, and it's the agent's cwd.
        let vault = VaultGenerator.vaultRoot
        guard FileManager.default.fileExists(atPath: vault.path) else { throw ProError.noVault }

        // 3. One read-only Codex call: summaries over stdin, the vault as the working directory.
        var inv = CodexCLI.Invocation(prompt: Self.prompt(recent: recent, now: now))
        inv.effort = .xhigh                 // the deepest pass — this judgment IS the product
        inv.sandbox = .readOnly             // it only reads the vault — never writes or acts
        inv.cwd = vault.path                // working dir = the knowledge base (Read/Glob/Grep)
        inv.outputSchema = Self.schema
        inv.timeout = 1_200                 // high-effort agentic reads over the vault can run long

        Log("Proactive.judge: \(recent.count) summaries in the last \(Self.lookbackDays)d → asking Codex (read-only, vault cwd)…")
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

    private static func prompt(recent: [CloudNote], now: Date) -> String {
        let today = todayString(now)
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        var lines: [String] = []
        lines.reserveCapacity(recent.count)
        for (i, n) in recent.enumerated() {
            let (loc, src) = VaultGenerator.locSrc(kind: n.kind, folder: n.folder, sourceID: n.sourceID)
            let when = n.itemDate.map { df.string(from: $0) } ?? "undated"
            let title = (n.title?.isEmpty == false) ? n.title! : "(untitled)"
            lines.append("#\(i + 1) · [\(src)] \(loc) · \(when)\n\(title) — \(n.text)")
        }

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

        ## YOUR EDGE IS CROSS-SOURCE CONTEXT — this is the whole game
        Everyone else's AI is trapped inside one app. You are not. The very best action items almost \
        never come from one source read in isolation — they emerge when you CONNECT THE DOTS across \
        tools and across the knowledge base. A fragment in one place becomes a high-impact, perfectly \
        grounded action the moment you corroborate and enrich it with everything else you know.

        For EVERY candidate, ask: *what else do I know about this?* Hunt for the same person, project, \
        deadline, place, amount, or commitment appearing in another source or in the vault — then FUSE \
        them. Convergence across sources is gold: it is the action item that no single-app AI could \
        ever find.
        - A WhatsApp/iMessage message mentions a thing → the vault has a note on that exact thing → \
        another tool has related info. Fuse all three.
        - A reminder / renewal / confirmation email arrives → the vault shows why it actually matters \
        to THIS user → it becomes a personalized action instead of inbox noise.
        - The user wrote a to-do in Apple Notes → a message or email shows it's now due or unblocked → \
        surface it now, with the next step.
        - Someone proposes a time in iMessage → the calendar shows the user is free → the action is \
        "reply yes and put it on the calendar."
        - A saved file / bookmark (a form, an application, an event) → a deadline stated or implied \
        elsewhere → the action is "complete it before it closes."

        A signal that exists in only ONE source with nothing else to corroborate or contextualize it \
        is usually weaker — prefer the connected ones, and make the connection explicit.

        ## USE BOTH INPUTS, DEEPLY — and do NOT let email dominate
        1. **The last \(lookbackDays) days of summaries** (at the end of this message), from EVERY \
        source — files, WhatsApp, iMessage, Apple Notes, Calendar, and Gmail. Each line is \
        `#<n> · [source] location · date` then `Title — summary`. Email summaries LOOK action-dense \
        because they spell tasks out — do NOT over-index on them. A promise made in WhatsApp, a to-do \
        written in Notes, a deadline implied by a saved file, a request in iMessage are every bit as \
        important. Actively scan EVERY source and aim for a SPREAD, not five email items.
        2. **The knowledge base** — your working directory IS the user's whole life as an \
        Obsidian-style markdown vault. READ IT DEEPLY with your file tools: start with the root \
        `README.md`, then grep / list / read the notes relevant to each candidate (the people, \
        projects, commitments, preferences, and timelines involved). The vault is what turns a generic \
        signal into a personalized, accurate, high-impact action. NEVER judge importance from the \
        summaries alone — ground every call in who this user actually is and what they're in the \
        middle of.

        ## What an ACTION ITEM is
        Something the user should DO, DECIDE, PREPARE FOR, or BE AWARE OF soon — concrete, time-relevant, \
        and ideally something that could be acted on. Sentient will SOON be able to take these actions \
        for the user (draft and send a reply, fill a form in the browser, schedule a meeting, send a \
        message). For now your job is DETECTION + framing: identify the item and describe the EXACT \
        next action as a precise, ready-to-execute step — so it's ready the instant the action \
        infrastructure ships. Do not actually perform anything; just detect and frame.

        ## Examples of the kinds to look for
        (Illustrative and HYPOTHETICAL — learn the SHAPE and the cross-source reasoning, NOT these \
        specific details. They generalize to any person, topic, and tool. Do not look for these exact \
        scenarios; find the real ones in THIS user's data.)

        - **Overdue reply awaiting the user.** A contact emailed days ago asking the user to do \
        something — an intro, a blurb, a decision — and it's still unanswered; the vault explains who \
        they are and why it matters. ACTION: "Draft the reply (using the vault's context) so it's \
        ready to send." Fuse: Gmail + the vault note on that person/topic.
        - **Cross-tool meeting request.** Someone proposes a time over iMessage/WhatsApp; the calendar \
        shows the user is free then. ACTION: "Reply to confirm and add it to the calendar." Fuse: \
        message + Calendar + the vault note on that person.
        - **A promise the user made.** In a chat the user said they'd send / research / share \
        something, and another source or the vault shows that thing now exists or is ready. ACTION: \
        "Send what you promised — it's ready." Fuse: WhatsApp + the research/file it lives in.
        - **A deadline with a form to complete.** The user saved/bookmarked or got an email about an \
        application, registration, or renewal that closes soon, and the vault holds the details the \
        form needs (name, school, what they're building, etc.). ACTION: "Complete the registration \
        before it closes (a browser agent can fill it from your vault facts)." Fuse: saved file / \
        reminder email + a stated/known deadline + vault facts.
        - **A renewal / expiry / payment.** A reminder email or saved document points to something \
        expiring (a domain, subscription, membership, document); the vault confirms the user actually \
        relies on it. ACTION: "Renew or cancel before <date>." Fuse: Gmail/file + vault.
        - **A to-do the user wrote themselves.** The user noted a task in Apple Notes and another \
        source shows it's now due or unblocked. ACTION: surface it with the concrete next step. Fuse: \
        Notes + the corroborating source.
        - **A plan forming across people.** A group chat is brainstorming something (a trip, an event, \
        a decision); combined with everything the vault knows about the user, you can assemble the \
        concrete plan. ACTION: "Here's the plan — shall I share it with the group?" Fuse: group chat + \
        vault preferences/history.

        These are starting patterns, not a checklist — the biggest wins are the cross-source items you \
        discover that no template predicted.

        ## Hard accuracy rules (non-negotiable)
        - NEVER invent a date, name, fact, or deadline. If there's no real date, set `due_date` to "".
        - Every action item MUST trace to real evidence in the summaries and/or the vault — and you \
        must cite that evidence in `sources`.
        - ATTRIBUTION: other people's plans, jobs, and tasks are THEIRS, not the user's. Only surface \
        what is genuinely the user's to act on. (When someone introduces themselves in a group, that's \
        about THEM, not the user.)
        - NO raw private specifics (card / account numbers, passwords, exact medical or financial \
        figures).
        - A confident wrong item is far worse than a missed one.

        ## Rank, then cut
        Rank by (impact to THIS user) × (time-sensitivity) × (how clearly actionable it is). Strongly \
        favor cross-source items grounded in the vault. Return AT MOST \(maxItems). Return FEWER — even \
        zero — if there genuinely aren't that many worth surfacing. NEVER pad. Two perfect cross-source \
        items beat five shallow single-source ones, and aim for a SPREAD across sources — not five from \
        the same place.

        ## Output
        Return ONLY the structured object defined by the output schema — no prose around it. For each \
        action item:
        - **title** — a short, specific, human headline (≤ ~8 words), like a great notification.
        - **action** — the EXACT next step, addressed to the user ("Reply to…", "Register for…", \
        "Send the…", "Renew…"), written as something ready to execute.
        - **importance** — WHY this matters to THIS user right now, and explicitly NAME THE DOTS YOU \
        CONNECTED: which sources and which vault notes, and what each one contributed. This is where \
        your cross-source intelligence must visibly show.
        - **due_date** — the real relevant date in plain words ("June 20, 2026", "this Friday"), or "" \
        if there genuinely is none.
        - **sources** — the concrete evidence you fused, each item by name (e.g. "WhatsApp · Dad", \
        "Vault · People/Dad.md", "Notes · running gear", "Calendar"). Show the cross-source provenance \
        here.
        - **urgency** — "high", "medium", or "low".

        The last \(lookbackDays) days of summaries follow.

        ---

        \(lines.joined(separator: "\n\n"))
        """
    }

    private static func todayString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .none; return f.string(from: d)
    }
}
