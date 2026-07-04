# Knowledge Viewer (reader · editor · manager)

The **Knowledge** window — what the home's "Knowledge" nav item opens. A minimal Obsidian-style
surface over the real on-disk vault (`~/Sentient OS - Knowledge Base/`, resolved via
`VaultGenerator.vaultRoot`). It replaced the old `DatabaseView` (a dev CycleStore-summaries
inspector; that job still lives in Dev Tools via `Views/Dev/SummariesView.swift`).

**Files (`Views/Knowledge/`):**
- `VaultTree.swift` — data. Scans the vault into a `VaultNode` tree (folders incl. empty ones,
  `.md` notes; `.obsidian`/dotfiles skipped; README pinned out as "Overview"), builds
  `titleIndex` (lowercased filename stem → URL — the wikilink resolver, and the edge set a future
  graph view needs), and `read()` (strips YAML frontmatter, promotes the first `# H1` to title).
- `MarkdownView.swift` — rendering. A hand-rolled block renderer for the vault's small verified
  subset (`#/##/###`, paragraphs, `- ` bullets, `---` rules) — no markdown dependency. Inline text
  goes through `AttributedString`; `[[wikilinks]]` are pre-split and rendered as accent links over
  a custom `sentient-wiki:` URL scheme (unresolved → dimmed, inert). `OpenURLAction` routes wiki
  links to navigation and `http(s)` to the browser.
- `KnowledgeView.swift` — the window (`windowID = "knowledge"`). Sidebar (header + search + tree)
  and the reader column; titlebar toolbar = Back (only after a wikilink jump — tree clicks reset
  the trail) · Edit⟷Save · Move to Trash · Reveal in Finder.

**Editing:** Edit opens the RAW file (frontmatter included) in a `TextEditor`; Save writes
atomically and refreshes the render. Navigating away with unsaved edits raises Save / Discard /
Cancel (all sidebar clicks, wikilinks, and Back funnel through guards). `VaultActivity.editorBusy`
is set while editing (the updater-skip seam). Esc cancels.

**Create / delete:** three creation affordances — the header "+" (root), a hover "+" on folder
rows (inside that folder), and right-click menus (folders, notes, empty root space). New notes are
seeded `# Title` and open straight into edit mode; names are sanitized + uniqued (never
overwrite). Delete = **move to macOS Trash** (toolbar trash icon or right-click; recoverable, no
confirm). The README/Overview can't be deleted. Empty folders show in the tree.

**Cloud sync (debounced):** every change (save / create / delete) calls
`VaultActivity.markChanged()` → sets the persisted `vaultDirty`, and ONE mirror push fires **30s
after the last change** (`VaultCloud.pushIfDirty` → `MirrorClient.push`) — a spree coalesces into
a single push. The timer lives in the `VaultActivity` singleton, so it survives closing the
window; a quit mid-debounce is caught by the on-launch `pushIfDirty()` (the dirty flag persists).
The sidebar header shows the state (mirror on): dot + "Synced to Cloud MCP │ 🔒 E2E Encrypted" /
"Will sync soon" / spinner + "Syncing…"; mirror off → "Saved locally on this Mac". *(E2E
Encrypted is surfaced now, implemented later.)* The concurrent-writer seam (an editor save landing
during a KB update) is handled by VaultCloud's swap-time freshness check (B11, PR #96).

**Design notes:** OLED-black reading pane vs a warm-tinted sidebar (`Theme.panel`);
`Theme.knowledgeAccent` (amber-orange) for wikilinks/selection/bullets; sidebar disclosure uses a
clipped accordion (children retract up under the folder line, opacity on an exponential curve) over
a plain `VStack` — **not LazyVStack** (it mangles the transitions). `WindowChrome` forces the
transparent titlebar at launch (otherwise it's grey until the first resize).

**To build later:** the graph view (edges = `titleIndex`) · folder rename/move · a visible
"sync failed" state (today a failed push just stays pending and auto-retries).
