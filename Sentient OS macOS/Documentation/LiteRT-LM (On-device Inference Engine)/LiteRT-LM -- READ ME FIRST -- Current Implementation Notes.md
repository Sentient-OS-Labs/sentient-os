Hey Claude!

LiteRT-LM keeps getting updates, but we use a local copy of LiteRT-LM imported as a local dependency on Xcode.

In this folder are additional docs files from LiteRT-LM’s website.

Whenever we’re updating to the latest build of LiteRT-LM, you’d wanna clone the latest version of the LiteRT-LM codebase from their main branch and also update those 2 docs files that were pulled from the website.

Below is our current implementation of LiteRT-LM. Be sure to update this accordingly if you’re working on something that relates to this part of Sentient OS.


---
---
---

# LiteRT-LM Implementation Notes

> Everything future-Claude (or future-human) needs to know about the on-device inference stack. Written ~immediately after the MLX→LiteRT-LM rebase, so it captures decisions and gotchas while they're fresh.

> **⚠️ Scope (2026-06-04):** This documents the **iOS** app's `OnDeviceInference.swift` (Gemma 4 **E2B**). The **macOS** `Engine.swift` was written **fresh** (Gemma 4 **E4B**, GPU vision, MTP) and deliberately does **not** inherit these "gotchas" — the iOS inference had an unfixed bug, so they were never validated. For macOS, see the **macOS Architecture Plan §4**.

---

## 🧠 TL;DR

`OnDeviceInference.swift` is the **one and only** wrapper between the app and our inference backend. It sits directly on top of Google's [LiteRT-LM](https://ai.google.dev/edge/litert-lm) Swift API running **Gemma-4-E2B** (2.41 GB on disk, ~1.45 GB peak RAM). Everything else in the app talks to `OnDeviceInference.shared`; nothing imports LiteRTLM directly.

- **Backend:** GPU (Metal) with MTP speculative decoding enabled by default
- **Vision backend:** CPU (required for image input on iOS)
- **Model file:** `~/Library/Application Support/SentientOS/Models/gemma-4-E2B-it.litertlm`
- **Performance (iPhone 17 Pro):** ~72 tok/s decode, ~0.2s TTFT, ~2.2s per screenshot

If you're debugging, jump to **Gotchas & Debug Guide**. If you're extending, jump to **How to Extend**.

---

## 🏗️ Architecture at a glance

```
   App layer (ScreenshotProcessor, DebugView_InferenceTestView, AppState)
        │
        ▼
   OnDeviceInference.shared       ← @MainActor singleton
        │  download() ─────────►  URLSession + HF token → HF Xet CDN
        │  loadModel() ────────►  LiteRTLM.Engine (actor) + EngineConfig
        │  generate(…) ────────►  Conversation (fresh per call) → sendMessageStream
        │  unloadModel() ──────►  engine = nil (deinit frees native handle)
        ▼
   LiteRTLM (Google SPM dep)
```

There is **no** intermediate abstraction layer. No "Session" object, no chat-history management, no "Manager" class. Just `OnDeviceInference` → `Engine` → done. This was deliberate — keeps the surface tiny, easy to debug, easy to swap if Google ever changes their API.

### Public API surface (what callers see)

```swift
OnDeviceInference.shared.isModelDownloaded    // Bool
OnDeviceInference.shared.isModelLoaded        // Bool

// Idempotent — returns immediately if already downloaded
try await OnDeviceInference.shared.download { progress in
    // progress: Double 0.0...1.0, called off MainActor every ~64 KB chunk
}

// ~5-10s on iPhone — self-heals on stale-cache failure (one retry w/ cache wipe)
try await OnDeviceInference.shared.loadModel()

// Stateless per call — fresh Conversation each time
let result = try await OnDeviceInference.shared.generate(
    prompt: "...",
    images: [uiImage],         // [] for text-only
    resize: .p720,             // visual token budget; see Image Fidelity section
    parameters: .default       // sampling knobs
)

OnDeviceInference.shared.unloadModel()
```

`InferenceResult` carries `text`, plus per-call timings (`preprocessingTime`, `prefillTime`, `decodeTime`, `totalTime`, `timeToFirstToken`), throughput (`tokensPerSecond`, `promptTokensPerSecond`), token counts, and a `stopReason`. The DevMetricsOverlay in `ProcessingView` consumes all of these for the live debug readout.

---

## 🎚️ Image fidelity (the three knobs)

Three settings stack to determine how much detail the model sees. **All three matter — bottlenecked by whichever is most aggressive.** From source to model:

```
~14 MB raw screenshot
   ↓ (1) ImageIO downsample → 720p (~1.3 MB CGImage)
   ↓ (2) JPEG @ 0.85 → ~80-150 KB
   ↓ (3) LiteRTLM Content.imageData → vision encoder
   ↓     Visual token budget cap (560 default) → KV cache
   → LLM
```

### Knob 1 — Pre-downsample resolution

- **Where:** `ImageUtilities.downsample(data:)` in `Services/ImageUtilities.swift`
- **Current value:** 720p short edge (`defaultInferenceShortEdge: CGFloat = 720`)
- **Range:** any CGFloat
- **Why this exists:** memory efficiency. iPhone screenshots can be 1320×2868 px (~15 MB decoded). ImageIO's `CGImageSourceCreateThumbnailAtIndex` decodes *directly* to 720p, never materializing the full-res buffer (~14 MB → ~1.3 MB peak).
- **When to change:** if you suspect even 720p is too small for some screenshots (dense text could degrade), bump to 1080. If you're chasing memory, drop to 540 — but model accuracy will suffer.

### Knob 2 — JPEG encoding quality

- **Where:** `OnDeviceInference.generate()` — `img.jpegData(compressionQuality: 0.85)`
- **Current value:** `0.85`
- **Range:** `0.0` (most compressed, lots of artifacts) → `1.0` (lossless)
- **Why this exists:** LiteRT-LM's `Content.imageData(Data)` needs raw bytes. We need to encode somehow. JPEG @ 0.85 is the battle-tested sweet spot — small bytes, no visible quality loss to a vision encoder.
- **When to change:** if accuracy seems to suffer, bump to 0.95 (near-lossless). If bytes-on-disk matter for some reason, drop to 0.7. Probably never touch this — the model re-encodes internally anyway.
- **If you want to expose as a knob:** add a `jpegQuality: Float = 0.85` param to `generate()`. Trivial.

### Knob 3 — Visual token budget (the BIG fidelity lever)

- **Where:** `OnDeviceInference.ImageResize` enum, mapped via `resize:` param to `generate()`, applied via `ExperimentalFlags.visualTokenBudget`
- **Current default:** `560` (the `.p720` case)
- **Options (Gemma 4 spec):** `70 | 140 | 280 | 560 | 1120`, or `nil` for no cap
- **What it means:** number of tokens the vision encoder spends representing the image. *Not* a pixel resolution — it's "how much of the model's reasoning bandwidth does the image consume." More tokens = better at fine detail (dense text, tiny UI elements, charts), more prefill compute per image.
- **Enum mapping (yes, the case names are vestigial — kept for source-compat):**
  - `.p512` → budget 280 (fast)
  - `.p720` → budget 560 (**default**, good for screenshots)
  - `.none` → no cap (engine default)
  - `.custom(Int32)` → any of the five tiers
- **When to change:**
  - Bump to **1120** if screenshots are dense text-heavy (recipes, articles, code, dense UI) and quality matters more than speed
  - Drop to **280** for "Fast" mode if you ever expose a user-facing speed/quality slider
  - Reference: [ai.google.dev/gemma/docs/capabilities/vision#variable-resolution](https://ai.google.dev/gemma/docs/capabilities/vision#variable-resolution)

---

## 🧭 Key decisions & why (non-obvious choices to NOT undo)

### Why URLSession direct download (not `swift-huggingface`)

The original MLX implementation used `#hubDownloader()` from `swift-huggingface`. Two problems with it for our use case:

1. **Progress bar broken.** Their `Progress` object's `fractionCompleted` was stuck near 0% for ~all of the 2.5 GB download, then snapped to 100%. Root cause likely upfront-totalUnitCount estimation being way off.
2. **No HF token plumbing.** Anonymous HF downloads are bandwidth-capped; the token unlocks unmetered Xet CDN routing.

We replaced with a direct `URLSession.downloadTask + URLSessionDownloadDelegate` (see `DownloadProgressDelegate`). `didWriteData(_:totalBytesWritten:totalBytesExpectedToWrite:)` gives us exact byte progress every ~64 KB. Smooth, accurate, trustworthy.

**Important wart:** we use the classic delegate + `withCheckedThrowingContinuation` pattern instead of the async `session.download(for:)` overload. The async overload's internal Swift-Concurrency bridging *consumes* `URLSessionDownloadDelegate.didWriteData` events instead of forwarding them to our delegate — which would leave progress stuck at 0%. If anyone ever "modernizes" this back to `session.download(for:)`, the progress bar will silently break again. *Don't.*

### Why fresh `Conversation` per `generate()` call (stateless)

LiteRT-LM's `Conversation` maintains chat history. Each `sendMessage` appends. For our use case (each screenshot is independent), we want stateless — no history bleeding between screenshots.

Creating a fresh `Conversation` per call is cheap (just a C handle allocation) and gives us clean isolation. It also means we *could* later support a "system prompt" by setting `ConversationConfig.systemMessage` per call without polluting other calls.

### Why explicit `topK = 64`

LiteRT-LM's built-in default (in `runtime/engine/engine_settings.cc`) is `top_k = 1`, which is essentially greedy decoding → repetitive, boring output. Google's published Gemma 4 recommendations are `temperature=1.0, top_p=0.95, top_k=64`. We explicitly set these in `GenerationParameters` to override the unhelpful default. *Don't drop the explicit setter.*

### Why model file in Application Support (not Caches)

- `~/Library/Caches/` — iOS can evict files under storage pressure. Bad for a 2.58 GB download.
- `~/Library/Application Support/` — persistent. Good.
- Plus we set `URLResourceValues.isExcludedFromBackup = true` so the 2.58 GB doesn't bloat user iCloud backups.

### Bundle-or-download fallback (the sideload escape hatch)

`OnDeviceInference.resolvedModelPath` checks `Bundle.main.path(forResource: "gemma-4-E2B-it", ofType: "litertlm")` first. If the model is *bundled* in the app (i.e. dragged into the Xcode project so it ends up in the `.ipa`'s resources), the engine loads from there and the download is skipped entirely. If not bundled, falls back to the downloaded copy in Application Support.

**Why this exists:** sideload demos. Pre-installing the app via Xcode cable on someone's iPhone with the model bundled = instant first-launch (no awkward 5-20 min HF download wait). Also handy for dev iteration if you want to skip the download dance.

**Critical gotcha for App Store builds:** if the model is left in the bundle when archiving, the IPA balloons to ~2.75 GB AND the app still downloads from HF on first launch (wasted bandwidth + doubled disk usage). See `/Documentation/Prepare for actual release build.md` § 4 for the pre-ship checklist.

**To bundle:** drag `gemma-4-E2B-it.litertlm` into the Xcode project navigator, confirm "Sentient OS" target is checked. It lands in Build Phases → Copy Bundle Resources. Done.

**To unbundle:** right-click the file in project navigator → Delete → "Remove Reference" (keeps the file on disk for re-bundling later).

### Why `visualBackend: .cpu()` for the vision executor

Per LiteRT-LM's docs and the iOS sample, vision needs an explicit visionBackend on iOS. CPU is what they recommend / what the sample uses. GPU vision isn't (yet?) supported on iOS as of v0.12.0.

### Why MTP + benchmark always on

- **MTP (Multi-Token Prediction):** Google's blog says "universally recommended for all GPU/Metal tasks." Gives us ~2-3× decode speedup (we measured ~72 tok/s vs. their 56 tok/s baseline, on top of which TTFT also drops). Enabled via `ExperimentalFlags.enableSpeculativeDecoding = true` *before* engine creation.
- **Benchmark:** required for `Conversation.getBenchmarkInfo()` which feeds our DevMetricsOverlay. Jesai wants it always on (Debug + Release) for production telemetry. Tiny overhead.

### Why self-heal on engine init failure (the retry-with-cache-wipe pattern)

Intermittent "Failed to create engine" errors on app relaunch are almost always stale/half-evicted Metal shader cache. iOS evicts Caches files individually under storage pressure → corrupt cache → `litert_lm_engine_create()` returns nil. Debug-vs-Release binary differences also invalidate cached shaders.

`loadModel()` tries once, wipes `cacheDir` on failure, retries once. Self-healing, no user impact, no code paths to maintain. If both attempts fail, *then* throw.

### Why the engine-stuck safeguard in `ScreenshotProcessor.runProcessing()`

Separate from the init-time self-heal above, there's a *mid-batch* safeguard for a different (rarer) failure mode: the LiteRT-LM engine can wedge into a "fast-fail every call" state where `generate()` returns immediately without doing real work. Observed ~once-in-20-batches in May 2026.

`runProcessing()` times each `processScreenshot` call. Real inference is ~2.2s on iPhone 17 Pro; **any sub-0.9s call is anomalous**. Two anomalous calls in a row → force-restart the engine via `unloadModel()` + `loadModel()`. Hard cap at 2 restarts per batch; if still wedged, yield `.failed` with a "please restart the app" message instead of looping forever.

**Happy path is untouched** — the only added work per loop iteration is a `Date()` subtraction and an integer compare. Every successful inference resets the counter to zero, so the restart logic never fires under normal conditions. See `ScreenshotProcessor.swift`'s main `for` loop in `runProcessing()` for the implementation, and `/Documentation/Our Code Documentation/ScreenshotProcessor and ImageUtilities Explained.md` § "Engine-stuck Safeguard" for the user-facing explanation.

### Why `maxNumTokens: 1024` in `EngineConfig`

This is the KV cache size — total input + output tokens. Our prompts are short (~200 tokens), images use up to 560 visual tokens, responses are ~30 words (~50 tokens). 1024 gives generous headroom without wasting KV cache memory. If you ever increase `visualTokenBudget` to 1120, bump `maxNumTokens` to ~2048 to stay safe.

### Why the `ImageResize` enum kept its `.p512`/`.p720` case names

After the rebase, those names no longer literally describe pixels — they map to visual token budgets (280/560). Renaming to `.fast`/`.quality` would touch every call site (`ScreenshotProcessor`, `DebugView_InferenceTestView`, etc.) for zero readability gain. Documented at the enum; left as-is.

---

## 🐛 Gotchas & debug guide

### "Failed to create engine" / `loadModel` throwing

- **First check:** is the cache wipe + retry firing? Look for `LiteRT-LM engine init failed: ... — wiping cache and retrying.` in the Xcode console. If you see that AND it then succeeds, the self-heal is working.
- **If both attempts fail:** likely not the cache. Candidates:
  - GPU init failure (rare). Try `backend: .cpu()` in `makeEngine()` to isolate — if CPU works, it's a Metal issue.
  - Model file corruption. Check the file size: `ls -la ~/Library/Application\ Support/SentientOS/Models/`. Should be exactly 2,588,147,712 bytes.
  - LiteRT-LM version mismatch (rare, but if Google releases a breaking change).

### Download progress stuck at 0%

If this comes back after some "improvement" PR: someone probably switched `download()` back to `session.download(for: req)` (the async overload) instead of the manual `withCheckedThrowingContinuation` pattern. See "Why URLSession direct download" above for *why* this matters.

### SourceKit complaining `"No such module 'UIKit'"`

Pure LSP indexer noise — UIKit is available on all iOS targets, the file built fine before, the project still builds. Restart Xcode if it's visually annoying. Not a real error.

### `getBenchmarkInfo()` throwing

Wrapped in `try?` inside `generate()` with a graceful zero-fallback. If benchmark metrics suddenly start showing all zeros, this is why. Check `ExperimentalFlags.enableBenchmark = true` in `loadModel()` is still set.

### HF token rotation

Token lives at `OnDeviceInference.hfToken` (hardcoded `private static let`). Read-only, scoped to public models. If it ever leaks (showed up in a security scanner, etc.):
1. Go to [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens), revoke the old token
2. Create new one ("Read" type), paste into `OnDeviceInference.hfToken`
3. Ship the update

Even a leaked read-only token's max blast radius is "someone downloads public Google models faster." Low-severity.

### Engine init taking ~10s on first load

Expected per LiteRT-LM docs. The first launch after install bears the full Metal shader compilation cost; subsequent loads are faster (warm cache).

### "I/O on main thread" warnings during load

Should be gone after the rebase (we moved cache-dir creation off-main via `Task.detached`). If they come back, check that `ensureModelDirectoryExists()` is still `nonisolated` and the `Task.detached` wrapper in `loadModel()` is intact.

### Memory creeping during long batches

LiteRT-LM is much better-behaved than MLX here (no manual cache management needed). If you ever see Xcode memory gauge creeping past 1.6 GB during a batch, something's likely off — check that we're not accidentally retaining `Conversation` objects across `generate()` calls. (Each `generate()` should create + drop a Conversation.)

---

## 🛠️ How to extend

### Swap the model

Edit `OnDeviceInference.currentModel`:

```swift
static let currentModel = ModelDescriptor(
    id: "litert-community/gemma-4-E4B-it-litert-lm",   // for example
    displayName: "Gemma 4 E4B (LiteRT-LM)",
    approxDiskSizeGB: 3.65
)
```

Then also update:
- `Self.modelDownloadURL` (the HF resolve URL — change `gemma-4-E2B-it.litertlm` to the new filename)
- The filename in `modelFileURL` (`gemma-4-E2B-it.litertlm` → new filename)
- `isModelDownloaded`'s size sanity check (`> 2_500_000_000` → match new file size)
- `loadModel()`'s `maxNumTokens` may need a bump if the new model has bigger context windows

### Tune sampling

Edit `GenerationParameters.default` defaults, or pass a custom `GenerationParameters` to `generate(parameters:)`. Defaults are Google's published Gemma 4 recommendations — don't drop below `topK=64` unless you *want* repetitive output (LiteRT-LM's hardcoded default of 1 is essentially greedy decoding).

### Tune visual token budget

Default is 560 (`.p720`). Per-call override via `generate(resize: .p512 | .p720 | .none | .custom(n))`. To change app-wide default, edit `loadModel()`'s `ExperimentalFlags.visualTokenBudget = 560` line AND the default in `generate(resize:)`.

### Add tool/function calling

LiteRT-LM supports it via the `Tool` protocol + `@ToolParam` property wrapper. Pass tools to `ConversationConfig(tools: [...])` in `generate()`. Tools are auto-invoked by the model — see [LiteRT-LM Swift Tools doc](https://ai.google.dev/edge/litert-lm/swift#define_and_use_tools) for the pattern.

### Background downloads (so download continues when app is suspended)

Currently we use a foreground URLSession — if the user backgrounds the app mid-download, iOS suspends the task. For a 2.58 GB download this hurts.

To upgrade: in `download()`, swap `URLSession(configuration: .default, ...)` for `URLSession(configuration: .background(withIdentifier: "..."), ...)`. Caveat: background URLSession needs a more elaborate delegate pattern (events can come back after the app relaunches), so it's not a one-liner. Doable, but punt unless users complain.

### Resume-on-cancellation

URLSession supports `cancel(byProducingResumeData:)` → persist resumeData → `downloadTask(withResumeData:)` on retry. For 2.58 GB this would matter for flaky-wifi users. Not implemented; flagged for later.

### Stream tokens to the UI live

`generate()` currently collects the full response before returning. To stream chunks:
1. Add a new method like `generateStream(prompt:images:resize:parameters:) -> AsyncThrowingStream<String, Error>`
2. Reuse the `for try await chunk in conversation.sendMessageStream(...)` loop, yielding each chunk
3. Call site uses `for try await text in stream { updateUI(text) }`

Useful for the eventual "talk to your data" feature where the user sees the response stream in.

### Distinguish stop vs. length-cap stop reasons

Currently `InferenceResult.stopReason` always returns `.stop`. LiteRT-LM doesn't expose a stop reason directly. To detect length-cap stops:
- Compare `generationTokenCount` against `maxNumTokens`. If close to the cap, it likely got truncated.
- Or look at the last few characters — if the response ends mid-sentence, probably truncated.

Not critical for now (our prompts produce short responses well under cap).

---

## 🚀 Disabling debug / benchmark for release

Right now `ExperimentalFlags.enableBenchmark = true` is set in `loadModel()` for both Debug and Release builds (per Jesai's request — useful telemetry during the beta). When prepping for proper App Store release, flip it off as part of the dev-cleanup pass.

### What "always on" actually costs

Per LiteRT-LM's docs and our measurements: tiny. Benchmark mode adds a small bookkeeping overhead inside `Conversation.getBenchmarkInfo()` accounting but doesn't slow down inference itself. We're talking single-digit-percent overhead at worst. It's not a correctness issue to leave on — Jesai chose to keep it for production telemetry.

### How to turn it off

**Step 1.** In `OnDeviceInference.loadModel()`, change:

```swift
ExperimentalFlags.enableBenchmark = true             // always on per Jesai (need it for dev metrics)
```

to:

```swift
ExperimentalFlags.enableBenchmark = false
```

Or just delete the line — `false` is the default. (Note: `ExperimentalFlags.optIntoExperimentalAPIs()` in `init()` still needs to stay — `enableSpeculativeDecoding` requires it.)

**Step 2.** Understand the cascade — these `InferenceResult` fields will silently start returning `0`:

- `prefillTime`
- `decodeTime`
- `tokensPerSecond`
- `promptTokensPerSecond`
- `promptTokenCount`
- `generationTokenCount`

(They come from `BenchmarkInfo` which is only available when the flag is on. The code already has `try? conversation.getBenchmarkInfo()` with a zero-fallback so the inference itself won't fail — you just lose the metrics.)

**Fields that keep working** (they're wall-clock-based, no benchmark needed):

- `text`
- `preprocessingTime`
- `totalTime`
- `timeToFirstToken`
- `stopReason`

**Step 3.** Strip the dev-only overlay UI that consumed those zeroed metrics. This is already documented separately — see `/Documentation/Prepare for actual release build.md`. Search the codebase for `DEV-ONLY: remove before ship` (exact phrase, case-sensitive) and delete each block. Key hits:

- `ProcessingView.swift` — the `DevMetricsOverlay` struct + the `.overlay(...)` modifier that attaches it + the `lastPreprocessingTime`/`lastPrefillTime`/`lastDecodeTime`/`lastTotalTime`/`lastTokensPerSecond` `@State` vars that feed it
- `ScreenshotProcessor.swift` — `ProcessingResult`'s timing fields (`preprocessingTime`, `prefillTime`, `decodeTime`, `totalTime`, `tokensPerSecond`) become dead weight; can either remove or leave (they're harmless if left)

**Step 4 (optional cleanup).** Drop the now-always-zero fields from `InferenceResult` entirely:

- Remove from the struct: `prefillTime`, `decodeTime`, `tokensPerSecond`, `promptTokensPerSecond`, `promptTokenCount`, `generationTokenCount`
- Remove from `generate()`: the `bench` extraction logic, the if-else branches that populate those fields
- Removes ~20 lines, makes the struct match what's actually meaningful in production

This is a polish step — not strictly required, but the struct is cleaner without dead fields.

### Verify nothing broke

After steps 1-3, `DebugView_InferenceTestView` will still work — it'll just show `0.0 tok/s · 0 tokens` in its metrics line where benchmark used to populate. That's expected. If you also did step 4, you'd need to update the InferenceTestView's metrics line (line ~333 in `DebugView_InferenceTestView.swift`) to not reference removed fields.

Compile (`⌘B`) should be clean throughout.

---

## 📚 Useful references

| Resource | Where |
|---|---|
| LiteRT-LM official overview | https://ai.google.dev/edge/litert-lm/overview |
| LiteRT-LM Swift API guide | https://ai.google.dev/edge/litert-lm/swift |
| LiteRT-LM GitHub | https://github.com/google-ai-edge/LiteRT-LM |
| Gemma 4 E2B HF model card | https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm |
| Gemma 4 vision capabilities | https://ai.google.dev/gemma/docs/capabilities/vision |
| MTP blog post | https://blog.google/innovation-and-ai/technology/developers-tools/multi-token-prediction-gemma-4/ |
| Local LiteRT-LM source checkout (for spelunking) | `/NEW - LiteRT-LM Reference/LiteRT-LM Codebase for Reference/` |
| Original migration plan (historical) | `/Documentation/LiteRT-LM Migration Plan.md` |

---

## 📐 Known performance baseline (iPhone 17 Pro)

Recorded right after the rebase, single screenshot, default settings (`.p720` / budget 560):

- **TTFT:** ~0.2s
- **Prefill:** ~3,800 tok/s (560 visual + ~200 text = ~760 tokens in ~0.20s)
- **Decode:** ~72 tok/s (with MTP)
- **Total per screenshot:** ~2.2s
- **Peak RAM:** well under 1.6 GB
- **Thermal:** nominal even after extended batches

If these numbers drop significantly without an obvious cause:
- MTP might have silently disabled (check `enableSpeculativeDecoding = true` is still being set before engine creation)
- GPU might have fallen back to CPU (check the engine init path, look for any `.cpu()` in `EngineConfig`)
- Visual budget might have changed (560 vs 1120 is a real perf hit)

---

*Last updated: post-rebase, May 2026. Update this doc when you make non-obvious changes.*
