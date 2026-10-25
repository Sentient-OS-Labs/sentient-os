# Self-Testing: the headless eval harness

How we verify backend behavior: run the REAL app binary headless with an environment variable, exercise
the actual code paths, print the results, exit. `Self Tests - Temp/` is a historical folder name;
the checked-in DEBUG-only fixtures and their Scripts runners provide repeatable regression evidence.
Native UI fixtures additionally render and interact with only owned, isolated windows.

The eval ladder, fastest to most real: the Xcode MCP `ExecuteSnippet` (run a snippet in a file's
context, see prints) → a self-test (the real code over real data, this doc) → a full app run.

## Recreating the harness (three steps)

1. **The dispatcher.** Drop a tiny `SelfTest.swift` in `Self Tests - Temp/` that reads `SENTIENT_SELFTEST`, routes to your test in a `Task`, and calls `exit(0)` before any window opens:

   ```swift
   enum SelfTest {
       @MainActor static func runIfRequested() {
           guard let mode = ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] else { return }
           Task {
               switch mode {
               case "mything": await SelfTestMyThing.run()
               default: print("SELFTEST: unknown mode '\(mode)'")
               }
               exit(0)
           }
       }
   }
   ```

2. **The hook.** The DEBUG dispatcher already exists. `main.swift` routes isolated `sidekickapp` and
   `nativecua` modes before AppState; use those validated bootstraps for real-app UI/native tests.
   The ordinary app initializer retains `SelfTest.runIfRequested()` for older headless fixtures.
3. **The test.** Call the real code (`Engine`, a connector, `CodexCLI`, `MirrorClient`, …), print or assert, and use `Log()` so `/tmp/sentient-dev.log` carries it.

Knobs are just more environment variables: `SENTIENT_MODEL_PATH` (the on-device model),
`SENTIENT_VAULT_ROOT` (a scratch knowledge-base folder), `SENTIENT_MIRROR_BASE` (a local mirror
server), `SENTIENT_SLICE_BUDGET` (force multi-part corpus runs), plus whatever your test reads. All are
DEBUG-only by design.

## Running it (mind the two-builds gotcha)

Self-tests launch the **Debug binary directly**, not through Xcode's Run.

1. Build the Debug app through Xcode or use an isolated CLI `xcodebuild -derivedDataPath /tmp/…`. Do not reuse the GUI's DerivedData: CLI signing can replace its LiteRT dylib and break the next Run. A separate build directory isolates build products only; a normally launched app with the same bundle identity still uses the user's preferences and Application Support. Use a runner that establishes isolated defaults and data roots before constructing app services.
2. Run headless: `SENTIENT_SELFTEST=mything SENTIENT_MODEL_PATH=… "<Debug>/Sentient OS.app/Contents/MacOS/Sentient OS"`. `AppState` skips automatic launch side effects under `SENTIENT_SELFTEST` (scheduler, hotkey, updater, model download and Codex install), and `Notify` is silent. The flag alone does not isolate preferences or make arbitrary test code safe: each fixture must guard its own explicit I/O and permission actions.
3. Inspect receipts and captures. Keep focused regression checks; temporary exploratory fixtures can be removed.

## Onboarding regression checks

`test_personal_setup_flow.py`, `test_source_consent.py`, `test_processing_source_readiness.py`,
`test_health_requirements.py`, and `test_sidekick_plan_recovery.py` compile actual policies with
synthetic collaborators and isolated preferences. Permission readiness, pending-request and safe
relaunch scripts exercise cancellation, live-proof lifetime and subprocess handoff without real
permissions or model calls.

Run `test_personal_setup_home.py --app <signed Debug app>` and `test_personal_setup_sources.py --app
<signed Debug app>` for native UI verification. They install a process-local preference suite before
AppState, redirect app support/vault data to marked fixture roots, and prohibit provider submission.
Receipts include interaction/layout assertions and owned-window captures. Optional `--manual-review`
on the Home runner holds the fixture for CUA inspection, then runs the same assertions.
`--presentation-capture` adds a 1280×760 empty-Home capture and wide captures of each interactive
showcase, including prepared artifacts. It verifies whole-window bounds and primary controls;
it does not alter the production UI.

`test_native_permissions_no_fda.py --app <signed Debug app>` is the live model-free capability
check. It copies only verified runtime code, denies TCC database access and live app-data access,
captures only its synthetic window, and writes boolean evidence. It never changes TCC or logs in.
The system database must be demonstrably denied. A missing per-user database is reported separately
from a denial; either way, neither database may supply permission evidence to the capability check.
It deliberately refuses to displace a competing computer-use helper; run it only when that helper's
owner can safely release it. This is separate from the synthetic permission regression suites.

## Modes that existed and can be recreated

`codexcli` (discovery → ping → a real run, envelope dumped) · `vault` (a full knowledge-base build
into a scratch root) · `mirror` (enable → push → stats → delete → disable) · `fileiter` / `chatiter` /
`notesiter` (the pipeline per source) · `skipping` / `skipcensus` (the Files prune rules on fixtures /
a read-only real-Mac census of what gets pruned and why) · `tokens` (exact prefill/decode counts for the
chat window budget, via `Engine(collectStats: true)`) · `parse` / `whatsapp` (triage JSON parsing / the
WhatsApp windows the model would see) · `imdecode` / `notesdecode` (the two decoders' rates) ·
`modeldownload` (the downloader against the real job into a scratch dir: crash mid-download, resume to
completion and verify, a flipped hash must refuse and wipe).
