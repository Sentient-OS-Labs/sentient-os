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
            id: "anthos", kind: .overdue,
            kicker: "Overdue · 4 days · Gmail",
            title: "You ghosted Anthos Capital.",
            body: "Serena cold-emailed four days ago — $1.5B fund, names like Honey and Kalshi. She wants time next week. I wrote your reply.",
            letter: """
            Serena Saxena from Anthos Capital cold-emailed four days ago — she found Sentient down an on-device-vs-cloud rabbit hole. Anthos runs a $1.5B fund with $3B+ in AUM, and backs companies people are obsessed with: Honey, Kalshi, Erewhon, Olaplex.

            She's in LA and asked for time early next week. You went quiet. Let's fix that — the draft's below, warm and ready.
            """,
            draft: """
            Hi Serena,

            Thank you for reaching out — and for going down the on-device rabbit hole. That's exactly the bet.

            Quick context: Sentient OS is a private, on-device intelligence layer for your whole digital life. Your Mac reads everything you've saved — files, screenshots, WhatsApp, iMessage, Notes — entirely on your own hardware, and distills it into a knowledge vault every AI you use can plug into. Raw data never leaves the device. We hit 2,500+ waitlist signups in 24 hours from a single Reddit post, and we launch publicly this month.

            I'd love to find time next week. I'm in SF — happy to do a call, or grab time if you're ever up here. Would Tuesday or Wednesday afternoon work on your end?

            Best,
            Jesai
            """,
            draftLabel: "Draft · Gmail",
            detailLabel: "read the draft",
            offer: "Should I send it for you?",
            workLog: ["→ reading Serena's note",
                      "→ opening Gmail",
                      "→ composing your reply…",
                      "✓ sent"],
            doneTitle: "Sent to Anthos.",
            doneBody: "Serena has your reply — and two times next week.",
            codexPrompt: "Open Gmail and reply to Serena Saxena (Anthos Capital) with the approved draft in this briefing. Send it."),

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
            id: "deepika", kind: .plan,
            kicker: "Warm intro · 3 days · Gmail",
            title: "Deepika opened a $1.5M door.",
            body: "She's connecting you with Jordan, Outlander's senior partner, and asked for a TLDR she can forward. I wrote it.",
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
