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
  greeting in the SF display voice (`.display(27)` — "Good evening, Jesai.", the name from the
  macOS account, `macFirstName`) over a mono-caps read-line (the REAL lifetime count from
  `LifetimeStats`). Card titles stay upright serif — serif marks content about the user's life.
- **The scatter:** the suggestion cards, dealt in from above the header with staggered springs into
  organic per-count slots in the **card zone** (the band between the chrome and the dock —
  `slots(count:in:)`, layouts defined up to 6 cards). Each card can be fired, flick-dismissed with
  drag physics, or tapped to expand into a full typeset letter.
- **The empty state — the orb's ONE home:** when there are no cards, the living **`Orb`** rises into
  the center with *"I'm here to help."* The orb appears **only** here (plus the ProcessingView
  takeover); Settings and Connect use the static `OrbMark` glyph instead.
- **Knowledge-base-only mode (free/go plans, `CodexAuth.knowledgeBaseOnly`):** cards never come, so
  the empty state is replaced by the ALWAYS-mounted **preview note** — orb + "This is a preview of
  Sentient." + the three feature rows + the *Get ChatGPT Plus* glow CTA + a *Reset Sentient…*
  `QuietPillButton` (deep-links to Settings → System via `SettingsView.requestedPane`). The gift
  envelope (the only card this home can hold) perches at a fixed top-center slot ABOVE a compact
  version of the note; flinging the letter blooms the note into the full center. Once the plan claim
  reads Plus (re-decoded every appearance), the note becomes *"You're on Plus. Time to go live."*
  with a *Reset & Rebuild* glow. See `Plan Gate (CodexAuth & Knowledge-Base-Only).md`.
- **The dock:** the `PromptBar` command bar + the trust footer (the command bar is HIDDEN in
  knowledge-base-only mode — computer use runs on quota those plans don't have). A small `DEV TOOLS`
  handle is pinned bottom-right (→ the `Views/Dev/DevToolsView.swift` sheet; `#if DEBUG` — compiled
  out of Release, and it's the sheet's only opener, so Dev Tools is unreachable there).
- **The caution banner — `cautionBanner` / `CautionCapsule` (ONE slot, most severe first):** the
  blank space top-right beside the greeting holds at most ONE capsule; a LIVE issue outranks
  history. Both roads lead to Permissions & Health (`SettingsView.requestedPane = .health`).
  - **The live health ladder (red) — `System/HealthCaution.swift`:** probes CURRENT state on
    appear + every app foreground, rung by rung: ① an essential permission is off (Full Disk
    Access · the overnight wake helper via `WakeHelperClient.isReachable()` — the XPC ground
    truth a file check can't fake, see the scheduler doc · launch at login) → ② codex is gone or
    signed out (`codex login status`, verdict cached ~5 min; cache bypassed while a codex banner
    is up so a fix clears on the next foreground) → ③ computer use REGRESSED — gated on the
    `computerUse.everReady` latch (set by the probe and by `ComputerUseGate` at its moment of
    truth; cleared by FactoryReset), so a user who never set it up is never nagged. Nothing
    persists: broken shows, fixed melts away on the next probe. ✕ mutes an issue KIND for the
    session (lower rungs still surface). Suppressed entirely in knowledge-base-only mode (nothing
    nightly runs there) and on demo decks (no red capsules mid-pitch).
  - **The morning-after caution (amber):** when last night's UNATTENDED 3am run failed for one of
    the three knowable reasons (codex signed out · no internet · usage limit — recorded by
    `Scheduling/OvernightCaution` at `ProactiveCycle`'s catch sites, scheduled runs only): amber
    `HealthDot`, the first-person message, ✕ (clears the record), *Open Settings* on the
    logged-out one. The next fully successful cycle clears it on its own; the foreground refresh
    also re-reads it. Amber on purpose: a caution, never an alarm — only the overnight magic was
    missed.
- **The letter layer:** an always-mounted overlay (opacity/scale-driven — view *insertion* can miss a
  redraw on hidden-titlebar windows) that expands a card into the typeset reading view, with the
  **editable draft block** for real cards (below).

`RootView` feeds the home its live context (`thingsUnderstood`, the armed `sources`, custom roots,
`modelMissing`, the `realCards` flag, and the `onAnalyze`/`onShowDevTools` callbacks) and owns the
HomeView ⟷ ProcessingView cross-fade. **Analyze Now runs the shared `SourceSelection` picks through
`ProcessingView` `.auto`** — with real cards ON it's the FULL cycle (read → `ProactiveCycle`: KB →
mirror → gift → proactive → wipe), byte-for-byte what the 3am scheduler runs. During the cycle's
cloud tail the takeover shows the phase line plus codex's own reasoning as a one-line mono ticker
under a "THINKING" whisper (`ProcessingView.liveThought`, fed by `ProactiveCycle`'s `onLine` hook —
shell `$ ` lines filtered as noise, thoughts promoted at a 1.4s cadence, cleared per phase), and the
footer sets expectations in three lines: the ~15-minute estimate (with the 10-minute warm flip), the
keep-Sentient-open/lid-up instruction, and the reassurance that 3am runs wake a lid-shut, plugged-in
Mac on their own. `RootView` also owns
**the onboarding finale**: when the first analysis finishes, onboarding dissolves into the home and
the Knowledge window (the Constellation) opens ON TOP a beat later — every user's first sight of
their knowledge base, whatever their plan. ProcessingView's "Analysis complete" screen
**auto-advances after 5s** (the Done button stays as a skip; a cancellation check stops a manual
Done from double-firing the finale) — so someone who left the first run going overnight wakes up
to the Constellation + cards, never a stale complete screen. Dev runs (`showPrompt`) keep the
manual Done so final counts can be inspected. `RootView` also mounts the screen-agnostic
**computer-use setup whisper** — a small spinner + "Setting up Codex computer use in the
background." bottom-left, keyed to the live `CodexSetup.settingUpComputerUse` flag, so it rides
onboarding's takeover, the knowledge-base phase, and (rarely) the home for exactly as long as the
bootstrap actually runs.

**First-use permission gate:** a real card's fire and the command bar both pass
`ComputerUseGate.intercept` — while a required action grant is missing, the one-time setup window
holds the action and fires it on Continue. See `Permission Guide (First-Use Grants).md`.

## Real cards vs the demo deck — `ForYouModel`

The deck is the 3-way dev mode `BriefingDeck` (Dev Tools → Proactive Cards…; `dev.proactive.deck`):
`.real` ships as the default (installs whose legacy `dev.proactive.realCards` bool was OFF default
to the jesai deck — those devs were pitching), `.jesai` / `.launch` are the hard-coded demo decks:

- **Real mode (the default):** `beginVisit` builds the deck from the persisted proactive results —
  one card per `PreparedAction` in `ProactiveResearch.latest()`
  (`Briefing(from:)` — method accent + `METHOD · TARGET` kicker, the `card_summary` body, the
  LLM-written fire button), with the welcome **`GiftLetter`** envelope riding LAST (the
  bottom-right scatter perch; sealed, wax-stamped, addressed "For \<macFirstName\>" from
  the macOS account — "For you" when nameless; generated once from the user's own
  knowledge base, and retired when the NEXT full cycle replaces the deck — its letter footer carries
  the **Save to Desktop** keepsake, a branded share PNG revealed in Finder; see
  `Proactive Intelligence (Judge).md` §The welcome gift). **Firing is real:** `runReal` routes through
  `ProactiveExecutor.fire`, streams codex's live play-by-play into the card (`liveLines`, with a
  per-card **STOP** that terminates the codex process), flies the card away on success and removes it
  from the persisted set; a failure returns it to the offer state for edit + retry. **Drafts are
  editable:** the letter view's draft block is a `TextEditor` for real cards — Save persists the edit
  into `preparedContent` (both in-memory and in `ProactiveResearch.latest()`), so what the user edited
  is verbatim what fires.
- **Demo modes (pitch / launch-video):** the hard-coded decks — `Briefing.jesaiDemo` (the investor
  showcase: Charles/EWOR · Anthos · AIM · SSN prep · Supabase · the welcome letter) and
  `Briefing.launchDemo` (the audience-safe launch-video set) — playing the scripted `workLog`
  theater. Parked/alternate cards live commented at the bottom of `Briefing.swift` as a swap-in
  library.
- **Mid-uninstall, the deck is off the table:** `Uninstall.run` raises `AppState.isUninstalling`,
  and the home clears its cards (`ForYouModel.clear()`) and refuses every re-deal while it's up —
  the teardown's `removePersistentDomain` re-publishes EVERY @AppStorage key (the deck's included),
  and without the gate the home dealt a fresh demo deck behind the farewell sheet (field-found
  2026-07-11). A cancelled uninstall deals the deck back in.

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
In the **offer** phase the WHOLE face is the tap target for the letter (not just "read more") — the
fire CTA and "read more" buttons sit above the ancestor tap in hit-testing, so they keep their own
actions; working/done faces don't tap-expand (a stray click mid-run shouldn't cover the STOP).

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
