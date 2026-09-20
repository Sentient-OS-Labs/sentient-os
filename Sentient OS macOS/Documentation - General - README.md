# Documentation: the map

Sentient OS documents itself **per feature, next to the code**. Every folder under `Sentient OS macOS/`
that carries a feature holds a `Documentation - <Feature>.md` (two files where a feature is big enough
to deserve a split). The few general, cross-cutting notes sit at the source root as
`Documentation - General - <Topic>.md` (this map is one of them). Read a feature's doc
before building in that area, and update it once your change is tested and confirmed working (the
rule lives in the team's `3_Dev_Notes_and_Rules.md`).

Docs are written for a reader who has never seen the code: what the feature does, the files and their
jobs, how it works at a mid level, the rules and sharp edges that break things when ignored, and where
to look next. Plain language, no invented terms, no changelog clutter; the code is the source of truth
for details.

## The codebase, folder by folder

Everything lives under `Sentient OS macOS/` (one Xcode synchronized file group: files added or moved on
disk join the target automatically, and the docs are stripped from the shipped bundle by a build phase).

| Folder | Job | Doc |
|---|---|---|
| `App/` | The entry point (the binary doubles as the root wake helper), the app scenes and windows, `AppState`, the Dock policy | `App/Documentation - App Shell.md` |
| `Engine/` | On-device inference: the LiteRT-LM wrapper around Gemma 4 E4B, triage prompts and verdicts, the PII backstop, the model locator and downloader | `Engine/Documentation - On-Device Engine & Triage.md` |
| `Ingestion/` | The reading pipeline: `Connector` → `IterativeRun` → `CycleStore` (crash-safe, per-bucket marks), the connectors, lifetime stats, `FactoryReset` | `Ingestion/Documentation - Ingestion Pipeline.md` |
| `Sources/` | The readers: Files, WhatsApp, iMessage, Apple Notes (local), Gmail and Google Calendar (through the user's codex or claude.ai connectors), the shared selection and chat windowing | `Sources/Documentation - Sources - Local (Files, WhatsApp, iMessage, Notes).md` · `Sources/Documentation - Sources - Cloud (Gmail, Calendar).md` |
| `Cloud/` | The two frontier engines (`codex exec` + `claude -p`) behind FrontierRun's dispatch, the setup engines, the plan gate, bring-your-own-model, the MCP mirror client | `Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md` · `… - ClaudeCLI (the claude -p engine).md` · `… - Codex Setup.md` · `… - Plan Gate (CodexAuth).md` · `… - Frontier Model Choice (BYOM).md` · `… - MCP Mirror.md` |
| `Connectors/` | Sentient-owned OAuth for supported remote MCP services, credential lifecycle, native discovery, and per-engine tool policy | `Connectors/Documentation - Connectors (Direct MCP).md` |
| `Driver/` | The cua driver — the hands and eyes of computer use: the pinned binary, Sentient's embedded daemon, the hybrid MCP + CLI transport, the inlined skill | `Driver/Documentation - Driver (cua-driver).md` |
| `Vault/` | The knowledge base: first build, nightly updates, corpus batching, the sync seam | `Vault/Documentation - Knowledge Base (Vault).md` |
| `Proactive/` | Proactive Intelligence: the cycle, judge → research and prepare → the executor, the gift letter | `Proactive/Documentation - Proactive Intelligence.md` |
| `Scheduling/` | The 3 AM run: the scheduler, the root wake helper and its installer, power gates, launch at login, the morning-after caution | `Scheduling/Documentation - Overnight Scheduler & Wake Helper.md` |
| `Notch Magic/` | Sidekick: the hotkey, voice, the shared run, the notch overlay | `Notch Magic/Documentation - Sidekick - General.md` · `Notch Magic/Documentation - Sidekick - Notch Window & Visual.md` |
| `Double Tap/` | Double Tap: two taps of right ⌥ draft the reply to the email or message on screen, from one screenshot plus the whole knowledge base, pasted into the focused field | `Double Tap/Documentation - Double Tap.md` |
| `System/` | Permissions (FDA, Sentient's action grants, TCC reads), the live health ladder, notifications, uninstall | `System/Documentation - System (Permissions, Health, Uninstall).md` |
| `Diagnostics/` | `Log()`, Sentry, TelemetryDeck, the executor scoreboard, the source-health sensors | `Diagnostics/Documentation - Diagnostics (Sentry & TelemetryDeck).md` |
| `Updates/` | Sparkle auto-update and the release pipeline (`Scripts/`) | `Updates/Documentation - Auto-Update (Sparkle) & Release Pipeline.md` |
| `Views/` | The home, the processing takeover, the cards, the popovers, the connect surfaces, the shared design pieces | `Views/Documentation - Views - Home, Processing & Shared UI.md` |
| `Views/Settings/` | The Settings window and its six panes, the uninstall sheet, the privacy policy | `Views/Settings/Documentation - Settings.md` |
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

`README.md` (the public face), `SECURITY.md` (the privacy invariants as security claims, why each
capability is needed, the hardening program), `CONTRIBUTING.md`, `LICENSING.md` + `CLA.md` (AGPL with
a commercial exception), `Signing.xcconfig` (the ONE place the signing team lives; per-dev override in
the gitignored `Signing.local.xcconfig`), `Info.plist` (the Sparkle keys only), the entitlements (audio
input, for the Hardened Runtime), and `jesai.Sentient-OS-macOS.WakeHelper.plist` (the bundled daemon
plist the dev cockpit's SMAppService path uses).
