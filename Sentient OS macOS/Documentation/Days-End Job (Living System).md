# The Day's-End Job — the Living System (June 11)

Everything that makes Sentient *sentient*, behind ONE entry point: `DaysEndJob.shared.run(store:)`.
Pipeline: editor-idle check → iterative updater → proactive intelligence → mirror push →
notification. Idempotent (empty queue = cheap no-op), single-flight (an actor bool; re-triggers
while running are ignored).

**Trigger:** the "Run Proactive Intelligence" dev button in RootView's DEV CONTROLS (it fires
the whole day's-end pipeline, not just the judge) — deliberately the ONLY trigger until the
condition-gate scheduler lands. The scheduler will simply call the same function on its own
clock; no logic lives in the button.

## The iterative updater (`VaultUpdater`)

- **Queue:** every `Summary` with `syncedToVault == nil`, oldest first, carried with
  `PersistentIdentifier`s — summaries are versioned, so we stamp the EXACT rows we sent, never
  "by sourceID". The queue self-populates (rows are born unsynced) and self-heals (failed jobs
  stamp nothing; rows simply re-enter).
- **The job:** ONE `codex exec` call — GPT-5.5 medium effort, `workspace-write` sandbox,
  **cwd = the LIVE vault** (no staging dir: inputs are tiny, edits are surgical), 30-min
  timeout. Stdin = the vault's skeleton tree + the new summaries (title, text, itemDate,
  source-trust tag) + the editing-flavored port of the Stage-2 core (truth/attribution,
  source-trust tiers, explore-only-what-you-need, never delete wholesale).
- **Safety net:** `cp -R` snapshot before the job. A thrown error mid-edit restores it; a
  **usage limit does NOT** — the half-edited vault is exactly what a session resume
  (`codex exec resume`, id kept in memory) continues from. Either way nothing was stamped, so
  a fresh restart is also correct.
- **On success:** stamp the sent rows, set `VaultActivity.vaultDirty`.

## Editor-idle + push (`VaultActivity` — the seam, not the feature)

- `editorBusy` (always false today; the Phase-5 editor will set it): the job returns
  immediately — never blocks/waits, the next trigger retries.
- `vaultDirty` (persisted in UserDefaults): set by the updater AND by initial generation;
  cleared **only after a successful push**, so a transient network failure just retries next
  run. `DaysEndJob.pushIfDirty()` is the one push path — initial gen calls it too, which
  closes the "nothing auto-pushes yet" gap from Arch §7.

## Proactive Intelligence (`Proactive`)

- **Selection:** reminder-flagged summaries with `createdAt` past the `proactive` cursor.
- **The judge:** one Sonnet call, NO tools, `--json-schema` →
  `{"decisions":[{kind: remind|brief|skip, time, text, reason}]}`. The taste law is in the
  prompt (*most days: nothing; at most ONE per day; only time-sensitive, personally
  actionable*) **and enforced in code** — first non-skip decision wins, rest dropped.
- **Tier 1 (remind):** `Notify.schedule(at:)` — past/unparseable time fires now (better a late
  nudge than a silent drop).
- **Tier 2 (brief):** a second agentic call — `Read,Glob,Grep,WebSearch,Write`, cwd = vault
  (context), `--add-dir` the **Briefings folder** (`~/Library/Application
  Support/SentientOS/Briefings/`, deliberately OUTSIDE the vault so briefings never ride the
  mirror push) → one `<yyyy-MM-dd> — <slug>.md` + a notification. **Never auto-sends** — drafts
  and offers only.
- Failures never block the updater/push; the pointer doesn't advance and tomorrow re-judges.

## Notifications (`Notify`)

Small `UNUserNotificationCenter` wrapper: `now`/`schedule(at:)→id`/`cancel(id:)`. Permission is
requested lazily on first use (the real ask moves into onboarding). Quiet by design — no-op
runs never notify.

## The welcome briefing

Initial generation's second act (`VaultGenerator.writeWelcomeBriefing()`): a cheap Sonnet pass
over the freshly built vault that writes "What I learned about you" (portrait + 3–5
cross-domain connections + what happens next) into Briefings — For You's day-one artifact.
Best-effort, off the UI path, fired alongside the post-gen mirror push.

## Self-tests (real Sonnet calls — they spend a little budget)

- `SENTIENT_SELFTEST=daysend SENTIENT_VAULT_ROOT=/tmp/scratch` — fixture vault + seeded queue
  → run → asserts the fold, exact-row stamping, vault change, and the second-run no-op.
  REQUIRES the vault-root override; refuses to run if the mirror is enabled without
  `SENTIENT_MIRROR_BASE` (the push step would clobber the real hosted mirror).
- `SENTIENT_SELFTEST=proactive` — seeds one actionable + one stale flagged summary → proves
  judging, the ≤1/day cap, and the pointer (re-run judges nothing).
- `SENTIENT_VAULT_ROOT` is honored by everything vault-shaped (generator, updater, mirror zip).
