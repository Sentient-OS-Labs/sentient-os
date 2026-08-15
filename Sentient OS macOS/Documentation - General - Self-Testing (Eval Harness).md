# Self-Testing: the headless eval harness

How we verify backend behavior: run the REAL app binary headless with an environment variable, exercise
the actual code paths, print the results, exit. No UI, no guessing. Self-tests are scaffolding: write one
to nail a behavior, then delete it. That is why `Self Tests - Temp/` is named Temp and kept empty.

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

2. **The hook.** Re-add the one-line call in the app struct's `init()` (`App/Sentient_OS_macOSApp.swift`; the placeholder comment marks the spot), under `#if DEBUG`, so it runs before the UI launches. Note `main.swift` is the real entry and branches into the wake helper first.
3. **The test.** Call the real code (`Engine`, a connector, `CodexCLI`, `MirrorClient`, …), print or assert, and use `Log()` so `/tmp/sentient-dev.log` carries it.

Knobs are just more environment variables: `SENTIENT_MODEL_PATH` (the on-device model),
`SENTIENT_VAULT_ROOT` (a scratch knowledge-base folder), `SENTIENT_MIRROR_BASE` (a local mirror
server), `SENTIENT_SLICE_BUDGET` (force multi-part corpus runs), plus whatever your test reads. All are
DEBUG-only by design.

## Running it (mind the two-builds gotcha)

Self-tests launch the **Debug binary directly**, not through Xcode's Run.

1. Build the Debug app through the Xcode GUI (the Xcode MCP `BuildProject` or ⌘B): that build owns the real accumulated database and knowledge base at `~/Library/Developer/Xcode/DerivedData/Sentient_OS_macOS-<hash>/Build/Products/Debug/`. A CLI `xcodebuild` must be isolated with `-derivedDataPath /tmp/…` (it shares the GUI's DerivedData otherwise and leaves an ad-hoc-signed LiteRT dylib that breaks the next Run); an isolated build is a fresh app with no data.
2. Run headless: `SENTIENT_SELFTEST=mything SENTIENT_MODEL_PATH=… "<Debug>/Sentient OS.app/Contents/MacOS/Sentient OS"`. `AppState` skips every launch side effect under `SENTIENT_SELFTEST` (the scheduler, the hotkey, the updater, the model download, the codex install), and `Notify` is silent, so a test can never trip a password dialog or a permission prompt.
3. Inspect, iterate, then DELETE the test.

## Modes that existed and can be recreated

`codexcli` (discovery → ping → a real run, envelope dumped) · `vault` (a full knowledge-base build
into a scratch root) · `mirror` (enable → push → stats → delete → disable) · `fileiter` / `chatiter` /
`notesiter` (the pipeline per source) · `skipping` / `skipcensus` (the Files prune rules on fixtures /
a read-only real-Mac census of what gets pruned and why) · `tokens` (exact prefill/decode counts for the
chat window budget, via `Engine(collectStats: true)`) · `parse` / `whatsapp` (triage JSON parsing / the
WhatsApp windows the model would see) · `imdecode` / `notesdecode` (the two decoders' rates) ·
`modeldownload` (the downloader against the real job into a scratch dir: crash mid-download, resume to
completion and verify, a flipped hash must refuse and wipe).
