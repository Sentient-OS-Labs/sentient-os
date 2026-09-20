# Dev Tools (Views/Dev/)

The developer cockpit. Compiled into DEBUG builds only (the home's DEV TOOLS handle is `#if DEBUG` and
is the sheet's only opener, so none of this is reachable in Release). Everything here drives the same
seams the shipping UI uses; nothing has its own processing path.

## Files

| File | Job |
|---|---|
| `DevToolsView.swift` | The sheet: the INITIAL / ITERATIVE columns, the proactive buttons, the source pickers, MCP controls, FDA re-check, Reset everything, the demo knobs, and the doors to the other dev surfaces. |
| `OvernightDevView.swift` | The overnight cockpit in its own window: approve the helper (the SMAppService path), launch at login, test the 14 h auto-enable with a shortened wait, manual arm at a chosen time; a live status panel polls every 2 s. |
| `ProactiveExecuteView.swift` | PART 3's bench: the real ready-to-fire `PreparedAction`s from the last research run, each with a working FIRE button through `ProactiveExecutor`. |
| `ProactiveItemsView.swift` | The last judge run's items in full detail. |
| `SummariesView.swift` | The current cycle's survivor summaries in `CycleStore`, with Export / Import (dump the whole set to JSON, or load one to REPLACE this machine's set, backing up first; pointers are never touched). |
| `PermissionsView.swift` | Every macOS grant Sentient cares about (all its own now), with re-checks and the legacy Automation-row cleanup. |
| `HotkeyLabView.swift` | The bench that proved the permission-free hotkey (NSEvent `flagsChanged` monitors). Superseded by `SidekickHotkeyMonitor`; kept for feel-testing. |
| `../CodexSetupView.swift` | The three-step Codex setup window over the shared `CodexSetup` engine (in `Views/`). |

## What the main sheet offers

- **INITIAL:** start / resume (top → bottom, `.auto`) · tell cloud "go make knowledge base exist" (`VaultCloud.create`) · proactive system (the judge).
- **ITERATIVE:** start on device (bottom → top, `.iterative`) · tell cloud "go update knowledge base" · proactive system.
- **proactive RESEARCH + PREPARE** (part 2 over the last judge run, with the live calendar fetched when connected) · **proactive EXECUTE** (opens the window) · VIEW SUMMARIES · VIEW ACTION ITEMS · PERMISSIONS · HOTKEY LAB · CODEX SETUP · Overnight Processing….
- **PROACTIVE CARDS:** the 3-way deck (`real` / `jesai` / `launch`; `real` is the shipping default; the demo decks are pitch mode). Two screen-recording knobs for the takeover: a resizable analysis window (drops the min frame and the Stop footer) and a demo bar baseline (opens the bar mid-run; display-only).
- **SOURCES:** the same `dbg.*` selection Settings uses (custom roots, chat pickers, Gmail / Calendar connect sheets).
- **MCP:** toggle, Copy MCP Link, Copy System Prompt, MCP SYNC (a forced push), Stats.
- **DOUBLE TAP:** the on/off switch, the route (Sentient relay, the shipped default, with a URL override for previews or `wrangler dev`; or a dev OpenAI key saved to the Keychain, never to defaults), and the last run's timing line (capture, first text, total, token counts, verdict). See `Double Tap/Documentation - Double Tap.md`.
- Full Disk Access re-check / grant / relaunch, and **Reset everything** (the shared `FactoryReset`).

Console visibility: `Log()` tees to `/tmp/sentient-dev.log` in DEBUG; `tail -f` it while clicking
around. Headless self-tests are documented in `Documentation - General - Self-Testing (Eval Harness).md`.

## Related docs

`Ingestion/Documentation - Ingestion Pipeline.md`, `Proactive/Documentation - Proactive Intelligence.md`, `Scheduling/Documentation - Overnight Scheduler & Wake Helper.md`, `Cloud/Documentation - Cloud - Codex Setup.md`, `Driver/Documentation - Driver (cua-driver).md`, `Cloud/Documentation - Cloud - MCP Mirror.md`, `Double Tap/Documentation - Double Tap.md`.
