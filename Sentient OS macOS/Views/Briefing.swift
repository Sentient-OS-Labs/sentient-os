//
//  Briefing.swift
//  Sentient OS macOS
//
//  The briefing (suggestion-card) model + the demo set for the home (HomeView). A briefing is an
//  OFFER: the AI already did the work (research / draft / plan) and asks one question —
//  "Should I do this for you?" — clicking it is the user's fire (Privacy Constitution: we
//  never act unbidden; we offer, they fire).
//
//  THE CODEX SEAM: `codexPrompt` is what real execution sends to the user's own Codex CLI
//  (`CodexCLI.run` — computer use, the connectors, the works — armed with the vault's personal
//  context). The demo plays the hard-coded `workLog` theater instead; swapping in the real
//  call is a one-line change at the seam in HomeView (ForYouModel.run).
//
//  ALL content below is the hard-coded investor-demo set (mined from the real vault for
//  authenticity). The proactive-intelligence module generates real ones post-launch.
//

import SwiftUI

struct Briefing: Identifiable {
    enum Kind {
        case meeting, overdue, promise, deadline, plan, welcome

        /// The kind's accent — used as the card's hairline tint and kicker color (jewelry rule:
        /// one quiet color per card; the welcome letter alone wears the full gradient).
        var accent: Color {
            switch self {
            case .meeting:  Color(red: 0.36, green: 0.55, blue: 1.00)   // cobalt
            case .overdue:  Color(red: 1.00, green: 0.50, blue: 0.18)   // overdue orange — hotter than amber
            case .promise:  Theme.Ink.green
            case .deadline: Color(red: 1.00, green: 0.42, blue: 0.45)   // ember
            case .plan:     Color(red: 0.72, green: 0.46, blue: 0.96)   // orchid
            case .welcome:  Theme.Ink.amber
            }
        }
    }

    let id: String
    let kind: Kind
    let kicker: String          // mono-caps provenance whisper, e.g. "OVERDUE · 3 DAYS · GMAIL"
    let title: String           // the serif headline
    let body: String            // 2–3 line card preview
    let letter: String?         // the full typeset letter (paragraphs split on \n\n; "✦ " = accent bullet)
    let draft: String?          // a ready-to-send message, shown as a copyable draft block
    let draftLabel: String?     // the draft block's tag, e.g. "DRAFT REPLY · IMESSAGE"
    let detailLabel: String?    // the quiet open-the-letter link, e.g. "read the draft"
    let offer: String?          // the verb CTA, e.g. "Should I send it for you?" (nil = no action)
    let workLog: [String]       // the agentic theater lines (demo stand-in for live codex output)
    let doneTitle: String
    let doneBody: String
    let codexPrompt: String?    // what real execution hands to CodexCLI (see THE CODEX SEAM above)
    let accent: Color           // the card's one accent (jewelry rule). Demo: kind.accent; real: per method.

    init(id: String, kind: Kind, kicker: String, title: String, body: String,
         letter: String? = nil, draft: String? = nil, draftLabel: String? = nil,
         detailLabel: String? = nil, offer: String? = nil, workLog: [String] = [],
         doneTitle: String = "", doneBody: String = "", codexPrompt: String? = nil,
         accent: Color? = nil) {
        self.id = id
        self.kind = kind
        self.kicker = kicker
        self.title = title
        self.body = body
        self.letter = letter
        self.draft = draft
        self.draftLabel = draftLabel
        self.detailLabel = detailLabel
        self.offer = offer
        self.workLog = workLog
        self.doneTitle = doneTitle
        self.doneBody = doneBody
        self.codexPrompt = codexPrompt
        self.accent = accent ?? kind.accent
    }

    // MARK: Real cards — built from a prepared proactive action (the toggle's real mode)

    /// Map a verified, ready-to-fire `PreparedAction` onto a card. The kicker is the clean
    /// `METHOD · TARGET` whisper; the accent is the method's signature color (jewelry). Fireable
    /// methods carry the editable draft + the LLM-written button; research is a read-only briefing.
    init(from a: PreparedAction) {
        let isResearch = a.method == .research
        let content = a.preparedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !content.isEmpty
        self.init(
            id: a.title,                                                   // stable; == PreparedAction.id
            kind: .plan,                                                   // placeholder; `accent` drives color
            kicker: Self.kickerLine(method: a.method, target: a.target),
            title: a.title,
            body: a.cardSummary,
            letter: isResearch && hasContent ? content : nil,             // research: the briefing IS the letter
            draft: !isResearch && hasContent ? content : nil,             // actions: the editable draft block
            draftLabel: Self.draftLabelText(for: a.method),
            detailLabel: hasContent ? (a.detailLabel.isEmpty ? "read the draft" : a.detailLabel) : nil,
            offer: (isResearch || a.buttonText.isEmpty) ? nil : a.buttonText,
            workLog: [],
            doneTitle: "Done.",
            doneBody: "",
            codexPrompt: nil,
            accent: Self.accentColor(for: a.method))
    }

    /// The welcome "gift" card — built straight from the generated Markdown letter (`GiftLetter` writes
    /// the whole thing: real cross-life patterns in plain English, title and all). The model opens with
    /// its own "# Title"; we promote that to the card title so the expanded letter never shows two
    /// titles, and the rest becomes the letter body. The envelope/letter UX keys off `kind == .welcome`.
    init(fromGiftMarkdown markdown: String) {
        var title = "A gift — connections across your life."
        var lines = markdown.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let head = lines[i].trimmingCharacters(in: .whitespaces)
            if head.hasPrefix("# ") {
                let t = String(head.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { title = t }
                lines.removeSubrange(0...i)
            }
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            id: "welcome", kind: .welcome,
            kicker: "Welcome · Read across your whole life",
            title: title,
            body: "A letter from your Sentient.",
            letter: body,
            detailLabel: "read it",
            offer: nil,
            doneTitle: "", doneBody: "")
    }

    /// The clean mono-caps kicker: `METHOD · TARGET` (gmail/calendar/research name themselves).
    static func kickerLine(method: PreparedAction.Method, target: String) -> String {
        let t = target.trimmingCharacters(in: .whitespaces).uppercased()
        switch method {
        case .gmail:    return "GMAIL"
        case .calendar: return "CALENDAR"
        case .computer: return t.isEmpty ? "COMPUTER USE" : "COMPUTER USE · \(t)"
        case .research: return "RESEARCHED"
        }
    }

    /// The method's signature accent (jewelry: one quiet color per card).
    static func accentColor(for method: PreparedAction.Method) -> Color {
        switch method {
        case .gmail:    return Color(red: 1.00, green: 0.42, blue: 0.45)   // ember
        case .calendar: return Color(red: 0.36, green: 0.55, blue: 1.00)   // cobalt
        case .computer: return Color(red: 0.30, green: 0.82, blue: 0.78)   // teal
        case .research: return Theme.Ink.green                              // mint
        }
    }

    /// The draft-block tag in the expanded letter.
    static func draftLabelText(for method: PreparedAction.Method) -> String {
        switch method {
        case .gmail:    return "Draft email"
        case .calendar: return "Event"
        case .computer: return "What I'll do"
        case .research: return "Briefing"
        }
    }

    // MARK: The demo six

    /// The EXACT reply we send Serena — ONE source of truth, shared by the Anthos card's draft
    /// PREVIEW (what you read when you click the card) and the `codexPrompt` that actually sends
    /// it. They interpolate this same string, so the preview and the sent email can never drift.
    private static let anthosReply = """
        Hey Serena,

        Thanks for reaching out, and that's awesome to hear! :)

        Would love to chat! I think you'll be surprised — what you see on the website right now is a really old version of Sentient from over a month ago.

        I'm using our core on-device processing moat to build a knowledge base for all your LLMs from your entire life. And cooler still, what I call Proactive Intelligence:

        Sentient, with its continuous free on-device compute, understands your entire life and then *acts* on it for you (backed by that rich knowledge base!). It does this through computer use.

        I'd love to show you live any time you're free. Would Friday work? If not, happy to chat early next week.

        Best,
        Jesai
        """

    /// The EXACT reply we send Charles — shared by the Charles card's draft PREVIEW and its
    /// `codexPrompt` (the live reply-all into the real "EWOR | Introducing Jesai & Charles"
    /// thread), so the preview and the sent email can never drift.
    private static let charlesReply = """
        Hey Charles,

        Really excited to meet you! :)
        Thanks so much for making the time.

        I'm in SF (PDT), and I'm happy to work around your schedule. For reference:
        - I can make any time Monday work, until 4:30 PM
        - I can make any time Tuesday work

        I'll also send some materials before the call.

        Looking forward to it,
        Jesai
        """

    static let demo: [Briefing] = [
        Briefing(
            id: "charles", kind: .deadline,
            kicker: "Reply · 2 days · Gmail",
            title: "Charles from EWOR is waiting on your timeslots.",
            body: "Daniel introduced you to Charles Ferguson — he sold companies to Microsoft and Oracle, pre-seeded Higgsfield, and won an Oscar. I checked your calendar and drafted your reply.",
            letter: """
            Daniel introduced you to Charles Ferguson for your next EWOR interview — he sold companies to **Microsoft** and **Oracle**, pre-seeded **Higgsfield** (€500M ARR in a year), and won an **Oscar**.

            He cc'd his assistant Emily to schedule and asked for any materials — a deck or a memo. So I checked your calendar for **Monday and Tuesday**, found your open windows, and wrote your reply: a few timeslots and a memo offer.
            """,
            draft: Briefing.charlesReply,
            draftLabel: "Draft reply · Gmail",
            detailLabel: "read the draft",
            offer: "Should I send it for you?",
            workLog: ["→ reading Charles's note",
                      "→ checking Monday & Tuesday for open slots",
                      "→ opening Gmail",
                      "→ composing your reply…",
                      "✓ sent"],
            doneTitle: "Sent to Charles.",
            doneBody: "Emily has your availability — and materials are on the way.",
            codexPrompt: """
            You are running fully headless and autonomous, with the user's explicit prior approval to act on their behalf for THIS task — they clicked "send it for me." Do NOT ask for confirmation or approval, do NOT pause to verify, and do NOT merely draft. Actually SEND. If any tool surfaces a confirmation or approval step, treat it as already granted by the user and proceed.

            Use the Gmail MCP to open the thread titled "EWOR | Introducing Jesai & Charles". In that thread, find the message from Charles Ferguson (chf@cferguson.com) whose body STARTS WITH "Thank you, Daniel, and moving you to bcc." REPLY-ALL to THAT message — include every recipient on it (all To and all Cc: Charles, his assistant Emily, and the EWOR "selection" address) so everyone Charles addressed receives the reply. Reply to CHARLES'S message specifically (NOT Daniel's earlier intro) so the reply respects that Charles moved Daniel to bcc — do not add Daniel. Send EXACTLY the message below, verbatim — do not change, rephrase, summarize, or add anything:

            \(Briefing.charlesReply)

            Send this reply-all now via the Gmail MCP — the user has already approved it. Do not ask, do not draft-and-wait; complete the send, then report exactly who it went to (the full To and Cc list).

            FORMATTING: send it as an HTML email (set the send tool's content_type to "text/html"). Put each paragraph in its own <p>…</p> tag; render the two "I can make any time…" lines as a <ul><li>…</li></ul> list; write the sign-off as "Looking forward to it,<br>Jesai". Keep every word — including ":)" and "4:30 PM" — exactly as written. Do NOT send as text/plain and do NOT insert any manual line breaks inside a paragraph.
            """),

        Briefing(
            id: "anthos", kind: .overdue,
            kicker: "Overdue · 2 days · Gmail",
            title: "You need to reply to Anthos Capital.",
            body: "Serena emailed two days ago — $3B+ AUM, names like Honey and Kalshi. She wanted time this week. I wrote your reply.",
            letter: """
            Serena Saxena from Anthos Capital emailed two days ago — she found Sentient down an on-device-vs-cloud rabbit hole. Anthos runs a $1.5B fund with $3B+ in AUM, and backs companies people are obsessed with: Honey, Kalshi, Erewhon, Olaplex.

            She's in LA and asked for time early this week. You went quiet. Let's fix that — the draft's below, warm and ready.
            """,
            draft: Briefing.anthosReply,
            draftLabel: "Draft · Gmail",
            detailLabel: "read the draft",
            offer: "Should I send it for you?",
            workLog: ["→ reading Serena's note",
                      "→ opening Gmail",
                      "→ composing your reply…",
                      "✓ sent"],
            doneTitle: "Sent to Anthos.",
            doneBody: "Serena has your reply — Friday, or early next week.",
            codexPrompt: """
            You are running fully headless and autonomous, with the user's explicit prior approval to act on their behalf for THIS task — they clicked "send it for me." Do NOT ask for confirmation or approval, do NOT pause to verify, and do NOT merely draft. Actually SEND. If any tool surfaces a confirmation or approval step, treat it as already granted by the user and proceed.

            Use the Gmail MCP to reply to the email from jesaitarun@gmail.com with the subject "Sentient OS test". Reply in that thread and send EXACTLY the message below, verbatim — do not change, rephrase, summarize, or add anything:

            \(Briefing.anthosReply)

            Send this reply now via the Gmail MCP — the user has already approved this send. Do not ask, do not draft-and-wait; complete the send and confirm it went out.

            IMPORTANT — formatting: send it as an HTML email. Set the send tool's content_type to "text/html" and format the body as clean HTML so it reflows naturally in the reader's inbox: put EACH paragraph above inside its own <p>…</p> tag, and write the sign-off as "Best,<br>Jesai". Keep every word — including ":)", the "—" em-dash, "*acts*", and "Friday" — exactly as written. Do NOT send as text/plain and do NOT insert any manual line breaks inside a paragraph; plain text gets hard-wrapped mid-sentence, which is the ugly formatting we're fixing.
            """),

        Briefing(
            id: "aim", kind: .promise,
            kicker: "Press · Early next week · WhatsApp",
            title: "AIM India wants your voice.",
            body: "Supreeth wants to interview you on Apple's Siri AI — and offered to cover the Sentient launch. He asked if you're free early next week. Reply's drafted.",
            letter: """
            Supreeth from AIM (Analytics India Magazine) reached out — he wants you as an expert voice on Apple's Siri AI, and offered to cover the Sentient OS launch while he's at it. Two birds.

            He asked if you're free early next week. You are — your week's wide open. Say the word and I'll send your yes.
            """,
            draft: "Hi Supreeth! Would love to — early next week works great on my end. And thank you for offering to cover the Sentient OS launch; happy to give you a hands-on look. Talk soon!",
            draftLabel: "Draft reply · WhatsApp",
            detailLabel: "read the draft",
            offer: "Reply & lock it in?",
            workLog: ["→ opening WhatsApp",
                      "→ finding Supreeth (AIM India)",
                      "→ confirming early next week…",
                      "✓ replied"],
            doneTitle: "You're on with AIM.",
            doneBody: "Confirmed for early next week — Supreeth's expecting you.",
            codexPrompt: "Reply to Supreeth (AIM India) on WhatsApp with the approved draft confirming the interview early next week."),

        Briefing(
            id: "ssn", kind: .promise,
            kicker: "Researched",
            title: "Prep Social Security Appointment",
            body: "Your SSA appointment is tomorrow at 1:10 PM. This opens the prep checklist and arrival plan; nothing gets sent.",
            letter: """
            Your Social Security Administration appointment is tomorrow at 1:10 PM. This is a read-only prep — nothing gets sent or scheduled.

            Bring (originals, not photocopies)
            - Passport and your current F-1 visa
            - Most recent I-94 (print it from the CBP site)
            - I-20, with the employment-authorization page signed
            - Your on-campus job offer / authorization letter
            - A completed SS-5 application (download from ssa.gov)

            Arrival plan
            - The office runs long — arrive about 20 minutes early, take a number, and fill the SS-5 while you wait.
            - No card same-day: it's mailed in ~10–14 business days, so confirm the address on file is your current one.

            I'll nudge you tomorrow morning. — your Sentient
            """,
            detailLabel: "read the prep checklist",
            offer: nil,
            doneTitle: "", doneBody: ""),

        Briefing(
            id: "supabase", kind: .deadline,
            kicker: "Renew · Friday · Computer use",
            title: "Your Supabase project expires Friday.",
            body: "The free-tier database behind Sentient pauses this Friday after a week idle — and it's the one holding your 2,500+ waitlist signups. I can renew it in your dashboard. Want me to?",
            letter: """
            Supabase flagged your **sentient-os** project: it's set to pause this **Friday**. Free-tier projects pause after 7 days of inactivity, and once paused the database goes offline until you restore it — and this is the one holding your **2,500+ waitlist signups**, so I'd rather not let it lapse.

            I'll handle it the way you would: open your Supabase dashboard in your own logged-in browser, go to **sentient-os**, and restore it — nothing touched but the renew button, and nothing leaves this Mac. One tap and you're back online.
            """,
            draft: "Open your Supabase dashboard → project 'sentient-os' → restore project → confirm it's back on the free tier.",
            draftLabel: "What I'll do · Computer use",
            detailLabel: "read the plan",
            offer: "Renew it for you?",
            workLog: ["→ opening your Supabase dashboard",
                      "→ finding project 'sentient-os'",
                      "→ restoring the paused project…",
                      "→ confirming it's back on the free tier",
                      "✓ renewed — back online"],
            doneTitle: "Supabase renewed.",
            doneBody: "Your database is back online — waitlist safe, still free tier.",
            codexPrompt: "Use computer use to open the user's Supabase dashboard in their own logged-in browser, open the 'sentient-os' project, and restore/renew it so it doesn't pause. Confirm it's back online, then report what you did.",
            accent: Color(red: 0.36, green: 0.55, blue: 1.00)),   // cobalt (Luis's old blue)

        Briefing(
            id: "welcome", kind: .welcome,
            kicker: "Welcome · Read across your whole life",
            title: "A gift — connections across your life.",
            body: "Three patterns you might not have seen yourself — visible only with everything in one place.",
            letter: """
            I read **1,704 things** across your life last night. Three patterns you might not have seen yourself:

            ✦ **You never accept defaults.** Your iPhone ran **iPadOS** — WIRED noticed. Macs got **Apple Intelligence** before Apple shipped it, because you ported it. Your playlists skip the charts — and now you're routing around **college** itself.

            ✦ **You spec hardware in numbers and music in feelings.** RAM chosen by the gigabyte for local LLMs; playlists curated for **“mood, tears, goosebumps.”**

            ✦ **Your optimization points outward.** The systems you engineer for yourself show up rebuilt as **study systems for Jacob**, 8,000 miles away.

            I'll keep watch from here. — **your Sentient**
            """,
            detailLabel: "read it again",
            offer: nil,
            doneTitle: "", doneBody: ""),
    ]

    // MARK: - Parked / alternate demo cards (swap-in library)
    //
    // Retired or alternate "For You" cards, kept here so they're easy to swap back into the `demo`
    // deck above. To use one: delete its surrounding /* … */ and move the Briefing(…) into `demo`
    // (and drop/replace a current card so the count stays 6 — the scatter layouts in HomeView's
    // `slots(count:)` only define up to 6). Each is self-contained (no shared-constant refs).
    // Parked = NOT compiled, so these can quietly go stale — re-read before relying on one.

    /* ── Fareed (RICH-letter variant) · "Prepare for your call with Fareed from Speedrun." — the
       researched prep card (cobalt) that lived in the demo deck before Anthos took its slot. ──
        Briefing(
            id: "fareed", kind: .meeting,
            kicker: "Prep · 4:30 PM tomorrow · Researched",
            title: "Prepare for your call with Fareed from Speedrun.",
            body: "Remember: Josh Lu wanted Fareed to be your a16z Speedrun partner. I've researched and found that GTM strategy matters a lot to him. Here's a doc that'll help you prepare for your call.",
            letter: """
            Your call with Fareed is tomorrow at 4:30 PM. Josh Lu wanted him as your a16z Speedrun partner — and once I read Fareed's background, it's obvious why. I pulled the highlights that'll get you ready.

            ✦ **Why Josh connected you: he OWNED GTM at Slack.** Fareed was Director of Product for Lifecycle and the revenue owner for Slack's self-serve business — acquisition, activation, retention, monetization: the whole PLG engine at the company that *defined* bottoms-up growth. Sentient's free-forever consumer wedge is exactly his world. Speak his language — growth loops, activation, the path from a loved free product to revenue.

            ✦ **He literally wrote about a thesis behind your product.** His recent post — *"Agent-native products are coming"*: *"Every product on the internet was built for a human with eyes, a cursor, and a credit card. Agents have none of those. The real opportunity is products designed for agents from scratch."* That is core to Sentient — an agent-native knowledge base your whole life feeds, offered to your AIs for Proactive Intelligence. Open here; he'll feel seen, and you'll prove you did the work.

            ✦ **He thinks in product strategy — so be crisp.** At Reforge he built, with Casey Winters, the Product Strategy program that's now their **#1**. Expect him to probe your strategic spine: consumer free-forever as the loved wedge, the enterprise per-employee intelligence layer as the business, the on-device moat that makes both possible. Have the one-becomes-the-other story tight.

            ✦ **Lead with distribution proof.** He loves network effects and growth loops, so the Reddit moment lands hard: **2,500+ waitlist signups in 24 hours, $0 spent.** That's the organic growth-loop evidence he's wired to respond to.

            Walk in as the agent-native, PLG-native founder he's been writing about. — your Sentient
            """,
            detailLabel: "read the prep doc",
            offer: nil,
            doneTitle: "", doneBody: ""),
    */

    /* ── EWOR · "Prepare for your call with Daniel, CEO of EWOR." (researched prep card, orchid) ──
        Briefing(
            id: "ewor", kind: .plan,
            kicker: "Prep · 11 AM today · Researched",
            title: "Prepare for your call with Daniel, CEO of EWOR.",
            body: "Somya Gupta nominated you for the EWOR Fellowship — and Daniel Dippold, its founder & CEO, wants 15 minutes today at 11 AM. I researched him and EWOR and pulled together what'll get you ready.",
            letter: """
            Your EWOR selection interview is today — 11:00–11:15 AM PDT, on Zoom (it moved up from 10:45). Somya Gupta nominated you, and you're meeting Daniel Dippold, EWOR's founder & CEO. He called it casual, but it's 15 minutes and it's selective — so walk in sharp.

            ✦ **Know your room.** Daniel is a mathematician-turned-founder: raised **$100M** in his twenties, angel in **7 unicorns**, and built three organizations still thriving — EWOR, New Now Group, Sigma Squared. He rewards technical depth and outlier conviction — lead with the on-device moat and your all-in, drop-out resolve.

            ✦ **Speak EWOR's language.** They back the **top 0.1%** of founders building transformative tech — up to **€500K** immediate, plus weekly 1:1 coaching from unicorn founders (Adjust, ProGlove, SumUp). No standard playbooks; they tailor to each founder. Frame Sentient as exactly that non-linear, outlier bet.

            ✦ **Your 15-minute arc.** Open with the Reddit moment — **2,500+ waitlist signups in 24 hours, $0 spent**. Then the wedge: consumer free-forever as the loved foothold, the enterprise per-employee intelligence layer as the business. Close on why now, and why you.

            Somya put their name on you — make it land. — **your Sentient**
            """,
            detailLabel: "read the prep doc",
            offer: nil,
            doneTitle: "", doneBody: ""),
    */

    /* ── Fareed (ORIGINAL short-letter variant) · alternate to the current rich-letter Fareed card ──
        Briefing(
            id: "fareed", kind: .meeting,
            kicker: "Prep · Tomorrow · Researched",
            title: "Prepare for your call with Fareed from Speedrun tomorrow.",
            body: "Remember: Josh Lu wanted Fareed to be your a16z Speedrun partner. I've researched and found that GTM strategy matters a lot to him. Here's a doc that'll help you prepare for your call.",
            letter: """
            Remember: Josh Lu wanted Fareed to be your a16z Speedrun partner — and your call is tomorrow. I went through everything and pulled together what'll get you ready.

            ✦ **GTM is his lens.** Across his bets and writing, Fareed weighs go-to-market harder than almost anything. He'll want a crisp distribution story, not just the tech.

            ✦ **Open with the Reddit moment.** 2,500+ waitlist signups in 24 hours from a single post, $0 spent — that's the GTM proof that lands with him. Lead with it.

            ✦ **Have the wedge ready.** Consumer free-forever as the loved wedge; the enterprise per-employee intelligence layer as the business. Expect him to push on how one becomes the other.

            Walk in leading with distribution. — your Sentient
            """,
            detailLabel: "read the prep doc",
            offer: nil,
            doneTitle: "", doneBody: ""),
    */

    /* ── Luis · "Luis invited you to lunch at Headline." (meeting card, cobalt · iMessage + Calendar)
       — lived in the demo deck before the Supabase computer-use card took its slot. ──
        Briefing(
            id: "luis", kind: .meeting,
            kicker: "Meeting · iMessage + Calendar",
            title: "Luis invited you to lunch at Headline.",
            body: "He proposed next Wednesday at 1 PM. I checked your calendar — you're free. Should I reply and add it to your cal?",
            letter: """
            Luis Schmitz invited you to lunch at Headline next Wednesday at 1 PM, at their Presidio office. I checked your calendar: you're free, with nothing for two hours on either side.

            Worth remembering: their HQ is 101 Montgomery Street in the Presidio — NOT the Montgomery in Downtown. I'll remind you that morning.
            """,
            draft: "Hi Luis! Wednesday at 1 PM works perfectly — see you at the Presidio. Looking forward to it!",
            draftLabel: "Draft reply · iMessage",
            detailLabel: "read the draft",
            offer: "Reply & add it to your calendar?",
            workLog: ["→ opening Messages",
                      "→ replying to Luis…",
                      "→ adding Wednesday 1:00 PM to Calendar",
                      "→ location: the Presidio (101 Montgomery St)",
                      "✓ replied & scheduled"],
            doneTitle: "Wednesday's locked in.",
            doneBody: "Replied to Luis · lunch on your calendar — the Presidio one.",
            codexPrompt: "Reply to Luis Schmitz on iMessage with the approved draft, then create the calendar event 'Lunch @ Presidio — Jesai x Luis' for next Wednesday 1 PM at 101 Montgomery St (Presidio)."),
    */
}
