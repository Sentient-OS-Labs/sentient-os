# Files Iterative System (Interval Pointer)

The from-scratch rebuild of the iterative updater, **files-only** (June 13). It replaces the old
ledger-less pointer + `VaultUpdater`/`DaysEndJob` machinery *for files*. Messages/WhatsApp/iMessage/
Notes are **untouched** — they still run the old shared belt (`DataSource` → `Pipeline` → `Store`,
with `BackfillCursor`) and will migrate to this system later.

It is **self-contained** (new `File Ingestion/` group + its own SwiftData store) and driven entirely
from the **DEV TOOLS sheet** (`DevToolsView`) — the hand-drawn INITIAL | ITERATIVE mockup.

## The one durable idea: a per-folder processed interval

The only thing that survives a cycle is, per file root, the **processed interval `[lo, hi]`** of the
**date-added** timeline. Each bound is a `FileKey = (dateAdded, path)`:

- **`hi`** = newest file processed. The anchor the next ITERATIVE run starts *above*.
- **`lo`** = oldest file processed. An INITIAL top→bottom descent slides it down.

**Why `(dateAdded, path)` and not just a date** (`FileKey.swift`): `kMDItemDateAdded` is only
second-precise and real folders have files sharing the exact same second (two screenshots at
9:29 PM). A date-only boundary can't tell those twins apart when the folder is re-scanned on a later
run → it would either reprocess one (dup) or skip one (lost). The path is the tiebreak: it makes
every file a distinct point so the boundary names *exactly one* file. **Date added** (not created/
modified) is the key because it's "when this entered my life", and we deliberately do **not**
reprocess edited files.

## The cycle (and why summaries are disposable)

A cycle = *on-device summarize → cloud (make/update KB) → cloud (proactive) → wipe summaries → next
cycle starts clean*. So **`FileNote`s are ephemeral** — they live only for one cycle. That means
"tell cloud" just sends whatever notes currently exist (no "which are new?" bookkeeping), and the
**proactive button ends the cycle by wiping all notes**. The interval pointer persists; the
summaries do not.

## Components (`File Ingestion/`)

- **`FileKey.swift`** — the `(dateAdded, path)` ordered key (the tiebreak, in one place).
- **`FileStore.swift`** — `@ModelActor` over its **own** on-disk container (`FileIngestion.store`,
  isolated from the old `Store`'s `default.store` so adding these models never schema-wipes the dev
  DB). Models: `FolderPointer` (durable interval) + `FileNote` (ephemeral survivor). API:
  `interval/setInterval/clearFolder · recordNote/notes/reminderNotes/wipeAllNotes · counts`.
- **`FileRun.swift`** — the on-device orchestrator. Reuses `Engine` + `Triage` + `FilesSource`
  (`eligibleFiles` + `load`); mirrors `Pipeline`'s GPU-wedge resilience.
  - `runInitial(roots:)` — top→bottom: `clearFolder`, pin `hi` at the newest, walk newest→oldest,
    slide `lo` down.
  - `runIterative(roots:)` — bottom→top: take files with `key > hi`, walk oldest→newest, slide `hi`
    up. (No interval yet ⇒ "run initial first", skipped.)
  - The interval advances after **every** item (survivor / junk / sensitive / given-up) so it stays
    contiguous and a stopped run resumes; survivors write a `FileNote`, junk/sensitive store nothing
    (zero trace).
- **`FileVaultCloud.swift`** — the three Codex calls + the `CloudNote` value type (decouples the
  cloud prompts from the old `Store`'s `SummaryItem`/`PersistentIdentifier`):
  - `create` — reuses `VaultGenerator.generate(notes:)` (staging + atomic swap + usage-limit resume).
  - `update` — surgical edits on the live vault; the eval-validated prompt is lifted from the old
    `VaultUpdater` (orchestration rebuilt here — no store queue, since notes are wiped wholesale).
  - `proactive` — **placeholder** (read-only Codex call) over the reminder-flagged notes; returns a
    count. Real proactive intelligence is future work (`// TODO`).
  - After create/update it pushes the mirror (same rule as the retired `DaysEndJob.pushIfDirty`).
- **`FileNotesView.swift`** — the VIEW SUMMARIES list (the current cycle's `FileNote`s).
- **`Views/DevToolsView.swift`** — the cockpit: source chips on top, INITIAL | ITERATIVE columns
  (3 buttons each), VIEW SUMMARIES, and a "More" disclosure (legacy Start Analysis, old-store viewer,
  file-store reset, FDA). The new buttons act on the selected **file** roots; messages/Notes run from
  the home's Analyze Now / "More".

## What was deleted (the old iterative updater)

`VaultUpdater.swift`, `DaysEndJob.swift`, `VaultView.swift` (Create Knowledge Base — it only lived in
the dev sheet), and their self-tests (`SelfTest_E2E`, `SelfTest_UpdaterE2E`). **Kept** (the home +
messages need them): `Pipeline`, old `Store`/`Summary`/`SourceCursor`, `DataSource`, `VaultGenerator`
(refactored to take `CloudNote`), `MirrorClient`, `ProcessingView`, `DatabaseView`, all message/Notes
sources. (`Store.survivorSummaries/unsynced/markSynced` are now dormant — they belong to the future
messages migration.)

## Verify

`SENTIENT_SELFTEST=fileiter` — deterministic, no model/codex: FileKey tiebreak · the newer-than-hi
partition (twin at the boundary) · FileStore round-trip · eligibleFiles skip/keep. The
engine-driven + cloud end-to-end is exercised by clicking the dev buttons on real folders.
