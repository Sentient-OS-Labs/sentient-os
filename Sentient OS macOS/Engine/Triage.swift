//
//  Triage.swift
//  Sentient OS macOS
//
//  The on-device "bouncer". The model is asked to write the SUMMARY first (so it
//  actually understands the file before judging), THEN a short title, THEN the junk flag, and
//  only-if-applicable a sensitive flag. We parse that compact JSON and map it to a
//  Verdict + the model's title/summary (Outcome).
//
//  FAIL-CLOSED: anything we can't confidently parse is treated as JUNK (dropped), never a
//  survivor — so a malformed parse can never leak content into the cloud vault. Sensitivity
//  regex backstops are a pre-launch hardening task; for now we trust the model's flag.
//

import Foundation

enum Triage {

    // MARK: Prompt

    /// Dispatches to a source-flavored prompt: a file judges one document (Apple Notes ride the
    /// same path — a note IS a document the user wrote); chat sources judge a CONVERSATION
    /// WINDOW — with a dedicated, far stricter prompt for GROUP chats (attribution is the hard
    /// part). All emit the SAME JSON contract, so parse()/decide() are shared & unchanged.
    static func prompt(for artifact: Artifact, currentDate: Date) -> String {
        if artifact.kind == .file || artifact.kind == .notes {
            return filePrompt(for: artifact, currentDate: currentDate)
        }
        return artifact.metadata["isGroup"] == "1"
            ? groupChatPrompt(for: artifact, currentDate: currentDate)
            : chatPrompt(for: artifact, currentDate: currentDate)
    }

    private static func filePrompt(for artifact: Artifact, currentDate: Date) -> String {
        let today = Self.dateString(currentDate)
        let path = artifact.metadata["displayPath"] ?? artifact.metadata["name"] ?? artifact.id
        let created = artifact.metadata["created"] ?? "unknown"

        let body: String
        if artifact.imageData != nil {
            body = "The file is the attached image."
        } else if let text = artifact.text, !text.isEmpty {
            body = "File content (may be truncated):\n\"\"\"\n\(text)\n\"\"\""
        } else {
            body = "(No readable text content — judge from the path and dates.)"
        }

        return """
        You curate a user's personal knowledge base: a vault of what genuinely matters in their life, for their AI to draw on. You see one file at a time. Write a short summary of what it is, then decide whether it belongs in the knowledge base.

        IMPORTANT: flagging a file as junk ONLY keeps it out of the knowledge base — the file is NEVER deleted or moved, it stays exactly where it is on disk. So judge purely on "is this worth having in a curated vault of the user's life?", not on whether they should keep the file. People save FAR more than is worth remembering — a Downloads folder is mostly junk for a knowledge base even though the files are fine to leave on disk.

        Today is \(today).
        File path: \(path)
        File created: \(created)
        \(body)

        Write the summary FIRST (understand the file), then judge it. Reply with ONLY a compact JSON object (no markdown, no extra text), with keys in EXACTLY this order:

        {"summary":"<~30 words: what this file is>","title":"<short 3-6 word title>","junk":<true|false>}

        Then append this key ONLY IF it applies:
          ,"sensitive":true  — only if it holds highly sensitive data that must never be stored anywhere (SSN, passport/ID, full card numbers, passwords, sensitive medical records)

        Guidance:
        - title: a short human title, e.g. "UMass Tech Challenge Award".
        - junk: true when a file isn't worth keeping in a curated vault of the user's life (it stays on disk either way). Clear junk: installers & setup files, one-off or random downloads, memes & throwaway images, duplicates, boilerplate or generic documents, expired or now-irrelevant content. Be willing to flag — much of a Downloads folder isn't vault-worthy. But judge by whether the CONTENT genuinely matters, not by file type: a meaningful receipt, booking, ticket, or confirmation can be valuable life context worth keeping; only a trivial one is junk.
        """
    }

    /// The 1:1 (DM) conversation bouncer. The other party is a single known person, so attribution
    /// is easy; the job is mostly "is anything here durable life-knowledge about the user or theirs?"
    private static func chatPrompt(for artifact: Artifact, currentDate: Date) -> String {
        let head = """
        You curate a person's private knowledge base — a vault of what genuinely matters in their life, for their AI to draw on. You're shown ONE slice of a 1:1 (direct message) conversation. Decide whether anything here is worth remembering.

        WHO IS WHO: the user (whose knowledge base this is) is ONLY the person labelled "Me". The other party is someone else — when THEY say "I" / "my", that's THEM, never the user. Attribute every fact to the right person.

        Be RUTHLESS. The VAST majority of messaging is ephemeral and worth NOTHING — greetings, reactions, "ok"/"haha", banter, logistics that won't matter tomorrow. DEFAULT TO JUNK. Only keep genuinely DURABLE life-knowledge: concrete plans & commitments, decisions, meaningful facts about the user or the people in their life, recommendations (books / places / products), bookings / contact details, and dates / deadlines / appointments. Set a HIGH bar — would this be worth surfacing to the user months from now? Do NOT record trivial possessions or throwaway remarks.
        """
        return head + "\n\n" + chatJudgingTail(for: artifact, currentDate: currentDate)
    }

    /// The GROUP-chat bouncer — far stricter. In a group most voices are OTHER people (intros, AMAs,
    /// debates, pitches), so ATTRIBUTION is the dangerous part: never absorb someone else's life into
    /// the user's. The window header states how many of the messages were actually the user's.
    private static func groupChatPrompt(for artifact: Artifact, currentDate: Date) -> String {
        let head = """
        You curate a person's private knowledge base — a vault of what genuinely matters in THIS user's life, for their AI to draw on. You're shown ONE slice of a GROUP chat. Decide whether anything here is worth remembering ABOUT THE USER.

        ATTRIBUTION IS THE #1 RULE — getting it wrong POISONS the vault. The user is ONLY the person labelled "Me". EVERY other name is a DIFFERENT person. The header above the conversation says how many messages in this slice were actually the user's ("Me") — READ IT. If "Me" sent few or none, the user was a BYSTANDER and this slice is almost certainly JUNK.

        Group chats are full of introductions, AMAs, and people pitching themselves. When ANYONE other than "Me" says "I" / "my" / "I'm building" / "my background" / "my goal" — that is THEM describing THEMSELVES; it is NEVER a fact about the user. DO NOT absorb other people's biographies, jobs, projects, opinions, or goals into the user's profile. A fact is "about the user" ONLY if "Me" stated it about themselves, or someone explicitly addressed/named the user.

        PARTICIPATING IS NOT THE SAME AS IT BEING ABOUT THE USER — even when the user sends MANY messages. Asking questions, debating, reacting, or showing curiosity about a topic does NOT make that topic the user's work, job, expertise, or even a durable interest. A common failure is fusing a talkative GUEST's identity onto the user: if someone gives a detailed first-person introduction and "Me" replies with questions, the model wrongly writes the GUEST's biography as the user's.
        ILLUSTRATIVE EXAMPLE (made-up — learn the PATTERN, it generalises to any person and any topic): a guest in the group says "I'm a marine biologist and I run a coral-restoration startup", and "Me" asks them how they got funding. The ONLY correct answer is JUNK. WRONG: "the user is a marine biologist / runs a coral-restoration startup" (that's the GUEST), "the user is being interviewed" (the GUEST is), "the user is interested in coral restoration" (merely discussing a topic is not durable). The rule, for ANY subject: NEVER write "the user is / does / builds / works on / is interested in X" unless "Me" plainly stated X about their OWN life or work.

        KNOWN false attributions (real recurring errors — these are OTHER members of the user's groups, NEVER the user): a "soft rock geologist" / a geologist of any kind, and anyone "building voice agents" (e.g. "at 11x"/"111x"). If a summary would call the user a geologist or say the user builds voice agents, it has absorbed someone else's identity → that window is JUNK.

        DEFAULT HARD TO JUNK — much harder than a 1:1 chat. The user "discussing", "asking about", "expressing interest in", "sharing an opinion on", or "being involved in a discussion about" ANY topic is JUNK — and this is true EVEN when the discussion is long, technical, or substantive. Depth of participation does NOT turn a topic into a durable fact about the user. The bar for a keeper is a CONCRETE FACT ABOUT THE USER'S ACTUAL LIFE: who they are, where they are, what they DECIDED or COMMITTED to, what HAPPENED to or for them, their relationships and plans (with dates). If the only thing you can say is "the user discussed / is interested in / has an opinion about X", that is JUNK. Ambient banter, other people's intros / opinions / debates, and links nobody acted on → JUNK.
        """
        return head + "\n\n" + chatJudgingTail(for: artifact, currentDate: currentDate)
    }

    /// Shared tail for both chat prompts: the data, the privacy/sanitise rule, and the EXACT JSON
    /// output contract (so parse()/decide() stay shared across DM, group, and files).
    private static func chatJudgingTail(for artifact: Artifact, currentDate: Date) -> String {
        let today = Self.dateString(currentDate)
        // Backstop: keep the conversation under the KV cache so the prompt can never be rejected as
        // "too long" (near-always a no-op — a normal window is far below `maxConversationBytes`).
        let conversation = ChatWindowing.clampToContext(artifact.text ?? "(empty conversation)")
        return """
        Nothing is ever deleted from the device — "junk" only means "don't add this to the vault". Today is \(today).

        \(conversation)

        Write the summary FIRST — and ALWAYS write something here, because articulating what's in the slice forces you to actually READ it before you judge. If there ARE durable keepers, the summary IS those keepers (framed as durable facts about the user's life; name each if there are several — it may run a bit longer than one line). If there is NOTHING durable, the summary is a brief one-line note of what the slice was actually about (e.g. "Group banter about wearable tech; 'Me' only reacted" or "Logistics about dinner timing"). Either way, write it FIRST, then judge. Write in the THIRD PERSON: call the user 'the user' (or 'they') — NEVER write 'Me' as if it were a name; 'Me' is only the transcript's label for the user's own lines.

        PRIVACY — this is critical: the summary you write is KEPT and may be shared with the user's other AIs, so it must NEVER contain raw private specifics — card / SSN / passport / account numbers, passwords, exact medical specifics (diagnoses, procedures), or exact financial figures (amounts, valuations, salaries). When a conversation mixes useful info WITH private specifics, summarize ONLY the useful, non-private parts and simply OMIT the private specifics — and do NOT mark it sensitive. (E.g. a relative's surgery details + a birthday + a book recommendation → summarize the birthday and the recommendation, leave the medical details out, keep it with junk=false.)

        Then judge. Reply with ONLY a compact JSON object (no markdown, no extra text), with keys in EXACTLY this order:

        {"summary":"<ALWAYS write this first: the durable keepers if any; otherwise a brief one-line note of what the slice was actually about>","title":"<short 3-6 word title>","junk":<true|false>}

        Then append this key ONLY IF it applies:
          ,"sensitive":true  — RARE. Use ONLY when the window is WHOLLY private — i.e. after omitting the private specifics there is nothing useful left worth keeping (e.g. a message that is only a password, only card/account details, or only a raw private medical disclosure). If anything safe and useful remains, prefer the sanitized summary above and keep it (junk=false) instead.

        EXAMPLE of the output style (made-up — copy the PHRASING & attribution, not the content): for a slice where 'Me' writes "signing the lease on the Capitol Hill place friday, moving in the 15th" and another person, Maya, says she'll be in Seattle in June, a good response is:
        {"summary":"The user is signing a lease on a Capitol Hill apartment on Friday and moving in on the 15th. Maya plans to be in Seattle in June.","title":"New Apartment Lease","junk":false}
        Notice: the user is called 'the user' (NEVER 'Me'), and Maya's plan is attributed to Maya by name.
        """
    }

    // MARK: Decision

    /// The full outcome: the verdict + the model's title/summary, shown during processing for ANY
    /// verdict. Survivors carry a non-empty summary; junk/sensitive are dropped (zero trace).
    /// WHY an item landed where it did — §7.13, so the diagnostics can tell a garbled model reply
    /// (`parseFailed`) apart from a genuine junk verdict (`modelJunk`) apart from an empty summary,
    /// all of which used to increment the same opaque junk counter ("why so much junk?").
    enum Reason: String, Sendable { case survivor, sensitive, modelJunk, emptySummary, parseFailed }

    struct Outcome {
        let verdict: Verdict
        let title: String?
        let summary: String
        let reason: Reason
    }

    static func decide(_ responseText: String) -> Outcome {
        guard let r = parse(responseText) else {
            return Outcome(verdict: .junk, title: nil, summary: "", reason: .parseFailed)   // fail-closed
        }
        let summary = r.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = r.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty ? nil : trimmedTitle

        if r.sensitive {
            return Outcome(verdict: .sensitive, title: title, summary: summary, reason: .sensitive)
        }
        if r.junk {
            return Outcome(verdict: .junk, title: title, summary: summary, reason: .modelJunk)
        }
        if summary.isEmpty {
            return Outcome(verdict: .junk, title: title, summary: summary, reason: .emptySummary)
        }
        return Outcome(verdict: .survivor, title: title, summary: summary, reason: .survivor)
    }

    // MARK: Lenient JSON parsing

    struct Parsed { let summary: String; let title: String; let junk: Bool; let sensitive: Bool }

    static func parse(_ text: String) -> Parsed? {
        // Isolate the JSON object span; if there are no braces at all, still try field recovery.
        let span: String
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            span = String(text[start...end])
        } else {
            span = text
        }

        // Fast path: strict JSON.
        if let data = span.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func flag(_ key: String) -> Bool {
                if let b = obj[key] as? Bool { return b }
                if let n = obj[key] as? NSNumber { return n.boolValue }
                if let s = obj[key] as? String { return ["true", "yes", "1"].contains(s.lowercased()) }
                return false
            }
            return Parsed(summary: (obj["summary"] as? String) ?? "",
                          title: (obj["title"] as? String) ?? "",
                          junk: flag("junk"), sensitive: flag("sensitive"))
        }

        // Recovery path: the model fumbled the JSON (a stray quote, trailing comma, …). Extract
        // each field on its own so one malformed key can't sink an otherwise-valid keeper. Still
        // fail-closed: no recoverable summary ⇒ nil (→ junk), and an unreadable junk flag ⇒ junk.
        guard let summary = stringField("summary", in: span) else { return nil }
        return Parsed(summary: summary,
                      title: stringField("title", in: span) ?? "",
                      junk: boolField("junk", in: span) ?? true,
                      sensitive: boolField("sensitive", in: span) ?? false)
    }

    /// Pull a JSON string value for `key` (honoring \" and \n escapes) even from almost-JSON.
    private static func stringField(_ key: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"") else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
    }

    /// Pull a boolean value for `key` (true/false/yes/no/1/0) from almost-JSON; nil if absent.
    private static func boolField(_ key: String, in s: String) -> Bool? {
        guard let re = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*\"?(true|false|yes|no|1|0)\"?", options: .caseInsensitive) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ["true", "yes", "1"].contains(ns.substring(with: m.range(at: 1)).lowercased())
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
    private static func dateString(_ d: Date) -> String { formatter.string(from: d) }
}
