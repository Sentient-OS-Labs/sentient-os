# Security Policy

Sentient OS is built on a promise: your raw data never leaves your Mac. We treat anything that breaks that promise, or any other security issue, as a top priority.

## Reporting a vulnerability

Email **security@sentient-os.ai**.

Please do not report vulnerabilities through public GitHub issues.

Include what you can:

- What the issue is and why it matters
- Steps to reproduce (a proof of concept helps a lot)
- The version or commit you tested
- Any suggested fix

You will get an acknowledgement within 48 hours, and we will keep you informed while we work on a fix.

## Scope

Everything Sentient OS ships is in scope:

- The macOS app (this repository)
- The hosted MCP mirror at `mcp.sentient-os.ai` and its server code
- Our release and update infrastructure

We are especially interested in reports that break our privacy invariants, because they are security claims, not marketing:

1. Raw data never leaves the device; cloud models only ever see PII-stripped summaries.
2. Items judged sensitive on-device leave zero trace downstream.
3. The MCP mirror stores only ciphertext encrypted on the user's Mac (AES-256-GCM); the server never sees plaintext at rest.
4. No accounts: a mirror cannot be tied to a human identity.
5. Deletion is total and self-serve; an unrefreshed mirror auto-deletes after 30 days.

If you find a way to violate any of these, we especially want to know.

When testing the live mirror, test against your own data and your own mirror URL. Please avoid disruptive testing (denial of service, resource exhaustion) against `mcp.sentient-os.ai`, and if you believe you can reach another user's vault, stop at the minimum proof needed and report it.

## Why Sentient needs the access it does

Sentient is an AI that acts on your Mac, in your own apps, so it genuinely asks for real power: Full Disk Access, control of a computer-use helper, and the ability to run an agent headlessly. The honest response to "this app is powerful" is not to hide the power but to explain each capability, why an agent like this cannot work without it, why it is safe, and how you revoke it. All of it is in this open-source repository; none of it is obfuscated.

**The trust boundary up front:** Sentient's cloud half runs entirely through **your own** Codex CLI, signed into **your own** ChatGPT account. When something "goes to the cloud," it goes to OpenAI under the account and privacy policy you already have with them — **never to a Sentient server**. The one exception is the opt-in mirror, described at the end.

### Full Disk Access, and no App Sandbox
- **What:** reads WhatsApp / iMessage / Apple Notes out of the SQLite databases already on your disk (macOS gates these behind Full Disk Access), and the app is not App-Sandboxed (the sandbox and FDA are mutually exclusive).
- **Why essential:** those databases are where your real life lives on your Mac, and there is no API for them. Reading them locally is the whole point — it is what lets the understanding happen on your silicon instead of in someone's cloud.
- **Why safe:** everything read under FDA is processed locally by the on-device model; only PII-stripped summaries ever leave (see the data-flow list below). Reads are copy-then-delete and WAL-safe, so a plaintext copy never lingers.
- **Revoke:** System Settings → Privacy & Security → Full Disk Access, any time.

### The Automation grant for the computer-use helper (`System/Permissions.swift`)
- **What:** to act on your Mac, Sentient drives OpenAI's Codex "computer use" helper over Apple Events. macOS gates that with an Automation grant ("Sentient OS → Codex Computer Use"). Sentient writes that one grant row into **your own** user TCC database (it can, because you granted Full Disk Access), then reloads `tccd` so it takes effect.
- **Why essential, and why there is no prompt:** macOS normally shows an Automation consent dialog — but this specific helper exposes no idle Apple Event endpoint, so `AEDeterminePermissionToAutomateTarget` returns `procNotFound` and **no dialog can be triggered at all**. Terminal and Warp acquire the identical grant the first time you run computer use from them. Without it, the very first computer-use action blocks forever.
- **Why safe:** the grant authorizes exactly one thing — Sentient controlling **its own** bundled computer-use helper — and nothing broader; it writes nothing device-specific; and it is code-signature-scoped to the real signed bundles, so an impostor binary can't inherit it. The consent is real where it counts: you installed an app whose entire stated purpose is to act on your Mac via your own Codex, and you granted Full Disk Access to enable it. Sentient re-applies the row only if a Codex plugin update drops it — because you cannot re-grant it yourself (there is no dialog), not to override a choice you made.
- **Revoke:** uninstalling Sentient (Settings → uninstall) removes it; it never authorizes anything but Sentient's own helper.

### Acting on your accounts and your Mac, with layered safeguards (`Cloud/CodexCLI.swift`, `Proactive/ProactiveExecutor.swift`)
When you fire an action, Sentient hands Codex the **least** power that does the job, and wraps every path in independent, overlapping safeguards. There are three paths, each locked down on its own terms:

- **Sending an email or adding a calendar event (a card you tap):** Codex stays inside its Seatbelt sandbox for the whole run — it cannot run shell commands or touch your files — and it is handed a **single-run pre-approval scoped to just that one connector write**, driven by a fixed, app-authored prompt for that one task. It can do the exact thing you tapped, and nothing else. A self-healing check guarantees the send still goes through even if OpenAI later changes its connector surface, so the hardening never costs reliability.
- **The overnight research that drafts your cards:** it only ever reads and drafts, and **three independent guards** stop it from sending anything at all — the prompt forbids it, the sandbox and approval policy auto-cancel any write, *and* the send and delete tools are removed from its toolbox entirely. A prompt-injecting email is yelling instructions at an agent with no hands, no permission, and no orders to obey.
- **Sidekick and computer use (acting in your own apps):** this path uses Codex's full capability, because OpenAI's computer-use plugin is *measured* to refuse to run headless otherwise — and it is wrapped in control you can see and feel. It **never runs on its own.** It runs only when **you** start it: you tap a proactive card, or you hold the key and ask Sidekick yourself. Your Mac has to be awake and in front of you, and the instant it runs the notch blooms into a large glowing panel with live status and a **STOP** button that kills the run on one press (the process, not just the animation). Every instruction is app-authored and fixed — one declared task, never raw web or email text, and page content can never add or re-aim what it does. From the first tap to the last, you are in control.

### The computer-use confirmation-policy patch (`Cloud/ComputerUseSkillPatch.swift`)
- **What:** Sentient edits the confirmation policy inside your Codex computer-use skill so the agent stops re-asking "shall I proceed?" before the everyday actions you already told it to do.
- **Why essential:** by default Codex will not send the message even after you fire the card — it stops to re-confirm, and a headless run can't answer, so the action stalls. "One tap and it's done" requires the agent to do the thing you fired.
- **Why safe:** the patch **keeps every high-stakes guardrail verbatim** — deleting data, financial transactions, saving passwords, creating accounts or API keys, changing system settings, medical actions, and the transmit-sensitive-data rules all still hard-confirm — and keeps the anti-prompt-injection rule. It relaxes only the everyday re-confirmations (sending the message you dictated, filling the form) and the standalone CAPTCHA / browser-safety-prompt rows, which are safe to pass because you authored and fired the task and are watching it act in your own logged-in session. The exact before/after diff lives in `Documentation/Computer-Use Skill Patch (Confirmation Policy).md`.

### Sidekick screenshots (`Notch Magic/CommandRunModel.swift`)
- **What:** when you invoke Sidekick — and only if you granted Screen Recording — Sentient snaps a still of your display(s) and attaches it to that one Codex run, so the agent can see what you're looking at ("finish this for me" has to see "this").
- **Why safe:** it is **optional** (no grant → Sidekick runs text-only), you grant it behind an info panel that states exactly what and why, the image goes to **your own** Codex/OpenAI (the same place your ChatGPT prompts already go) and **never to a Sentient server**, and the local file is deleted the instant the run ends.

### What actually leaves your Mac
Raw files, messages, and databases never leave. What can leave, and only to **your own** OpenAI account via your own Codex:
- **PII-stripped summaries** the on-device model writes (these build your knowledge base).
- During a proactive run or Sidekick command: your **knowledge base**, live **Gmail/Calendar** context (through OpenAI's own connectors, which you connect inside ChatGPT — that data already flows through your ChatGPT account, not us), and Sidekick's optional screenshot.

None of that reaches a Sentient server. The only thing that can is the opt-in mirror.

### The one thing that touches our servers: the opt-in MCP mirror
Off by default. When on, your Mac encrypts the whole knowledge base with AES-256-GCM before upload; our server stores only ciphertext and holds no key of its own. This is **zero-access encryption**, and here is its honest threat model:
- **Protects against:** theft of our server's disk, a subpoena of stored data, a passive breach — each yields ciphertext and no keys.
- **Does not claim to protect against** a malicious or compromised operator of the *running* service, because the server decrypts in memory for the instant of each request (your connector URL carries the key). We don't hide this — it's stated in `Cloud/MirrorClient.swift` and the mirror doc.
- **Your part:** the connector URL is a bearer secret (it contains your password). Keep it private, like a password; never paste it publicly.

Reinforced by no accounts (a vault can't be tied to you), a 30-day auto-delete lease, one-click delete, and an open-source server you can read or self-host.

### Diagnostics and analytics
Crash reports (Sentry) and product analytics (TelemetryDeck) are **Release-only**, structure-only (counts and enums, never your content), each with its own opt-out in Settings; crash reporting turns off completely. When analytics is off, the only thing still sent is a handful of **extremely anonymized usage-count pings** — how many people use Sentient, and how often Sidekick, proactive cards, overnight runs, and the home screen are used. Counts only: no content, no account, no IP. It's disclosed in the toggle's own caption, so the opt-out is honest — everything beyond those five simple counts stops.

## How we harden

Security here is proactive, not reactive. Ahead of the first public release, the whole codebase went through a dedicated security hardening program: adversarial audits by the strongest frontier models (Anthropic's Claude Mythos/Fable 5 and OpenAI's GPT-5.6 Sol) across every logging, capture, network, and privilege surface, paired with line-by-line manual review by both developers, over more than a week. Among the things that program locked down:

- The crash/telemetry pipeline reports structure only (counts, enums, error-type labels) behind two independent opt-outs, with a scrubber backstop, and every SDK default that captures URLs or request data is forced off as a regression-guarded invariant. See `Documentation/Diagnostics (Sentry).md`.
- The hosted mirror never logs request paths (the URL carries the user's secret): enforced at import time, covered by a regression test, and belt-and-suspenders in the deploy config, on top of at-rest AES-256-GCM encryption. See `Documentation/MCP Mirror Client.md`.
- The root wake helper only ever executes a codesign-verified, untampered app binary, so a user-writable app bundle can never be leveraged for root execution. See `Documentation/Overnight Scheduler (3am Wake).md`.
- A deterministic PII backstop (`Engine/PIIScan.swift`) sits behind the on-device model's triage, so a slipped raw identifier (SSN, card number, passport number) can never reach the cloud.

The receipts live in `Documentation/`. We would rather show the work than claim it.

## Supported versions

Sentient OS is under active development. Security fixes land in the latest release only, so please make sure the issue reproduces against the newest version.

## Coordinated disclosure

We ask that you give us reasonable time to fix an issue before disclosing it publicly. 90 days is a good default; issues in the hosted mirror will typically be fixed much faster. We are happy to credit you when the fix ships, or keep you anonymous if you prefer.

We do not run a paid bounty program yet. It's a two-person team; what we offer is fast fixes, honest credit, and gratitude.
