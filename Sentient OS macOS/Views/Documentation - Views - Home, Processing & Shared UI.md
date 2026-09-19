# Views: the home, the processing takeover, and the shared UI (Views/)

The app opens straight into the proactive **"For You" home**: a scatter of suggestion cards over OLED
black, an editorial greeting, the glowing command bar at the foot, and the living orb when there is
nothing to show. This doc covers everything at the top level of `Views/`: the switchboard, the home and
its cards, the popovers, the processing takeover, the connect surfaces, and the shared design pieces.
Subfolders have their own docs (`Settings/`, `Knowledge/`, `Onboarding/`, `Permissions/`, `Dev/`).

Before touching anything here, view `Our_Stuff/Claude_Context/UI_Inspiration/` and its README (the
design bar). In one breath: OLED black as a material; the app speaks SF (`.display()`), the user's life
speaks upright serif (card titles, note names, the letter), the machine whispers mono caps; the AI
gradient glow is jewelry (one or two glowing objects per screen); motion is physics; no em dashes, no
serif italic display, no borrowed brand hues.

## Files

| File | Job |
|---|---|
| `RootView.swift` | The main window's switchboard: onboarding → the home ⟷ the processing takeover. Owns the analyze/source state, the bottom-left whispers, the update-gate overlay, the Dev Tools sheet, and the onboarding finale. |
| `HomeView.swift` | THE home: chrome, the caution banner slot, the card scatter, the empty state, the free-plan preview state, the dock, the expanded letter (`LetterView`), and `ForYouModel` (deal · run · dismiss). |
| `Briefing.swift` | The card model (`Briefing`, `BriefingDeck`), built from a `PreparedAction`, from the gift markdown, or from the two hard-coded demo decks. |
| `BriefingCard.swift` | One card through its four lives (sealed envelope → offer → working → done), `OfferButton`, the envelope. |
| `HomePopovers.swift` | The Analysis popover (things understood, vault counts, Analyze Now, the run footer, the overnight-on-battery switch, source chips) and the Give AIs Knowledge popover. `SourceChip`, `HomeStats`. |
| `PromptBar.swift` | The command bar ("Tell me what you want me to DO"): computer use only; STOP while running. |
| `ProcessingView.swift` | The one analysis takeover, shared by the home, onboarding, and the dev buttons; `RunSource` and `RunSource.connectors(from:)`. |
| `CuaDriverUpdateNotice.swift` | The ordinary computer-use update notice: real download progress, verification, retry, and completion, fed by the shared installer. |
| `CautionCapsule.swift` | The banner capsule (amber / red / green) and the self-contained `UpdateNoticeCapsule`. |
| `LetterBody.swift` · `LetterPaper.swift` · `PlanEditor.swift` · `GiftShareImage.swift` | The letter renderer (the light Markdown subset), the dog-eared page for research notes, the mono step-plan editor, and the gift's Save-to-Desktop poster. |
| `ConnectAIsView.swift` | The guided "Connect your AIs" window (its own scene). |
| `CloudConnectSheet.swift` · `ChatPicker.swift` | The Gmail/Calendar connect sheet and the WhatsApp/iMessage chat picker. |
| `Theme.swift` · `GlowButton.swift` · `Orb.swift` · `GlowProgressBar.swift` · `FileThumbnail.swift` · `ModelDownloadWhisper.swift` · `MenuBarView.swift` · `FrontierEnginePicker.swift` · `CodexSetupView.swift` | Shared design pieces and small surfaces (below). |

## `RootView`

Renders `OnboardingView` until onboarding completes; then either `ProcessingView` (Analyze Now) or the
home, cross-faded. Analyze Now runs the shared `SourceSelection` picks through `ProcessingView` in
`.auto` mode with the Gmail/Calendar flags, and `fullCycle: true` whenever the card deck is `.real` (the
default), so it is byte-for-byte what the 3 AM run does. After a run it calls `maybeAutoEnable()`.
The onboarding finale: when the first analysis finishes, onboarding dissolves into the home and the
Knowledge window (the Constellation) opens on top a beat later. Also mounted here: the bottom-left
whispers (`ModelDownloadWhisper` while the model lands in the background; "Setting up Codex computer
use in the background." while `CodexSetup.settingUpComputerUse`), `UpdateGateView(host: .home)`, and
the `Home.opened` core analytics signal (launch vs reopen). A dev knob (`dev.processing.resizableDemo`)
drops the window's 1040×800 minimum during a takeover for screen recordings.

## The home (`HomeView`)

Layers, bottom to top: the scatter, then either the empty state (the orb with "I'm here to help.", the
orb's ONE home besides the takeover) or the free-plan preview state, the dock (`PromptBar` + "Private by
design."), the chrome (a top bar of quiet doors: Analysis ▾, Knowledge, Give AIs Knowledge ▾, the
Settings gear; below it the hour-aware greeting with the Mac account's first name and the real lifetime
read count), the caution banner slot, the DEBUG-only DEV TOOLS handle, and the always-mounted letter
layer (opacity-driven; view insertion can miss a redraw on hidden-titlebar windows).

**The banner slot** holds at most one capsule, most severe first: a LIVE `HealthCaution` issue (red;
re-probed on appear and every foreground; ✕ mutes the kind for the session), else the morning-after
`OvernightCaution` (amber; ✕ clears the record), else the green just-updated notice. Both roads lead to
Settings → Permissions & Health. Suppressed on the free home and on demo decks.

**Cards.** `ForYouModel.beginVisit(deck:)` builds the deck: in `.real` mode one `Briefing(from:)` per
`PreparedAction` in `ProactiveResearch.latest()` (accent = a shade from the method's color family,
cycled by the card's order among its method-mates, so a morning of five computer-use cards gets five
different greens), with the gift envelope riding LAST (the bottom-right perch); the two demo decks
(`jesai`, `launch`; Dev Tools → Proactive Cards) play scripted theater instead. Cards deal in with
staggered springs into per-count slots in the card zone, can be flick-dismissed with drag physics, and
tap-expand into the letter. **Firing a real card** (`runReal`): pass the first-use permission gate,
adopt Sidekick's shared run for any fireable method (so the notch lights and every other entry point
locks), route through `ProactiveExecutor.fire` with codex's live lines streamed into the card (a per-card
STOP cancels the codex process), fly the card away and remove it from the persisted set on success, or
return it to the offer state for edit and retry on failure. Other fireable cards' CTAs dim while any
task runs. Mid-uninstall the deck is cleared and never re-dealt (the defaults wipe re-publishes every
`@AppStorage` key).

**The letter (`LetterView`).** The expanded reading view: kicker, serif title, `LetterBody`, and for
fireable cards a real composer: an editable **To:** row (the executor sends to exactly it), a
**Subject** row for drafts that open with `Subject:` (split for display, recombined into the one
verbatim string), and the body (`PlanEditor` for computer-use plans, a `TextEditor` for messages and
events). Edits auto-save on a 300 ms debounce into `preparedContent` / `recipient`, both in memory and
in `ProactiveResearch.latest()`, so what the user edited is exactly what fires; the corner status walks
Editable → Saving… → Saved. Research notes dress as letter paper (the dog-eared `LetterPaper`) and render
neutral; the gift keeps its accent dress and carries the **Save to Desktop** keepsake
(`GiftShareImage.save`: a @2x PNG of the letter with a branding colophon, revealed in Finder).

**Free-plan preview state:** the orb over "This is a preview of Sentient." with the three feature rows,
a Get ChatGPT Plus glow, and a Reset Sentient… pill (deep-linking to Settings → System); the gift
envelope perches top-center above a compact version; once the claim reads Plus it becomes "You're on
Plus. Time to go live." with a Reset & Rebuild glow. The command bar is hidden.

The banner slot also carries ordinary CUA updates. Live health issues take precedence, followed by
an active or failed driver update, morning/connector cautions, and completion notices. The driver
notice uses real byte progress when the total is known, an indeterminate bar for preparation and
verification, and Retry after failure. It does not block the home. The legacy Codex-to-CUA migration
remains a separate setup window; see the Driver and Permission Gate docs.

## The cards (`Briefing`, `BriefingCard`)

`Briefing`: kicker (mono caps, `METHOD · TARGET`), serif title, preview body, the full `letter` or the
`draft` + `draftLabel`, `detailLabel`, the `offer` verb (the LLM-written fire button), `workLog` (demo
theater), accent, `isPlan` (a computer task with no recipient renders its draft as the mono step list).
`BriefingDeck` (`dev.proactive.deck`: real / jesai / launch) is the 3-way dev mode; `.real` ships as the
default. `BriefingCard` lives four lives: `sealed` (the wax-sealed envelope addressed to the user's first
name; the flap swings open in 3D) → `offer` (the whole face tap-expands the letter; the fire CTA and
"read more" keep their own actions) → `working(n)` (theater or the live `liveLines` + STOP) → `done`.

## The popovers (`HomePopovers`)

**Analysis:** things understood, the real on-disk vault counts, the Analyze Now button (armed only when
sources are selected and the model is present), Last run / Next run (the Next run line states the real
conditions and rewords itself live when the battery opt-in is on), the quiet "Run on battery too" switch
(writes `scheduler.allowBattery`, the same key the 3 AM gate reads; shown only when sources are armed and
the Mac has a battery, so desktops never see it), and the source chips on the same `dbg.*` keys as
Settings (folder chips toggle; WhatsApp/iMessage open the `ChatPicker`; Gmail/Calendar open the connect
sheet or render locked). **Give AIs Knowledge:** the pitch and the glowing "Set up in 2 minutes" /
"Configure" CTA that opens `ConnectAIsView`; deliberately no controls of its own.

## The command bar (`PromptBar`)

One mode, computer use. Idle: the mode pill, the input with a bright "DO" in the placeholder, the send
button; running: the orb mark + codex's cleaned status line + STOP. `onSend` → `commandCoordinator.submit`
(the same run Sidekick drives), `onStop` → `commandCoordinator.stop()`. Launch focus lands here.

## The processing takeover (`ProcessingView`)

The ONE analysis screen. States: loading the model → processing (a breathing sparkle, "Analyzing
Files / Notes / Messages / …" cycling in gradient, `GlowProgressBar`, kept / junk counts, the "just
processed" card with a QuickLook thumbnail, verdict pills, and a blurred summary for sensitive items) →
preparing (`fullCycle` only: the orb in processing mode over the phase line, codex's live thoughts as a
fading three-line "THINKING" trail promoted at a 1.4 s cadence, and the patience footer: "FIRST RUN ·
ABOUT 15 MINUTES", the keep-Sentient-open-and-lid-up instruction, and the "Just this once" reassurance)
→ completed (auto-advances after 5 s; dev runs keep the manual Done) or failed (the classified failure
with honest copy: "Codex isn't logged in" gets an inline Log in to Codex whose auto-notice poll retries
the cycle by itself; usage limit and no internet get progress-is-saved lines; anything else shows the
step's message with Back / Retry).

The run: one progress stream carries `IterativeRun` then the Gmail and Calendar legs (each window mapped
onto the same bar and card), then `ProactiveCycle.run` when `fullCycle`. A generation token makes a
paused, stopped, or superseded run stale so it can never fire the tail; onboarding's `pausable` mode
freezes in place and, on resume, waits for the old run to drain and composes carried counts so the bar
never restarts. `DisplayAwake` holds the screen on for the initial ingest. The dev buttons pass
`showPrompt: true`, which adds a left pane showing the exact prompt for the current item; that is the
only dev/prod difference. Two more display-only demo knobs (`dev.processing.demoBaseDone/Total`) let a
screen recording open mid-run.

## Connect surfaces

`ConnectAIsView` (windowID `connect-ais`): sharing off → the guide peeks crisp for a second, then blurs
under a consent veil ("Connect your AIs?", the trust pillars, a "Yes, use the cloud MCP" glow that
enables the mirror and pushes, "Not now"); sharing on → tabs for Claude, ChatGPT, and Other AIs, each
step a bundled looping tutorial clip (`Media/connect-<ai>-<n>.mp4`; a missing file renders a glass
placeholder) with a take-me-there deep link into that AI's own settings, the masked link + Copy, the
system prompt + Copy, and the top-right MCP pill (last synced time; turning off confirms and deletes).
`CloudConnectSheet` and `ChatPicker` are documented with the sources.

## Shared design pieces

- `Theme`: the palette (`bg`, `panel`, `elevated`, `stroke`, the `Ink` set: `statusInk`, `body`, `label`, `deepMuted`, `green` #4ade80, `amber`, `red`, `gold`, the Knowledge accents), verdict colors, `MonoCaps`, `.display()`, `.glassCard()`, `PressScaleStyle`, `Date.glanceStamp`, the verdict pills.
- `GlowButton` (the white capsule on the rotating conic halo; `GlowHalo.stops` are THE canonical AI-gradient stops shared with the notch, the progress bar, and the website), `QuietPillButton`.
- `Orb` (the living brand mark: a glassy planet, a depth-sorted 3D ring, halo; modes idle / processing / attention; performance rules in its header: no per-frame state writes, no per-frame blur, a focus-aware clock so a background window is capped at 60 fps) and `OrbMark` (the static glyph and the menu-bar template icon).
- `GlowProgressBar` (the scrolling multicolor bar with a tip glow), `FileThumbnail` (QuickLook), `ModelDownloadWhisper`, `MenuBarView` (Open, status, Check for Updates…, version, Quit), `FrontierEnginePicker` (documented in the BYOM doc), `CodexSetupView` (dev-only).

## Rules

- View the design bar before any user-facing work. One or two glowing objects per screen.
- Serif only for content about the user's life; never italic display; no em dashes in copy.
- The home renders real cards by default; the demo decks are dev-tools-only.
- Every fire and every command passes the one-task lock and the permission gate; do not add a side door.

## Related docs

`Proactive/Documentation - Proactive Intelligence.md`, `Notch Magic/Documentation - Sidekick - General.md`, `Ingestion/Documentation - Ingestion Pipeline.md`, `System/Documentation - System (Permissions, Health, Uninstall).md` (the banners), `Cloud/Documentation - Cloud - MCP Mirror.md`, `Views/Settings/Documentation - Settings.md`, `Views/Knowledge/Documentation - Knowledge Window (Constellation & Reader).md`, `Views/Onboarding/Documentation - Onboarding.md`, `Views/Permissions/Documentation - Permission Gate & Guide.md`, `Views/Dev/Documentation - Dev Tools.md`.
