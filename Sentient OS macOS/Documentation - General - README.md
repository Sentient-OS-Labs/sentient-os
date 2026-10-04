# Sentient: features, privacy and the codebase

Sentient OS documents itself **per feature, next to the code**. Every folder under `Sentient OS macOS/`
that carries a feature holds a `Documentation - <Feature>.md` (two files where a feature is big enough
to deserve a split). The few general, cross-cutting notes sit at the source root as
`Documentation - General - <Topic>.md` (this map is one of them). Read a feature's doc before building in that area, and update it when the implementation changes. Keep public
explanations grounded in the current source and verified behavior.

Docs are written for a reader who has never seen the code: what the feature does, the files and their
jobs, how it works at a mid level, the rules and sharp edges that break things when ignored, and where
to look next. Plain language, no invented terms, no changelog clutter; the code is the source of truth
for details.

## One understanding, three ways to act

Sentient builds useful context from the sources you choose, then brings that context into the small
moments that fill your day. **The work between the work adds up.** These are the three ways to use it:

| Feature | What it does | Start here |
|---|---|---|
| **Sidekick: when you ask.** | Click the notch, type, or hold the Sidekick key to speak. Hand off the task in front of you using your screen and knowledge as context, in your own apps and logged-in browser. | [Sidekick](Notch%20Magic/Documentation%20-%20Sidekick%20-%20General.md) |
| **Double Tap: in two taps.** | Double tap the Sidekick key, right Command by default, to draft a reply in the focused field using the visible conversation, your knowledge and one-time writing examples. You review and send it. | [Double Tap](Double%20Tap/Documentation%20-%20Double%20Tap.md) |
| **Proactive intelligence: before you ask.** | Wake up to useful drafts, plans and suggestions prepared from your context. Review them and start the action with a click. | [Proactive intelligence](Proactive/Documentation%20-%20Proactive%20Intelligence.md) |

For example: hand off a registration you have started, draft a client update using relevant project
knowledge, or catch a follow-up you forgot. The important connection is context from across your life,
not just text on the current screen. These are illustrative workflows; the available information,
model and task determine what Sentient can complete.

## Personal AI. Privacy at its core.

**On-device understanding. Your choice of AI. Knowledge you own.**

1. **Understand locally.** Sentient's on-device model analyzes enabled files, saved screenshots,
   conversations, Apple Notes, Apple Mail and Apple Calendar. The raw source material is not uploaded
   for this analysis. [Local sources](Sources/Documentation%20-%20Sources%20-%20Local%20(Files,%20WhatsApp,%20iMessage,%20Notes).md)
2. **Choose the AI that puts it to work.** Your chosen model consolidates useful summaries into
   knowledge, prepares suggestions and powers Sidekick. Use your ChatGPT/Claude account, a compatible
   API provider or supported larger local model. Apple Mail and Calendar work without a subscription.
   [Model choice](Cloud/Documentation%20-%20Cloud%20-%20Frontier%20Model%20Choice%20(BYOM).md)
3. **Keep the knowledge.** The result is readable, editable Markdown in a folder on your Mac, with
   a Reader View and a Constellation View. Optional sharing lets other AIs use it too.
   [Knowledge](Vault/Documentation%20-%20Knowledge%20Base%20(Vault).md) ·
   [Sharing](Cloud/Documentation%20-%20Cloud%20-%20MCP%20Mirror.md)

No separate Sentient account is required. The app and supporting infrastructure are open source.
Double Tap has its own provider controls, including local options and a low-latency covered OpenAI
API route with Zero Data Retention. Sharing is a separate opt-in with on-Mac encryption, no persisted
relay key, and in-memory decryption for authorized requests.

At 3 AM, Sentient can wake your Mac with the lid closed to do the understanding and preparation.
Keep it running in the menu bar, with wake setup complete and the power conditions met. The user
starts proposed actions; overnight preparation does not send replies or execute computer tasks.
[Overnight setup](Scheduling/Documentation%20-%20Overnight%20Scheduler%20%26%20Wake%20Helper.md)

The [security policy](../SECURITY.md) explains permissions, service boundaries and vulnerability
reporting. The in-app policy and shared wording live in `Views/Settings/PrivacyCopy.swift`. Feature
guides describe implementation rather than substituting for provider policies.

## The codebase, folder by folder

Everything lives under `Sentient OS macOS/` (one Xcode synchronized file group: files added or moved on
disk join the target automatically, and the docs are stripped from the shipped bundle by a build phase).

| Folder | Job | Doc |
|---|---|---|
| `App/` | The entry point (the binary doubles as the root wake helper), the app scenes and windows, `AppState`, the Dock policy | `App/Documentation - App Shell.md` |
| `Engine/` | On-device inference: the LiteRT-LM wrapper around Gemma 4 E4B, triage prompts and verdicts, the PII backstop, the model locator and downloader | `Engine/Documentation - On-Device Engine & Triage.md` |
| `Ingestion/` | The reading pipeline: `Connector` → `IterativeRun` → `CycleStore` (crash-safe, per-bucket marks), the connectors, lifetime stats, `FactoryReset` | `Ingestion/Documentation - Ingestion Pipeline.md` |
| `Sources/` | The readers: Files, WhatsApp, iMessage, Apple Notes, Apple Mail and Apple Calendar (local), Gmail and Google Calendar (through the user's codex or claude.ai connectors), the shared selection and chat windowing | `Sources/Documentation - Sources - Local (Files, WhatsApp, iMessage, Notes).md` · `Sources/Documentation - Sources - Cloud (Gmail, Calendar).md` |
| `Cloud/` | The two frontier engines (`codex exec` + `claude -p`) behind FrontierRun's dispatch, the setup engines, the plan gate, bring-your-own-model, the MCP mirror client | `Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md` · `… - ClaudeCLI (the claude -p engine).md` · `… - Codex Setup.md` · `… - Plan Gate (CodexAuth).md` · `… - Frontier Model Choice (BYOM).md` · `… - MCP Mirror.md` |
| `Cloud/Mail Accounts/` | Disclosed email-only founder-feedback list, separate write authentication and local retry queue | `Cloud/Mail Accounts/Documentation - Connected Email Accounts.md` |
| `Connectors/` | Sentient-owned OAuth for supported remote MCP services, credential lifecycle, native discovery, and per-engine tool policy | `Connectors/Documentation - Connectors (Direct MCP).md` |
| `Driver/` | Native OpenAI computer use for all backends, dependency setup, and legacy CUA cleanup | `Driver/Documentation - Native Computer Use.md` · `Driver/Documentation - Driver (cua-driver).md` |
| `Vault/` | The knowledge base: first build, nightly updates, one-time writing examples, corpus batching and sync | `Vault/Documentation - Knowledge Base (Vault).md` |
| `Proactive/` | Proactive Intelligence: the cycle, judge → research and prepare → the executor, the gift letter | `Proactive/Documentation - Proactive Intelligence.md` |
| `Scheduling/` | The 3 AM run: the scheduler, the root wake helper and its installer, power gates, launch at login, the morning-after caution | `Scheduling/Documentation - Overnight Scheduler & Wake Helper.md` |
| `Notch Magic/` | Sidekick: the hotkey, voice, the shared run, the notch overlay | `Notch Magic/Documentation - Sidekick - General.md` · `Notch Magic/Documentation - Sidekick - Notch Window & Visual.md` |
| `Double Tap/` | Double Tap: two taps of the Sidekick key (right ⌘ by default), an unsent contextual reply, editable one-time writing examples and independent cloud/local provider choice | `Double Tap/Documentation - Double Tap.md` |
| `System/` | Permissions (FDA, Sentient's action grants, TCC reads), the live health ladder, notifications, uninstall | `System/Documentation - System (Permissions, Health, Uninstall).md` |
| `Diagnostics/` | `Log()`, Sentry, TelemetryDeck, the executor scoreboard, the source-health sensors | `Diagnostics/Documentation - Diagnostics (Sentry & TelemetryDeck).md` |
| `Updates/` | Sparkle auto-update and the release pipeline (`Scripts/`) | `Updates/Documentation - Auto-Update (Sparkle) & Release Pipeline.md` |
| `Views/` | The home, the processing takeover, the cards, the popovers, the connect surfaces, the shared design pieces | `Views/Documentation - Views - Home, Processing & Shared UI.md` |
| `Views/Settings/` | The Settings window and its seven panes, the uninstall sheet, the privacy policy | `Views/Settings/Documentation - Settings.md` |
| `Views/Knowledge/` | The Knowledge window: the Constellation View, the reader, the editor | `Views/Knowledge/Documentation - Knowledge Window (Constellation & Reader).md` |
| `Views/Onboarding/` | First launch, step by step | `Views/Onboarding/Documentation - Onboarding.md` |
| `Views/Permissions/` | The first-use permission gate, persistent upgrade coordinator and scene guard, and floating drag-into-Settings guide | `Views/Permissions/Documentation - Permission Gate & Guide.md` |
| `Views/Dev/` | The dev cockpit (DEBUG only) | `Views/Dev/Documentation - Dev Tools.md` |
| `Media/` | The bundled tutorial clips for the Connect your AIs window | (in the Views doc) |
| `Self Tests - Temp/` | Kept EMPTY; self-tests are scaffolding, recreated on demand | `Documentation - General - Self-Testing (Eval Harness).md` |
| `Vendor/LiteRTLM/` (repo root) | The vendored LiteRT-LM SwiftPM package, pinned v0.13.1 | (in the Engine doc) |
| `Scripts/` (repo root) | `make_dmg.sh` and `release.sh` | (in the Updates doc) |

## The general notes (source root)

- `Documentation - General - Self-Testing (Eval Harness).md`: how we verify backend behavior headlessly with the real binary.
- `Documentation - General - Bundle Size & Build Phases.md`: the build phases (dylib thinning, doc stripping, dSYM upload, the daemon plist copy).

## Repo-level files worth knowing

`README.md` (the public face), `SECURITY.md` (data paths, permissions, service boundaries and vulnerability reporting), `CONTRIBUTING.md`, `LICENSING.md` + `CLA.md` (AGPL with
a commercial exception), `Signing.xcconfig` (the ONE place the signing team lives; per-dev override in
the gitignored `Signing.local.xcconfig`), `Info.plist` (the Sparkle keys only), the entitlements (audio input and Apple Events, for the Hardened Runtime), and `jesai.Sentient-OS-macOS.WakeHelper.plist` (the bundled daemon
plist the dev cockpit's SMAppService path uses).
