# Knowledge Viewer (Constellation View · reader · editor · manager)

The **Knowledge** window — what the home's "Knowledge" nav item opens. Two faces over the real
on-disk vault (`~/Sentient OS - Knowledge Base/`, resolved via `VaultGenerator.vaultRoot`):

- **The Constellation View — the window's DEFAULT face.** The knowledge base as a living
  night-sky graph: every note a star (sized by wikilink degree, twinkling on a stable per-note
  phase), every resolved `[[wikilink]]` a thread, top-level folders as hue-tinted labeled
  constellations, and the root README as the sun — the notch's `SpinningLogo`, slow, floating on
  the pinned center. The assembly entrance (stars glide in from beyond the rim and settle)
  replays on every window open; within a session the sky keeps its camera and star positions
  across reader trips.
- **The reader** — the minimal Obsidian-style split view: folder-tree sidebar + rendered
  markdown.

Glowing **SkyDoor** capsules swap between them — sky: top-center "Reader View" · reader:
top-left "Constellation View" · **⌘⇧G** either way · **Esc** leaves the sky. Clicking a star
opens that note in the reader; **Back** walks the wikilink trail and, when the trip began with a
star click, one more Back returns to the sky with that star glowing amber for a beat
(`cameFromSky`). Mode switches funnel through the same unsaved-edits guard as every other
navigation. *(This window replaced the old `DatabaseView` — that dev job still lives in Dev
Tools via `Views/Dev/SummariesView.swift`.)*

**Files (`Views/Knowledge/`):**
- `VaultTree.swift` — data. Scans the vault into a `VaultNode` tree (folders incl. empty ones,
  `.md` notes; dotfiles skipped; README pinned out as "Overview"), builds `titleIndex`
  (lowercased filename stem → URL — the wikilink resolver AND the graph's edge resolver), and
  `read()` (strips YAML frontmatter, promotes the first `# H1` to title).
- `MarkdownView.swift` — rendering. A hand-rolled block renderer for the vault's small verified
  subset — no markdown dependency. `[[wikilinks]]` render as accent links over a custom
  `sentient-wiki:` URL scheme (unresolved → dimmed, inert).
- `KnowledgeView.swift` — the window (`windowID = "knowledge"`). Owns the mode switch, the
  reader split view, the editor, create/delete, and the sky↔reader navigation loop.
- **`Graph/` — the Constellation View** (each file's top comment carries the deep detail):
  - `SkyGraph.swift` — nodes/edges in one pass over the vault: body `[[wikilinks]]` resolved
    through `titleIndex` (frontmatter is ignored on purpose), domains = top-level folders
    biggest-first (stable palette assignment), hover-preview lines, and "changed in the last
    36h" flags with a bulk-change guard (a full vault rebuild must not shimmer the whole sky).
    Plus the seeded mock graph the previews render.
  - `SkySimulation.swift` — the physics: spring threads, pairwise repulsion, per-constellation
    ring anchors, pinned root, a cooling alpha (the entrance), heavy damping + a
    terminal-velocity cap (stars glide, never boing). ⚠️ `SkyTuning`'s force constants are a
    BALANCED SET — scale them together or the settled composition changes.
  - `NightSkyModel.swift` — the brain: camera (pan / zoom-at-cursor), hit-testing, hover/focus/
    highlight blends, photon-pulse scheduling, and `load()` — rebuilds match star positions by
    URL, so re-entering the sky never replays the entrance.
  - `SkyRenderer.swift` — all Canvas drawing, painter's order: parallax stardust →
    constellation watermarks → the ~11s center breath → threads (resting ones batch into two
    stroked paths; the hovered star's ignite as domain→domain gradients; root-incident threads
    stop at the sun's rim, and a soft black disc under the logo keeps passing threads out of
    its face) → photon pulses (one synapse firing every ~5–8s) → stars → titles. Titles are
    zoom-gated at rest and COLLISION-AWARE always: candidates place greedily by priority
    (hovered star → highlight → busiest), and any label whose measured rect would overlap an
    already-placed label or the hover card simply isn't drawn. ⚠️ No per-frame blur filters —
    Orb.swift's 8-fps lesson; every glow is a layered gradient.
  - `NightSkyView.swift` — TimelineView + Canvas, the AppKit event catcher (two-finger scroll
    pans · pinch / mouse-wheel / ⌘-scroll zoom at cursor · star drag reheats the springs ·
    hover · still-click opens · Esc exits), the `SpinningLogo` sun overlay, the hover card
    (frame shared with the renderer via `hoverCardRect`), HUD whispers + "Private by design."
    footer, and `SkyDoor` — REAL Liquid Glass on macOS 26 (own capsule;
    `sharedBackgroundVisibility(.hidden)` prevents the toolbar's glass-on-glass double wrap;
    the 15 floor gets a dark capsule) with the warm gold→ember→violet edge-flow current.

**Editing:** Edit opens the RAW file (frontmatter included) in a `TextEditor`; Save writes
atomically and refreshes the render. Navigating away with unsaved edits raises Save / Discard /
Cancel (all sidebar clicks, wikilinks, Back, AND sky-mode switches funnel through the guards).
`VaultActivity.editorBusy` is set while editing (the updater-skip seam). Esc cancels.

**Create / delete:** three creation affordances — the header "+", a hover "+" on folder rows,
and right-click menus. New notes are seeded `# Title` and open straight into edit mode; names
are sanitized + uniqued. Delete = **move to macOS Trash** (recoverable, no confirm) for notes
AND folders — the toolbar trash icon (reading mode; hidden for the README/Overview, which can't
be deleted) or right-click. Trashing the folder that contained the open note lands back on
Overview.

**Cloud sync (debounced):** every change (save / create / delete) calls
`VaultActivity.markChanged()` → sets the persisted `vaultDirty`, and ONE mirror push fires **30s
after the last change** — a spree coalesces into a single push. The timer lives in the
`VaultActivity` singleton, so it survives closing the window; a quit mid-debounce is caught by
the on-launch `pushIfDirty()`. The sidebar header shows the state (mirror on): a calm white dot
— **deliberately never colored**, an amber "will sync" read as a warning — + "Synced to Cloud
MCP / Will sync soon / Syncing…" with the inline "🔒 E2E Encrypted" tag; mirror off → "Saved
locally on this Mac". *(E2E Encrypted is surfaced now, implemented later.)* The
concurrent-writer seam is handled by VaultCloud's swap-time freshness check (B11, PR #96).

**Design notes:** OLED-black reading pane vs a warm-tinted sidebar (`Theme.panel`);
`Theme.knowledgeAccent` (amber-orange) for wikilinks/selection/bullets — and the sky's
"changed last night" shimmer + return-highlight, so both faces share the warm identity. The
sidebar disclosure uses a clipped accordion over a plain `VStack` — **not LazyVStack** (it
mangles the transitions). `WindowChrome` forces the transparent titlebar at launch.

**To build later:** folder rename/move · a visible "sync failed" state (today a failed push just
stays pending and auto-retries) · sky ideas parked: remember-last-view, a per-note local graph.
