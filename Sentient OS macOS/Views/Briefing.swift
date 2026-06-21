//
//  Briefing.swift
//  Sentient OS macOS
//
//  The briefing ("offering") model + the demo set for the For You window. A briefing is an
//  OFFER: the AI already did the work (research / draft / plan) and asks one question —
//  "Should I do this for you?" — clicking it is the user's fire (Privacy Constitution: we
//  never act unbidden; we offer, they fire).
//
//  THE CODEX SEAM: `codexPrompt` is what real execution sends to the user's own Codex CLI
//  (`CodexCLI.run` — browser use, computer use, the works — armed with the vault's personal
//  context). The demo plays the hard-coded `workLog` theater instead; swapping in the real
//  call is a one-line change at the seam in BriefingsView.
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
            case .promise:  Theme.Ink.mint
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

    init(id: String, kind: Kind, kicker: String, title: String, body: String,
         letter: String? = nil, draft: String? = nil, draftLabel: String? = nil,
         detailLabel: String? = nil, offer: String? = nil, workLog: [String] = [],
         doneTitle: String = "", doneBody: String = "", codexPrompt: String? = nil) {
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

        Sentient, with its continuous free on-device compute, understands your entire life and then *acts* on it for you (backed by that rich knowledge base!). It does this through computer use and browser use.

        I'd love to show you live any time you're free. Would tomorrow (Friday) work? If not, happy to chat early next week.

        Best,
        Jesai
        """

    static let demo: [Briefing] = [
        Briefing(
            id: "anthos", kind: .overdue,
            kicker: "Overdue · 6 days · Gmail",
            title: "You still haven't replied to Anthos Capital.",
            body: "Serena emailed six days ago — $3B+ AUM, names like Honey and Kalshi. She wanted time this week. I wrote your reply.",
            letter: """
            Serena Saxena from Anthos Capital emailed six days ago — she found Sentient down an on-device-vs-cloud rabbit hole. Anthos runs a $1.5B fund with $3B+ in AUM, and backs companies people are obsessed with: Honey, Kalshi, Erewhon, Olaplex.

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

            IMPORTANT — formatting: send it as an HTML email. Set the send tool's content_type to "text/html" and format the body as clean HTML so it reflows naturally in the reader's inbox: put EACH paragraph above inside its own <p>…</p> tag, and write the sign-off as "Best,<br>Jesai". Keep every word — including ":)", the "—" em-dash, "*acts*", and "(Friday)" — exactly as written. Do NOT send as text/plain and do NOT insert any manual line breaks inside a paragraph; plain text gets hard-wrapped mid-sentence, which is the ugly formatting we're fixing.
            """),

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

        Briefing(
            id: "aim", kind: .promise,
            kicker: "Press · 10 AM tomorrow · WhatsApp",
            title: "AIM India wants your voice.",
            body: "Supreeth wants to interview you on Apple's Siri AI — and offered to cover the Sentient launch. He asked if you're free at 10 AM tomorrow. Reply's drafted.",
            letter: """
            Supreeth from AIM (Analytics India Magazine) reached out — he wants you as an expert voice on Apple's Siri AI, and offered to cover the Sentient OS launch while he's at it. Two birds.

            He asked if you're free tomorrow at 10 AM PST. You are — your morning is clear. Say the word and I'll send your yes.
            """,
            draft: "Hi Supreeth! Would love to — 10 AM PST tomorrow works perfectly. And thank you for offering to cover the Sentient OS launch; happy to give you an early, hands-on look. Talk then!",
            draftLabel: "Draft reply · WhatsApp",
            detailLabel: "read the draft",
            offer: "Reply & lock it in?",
            workLog: ["→ opening WhatsApp",
                      "→ finding Supreeth (AIM India)",
                      "→ confirming 10 AM tomorrow…",
                      "✓ replied"],
            doneTitle: "You're on with AIM.",
            doneBody: "Confirmed for 10 AM — Supreeth's expecting you.",
            codexPrompt: "Reply to Supreeth (AIM India) on WhatsApp with the approved draft confirming the 10 AM PST interview tomorrow."),

        Briefing(
            id: "zfellows", kind: .deadline,
            kicker: "Deadline · 8 days · Browser agent",
            title: "ZFellows closes in 8 days.",
            body: "You bookmarked the Dropout Graduation but never registered. The form needs your name, school, and what you're building — I have all three.",
            letter: """
            You bookmarked the ZFellows Dropout Graduation three weeks ago and never registered. It closes in 8 days.

            The form is short: name, school, and what you're building. I have all three — say the word and an agent fills it while you watch.
            """,
            detailLabel: nil,
            offer: "Want an agent to register you?",
            workLog: ["→ launching a browser agent",
                      "→ zfellows.com/dropout-graduation",
                      "→ name: Jesai Tarun · school: UMass Amherst",
                      "→ building: Sentient OS",
                      "→ submitting the form…",
                      "✓ registered — confirmation in your inbox"],
            doneTitle: "You're registered.",
            doneBody: "The ZFellows confirmation is in your inbox.",
            codexPrompt: "Use the browser to open the ZFellows Dropout Graduation registration and submit it for Jesai Tarun, UMass Amherst, building Sentient OS."),

        Briefing(
            id: "fareed", kind: .meeting,
            kicker: "Prep · 1 PM today · Researched",
            title: "Prepare for your call with Fareed.",
            body: "I've researched and found that GTM strategy matters a lot to him. Here's a doc that'll help you prepare for your call.",
            letter: """
            Your call with Fareed is today at 1 PM. Josh Lu wanted him as your a16z Speedrun partner — and once I read Fareed's background, it's obvious why. I pulled the highlights that'll get you ready.

            ✦ **Why Josh connected you: he OWNED GTM at Slack.** Fareed was Director of Product for Lifecycle and the revenue owner for Slack's self-serve business — acquisition, activation, retention, monetization: the whole PLG engine at the company that *defined* bottoms-up growth. Sentient's free-forever consumer wedge is exactly his world. Speak his language — growth loops, activation, the path from a loved free product to revenue.

            ✦ **He literally wrote about a thesis behind your product.** His recent post — *"Agent-native products are coming"*: *"Every product on the internet was built for a human with eyes, a cursor, and a credit card. Agents have none of those. The real opportunity is products designed for agents from scratch."* That is core to Sentient — an agent-native knowledge base your whole life feeds, offered to your AIs for Proactive Intelligence. Open here; he'll feel seen, and you'll prove you did the work.

            ✦ **He thinks in product strategy — so be crisp.** At Reforge he built, with Casey Winters, the Product Strategy program that's now their **#1**. Expect him to probe your strategic spine: consumer free-forever as the loved wedge, the enterprise per-employee intelligence layer as the business, the on-device moat that makes both possible. Have the one-becomes-the-other story tight.

            ✦ **Lead with distribution proof.** He loves network effects and growth loops, so the Reddit moment lands hard: **2,500+ waitlist signups in 24 hours, $0 spent.** That's the organic growth-loop evidence he's wired to respond to.

            Walk in as the agent-native, PLG-native founder he's been writing about. — your Sentient
            """,
            detailLabel: "read the prep doc",
            offer: nil,
            doneTitle: "", doneBody: ""),

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
    ]

    /// PARKED — the original "gift from your Sentient" welcome letter (the wax-sealed envelope card).
    /// Deliberately kept OUT of the `demo` deck above so it doesn't show in the UI right now, but
    /// preserved verbatim so it's one line away from returning: drop `Briefing.welcomeGift` back into
    /// `demo`. Its envelope visuals (`EnvelopeFace`, `welcomeGradient`, the `.sealed` phase) are still
    /// intact in BriefingCard.swift. NOTE: re-adding makes a 7-card deck — extend `slots(count:)` in
    /// BriefingsView (it only defines layouts up to 6), or swap it back in for another card to stay at 6.
    static let welcomeGift = Briefing(
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
        doneTitle: "", doneBody: "")
}
