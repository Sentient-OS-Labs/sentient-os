# Iterative Core (Connectors)

The connector-agnostic engine behind the **DEV TOOLS sheet** (INITIAL | ITERATIVE mockup). It reads
a source on-device, summarizes survivors, and ships them to the cloud to build/update the vault.
**Files is the first connector**; Notes and WhatsApp/iMessage are adapters that plug into the same
core (in progress). Self-contained: its own SwiftData store, isolated from the old `Store`. The old
belt (`DataSource` → `Pipeline` → `Store` + `BackfillCursor`) still serves the home's Analyze Now and
the not-yet-migrated sources; it's deleted once everything migrates.

## The shared core — a connector answers four questions
A connector is dumb: it lists keyed work-items per bucket and loads one. *All* pointer logic lives in
`IterativeRun`, never in a connector.

- **`ItemKey`** (`Ingestion/ItemKey.swift`) — the universal order-key: `(order: Double, tiebreak:
  String)`, compared lexicographically. Files → `(dateAdded, path)` · Notes → `(createdDate, uuid)` ·
  Chats → `(Double(rowID), "")`. The tiebreak makes every item a distinct point so the pointer names
  *exactly one* boundary (chats need none — row ids are unique). `order` alone isn't unique for files
  (same date-added second), hence the tiebreak.
- **`Connector`** (`Ingestion/Connector.swift`) — `kind`, `maxTokens`, `buckets(since:) -> [Bucket]`
  (current work-items per bucket, newest-first; `since` is a query hint — chats use `WHERE rowid >
  mark`), `load(Candidate) -> Artifact`. A `Bucket` = `(key, [(ItemKey, Candidate)])`. Work payload +
  content reuse the existing `Candidate`/`Artifact` value types.
- **`CycleStore`** (`Ingestion/CycleStore.swift`) — `@ModelActor`, own on-disk store
  (`IterativeCycle.store`). `BucketPointer` (DURABLE high-water mark per bucket) + `CycleNote`
  (EPHEMERAL survivor, wiped each cycle; carries `kind`+`sourceID` for the cloud's trust tag). API:
  `pointer/setPointer/clearBucket · recordNote/notes/reminderNotes/wipeAllNotes · counts · allPointers`.
- **`IterativeRun`** (`Ingestion/IterativeRun.swift`) — drives any connector. **initial**: per bucket,
  clear it, walk items newest→oldest, set the mark = newest *on completion* (interrupted ⇒ mark unset
  ⇒ iterative says "run initial first"). **iterative**: per bucket, take items `> mark`, walk
  oldest→newest, climb the mark *per item* (so a stopped run resumes). Reuses `Engine` + `Triage` +
  the GPU-wedge resilience. Survivors → `CycleNote`; junk/sensitive store nothing.

## The cycle (summaries are disposable)
*on-device summarize → cloud (make/update KB) → cloud (proactive) → wipe summaries → next cycle clean.*
`CycleNote`s are ephemeral, so "tell cloud" just sends whatever exists (no "which are new?"
bookkeeping); the **proactive button ends the cycle by wiping all notes**. Only the per-bucket mark
persists.

## The cloud — `VaultCloud` (`Ingestion/VaultCloud.swift`)
Connector-agnostic; operates on `CycleStore.notes()` regardless of source (`CloudNote.locSrc` keys on
`kind`/`sourceID` for per-source trust tiers).
- `create` — reuses `VaultGenerator.generate(notes:)` (staging + atomic swap + usage-limit resume).
- `update` — surgical edits on the live vault (eval-validated prompt lifted from the old VaultUpdater).
- `proactive` — **placeholder** (read-only Codex call) over the reminder-flagged notes; returns a count.
- After create/update: mirror push (the retired `DaysEndJob.pushIfDirty` rule).

## Connectors
- **`FilesConnector`** (`Ingestion/Connectors/FilesConnector.swift`) ✅ — one bucket per `FileRoot`
  (`file:<root.id>`), key `(dateAdded, path)`, item = a file. Wraps `FilesSource.eligibleFiles`
  (skip rules + caps) + `FilesSource.loadArtifact`.
- **NotesConnector** (next) — single bucket `"notes"`, key `(createdDate, uuid)`, item = a note;
  reuse `NotesSource.decodeBody`. Created-date key ⇒ edited notes are **not** re-summarized.
- **ChatConnector** (after) — per chat (`whatsapp:<jid>` / `imessage:<guid>`), key `(rowID, "")`,
  item = a `ChatWindowing` window; reuse `ChatWindowing` / `SQLiteDB` / `AddressBookNames`.

## What was deleted (folded into the core)
`FileKey` / `FileStore` / `FileRun` / `FileVaultCloud` / `FileNotesView` → `ItemKey` / `CycleStore` /
`IterativeRun` / `VaultCloud` / `SummariesView`. (Earlier, the old iterative updater — `VaultUpdater`,
`DaysEndJob`, `VaultView` — was already removed.) Still kept for the home + un-migrated sources:
`Pipeline`, old `Store`, `DataSource`, `ProcessingView`, `DatabaseView`, `VaultGenerator`,
`MirrorClient`, all source files.

## Verify
`SENTIENT_SELFTEST=fileiter` — deterministic, no model/codex: ItemKey tiebreak · the newer-than-mark
partition (twin at the boundary) · CycleStore round-trip · `FilesConnector.buckets` skip/keep.
Engine-driven + cloud end-to-end is exercised via the dev buttons on real folders.
