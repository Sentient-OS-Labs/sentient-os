# Documentation — the map

Per-feature engineering docs for the Sentient OS macOS app. Each doc is the deep reference for one
feature: read it **before** building in that area, and update it once your change is **tested and
confirmed working** (Dev Notes §Documentation practice). The three team-context files in
`Our_Stuff/Claude_Context/` are the product/architecture overview; these docs are the receipts.

## The codebase, folder by folder

Everything lives under `Sentient OS macOS/` (one Xcode synchronized file group — files added/moved
on disk auto-join the target):

| Folder | Job | Docs |
|---|---|---|
| `App/` | Process entry (`main.swift` — the binary doubles as the root wake helper), the SwiftUI app shell + windows, `AppState` | — |
| `Engine/` | On-device inference: `Engine` (LiteRT-LM/Gemma wrapper), `Triage` (the bouncer prompts + verdict parse), the `Verdict` enum, `ModelLocator` | `LiteRT-LM (On-device Inference Engine)/` |
| `Ingestion/` | The reading pipeline: `Connector` protocol + `ItemKey` + `IterativeRun` + `CycleStore` (crash-safe core), the per-source connectors (`Connectors/`), `LifetimeStats` (the lifetime counters the run bumps), `PipelineActivity`, `FactoryReset` | `Iterative Core (Connectors).md` |
| `Sources/` | ALL the sources. The raw local readers — `FilesSource`, `WhatsAppSource`, `iMessageSource`, `NotesSource` (+ `ChatWindowing`, `AddressBookNames`, `SQLiteDB` WAL-safe copy) — AND the two cloud sources, `GmailConnect` + `CalendarConnect` (fetch + summarize via codex, write `CycleStore` directly — the pipeline's "cloud legs"). Plus `SourceSelection`/`CustomRoots` and the `Candidate`/`Artifact` value types | `Files Source (Skipping & Caps).md` · `WhatsApp Source (ChatStorage).md` · `iMessage Source (chat.db).md` · `Apple Notes Source (NoteStore).md` · `Gmail Connector (Codex).md` · `Calendar Connector (Codex).md` |
| `Vault/` | The knowledge base: `VaultGenerator` (first build), `VaultCloud` (create/update + mirror push), `VaultActivity` (dirty flag + debounced sync) | `Vault Generation (Stage 2).md` |
| `Proactive/` | Proactive Intelligence, all three parts: `Proactive` (judge) → `ProactiveResearch` (verify + prepare) → `ProactiveExecutor` (fire), plus `ProactiveCycle` (the shared post-read tail) and `GiftLetter` (the welcome letter) | `Proactive Intelligence (Judge).md` |
| `Cloud/` | The codex compute spine: `CodexCLI` (`codex exec` wrapper — the ONLY cloud-model path), `CodexSetup` + `ComputerUseSetup` (the 3-step setup engine), `CodexAuth` (ChatGPT plan detection + on-demand token refresh — the free/go plan gate), `AgentStatus` (the `STATUS: DONE/COULD_NOT` sentinel parser shared by the executor + Sidekick), `MirrorClient` (the hosted MCP mirror) | `CodexCLI (codex exec Compute Spine).md` · `Codex Setup Handoff (Onboarding).md` · `Plan Gate (CodexAuth & Knowledge-Base-Only).md` · `Computer-Use Bootstrap (Codex Reverse-Engineering).md` · `Computer-Use Skill Patch (Confirmation Policy).md` · `MCP Mirror Client.md` |
| `Scheduling/` | The overnight 3am machinery: `OvernightScheduler`, the root `WakeHelper` (+ client/installer/protocol), `PowerState` gates, `LoginItem`, `OvernightCaution` (the morning-after failure classification behind the home's banner) | `Overnight Scheduler (3am Wake).md` |
| `Notch Magic/` | Sidekick: the hold-to-talk hotkey (right ⌘ / right ⌥, `SidekickHotkeyMonitor`), on-device voice, the per-command screen still (`ScreenCapture`), the one shared command run, and the living notch overlay | `Notch Magic/Notch Magic.md` |
| `Diagnostics/` | `Log()` (the print replacement + dev-log tee), `CrashReporting` (Sentry), `Analytics` (TelemetryDeck), the sensors that feed them — `SourceHealth` (listing-collapse + extraction-rate memory) + `ExecutorScoreboard` (per-fire outcomes) | `Crash Reporting (Sentry).md` · `Diagnostics (Sentry).md` · `Product Analytics (TelemetryDeck).md` · `Source Diagnostics & Hardening (Sentry).md` |
| `System/` | macOS integration: `Permissions` (FDA/TCC/Automation grants), `Notify` (notifications — `ask()` wired into onboarding; `now()` sending still dormant), `AppLanguage` / `ResponseLanguage` / `SpeechOutput` (Settings → System language prefs) | `Localization (i18n).md` |
| `Views/` | The UI: the For You home + cards + command bar, popovers, processing takeover, `Knowledge/` (viewer/editor), `Settings/` (the five panes), `Permissions/` (the first-use gate + the floating drag-into-Settings guide), the connect sheets, `Theme` | `Home — Proactive Intelligence (For You).md` · `Knowledge Viewer.md` · `Settings.md` · `Permission Guide (First-Use Grants).md` |
| `Views/Dev/` | Dev-only surfaces: `DevToolsView` (the cockpit), `OvernightDevView`, `PermissionsView`, `HotkeyLabView`, `SummariesView`, `ProactiveItemsView`, `ProactiveExecuteView` | — |
| `Self Tests - Temp/` | Kept EMPTY — self-tests are scaffolding, recreated on demand | `Self-Testing (Eval Harness).md` |

## Odds and ends

- `Bundle Size (Arch Thinning & Doc Stripping).md` — the build phase that thins the LiteRT dylib and
  strips these very docs from the shipped .app.
- `Source Diagnostics & Hardening (Sentry).md` — the long design/history record behind the
  diagnostics; `Diagnostics (Sentry).md` is the concise live reference.
