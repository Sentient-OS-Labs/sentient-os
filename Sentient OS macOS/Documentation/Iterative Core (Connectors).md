# Iterative Core (Connectors)

The connector-agnostic engine that is now the ONLY on-device reading pipeline. It reads a source
on-device, summarizes survivors, and ships them to the cloud to build/update the knowledge base.
All four on-device sources are connectors on this core: **Files, Apple Notes, WhatsApp, iMessage**.
One UI — `ProcessingView` — drives it for BOTH the home **Analyze Now** button and the dev
**start-on-device** buttons. Self-contained: its own SwiftData store (`CycleStore`), isolated from
everything else. The old belt (`DataSource`-two-phase protocol, `Pipeline`, the old `Store`,
`BackfillCursor`) has been **deleted** — the per-bucket high-water mark is the whole story now.

## The shared core — a connector answers four questions
A connector is dumb: it lists keyed work-items per bucket and loads one. *All* pointer logic lives in
`IterativeRun`, never in a connector.

- **`ItemKey`** (`Ingestion/ItemKey.swift`) — the universal order-key: `(order: Double, tiebreak:
  String)`, compared lexicographically. Files → `(dateAdded, path)` · Notes → `(createdDate, uuid)` ·
  Chats → `(Double(rowID), "")`. The tiebreak makes every item a distinct point so the pointer names
  *exactly one* boundary (chats need none — row ids are unique). `order` alone isn't unique for files
  (same date-added second), hence the tiebreak.
- **`Connector`** (`Ingestion/Connector.swift`) — `kind`, `maxTokens`, `buckets(since:) -> [Bucket]`
  (current eligible work-items per bucket, newest-first), `load(Candidate) -> Artifact`. A `Bucket` =
  `(key, items)` where `items` is `[(key: ItemKey, item: Candidate)]`. The `since` marks are a query
  HINT only — a connector MAY use them to read efficiently (e.g. a chat's `WHERE rowid > mark`), but
  the current connectors ignore them and list everything; `IterativeRun` filters and advances
  authoritatively, so returning extra items is harmless. Work payload + content reuse the existing
  `Candidate`/`Artifact` value types.
- **`CycleStore`** (`Ingestion/CycleStore.swift`) — `@ModelActor`, own on-disk store
  (`IterativeCycle.store`). `BucketPointer` (DURABLE high-water mark per bucket) + `CycleNote`
  (EPHEMERAL survivor, wiped each cycle; carries `kind`+`sourceID` for the cloud's trust tag). API:
  `pointer/allPointers/setPointer/clearBucket · recordNote/notes/wipeAllNotes/importNotes · counts`.
- **`IterativeRun`** (`Ingestion/IterativeRun.swift`) — drives any connector, three modes. **initial**:
  per bucket, clear it, walk items newest→oldest, set the mark = newest *on completion* (interrupted ⇒
  mark unset ⇒ iterative says "run initial first"). **iterative**: per bucket, take items `> mark`,
  walk oldest→newest, climb the mark *per item* (so a stopped run resumes). **auto**: per bucket,
  initial when the bucket has no mark yet, else iterative — so one Analyze Now backfills a fresh folder
  while catching the rest up, all in one pass. (Home → `.auto`; the dev INITIAL/ITERATIVE buttons →
  `.initial`/`.iterative`.) Reuses `Engine` + `Triage` + the GPU-wedge resilience (preemptive reload
  every ~40 items + reactive reload after a burst of failures). Survivors → `CycleNote`;
  junk/sensitive store nothing.

## The cycle (summaries are disposable)
*on-device summarize → cloud (make/update KB) → cloud (proactive judge) → next cycle.*
`CycleNote`s are ephemeral, so "tell cloud" just sends whatever exists (no "which are new?"
bookkeeping). Only the per-bucket mark persists. `CycleStore.wipeAllNotes()` is the cycle-end wipe.
It is NOT fired by the proactive button — that judge is read-only and re-runnable for prompt tuning
(`DevToolsView.runProactive` only reads `CycleStore.notes()`). Today the only wipe trigger is the dev
**Reset** action (`runReset`, which also clears the selected roots' pointers). Where the wipe belongs
in the real trigger sequence is a later wiring decision.

## The cloud — `VaultCloud` (`Ingestion/VaultCloud.swift`)
Connector-agnostic; operates on `CycleStore.notes()` regardless of source. The cycle's notes become
`CloudNote`s (`VaultGenerator.locSrc(kind:folder:sourceID:)` derives each note's per-source trust tag).
- `create` — "go make knowledge base exist": reuses `VaultGenerator().generate(notes:)` (staging dir +
  atomic swap + usage-limit resume).
- `update` — "go update knowledge base": surgical edits on the live vault (eval-validated prompt
  lifted verbatim from the old VaultUpdater; that updater is itself deleted).
- After create/update, `VaultCloud` only **marks the vault dirty** (`markDirty()` → `VaultActivity.vaultDirty`).
  It does NOT push. MCP sync is a SEPARATE step: the dev **MCP SYNC** button (`MirrorClient.push`) plus
  `VaultCloud.pushIfDirty()` run once on app launch as the catch-up. (To re-couple auto-push after a
  KB update, `markDirty()` just calls `pushIfDirty()`.)

Proactive intelligence is **its own module** (`Ingestion/Proactive.swift`) — the read-only judge over
the last week of `CycleStore.notes()` + the live vault. See its doc.

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

All four on-device source families run on the core, and the home's **Analyze Now** already routes
through `IterativeRun` (mode `.auto`) via the shared `ProcessingView`. **Remaining (out of scope
here):** add the automatic scheduler that calls these same entry points on its own clock.
Gmail/Calendar are the later cloud family (Gmail rides along as a cloud leg through `GmailConnect`).

`ProcessingView.connectors(from:)` turns the selected `RunSource`s into core connectors —
both the home Analyze Now and the dev start-on-device buttons share that one path. The dev cockpit
(`DevToolsView`) lays the buttons out as the INITIAL / ITERATIVE columns; "tell cloud" / proactive
operate on all of `CycleStore.notes()` regardless of connector.

## What was deleted (merged into the core)
`FileKey` / `FileStore` / `FileRun` / `FileVaultCloud` / `FileNotesView` → `ItemKey` / `CycleStore` /
`IterativeRun` / `VaultCloud` / `SummariesView`. The old reading belt is also fully gone: the
`DataSource` two-phase `scan/load` protocol + `ScanResult`/`BackfillCursor`, `Pipeline`, the old
`Store` (`Summary`/`SourceCursor` models), the `VaultUpdater`/`DaysEndJob` day's-end job, and the
streaming `Engine.generateStream`. `Sources/DataSource.swift` now holds ONLY the value types
(`SourceKind`, `Candidate`, `Artifact`); `Store/Models.swift` now holds ONLY `enum Verdict`. Still
live and reused by the core: `Engine`, `Triage`, `ProcessingView`, `DatabaseView`, `VaultGenerator`
(at the project root), `MirrorClient`, and every source file's `eligible…()` listing.

## Verify
`SENTIENT_SELFTEST=fileiter` — deterministic, no model/codex: ItemKey tiebreak · the newer-than-mark
partition (twin at the boundary) · CycleStore round-trip · `FilesConnector.buckets` skip/keep.
`SENTIENT_SELFTEST=notesiter` — runs the real `NotesConnector` against the live Notes DB (structural
invariants); needs Full Disk Access (skips gracefully without it).
`SENTIENT_SELFTEST=chatiter` — runs the real WhatsApp + iMessage connectors over all chats (per-chat
buckets · right kind · windows have text · keys unique + newest-first per chat); WhatsApp's group
container is readable without FDA (validated on 77 chats / 237 windows), iMessage's `chat.db` needs
FDA. Engine-driven + cloud end-to-end is exercised via the dev buttons.
