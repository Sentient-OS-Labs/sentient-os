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
  wordmark on the left; on the right four **doors** — `Analysis ▾` · `Your AIs ▾` (quick popovers)
  · `Knowledge` · `⚙` (their own windows). Below it, the editorial voice: an hour-aware serif-italic
  greeting ("Good evening, Jesai.") over a mono-caps read-line.
- **The scatter:** the suggestion cards, dealt in from above the header with staggered springs into
  organic per-count slots placed in the **card zone** (the band between the chrome and the dock, so
  nothing overlaps either — `slots(count:in:)`). Each card you can fire (the work-log animation
  plays, then it flies off), flick away with drag physics, or tap to expand into a full typeset
  letter. *(Cards + the CodexCLI seam: `Briefing.swift` / `BriefingCard.swift`; engine = `ForYouModel`.)*
- **The empty state — the orb's ONE home:** when there are no cards, the living **`Orb`** rises into
  the center with *"I'm here to help."* (a launchpad, not a dead end — your eye drops straight to the
  command bar). The orb appears **only** here (plus the separate ProcessingView takeover); Settings
  and Connect use the static `OrbMark` glyph instead.
- **The dock:** the `PromptBar` command bar ("Tell me what you want me to DO" · Computer use · send)
  + the trust footer. A small `DEV TOOLS` handle is pinned bottom-right (`devToolsOverlay`
  → the DevToolsView sheet; the Release strip re-hides it).
- **The letter layer:** an always-mounted overlay (opacity/scale-driven — view *insertion* can miss a
  redraw on hidden-titlebar windows) that expands a card into a typeset reading view.

`RootView` feeds the home its live context (`thingsUnderstood`, the armed `sources`,
`analyzeEnabled`/`modelMissing`, and the `onAnalyze`/`onShowDevTools` callbacks). The home owns
`@Environment(\.openWindow)` for Knowledge / Settings / Connect.

## The nav popovers — `Views/HomePopovers.swift`

Status lives here, never cluttering the home — you open them only when curious.

- **`AnalysisPopover`** — the work glance: things understood, the real on-disk knowledge-base size
  (`HomeStats.countVault`), the synced time, an **Analyze Now** control, and the **source chips** (the
  sources are what analysis reads, so they live under "Analysis"). The "Analysis" nav item carries a
  quiet mint status dot (a pulse for the live morning run is ready to wire once the scheduler exists).
- **`YourAIsPopover`** — the access-log glance ("ChatGPT read 5 notes yesterday") + the glowing
  **Connect your AIs** button (`GlowButton`) → opens the Connect window.

Demo strings (synced time, access log, pending) stand in until the real polls land; the knowledge-base
counts ARE real.

## The cards — `Briefing.swift` · `BriefingCard.swift`

`Briefing` = the suggestion-card model (kicker / serif title / preview body / full `letter` / copyable
`draft` / the `offer` verb / `workLog` animation / done state / **`codexPrompt`**). Kind → accent
(meeting cobalt · overdue orange · promise mint · deadline ember · plan orchid · welcome = the full
gradient). The card lives four lives: `sealed` (welcome envelope) → `offer` → `working(n)` → `done`.

**THE CODEX SEAM:** demo execution plays the scripted `workLog`; the **Anthos** card is wired LIVE —
`ForYouModel.run` actually runs `CodexCLI` on its `codexPrompt` (a real Gmail send via `bypassApprovals`)
while the animation plays. ⚠️ **The current six cards are a hard-coded showcase deck** (Anthos · Luis ·
AIM · ZFellows · Fareed · Daniel/EWOR); the welcome "gift" letter is parked as `Briefing.welcomeGift`.
**Wiring the cards to the real proactive actions** (`ProactiveResearch`'s prepared actions — `card_summary`
+ `prepared_content` + a fire button on the `execution_recipe`), plus streaming each action's progress
back to its card with a STOP button, is the next step.

## The command bar — "Let me DO stuff for you"

`PromptBar` has a single mode — **Computer use** — shown as a one-option segmented control (Browser
use was removed). `onSend(text, mode)` is wired live: `HomeView` builds "Using computer use, <task>…"
and runs it through `CodexCLI.runAgentCommand`, streaming codex's play-by-play back into the bar with
a STOP button. (Computer use is the WIP Codex-CLI path.)

## The other windows

- **`Views/Settings/SettingsView.swift`** (`windowID "settings"`, the gear) — the REAL two-pane
  Settings window: five live panes (Knowledge Sources · Proactive & Sidekick · Your AIs · System ·
  Permissions & Health). Doc: `Documentation/Settings.md`.
- **`Views/ConnectAIsView.swift`** (`windowID "connect-ais"`) — the deferred setup guide (stub): the
  real two-step flow (copy your MCP URL → add the line to your AI's instructions) lands later.
- **Knowledge** = the existing `DatabaseView` window (`windowID "knowledge"`) — a reader today; the
  full editor + graph view is to build.

## The switchboard & dev cockpit — `Views/RootView.swift` · `Views/DevToolsView.swift`

`RootView` = `HomeView` (idle) ⟷ `ProcessingView` (the full-screen analyze takeover), today a
cross-fade. It owns the analyze/source state; **Analyze Now** (in the Analysis popover) and the dev
sheet run the same `SourceSelection`. `DevToolsView` is the dev cockpit behind the DEV TOOLS handle (the
Release strip re-hides it). **`SourceSelection`** (top of DevToolsView) is the one shared reader of the
`dbg.run.*` prefs, so both entry points run the exact same picks.

The orb primitive (the living `Orb` + the static `OrbMark`) is documented in `Views/Orb.swift`'s header
— the true-3D ring, Keplerian particles, and the hard-won per-frame performance rules.

## Still demo / future

Real cards from the proactive actions (above) · real access-log + synced time · `Demo.name` from the
knowledge-base portrait · the scheduler's "Analysis pulses during the morning run" wire · the
Connect-your-AIs guided flow · the morph between the home and the ProcessingView takeover.
