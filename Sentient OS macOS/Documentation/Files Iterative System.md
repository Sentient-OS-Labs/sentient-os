# Files Iterative System (Interval Pointer)

The from-scratch rebuild of the iterative updater, **files-only** (June 13). It replaces the old
ledger-less pointer + `VaultUpdater`/`DaysEndJob` machinery *for files*. Messages/WhatsApp/iMessage/
Notes are **untouched** — they still run the old shared belt (`DataSource` → `Pipeline` → `Store`,
with `BackfillCursor`) and will migrate to this system later.

It is **self-contained** (new `File Ingestion/` group + its own SwiftData store) and driven entirely
from the **DEV TOOLS sheet** (`DevToolsView`) — the hand-drawn INITIAL | ITERATIVE mockup.

## The one durable idea: a per-folder high-water mark

The only thing that survives a cycle is, per file root, a single **high-water mark** = the **newest
file processed**, stored as a `FileKey = (dateAdded, path)`. Invariant: everything ≤ the mark is
done; everything newer is new (the next ITERATIVE run starts *above* it). INITIAL sets it = newest
once its descent completes; ITERATIVE climbs it up, per item.

*(There is no `[lo, hi]` interval — an earlier design tracked the descent's low end too, but it was
write-only: nothing ever read it. The mark alone is sufficient. The trade is that a stopped INITIAL
restarts rather than resumes — fine, since initial is the one-time, foreground, watched run, and the
ongoing ITERATIVE flow is single-mark crash-resumable.)*

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
**proactive button ends the cycle by wiping all notes**. The high-water mark persists; the
summaries do not.

## Components (`File Ingestion/`)

- **`FileKey.swift`** — the `(dateAdded, path)` ordered key (the tiebreak, in one place).
- **`FileStore.swift`** — `@ModelActor` over its **own** on-disk container (`FileIngestion.store`,
  isolated from the old `Store`'s `default.store` so adding these models never schema-wipes the dev
  DB). Models: `FolderPointer` (durable high-water mark) + `FileNote` (ephemeral survivor). API:
  `pointer/setPointer/clearFolder · recordNote/notes/reminderNotes/wipeAllNotes · counts`.
- **`FileRun.swift`** — the on-device orchestrator. Reuses `Engine` + `Triage` + `FilesSource`
  (`eligibleFiles` + `load`); mirrors `Pipeline`'s GPU-wedge resilience.
  - `runInitial(roots:)` — top→bottom: `clearFolder`, walk newest→oldest, then on completion set the
    mark = newest. (Interrupted ⇒ mark stays unset ⇒ iterative says "run initial first".)
  - `runIterative(roots:)` — bottom→top: take files with `key > mark`, walk oldest→newest, climbing
    the mark per item (so a stopped run resumes). No mark yet ⇒ "run initial first", skipped.
  - Survivors write a `FileNote`; junk/sensitive store nothing (zero trace).
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
