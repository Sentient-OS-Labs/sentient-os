# Pointer Architecture — Kill the Ledger (June 11) + Newest-First Backfill (June 12)

The dedup/incrementality rewrite. The old `LedgerEntry` table (one permanent row per item ever
analyzed, plus tombstones for junk/sensitive) is **gone**. The only question the system ever
asks is *"what's new since last time?"* — so every source keeps **pointers**: "I have processed
everything up to HERE." An incremental run scans past the pointers, processes oldest-first, and
advances each pointer after its item durably saves.

**The payoff:** initial processing and incremental processing are the SAME code path. Pointer
absent → everything, **newest first** (the backfill — see below; connector caps still apply) =
the initial pass. Pointer present → only the new stuff, ascending. And the privacy story got
stronger: junk/sensitive items now leave **zero trace** — judged on-device, discarded, gone
(no tombstones anywhere; `LifetimeStats` keeps only counters).

## The pointers (all rows in `SourceCursor`, key → value)

| Key | Value | Notes |
|---|---|---|
| `file:<FileRoot.id>` | `epochSeconds\|path` | One per folder root. Path = same-second tiebreak. |
| `whatsapp:<jid>` | highest consumed `Z_PK` | **Per chat** (see below). |
| `imessage:<guid>` | highest consumed `ROWID` | **Per chat**. |
| `notes` | `modEpochSeconds\|noteUUID` | Edited note → mod-date passes the pointer → re-summarized. |

⚠️ **Date-valued pointer rule** (learned live): store `timeIntervalSinceReferenceDate` — Date's
NATIVE representation. A Unix-epoch conversion round-trips lossily through Double and the
strict `>` re-matches the newest already-consumed row. (Proactive intelligence's judged-items
pointer hit exactly this; it returns with its own trigger — scaffold in git `67d8078`.)

**Why per-chat keys (a deliberate divergence from the handoff's single Z_PK pointer):** chats
interleave in Z_PK/ROWID space. With one global pointer, saving chat B's window advances the
pointer past chat A's still-unprocessed older messages — a crash there silently loses them.
Per-chat keys make every chat independently crash-safe (same shape as Files' per-root keys).

## The backfill — a key's first run digs newest-first (June 12)

A user watching the first run should see the app understanding what's happening NOW — not
chewing through ancient files first. So a key with **no pointer at all** runs as a **backfill**:
the capped selection is consumed **newest-first**, and the consumed region is the closed
interval **[lo, hi]** instead of "everything ≤ pointer":

- The cursor's value during a backfill is a JSON-encoded **`BackfillCursor`**
  (`{"hi":…,"lo":…,"remaining":n}`, DataSource.swift) in the same `SourceCursor` row — a `{`
  prefix is unambiguous (plain values start with a digit), so Store/Pipeline stay encoding-blind.
- **`hi`** = the newest consumed value (the eventual plain pointer). **`lo`** = the descent
  watermark; every durable save rewrites the full state, so an interrupted backfill resumes
  digging strictly below `lo` — exactly the crash-resume property, mirrored.
- **Items arriving mid-backfill** land above `hi` and are emitted FIRST on later runs
  (ascending, sweeping `hi` up) before the descent resumes — day 2 of an unfinished backfill
  still shows today's life before history.
- **Termination:** `remaining` carries the connector cap as a TOTAL budget across interrupted
  runs (files: 1,000/root · notes: 1,000); the item that spends the last of it writes the plain
  `hi` pointer. Chats are unbudgeted (`remaining` nil) — the rolling 90-day floor ends the dig.
  A dig that comes up empty (aged out, files deleted) completes via `ScanResult.completions`:
  the scan reports "this key is done", and the Pipeline collapses it to the plain `hi` before
  processing. Chat sources never complete on a scan that hit the global 100k cap — an empty dig
  there may be the clip, not the end (`mayBeClipped`, ChatWindowing.chatCandidates).
- Once collapsed, the key behaves exactly as before: plain pointer, ascending, done.

The failure policy mirrors too: during a descent, a permanently-failing item is passed by the
next success BELOW it (its slot lands inside [lo, hi] without a summary) — same
no-poison-pills, no-bookkeeping property as the ascending case.

## The file date

`date = min(max(mtime, dateAdded, movedInAncestorDate), now)`

- `dateAdded` catches downloads carrying old mtimes; `mtime` catches edits.
- `movedInAncestorDate` (each directory's own dateAdded, propagated down during the walk)
  catches **whole folders dragged into a root** — their files keep old dates and would
  otherwise be invisible to the pointer forever.
- The `min(…, now)` clamp keeps a future-dated file (clock weirdness) from poisoning the pointer.

## The shared guards

- **Freshness hold-back (1h, `sourceFreshnessHoldBack`):** items newer than an hour are left
  for the next run — a doc mid-editing-session, an actively-flowing conversation, or a note
  being typed is never summarized between keystrokes. Pointers can't advance past `now − 1h`
  by construction.
- **Ordering contract (`DataSource.scan`):** incremental keys come back ascending; backfilling
  keys come back new-items-first (ascending) then descending below `lo`. The pipeline advances
  each candidate's cursor only after its durable save. Crash = resume, never skip. (Selection
  is always newest-N for the caps; *consumption* direction depends on the key's state.)
- **Junk/sensitive advance the pointer with nothing else saved** — the cursor write IS the
  durable record (`Store.record` does the summary insert + cursor upsert in one transaction).

## Versioned summaries

`Summary.sourceID` is no longer unique — re-analysis INSERTS a new row; our code (not the
model) appends `" — Edit"` to the title when an older version exists. The cloud model benefits
from seeing the evolution; `survivorSummaries()` (full generations) collapses to
latest-per-source. `Summary` also absorbed the ledger's `kind`/`folder` (the vault prompt's
source-trust tiers need them) and gained `itemDate` (the artifact's own date — the proactive
judge keys on it). New rows are born `syncedToVault == nil`, which makes the iterative
updater's queue **self-populating** — nothing to reset, ever.

## Failure policy (no failure bookkeeping, by design)

- An item whose failure triggered a reactive engine reload is **retried once** on the fresh
  engine (the wedge ate its first try; the retry usually lands).
- An item that still fails is given up: its pointer is not advanced *by it*, so it's retried
  next run **only if nothing newer in its pointer key succeeds**. A permanently corrupt file is
  passed by the next success behind it — no poison pills, no retry tables. (Re-processed
  survivors are harmless: they're just another version.)

## Self-tests

- `SENTIENT_SELFTEST=incremental` — the pointer-lifecycle proof, no model (22 checks):
  newest-first backfill → collapse to plain → no-op → new file only → edited file as `— Edit`
  version → corpus stamping → junk advances with zero trace → interrupted backfill (mid-flight
  BackfillCursor, mid-backfill arrivals first, resumed descent, budget collapse) → emptied dig
  completing via the scan's completion report.
- `skipping` (17 checks) still green — fixtures use the `testIgnoreDateAdded` /
  `testZeroHoldBack` seams on `FilesSource` (real filesystems can't backdate dateAdded).
