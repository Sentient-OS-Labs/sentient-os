# Self-Testing — the headless eval harness

**How we verify backend behavior: run the REAL app binary headless with an env var, exercise the
actual code paths, print the results, exit — no UI, no guessing.** This is the project's eval culture.
Self-tests are *scaffolding*: you write one to nail a behavior, then delete it. That's why
`Self Tests - Temp/` is named "Temp" — and why **it's kept empty** (the accumulated tests were
cleared). When you need to verify something, recreate just the test you need using the pattern below.

> The eval ladder, fastest → most real: **Xcode MCP `ExecuteSnippet`** (run a snippet in a file's
> context, see prints) → **a self-test** (the real code over real data, this doc) → **a full app run**.

## How the harness works (recreate it in 3 steps)

### 1. The dispatcher
Drop a tiny dispatcher in `Self Tests - Temp/` (e.g. `SelfTest.swift`). It reads `SENTIENT_SELFTEST`
and routes to your test, then exits:

```swift
import Foundation

enum SelfTest {
    /// Called from the @main app's init() under #if DEBUG, BEFORE the UI exists.
    @MainActor static func runIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] else { return }
        Task {
            switch mode {
            case "mything": await SelfTestMyThing.run()
            // add more modes here
            default: print("SELFTEST: unknown mode '\(mode)'")
            }
            exit(0)   // headless: we ran, now quit before any window opens
        }
    }
}
```

### 2. The hook
Re-add the one-line call in the app struct (`App/Sentient_OS_macOSApp.swift` — note: `@main` itself is `App/main.swift`, which branches into the wake helper first), under `#if DEBUG`,
so it runs before the UI launches:

```swift
init() {
    #if DEBUG
    SelfTest.runIfRequested()
    #endif
}
```
*(There's a placeholder comment there now pointing here.)*

### 3. The test
Write the actual test — it calls the real code and prints/asserts. Use `Log()` (it tees to
`/tmp/sentient-dev.log` in DEBUG) so you can `tail -f` it:

```swift
enum SelfTestMyThing {
    static func run() async {
        Log("SELFTEST mything: start")
        // ... call the REAL code path (Engine, a Connector, CodexCLI, MirrorClient, …) ...
        // ... print outputs; for assertions just compare + Log("✓"/"✗ …") and count failures ...
        Log("SELFTEST mything: done")
    }
}
```

**Knobs** are just more env vars read via `ProcessInfo` — past tests used `SENTIENT_SELFTEST_N`
(how many items), `SENTIENT_SELFTEST_OUT` (a dump-file path), `SENTIENT_MODEL_PATH` (the on-device
model), `SENTIENT_MIRROR_BASE` (point the mirror client at a local server), `SENTIENT_VAULT_ROOT`
(a scratch knowledge-base dir).

## How to RUN it (mind the two-builds gotcha)

Self-tests launch the **Debug binary directly**, not through Xcode's Run.

1. **Build the Debug app.** Prefer the Xcode-GUI build (the Xcode MCP `BuildProject`, or ⌘B) — that's
   the build with the **real accumulated database + knowledge base**, in
   `~/Library/Developer/Xcode/DerivedData/Sentient_OS_macOS-<hash>/Build/Products/Debug/`. Glob that
   path, or ask the user. ⚠️ The `xcodebuild` CLI builds into its OWN DerivedData — a fresh app with
   no database; fine for compiling, wrong for data-dependent tests.
2. **Run headless with the env var:**
   ```sh
   SENTIENT_SELFTEST=mything \
   SENTIENT_MODEL_PATH="/path/to/gemma-4-E4B-it.litertlm" \
     "<DerivedData>/.../Debug/Sentient OS.app/Contents/MacOS/Sentient OS"
   ```
   It runs the test, prints to stdout (and `/tmp/sentient-dev.log` via `Log()`), and `exit(0)`s before
   any window opens. Notifications are auto-silenced while `SENTIENT_SELFTEST` is set (`Notify.swift`).
3. **Inspect, iterate, then DELETE the test** when the behavior is nailed (the "Release strip"
   enforces an empty folder; don't let scaffolding rot).

## Past modes you can recreate on demand

These were useful self-test modes that lived here before the cleanup; the per-feature docs still name
them. Recreate the one you need with the pattern above:

| Mode (`SENTIENT_SELFTEST=`) | Verifies |
|---|---|
| `codexcli` | `CodexCLI` discovery → ping → a real `codex exec` run, envelope dumped |
| `vault` | `VaultGenerator` full knowledge-base build (+ `SENTIENT_VAULT_ROOT` scratch dir) |
| `mirror` | `MirrorClient` enable → push → stats → delete → disable (against prod or `SENTIENT_MIRROR_BASE`) |
| `fileiter` / `chatiter` / `notesiter` | the `Connector → IterativeRun → CycleStore` pipeline per source |
| `skipping` / `skipcensus` | the Files prune rules (fixture assertions) / a real-Mac prune census |
| `tokens` | exact prefill/decode token counts for the chat window budget |
| `parse` / `whatsapp` | Triage JSON parsing / the WhatsApp windows the model would see |
| `imdecode` / `notesdecode` | the iMessage `attributedBody` / Apple Notes gunzip+protobuf decoders |

> Keep this doc true: if you build a self-test worth keeping around for a while, note its mode here;
> when you delete it, the folder goes back to empty.
