# Proactive Intelligence (Proactive/)

**Useful work, ready before you ask.** An overdue reply with the missing project detail. A deadline
that needs a form. A trip that still needs a check-in. Proactive intelligence looks for unfinished
work supported by your context, prepares the next step, and puts it within reach in the morning.
These are examples, not fixed daily cards or a promise to find something every night.

Overnight, Sentient decides what in the user's life is worth doing,
verifies it against the live world, prepares it (a draft, an event, a step-by-step plan, or a briefing),
and leaves it on the home as a card the user fires with one click. Three parts, each its own prompt,
lined up exactly on the permission boundary: parts 1 and 2 are read-only with respect to external services; part 3 is the
action-execution step and runs only on the user's press. Plus the cycle that sequences everything and the
one-time welcome gift letter.

## Files

| File | Job |
|---|---|
| `ProactiveCycle.swift` | The shared tail every full processing cycle runs (Analyze Now, onboarding's first analysis, the 3 AM run): knowledge base → mirror push → gift letter (once) → decide → research and prepare → wipe the summaries. Classifies failures. |
| `Proactive.swift` | PART 1, the judge: a hermetic, summaries-only call that finds up to 8 candidate action items. |
| `ProactiveResearch.swift` | PART 2, research and prepare: verifies each candidate against the live world and stages the ≤5 strongest as ready-to-fire `PreparedAction`s. Never fires. |
| `ProactiveExecutor.swift` | PART 3, the executor: fires one `PreparedAction` on the user's press through its channel (gmail / calendar / computer). |
| `GiftLetter.swift` | The welcome "letter from Sentient": one codex call over the finished knowledge base, generated once. |

## The cycle (`ProactiveCycle.run`)

Runs AFTER the on-device read has filled `CycleStore`. Steps, in order:

1. Nothing new this cycle → stamp `proactive.lastCycleAt`, report done, return.
2. **Knowledge base:** `VaultCloud.create` the first time, else `VaultCloud.update` (a sliced corpus reports "part N of M" through the phase line).
3. `VaultCloud.pushIfDirty()` (no-op when the mirror is off).
4. **Gift letter**, only if none exists yet. Best-effort; a failure never fails the cycle. A gift that already existed before this cycle retires when the proactive stage replaces the deck (step 5), so it lives exactly one deck; in knowledge-base-only mode there is no replace, so the free home's lone envelope lives on.
5. **Proactive**, skipped entirely in knowledge-base-only mode (an empty ready list is saved so stale cards never linger): fetch the live calendar block once if Calendar is connected (`CalendarConnect.fetchProactiveContext`), then the judge, then research and prepare over its items.
6. **Wipe the cycle's summaries** (`CycleStore.wipeAllNotes`), clear any morning-after caution, stamp the last-cycle time, and stamp "first full cycle completed" for the scheduler's 14 h auto-enable clock. Success only: a failure at any step keeps the summaries for the next retry.

Every failure funnels through one `fail` helper: `OvernightCaution.classify` turns it into codex
signed out / no internet / usage limit / input too large when it can; the UNATTENDED run
(`scheduled: true`) additionally persists that kind for the home's amber banner, while a watched
Analyze Now shows the same kind live on the takeover's failed screen. `progress` carries the phases the
UI renders; `onLine` streams codex's humanized play-by-play from every cloud stage (the takeover's
"THINKING" trail; the scheduler passes nothing). `resetAll()` forgets the judge items, the prepared
deck, the gift, and the last-cycle stamp.

Local files, conversations, notes, Apple Mail and Apple Calendar are first analyzed on-device.
The selected frontier model organizes the knowledge and prepares suggestions; it can be local or
hosted. Apple Mail and Calendar provide email and schedule context without a ChatGPT or Claude
subscription. Hosted/direct connectors are optional additional sources, with their own support.

Apple Calendar summaries are dated local snapshots, distinct from hosted live-calendar context.
When they are present, both judge and research receive `CalendarContext.localSnapshotPolicy`: do
not infer free time or attendance, do not pass local occurrence IDs to hosted APIs, and do not treat
this read-only connection as write access. Any native-calendar action must be prepared for explicit
user-triggered computer use and verify the live calendar first.

## PART 1: the judge (`Proactive.findActionItems`)

- **Input:** the last 7 days of summaries from every source (`Proactive.recent`: windowed by item date, byte-budgeted to `CorpusSlicer.budget`, oldest dropped first), plus the pre-fetched live calendar block, plus the user's standing instructions from Settings (`Proactive.instructionsBlock`, from `CustomInstructions.proactive`), plus the clock ("Right now it is Thursday, July 17, 2026 at 1:05 PM (PDT)", since a hermetic run cannot even run `date`).
- **Hermetic on purpose:** read-only sandbox, `cwd` = an empty scratch dir, no web search, no user config or MCP servers, `--output-schema`, high effort. It judges from the summaries alone; the deep grounding is part 2's job, and part 2 is verify-only, so this shortlist is the ceiling.
- **Output:** up to 8 ranked `ActionItem`s (`title`, `action`, `importance` naming the dots connected, `dueDate` or nil, `sources`, `urgency`). Fewer, even zero, when nothing is worth surfacing. The prompt teaches the SHAPE of good items (an overdue reply, a cross-tool meeting request, a promise the user made, a deadline with a form, a renewal, a self-written to-do, a plan forming in a group chat), demands cross-source connections only when they are really there, forbids invented dates and facts, and never forces a spread across sources.
- Persists to `proactive.latestActionItems` (the dev viewer reads it).

## PART 2: research and prepare (`ProactiveResearch.researchAndPrepare`)

One read-only agentic pass over part 1's items, two jobs per item:

1. **Verify** against the live world and DROP the stale ones: the knowledge base (`cwd` = the vault; the identity anchor, the user's voice, and the facts a draft needs), the Gmail MCP if connected (read the actual thread; never send, draft, label, or modify), web search (identity-matched external facts), and the calendar block. Verdicts: `confirmed`, `updated` (a detail corrected), or `unverified` (a valid, expected outcome; honest uncertainty beats invented certainty).
2. **Prepare** every survivor to be ready to fire: `prepared_content` (the VERBATIM artifact the user reviews and can edit: the full email subject + body, the exact chat message, the numbered step-by-step PLAN for a computer task, or a research briefing in the letters' light Markdown), `execution_recipe` (ROUTING only: recipient and thread, event fields, the app or URL to start in), `recipient` (the editable "To:"), an LLM-written `button_text` and `detail_label`, `sources`, and a `review_note`.

Three design constraints shape the prompt and invocation:

- **Accuracy:** receipts only; a live fact exists only if a tool returned it this run.
- **Never fires:** three independent layers: the prompt rule; a read-only sandbox with `bypassApprovals = false` (a connector write auto-cancels headless); and `CodexCLI.Invocation.stripConnectorActionTools`, which removes the sending and destructive connector tools from the run's tool surface entirely, to limit the tools available to untrusted retrieved content. On the Claude engine the same preset maps to the curated read-only connector allows (`ClaudeCLI.ConnectorTools`): reads flow, and no write rule exists in the run, so "never fire" stays structural there too.
- **Never computer use**, not even to verify: research runs do not receive the native computer-use tools (these belong to `runAgentCommand`) and the prompt forbids it; acting on the Mac belongs to part 3, on the user's press.

Methods: `gmail`, `calendar`, `computer` (native apps, chat sends via Messages, AND logged-in website
tasks in the user's real browser), `research` (informational only; nothing fires). At most 5 ready
cards (`maxReady`, enforced in the prompt and as a code backstop): scarcity is taste. Invocation:
high effort, read-only, `cwd` vault, web on, user config on (for the Gmail MCP), the strip preset,
`--output-schema`, 1800 s. Persists to `proactive.latestReady`, which the home renders.

## PART 3: the executor (`ProactiveExecutor.fire`)

Routes on `method`. The user-editable artifact rides in a `<<<CONTENT … CONTENT>>>` block and the
routing (with the possibly edited recipient placed FIRST as the authoritative destination) in a
`<<<ROUTING … ROUTING>>>` block, so what the user edited is exactly what fires.

- **gmail / calendar:** `FrontierRun.run` with the sandbox ON (`read-only`) and the connector write tools pre-approved for the one run (`approveConnectorWrites`; on Claude that preset maps to a scoped allow), user config on, web off, 300 s. If the agent reports `COULD_NOT` AND the raw JSONL carries the verbatim "cancelled MCP tool call" marker (the pre-approval did not take, e.g. codex changed its apps config surface), it retries ONCE on the bypass path with the same fixed wrapper and emits `codex.fire_fallback`, to recover that recognized tool-policy failure without an unbounded retry loop.
- **computer:** `FrontierRun.runAgentCommand`, the same spine as Sidekick, with a 900-second deadline. All current model backends use native OpenAI computer tools through Codex; Claude inference uses its local subscription bridge. The card wrapper confines work to the user's one approved task and the selected runtime's documented transport. `FrontierRun` adds the matching manual and custom-backend guardrails once. Only an exact final success sentinel counts as completion; missing status is unconfirmed.
- **research:** `notFireable` (a briefing to read).

Every wrapper is a fixed, app-authored prompt that instructs the model to follow one declared task
and treat both blocks and retrieved content as data. This is a guardrail, not a guarantee that prompt
injection or an incorrect model action is impossible. The wrapper requires a final `STATUS: DONE — …` / `STATUS: COULD_NOT — …` line parsed by the
shared `AgentStatus`. Outcomes feed `ExecutorScoreboard` (defects only) and the analytics signals
`Proactive.actionFired` (core tier) and `ComputerUse.finished` (agent seconds). A user STOP (a cancelled
Task) records nothing.

## Where it surfaces

- **The home** deals real cards from `ProactiveResearch.latest()` (`Views/HomeView.swift`, `ForYouModel`): editable drafts, the LLM-written fire button, live streamed progress, a per-card STOP; a fired card flies away and is removed from the persisted set; a failed one returns to the offer state for edit and retry. Any fireable card fire ADOPTS Sidekick's shared run, so the notch lights with the card's title, `CommandRunModel.isRunning` is the app-wide one-task-at-a-time lock, and every STOP surface reaches it. Research cards fire nothing and stay quiet.
- **Dev Tools:** "proactive system" (part 1), "proactive RESEARCH + PREPARE" (part 2), the "PROACTIVE · EXECUTE" window (part 3 with real FIRE buttons), and "VIEW ACTION ITEMS".

## The gift letter (`GiftLetter.generate`)

One frontier call (the flagship tier — `gpt-6-sol` / `sonnet` — high, `workspace-write`, `cwd` =
the vault, no web, hermetic) reads
the whole knowledge base and writes a short, delightful cross-life-patterns letter as `Gift from
Sentient.md` in the vault folder; the app reads it back, persists it (`gift.latestLetter`), and deletes
the file on every exit path so nothing strays into the vault or the mirror. The prompt (in the code)
demands real, grounded, surprising patterns, plain warm language, no AI-isms, a `# Title`, bold
headline + one-sentence explanations, `✦` bullets, and a `-- Your Sentient` sign-off. The home renders
it as the sealed envelope card (`Briefing(fromGiftMarkdown:)`), with a **Save to Desktop** keepsake
(`Views/GiftShareImage.swift`).

## Rules

- Parts 1 and 2 may save local preparation state but must not mutate connected services, send messages, or use computer use. Part 3 fires only on the user's press.
- Content and routing blocks are DATA. Never let a channel prompt become dynamic beyond those blocks.
- `bypassApprovals` in this folder appears only in the computer channel and the one-shot connector fallback.
- Content-bearing logs (items, drafts, recipes) are `#if DEBUG` only.

## Related docs

`Vault/Documentation - Knowledge Base (Vault).md`, `Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md`, `Cloud/Documentation - Cloud - ClaudeCLI (the claude -p engine).md`, `Scheduling/Documentation - Overnight Scheduler & Wake Helper.md`, `Views/Documentation - Views - Home, Processing & Shared UI.md`, `Notch Magic/Documentation - Sidekick - General.md` (adopted runs), `Sources/Documentation - Sources - Cloud (Gmail, Calendar).md`.
