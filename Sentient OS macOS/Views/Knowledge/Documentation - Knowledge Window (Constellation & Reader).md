# The Knowledge Window (Views/Knowledge/): Constellation View, reader, editor

The **Knowledge** window (windowID `knowledge`; the home's Knowledge door and the onboarding finale
open it) shows the user their own knowledge base at `~/Sentient OS - Knowledge Base/`. Two faces over
the same folder:

- **The Constellation View, the default face.** The knowledge base as a living night sky: every note a star (sized by wikilink degree, twinkling on a stable per-note phase), every resolved `[[wikilink]]` a thread, top-level folders as hue-tinted labeled constellations, and the root README as the sun (the notch's `SpinningLogo`, slow, floating on the pinned center). The assembly entrance (stars glide in from beyond the rim and settle) replays on every window open; within a session the sky keeps its camera and positions across reader trips.
- **The reader:** an Obsidian-style split view: a folder-tree sidebar and rendered markdown, with editing, creation, and deletion.

Native toolbar buttons (`SkyDoor`, wearing a muted moving gradient rim so the other face is
discoverable) swap between them; ⌘⇧G either way; Esc leaves the sky. Clicking a star opens that note in
the reader; Back walks the wikilink trail, and one more Back returns to the sky with that star glowing
for a beat.

## Knowledge you can inspect and keep

These views show ordinary Markdown files, so the user can understand what Sentient knows, correct
a detail, add context or use a preferred editor. The graph is another view of the same notes, not a
separate hidden memory store. Local storage and chosen-model inference are separate: a hosted
frontier model can process notes to organize knowledge or carry out a task even when MCP sharing is off.

The root `writingstyle.md` support file is excluded from the tree, search and graph. Its one-time
writing examples remain editable through **Settings → Double Tap → Show writing examples in Finder**.
They are included in Double Tap requests and in the folder if optional MCP sharing is enabled.

## Files

| File | Job |
|---|---|
| `KnowledgeView.swift` | The window: the mode switch, the split view, navigation and the back trail, the editor, create / delete, the unsaved-edits guard, the sidebar's sync status line. |
| `VaultTree.swift` | Data: scans the folder into a `VaultNode` tree (folders including empty ones, `.md` notes, dotfiles skipped, README pinned out as "Overview"), builds the title index (lowercased filename stem → URL, the wikilink AND graph-edge resolver), and reads a note (strips YAML frontmatter, promotes the first `# H1` to the title). |
| `MarkdownView.swift` | A hand-rolled block renderer for the vault's small verified subset (`#`/`##`/`###`, paragraphs, `- ` bullets, `---`, fenced code and box-drawing trees, inline bold / italic / code / links); `[[wikilinks]]` render as sky-blue links over a custom `sentient-wiki:` URL scheme (unresolved ones dim and inert). |
| `Graph/SkyGraph.swift` | Nodes and edges in one pass over the vault: body wikilinks resolved through the title index (`[[X|alias]]` and `[[X#heading]]` handled), domains = top-level folders biggest-first (stable palette), hover-preview lines, and "changed in the last 36 h" flags with a bulk-change guard (a full rebuild must not shimmer the whole sky). Plus a seeded mock graph for previews. |
| `Graph/SkySimulation.swift` | The physics: spring threads, pairwise repulsion, per-constellation ring anchors, a pinned root, a cooling alpha (the entrance), heavy damping and a terminal-velocity cap (stars glide, never boing). Dragging a star reheats its neighborhood. |
| `Graph/NightSkyModel.swift` | The brain: the graph + simulation + camera, advanced once per frame from the Canvas closure (no per-frame published writes), hit-testing, hover / focus / highlight blends, photon pulses, pan and zoom-at-cursor, star dragging, and `load()` (a rebuild restores positions by URL so re-entering never replays the entrance). |
| `Graph/SkyRenderer.swift` | All Canvas drawing, painter's order: parallax stardust → constellation watermarks → the center breath → threads (resting ones batched into two paths; the hovered star's ignite) → photon pulses (a synapse firing every ~5 to 8 s) → stars → titles (zoom-gated, collision-aware: a label that would overlap another or the hover card is not drawn). No per-frame blur filters; every glow is a layered gradient. |
| `Graph/NightSkyView.swift` | `TimelineView` + `Canvas`, the AppKit event catcher (two-finger scroll pans, pinch / wheel / ⌘-scroll zoom at cursor, star drag, hover, still-click opens, Esc exits), the sun overlay, the hover card, HUD whispers, the empty state, `SkyDoor`. |

## The reader and editor

Sidebar: a pinned "Overview" (the README), search, disclosure folders (a clipped accordion over a
plain `VStack`, deliberately not `LazyVStack`), a header "+" and a folder-hover "+" and right-click menus
for New note / New folder / Move to Trash. Reader: the rendered note with wikilink navigation, and a
toolbar of Edit, Move to Trash (hidden for the Overview), and Reveal in Finder.

- **Code and tree blocks:** fenced code and adjacent box-drawing tree rows render verbatim in monospace, preserving indentation. Fence delimiters are omitted; an unterminated fence still displays its body. Ordinary prose keeps the existing inline markdown and wikilink behavior.
- **Editing:** Edit opens the RAW file (frontmatter included) in a `TextEditor`; Save writes atomically and re-renders. Navigating away with unsaved edits (a sidebar click, a wikilink, Back, or a mode switch) raises Save / Discard / Cancel; nothing is ever silently dropped. `VaultActivity.editorBusy` is set while editing, so the nightly updater skips a cycle rather than race the user.
- **Create / delete:** new notes are seeded `# Title` and open straight into edit; names are sanitized and uniqued. Delete moves notes AND folders to the macOS Trash (recoverable, no confirm). The create prompt is a system alert whose initial key view lands on the button row on macOS 26, so the field's focus is claimed a beat after presentation.
- **Cloud sync:** every save, create, or delete calls `VaultActivity.markChanged()`, which sets the persisted dirty flag and schedules ONE mirror push 30 s after the last change (the timer survives closing the window; a quit mid-debounce is caught by the launch catch-up). The sidebar header shows the state when the mirror is on: a calm white dot (never colored) plus "Synced to Cloud MCP / Will sync soon / Syncing…" with an "Encrypted" tag; mirror off shows "Saved locally on this Mac". A concurrent nightly merge is protected by the updater's swap-time freshness check.

## The Constellation View mechanics

`NightSkyModel.tick(now:size:)` runs inside the Canvas closure every frame: it steps the simulation,
eases the per-star ignite blends (the hovered star, its neighbors at 0.75, the return-from-reader
highlight decaying over ~2.6 s), dims the rest while a hover is up, and schedules photon pulses only
once the sky is calm. Camera math (`toScreen` / `toWorld`), the forgiving hit-test reach, pan clamping,
and Figma-style zoom-at-cursor live there too. The hover card's frame is one source of truth shared by
the SwiftUI overlay and the renderer, so labels never slide under it. `SkyTuning`'s force constants are
a balanced set (scaled together to calm the motion without moving the equilibrium); scale them together
or the composition changes.

## Design notes: the "Starlight" scheme

OLED-black reading pane against a moonlit-slate sidebar (`Theme.panel`, a cool graphite; the earlier
warm/amber identity read as a borrowed brand hue). Color means "alive / tappable": `Theme.knowledgeAccent`
(starlight periwinkle #8ea6ff) for selection and interactive chrome, `Theme.knowledgeLink` (a solid,
minimalist sky blue #6fb6ff, no gradients) for wikilinks, `Theme.dawnCyan` for the sky's "changed last
night" shimmer; bullets and everything non-interactive are neutral ink. Serif is the face of note names
only (the reader's title and headings, hover-card titles, star labels); all chrome speaks the SF display
voice. `WindowChrome` forces the transparent title bar at launch.

## Rules

- All navigation funnels through the unsaved-edits guard.
- No per-frame `@Published` / `@State` writes in the sky; no per-frame blur.
- Never resolve wikilinks or build edges from anything but `KnowledgeVault.titleIndex`.

## Related docs

`Vault/Documentation - Knowledge Base (Vault).md` (what writes the folder), `Cloud/Documentation - Cloud - MCP Mirror.md`, `Notch Magic/Documentation - Sidekick - Notch Window & Visual.md` (`SpinningLogo`), `Views/Documentation - Views - Home, Processing & Shared UI.md` (`Theme`, `Orb` performance rules).
