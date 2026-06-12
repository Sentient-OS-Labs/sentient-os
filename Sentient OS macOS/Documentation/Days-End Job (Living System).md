# The Day's-End Job — the Living System (June 11)

The knowledge-base lifecycle behind ONE entry point: `DaysEndJob.shared.run(store:)`.
Pipeline: editor-idle check → iterative updater → mirror push → notification. Idempotent
(empty queue = cheap no-op), single-flight (an actor bool; re-triggers while running are
ignored).

**Proactive intelligence is deliberately NOT in this pipeline** (June 11 decision): it's
being built separately with its own trigger, scheduled to run AFTER a knowledge-base update
(both are agentic jobs over the same vault — sequence, never parallelize). A fully working
scaffold (judge with `--json-schema` decisions, ≤1/day cap enforced in code, tier-1 scheduled
reminders, tier-2 agentic briefings with WebSearch) lives in git history at `67d8078` — mine
it when rebuilding. Two hard-won lessons from its live runs: store date-valued pointers in
Date's NATIVE `timeIntervalSinceReferenceDate` (epoch conversion round-trips lossily and
re-judges the newest item), and never call `UNUserNotificationCenter.requestAuthorization`
from a headless run (it hangs).

**Trigger:** the "Update Knowledge Base" dev button in RootView's DEV CONTROLS — deliberately
the ONLY trigger until the condition-gate scheduler lands. The scheduler will simply call the
same function on its own clock; no logic lives in the button.

## The iterative updater (`VaultUpdater`)

- **Queue:** every `Summary` with `syncedToVault == nil`, oldest first, carried with
  `PersistentIdentifier`s — summaries are versioned, so we stamp the EXACT rows we sent, never
  "by sourceID". The queue self-populates (rows are born unsynced) and self-heals (failed jobs
  stamp nothing; rows simply re-enter).
- **The job:** ONE `claude -p` call — `--model sonnet`, tools `Read,Glob,Grep,Write,Edit`,
  **cwd = the LIVE vault** (no staging dir: inputs are tiny, edits are surgical), 30-min
  timeout. Stdin = the vault's skeleton tree + the new summaries (title, text, itemDate,
  source-trust tag) + the editing-flavored port of the Stage-2 core (truth/attribution,
  source-trust tiers, explore-only-what-you-need, never delete wholesale).
- **Safety net:** `cp -R` snapshot before the job. A thrown error mid-edit restores it; a
  **usage limit does NOT** — the half-edited vault is exactly what `--resume` (session id kept
  in memory) continues from. Either way nothing was stamped, so a fresh restart is also correct.
- **On success:** stamp the sent rows, set `VaultActivity.vaultDirty`.
- ⚠️ **Sized for daily deltas, not a from-scratch corpus.** After a schema wipe with an
  existing vault on disk: re-analyze, then stamp the corpus directly (see PR #12's migration
  note) instead of folding ~everything through Sonnet.

## Editor-idle + push (`VaultActivity` — the seam, not the feature)

- `editorBusy` (always false today; the Phase-5 editor will set it): the job returns
  immediately — never blocks/waits, the next trigger retries.
- `vaultDirty` (persisted in UserDefaults): set by the updater AND by initial generation;
  cleared **only after a successful push**, so a transient network failure just retries next
  run. `DaysEndJob.pushIfDirty()` is the one push path — initial gen calls it too, which
  closes the "nothing auto-pushes yet" gap from Arch §7.

## Notifications (`Notify`)

Small `UNUserNotificationCenter` wrapper (`now(title:body:)` only, for now). Permission is
requested lazily on first use (the real ask moves into onboarding); suppressed entirely under
`SENTIENT_SELFTEST`. Quiet by design — no-op runs never notify.

## The welcome briefing

Initial generation's second act (`VaultGenerator.writeWelcomeBriefing()`): a cheap Sonnet pass
over the freshly built vault that writes "What I learned about you" (portrait + 3–5
cross-domain connections + what happens next) into the **Briefings folder**
(`~/Library/Application Support/SentientOS/Briefings/` — deliberately OUTSIDE the vault, so
For You artifacts never ride the mirror push). Best-effort, off the UI path, fired alongside
the post-gen mirror push.

## Self-test (a real Sonnet call — it spends a little budget)

- `SENTIENT_SELFTEST=daysend SENTIENT_VAULT_ROOT=/tmp/scratch` — fixture vault + seeded queue
  → run → asserts the fold, exact-row stamping, vault change, and the second-run no-op.
  REQUIRES the vault-root override; refuses to run if the mirror is enabled without
  `SENTIENT_MIRROR_BASE` (the push step would clobber the real hosted mirror).
- `SENTIENT_VAULT_ROOT` is honored by everything vault-shaped (generator, updater, mirror zip).
