# On-Device Engine & Triage (Engine/)

Everything that runs the on-device model: the LiteRT-LM wrapper around Gemma 4 E4B, the triage
prompts and verdict parsing (the "bouncer" that decides keep / junk / sensitive), the deterministic PII
backstop, where the model file lives, and how it gets downloaded during onboarding.

This is the high-volume understanding stage: analysis runs on the Mac rather than uploading each
source item for inference. It makes rich personal context practical while keeping the first pass
local. `ModelDownload` fetches the model; `Engine` performs inference on-device. The useful summaries
are later processed by the user's chosen frontier model, which can be local or hosted.

## Files

| File | Job |
|---|---|
| `Engine.swift` | The `Engine` actor: one native `LiteRTLM.Engine` per batch, `load()` / `generate()` / `reload()` / `unload()`. The only place that imports `LiteRTLM`. |
| `Triage.swift` | Builds the per-item prompt (file, DM chat, group chat, Apple Mail, Apple Calendar), parses the JSON reply, and maps it to a `Verdict` plus title and summary. Fail-closed. |
| `Verdict.swift` | `survivor` / `junk` / `sensitive`. |
| `PIIScan.swift` | Regex backstop behind the model: SSN, Luhn-valid card number, passport number in a would-be survivor's summary or title drops the whole item as sensitive. |
| `ModelLocator.swift` | Finds `gemma-4-E4B-it.litertlm` on this Mac (env override in DEBUG → app bundle → Application Support → the repo root in DEBUG). |
| `ModelDownload.swift` | The onboarding download: 8 parallel range requests into part files, resumable, SHA-256 verified, atomic move into the slot `ModelLocator` resolves. |

The dependency is the vendored SwiftPM package at `Vendor/LiteRTLM/` (repo root), pinned to LiteRT-LM
**v0.13.1**. Pin tagged releases only; `main` does not wire the macOS binary slice. The prebuilt
`CLiteRTLM_mac` dylib is fat (arm64 + x86_64) and is thinned at build time (see `Documentation - General - Bundle Size & Build Phases.md`).

## The engine (`Engine.swift`)

`Engine` is a Swift actor. `IterativeRun` creates one per run, sized to the largest KV cache any
selected connector needs (`maxNumTokens`, 4096 by default, 16 384 for chat windows), loads it once
(~10 s, mostly Metal shader compilation; warm loads are faster), and calls `generate(prompt:imageData:)`
once per item.

Settings that matter (all in `load()` / `generate()`):

- **GPU (Metal) for text AND vision.** GPU vision measured ~21% faster than CPU on Apple Silicon at the same quality.
- **Speculative decoding on** (`ExperimentalFlags.enableSpeculativeDecoding`). Gemma 4's draft heads are inside the single model file; roughly 2 to 3× faster decode.
- **`visualTokenBudget = 560`** (Gemma 4 tiers: 70 / 140 / 280 / 560 / 1120). This is how much of the model's attention an image gets, not pixel size. The Files source downsizes images to 768 px on the long edge before they get here.
- **Sampler `topK 64 · topP 0.95 · temperature 0.15`.** Near-deterministic for stable JSON. Not greedy: LiteRT-LM has no repetition penalty, and pure argmax is the setting most likely to loop.
- **`maxOutputTokens = 1024`** bounds a runaway repetition loop to ~16 s instead of decoding to the KV ceiling.
- **A fresh `Conversation` per call.** No history between items, and the KV cache is freed at function exit, so memory stays flat across a 1,000-item run.
- **Cache dir** for LiteRT-LM's shader cache: `~/Library/Application Support/SentientOS/ModelCache`.
- `collectStats: true` turns on LiteRT-LM's benchmark instrumentation (exact prefill/decode token counts on each `Result`). Self-tests only; off in production.

**GPU wedge recovery.** On long runs the GPU executor can wedge (a Dawn/WebGPU "outstanding map pending"
error), after which every `generate()` fails. `reload()` is a full kill: `unload()` (ARC deletes the C++
engine synchronously, tearing down the Metal device), a ~1 s pause so the driver finishes reclaiming
memory, then a fresh `load()`. `IterativeRun` decides when to call it: preemptively every 40 items,
and reactively after 3 consecutive generate failures (with one retry of the failed item on the fresh
engine, and a hard stop after 4 reloads with no progress). See `Ingestion/Documentation - Ingestion Pipeline.md`.

## Triage: the on-device bouncer (`Triage.swift`)

Files, notes and conversation windows use a summary-first prompt and a JSON reply:

```
{"summary":"…","title":"…","junk":true|false}   optionally followed by  ,"sensitive":true
```

The prompt variants preserve attribution and use source-specific privacy rules:

- **File prompt** (files and Apple Notes): judges one document by path, creation date, and either the extracted text or the attached image. Explains that "junk" only means "not worth the knowledge base", never deletion.
- **DM chat prompt**: one slice of a 1:1 conversation. "Me" is the user; the other party's "I" is never the user. Default to junk; keep only durable life knowledge.
- **Group chat prompt**: much stricter. Attribution is the whole game: other members' introductions, jobs, wins, and news are never the user's. Deep participation in a discussion is still junk unless "Me" stated a concrete fact about their own life. Every fact in the summary must name whose it is.

- **Apple Mail prompt**: classification first. `decideMail` requires strict JSON with explicit
  boolean `junk` and `sensitive` fields, plus string `summary` and `title`; missing privacy flags are
  not recovered. Rejected messages have empty content. A valid keeper then goes through the shared
  output checks. Invalid output remains retryable in the Mail pipeline.
- **Apple Calendar prompt**: one native event as untrusted JSON. Keep concrete scheduled commitments,
  preserve date/status uncertainty, and reject generic holidays and instruction-only text. Medical,
  intimate, credential-bearing, and other highly private events are dropped in full. Dates alone do
  not justify a retained summary.

The pipeline calls `decide(_:for:)`. For Apple Calendar, it checks raw input for high-risk identifiers
and labelled credentials, checks output for credentials, and rejects explicit classifier overrides.
JSON fields are decoded before these checks. Calendar replies require a complete JSON object with
string summary/title and explicit boolean junk/sensitive flags; missing or mistyped fields fail closed.
Sensitive calendar outcomes also discard their title
and summary in memory. These narrow deterministic checks supplement the model; they are not a
complete detector for arbitrary secrets or prompt injection. Other sources keep their mixed-content
policy. Calendar parse failures invalidate the pending snapshot instead of advancing its checkpoint.

Shared privacy rules in every flavour: the summary is kept and may be shared with the user's other AIs,
so it must omit raw private specifics (card, SSN, passport, account numbers, passwords, exact medical
or financial figures). A file whose core content is sensitive is flagged sensitive; a useful file with a
few private specifics is kept with those specifics omitted.

**`decide()` is fail-closed**, in this order:

1. Unparseable reply → junk (`reason: .parseFailed`). No knowledge summary is retained from that parse failure.
2. `sensitive: true` → sensitive.
3. `junk: true` → junk.
4. Empty summary → junk (`.emptySummary`).
5. `PIIScan.containsHighRiskPII` on the summary or title → sensitive, and the summary/title are dropped from the outcome too.
6. Otherwise survivor.

`parse()` tries strict JSON first, then a per-field regex recovery so one malformed key does not sink an
otherwise-valid keeper. `Outcome.reason` lets diagnostics tell "garbled reply" from "genuine junk"
(a run where ≥20% of items were parse failures emits a Sentry warning; see the Diagnostics doc).

Junk and sensitive outcomes do not become knowledge summaries. The pipeline still retains the
progress needed to avoid reprocessing, and Mail has dedicated checkpoint/retry state. Lifetime
counters record verdict totals. Do not describe these filters as complete de-identification: useful
summaries are personal, and narrow pattern checks cannot detect every kind of sensitive content.

## The PII backstop (`PIIScan.swift`)

A small on-device model can slip. `containsHighRiskPII` catches a US SSN (with separators, skipping
invalid ranges), a 13 to 19 digit Luhn-valid card number, and a "passport" mention followed by a 6 to 9
character alphanumeric code. It is tuned to prefer dropping a good summary over leaking one identifier.

## Finding the model (`ModelLocator.swift`)

`resolve()` returns the first that exists: `SENTIENT_MODEL_PATH` (DEBUG only, for headless runs) →
the app bundle → `~/Library/Application Support/SentientOS/Models/gemma-4-E4B-it.litertlm` (where the
download lands) → in DEBUG, walking up from the source file to the repo root (the model sits next to the
`.xcodeproj` on dev Macs, gitignored). The model is never bundled into the shipped app.

## The download (`ModelDownload.swift`)

`ModelDownload.shared.kickIfNeeded()` is safe to call any time: it no-ops when `ModelLocator` already
finds a model or a download is in flight, and restarts from `.failed` (Try Again). `AppState` kicks it
2 s after the post-FDA relaunch during onboarding; `OnboardingModelDownloadView` and the home's
`ModelDownloadWhisper` render its `phase` / `bytesDone`.

How the transfer works:

- Source: the official `litert-community/gemma-4-E4B-it-litert-lm` repo on Hugging Face (anonymous, no token). Size (3,659,530,240 bytes) and SHA-256 are pinned in `ModelDownloadJob.production`; a HEAD check refuses to start if the server's size no longer matches.
- A 10 GB free-space preflight refuses to start with a clear message (parts + the assembled copy + breathing room). The capacity read is fail-open.
- **8 parallel HTTP range chunks**, each appending to its own `part_N` file whose size is its resume bookmark, so a quit or crash resumes mid-chunk. A staging marker (`expected.sha256`) wipes stale parts if the pinned hash ever changes.
- Up to 4 full attempts with a growing pause; per-chunk retries inside. Fatal errors (upstream changed, checksum, disk write) skip the ladder and show a user-facing sentence.
- Parts are streamed through SHA-256 into `assembled.tmp` in one pass, deleted as consumed, and only a verified digest moves the file into place. A checksum mismatch wipes staging so the retry starts clean.

## Rules

- Do not drop the explicit sampler or the output cap; do not lower `topK` below 64.
- Keep `visionBackend: .gpu`; keep the vendored package on a tagged v0.13.x.
- Triage must stay fail-closed. Any new parsing path must map "can't tell" to junk, never survivor.
- Nothing in this folder may write outside `~/Library/Application Support/SentientOS/`.

## Related docs

`Ingestion/Documentation - Ingestion Pipeline.md` (the caller), `Sources/Documentation - Sources - Local (Files, WhatsApp, iMessage, Notes).md` (what feeds the prompts), `Views/Onboarding/Documentation - Onboarding.md` (the download screen). LiteRT-LM references: https://ai.google.dev/edge/litert-lm/overview and https://ai.google.dev/edge/litert-lm/swift; the upstream source checkout for spelunking lives at the workspace root (`LiteRT-LM Codebase for Reference/`, gitignored, must never be moved inside the Xcode project tree).
