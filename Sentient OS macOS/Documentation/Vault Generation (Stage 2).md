# Vault Generation — Stage 2 (the agentic build)

`VaultGenerator.generate(notes:resume:onProgress:onLine:)` turns the on-device survivor summaries
(passed as `[CloudNote]`) into the markdown knowledge base at `~/Sentient OS - Knowledge Base/`,
through ONE route: `codex exec` via the `CodexCLI` spine — `gpt-5.6-sol` at **`.high` effort**
(every plan — the initial build's `.xhigh` override was retired 2026-07-10, it thinks far too
long; `.high` is also all a free/go plan's tiny monthly quota affords, see
`Plan Gate (CodexAuth & Knowledge-Base-Only).md`),
`workspace-write` sandbox, cwd = a staging dir; the model writes the `.md` files itself with its
file tools. Without a working codex the run throws `CodexCLI`'s `.notAvailable` (no fallback — a ChatGPT
subscription is a hard requirement; the old direct-Anthropic-API route was removed June 11 — its
key lived only in a gitignored `Secrets.swift` that was never committed, so no key is in history).

This is the first build. `Vault/VaultCloud.swift` is the iterative system's wrapper around it:
`VaultCloud.create()` reuses this generator; `VaultCloud.update()` merges each cycle's new notes.
**[UPDATED 2026-07-02, B11] Both build AND update now stage-then-swap** (update no longer edits the
live vault in place — see below). (The old `VaultUpdater`/`DaysEndJob` were deleted — `VaultCloud`
replaced them.)

## Why agentic (Arch §5/§6)

- **No per-message output cap** — the model writes files across turns instead of one giant response.
- **Resumable** — a usage-limit failure throws `VaultError.usageLimit(message:resume:)`; the
  `ResumeToken` carries the Codex session (thread) id AND the staging path. Passing it back to
  `generate(resume:)` continues the same session over the same half-written staging dir.
  ⚠️ On resume the workspace root is the PROCESS cwd (CodexCLI sets it from `Invocation.cwd`).
- **Free at the margin** — the user's own ChatGPT subscription does the work.

## Safety: staging + atomic swap (BOTH build & update — B11, 2026-07-02)

Neither build nor update ever touches the live knowledge base mid-run. Shared helpers on
`VaultGenerator`:
- **`newStagingDir(seedFrom:)`** — a `.sentientos-vault-staging-<uuid>` dir **sibling of the vault**
  (same volume as the vault, so an atomic swap works even under a `SENTIENT_VAULT_ROOT` scratch dir).
  **Build** seeds it empty; **update** seeds it with a **copy of the current vault** so codex has the
  existing notes to edit. It first **sweeps orphaned staging dirs** (they used to leak).
- **`swapStagingIntoVault`** — `FileManager.replaceItemAt` (a true same-volume atomic replace); on any
  throw the existing vault is left intact.
- **`runCodexInStaging`** — the shared codex run (progress poller + usage-limit → `ResumeToken`).

Only after the run succeeds (build: >0 notes; update: passes the freshness check) is the swap done.
A mid-run death (limit / crash / kill) leaves the previous vault untouched and the staging dir resumable.

**Durable resume for BOTH** — `VaultCloud` persists the `ResumeToken(sessionID, stagingPath[, vaultFingerprint])`
to UserDefaults (`vault.create.resume` / `vault.update.resume`), loaded in `init`, discarded if the
staging dir is gone or there's no session. So a usage limit **or an app restart** resumes over staging
instead of re-running the expensive initial build from scratch. (`ResumeToken` is `Codable`.)

**Update freshness check (concurrent editor edits)** — the Knowledge editor writes note files directly
into the live vault, so `update()` guards against clobbering a user edit: it (a) **skips** the merge if
`VaultActivity.editorBusy` at start, and (b) captures `VaultGenerator.vaultFingerprint(vault)` (a
SHA-256 over each `.md`'s `relpath|size|mtime`) at seed time — carried in the resume token — and at
swap time, if the live vault's fingerprint changed (the user saved a note during the run), it **aborts
the swap** (discards staging, emits `vault.update.stale_swap_averted`, re-runs next cycle) rather than
overwrite the edit.

*(This replaced the pre-B11 update path, which edited the live vault in place with a `.bak` restore —
that whole choreography, B1, is now deleted.)*

## Corpus batching — large first runs (`Vault/CorpusSlicer.swift`)

`codex exec` accepts a bounded per-turn input (~1 MiB, server-side). A data-rich Mac's first build
(thousands of survivor summaries) or a heavy week's update backlog can render past that in one
prompt, so the corpus is fed as a **byte-budgeted sequence of parts** instead of a single prompt.

- **`CorpusSlicer.slice(_:budget:)`** walks the notes in order and closes a part when the next
  entry's rendered cost would cross the budget (**700 KB default**, ~33% headroom under the cap;
  entries are never split — an oversized single entry gets its own part, loudly). It's deliberately
  dumb and deterministic: no ranking, no sampling, so identical input always re-derives identical
  parts — the property mid-sequence resume depends on. `CorpusSlicer.render` is the SAME entry
  rendering the prompts use, so measured cost can never drift from what's actually sent.
- **How the parts fold into one vault:** part one rides the existing **build** prompt; every later
  part folds into the *same staging dir* through the battle-tested **update/merge** prompt, a fresh
  codex session each. The single atomic staging → vault swap at the very end is unchanged, so a
  many-part run still lands as one clean replace. A single-part corpus takes the exact pre-existing
  code path — zero behavior change for normal-sized runs. `VaultCloud.update()` runs the same
  slicing loop, with the freshness check and the one swap still at the end.
- **Resume across parts:** `ResumeToken` carries a `sliceIndex` (the next unfed part) alongside the
  session id and staging path (decode-compatible with older tokens, which default to part 0). A
  usage-limit or restart mid-sequence resumes the in-flight session first, then continues the
  remaining parts — never re-feeding a completed one. A **staging-dir corpus snapshot**
  (`.sentient-corpus.json`, written only for multi-part runs, deleted before the swap and swept with
  any orphan staging) guarantees the identical re-slice across restarts even though `CycleStore`
  returns notes newest-first (a fresh fetch after more ingestion would otherwise shift every
  boundary).
- **The guard behind it:** `CodexCLI` rejects any prompt over `promptByteCap` (**950 KB**) pre-spawn
  with a typed `CLIError.inputTooLarge` — a belt-and-suspenders floor so a mis-budgeted prompt fails
  cleanly and classifiably (surfaced by `OvernightCaution` as honest banner/takeover copy) instead
  of erroring deep inside codex. Proactive's judge/research 7-day window is trimmed to the same
  shared byte budget (oldest dropped first).
- **Progress:** a multi-part run reports "part N of M" in the takeover phase line and Dev Tools.

Verified end-to-end at real-user scale: ~1,800 mixed-source summaries (2.55 MB rendered, 2.4× the
per-turn cap) built through 4 parts, with a project thread deliberately scattered across every part
consolidating into ONE domain in the finished vault — the cross-part seam produces no fragmentation.

## Progress

Two channels, both optional:
- **The filesystem poller** — a 2s poll of the staging dir's `.md` count → `Progress.writing(notes:)`
  → the caller's status line (Dev Tools shows "… writing N notes").
- **The live thought stream (2026-07-11)** — `generate`/`runCodexInStaging` (and
  `VaultCloud.create/update`) take an optional `onLine`, forwarded to `CodexCLI.run(_:onLine:)`,
  whose `humanLine` adapter reduces the `--json` events to readable play-by-play (reasoning ·
  `$ commands` · tool calls · web searches). `ProactiveCycle.run(progress:onLine:)` threads it from
  EVERY cloud stage (build/update · gift · judge · research) into the takeover's "THINKING" trail
  (`ProcessingView.liveThought`) — which drops `$ ` shell lines AND structured JSON output (the
  research stage's closing `{"ready":…}` verdict) as noise, and promotes thoughts at a 1.4s cadence
  into a fading three-line trail (newest brightest at the bottom; cleared per phase). The 3am
  scheduler passes nothing.

## The prompt

`vaultPromptCore` (the eval-validated wisdom: source-trust tiers, truth & attribution,
ruthless synthesis, README-first portrait, structure rules, 80–120-note density) +
`agenticOutputInstructions`. User-agnostic — no hardcoded per-user facts.

**2026-07-17 tightening (founder pass, both build AND update prompts):** density target lowered to
**80–120 notes** with hard shape caps — **at most ~10 root folders; a subfolder holds ~2–5
substantial notes** (overflow = consolidate, never another file) — plus a **never-assume rule**
("less knowledge is WAYYY better than wrong knowledge; if you're not sure, DON'T INCLUDE IT"). The
UPDATE prompt now quantifies consolidation (**~90% of merges edit an existing note; a new file is
~5%, only when truly deserved**), gates every merge on "genuinely makes the knowledge base more
VALUABLE", and carries the same shape targets — so six months of nightly merges can't sprawl the
vault into a scatter of tiny files.
⚠️ Known small-corpus finding (June 11, 83-summary eval): the fixed density target pulls
toward one-note-per-summary when the corpus is smaller than the target; revisit after the
full-scale (1,704-summary) gate run.

## The welcome letter — ✅ built (as `Proactive/GiftLetter.swift`)

The day-one "letter from Sentient" is now real: `GiftLetter.generate()` runs one hermetic codex call
over the finished knowledge base (it reads the vault, writes `Gift from Sentient.md`, we read it back,
persist it, and delete the file so nothing strays into the vault or the mirror). `ProactiveCycle`
writes it ONCE, the first time a knowledge base exists; the home renders it as the sealed envelope
card. See `Proactive Intelligence (Judge).md` §The welcome gift.

## Self-test

*(Recreate the harness first — see `Self-Testing (Eval Harness).md`; `Self Tests - Temp/` is kept empty.)*

```sh
SENTIENT_SELFTEST=vault SENTIENT_SELFTEST_N=8 "<app>/Contents/MacOS/Sentient OS"   # tiny subset
SENTIENT_VAULT_ROOT=/tmp/scratch …                                                  # protect the real vault
```

## Siblings on the same spine

The iterative knowledge-base update (`VaultCloud.update()`, see `Vault/VaultCloud.swift`) rides the
same `CodexCLI` spine — surgical edits over a staged COPY of the vault, atomically swapped in on
success (B11, above). `VaultCloud.create()` calls straight into this generator for the first build.
Both live in `Vault/` alongside `VaultActivity` (the dirty-flag / debounced-mirror-sync seam).
