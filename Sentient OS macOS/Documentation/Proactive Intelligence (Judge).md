# Proactive Intelligence — Step 1: The Judge

Flagship feature #2 (Arch §4, §6). Proactive is its **own module + trigger**, sequenced AFTER a
knowledge-base build/update, never concurrently (two agentic jobs over the same vault). This doc
covers **step 1, the judge** — the rest (tier-1 reminders, tier-2 briefings, the For You surface,
the real scheduler trigger) builds on it.

File: `Ingestion/Proactive.swift` (the `Proactive` actor + the `ActionItem` value type).

## What it does

Once the initial pass has produced summaries and the vault exists, one **read-only** Codex call
(gpt-5.5, **xhigh** effort — the deepest pass, since this judgment is the product) reads BOTH inputs
and connects the dots:

1. **The last 7 days of summaries** from EVERY source — files, WhatsApp, iMessage, Apple Notes, and
   Gmail — passed over stdin. Each line: `#n · [source] location · date` then `Title — summary`.
   "What just happened." (Windowed inside `findActionItems` by each note's `itemDate`; the date is
   now reliably present on every summary — see Pointer Architecture + `corpusMessage`/`updatePrompt`.)
2. **The live knowledge base** — the agent's working directory (`VaultGenerator.vaultRoot`), explored
   read-only with its file tools (Read/Glob/Grep). "Who the user is / what they're already in the
   middle of." The judge grounds importance in the vault, so a generic receipt only surfaces when the
   vault shows it actually matters to this user.

Output: **up to 5** ranked `ActionItem`s via `--output-schema` (`{action_items:[{title, action,
importance, due_date, sources, urgency}]}`). It returns FEWER — even zero — when there genuinely
aren't 5 worth surfacing (scarcity = taste). It only FINDS and RANKS; it does **not** write,
schedule, or notify — those are the next tiers.

## The contract (`ActionItem`)

| field | meaning |
|---|---|
| `title` | short, specific headline (≤ ~8 words) |
| `action` | what the user should concretely do / be aware of |
| `importance` | WHY it matters to THIS user — the dots connected (which summaries + which vault notes) |
| `dueDate` | the real relevant date in plain words, or `nil` (the prompt forbids invented dates) |
| `sources` | the evidence — summary titles / vault note names |
| `urgency` | `high` / `medium` / `low` |

## The prompt

Accuracy-first, deliberately detailed, and **cross-source-first** (the judgment IS the product, and
cross-tool context is the moat). Core thrust:
- **Cross-source is the whole game** — fuse the same person/project/deadline across tools + the vault;
  a single-source signal with nothing to corroborate it ranks lower. The `importance` field must name
  the dots connected and `sources` must cite the fused evidence.
- **Do NOT let email dominate** — email summaries look action-dense, but a WhatsApp promise, a Notes
  to-do, a saved-file deadline, an iMessage request matter equally; aim for a spread across sources.
- **Read the vault deeply** (root README, then grep/read relevant notes) — never judge from summaries
  alone.
- **Detection, not execution (for now)** — frame the exact next action (draft reply, fill a form via
  a browser agent, schedule, send) as ready-to-execute; the action infra ships later.
- An **illustrative example catalogue** (hypothetical — overdue reply, cross-tool meeting, a promise
  made, a deadline+form, a renewal/expiry, a self-written to-do, a plan forming across a group) teaches
  the SHAPE and the cross-source reasoning, not specific facts.
- Standard guardrails: never invent a date/fact; attribution discipline; no raw private specifics; a
  confident wrong item is worse than a miss; at most 5, fewer if warranted; scarcity = taste.

## Invocation specifics

`CodexCLI.Invocation`: `effort .high`, `sandbox .readOnly`, `cwd = vault`, `outputSchema`, `timeout
1200s`. Errors are typed (`ProError`): `noVault` (build the KB first — both inputs are required),
`noRecent` (nothing in the window), `usageLimit`, `failed`.

## How to run it (the eval surface)

The **DEV TOOLS sheet** → "proactive system" button (`DevToolsView.runProactive`). It runs the judge
over the current cycle's summaries and shows the action-item titles in the status line; the **full
detail goes to the console** via `Log()` (`tail -f /tmp/sentient-dev.log`). It does **not** wipe the
cycle, so it's re-runnable while tuning the prompt. Typical flow: on-device pass → "go make knowledge
base exist" → "proactive system".

## Not built yet (next steps)

- Tier 1 — reminders (scheduled macOS notification from an action item).
- Tier 2 — briefings (agentic, workspace-write + web search + `--add-dir` Briefings; never auto-send).
- The For You surface (real cards from these `ActionItem`s).
- The real trigger (the scheduler calls this after a KB update) + the ≤1/day taste cap in code.
