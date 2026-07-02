//
//  ProactiveResearch.swift
//  Sentient OS macOS
//
//  Proactive Intelligence — PART 2 of 3: RESEARCH & PREPARE (Arch §6), the heart of the feature.
//  PART 1 (Proactive.swift) finds the top action items from the summaries alone. PART 2 (this file)
//  does two things, in order, for each item — all READ-ONLY, in ONE agentic pass:
//    1. VERIFY it against the LIVE world (the Gmail MCP if connected + web + the knowledge base) —
//       prove it's still real, still the user's, still needed; DROP the stale/done/expired ones.
//    2. PREPARE every survivor to be READY TO FIRE — draft it in the user's voice + write the exact
//       execution recipe — so PART 3 (the executor) runs it on the user's one-button press.
//
//  Merging verify + prepare into one pass avoids re-reading the same thread/vault twice, and keeps
//  the WHOLE read-only/safe world in Parts 1–2 — the single write-capable step is PART 3.
//
//  THE TWO INVARIANTS (both enforced in the prompt AND the invocation):
//    • Accuracy: receipts-only, never fabricate; "couldn't confirm" → `unverified` is a valid outcome.
//    • Never fire: it stages but NEVER sends/submits/pays/RSVPs. `bypassApprovals = false` + sandbox
//      means a connector WRITE would auto-cancel headless anyway (codex/Gmail permissioning findings).
//
//  Output: ready-to-fire `PreparedAction`s (carrying the verify verdict + the prepared draft + a
//  deterministic `execution_recipe` — the routing contract PART 3's executor runs)
//  plus the `dropped` items. Verify-only on discovery: it never invents a NEW item (that's PART 1).
//
//  Key methods:
//   - researchAndPrepare(items:now:)  → ReadyResult   (verifies + stages PART 1's items, runs Codex)
//
//  Doc: Documentation/Proactive Intelligence (Judge).md  (PART 2 section)
//

import Foundation

/// One PART 1 action item after PART 2 — VERIFIED against the live world and STAGED ready to fire.
/// Carries the verify verdict (`status` + `verification`) plus everything PART 3 needs to execute it:
/// the human-facing card, the reviewable draft, and the deterministic recipe. Sendable value type the
/// For You UI + PART 3 (the executor) consume.
struct PreparedAction: Sendable, Identifiable, Codable {
    let title: String
    let method: Method             // the ONE channel PART 3 fires this through (model-picked)
    let target: String             // the app/site this acts in, for the card kicker ("LinkedIn",
                                   // "Notion"); "" for gmail/calendar/research (the method names itself)
    let urgency: ActionItem.Urgency
    let dueDate: String?
    let status: Status             // the verify verdict (confirmed / updated / unverified)
    let verification: String       // WHAT was checked + WHAT each live source said (receipts)
    let cardSummary: String        // human-facing: what this is + what the fire button will do
    let preparedContent: String    // the VERBATIM sendable artifact the user reviews + EDITS (the drafted
                                   // email/message/event/briefing) — the single source of truth the
                                   // executor sends; the user's edits to this are what actually fire
    let executionRecipe: String    // ROUTING ONLY: which thread/recipient/chat/app/URL + which field
                                   // takes which content. References preparedContent, never duplicates
                                   // the body. "none" for research.
    let buttonText: String         // LLM-written fire CTA ("Should I send it for you?"); "" = no fire (research)
    let detailLabel: String        // LLM-written "read the …" link ("read the draft", "read the brief")
    let sources: [String]          // grounding receipts (vault notes, the thread, web results)
    let reviewNote: String         // what to double-check/decide before firing; "" if fully ready

    enum Status: String, Sendable, Codable { case confirmed, updated, unverified }

    /// The ONE channel PART 3 fires this action through — the model picks it. Folds the old seven
    /// kinds: email_reply/email_new → .gmail · message → .computer (sends via Messages/WhatsApp) ·
    /// reminder → .research (surfaced, no fire). `research` carries no fire (`executionRecipe == "none"`).
    enum Method: String, Sendable, Codable {
        case computer   // drives the Mac via codex computer use — native apps, sending a chat message,
                        // AND logged-in website tasks (register/RSVP/buy/fill a form) via the real browser
        case gmail      // the user's Gmail MCP via codex
        case calendar   // the user's Calendar MCP via codex
        case research   // informational briefing — nothing to fire
    }
    var id: String { title }
}

/// A PART 1 item that PART 2's verify half killed (already handled / expired / cancelled / a misread),
/// with the reason the live source gave.
struct DroppedItem: Sendable, Identifiable, Codable {
    let title: String
    let reason: String
    var id: String { title }
}

/// The PART 2 result: the survivors staged ready to fire (`ready`) + what verification dropped
/// (`dropped`). For You shows `ready`; PART 3 fires one of them on the user's press.
struct ReadyResult: Sendable, Codable {
    let ready: [PreparedAction]
    let dropped: [DroppedItem]
}

actor ProactiveResearch {

    static let shared = ProactiveResearch()

    /// The most ready cards PART 2 ever returns. It verifies PART 1's wider net (up to 8) and prunes
    /// to the strongest few — scarcity is taste. Enforced in the prompt AND as a code backstop.
    static let maxReady = 5

    enum ResError: LocalizedError {
        case noItems
        case noVault
        case usageLimit(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .noItems:           return "No action items to work — run PART 1 (\u{201C}proactive system\u{201D}) first."
            case .noVault:           return "No knowledge base on disk yet — build it first (research + prepare read the vault for context + the user's voice)."
            case .usageLimit(let m): return "Your AI hit its usage limit — try again later. (\(m.prefix(160)))"
            case .failed(let m):     return m
            }
        }
    }

    // MARK: Research & prepare

    /// PART 2 — verify then prepare, in one read-only pass. For each PART 1 item: prove it's still real
    /// against the live sources (Gmail MCP if connected + web) and the knowledge base, dropping the
    /// stale ones; then stage every survivor ready to fire (draft in the user's voice + the execution
    /// recipe). Read-only — it researches and stages, it NEVER fires. Verify-only — it never adds a new
    /// item. Returns the ready + dropped split; throws on no-items / no-vault / usage-limit / failure.
    func researchAndPrepare(items: [ActionItem], notes: [CloudNote] = [], now: Date = Date(),
                            calendarContext: String? = nil) async throws -> ReadyResult {
        guard !items.isEmpty else { throw ResError.noItems }
        let recent = Proactive.recent(from: notes, now: now)   // the SAME last-week corpus PART 1 saw

        // The vault is a research surface, the source of the user's voice + the facts a draft/form
        // needs, AND the agent's cwd (Read/Glob/Grep over the knowledge base).
        let vault = VaultGenerator.vaultRoot
        guard FileManager.default.fileExists(atPath: vault.path) else { throw ResError.noVault }

        var inv = CodexCLI.Invocation(prompt: Self.prompt(items: items, recent: recent, now: now, calendarContext: calendarContext))
        inv.effort = .high                  // gpt-5.5 → high (accuracy + the prepared draft are the product)
        inv.sandbox = .readOnly             // verifies + stages — never sends, drafts into a provider, or acts
        inv.cwd = vault.path                // working dir = the knowledge base (a research surface + the voice)
        inv.webSearch = true                // ground external facts (on-sale/event dates, deadlines, form fields)
        inv.includeUserConfig = true        // load the user's MCP servers — the Gmail MCP (read-only)
        inv.bypassApprovals = false         // ⚠️ load-bearing: NO fire — a connector write auto-cancels
        inv.outputSchema = Self.schema
        inv.timeout = 1_800                 // agentic verify + prepare (Gmail + web + vault) over ≤5 items runs long

        Log("ProactiveResearch: verify + prepare \(items.count) item(s) → Codex (read-only, vault cwd, Gmail MCP + web, never fire)…")
        do {
            let env = try await CodexCLI.shared.run(inv)
            let parsed = Self.parse(env.result)
            // Backstop the prompt's prune: PART 2 returns at most maxReady (5) of the strongest cards.
            let result = ReadyResult(ready: Array(parsed.ready.prefix(Self.maxReady)), dropped: parsed.dropped)
            Log("ProactiveResearch: ✅ ready \(result.ready.count), dropped \(result.dropped.count) (turns \(env.numTurns ?? -1), \(env.outputTokens ?? -1) out-tokens)")
            for (i, a) in result.ready.enumerated() {
                Log("  READY #\(i + 1) [\(a.method.rawValue)\(a.target.isEmpty ? "" : " · \(a.target)") · \(a.status.rawValue)\(a.dueDate.map { " · due \($0)" } ?? "")] \(a.title)\n      button: \(a.buttonText.isEmpty ? "(none)" : a.buttonText) · link: \(a.detailLabel)\n      card: \(a.cardSummary)\n      checked: \(a.verification)\n      content: \(a.preparedContent)\n      recipe: \(a.executionRecipe)\n      review: \(a.reviewNote.isEmpty ? "(none — fully ready)" : a.reviewNote)\n      src: \(a.sources.joined(separator: " | "))")
            }
            for d in result.dropped {
                Log("  DROP \(d.title) — \(d.reason)")
            }
            Self.saveLatest(result)
            return result
        } catch let CodexCLI.CLIError.usageLimit(message, _) {
            throw ResError.usageLimit(message)
        } catch {
            throw ResError.failed("\(error)")
        }
    }

    // MARK: Last-run persistence (for the For You surface / a dev viewer)

    private static let latestKey = "proactive.latestReady"

    /// Persist the most recent run (Codable → UserDefaults JSON) so the For You surface / a dev viewer
    /// can show the ready-to-fire cards without re-running, and across app launches.
    static func saveLatest(_ result: ReadyResult) {
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: latestKey)
        }
    }

    /// The most recent run (nil if it never ran).
    static func latest() -> ReadyResult? {
        guard let data = UserDefaults.standard.data(forKey: latestKey),
              let result = try? JSONDecoder().decode(ReadyResult.self, from: data) else { return nil }
        return result
    }

    /// Forget the last prepared deck (the dev "Reset everything" path) — the home's "For You" empties.
    static func clear() { UserDefaults.standard.removeObject(forKey: latestKey) }

    // MARK: Output schema (the `--output-schema` contract)

    private static let schema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "ready":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{\
    "title":{"type":"string"},\
    "method":{"type":"string","enum":["computer","gmail","calendar","research"]},\
    "target":{"type":"string"},\
    "urgency":{"type":"string","enum":["high","medium","low"]},\
    "due_date":{"type":"string"},\
    "status":{"type":"string","enum":["confirmed","updated","unverified"]},\
    "verification":{"type":"string"},\
    "card_summary":{"type":"string"},\
    "prepared_content":{"type":"string"},\
    "execution_recipe":{"type":"string"},\
    "button_text":{"type":"string"},\
    "detail_label":{"type":"string"},\
    "sources":{"type":"array","items":{"type":"string"}},\
    "review_note":{"type":"string"}},\
    "required":["title","method","target","urgency","due_date","status","verification","card_summary","prepared_content","execution_recipe","button_text","detail_label","sources","review_note"]}},\
    "dropped":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{\
    "title":{"type":"string"},\
    "reason":{"type":"string"}},\
    "required":["title","reason"]}}},\
    "required":["ready","dropped"]}
    """

    // MARK: Tolerant parse (output-schema makes `result` the JSON; still fence-safe)

    private static func parse(_ result: String) -> ReadyResult {
        let span: String
        if let s = result.firstIndex(of: "{"), let e = result.lastIndex(of: "}"), s < e {
            span = String(result[s...e])
        } else { span = result }
        guard let data = span.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ReadyResult(ready: [], dropped: [])
        }
        let ready: [PreparedAction] = (obj["ready"] as? [[String: Any]] ?? []).compactMap { d in
            guard let title = (d["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let due = (d["due_date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PreparedAction(
                title: title,
                method: PreparedAction.Method(rawValue: (d["method"] as? String)?.lowercased() ?? "research") ?? .research,
                target: ((d["target"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                urgency: ActionItem.Urgency(rawValue: (d["urgency"] as? String)?.lowercased() ?? "medium") ?? .medium,
                dueDate: (due?.isEmpty == false) ? due : nil,
                status: PreparedAction.Status(rawValue: (d["status"] as? String)?.lowercased() ?? "unverified") ?? .unverified,
                verification: (d["verification"] as? String) ?? "",
                cardSummary: (d["card_summary"] as? String) ?? "",
                preparedContent: (d["prepared_content"] as? String) ?? "",
                executionRecipe: (d["execution_recipe"] as? String) ?? "",
                buttonText: ((d["button_text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                detailLabel: ((d["detail_label"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                sources: (d["sources"] as? [String]) ?? [],
                reviewNote: (d["review_note"] as? String) ?? "")
        }
        let dropped: [DroppedItem] = (obj["dropped"] as? [[String: Any]] ?? []).compactMap { d in
            guard let title = (d["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            return DroppedItem(title: title, reason: (d["reason"] as? String) ?? "")
        }
        return ReadyResult(ready: ready, dropped: dropped)
    }

    // MARK: The prompt — verify THEN prepare, accuracy-obsessed, never fires

    private static func prompt(items: [ActionItem], recent: [CloudNote], now: Date, calendarContext: String?) -> String {
        let today = todayString(now)
        var lines: [String] = []
        lines.reserveCapacity(items.count)
        for (i, it) in items.enumerated() {
            lines.append("""
            #\(i + 1) · [\(it.urgency.rawValue)] \(it.title)
               Proposed action: \(it.action)
               Why PART 1 flagged it: \(it.importance)
               Claimed due date: \(it.dueDate ?? "none stated")
               Cited summaries: \(it.sources.isEmpty ? "—" : it.sources.joined(separator: ", "))
            """)
        }

        // The user's LIVE calendar (last 7 days + next 24h, ALL events), pre-fetched as text. A
        // grounding surface for verify/prepare — confirm free/busy, an event's real time, what's
        // imminent. Only present when Calendar is connected (CalendarConnect.fetchProactiveContext).
        let calendarBlock: String = {
            guard let ctx = calendarContext?.trimmingCharacters(in: .whitespacesAndNewlines), !ctx.isEmpty else { return "" }
            return """

            ## THE USER'S LIVE CALENDAR (every event — last 7 days + next 24 hours)
            The user's actual calendar right now (already fetched for you). Use it as a grounding \
            surface: confirm whether the user is free/busy at a proposed time, get an event's real \
            date/time right, see what's imminent, or catch that an item is already on the calendar. \
            Treat it as receipts (it came from the live calendar). You may still call your Calendar \
            tool to read a specific event in more detail if one is connected.

            \(ctx)
            """
        }()

        // The FULL last-week summary corpus — the exact context PART 1 saw. PART 2 now gets it too, so it
        // can understand each item in full context instead of only PART 1's one-line distillation.
        let summariesBlock: String = {
            guard !recent.isEmpty else { return "" }
            return """

            ## THE FULL LAST-WEEK CONTEXT — the SAME summaries PART 1 saw
            Below is the ENTIRE corpus of the user's last \(Proactive.lookbackDays) days of summaries \
            across every source — the exact context PART 1 read when it picked the items. Use it as deep \
            background: understand each item in its full context, notice related signals PART 1 didn't \
            spell out, pull in extra facts a draft needs, and ground your verification. These are \
            distilled summaries (already PII-stripped), NOT live data — still confirm time-sensitive \
            facts against the live sources (Gmail, web, calendar). The items to work follow after.

            \(Proactive.summaryLines(recent))
            """
        }()

        return """
        You are the **Research & Prepare** step of Sentient OS's Proactive Intelligence — PART 2 of 3, \
        and the heart of the feature. PART 1 read the user's last week across every source and picked \
        the handful of ACTION ITEMS that *might* deserve their attention — but those were inferred from \
        short summaries that can be stale or imprecise. For EACH item you do two things, in order:

        1. **VERIFY** it against the LIVE world — prove it's still real, still the user's to do, and \
        still needed; get every detail exactly right, or DROP it.
        2. **PREPARE** every survivor to be **ready to fire** — draft it in the user's own voice and \
        write the exact recipe — so that in PART 3 the user taps ONE button and it executes with \
        nothing left to decide or look up.

        Today is \(today).

        ## TWO INVIOLABLE RULES
        **1 — Total accuracy, ZERO fabrication.** The user will ACT on what you produce, so a confident \
        wrong answer is catastrophic, far worse than admitting uncertainty.
        - **Receipts only.** State a fact about the live world ONLY if a tool you actually called this \
        run returned it — point to the receipt (the specific email you read, the specific web result). \
        No receipt → not a fact.
        - **Never fabricate** a tool result, an email, a thread, a date, a price, a link, an address, or \
        a status. If you didn't see it with a tool, it didn't happen.
        - **"Couldn't confirm" is a valid, expected, GOOD outcome** (→ `status: unverified`). Honest \
        uncertainty always beats invented certainty.
        - **Identity-match every external fact** — only accept a Gmail/web result that clearly concerns \
        the user's *specific* thing (right person, org, event, place, time), cross-checked against the \
        knowledge base. Generic or ambiguous → reject it.

        **2 — You PREPARE, you do NOT fire.** You verify, draft, gather, and stage — you NEVER perform \
        the irreversible action: never send an email or message, submit a form, pay, RSVP, book, post, \
        or confirm anything. Every outward action waits for the user's explicit press in PART 3. If you \
        feel the pull to "just send it to be helpful" — do not. Staging it perfectly IS the job.

        ## YOUR SURFACES (all READ-ONLY — you only gather, never act)
        You ALSO have the **full last-week summary corpus** (at the end of this message — the same \
        context PART 1 saw) as background. Beyond that, gather live from:
        1. **The knowledge base** — your working directory IS the user's whole life as an Obsidian-style \
        markdown vault. Read the root `README.md`, then grep/read the notes about the people, projects, \
        and commitments involved. It's three things at once: your **identity anchor** (is a Gmail/web \
        result really the user's thing?), the user's **VOICE** (how they actually write), and the \
        **facts** a reply or form needs. Use it heavily.
        2. **Gmail — via the Gmail MCP, IF connected.** Read the *actual current* thread: already \
        replied/handled? resolved, cancelled, expired? deadline passed? **READ ONLY — never send, \
        draft, reply, label, archive, or modify.** No Gmail tool available → skip gracefully, say so, \
        mark `unverified` — never pretend.
        3. **Web search** — ground external facts (on-sale/event dates, deadlines, hours, price, a \
        form's required fields, what a registration page asks for), identity-matched. **Look up only — \
        never submit/pay/confirm.**
        If a tool you'd need isn't available, go as far as you can and say in `review_note`/the recipe \
        what the fire step will have to handle.

        ## PER ITEM: VERIFY → then PREPARE
        Work the items ONE AT A TIME.

        **First, verify.** Read the vault for context, check the right live source, and decide a verdict:
        - **dropped** — already handled, expired/past, cancelled, or a misread of the summary → drop it \
        with the reason. When a live source contradicts the item, DROP it — never surface stale urgency.
        - **survives** — it's real. Set `status`: **confirmed** (verified current), **updated** (real, \
        but you corrected a detail — apply the correction), or **unverified** (couldn't confirm with \
        tools, but no evidence it's stale either).

        **Then prepare every survivor** to ready-to-fire:
        - Gather everything the action needs — the thread, the form's fields, the facts — until nothing \
        is missing.
        - Compose `prepared_content`: the VERBATIM artifact the user reviews/approves/EDITS — and that \
        fires exactly as written — in the user's own voice wherever it's something they'd say.
        - Write `execution_recipe`: ROUTING only (where the action goes), referencing `prepared_content` \
        — never restate the message body in the recipe.
        - If something irreversible genuinely can't be resolved (an unknown recipient, a real either/or \
        choice), prepare everything else and put exactly what the user must check/decide in \
        `review_note` — never guess on the irreversible specifics.

        ## VERIFY-ONLY ON DISCOVERY
        You work ONLY the items handed to you below. **Never invent a brand-new action item** — \
        discovery already happened in PART 1.

        ## THE FOUR METHODS (set `method`) — pick the ONE channel that fires this action
        You decide HOW Sentient carries out each action. Pick exactly one method:
        - **gmail** — anything in the user's email (a reply or a brand-new message). \
        `prepared_content` = the full draft (subject + body); `execution_recipe` = recipient(s) + the \
        exact thread it belongs to.
        - **calendar** — add or change an event on the user's calendar. `prepared_content` = the event \
        the user reviews (title, start/end, attendees, notes); `execution_recipe` = those fields, structured.
        - **computer** — drives the user's Mac directly (their own computer use): act in a native \
        desktop app (e.g. Notion), SEND a WhatsApp / iMessage (via the Messages app), OR do a task on a \
        WEBSITE the user is already logged into by driving their real browser (register, RSVP, fill an \
        application, buy, post on X/LinkedIn/Reddit/Amazon/GitHub). `prepared_content` = the exact \
        text/values the user reviews; `execution_recipe` = which app or URL + which chat/where + ordered \
        steps (and which field takes which value for a web form). (The fire step NEVER uses \
        AppleScript/Terminal — only computer use.)
        - **research** — informational only: write the briefing the user wanted (a trip plan, a \
        comparison, prepped notes for a call). Nothing fires — `execution_recipe` = "none", \
        `button_text` = "".

        **Which method:** email → **gmail**; calendar events → **calendar**; everything Sentient ACTS \
        on for the user — a native Mac app, a chat message (WhatsApp/iMessage via Messages), or a \
        logged-in website — → **computer**. A real task only the user can do by hand with nothing to \
        automate (e.g. a phone call) → **research** (surface it; don't drop it).

        ## ACCURACY & VOICE (this will go out under the user's name)
        - Ground every draft and every field value in real evidence (the vault, the thread, verified \
        facts). NEVER invent an address, a name, a date, or a form value — if you don't have it, say so \
        in `review_note`.
        - Match the user's voice and norms from the vault — greeting, formality, sign-off, how they \
        actually write. The draft must read like THEY wrote it, not like an AI.
        - Never stage anything the user wouldn't want sent (private specifics that don't belong, guesses \
        dressed up as fact). For an `unverified` item, flag the unverified part in `review_note`.

        ## OUTPUT
        Return ONLY the structured object defined by the schema — no prose around it.
        `ready` — the survivors, each staged to fire. For each:
        - **title** — short, specific headline (≤ ~8 words).
        - **method** — one of the four above (the single channel that fires this).
        - **target** — the app or website this acts in, as a short brand name for the card label \
        ("LinkedIn", "Notion", "Amazon"). REQUIRED for **computer**; leave "" for \
        gmail / calendar / research (the method names itself).
        - **urgency** — "high" / "medium" / "low".
        - **due_date** — the real VERIFIED date in plain words, or "" if none / unverified.
        - **status** — "confirmed" / "updated" / "unverified".
        - **verification** — a tight account of WHAT you checked and WHAT each live source said, with \
        receipts, separating what you VERIFIED from what remains inferred.
        - **card_summary** — one or two lines the user reads in For You: what this is + what the button \
        will do ("Send this reply to Dana confirming Thursday").
        - **prepared_content** — the EXACT artifact that will be sent/used, in the user's own voice. \
        This is what the user reviews AND CAN EDIT, and this is what fires VERBATIM — so make it \
        complete and final: the full email subject+body, the full message text, the event details, or \
        the briefing write-up. (Edits the user makes here are exactly what gets sent.)
        - **execution_recipe** — ROUTING ONLY: where the action goes, not its words. Recipient(s) + the \
        exact thread for **gmail**; the structured event fields for **calendar**; for **computer**, the \
        app or URL + which chat/where + ordered steps (and which field takes which value for a web \
        form). Do NOT restate the message body here — it lives in `prepared_content` and is sent from \
        there. "none" for research.
        - **button_text** — the one-tap fire button's label, specific to THIS action and in the user's \
        framing ("Should I send it for you?", "Reply & add it to your calendar?", "Register me?"). \
        Leave "" for research (it has no fire button).
        - **detail_label** — the quiet link that opens the full draft to read/edit ("read the draft", \
        "read the brief", "read the prep doc").
        - **sources** — the evidence you relied on, each by name, incl. what you verified against (e.g. \
        "Gmail · thread with Dana (6/16)", "Web · venue on-sale page", "Vault · People/Dana.md").
        - **review_note** — what (if anything) the user should double-check/decide before firing; "" if \
        fully ready.
        `dropped` — the items verification killed: **title** + **reason** (what the live source showed).

        You receive up to 8 candidate items. Return AT MOST \(Self.maxReady) READY cards — the \
        strongest, most useful, most time-sensitive of what survives. Dropping a stale item is a \
        success, not a failure; and if MORE than \(Self.maxReady) survive verification, keep only the \
        \(Self.maxReady) strongest and cut the rest. Prepare everything you keep right up to the fire \
        line, and stop there.

        \(calendarBlock)
        \(summariesBlock)
        The action items to research and prepare follow.

        ---

        \(lines.joined(separator: "\n\n"))
        """
    }

    private static func todayString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .none; return f.string(from: d)
    }
}
