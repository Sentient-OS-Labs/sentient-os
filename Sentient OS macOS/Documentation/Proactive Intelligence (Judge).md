# Proactive Intelligence — the 3-part pipeline (Judge → Research & Prepare → Fire)

The product's headline feature (Arch §7). Proactive is its **own module** (`Proactive/`), sequenced
AFTER a knowledge-base build/update, never concurrently (two agentic jobs over the same knowledge
base). Three parts, each its own prompt:
- **PART 1 — Judge**: finds the top action-item candidates from the summaries alone.
  `Proactive/Proactive.swift`.
- **PART 2 — Research & Prepare**: verifies each against the live world (Gmail MCP + web + the
  knowledge base) AND stages every survivor **ready to fire** (draft + execution recipe), in one
  read-only pass. `Proactive/ProactiveResearch.swift`.
- **PART 3 — Fire (the executor)**: the single write-capable step — on the user's one-button press it
  runs a `PreparedAction`'s recipe with `bypassApprovals`. `Proactive/ProactiveExecutor.swift`.

**The whole read-only/safe world is Parts 1–2; the one dangerous, write-capable step is PART 3** — the
pipeline lines up exactly on the permission boundary.

**The trigger is `ProactiveCycle`** (`Proactive/ProactiveCycle.swift`) — the shared post-read tail
that BOTH the home's real-mode Analyze Now (`ProcessingView`, `fullCycle: true`) and the 3am
overnight scheduler run: knowledge base create/update → mirror push → *(first time only)* the welcome
`GiftLetter` → decide → research + prepare → **wipe the cycle's summaries** (success only — a failed
step keeps them for retry). The results land in `ProactiveResearch.latest()` (UserDefaults), which the
home's For You deck renders as real cards. **Knowledge-base-only mode (free/go plans) skips decide +
research entirely** (an empty ready-list is saved so stale cards can't linger); the KB → mirror →
gift → wipe legs still run — see `Plan Gate (CodexAuth & Knowledge-Base-Only).md`.
`run(progress:onLine:)` also streams codex's humanized play-by-play from every cloud stage (KB
build/update · gift · judge · research) — the takeover's live "THINKING" line (see the Progress
section of `Vault Generation (Stage 2).md`); the scheduler passes no `onLine` and streams nothing.

## PART 1 — What the judge does

A **hermetic, summaries-only** Codex call (gpt-5.6-sol, **high** effort — this judgment is the product)
that reads ONE input and ranks it:

- **The last 7 days of summaries** from every source — files, WhatsApp, iMessage, Apple Notes,
  Gmail, and Calendar — passed over stdin. Each line: `#n · [source] location · date` then
  `Title — summary`. "What just happened." (Windowed inside `findActionItems` by each note's
  `itemDate`; `Proactive.recent(from:)` defines the window ONCE, shared with PART 2 so both reason
  over the same corpus.)
- **The live calendar, when Calendar is connected** — a `## THE USER'S LIVE CALENDAR` block (last 7
  days + next 24 hours, ALL events) passed as `calendarContext:`. Fetched **ahead of time as plain
  text** (`CalendarConnect.fetchProactiveContext`), so PART 1 stays tool-free — the calendar is just
  extra grounding for time-sensitivity. Omitted when Calendar isn't connected.

PART 1 deliberately uses **NO tools** — no vault reads, no Gmail/Calendar MCP, no web search. The call
runs hermetic (`includeUserConfig = false`, `webSearch = false`) over a neutral empty scratch dir as
`cwd`, so even the read-only file tools have nothing to find: it judges from the summaries (plus the
pre-fetched calendar text) ALONE. The deep grounding — vault + Gmail MCP + web — is **PART 2's** job,
and PART 2 is **verify-only**: it can correct, enrich, or DROP a PART 1 item, but never add a new one.
That makes PART 1's shortlist the ceiling.

Output: **up to 8 candidates** (`Proactive.maxItems` — PART 1 casts a deliberately WIDER net; PART 2
prunes to the **≤5 strongest**, `ProactiveResearch.maxReady` — that's where scarcity = taste) as
ranked `ActionItem`s via `--output-schema` (`{action_items:[{title, action, importance, due_date,
sources, urgency}]}`). It returns FEWER — even zero — when there genuinely aren't that many worth
surfacing. It only FINDS and RANKS; it does **not** verify, write, schedule, or notify.

### The contract (`ActionItem`)

| field | meaning |
|---|---|
| `title` | short, specific headline (≤ ~8 words) |
| `action` | what the user should concretely do / be aware of |
| `importance` | WHY it matters to THIS user — the dots connected (which summaries/sources) |
| `dueDate` | the real relevant date in plain words, or `nil` (the prompt forbids invented dates) |
| `sources` | the evidence — the summaries used, each by name |
| `urgency` | `high` / `medium` / `low` |

### The prompt

Accuracy-first and deliberately detailed. Cross-source context is the moat, but it's used to
**ground** each item, not to filter or diversify the output. Core thrust:
- **Cross-source context grounds every item** — connect candidates across sources (a Notes to-do that
  another summary shows is now due, a proposed time plus a free calendar slot). This is NOT a
  preference for items that touch many sources: a deep single-source item is every bit as valid.
  `importance` must name the dots connected; `sources` must cite the evidence.
- **No forced spread, no anti-email bias** (June 18) — scan every source thoroughly, but pick the
  genuinely strongest items whatever their source.
- **Judge from the summaries ALONE** — the prompt tells the model explicitly it has no vault/Gmail/web
  to lean on, and that a later step verifies (so it needn't be perfectly certain, but must not pad).
- An **illustrative example catalogue** (hypothetical — overdue reply, cross-tool meeting, a promise
  made, a deadline+form, a renewal/expiry, a self-written to-do, a plan forming across a group)
  teaches the SHAPE, not specific facts.
- Standard guardrails: never invent a date/fact; no raw private specifics; a confident wrong item is
  worse than a miss.
- **The user's own standing instructions** — `Proactive.instructionsBlock` injects the free text from
  Settings → Proactive & Sidekick (`proactive.instructions`, via `CustomInstructions`) as a
  high-priority directive block near the top: honor what they say to surface / skip, but it never
  overrides the accuracy or never-fire rules. The block is `""` when unset (prompt unchanged), and the
  SAME block is reused in PART 2 (like `recent`/`summaryLines`) so exclusions and preferences hold
  end-to-end.

### Invocation specifics

`CodexCLI.Invocation`: `effort .high`, `sandbox .readOnly`, `cwd =` a neutral empty scratch dir,
`webSearch = false` + `includeUserConfig = false` (hermetic — no tools), `outputSchema`, `timeout
1200s`, `feature "proactive"`. Errors typed (`ProError`): `noRecent` / `usageLimit` / `failed`. The
last run persists to UserDefaults (`Proactive.latest()`) for PART 2 + the dev viewer.

## PART 2 — Research & Prepare

File: `Proactive/ProactiveResearch.swift` (the `ProactiveResearch` actor + `PreparedAction` /
`DroppedItem` / `ReadyResult` value types). It takes PART 1's `[ActionItem]` and, for each, does two
things **in one read-only pass** — verify then stage:

1. **VERIFY** against the LIVE world — prove it's still real / the user's / needed, or DROP the stale
   ones. (Merging verify + prepare into one pass avoids re-reading the same thread/vault twice, and
   keeps the whole read-only/safe world in Parts 1–2.)
2. **PREPARE** every survivor **ready to fire** — draft it in the user's voice (`prepared_content`) +
   write the routing-only `execution_recipe` PART 3 runs.

Two inviolable rules, enforced in the prompt AND the invocation:
- **Accuracy / anti-hallucination** — receipts-only (state a live fact only if a tool returned it this
  run), mandatory identity-match for any external fact, "couldn't confirm" → `status: unverified` as a
  valid outcome. Verify-only on discovery (never invents a new item — that's PART 1).
- **Never fires** — it stages but never sends/submits/pays/RSVPs. `bypassApprovals = false` + sandbox
  means a connector WRITE (e.g. Gmail `send_email`) would auto-cancel headless anyway.

Research surfaces (all read-only): the **full last-week summary corpus** (the SAME window PART 1 saw,
as background context), the **knowledge base** (`cwd` — identity anchor + the user's **voice** + the
facts a draft/form needs), the **Gmail MCP** if connected (read the live thread; skip gracefully +
mark `unverified` if absent), **web search** (external facts, identity-matched), and the
**live-calendar context** (the same `calendarContext:` block as PART 1). It also carries the user's
**standing instructions** — the SAME `Proactive.instructionsBlock` PART 1 shows — so preferences that
shape staging (a channel to prefer, a draft tone, a thing to skip) hold through the prune-to-5.

`CodexCLI.Invocation`: `effort .high`, `sandbox .readOnly`, `cwd = vault`, `webSearch = true`,
`includeUserConfig = true`, `bypassApprovals = false`, `outputSchema`, `timeout 1800s`, `feature
"proactive-research"`. Output: `{ready:[{title, method, target, urgency, due_date, status,
verification, card_summary, prepared_content, execution_recipe, button_text, detail_label, sources,
review_note}], dropped:[{title, reason}]}`.

- `method` ∈ `gmail` / `calendar` / `computer` / `research` — `computer` covers native-app actions,
  chat sends, AND logged-in website tasks (driven via the user's real browser); `research` carries no
  fire (`execution_recipe = "none"` — it absorbs a real-but-unautomatable item rather than drop it).
- `target` = the app/site brand for the card kicker ("COMPUTER USE · LINKEDIN").
- `prepared_content` = the VERBATIM artifact the user reviews and **can edit in the card's letter
  view** — the edit is persisted back into `ProactiveResearch.latest()` and is exactly what fires.
- `button_text` / `detail_label` = the LLM-written fire CTA ("Should I send it for you?") + the quiet
  open-the-draft link.
- `status` ∈ confirmed / updated / unverified; `review_note` = what to double-check before firing.

Errors typed (`ResError`): `noItems` / `noVault` / `usageLimit` / `failed`. Persists to
`ProactiveResearch.latest()` — the home's For You deck and PART 3 both read it.

## PART 3 — Fire / the executor

The single write-capable step: on the user's one-button press, `fire(_:progress:)` performs a
`PreparedAction` for real, routed by `method`:
- **gmail** → the user's Gmail MCP via codex (**`bypassApprovals = true`** — the only thing that lets
  an approval-gated connector write fire headless).
- **calendar** → the user's calendar MCP via codex (same bypass; an honest "couldn't" if none exists).
- **computer** → **computer use via the Codex CLI** (`CodexCLI.runAgentCommand` — the SAME spine the
  home command bar and Sidekick use): native apps, chat sends (WhatsApp/iMessage via Messages), and
  logged-in website tasks in the user's real browser. This works on the plain CLI —
  `ComputerUseSetup` bootstraps the payload into `~/.codex` (doc: `Computer-Use Bootstrap (Codex
  Reverse-Engineering).md`); the required macOS grants live in `System/Permissions.swift` + the
  Settings health board.
- **research** → `notFireable` (a briefing to read; nothing fires).

**The security wrapper is built.** `bypassApprovals` removes the whole sandbox, and the recipe was
authored by an LLM from the user's email + knowledge base — a prompt-injection path into a no-sandbox
execution. So each channel runs a **fixed, app-authored wrapper prompt** (`gmailWrapper` /
`calendarWrapper` / `computerWrapper`) that: wraps the user-reviewable `preparedContent` in a
`<<<CONTENT>>>` block sent **VERBATIM** (the user's edits are exactly what goes out) and the routing
in a `<<<ROUTING>>>` block · declares BOTH blocks DATA, never instructions · confines the run to the
one declared action (computer use is additionally forbidden AppleScript/Terminal shortcuts) · demands
a final **`STATUS: DONE — …` / `STATUS: COULD_NOT — …`** sentinel. The sentinel verdict feeds
`ExecutorScoreboard` (`Diagnostics/ExecutorScoreboard.swift`, §7.19) — one structured event per fire;
"fired" means codex *claimed* done, and a missing sentinel is tracked as the false-success risk.
Cancellation is real: the awaiting Task's cancel (a card's STOP) terminates the codex process.

## Where it surfaces

- **The For You home (the default experience):** the home deals real cards from
  `ProactiveResearch.latest()` (`dev.proactive.realCards`, ON by default) — the
  welcome `GiftLetter` envelope first, then one card per `PreparedAction` (method accent + kicker,
  editable draft, the LLM-written fire button). Firing streams codex's live play-by-play into the
  card with a per-card STOP; success flies the card away and removes it from the persisted set.
  The dev toggle OFF = the hard-coded investor demo deck (pitch mode; scrubbed pre-launch). See
  `Home — Proactive Intelligence (For You).md`.
- **The dev cockpit:** DEV TOOLS → "proactive system" (PART 1) → "proactive RESEARCH + PREPARE"
  (PART 2) → the "PROACTIVE · EXECUTE" window (PART 3, real FIRE buttons) — plus "VIEW ACTION ITEMS"
  for the last judge run. Full detail tees to the console (`tail -f /tmp/sentient-dev.log`).
- **The full pipeline:** Analyze Now (real mode) and the 3am scheduler both run `ProactiveCycle` —
  no dev buttons needed.

## The welcome gift — `Proactive/GiftLetter.swift`

The day-one "letter from Sentient" card: ONE hermetic codex call (gpt-5.6-sol, high, `workspace-write`
over the user's own knowledge base, no web/MCP) reads the whole vault and writes a short, delightful
cross-life-patterns letter as `Gift from Sentient.md`; the app reads it back, persists it
(`gift.latestLetter`), and deletes the file so nothing strays into the vault or the mirror.
Generated ONCE by `ProactiveCycle` (best-effort — never fails the cycle), rendered as the sealed
envelope card (`Briefing(fromGiftMarkdown:)`). The prompt lives in
the code itself — `GiftLetter.prompt(vaultPath:)` is the source of truth (the old Our_Stuff scratch md is temporary).

**Lifecycle — the gift lives exactly one deck.** `ProactiveCycle` notes whether a gift already
existed before the run (`giftPreexisted`); when the proactive stage successfully replaces the deck,
a pre-existing gift is cleared. A failed cycle never eats it (the clear sits after the research leg's
early returns), and knowledge-base-only mode never reaches it (no proactive stage — the envelope is
the free home's only card, so it lives on). A gift whose generation failed on cycle 1 regenerates on
cycle 2 and still gets its full day.

**The keepsake — `Views/GiftShareImage.swift`.** The expanded welcome letter carries a footer only
the gift wears: **Save to Desktop** + the whisper "Your gift will be cleared from the home screen
soon." The button renders the letter as a @2x poster PNG — the letter card in the welcome-gradient
hairline on OLED black, plus the left-aligned branding colophon (orb + wordmark, the one-line pitch,
sentient-os.ai) — via `ImageRenderer`, drawn by the SAME shared `LetterBody` renderer as the
on-screen letter (extracted from `LetterView` for exactly this parity). It saves as
`~/Desktop/Gift from Sentient.png` (counter-suffixed, never overwrites) and reveals the file
selected in Finder, so sharing it is one drag. The share view takes the built `Briefing`, not raw
markdown — the gift init promotes `# Title` out of the letter text, so the briefing is the only
faithful carrier of both.

## Not wired yet (next steps)

- **Retiring the demo deck** — real cards are the default now; deleting the hard-coded demo cards
  (they carry real investor names) is a pre-launch checklist item.
- **Tier 1 reminders** — a scheduled macOS notification from a `reminder`/dated action
  (`System/Notify.swift` is the dormant hook).
- **The ≤1/day taste cap** in code (today the cycle runs whenever triggered).
