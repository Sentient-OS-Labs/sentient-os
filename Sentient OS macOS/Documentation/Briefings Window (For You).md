# The Briefings Window — For You ("The Offerings")

The proactive-intelligence surface (Arch §9 naming: surface = **For You**, artifacts =
**briefings**) — and the stage for the headline feature: every briefing is an **offer**.
The AI already did the work (research / draft / plan) and asks one question — *"Should I
send it for you?"* — clicking it is the user's fire (Privacy Constitution: we never act
unbidden; we offer, they fire). Execution rides the user's own Codex CLI (browser use,
computer use), armed with the vault's personal context.

Three files:

## `Views/Briefing.swift` — model + the demo six

`Briefing` (kicker / serif title / preview body / full `letter` / copyable `draft` / the
verb `offer` / `workLog` theater lines / done state / **`codexPrompt`**). Kind → accent
(meeting cobalt · overdue amber · promise mint · deadline ember · plan orchid · welcome =
the full gradient).

**THE CODEX SEAM:** demo execution plays the scripted `workLog`; real execution replaces
the loop in `ForYouModel.run` with `CodexCLI.run` on `codexPrompt`, streaming JSONL events
into the same lines. One swap point, clearly marked.

**All six cards are hard-coded showcase content** (Deepika/Outlander · Luis/Headline ·
Dad's shoes · ZFellows · SF break plan · the welcome letter), mined from the real vault for
authenticity. The proactive module generates real ones post-launch.

## `Views/BriefingCard.swift` — the card's four lives

`sealed` (welcome only: dark-paper envelope, 3D-swinging flap, gradient wax seal stamped
with the orb mark — tap to open) → `offer` (kicker + serif headline + `OfferButton`, the
accent-ringed verb CTA) → `working(n)` (the agentic theater: mono log lines typing in
under a blinking cursor) → `done` (mint check; the model flies the card away after ~3s).
`OfferButton` is shared with the expanded letter.

## `Views/BriefingsView.swift` — the window

- **The deal:** cards spring in from above the header, staggered 110ms apart, and settle
  into organic slots (per-population layouts + stable per-id jitter/rotation — pinned, not
  gridded).
- **Flick physics:** drag any card; past a flick threshold (predicted translation > 320pt)
  it flies off along the flick vector and the scatter **reflows** with springs.
- **The letter:** detail links expand a full typeset reading view (paragraph + ✦-bullet
  styling, accent-barred draft block with Copy, the offer button lives there too). Esc /
  click-outside / ✕ closes; the scatter blurs behind.
- Header greeting is hour-aware ("Good morning, Jesai." — name is `Demo.name` until the
  vault portrait supplies it). Reminders whisper-strip + trust footer on the floor. Empty
  state: *"All quiet." / YOUR AI LOOKS OUT FOR YOU*.
- Scene: its own `Window` (`BriefingsView.windowID`), hidden title bar, 1180×800. Opened by
  the Constellation's briefing satellite (which now shows the latest offer + a `+5` pill).

## Still demo / future

Real briefings from the proactive module · real reminders in the strip · `Demo.name` from
the vault · trackpad two-finger swipe-to-dismiss (needs an NSEvent scroll monitor; drag-
flick ships first) · menu-bar "newest briefing" entry.
