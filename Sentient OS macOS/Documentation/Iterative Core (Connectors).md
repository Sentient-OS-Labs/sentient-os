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
  `pointer/setPointer/clearBucket · recordNote/notes/wipeAllNotes · counts · allPointers`.
- **`IterativeRun`** (`Ingestion/IterativeRun.swift`) — drives any connector. **initial**: per bucket,
  clear it, walk items newest→oldest, set the mark = newest *on completion* (interrupted ⇒ mark unset
  ⇒ iterative says "run initial first"). **iterative**: per bucket, take items `> mark`, walk
  oldest→newest, climb the mark *per item* (so a stopped run resumes). Reuses `Engine` + `Triage` +
  the GPU-wedge resilience. Survivors → `CycleNote`; junk/sensitive store nothing.

## The cycle (summaries are disposable)
*on-device summarize → cloud (make/update KB) → cloud (proactive judge) → next cycle.*
`CycleNote`s are ephemeral, so "tell cloud" just sends whatever exists (no "which are new?"
bookkeeping). Only the per-bucket mark persists. (`wipeAllNotes` is the cycle-end wipe; the proactive
button no longer fires it — the judge is read-only + re-runnable for prompt tuning. Where the wipe
belongs in the real trigger sequence is a later wiring decision.)

## The cloud — `VaultCloud` (`Ingestion/VaultCloud.swift`)
Connector-agnostic; operates on `CycleStore.notes()` regardless of source (`CloudNote.locSrc` keys on
`kind`/`sourceID` for per-source trust tiers).
- `create` — reuses `VaultGenerator.generate(notes:)` (staging + atomic swap + usage-limit resume).
- `update` — surgical edits on the live vault (eval-validated prompt lifted from the old VaultUpdater).
- After create/update: mirror push (the retired `DaysEndJob.pushIfDirty` rule).

Proactive intelligence is **its own module** (`Ingestion/Proactive.swift`, Arch §6) — the read-only
judge over the last week of `CycleStore.notes()` + the live vault. See its doc.

## Connectors
- **`FilesConnector`** (`Ingestion/Connectors/FilesConnector.swift`) ✅ — one bucket per `FileRoot`
  (`file:<root.id>`), key `(dateAdded, path)`, item = a file. Wraps `FilesSource.eligibleFiles`
  (skip rules + caps) + `FilesSource.loadArtifact`.
- **`NotesConnector`** (`Ingestion/Connectors/NotesConnector.swift`) ✅ — single bucket `"notes"`,
  key `(createdDate, "notes:<uuid>")`, item = a note; wraps `NotesSource.eligibleNotes` (reuses the
  gunzip/protobuf `decodeBody`). **Created-date** key ⇒ edited notes are **not** re-summarized.
  Needs Full Disk Access.
- **`WhatsAppConnector` / `iMessageConnector`** (`Ingestion/Connectors/ChatConnectors.swift`) ✅ —
  per chat (`whatsapp:<jid>` / `imessage:<guid>`), key `(rowID, "")` (row id is unique + monotonic →
  no tiebreak), item = a `ChatWindowing` window (so `maxTokens` 16384), chat Triage prompt (DM vs
  group). Wrap each source's `eligibleWindows()` (reuses `ChatWindowing` / `SQLiteDB` /
  `AddressBookNames` / the typedstream decode). Per-chat opt-in via the dev picker's chat selection.

All three on-device source families now run on the core. **Remaining (out of scope here):** rewire
the home's Analyze Now to `IterativeRun`, add the scheduler, then delete the old belt
(`DataSource`/`Pipeline`/old `Store` + the sources' `scan` paths). Gmail/Calendar are the later cloud family.

The dev cockpit (`DevToolsView`) has an **ON-DEVICE CONNECTOR** picker (Files / Apple Notes) that
routes the INITIAL/ITERATIVE buttons to the chosen connector. "tell cloud" / proactive operate on
all of `CycleStore.notes()` regardless of connector.

## What was deleted (folded into the core)
`FileKey` / `FileStore` / `FileRun` / `FileVaultCloud` / `FileNotesView` → `ItemKey` / `CycleStore` /
`IterativeRun` / `VaultCloud` / `SummariesView`. (Earlier, the old iterative updater — `VaultUpdater`,
`DaysEndJob`, `VaultView` — was already removed.) Still kept for the home + un-migrated sources:
`Pipeline`, old `Store`, `DataSource`, `ProcessingView`, `DatabaseView`, `VaultGenerator`,
`MirrorClient`, all source files.

## Verify
`SENTIENT_SELFTEST=fileiter` — deterministic, no model/codex: ItemKey tiebreak · the newer-than-mark
partition (twin at the boundary) · CycleStore round-trip · `FilesConnector.buckets` skip/keep.
`SENTIENT_SELFTEST=notesiter` — runs the real `NotesConnector` against the live Notes DB (structural
invariants); needs Full Disk Access (skips gracefully without it).
`SENTIENT_SELFTEST=chatiter` — runs the real WhatsApp + iMessage connectors over all chats (per-chat
buckets · right kind · windows have text · keys unique + newest-first per chat); WhatsApp's group
container is readable without FDA (validated on 77 chats / 237 windows), iMessage's `chat.db` needs
FDA. Engine-driven + cloud end-to-end is exercised via the dev buttons.
