# Files Source — Skipping & Caps

How `FilesSource.eligibleFiles()` decides what *never* reaches the model. **Three free layers** (no
inference, all from filesystem metadata): **subtree pruning** (whole directories we refuse to walk
into), **per-file rejects** (obvious-noise files dropped by name/size), and **caps** (bounds on what
survives the walk) — plus **walk bounds** that stop a pathological folder tree from stalling the run.
All of it lives in `Sources/FilesSource.swift`; a skipped item never becomes a `Candidate` and never
sees inference. `FilesConnector` wraps `eligibleFiles()` into one bucket per root for the iterative
pipeline.

## 1. Subtree pruning — `pruneReason(_:) -> String?`

One directory listing is read per directory; every rule runs against it. First match wins, and on a
match the whole subtree is skipped via `enumerator.skipDescendants()`.

| Rule | Trigger | Example |
|---|---|---|
| noindex | dir name ends `.noindex` | `Cache.noindex` |
| name blocklist | dep/build/cache/dataset names | `node_modules`, `venv`, `dist`, `datasets`, `checkpoints` |
| never-index marker | `.metadata_never_index` present | Spotlight opt-outs |
| **vault exemption** | `.obsidian` or `logseq` present → **never prune** (overrides everything below) | personal vaults — even git-synced, even with a stray `package.json` |
| **`.git`** | `.git` present → prune, period (June 11 — a 38-repo survey found zero notes repos; the ~1% git-synced journals have the escape hatch below) | every cloned/own repo |
| manifest | a known project manifest present | `package.json`, `Cargo.toml`, `Makefile`, `pyproject.toml`… |
| project bundle | any `*.xcodeproj` / `*.sln` entry | Xcode/VS project folders |
| code-density | ≥10 extensioned entries, and **code OR bulk data/markup** is the majority | manifest-less script folders; folders dominated by `.json`/`.html`/`.ipynb`/`.css`/`.xml`/`.yaml` (2026-06-25: data/markup added — these never reach the model anyway, so a folder that's mostly them is a project/dump, not a life) |
| **dataset** | ≥100 files of one extension, ≥90% homogeneous, ≥80% machine-generated names (`chunk_0001`, pure numbers, hashes, UUIDs) | scraped corpora, ML datasets. **Skipped entirely** — no sampling (June 10) |

**Screenshots stay; camera rolls don't.** `isDatasetName` still exempts `Screenshot…`/`IMG_…`/`DSC…`
names from the *folder-level* dataset rule — so a real document sitting in a photo folder is never
lost to an all-or-nothing folder skip. Screenshots are keepers (one can hold a ticket / address /
confirmation). Camera-roll **photos** are removed precisely, one file at a time, by the per-file
reject in §2 — not by pruning the folder.

**The escape hatch (by construction):** `pruneReason` only runs on *subdirectories* — a root the
user explicitly added in Sources is never itself prune-checked. Anyone whose plain git notes repo
gets skipped can add that folder as a custom root and it walks fine.

Hidden dirs and bundle *contents* are already excluded by the enumerator options
(`.skipsHiddenFiles`, `.skipsPackageDescendants`).

## 2. Per-file rejects — `fileRejectReason(name:ext:size:)` (added 2026-06-25)

Content-free: judged from the **name and size only, never by reading the file**. Runs per file after
the extension whitelist. Every reject is one model call saved.

| Reject | Trigger |
|---|---|
| camera roll | image named `IMG_` / `IMG-` / `PXL_` / `DSC*` / `MVIMG` / `PANO` / `GOPR` / `BURST` (phone/camera photos; **screenshots excluded** — they often carry real info) |
| lock/temp | name starts `~$` or `.~` (e.g. Word's `~$Report.docx` — garbage content) |
| boilerplate | basename is `README` / `LICENSE` / `COPYING` / `NOTICE` / `CHANGELOG` / `AUTHORS` / `CONTRIBUTING` / `CODE_OF_CONDUCT` / `EULA`, any extension |
| empty | 0-byte file |
| oversize | over `maxFileBytes` (~100 MB) — the **hang guard**; never even opens a giant file |

Decision (2026-06-25): camera-roll photos add nothing to a *life* knowledge base, so they're dropped
outright (describing random pictures is wasted vision inference). The "blind" semantic categories —
logos, avatars, album art, an NDA's text, a `.txt` log — have no reliable name/size tell and stay
the model's job; we never read a file's contents to classify it.

## 3. Walk bounds (added 2026-06-25)

Stop one pathological folder from stalling the run:

- **Max depth 3** — never descend past 3 subfolder levels (`maxWalkDepth`). Bounds a deeply nested
  downloaded tree.
- **Symlinks skipped** — never followed, so a symlink loop can't make the walk run forever.
- **Per-item extraction timeout** — content extraction is wrapped in a 30 s wall-clock cap in
  `IterativeRun` (`withExtractionTimeout`); a corrupt file abandons instead of hanging. The ~100 MB
  ceiling in §2 is the first-line guard against a giant file; this is the backstop for a
  small-but-corrupt one. (A truly-hung synchronous extractor can't be force-killed — it leaks its
  thread — but it never blocks the pipeline.)

## 4. Caps

Applied newest-first (by date-added) after the walk, in `cappedNewestFirst`:

- **Age cutoff** — Downloads only: files older than **1 year** are dropped (old downloads are noise;
  old Desktop/Documents files can be keepers). `FilesSource.maxAge`.
- **Per-directory cap** — **100, every root** (any one directory contributes at most this many,
  newest win — the blunt backstop for bulk dumps the heuristics miss). `FilesSource.perDirectoryCap`.
  *(Was briefly 300 for Downloads, June 11; back to 100 across the board on 2026-06-25.)*
- **Per-root cap** — newest **1,000** per root, every root. `FilesSource.perRootCap`.

`FileRoot.source` builds the correctly-configured `FilesSource` for each root — use it instead of
constructing `FilesSource` by hand.

## Thresholds are [STARTING POINT]

The density/dataset numbers (10 / majority · 100 / 90% / 80%) and the new walk/size/cap numbers
(depth 3 · 100/dir · ~100 MB · 30 s) were tuned on real runs but are judgment calls. Tune with
evidence, not vibes.

## Self-test

The `SENTIENT_SELFTEST=skipping` (synthetic fixtures, no model) and `skipcensus` (read-only real-Mac
report: every pruned dir + reason, top contributors) modes are scaffolding — deleted when done
(`Self Tests - Temp/` is kept empty). Recreate them from `Documentation/Self-Testing (Eval
Harness).md` whenever you next tune these heuristics; `skipcensus` is the fastest way to see exactly
which folders get pruned and why.

## Historical census (June 11 — predates the 2026-06-25 per-file rejects + 100/dir cap)

Downloads waterfall: 21,364 raw whitelisted files → 5,286 after pruning → 551 after the 1-year cutoff
→ 324 after caps; Desktop 19,216 → 582 → 375. 218 Downloads subtrees pruned (an ML dataset + course
repos); the Documents Obsidian vault fully kept. (Re-run `skipcensus` for current numbers — the
per-file rejects and 100/dir cap now cut further.)
