Hey Claude!

LiteRT-LM keeps getting updates, but we use a local copy of LiteRT-LM imported as a local SwiftPM dependency in Xcode (`Vendor/LiteRTLM/`, pinned **v0.13.1**).

In this folder are two reference docs pulled from LiteRT-LM's website (the Overview page and the Swift API page). Whenever we update to a newer LiteRT-LM build, you'd want to clone the latest version of the LiteRT-LM codebase from their main branch (it lives at the workspace root as `LiteRT-LM Codebase for Reference/`) and refresh those two website docs too.

Below are the notes on **our** current on-device inference code. Keep this in sync whenever you touch this part of Sentient OS — the code is the source of truth.

---
---
---

# On-device inference — implementation notes

> Everything future-Claude (or future-human) needs to know about the macOS on-device inference stack. The wrapper is `Engine.swift`; it's driven by `IterativeRun.swift`; the model file is found by `ModelLocator.swift`.

> **⚠️ Scope.** This documents the **macOS** app (Gemma 4 **E4B**). The old iOS app — with its `OnDeviceInference.swift`, `ScreenshotProcessor.swift`, Gemma 4 E2B, and HF download flow — is **discontinued and gone from this repo**. `Engine.swift` was written **fresh** against the LiteRTLM 0.13.1 Swift API (GPU vision, MTP) and does NOT inherit the old wrapper's gotchas. If a doc or comment still mentions screenshots or the iOS wrapper, treat it as history.

---

## 🧠 TL;DR

`Engine.swift` is the one and only wrapper between the app and Google's [LiteRT-LM](https://ai.google.dev/edge/litert-lm) Swift API, running **Gemma 4 E4B** (`gemma-4-E4B-it.litertlm`, ~3.66 GB on disk). It's a Swift `actor` that owns one native `LiteRTLM.Engine` for the duration of a batch. Nothing else imports `LiteRTLM` directly — callers go through `Engine`.

- **Backend:** GPU (Metal) on Apple Silicon
- **Vision backend:** GPU (Metal) too — [MEASURED] ~21% faster than `.cpu()`, same quality
- **Sampling:** `topK 64`, `topP 0.95`, `temperature 0.15` (near-deterministic — reliable JSON triage)
- **Speculative decoding (MTP):** on (Gemma 4's draft heads ride in the single model file)
- **Visual token budget:** 560 (Gemma 4's `70/140/280/560/1120` detail tiers)
- **Output cap:** 1024 tokens per item (`maxOutputTokens`) — bounds a runaway repetition loop
- **The one caller:** `IterativeRun.swift` (the connector-agnostic on-device orchestrator behind both "Analyze Now" and the dev buttons), plus the self-test harness.

If you're extending this, read `Engine.swift` first — it's ~155 lines and heavily commented. This doc is the why behind those lines.

---

## 🏗️ Architecture at a glance

```
   IterativeRun (orchestrator: per-bucket walk, GPU-wedge resilience)
        │
        ▼
   Engine  (actor)                     ← Sentient's wrapper
        │  load()      ──────────────►  LiteRTLM.Engine + EngineConfig (init ~10s)
        │  generate(prompt, image?) ─►  fresh Conversation per call → sendMessage
        │  reload()    ──────────────►  full kill + ~1s pause + fresh load (wedge recovery)
        │  unload()    ──────────────►  native = nil (ARC → C++ delete frees ~3 GB)
        ▼
   LiteRTLM (Google SPM dep, Vendor/LiteRTLM, pinned v0.13.1)
```

There is **no** intermediate abstraction layer — no "Session" object, no chat-history manager. Just `IterativeRun → Engine → done`. Deliberate: tiny surface, easy to debug, easy to swap if Google changes their API.

### Public API surface (what callers see)

```swift
let engine = Engine(modelPath: path, maxNumTokens: 4096, collectStats: false)

try await engine.load()                       // expensive (~10s) — once per batch
let result = try await engine.generate(        // stateless: fresh Conversation each call
    prompt: "…",
    imageData: jpegData)                       // nil for text-only
try await engine.reload()                      // GPU-wedge recovery (kill → pause → load)
engine.unload()                                // frees ~3 GB
```

`Engine.Result` is `Sendable` (so it can hop back to the MainActor) and carries `text` + `totalTime`. When the engine was created with `collectStats: true`, it also carries exact token counts (`prefillTokens`, `decodeTokens`, `prefillTokensPerSecond`, `decodeTokensPerSecond`) — see "Stats / token instrumentation" below. There is **no streaming API** — `generate()` is synchronous, collecting the full response before returning. (The old streaming `generateStream` + its stall-watchdog were removed in the June-18 convergence.)

---

## 🎚️ Image fidelity

Vision input is a single `Data` of JPEG bytes passed to `generate(imageData:)`, which wraps it as `Content.imageData`. The connector that produces the artifact (e.g. the Files connector for images) is responsible for the downsample + JPEG encode before handing bytes to the engine. The one inference-side lever lives in `Engine.load()`:

- **`ExperimentalFlags.visualTokenBudget = 560`** — how many tokens the vision encoder spends representing the image. *Not* pixel resolution — it's "how much of the model's reasoning bandwidth the image consumes." Gemma 4 tiers: `70 | 140 | 280 | 560 | 1120`. 560 is the sweet spot for documents/screenshots; bump to 1120 for dense text-heavy inputs at the cost of more prefill compute. Reference: [ai.google.dev/gemma/docs/capabilities/vision#variable-resolution](https://ai.google.dev/gemma/docs/capabilities/vision#variable-resolution).

---

## 🧭 Key decisions & why (don't undo these without evidence)

### Why GPU vision (`visionBackend: .gpu`)
On iOS, LiteRT-LM needed `.cpu()` vision. On macOS / Apple-Silicon Metal, GPU vision works and is [MEASURED] ~21% faster than CPU, same quality. We use `.gpu` for both `backend` and `visionBackend`.

### Why a fresh `Conversation` per `generate()` call (stateless)
LiteRT-LM's `Conversation` accumulates chat history; each `sendMessage` appends. Every item we analyze is independent, so a fresh `Conversation` per call gives clean isolation — no history bleed between items. It's cheap (a C handle allocation), and the `Conversation` deinits at function exit, freeing its native handle + KV cache. Net effect: RAM stays flat whether it's item #1 or #500.

### Why `topK = 64`, `temperature = 0.15`
LiteRT-LM's built-in default is `top_k = 1` (essentially greedy decoding → repetitive garbage), so we set the sampler explicitly. `topK 64` / `topP 0.95` follow Gemma 4's published recommendations. The temperature is **0.15** (not Gemma's stock 1.0): triage wants near-deterministic, reliable JSON and faithful instruction-following, with less creative misattribution in the chat bouncer. We deliberately don't go to 0/greedy — pure argmax is the loopiest setting and LiteRT-LM has no repetition penalty, so a sliver of temperature is the only lever that lets the model escape a gibberish-repeat groove. *Don't drop the explicit sampler.*

### Why `maxOutputTokens = 1024`
The hard cap on generated (decode) tokens per item. A triage reply is a compact JSON summary; even a rich keeper for a dense transcript sits well under 1024. The cap's real job is a **backstop**: it bounds a runaway repetition loop to ~1024 tokens (~16s) instead of letting it decode all the way to the KV ceiling (the ~165s "hang" we measured).

### Why MTP (speculative decoding) is on
`ExperimentalFlags.enableSpeculativeDecoding = true` (set after `optIntoExperimentalAPIs()`, before engine creation). Gemma 4's draft heads are baked into the single `.litertlm` file, giving ~2–3× decode speedup on GPU/Metal. Google calls MTP "universally recommended for all GPU/Metal tasks."

### Why the GPU-wedge reload (`reload()` + the orchestration in `IterativeRun`)
[MEASURED] On long runs (~60 items) LiteRT-LM's GPU executor can wedge — Dawn/WebGPU error `"[Buffer] already has an outstanding map pending"` — after which **every** `generate()` fails forever. One unguarded overnight run produced 1,544 cascade failures. The fix is two-pronged, and it's split between the two files:

- **`Engine.reload()`** is the recovery primitive and must be a **full kill**: `unload()` (drops the only strong ref → ARC runs `LiteRTLM.Engine.deinit` → `litert_lm_engine_delete` → C++ `delete engine` **synchronously**, joining the GPU worker thread pools and destroying the WebGPU/Metal device — a real teardown, not a shallow reset) → **`Task.sleep(1s)`** (let the Metal **driver** finish reclaiming GPU memory asynchronously; allocating into a still-draining device is what makes a too-quick reload behave "shallow") → fresh `load()`. Costs roughly one `load()` (~10s) + the pause.
- **`IterativeRun`** decides *when* to reload: **preemptively** every `preemptiveReloadEvery = 40` items, and **reactively** after `failuresBeforeReload = 3` consecutive failures. An item whose failure triggered a reactive reload is retried **once** on the fresh engine; if it still fails it's given up and counted as failed (the bucket's high-water mark simply advances past it — no per-item retry bookkeeping, no poison pills). After `maxReloadsWithoutProgress = 4` reloads with no forward progress, the run stops rather than spin forever.

### Why the model file isn't bundled — `ModelLocator`
The model is **not** in the app bundle (despite some older docs). `ModelLocator.resolve()` finds it at runtime, in order:
1. `SENTIENT_MODEL_PATH` env override (headless / self-test runs),
2. the app bundle (`gemma-4-E4B-it.litertlm`) — so a bundled build "just works" if someone does drag it in,
3. `~/Library/Application Support/SentientOS/Models/gemma-4-E4B-it.litertlm` — where the onboarding downloader will put it (the launch-day location),
4. **DEBUG only:** the repo root next to the `.xcodeproj` (located via `#filePath`, so it works on every dev's Mac — the model is gitignored there).

Returns `nil` if the file isn't on this machine; the home then shows "the on-device model is missing." ⚠️ Release builds therefore need the model in Application Support — hosting for that download is still [OPEN].

### Cache directory
LiteRT-LM needs a writable scratch dir for its shader/compilation cache. `Engine.cacheDirectory()` uses `~/Library/Application Support/SentientOS/ModelCache`. First load after install/clean bears the full Metal shader-compilation cost (~10s); warm loads are faster.

### Stats / token instrumentation
`Engine(collectStats: true)` flips on `ExperimentalFlags.enableBenchmark`, so each `Result` carries the exact tokenized prefill size and decode counts (read from `Conversation.getBenchmarkInfo()`, wrapped in `try?` with a nil-fallback). This is **self-test only** — used by the token-budget self-test to size chat-window byte budgets. Leave it **off** in production (it's the default).

---

## 🐛 Gotchas & debug guide

- **`generate()` throwing `EngineError.notLoaded`:** you called it before `load()`. The orchestrator always loads first; only matters for ad-hoc/self-test callers.
- **`EngineError.modelNotFound`:** `ModelLocator` resolved a path that no longer exists, or you set a bad `SENTIENT_MODEL_PATH`. Check the four resolution locations above.
- **Every `generate()` suddenly fast-failing on a long run:** the GPU wedge (see above). In a path that doesn't go through `IterativeRun`, you won't get automatic recovery — call `engine.reload()` yourself.
- **Engine init taking ~10s on first load:** expected — Metal shader compilation. Warm loads (same cache dir) are faster.
- **RAM creeping during a batch:** shouldn't happen — each `generate()` creates and drops its own `Conversation`. If the Xcode memory gauge climbs, check nobody is accidentally retaining a `Conversation` across calls.
- **Decode suddenly much slower:** MTP may have silently turned off (confirm `enableSpeculativeDecoding = true` is set before engine creation), or the GPU fell back to CPU (look for any stray `.cpu()` in `EngineConfig`), or the visual budget changed.

---

## 🛠️ How to extend

### Swap the model
Change `ModelLocator.fileName` (and the bundle-resource name in `ModelLocator.resolve()`), then update the download host once that exists. If the new model has a bigger context window, bump the `maxNumTokens` passed by the connectors in `IterativeRun` (it sizes the engine to `connectors.map(\.maxTokens).max()`).

### Tune sampling / visual budget
Sampling lives in `Engine.generate()` (`SamplerConfig(topK:topP:temperature:)`); the visual budget lives in `Engine.load()` (`ExperimentalFlags.visualTokenBudget`). Don't drop `topK` below 64 unless you *want* repetitive output.

### Tool / function calling
LiteRT-LM supports it via the `Tool` protocol + `@ToolParam` property wrapper, passed to `ConversationConfig(tools:)`. We don't use it today — see the Swift API reference doc in this folder for the pattern.

---

## 📚 Useful references

| Resource | Where |
|---|---|
| LiteRT-LM official overview | https://ai.google.dev/edge/litert-lm/overview |
| LiteRT-LM Swift API guide | https://ai.google.dev/edge/litert-lm/swift |
| LiteRT-LM GitHub | https://github.com/google-ai-edge/LiteRT-LM |
| Gemma 4 E4B HF model card | https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm |
| Gemma 4 vision capabilities | https://ai.google.dev/gemma/docs/capabilities/vision |
| Vendored LiteRT-LM SwiftPM package (pinned v0.13.1) | `Vendor/LiteRTLM/Package.swift` |
| Local LiteRT-LM source checkout (for spelunking) | workspace root: `LiteRT-LM Codebase for Reference/` |

---

*Update this doc when you make non-obvious changes to `Engine.swift`, `IterativeRun.swift`, or `ModelLocator.swift`.*
