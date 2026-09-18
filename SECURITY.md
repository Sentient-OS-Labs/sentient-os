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

Sentient is an AI that acts on your Mac, in your own apps, so it genuinely asks for real power: Full Disk Access, Accessibility and Screen Recording for the computer-use engine, and the ability to run an agent headlessly. The honest response to "this app is powerful" is not to hide the power but to explain each capability, why an agent like this cannot work without it, why it is safe, and how you revoke it. All of it is in this open-source repository; none of it is obfuscated.

**The trust boundary up front:** Sentient's cloud half runs entirely through **your own** Codex CLI, signed into **your own** ChatGPT account. When something "goes to the cloud," it goes to OpenAI under the account and privacy policy you already have with them — **never to a Sentient server**. The one exception is the opt-in mirror, described at the end.

### Full Disk Access, and no App Sandbox
- **What:** reads WhatsApp / iMessage / Apple Notes out of the SQLite databases already on your disk (macOS gates these behind Full Disk Access), and the app is not App-Sandboxed (the sandbox and FDA are mutually exclusive).
- **Why essential:** those databases are where your real life lives on your Mac, and there is no API for them. Reading them locally is the whole point — it is what lets the understanding happen on your silicon instead of in someone's cloud.
- **Why safe:** everything read under FDA is processed locally by the on-device model; only PII-stripped summaries ever leave (see the data-flow list below). Reads are copy-then-delete and WAL-safe, so a plaintext copy never lingers.
- **Revoke:** System Settings → Privacy & Security → Full Disk Access, any time.

### Accessibility and Screen Recording — Sentient's own, and only Sentient's (`Driver/`, `System/Permissions.swift`)
- **What:** the hands and eyes of computer use are the open-source [cua driver](https://github.com/trycua/cua) (MIT), which Sentient runs as its **own child process** inside its own macOS permission chain. Acting therefore needs exactly two grants — Accessibility (click, type) and Screen Recording (see windows) — and both belong to **Sentient itself**, the app you already chose to trust. No second helper app ever appears in System Settings, and nothing is ever written into a TCC database to make it work: both grants come from the real macOS consent surfaces (the native Accessibility prompt; the Screen Recording list in System Settings), raised by a one-time setup window the first time you fire an action — never at launch, never during onboarding.
- **Why essential:** clicking another app's UI is what Accessibility gates, and reading the pixels the agent verifies its work against is what Screen Recording gates. An agent that acts on your Mac cannot exist without them.
- **Why safe:** the driver binary is version-pinned, its download is SHA-256-verified against the pinned release, and its code signature is verified against the developer's Apple team identity before it ever executes — Sentient runs the exact bytes it was tested with or nothing. The driver's product telemetry and its self-update channel are disabled in every process Sentient spawns. It acts in the background by design — per-window input with no cursor warp and no focus steal — and a visible agent cursor shows where it is working. The daemon is tied to the app's lifetime: quit Sentient and it is gone.
- **Revoke:** System Settings → Privacy & Security → Accessibility / Screen & System Audio Recording, any time; every computer-use surface stops until re-granted.
- On Macs updating from earlier releases, Sentient also cleans up after its former engine: the one Automation row the 1.x codex-helper path required is deleted at launch and at uninstall.

### Acting on your accounts and your Mac, with layered safeguards (`Cloud/CodexCLI.swift`, `Proactive/ProactiveExecutor.swift`)
When you fire an action, Sentient hands Codex the **least** power that does the job, and wraps every path in independent, overlapping safeguards. There are three paths, each locked down on its own terms:

- **Sending an email or adding a calendar event (a card you tap):** Codex stays inside its Seatbelt sandbox for the whole run — it cannot run shell commands or touch your files — and it is handed a **single-run pre-approval scoped to just that one connector write**, driven by a fixed, app-authored prompt for that one task. It can do the exact thing you tapped, and nothing else. A self-healing check guarantees the send still goes through even if OpenAI later changes its connector surface, so the hardening never costs reliability.
- **The overnight research that drafts your cards:** it only ever reads and drafts, and **three independent guards** stop it from sending anything at all — the prompt forbids it, the sandbox and approval policy auto-cancel any write, *and* the send and delete tools are removed from its toolbox entirely. A prompt-injecting email is yelling instructions at an agent with no hands, no permission, and no orders to obey.
- **Sidekick and computer use (acting in your own apps):** this path runs Codex at full capability — a headless run has no one to answer an approval prompt, and a sandbox would sever the agent from the driver that does the clicking — and it is wrapped in control you can see and feel. It **never runs on its own.** It runs only when **you** start it: you tap a proactive card, or you hold the key and ask Sidekick yourself. Your Mac has to be awake and in front of you, and the instant it runs the notch blooms into a large glowing panel with live status and a **STOP** button that kills the run on one press (the process, not just the animation). The run is hermetic — none of your own Codex plugins or servers load into it — and its only tools are the driver's, taught by a fixed operating manual that bakes in the guardrails: verify every action honestly, never report success on an unconfirmed action, take no destructive step beyond the one declared task. Every instruction is app-authored and fixed — one declared task, never raw web or email text, and page content can never add or re-aim what it does. From the first tap to the last, you are in control.

### Sidekick screenshots (`Notch Magic/CommandRunModel.swift`)
- **What:** when you invoke Sidekick — and only if you granted Screen Recording — Sentient snaps a still of your display(s) and attaches it to that one Codex run, so the agent can see what you're looking at ("finish this for me" has to see "this").
- **Why safe:** it rides the same Screen Recording grant the computer-use engine already explained and asked for (revoke it and Sidekick runs text-only rather than prompting mid-command), the image goes to **your own** Codex/OpenAI (the same place your ChatGPT prompts already go) and **never to a Sentient server**, and the local file is deleted the instant the run ends.

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

Security here is proactive, not reactive. Ahead of the first public release, the whole codebase went through a dedicated security hardening program: adversarial audits by the strongest frontier models (Anthropic's Claude Mythos/Fable 5 and OpenAI's GPT-5.6 Sol) across every logging, capture, network, and privilege surface, paired with line-by-line manual review over more than a week. Among the things that program locked down:

- The crash/telemetry pipeline reports structure only (counts, enums, error-type labels) behind two independent opt-outs, with a scrubber backstop, and every SDK default that captures URLs or request data is forced off as a regression-guarded invariant. See `Diagnostics/Documentation - Diagnostics (Sentry & TelemetryDeck).md`.
- The hosted mirror never logs request paths (the URL carries the user's secret): enforced at import time, covered by a regression test, and belt-and-suspenders in the deploy config, on top of at-rest AES-256-GCM encryption. See `Cloud/Documentation - Cloud - MCP Mirror.md`.
- The root wake helper only ever executes a codesign-verified, untampered app binary, so a user-writable app bundle can never be leveraged for root execution. See `Scheduling/Documentation - Overnight Scheduler & Wake Helper.md`.
- A deterministic PII backstop (`Engine/PIIScan.swift`) sits behind the on-device model's triage, so a slipped raw identifier (SSN, card number, passport number) can never reach the cloud.

The receipts live in the per-feature `Documentation - *.md` files next to the code (the map: `Sentient OS macOS/Documentation - General - README.md`). We would rather show the work than claim it.

## Supported versions

Sentient OS is under active development. Security fixes land in the latest release only, so please make sure the issue reproduces against the newest version.

## Coordinated disclosure

We ask that you give us reasonable time to fix an issue before disclosing it publicly. 90 days is a good default; issues in the hosted mirror will typically be fixed much faster. We are happy to credit you when the fix ships, or keep you anonymous if you prefer.

We do not run a paid bounty program yet. We offer fast fixes, honest credit, and gratitude.
