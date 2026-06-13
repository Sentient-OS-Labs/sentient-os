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
            case .overdue:  Theme.Ink.amber
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

    static let demo: [Briefing] = [
        Briefing(
            id: "deepika", kind: .overdue,
            kicker: "Overdue · 3 days · Gmail",
            title: "Deepika is waiting.",
            body: "She's connecting you with Jordan, Outlander's senior partner, about the ~$1.5M — and asked for a TLDR she can forward. I wrote it.",
            letter: """
            Deepika (Outlander VC) loved Sentient and is connecting you with Jordan, their senior partner, to talk through the ~$1.5M. She asked for a TLDR she could forward.

            That was three days ago. Time to land it — the draft is below, written to be forwarded.
            """,
            draft: """
            Hi Deepika,

            So great speaking with you — and thank you for connecting me with Jordan! Here's a TLDR you can forward along:

            Sentient OS is the private, on-device intelligence layer for your digital life. Your Mac reads everything you've saved — files, screenshots, WhatsApp, iMessage, Notes — entirely on your own hardware, and distills it into a knowledge vault every AI you use can plug into. Raw data never leaves the device. 2,500+ waitlist signups in 24 hours from a single Reddit post, a working product, and a public launch this month.

            Would love to walk Jordan through a live demo whenever suits.

            Best,
            Jesai
            """,
            draftLabel: "Draft · Gmail",
            detailLabel: "read the draft",
            offer: "Should I send it for you?",
            workLog: ["→ reading the thread with Deepika",
                      "→ opening Gmail",
                      "→ composing the forwardable TLDR…",
                      "✓ sent"],
            doneTitle: "Sent to Deepika.",
            doneBody: "The TLDR is on its way to Jordan.",
            codexPrompt: "Open Gmail and reply to the latest thread with Deepika (Outlander VC) using the approved draft in this briefing. Send it."),

        Briefing(
            id: "luis", kind: .meeting,
            kicker: "Meeting · iMessage + Calendar",
            title: "Luis wants Friday, 1 PM.",
            body: "Luis Schmitz (Headline) proposed meeting next Friday. I checked your calendar — you're free at 1 PM. The reply is drafted.",
            letter: """
            Luis Schmitz from Headline proposed meeting next week — Friday at 1 PM. I checked your calendar: you're free, with nothing for two hours on either side.

            Worth remembering: their HQ is 101 Montgomery Street in the Presidio — NOT the Montgomery in Downtown. I'll remind you that morning.
            """,
            draft: "Hi Luis! Friday at 1 PM works perfectly — see you at 101 Montgomery. Looking forward to it!",
            draftLabel: "Draft reply · iMessage",
            detailLabel: "read the draft",
            offer: "Reply & add it to your calendar?",
            workLog: ["→ opening Messages",
                      "→ replying to Luis…",
                      "→ adding Friday 1:00 PM to Calendar",
                      "→ location: 101 Montgomery St — the Presidio",
                      "✓ replied & scheduled"],
            doneTitle: "Friday's locked in.",
            doneBody: "Replied to Luis · calendar updated — the Presidio one.",
            codexPrompt: "Reply to Luis Schmitz on iMessage with the approved draft, then create a calendar event Friday 1 PM at 101 Montgomery St (Presidio), title 'Luis — Headline'."),

        Briefing(
            id: "dad", kind: .promise,
            kicker: "Promise · WhatsApp",
            title: "Dad's running shoes, found.",
            body: "You promised him shoe research. Done — a clear winner for daily runs and two backups. The message is ready to send.",
            letter: """
            You told your dad you'd research running shoes for him. Done — he needs stability shoes for daily walks and easy 5Ks, and this year the field has a clear winner.

            ✦ The pick: ASICS Gel-Kayano 31 — the benchmark stability shoe; plush, supportive, kindest to knees. ₹13,999 on amazon.in.

            ✦ Backup: Brooks Adrenaline GTS 24 — lighter, slightly firmer ride, same support. ₹11,500.

            ✦ Budget: New Balance 860v14 — the value play, often discounted. ₹9,999.
            """,
            draft: "Appa — researched the shoes properly :) Get the ASICS Gel-Kayano 31 — best stability for daily runs and easiest on the knees. If the size is sold out, the Brooks Adrenaline GTS 24 is just as good. Sending links!",
            draftLabel: "Draft · WhatsApp",
            detailLabel: "view the full research",
            offer: "Shall I send it to him?",
            workLog: ["→ opening WhatsApp",
                      "→ finding Dad",
                      "→ sending the message + links…",
                      "✓ delivered"],
            doneTitle: "Dad has it.",
            doneBody: "Delivered on WhatsApp, links and all.",
            codexPrompt: "Send Dad the approved WhatsApp message from this briefing, followed by the three amazon.in product links from the research."),

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
            id: "sfbreak", kind: .plan,
            kicker: "Plan · WhatsApp · Cofounders",
            title: "Your perfect SF break.",
            body: "You three were brainstorming attractions in the group chat. I built the day from everything I know about you — golden hour included.",
            letter: """
            The three of you were brainstorming a break day in the group chat. I built it from everything I know about you — the camera itch, the food list, the fog:

            ✦ 9 AM — Tartine in the Mission. It's been sitting on your Food to Try list since April.

            ✦ 11 AM — Marin Headlands. The Golden Gate from above, and the best photography light of the day.

            ✦ 2 PM — Musée Mécanique and Pier 39 chaos, settled by an It's-It taste test.

            ✦ 5 PM — Karl the Fog permitting: Twin Peaks at golden hour.

            ✦ 8 PM — the Alcatraz night tour — the one booking that actually sells out. I can grab three tickets the moment you say yes.
            """,
            detailLabel: "view the plan",
            offer: "Shall I post it to the chat?",
            workLog: ["→ opening WhatsApp",
                      "→ “Aditya, Aryaman & Jesai”",
                      "→ posting the plan…",
                      "✓ posted"],
            doneTitle: "It's on the chat.",
            doneBody: "Aditya and Aryaman are typing…",
            codexPrompt: "Post the SF break-day plan from this briefing to the WhatsApp group 'Aditya, Aryaman & Jesai'."),

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
}
