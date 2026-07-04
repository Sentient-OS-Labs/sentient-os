# The Home — Proactive Intelligence ("For You")

**The app opens straight into this.** Proactive Intelligence *is* the product, so it's the main
window — not a hub you route through. A scatter of **suggestion cards** (things the AI already did
the work for) sits over OLED black, with a command bar at the foot ("Let me DO stuff for you").
Everything else (Knowledge, Settings, status) is a quiet door at the top-right.

*(Replaces the retired Constellation home — its orb, source chips, Your-AIs glance and knowledge-base
stats were reused in this surface and its popovers. Arch §10.)*

## The surface — `Views/HomeView.swift`

The main window's content (rendered by `RootView`). Layers, bottom-to-top:

- **Chrome (on top, so the nav stays clickable):** a slim top bar — `OrbMark` + "Sentient OS"
  wordmark on the left; on the right four **doors** — `Analysis ▾` and `Connect AIs ▾` (popovers) ·
  `Knowledge` and `⚙ Settings` (their own windows). Below it, the editorial voice: an hour-aware
  serif-italic greeting ("Good evening, Jesai." — the name from the macOS account, `macFirstName`)
  over a mono-caps read-line (the REAL lifetime count from `LifetimeStats`).
- **The scatter:** the suggestion cards, dealt in from above the header with staggered springs into
  organic per-count slots in the **card zone** (the band between the chrome and the dock —
  `slots(count:in:)`, layouts defined up to 6 cards). Each card can be fired, flick-dismissed with
  drag physics, or tapped to expand into a full typeset letter.
- **The empty state — the orb's ONE home:** when there are no cards, the living **`Orb`** rises into
  the center with *"I'm here to help."* The orb appears **only** here (plus the ProcessingView
  takeover); Settings and Connect use the static `OrbMark` glyph instead.
- **The dock:** the `PromptBar` command bar + the trust footer. A small `DEV TOOLS` handle is pinned
  bottom-right (→ the `Views/Dev/DevToolsView.swift` sheet; the Release strip re-hides it).
- **The letter layer:** an always-mounted overlay (opacity/scale-driven — view *insertion* can miss a
  redraw on hidden-titlebar windows) that expands a card into the typeset reading view, with the
  **editable draft block** for real cards (below).

`RootView` feeds the home its live context (`thingsUnderstood`, the armed `sources`, custom roots,
`modelMissing`, the `realCards` flag, and the `onAnalyze`/`onShowDevTools` callbacks) and owns the
HomeView ⟷ ProcessingView cross-fade. **Analyze Now runs the shared `SourceSelection` picks through
`ProcessingView` `.auto`** — with real cards ON it's the FULL cycle (read → `ProactiveCycle`: KB →
mirror → gift → proactive → wipe), byte-for-byte what the 3am scheduler runs.

## Real cards vs the demo deck — `ForYouModel`

The home has two modes, flipped by the dev "REAL FOR-YOU CARDS" toggle (`dev.proactive.realCards`,
ON by default):

- **Real mode (the default):** `beginVisit` builds the deck from the persisted proactive results — the
  welcome **`GiftLetter`** envelope first (sealed, wax-stamped; generated once from the user's own
  knowledge base), then one card per `PreparedAction` in `ProactiveResearch.latest()`
  (`Briefing(from:)` — method accent + `METHOD · TARGET` kicker, the `card_summary` body, the
  LLM-written fire button). **Firing is real:** `runReal` routes through
  `ProactiveExecutor.fire`, streams codex's live play-by-play into the card (`liveLines`, with a
  per-card **STOP** that terminates the codex process), flies the card away on success and removes it
  from the persisted set; a failure returns it to the offer state for edit + retry. **Drafts are
  editable:** the letter view's draft block is a `TextEditor` for real cards — Save persists the edit
  into `preparedContent` (both in-memory and in `ProactiveResearch.latest()`), so what the user edited
  is verbatim what fires.
- **Demo mode (toggle OFF — pitch mode):** the hard-coded investor showcase deck
  (`Briefing.demo` — Charles/EWOR · Anthos · AIM · SSN prep · Supabase · the welcome letter), playing
  the scripted `workLog` theater. Parked/alternate cards live commented at the bottom of
  `Briefing.swift` as a swap-in library.

## The nav popovers — `Views/HomePopovers.swift`

Status lives here, never cluttering the home:

- **`AnalysisPopover`** — the work glance: things understood, the real on-disk knowledge-base counts
  (`HomeStats.countVault`), the synced stamp (real mode: the actual `ProactiveCycle.lastCycleKey`
  time), **Analyze Now**, and the **source chips** — live on the SAME `SourceSelection` keys as
  Settings/Dev Tools (folder chips toggle; WhatsApp/iMessage open the shared `ChatPicker`;
  Gmail/Calendar open their connect sheets; the WhatsApp chip hides when it isn't installed).
- **`YourAIsPopover`** — the real MCP mirror control: an ON/OFF pill wired to `MirrorClient`
  (enable + push / disable), live `stats()` ("Read 5 notes today"), Copy Link + Copy Prompt, and the
  glowing **Connect your AIs** CTA when off.

## The cards — `Briefing.swift` · `BriefingCard.swift`

`Briefing` = the suggestion-card model (kicker / serif title / preview body / full `letter` /
`draft` + `draftLabel` / `detailLabel` / the `offer` verb / `workLog` theater / done state / accent).
Built three ways: `init(from: PreparedAction)` (real cards — method-signature accents: gmail ember ·
calendar cobalt · computer teal · research mint), `init(fromGiftMarkdown:)` (the welcome letter — its
`# Title` promoted to the card title), or the hard-coded demo set (kind accents; the welcome card
alone wears the full gradient — jewelry rule). The card lives four lives: `sealed` (the envelope) →
`offer` → `working(n)` (scripted theater, or the real `liveLines` stream + STOP) → `done`.

## The command bar — "Let me DO stuff for you"

`PromptBar` has a single mode — **Computer use**. `onSend` routes through
`appState.commandCoordinator.submit(_:mode:source: .promptBar)` — the SAME shared run
(`CommandRunModel` → `CodexCLI.runAgentCommand`) the right-⌘ Sidekick hotkey drives, so the bar and
the notch are two views of one run: while running, the bar shows the cleaned codex `statusLine` with
a STOP button, and the notch glows alongside. (Doc: `Notch Magic/Notch Magic.md`.)

## The other windows

- **`Views/Settings/SettingsView.swift`** (`windowID "settings"`, the gear) — the real two-pane
  Settings: five live panes. Doc: `Settings.md`.
- **`Views/Knowledge/KnowledgeView.swift`** (`windowID "knowledge"`) — the real Obsidian-style
  reader/editor/manager over the vault. Doc: `Knowledge Viewer.md`.
- **`Views/ConnectAIsView.swift`** (`windowID "connect-ais"`) — the REAL two-step guided setup
  (copy the masked MCP link → copy the system prompt → "ask it: what do you know about me?").
- **`Views/Dev/ProactiveExecuteView.swift`** + **`Views/Dev/OvernightDevView.swift`** — dev windows
  (PART 3 fire bench · the overnight cockpit), opened from DEV TOOLS.

## Still demo / future

Scrubbing the demo deck before the repo goes public (it carries real investor names) · the demo
access-log/pending strings in the popovers when demo mode is on · the Analysis dot pulsing during a live morning run · the
home ⟷ takeover morph (today a cross-fade) · the richer menu bar.
