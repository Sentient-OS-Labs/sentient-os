# Vault Generation — Stage 2 (the agentic build)

`VaultGenerator.generate(notes:resume:onProgress:onLine:)` turns the on-device survivor summaries
(passed as `[CloudNote]`) into the markdown knowledge base at `~/Sentient OS - Knowledge Base/`,
through ONE route: `codex exec` via the `CodexCLI` spine — `gpt-5.6-sol` at **`.high` effort**
(every plan — the initial build's `.xhigh` override was retired 2026-07-10, it thinks far too
long; `.high` is also all a free/go plan's tiny monthly quota affords, see
`Plan Gate (CodexAuth & Knowledge-Base-Only).md`),
`workspace-write` sandbox, cwd = a staging dir; the model writes the `.md` files itself with its
file tools. Without a working codex the run throws `CodexCLI`'s `.notAvailable` (no fallback — a ChatGPT
subscription is a hard requirement; the old direct-Anthropic-API route and its
`Secrets.swift` dev key were deleted June 11 and live in git history).

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
