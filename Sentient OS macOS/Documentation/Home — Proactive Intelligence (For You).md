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
  wordmark on the left; on the right four **doors** — `Analysis ▾` and `Give AIs Knowledge ▾`
  (popovers; the latter renamed from "Connect AIs" 2026-07-13 — users read "connect" as the codex
  plumbing they'd already done) · `Knowledge` and `⚙ Settings` (their own windows; the gear is
  17pt **bold** since 2026-07-12 — user studies showed the old 14pt one got missed). Below it, the editorial voice: an hour-aware
  greeting in the SF display voice (`.display(27)` — "Good evening, Jesai.", the name from the
  macOS account, `macFirstName`) over a mono-caps read-line (the REAL lifetime count from
  `LifetimeStats`). Card titles stay upright serif — serif marks content about the user's life.
- **The scatter:** the suggestion cards, dealt in from above the header with staggered springs into
  organic per-count slots in the **card zone** (the band between the chrome and the dock —
  `slots(count:in:)`, layouts defined up to 6 cards). Each card can be fired, flick-dismissed with
  drag physics, or tapped to expand into a full typeset letter.
- **The empty state — the orb's ONE home:** when there are no cards, the living **`Orb`** rises into
  the center with *"I'm here to help."* The orb appears **only** here (plus the ProcessingView
  takeover); Settings and Connect use the static `OrbMark` glyph instead. The orb's clock is
  focus-aware (`FocusThrottledTimeline` in `Orb.swift`): window focused = the display-link schedule
  (up to 120fps on ProMotion), unfocused = a fixed timer hard-locked to 60fps (halo 30) — so a
  background window (overnight runs especially) never burns 120Hz frames. Full performance rules
  live in `Orb.swift`'s header comment.
- **Knowledge-base-only mode (free/go plans, `CodexAuth.knowledgeBaseOnly`):** cards never come, so
  the empty state is replaced by the ALWAYS-mounted **preview note** — orb + "This is a preview of
  Sentient." + the three feature rows + the *Get ChatGPT Plus* glow CTA + a *Reset Sentient…*
  `QuietPillButton` (deep-links to Settings → System via `SettingsView.requestedPane`). The gift
  envelope (the only card this home can hold) perches at a fixed top-center slot ABOVE a compact
  version of the note; flinging the letter blooms the note into the full center. Once the plan claim
  reads Plus (re-decoded every appearance), the note becomes *"You're on Plus. Time to go live."*
  with a *Reset & Rebuild* glow. See `Plan Gate (CodexAuth & Knowledge-Base-Only).md`.
- **The dock:** the `PromptBar` command bar + the trust footer — just "Private by design." here
  since 2026-07-13; the full "Your files never leave this Mac." line is reserved for the surfaces
  where files are the message (the command bar is HIDDEN in
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
    the three knowable reasons (codex signed out · no internet · usage limit — classified by
    `OvernightCaution.classify` at `ProactiveCycle`'s catch sites, persisted on scheduled runs
    only; a watched run shows the same kind live on the takeover's failed screen instead): amber
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
cloud tail (redesigned 2026-07-12) the takeover is the living orb (`Orb(mode: .processing)`) over
the phase line in the display voice, plus codex's own reasoning as a fading three-line mono trail
under a "THINKING" whisper (`ProcessingView.liveThought`, fed by `ProactiveCycle`'s `onLine` hook —
shell `$ ` lines and structured JSON output filtered as noise, thoughts promoted at a 1.4s cadence,
newest brightest at the bottom, cleared per phase), and the footer sets expectations in the three
voices: a mono-caps whisper with the ~15-minute estimate (the 10-minute flip lives there), the
keep-Sentient-open/lid-up instruction with a MacBook glyph in the display voice, and the quiet
"Just this once" reassurance that 3am runs wake a lid-shut, plugged-in Mac on their own.
**The failed screen speaks the classified failure** (2026-07-12): `ProactiveCycle`
returns a `CycleFailure` (message + `OvernightCaution.Kind?`), and `ProcessingView.failedView`
renders the kind — "Codex isn't logged in" gets a prominent **Log in to Codex** button (the shared
`CodexSetup.startLogin` browser flow; a 1.5s `codex login status` poll auto-notices the finished
sign-in and auto-retries the cycle, same pattern as Settings → Health), usage-limit and no-internet
get honest progress-is-saved one-liners, and unclassified failures show the step's raw message with
plain Back/Retry. Retry is honest in every case: `CodexCLI.validate` never caches a failed probe
(see the CodexCLI doc), so a fixed codex is seen on the very next attempt. `RootView` also owns
**the onboarding finale**: when the first analysis finishes, onboarding dissolves into the home and
the Knowledge window (the Constellation) opens ON TOP a beat later — every user's first sight of
their knowledge base, whatever their plan. ProcessingView's "Analysis complete" screen
**auto-advances after 5s** (the Done button stays as a skip; a cancellation check stops a manual
Done from double-firing the finale) — so someone who left the first run going overnight wakes up
to the Constellation + cards, never a stale complete screen. Dev runs (`showPrompt`) keep the
manual Done so final counts can be inspected. **Demo toggle** (Dev Tools → "Resizable analysis
window for demo", key `ProcessingView.resizableDemoKey`): while ON, the home's takeover drops
RootView's 1040×800 min frame (the window shrinks to the content's own floor — resizes freely for
the website's screen rec) and hides the Stop Analysis button + caption; home runs only — onboarding
keeps Pause, dev runs keep Stop, and the min frame snaps back when the takeover ends.
`RootView` also mounts the screen-agnostic
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
  LLM-written fire button; the `variant` = the card's order among its method-mates, driving the
  accent-family shade below), with the welcome **`GiftLetter`** envelope riding LAST (the
  bottom-right scatter perch; sealed, wax-stamped, addressed "For \<macFirstName\>" from
  the macOS account — "For you" when nameless; generated once from the user's own
  knowledge base, and retired when the NEXT full cycle replaces the deck — its letter footer carries
  the **Save to Desktop** keepsake, a branded share PNG revealed in Finder; see
  `Proactive Intelligence (Judge).md` §The welcome gift). **Firing is real:** `runReal` routes through
  `ProactiveExecutor.fire`, streams codex's live play-by-play into the card (`liveLines`, with a
  per-card **STOP** that terminates the codex process), flies the card away on success and removes it
  from the persisted set; a failure returns it to the offer state for edit + retry. **Drafts are
  editable, auto-saved:** every edit in the letter view's draft block (body, To:, Subject) commits on
  a 300ms debounce into `preparedContent`/`recipient` (both in-memory and in
  `ProactiveResearch.latest()`), so what the user edited is verbatim what fires — no Save button.
  The block's corner status walks the edit story: **✎ Editable** (fresh card — the affordance) →
  **Saving…** (typing) → **✓ Saved** (green, only after a real edit, so the word means something).
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
- **`ShareKnowledgePopover`** (renamed from `YourAIsPopover` with the door, 2026-07-13) — the MCP
  door, deliberately control-free: the mono-caps "Give AIs Knowledge" header, the pitch ("Offer
  your knowledge base to your ChatGPT or Claude."), the glowing **Set up in 2 minutes** CTA that
  opens the guided `ConnectAIsView` (which owns sharing on/off, the link, and the prompt), and the
  "Private · over MCP · two simple steps" whisper.

## The cards — `Briefing.swift` · `BriefingCard.swift`

`Briefing` = the suggestion-card model (kicker / serif title / preview body / full `letter` /
`draft` + `draftLabel` / `detailLabel` / the `offer` verb / `workLog` theater / done state / accent /
`isPlan`). Built three ways: `init(from: PreparedAction, variant:)` (real cards),
`init(fromGiftMarkdown:)` (the welcome letter — its `# Title` promoted to the card title), or the
hard-coded demo set (kind accents; the welcome card alone wears the full gradient — jewelry rule).

**Accents are color FAMILIES, not single colors (2026-07-14).** Real decks often cluster on one
method (five computer-use cards is a normal morning), and one shade repeated five times reads
bland. `Briefing.accentColor(for:variant:)` keeps one family per method and cycles its shades by
the card's order among method-mates (`variant`, counted in `beginVisit`) — neighbors always differ,
the family still names the method at a glance: **computer** = five greens (teal · leaf · seafoam ·
emerald · pistachio — a full deck of 5 gets five different greens) · **gmail** = three reds (ember
· coral · raspberry) · **research** = three blues (sky · periwinkle — the Knowledge window's
Starlight kin · azure) · **calendar** = lone cobalt (the rare card). Kickers: gmail reads
**GMAIL MCP** (2026-07-14).

The card lives four lives: `sealed` (the envelope) →
`offer` → `working(n)` (scripted theater, or the real `liveLines` stream + STOP) → `done`.
In the **offer** phase the WHOLE face is the tap target for the letter (not just "read more") — the
fire CTA and "read more" buttons sit above the ancestor tap in hit-testing, so they keep their own
actions; working/done faces don't tap-expand (a stray click mid-run shouldn't cover the STOP).

### The expanded letter — `LetterView` (in `HomeView.swift`) · `LetterBody.swift`

Every card expands into the typeset reading view. `LetterBody` (shared with the gift's share PNG)
renders the letters' **light Markdown** line-by-line: `## ` mono-caps section whispers · `### `
serif subheads · bullets (`✦ `/`- `/`* `/`• `) · `1.` numbered items · `---` hairline rules ·
`**bold**` inline · a `--` sign-off line. Research notes render it `neutral` (the house `•` bullet
+ dim headings — accent-colored reading text was unpleasant over a whole brief); the gift keeps the
✦ accent dress. PART 2's prompt teaches the model this subset for research briefings only.

**A research note dresses as letter paper** (`Views/LetterPaper.swift`): the page's top-right
corner is dog-eared — an insettable cut-corner page shape (so the accent `strokeBorder` traces the
crease) plus the lit fold flap lying on the page — with an accent letterhead hairline under the
title (the ✕ nudges left, clear of the fold). Other cards keep the plain rounded card.

**The draft block is a real composer.** An editable **To:** row (the executor sends to exactly it) ·
a **Subject** row for drafts that open with a `Subject:` line (split out for display; edits
recombine into the one verbatim string, so the artifact that fires never forks) · the body — plain
prose for messages/emails, or **`Views/PlanEditor.swift`** for computer-use plans (`isPlan` =
computer + no recipient): an NSTextView bridge with the real system mono, step numbers restyled in
quiet grey on every keystroke, airy leading, and smart quote/dash substitution OFF so codex gets
literal text. ⚠️ SwiftUI's `TextEditor` can't style ranges and silently falls back to **Courier**
for `.system(design: .monospaced)` — that's why the bridge exists. Chat sends keep the composer
(label "Draft message"); plans are labeled "What I'll do".

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
- **`Views/ConnectAIsView.swift`** (`windowID "connect-ais"`) — the guided setup: per-AI tabs
  (ChatGPT's three video steps · Claude's two · a text-only Other AIs) with bundled looping
  tutorial clips, deep-link pills into each AI's own settings screens, the masked MCP link +
  the system prompt to copy, and the sharing lifecycle itself (glow connect CTA when off; a
  quiet MCP ON/OFF pill behind the confirm when on) — closing with "ask it: what do you know
  about me?". Doc: the window section in `MCP Mirror Client.md`.
- **`Views/Dev/ProactiveExecuteView.swift`** + **`Views/Dev/OvernightDevView.swift`** — dev windows
  (PART 3 fire bench · the overnight cockpit), opened from DEV TOOLS.

## Still demo / future

Scrubbing the demo deck before the repo goes public (it carries real investor names) · the demo
access-log/pending strings in the popovers when demo mode is on · the Analysis dot pulsing during a live morning run · the
home ⟷ takeover morph (today a cross-fade) · the richer menu bar.
