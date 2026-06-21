# Files Source — Skipping & Caps

How `FilesSource.eligibleFiles()` decides what *never* reaches the model. Two halves: **subtree
pruning** (directories we refuse to walk into) and **caps** (bounds on what survives the walk).
All of it lives in `Sources/FilesSource.swift`; everything here happens at the walk level via
`enumerator.skipDescendants()`, so a skipped item never becomes a `Candidate` and never sees
inference. `FilesConnector` (`Ingestion/Connectors/FilesConnector.swift`) wraps `eligibleFiles()`
into one bucket per root for the iterative pipeline.

## Pruning — `pruneReason(_:) -> String?`

One directory listing is read per directory; every rule runs against it. First match wins:

| Rule | Trigger | Example |
|---|---|---|
| noindex | dir name ends `.noindex` | `Cache.noindex` |
| name blocklist | dep/build/cache/dataset names | `node_modules`, `venv`, `dist`, `datasets`, `checkpoints` |
| never-index marker | `.metadata_never_index` present | Spotlight opt-outs |
| **vault exemption** | `.obsidian` or `logseq` present → **never prune** (overrides everything below) | personal vaults — even git-synced, even with a stray `package.json` |
| **`.git`** | `.git` present → prune, period (decision June 11 — a 38-repo survey found zero notes repos; git notes journals are ~1% and have the escape hatch below) | every cloned/own repo |
| manifest | a known project manifest present | `package.json`, `Cargo.toml`, `Makefile`, `CMakeLists.txt`, `pyproject.toml`… |
| project bundle | any `*.xcodeproj` / `*.sln` entry | Xcode/VS project folders |
| code-density | ≥10 extensioned entries, majority source-code extensions | manifest-less script folders |
| **dataset** | ≥100 files of one extension, ≥90% homogeneous, ≥80% machine-generated names (`chunk_0001`, pure numbers, hashes, UUIDs) | scraped corpora, ML datasets. **Skipped entirely** — no sampling (decision June 10) |

**Screenshots & camera rolls are exempt from the dataset rule** (`Screenshot…`, `IMG_…`, `DSC…`
prefixes): they're personal gold — the per-directory cap bounds their volume instead.

**The escape hatch (by construction):** `pruneReason` only runs on *subdirectories* — a root the
user explicitly added in Sources is never itself prune-checked. Anyone whose plain git notes repo
gets skipped can add that folder as a custom root and it walks fine.

Hidden dirs and bundle *contents* are already excluded by the enumerator options
(`.skipsHiddenFiles`, `.skipsPackageDescendants`).

## Caps (connector-limits decision, June 10)

Applied newest-first (by date-added) after the walk, in `cappedNewestFirst`:

- **Age cutoff** — Downloads only: files older than **1 year** are dropped (old downloads are
  noise; old Desktop/Documents files can be keepers). `FilesSource.maxAge`.
- **Per-directory cap** — **300, every root** (raised from 100 for Downloads, June 11 — downloads
  are high-signal: tickets, receipts, PDFs); any one directory contributes at most that many
  (newest win). The blunt backstop for bulk dumps the heuristics miss. `FilesSource.perDirectoryCap`.
- **Per-root cap** — newest **1,000** per root, every root. `FilesSource.perRootCap`.

`FileRoot.source` builds the correctly-configured `FilesSource` for each root — use it instead of
constructing `FilesSource` by hand.

## Thresholds are [STARTING POINT]

The density/dataset numbers (10 / majority · 100 / 90% / 80%) were tuned on real census runs but
are judgment calls. Tune with evidence, not vibes — that's what the census mode is for.

## Self-test

`Self Tests - Temp/SelfTest_FileSkipping.swift`, no model needed:

```sh
SENTIENT_SELFTEST=skipping   "<app>/Contents/MacOS/Sentient OS"   # synthetic fixtures, 17 assertions
SENTIENT_SELFTEST=skipcensus "<app>/Contents/MacOS/Sentient OS"   # read-only real-Mac report:
                                                                  # every pruned dir + reason, top contributors
```

June 11 census on a dev's Mac (waterfall: 21,364 raw whitelisted files in Downloads → 5,286
after pruning → 551 after the 1-year cutoff → 324 after caps; Desktop 19,216 → 582 → 375):
218 Downloads subtrees pruned (an ML dataset + course repos); Desktop screenshots capped at 300;
the Documents Obsidian vault fully kept.
