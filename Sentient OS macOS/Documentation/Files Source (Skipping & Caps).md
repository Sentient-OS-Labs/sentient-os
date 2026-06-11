# Files Source — Skipping & Caps

How `FilesSource.scan()` decides what *never* reaches the model. Two halves: **subtree pruning**
(directories we refuse to walk into) and **caps** (bounds on what survives the walk). All of it
lives in `Sources/FilesSource.swift`; everything here happens at the walk level via
`enumerator.skipDescendants()`, so a skipped item never becomes a Candidate, never hits the
ledger, never sees inference.

## Pruning — `pruneReason(_:) -> String?`

One directory listing is read per directory; every rule runs against it. First match wins:

| Rule | Trigger | Example |
|---|---|---|
| noindex | dir name ends `.noindex` | `Cache.noindex` |
| name blocklist | dep/build/cache/dataset names | `node_modules`, `venv`, `dist`, `datasets`, `checkpoints` |
| never-index marker | `.metadata_never_index` present | Spotlight opt-outs |
| **Obsidian exemption** | `.obsidian` present → **never prune** (overrides everything below) | personal vaults, even with a stray `package.json` |
| manifest | a known project manifest present | `package.json`, `Cargo.toml`, `Makefile`, `CMakeLists.txt`, `pyproject.toml`… |
| project bundle | any `*.xcodeproj` / `*.sln` entry | Xcode/VS project folders |
| code-density | ≥10 extensioned entries, majority source-code extensions | manifest-less script folders |
| `.git` + code | `.git` present AND (any code file OR a classic code dir like `src`/`tests`) | cloned repos. Markdown-only git repos (notes vaults) pass |
| **dataset** | ≥100 files of one extension, ≥90% homogeneous, ≥80% machine-generated names (`chunk_0001`, pure numbers, hashes, UUIDs) | scraped corpora, ML datasets. **Skipped entirely** — no sampling (decision June 10) |

**Screenshots & camera rolls are exempt from the dataset rule** (`Screenshot…`, `IMG_…`, `DSC…`
prefixes): they're personal gold — the per-directory cap bounds their volume instead.

Hidden dirs and bundle *contents* are already excluded by the enumerator options
(`.skipsHiddenFiles`, `.skipsPackageDescendants`).

## Caps (connector-limits decision, June 10)

Applied newest-first (by creation date) after the walk, in `scan()`:

- **Age cutoff** — Downloads only: files older than **1 year** are dropped (old downloads are
  noise; old Desktop/Documents files can be keepers). `FilesSource.maxAge`.
- **Per-directory cap** — **100 for Downloads, 300 for every other root**; any one directory
  contributes at most that many (newest win). The blunt backstop for bulk dumps the heuristics
  miss. `FileRoot.perDirectoryCap`.
- **Per-root cap** — newest **1,000** per root, every root. `FilesSource.perRootCap`.

`FileRoot.source` builds the correctly-configured `FilesSource` for each root — use it instead of
constructing `FilesSource` by hand.

## Thresholds are [STARTING POINT]

The density/dataset numbers (10 / majority · 100 / 90% / 80%) were tuned on real census runs but
are judgment calls. Tune with evidence, not vibes — that's what the census mode is for.

## Self-test

`Self Tests - Temp/SelfTest_FileSkipping.swift`, no model needed:

```sh
SENTIENT_SELFTEST=skipping   "<app>/Contents/MacOS/Sentient OS"   # synthetic fixtures, 16 assertions
SENTIENT_SELFTEST=skipcensus "<app>/Contents/MacOS/Sentient OS"   # read-only real-Mac report:
                                                                  # every pruned dir + reason, top contributors
```

June 10 census on Aryaman's Mac: Downloads 218 subtrees pruned (an ML dataset + course repos)
→ 124 candidates; Desktop screenshots capped at 300; the Documents Obsidian vault fully kept.
