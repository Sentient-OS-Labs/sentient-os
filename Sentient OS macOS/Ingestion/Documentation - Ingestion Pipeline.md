# Ingestion Pipeline (Ingestion/)

The one on-device reading pipeline: **Connector → IterativeRun → CycleStore**. Every local source
(Files, Apple Notes, WhatsApp, iMessage) is a connector on this core, one screen (`ProcessingView`)
drives it for both the home's Analyze Now and the dev buttons, and the 3 AM scheduler runs the exact
same code. It is crash-safe by construction: every processed item commits its survivor note and its
progress marker in ONE store write, so an interrupted run resumes exactly where it stopped, never
duplicating and never skipping.

## Files

| File | Job |
|---|---|
| `Connector.swift` | The `Connector` protocol and `Bucket`. A connector is deliberately dumb: it lists its current work items per bucket (newest first) and loads one item's content. All pointer logic lives in `IterativeRun`. |
| `ItemKey.swift` | A work item's position in its connector's timeline: `(order, tiebreak)`. Files use (date added, path), Notes (creation date, uuid), chats (row id, ""). |
| `CycleStore.swift` | The pipeline's own SwiftData store: durable per-bucket pointers + ephemeral survivor summaries, with the atomic per-item commit. |
| `IterativeRun.swift` | The orchestrator: drives any connectors through one `Engine`, per bucket, in `.initial` / `.iterative` / `.auto` mode. Owns the GPU-wedge recovery, per-item extraction timeout, per-source time budget, and progress reporting. |
| `Connectors/FilesConnector.swift` · `NotesConnector.swift` · `ChatConnectors.swift` | Thin adapters over the `Sources/` readers: one bucket per folder root, one bucket for Notes, one bucket per chat. |
| `LifetimeStats.swift` | The lifetime counters ("I've read 12,438 things"). Numbers only; the only memory that a junk or sensitive item was ever looked at. |
| `PipelineActivity.swift` | A tiny "is a run active?" counter (`IterativeRun` and `ProactiveCycle` bump it). Settings disables Reset and Uninstall while it is non-zero; the updater also refuses to relaunch during a run. |
| `FactoryReset.swift` | The one full wipe shared by Settings → System → Reset and Dev Tools → Reset everything: cycle store, knowledge base folder, proactive traces, counters, cloud copy (best-effort), and the rewind to the start of onboarding. |

## The data model (`CycleStore`)

Its own on-disk container: `~/Library/Application Support/SentientOS/IterativeCycle.store`. Two models:

- **`BucketPointer` (durable, one per bucket).** Normally the **high-water mark**: everything at or below `(order, tiebreak)` is done, everything newer is new. During a bucket's FIRST run it also carries a **floor**: the mark holds the top (the newest item this first run covers), and the floor is the oldest item done so far, sinking one item at a time. A non-nil floor is the single tell that a first run is mid-descent. When the descent reaches the bottom, the floor collapses and the mark becomes a normal high-water mark. This is the only state that survives a cycle.
- **`CycleNote` (ephemeral, one per survivor).** The summary text, title, source kind, source id, folder tag, item date, and a `reminderFlagged` hint. Wiped at the end of every successful full cycle (`ProactiveCycle` step 4). Junk and sensitive items store nothing.

Bucket keys are the pointer namespace: `file:<root.id>` per folder root, `notes`, `whatsapp:<jid>`,
`imessage:<guid>`, and the cloud legs' `gmail` / `calendar`.

Write paths that matter:

- `advance(bucketKey:note:to:)`: everyday mode. Records the optional survivor note AND moves the mark, in one save.
- `sinkFloor(bucketKey:note:top:floor:)`: first-run mode. Records the note AND lowers the floor, in one save.
- `collapseFloor`: first run reached the bottom.
- `setPointer` (used by the Gmail/Calendar legs, which stamp a run-time mark and have no descent), `clearBucket` (an explicit initial reset), `wipeAllNotes` (cycle end), `wipeEverything` (factory reset), `importNotes` (a dev cross-pollination tool: summaries only, never pointers).
- All writes go through a collision-safe update-or-insert (`commit`) that rolls back and retries once, so a fetch or save failure can never make a bucket reprocess forever.

`CycleNoteItem` is the Sendable snapshot the UI and cloud calls consume; `CycleStore.scheme(_:)` is the
only part of a bucket key that may be logged (the full key can carry a phone-number JID or a file path).

## The run (`IterativeRun.run(connectors, mode:)`)

1. Bump `PipelineActivity`; if any DB source is selected, report the Full Disk Access probe once (an empty-morning diagnostic).
2. Create ONE `Engine` sized to the largest `maxTokens` among the connectors and load it. A load failure ends the run with a structured event.
3. For each connector, ask for its buckets. The `since` marks passed in are only a query hint (a connector may use them to read efficiently); the run still filters authoritatively. Buckets mid-first-run are omitted from the hints so their connector returns the full set.
4. For each bucket, pick the effective mode:
   - **`.initial`** (top → bottom): walk newest → oldest, sinking the floor per item. Resumes strictly below an existing floor. An EXPLICIT `.initial` first clears the bucket (a full reset); an `.auto`-chosen initial keeps partial progress.
   - **`.iterative`** (bottom → top): items past the mark, oldest → newest, advancing the mark per item. A bucket with no mark or an unfinished first run is skipped ("run initial first").
   - **`.auto`** (the everyday mode: the home, onboarding, the 3 AM run): initial if the bucket has no mark yet or a first run is mid-descent, else iterative. So one Analyze Now backfills a freshly added folder, resumes an interrupted first run, and catches everything else up.
5. Per item: load the content (a 30 s wall-clock extraction timeout, so one corrupt file cannot hang the run), build the prompt, generate, decide, bump `LifetimeStats`, and commit note + marker atomically. Extraction failures and generate failures are told apart: only a generate failure counts toward the GPU-wedge reload; an extraction failure just means the file is bad.
6. Each SOURCE gets a **60-minute wall-clock budget** across all its buckets; on overrun the run moves to the next source (progress is per-item atomic, so it simply resumes next run).
7. Unload the engine, run the end-of-run health checks (parse-failure spike, rolling extraction rate), and send the `Processing.completed` analytics signal (counts only).

`RunProgress` is the snapshot the UI reads: totals, verdict counts, and the last item's title / summary /
verdict / prompt, all describing the same item so a UI never shows a mismatched pair.

## Modes at the entry points

- Home Analyze Now, onboarding's first analysis, the 3 AM run: `.auto`.
- Dev Tools "start / resume (top → bottom)": `.auto`; "start on device (bottom → top)": `.iterative`; "Reset everything" then a run: a fresh first run everywhere.
- The Gmail and Calendar legs are not connectors; `ProcessingView` and the scheduler run them after the on-device leg, and they land in the same `CycleStore` (see the cloud sources doc).

## The cycle

On-device read (this folder) → the shared tail `ProactiveCycle` (knowledge base → mirror → gift →
proactive → wipe the summaries). Summaries are disposable on purpose: "tell the cloud" always sends
whatever exists, with no "which are new?" bookkeeping. Only the per-bucket marks persist. A failed tail
keeps the summaries so the next cycle retries.

## FactoryReset

`FactoryReset.run(appState:)`: wipes the cycle store, deletes the knowledge base folder, clears the
proactive traces (`ProactiveCycle.resetAll`), the lifetime counters, and the cloud copy (best-effort;
an offline reset still succeeds and the mirror's 30-day lease is the backstop). Then it rewinds to the
start of onboarding: clears the onboarding step and flag, the plan-mode flags (`plan.kbOnly`,
`plan.assertedPlus`), the permission-gate "offered" flags, the computer-use health latch, and the
scheduler's first-cycle / auto-enable / production-enabled state, and stops the scheduler loop. It also clears MCP connector state while preserving `mcp.mirror.*`. After the live onboarding rewind, `ComputerUseUpgrade.reset()` removes pending migration state, releases hidden windows, removes enforcement observers, and invalidates late installer results without cancelling the shared download.

Deliberately kept: the mirror password and opt-in (the share URL pasted into the user's AIs must
survive; the next push recreates the copy), the source selections, the frontier-model choice, and the
installed wake helper. Uninstall (`System/Uninstall.swift`) is the strict superset that removes those too.

## Rules

- All pointer logic lives in `IterativeRun`, never in a connector.
- Never split the note write from the marker write; every new commit path must go through `CycleStore`'s atomic helpers.
- Never log a full bucket key; log `CycleStore.scheme(key)`.
- The 60-minute per-source cap and the 40-item preemptive reload are tuned values; change them with evidence.

## Related docs

`Engine/Documentation - On-Device Engine & Triage.md`, `Sources/Documentation - Sources - Local (Files, WhatsApp, iMessage, Notes).md`, `Sources/Documentation - Sources - Cloud (Gmail, Calendar).md`, `Proactive/Documentation - Proactive Intelligence.md` (the cycle tail), `Views/Documentation - Views - Home, Processing & Shared UI.md` (`ProcessingView`).
