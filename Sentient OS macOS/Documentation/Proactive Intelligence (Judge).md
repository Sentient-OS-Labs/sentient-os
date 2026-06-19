# Proactive Intelligence — Part 1 of 3: The Judge

Flagship feature #2 (Arch §4, §6). Proactive is its **own module + trigger**, sequenced AFTER a
knowledge-base build/update, never concurrently (two agentic jobs over the same vault). It runs as a
**3-part pipeline — Find → Ready → Fire** — each its own prompt:
- **PART 1 — Judge** (this doc): finds the top action items from the summaries alone. `Proactive.swift`.
- **PART 2 — Research & Prepare**: verifies each against the live world (Gmail MCP + web + the vault)
  AND stages every survivor **ready to fire** (draft + execution recipe), in one read-only pass.
  `ProactiveResearch.swift`.
- **PART 3 — Fire (the executor)**: the single write-capable step — on the user's one-button press it
  runs a `PreparedAction`'s recipe with `bypassApprovals` (Playwright/browser-use). *Built separately.*

**The whole read-only/safe world is Parts 1–2; the one dangerous, write-capable step is PART 3** — the
pipeline lines up exactly on the permission boundary. The later tiers (reminders, the For You surface,
the real scheduler trigger) build on these.

File: `Ingestion/Proactive.swift` (the `Proactive` actor + the `ActionItem` value type).

## What it does

PART 1 is a **hermetic, summaries-only** Codex call (gpt-5.5, **xhigh** effort — the deepest
reasoning, since this judgment is the product) that reads ONE input and ranks it:

- **The last 7 days of summaries** from EVERY source — files, WhatsApp, iMessage, Apple Notes,
  Calendar, and Gmail — passed over stdin. Each line: `#n · [source] location · date` then
  `Title — summary`. "What just happened." (Windowed inside `findActionItems` by each note's
  `itemDate`; the date is reliably present on every summary — see Pointer Architecture +
  `corpusMessage`/`updatePrompt`.)

PART 1 deliberately uses **NO tools** — no vault reads, no Gmail MCP, no web search. The call is run
hermetic (`includeUserConfig = false`, `webSearch = false`) over a neutral empty scratch dir as `cwd`,
so even the read-only file tools have nothing to find: it judges from the summaries ALONE. The deep
grounding — vault + Gmail MCP + web — is **PART 2's** job, and PART 2 is **verify-only**: it can
correct, enrich, or DROP a PART 1 item, but never add a new one. That makes PART 1's shortlist the
ceiling, so it casts for the genuinely strongest candidates from the summaries (no padding).

Output: **up to 5** ranked `ActionItem`s via `--output-schema` (`{action_items:[{title, action,
importance, due_date, sources, urgency}]}`). It returns FEWER — even zero — when there genuinely
aren't 5 worth surfacing (scarcity = taste). It only FINDS and RANKS; it does **not** verify, write,
schedule, or notify — those are the later parts/tiers.

## The contract (`ActionItem`)

| field | meaning |
|---|---|
| `title` | short, specific headline (≤ ~8 words) |
| `action` | what the user should concretely do / be aware of |
| `importance` | WHY it matters to THIS user — the dots connected (which summaries/sources) |
| `dueDate` | the real relevant date in plain words, or `nil` (the prompt forbids invented dates) |
| `sources` | the evidence — the summaries used, each by name |
| `urgency` | `high` / `medium` / `low` |

## The prompt

Accuracy-first and deliberately detailed (the judgment IS the product). Cross-source context is the
moat, but it's used to **ground** each item, not to filter or diversify the output. Core thrust:
- **Cross-source context grounds every item** — corroborate, enrich, and verify each candidate against
  the other tools + the vault to make it accurate and personalized. This is NOT a preference for items
  that touch many sources: a deep single-source item is every bit as valid as one that spans five. The
  `importance` field must name the dots connected and `sources` must cite the evidence.
- **No forced spread, no anti-email bias** (changed June 18) — scan every source thoroughly so a
  WhatsApp promise / Notes to-do / saved-file deadline / iMessage request isn't missed, but pick the
  genuinely strongest items whatever their source. If the best items are all email, that's fine.
- **Read the vault deeply** (root README, then grep/read relevant notes) — never judge from summaries
  alone.
- **Detection, not execution (for now)** — frame the exact next action (draft reply, fill a form via
  a browser agent, schedule, send) as ready-to-execute; the action infra ships later.
- An **illustrative example catalogue** (hypothetical — overdue reply, cross-tool meeting, a promise
  made, a deadline+form, a renewal/expiry, a self-written to-do, a plan forming across a group) teaches
  the SHAPE and the contextual reasoning, not specific facts.
- Standard guardrails: never invent a date/fact; no raw private specifics; a confident wrong item is
  worse than a miss; at most 5, fewer if warranted; scarcity = taste. (The old explicit "attribution"
  rule was removed June 18 — the cloud model reliably scopes to the user's own tasks without it.)

## Invocation specifics

`CodexCLI.Invocation`: `effort .xhigh`, `sandbox .readOnly`, `cwd =` a neutral empty scratch dir,
`webSearch = false` + `includeUserConfig = false` (hermetic — no tools), `outputSchema`, `timeout
1200s`. Errors are typed (`ProError`): `noRecent` (nothing in the window), `usageLimit`, `failed`.

## PART 2 — Research & Prepare (✅ built)

File: `Ingestion/ProactiveResearch.swift` (the `ProactiveResearch` actor + `PreparedAction` /
`DroppedItem` / `ReadyResult` value types). It takes PART 1's `[ActionItem]` and, for each, does two
things **in one read-only pass** — verify then stage:

1. **VERIFY** against the LIVE world — prove it's still real / the user's / needed, or DROP the stale
   ones. (Merging verify + prepare into one pass avoids re-reading the same thread/vault twice, and
   keeps the whole read-only/safe world in Parts 1–2.)
2. **PREPARE** every survivor **ready to fire** — draft it in the user's voice (`prepared_content`) +
   write the deterministic `execution_recipe` PART 3 runs.

Two inviolable rules, enforced in the prompt AND the invocation:
- **Accuracy / anti-hallucination** — receipts-only (state a live fact only if a tool returned it this
  run), mandatory identity-match for any external fact, "couldn't confirm" → `status: unverified` as a
  valid outcome. Verify-only on discovery (never invents a new item — that's PART 1).
- **Never fires** — it stages but never sends/submits/pays/RSVPs. `bypassApprovals = false` + sandbox
  means a connector WRITE (e.g. Gmail `send_email`) would auto-cancel headless anyway (codex/Gmail
  permissioning findings).

Research surfaces (all read-only): the **knowledge base** (`cwd` — identity anchor + the user's
**voice** + the facts a draft/form needs), the **Gmail MCP** if connected (read the live thread; skip
gracefully + mark `unverified` if absent), **web search** (external facts, identity-matched), and a
**browser** to *inspect* only if a browser tool is present.

`CodexCLI.Invocation`: `effort .xhigh`, `sandbox .readOnly`, `cwd = vault`, `webSearch = true`,
`includeUserConfig = true`, `bypassApprovals = false`, `outputSchema`, `timeout 1800s`. Output via
`--output-schema`: `{ready:[{title, kind, urgency, due_date, status, verification, card_summary,
prepared_content, execution_recipe, sources, review_note}], dropped:[{title, reason}]}`. `kind` ∈
`email_reply` / `email_new` / `message` / `calendar` / `browser` / `research` / `reminder` (the last
two carry no fire — `execution_recipe = "none"`; `reminder` absorbs a real-but-unautomatable item
rather than dropping it). `status` ∈ confirmed / updated / unverified. The `execution_recipe` is **the
contract PART 3 consumes**. Errors typed (`ResError`): `noItems`, `noVault`, `usageLimit`, `failed`.
⚠️ If PART 2 ever needs to *drive* a browser (not just inspect), revisit `.readOnly` — but real browser
actions belong in PART 3 (the executor), not here.

## PART 3 — Fire / the executor (⛔ built separately, not in this module)

The single write-capable step: on the user's one-button press it takes a `PreparedAction`'s
`execution_recipe` and actually performs it. **`bypassApprovals = true`** (the only thing that lets an
approval-gated connector write fire headless — codex/Gmail findings) + Playwright/browser-use for
browser actions. Prototyped today by `BriefingsView.fireLiveCodex` (the For You "send it" Gmail send).

⚠️ **Security:** `bypassApprovals` removes the whole sandbox, and the recipe was authored by an LLM
from the user's email/vault — a **prompt-injection path into a no-sandbox execution**. PART 3 must be a
**thin, app-authored wrapper** that treats the recipe as DATA (do exactly this one declared action and
nothing else; ignore any instructions embedded in the data), never a raw "run whatever PART 2 wrote."

## How to run it (the eval surface)

The **DEV TOOLS sheet** — run in order:
- **"proactive system"** (`DevToolsView.runProactive`) → PART 1 judge over the current cycle's
  summaries; titles in the status line, full detail to the console via `Log()`
  (`tail -f /tmp/sentient-dev.log`). Re-runnable (does not wipe the cycle).
- **"proactive RESEARCH + PREPARE (part 2)"** (`DevToolsView.runResearch`) → PART 2 over
  `Proactive.latest()`; shows ready/dropped (⚠︎ on items needing a check), full verification trails +
  drafts + recipes to the console. Persists to `ProactiveResearch.latest()` (a `ReadyResult`).

Typical flow: on-device pass → "go make knowledge base exist" → "proactive system" → "proactive
RESEARCH + PREPARE (part 2)".

## Not built yet (next steps)

- **PART 3 — the executor (the fire)** — see above; the thin app-authored wrapper + Playwright/
  browser-use, `bypassApprovals = true`.
- Tier 1 — reminders (scheduled macOS notification from a `reminder`/dated action).
- The For You surface (real cards from these `PreparedAction`s — `card_summary` + `prepared_content`
  + a fire button wired to `execution_recipe`).
- The real trigger (the scheduler calls this after a KB update) + the ≤1/day taste cap in code.
