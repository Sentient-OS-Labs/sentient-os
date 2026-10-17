# Sidekick backend: architecture and validation

Status: implemented on `codex/sidekick-conversation-backend`, 2026-10-16; final acceptance
is recorded below. This document retains the agreed design and its validation requirements.
It supersedes the earlier steering and deferred-permission proposals. No release or deployment
is part of this work. The conversation presentation follow-up is documented at the end.

## Fixed scope

One durable local conversation serves Home, notch, voice and proactive cards. No user
chat/session management. Ship reliable responses, full history, context preparation,
background compaction and one editable memory file. The presentation follow-up uses these same owners.

Keep current codex exec, claude -p, Claude computer-use bridge, native helper, model
selection, authentication, routing, permission/setup flow and action verification. No new
App Server inference architecture, copied credentials, live steering, automatic queueing,
lazy permission system or general agent framework. Replies to existing ask_user questions
continue to work. A user can Stop, then send a follow-up using the preserved task state.

Computer-use permissions remain in the current initial setup/readiness flow. The agent
should answer context-only questions directly, but this release does not redesign helper
startup or tool registration to avoid setup prerequisites.

## Architecture

### 1. One conversation store

A local SQLite store under Sentient Application Support owns messages, task records,
activity and prepared context. Use transactions and a serial ingestion path. Persist before
acknowledging a message or publishing committed state. UI reads a projection of this store.

Keep the data model small:

* Task: stable ID, originating request/source, start/end, outcome, continuation reference,
  and the exact reviewed card snapshot where applicable.
* Event: stable ID, task ID, optional execution-attempt ID, sequence, timestamp, type and
  bounded payload. Types cover user/assistant messages, questions/answers and tool activity.
* Context snapshot: summary, source references, covered sequence and store generation.
* Read watermark: what the user actually viewed, independent of completion or Home opening.

Only explicit user-facing assistant messages appear as conversation text. Typed tool
operations appear behind activity disclosure. No raw reasoning, screenshots/base64,
telemetry, stderr or protocol bookkeeping in the conversation database. Bound large tool
arguments/results and omit credential values. Keep temporary screenshot cleanup unchanged.

Import the legacy last-15 history once, transactionally and idempotently, preserving every
available request/outcome/error and labelling missing answers honestly. Never invent old
answers. Preserve legacy data until migration succeeds; stop treating it as an independent
writer afterward. Reset clears migration inputs too, preventing reimport of deleted history.

Identical delivery retries are idempotent. Changed payloads under the same ID fail. Late
callbacks belong to their original attempt. Corrupt or newer-schema storage is an explicit
error, not an empty database to overwrite. Accepted events drain before terminal commit.

### 2. One app-owned task lifecycle

CommandCoordinator and CommandRunModel remain the execution owners. SidekickInteraction
carries task-scoped messaging, history and memory capabilities into existing provider paths.
No separate conversation executor is introduced.

Move real proactive-card task ownership out of Home/ForYouModel into the app-owned run.
Home observes task state and requests actions. View refresh, disappearance or replacement
by conversation must not cancel work or discard its outcome. Explicit Stop remains global.
Preserve card snapshots, reviewed-content policies and completion effects on the card deck.

Keep logical task IDs separate from attempt IDs for connector-to-computer fallback.
A retry after an actual terminal failure is a linked new task with its real user guidance.
One task gets one terminal outcome: success, failed, stopped or interrupted.

Stop cancels existing owned work and retains the one-task lock until cleanup finishes.
It preserves messages, actual tool states and the most recent useful update. An attempted
remote mutation without a confirmed result remains unknown. Continuing must inspect current
state before repeating it. A stopped task never depends on a final model response.

Persist questions, choices and real answers, including stable question IDs. Keep the
existing waiting mechanism and timeout accounting. After restart, unfinished tasks become
interrupted and old questions become historical; never recreate dead continuations or
silently restart actions. The onboarding demo must not enter real conversation history.

Reset/uninstall invalidate conversation generation before suspension, cancel/drain active
work and compaction, then erase the intended data. Stale writes, summaries and read updates
cannot recreate erased state. Existing diagnostic export remains narrow and scrubbed.

### 3. Explicit messages through the existing tool server

Add message_user(markdown, kind, priority) to SidekickToolServer and expose it on every
user-facing provider route: Codex computer/connector, Claude bridge/direct connector,
proactive tasks and custom-provider paths that already support Sidekick tools.

Kinds distinguish quiet updates from answers; priority requests attention. Prompt the
agent to ALWAYS send a final user-facing response before normally finishing, including a
short result note for actions and the substantive answer for information requests. A handled
failure gets a clear explanation. Do not add a redundant completion bubble after an answer.

Message tool success means durable commit. Preserve tool RPC idempotency. Do not display
the messaging tool again as generic activity. Classify telemetry by structured identity and
exclude it on every route, including its failed calls. Do not infer message types from prose.

Task success is separate from message delivery. Retain existing STATUS and action-evidence
checks. If a final message is absent because of an abnormal exit or violated response
contract, expose an honest outcome/final-text fallback without inventing success or repeating
a previously delivered answer. Forced Stop/crash uses app-owned status.

Final responses request attention when the relevant conversation is not visible. High-priority
intermediate messages can also request attention. Suppress duplicate notch presentation when
the user is already reading that conversation; normal progress remains quiet. Presentation
state exposes the durable target message and unread status for the later UI.

### 4. Context and lightweight replies

The conversation is independent of CLI sessions. A new task receives current memory,
recent exact exchanges, relevant prior task outcomes/uncertainty, an older-history summary
and exact retrieved references. Existing provider processes may end after their task.

Use an explicit input budget with headroom for existing instructions, knowledge, screenshots,
tools and output. Roughly 15 recent user turns is a soft initial target, not a deletion rule.
Long reports may require fewer; short exchanges can retain more. Preserve recent user
requests/answers together rather than arbitrary paragraph tails. Do not drop the current
request, its correction or its selected quote to make room for unrelated old activity.

Keep task continuity from the actual final response, useful user-facing updates and observed
execution outcomes. Do not require another model call or an elaborate parallel task journal
for every request. Stop still has factual partial state even without final prose.

Add bounded history search/read capabilities to recover exact old answers and artifacts.
Whole-message/selected-text reply is a source message ID plus an optional quote. Resolve it
against stored history and supply a quoted reference alongside the new user prompt. No
thread branching. Historical content and summaries remain data, never new authorization.

### 5. One background compactor

One debounced worker summarizes a fixed prefix of completed tasks. Record the source
sequence and store generation; preserve references to the original events. Summary content
covers requests, decisions, useful results, artifacts, unresolved work and uncertainty.

The worker uses existing tool-disabled provider execution. Explicitly remove inherited
SidekickInteraction and other foreground tool capabilities. It cannot edit memory, call
message_user, operate apps or use action connectors. It never resumes the active session.
Codex may still advertise built-in `apply_patch` and `request_user_input`; isolation does not
depend on an empty tool list. The read-only sandbox/never-approve policy refuses writes,
headless input is unavailable, and no foreground MCP capabilities are attached. A real CLI
negative fixture verifies rejected writes and unchanged test files.

Atomically install only a validated summary of an advancing completed prefix. Newer messages
remain exact. Stale/out-of-order results and results after reset do not replace current state.
Original visible history is never deleted by compaction. Do not rely indefinitely on an
unsupported summary-of-summary chain; keep source references and bounded task segments.

Foreground never waits for compaction. A slow/failed/rate-limited worker leaves the previous
valid summary and bounded recent history usable immediately, with exact retrieval available.
Prioritize foreground and runtime maintenance. Test concurrency against the current private
runtime/auth behavior; do not redesign credential ownership to enable background work.
Provider-owned compaction during an active execution is a separate existing mechanism.

### 6. Simple SidekickMemory.md

One plain Sidekick/SidekickMemory.md is authoritative. Migrate the entire existing Sidekick
Instructions text verbatim when creating it. The main agent edits it; the user edits it
through the existing Instructions surface. Reread current contents at request boundaries
and on editor activation. Write atomically and report failures accurately.

Remove old staged proposals, 1.5-second display delay, learned-entry ownership/suppression
metadata and task-success-dependent persistence. A valid memory save survives a later task
failure or Stop. There is no memory worker or extra learned-memory policy engine. Preserve
user edits and use ordinary file-integrity handling for concurrent writes. Factory reset
preserves the file as user settings; full uninstall removes app-owned data as before.

### 7. Presentation contract

Expose messages/activity, current task/status/question, unread/attention state, history
pagination/search, reply references and a target-message navigation request. Draft and
reading position must not depend on a provider process. Rendering is a separate presentation layer.

Home may show proactive cards with a history peek/up arrow at the bottom. Expanding history
moves suggestions away. That transition must never change context or task lifetime. A history
peek does not mark unseen answers read. Opening a response from the notch targets that message.
Markdown rendering, materials, animation and composer behavior are implemented in the UI
follow-up below. The existing memory editor remains connected to the same durable file.

## Implementation sequence

1. Write fresh characterization tests for the actual execution/message/question/Stop paths;
   establish an isolated app build. Old scripts are supplementary, not the acceptance standard.
2. Implement/store/migrate the conversation; prove persistence, ordering, failure and restart
   behavior independently before replacing the legacy context source.
3. Unify app-owned command/card lifecycle and structured event capture. Preserve existing
   routing, verification and cleanup semantics. Test Home lifecycle independence.
4. Add explicit messages, final-response instructions, questions/answers, activity filtering
   and backend attention/read state across all existing provider routes.
5. Replace personalization with simple file-backed memory and existing editor wiring.
6. Add bounded context, exact history retrieval, reply references and stopped-task continuity.
7. Add isolated nonblocking compaction and prove stale-result/reset/concurrency handling.
8. Run full cross-provider acceptance, restart/Stop/failure scenarios, Debug/Release builds,
   harmless real-provider tests and a controlled native fixture. Document tested limits.

The implementation follows these boundaries, with fresh behavioural fixtures for each. The
working tree remains available for review. No deployment or publish is part of this work.

## Test strategy and acceptance gates

Fresh tests compile whole production backend types where practical, with injectable
filesystem/transport/clock. Use temporary data and deterministic barriers at event, tool,
commit and completion boundaries. Avoid assertions that merely mirror the implementation.

| Area | Required scenarios |
|---|---|
| Store | Exact Markdown/Unicode; append/reopen/paging/search; interrupted migration; identical/changed duplicates; concurrent callbacks; terminal uniqueness; read-only/full disk; corrupt/newer schema |
| Lifecycle | Routing and permitted fallback; question/real answer; offline/timeout; Stop and restart; in-flight unknown mutation; late callback; rapid Stop then follow-up; reset during write |
| Cards | Exact reviewed snapshot; same action policies; success/failure/retry; task survives Home refresh/disappearance; completion updates deck once |
| Messages | Tool retry deduplication; failed commit; normal final tool use; missing-message fallback; no duplicate answer; telemetry absent including failures; accurate attention/unread |
| Memory | Verbatim migration; file authoritative; user/external edits; multiple immediate saves; later task failure/Stop; failed atomic write; no background writer |
| Context | Recent complete exchanges; oversized answers; exact selected quote/whole message; options/draft retrieval; relevant outcomes; stopped partial work; provider switch; budget reserve |
| Compaction | Fixed completed prefix; new tail while running; stale/out-of-order/reset result; malformed output; timeout/provider failure; no inherited tools; foreground proceeds immediately |
| Existing execution | Native IDs/images/errors; connector allow/deny and account/content checks; verified vs unknown writes; cancellation/owned-child drain; no transport/auth/permission regression |
| Runtime | Foreground plus compactor; login/refresh/repair contention; no copied/stale auth; provider/account changes; no foreign-profile writes; shared helper preserved |
| Integrated | Prompt -> updates/activity -> question/answer -> final -> follow-up -> Stop -> restart -> continue, across Codex/Claude, computer/connector, card/ordinary entry points |

Three evidence levels:

1. Deterministic production-code tests/fake processes for persistence and lifecycle.
2. Real pinned CLI integration against synthetic tools/endpoints for actual event/timeout behavior.
3. Harmless real-provider and signed-app/native acceptance with synthetic windows/pages/files.

No real sends, calendar changes or other user-account mutations for testing. Do not launch a
test build against production app data. Build using isolated DerivedData so the user's GUI
build/signing is untouched. Do not print credentials. Report OS/permission/account combinations
not exercised. A successful build alone never establishes runtime reliability.

## Implementation map

| Production file | Responsibility |
|---|---|
| `SidekickConversationStore.swift` | Versioned SQLite/WAL transactions, validated event identity, migration, queries, read watermarks, reset generations, summary prefix checks and interrupted-task recovery. |
| `SidekickConversationRun.swift` | Task-scoped durable messages/questions/answers, stream-specific activity identity, sanitization, factual interruption checkpoints and final-answer fallback. |
| `SidekickConversation.swift` | App-owned observable projection, current recorder, navigation/draft/reply/attention state, teardown and single background compaction job. |
| `SidekickConversationTools.swift` / `SidekickToolServer.swift` | `message_user`, `search_history`, `read_history`, existing question/memory tools and exact RPC retry handling. |
| `SidekickContext.swift` / `SidekickCompactor.swift` | Provider-neutral recent exchanges, quoted replies, independent older segments, isolated inference and validated summary installation. |
| `SidekickInstructionStore.swift` / `SidekickPersonalization.swift` | Authoritative atomic Markdown memory file, migration, immediate saves, revision conflicts and existing Settings integration. |
| `CommandRunModel.swift` / `CommandCoordinator.swift` | Single task owner, persistent request/outcome lifecycle, Stop/drain, continuation and adopted card tasks. |
| `Diagnostics/SidekickDiagnostics.swift` | Content-free Sentry/TelemetryDeck boundary and bounded categorical metrics. |

The store is `Application Support/SentientOS/Sidekick/Conversation.sqlite`; memory is the
adjacent `SidekickMemory.md`. Original messages remain on disk. A request considers up to
30 recent tasks and fits their encoded JSON into 72,000 UTF-8 bytes, prioritizing complete
newer exchanges. Fifteen completed tasks stay outside the compaction prefix. Summaries are
independent source segments, with up to eight segments considered for a bounded part of the
prompt; exact older text remains searchable/readable. These are byte budgets, not claimed
token counts. Large fields are marked truncated, never silently presented as complete.

Activity retains bounded, sanitized connector details and command arguments. Native computer-use
and arbitrary code/shell result bodies are metadata-only: screenshots, accessibility trees and
opaque command output do not enter conversation context or become a second transcript. Questions,
actual answers and uncertain interrupted operations retain factual continuity separately.

## Reproducible verification

Run the fresh production-code fixtures from the repository root:

```sh
python3 Scripts/test_sidekick_backend.py
```

This runs eight suites for storage, migration/projection, run recording, memory, MCP tools,
context/compaction, lifecycle and diagnostics. They compile complete production types using
strict Swift concurrency, temporary databases/files and inert external collaborators. Coverage
includes injected disk/commit failures, process crash/reopen, stale/reset races, simultaneous
callbacks, contradictory retries, stopped work, large/escaped Unicode data, tool filtering,
read-watermark races, memory conflicts and diagnostic consent/content boundaries.

The DEBUG-only `SidekickBackendLab` runs before normal app startup and SDK initialization:

```sh
SENTIENT_SELFTEST=sidekickbackend LAB_SIDEKICK_COMMAND=process_fixture "$SENTIENT_TEST_BINARY"
SENTIENT_SELFTEST=sidekickbackend LAB_SIDEKICK_COMMAND=parser_fixture "$SENTIENT_TEST_BINARY"
SENTIENT_SELFTEST=sidekickbackend LAB_SIDEKICK_PROVIDER=codex_fixture "$SENTIENT_TEST_BINARY"
SENTIENT_SELFTEST=sidekickbackend LAB_SIDEKICK_PROVIDER=chatgpt "$SENTIENT_TEST_BINARY"
SENTIENT_SELFTEST=sidekickbackend LAB_SIDEKICK_PROVIDER=claude "$SENTIENT_TEST_BINARY"
SENTIENT_SELFTEST=sidekickbackend LAB_SIDEKICK_PROVIDER=claude_bridge "$SENTIENT_TEST_BINARY"
SENTIENT_SELFTEST=sidekickbackend LAB_SIDEKICK_COMMAND=compaction LAB_SIDEKICK_PROVIDER=chatgpt "$SENTIENT_TEST_BINARY"
SENTIENT_SELFTEST=sidekickbackend LAB_SIDEKICK_COMMAND=compaction LAB_SIDEKICK_PROVIDER=claude "$SENTIENT_TEST_BINARY"
```

Set `SENTIENT_TEST_BINARY` to the executable in an isolated Debug build. Each run uses disposable
history, preferences and memory. Live-provider fixtures use the existing private subscription
login in place, never copied credentials. The bridge receives a synthetic native MCP endpoint;
it does not operate a real account/app. Receipts contain check names, counts and fixed failure
categories; a failed synthetic task may include a short scrubbed final answer. No test sends
mail, edits calendars or mutates connected user accounts.

`codex_fixture` runs the actual pinned Codex CLI against a local deterministic Responses
endpoint, including negative capability probes. `process_fixture` uses a real owned child
process to prove observer errors terminate/drain it and preserve the original error. These
are complementary to actual model inference, not substitutes for it.
`parser_fixture` verifies that the acceptance parser rejects unexpected actions, including
completion-only file changes and unknown executor types, while counting repeated item
notifications once. Nonterminal CLI error notices are recorded separately from tool actions;
they must not be silently described as successful operations.

`compaction` uses the actual default `SidekickCompactor`/`FrontierRun` path with synthetic
completed tasks, a recent-tail sentinel and a trapped inherited interaction. It verifies the
installed source prefix/generation, unchanged original history/recent tail/memory, no question
callback, and retained artifact references and uncertainty. Run it alongside the matching
`provider` fixture to test shared-runtime contention. Receipts include start/end timestamps;
positive interval overlap establishes concurrent execution, not merely two eventual successes.
The normal compactor CLI may retain synthetic session records in its usual private runtime;
the lab does not guess at session files to delete or touch foreground sessions.

The signed native capture fixture uses a synthetic window, with no saved pixels or model call:

```sh
SENTIENT_SELFTEST=nativecua LAB_COMMAND=capture LAB_ROOT=/tmp/sentient-native-check \
  LAB_NAME=capture "$SENTIENT_TEST_BINARY"
```

Check the receipt's `captureHealth=passed` and `captureVerified=true`; process exit alone is
not evidence of capture. A separately running OpenAI computer-use helper can own the shared
service and block startup. Testing reproduced the user's workaround by gracefully closing
only the identified conflicting helper, then verifying capture. This refactor does not claim
to remove that shared-helper limitation.

## Acceptance evidence and limits

* Fresh backend suites: **8/8 passed, 721 assertions**: store 181, migration 85, run 96,
  memory 72, tools 101, context/compaction 65, lifecycle 79 and diagnostics 42.
* Real ChatGPT: message update, history search/read, question/actual answer, memory read/write,
  final attention, terminal uniqueness and database reopen passed after signing in to the
  app's private Codex profile. Standalone Codex sign-in is not the same profile.
* Real Claude direct and Claude bridge: the same controlled end-to-end fixture passed; the
  bridge also exercised a synthetic native call through the real relay.
* Real default compaction plus foreground: **both passed on ChatGPT and Claude**, with
  measured execution overlap of 9,536 ms and 5,450 ms respectively. Each compactor passed
  11 checks and each concurrent foreground task passed 19. The 45 recent-tail records and
  memory stayed unchanged. These tests used private Codex 0.160.0 and Claude Code 2.1.301.
* Real pinned Codex/local endpoint: seven MCP receipts and the negative write/input probes
  passed. The acceptance parser passed 14 checks. One unidentified nonterminal CLI error
  notice occurred against the synthetic model catalog; it is counted separately, and its
  cause has not been established. The live-provider acceptance receipts had no provider
  error events. Actual owned-process cancellation/drain passed all five checks.
* Signed native capture: synthetic-window capture passed with granted Accessibility/Screen
  Recording permissions. This is not a pristine-machine permission-onboarding test.
* Full Debug and Release app builds passed in isolated DerivedData. Existing unrelated
  Swift concurrency warnings are not treated as proof of clean repository-wide concurrency.

SDK dispatch/consent/scrubbing tests use inert sinks; no fabricated production incidents or
analytics were uploaded to validate dashboards. Custom-provider endpoints and real connector
account mutations have not been live-tested by these fixtures. Visual presentation is covered
by the separate UI acceptance layer below. Old runtime/session
scripts with API drift are not a green baseline and are not counted as new acceptance coverage.

An earlier isolated Codex queue probe accepted a queued message during an active request,
but exec completed without consuming it. Steering remains explicitly deferred.

## Actual signed-app prompt-path acceptance

`Scripts/test_sidekick_app.py` and the DEBUG-only `SidekickAppLab.swift` add a separate
end-to-end layer. This is not the direct provider lab above. Original acceptance mounted
`PromptBar`; the UI follow-up now mounts `SidekickComposer` and calls its actual `sendDraft`
action. Both resolve to `AppState.commandCoordinator.submit(..., source: .promptBar)`,
exactly as Home does.
The production permission gate, display capture, router, native runtime, selected provider,
Sidekick tools, run lifecycle and conversation store execute normally. Input submission is
programmatic; the testing agent does not use its own computer-use service.

```sh
python3 Scripts/test_sidekick_app.py --app "/path/to/Debug/Sentient OS.app"
# Or build a development-signed Debug app in isolated DerivedData first:
python3 Scripts/test_sidekick_app.py --build
```

The runner verifies the app signature and a linked DEBUG capability marker before launch;
it refuses a Release binary, which would otherwise enter ordinary startup. Before AppKit or
AppState exist, the lab redirects the process's standard-defaults getter to an actual isolated
UserDefaults suite, proves that redirection before writing a sentinel, and retains it until
exit. A guarded DEBUG Application Support root and the existing vault override isolate app
data. The canonical private Codex runtime/authentication remains in place. No credentials are
copied, no real history is reset, and the normal scheduler/updater startup is suppressed by
the existing self-test guard.

The visible fixture covers the displays and contains a real text field and Reveal button.
Native computer use must fill the field and click once. Only the button handler reveals a
random in-memory code; neither prompt nor seed data contains it. Verification requires both
completed native action records and independently observed widget values/click count, followed
by an explicit durable answer containing that code. The field, button and code are then hidden
from pixels and accessibility before a history-only follow-up, whose tool activity must not
inspect the app or use a shell. Escape or closing the test window aborts, restores the desktop,
stops the owned run and prevents later requests.

Each provider executes six accepted requests:

1. Native text entry/click, verification, priority message, and recall of migrated context/memory.
2. Recall of that result using saved conversation after the UI result is hidden.
3. A real `ask_user` question answered through the existing recovery action.
4. A real pending question stopped through the coordinator, with no fabricated user answer.
5. Follow-up that distinguishes the stopped unanswered question from an earlier answered one.
6. A selected-text reply tied to the saved source message.

An immediate second submission while busy must be rejected without another task record.
The runner separately opens SQLite read-only, runs integrity checks and validates payloads,
request sources, task identities/outcomes, explicit messages, actual action evidence, replies,
telemetry exclusion and omitted native result bodies. It does not accept a model's success
claim or an app receipt alone as proof that the action occurred.

Upgrade fixtures use the actual previous `sidekick.history` JSON format and old instruction
key. Seven cases cover UUID and older ID-less entries, success, failed/stopped/unfinished
work, unclassified legacy status, card origin, Unicode, dates and recovery errors. An actual
app launch with malformed legacy data must preserve the source, expose a storage error and
refuse a prompt without launching inference. Repair changes only that fixture preference;
the initialized database is not reset. Subsequent startup must migrate once. A later process
reopen must retain identical conversation state and adopt an external memory-file edit.
Preference inspection uses macOS's preferences service (`defaults export`) with bounded
expected-state checks: its physical plist file can lag an acknowledged preferences update.

Verified on 2026-10-16 with the development-signed app:

* **ChatGPT and Claude both passed: 12 accepted prompt submissions, 132 in-app checks**,
  plus the independent Python/SQLite validation. Both performed actual native text entry and
  a button click; neither used a shell/JavaScript substitute for the action.
* Each profile contained 7 migrated tasks and 6 new tasks after completion. ChatGPT retained
  63 events; Claude retained 61. Both had 5 explicit final answers and 1 stopped new task.
* Both databases passed integrity checks and remained semantically identical across process
  relaunch. Migration did not invent old answers or duplicate records. The malformed-source
  preservation/repair case passed in the ChatGPT profile.
* Telemetry activity was absent and native screenshot/AX result bodies were omitted. The
  two completed runs left no newly created `sentient-shot-*.jpg` capture files behind.
* External memory edits survived reopening and refreshed the settings mirror.

Artifacts are retained under the runner-printed `sentient-sidekick-app-*` directories:
stage logs/receipts, fixture inputs, actual SQLite/memory, independent snapshots and results.
This verifies the real submission functions and computer-use path on this configured Mac;
it does not claim physical typing/Return-key UI coverage, pristine-machine permission setup,
normal scheduler/updater startup, custom-provider acceptance, or real account mutations.

## Automatic compaction through the prompt path

`Scripts/test_sidekick_app_compaction.py` extends successful native acceptance profiles.
It clones only their disposable history, memory and whitelisted fixture preferences, using
SQLite's backup API. Authentication remains in the canonical runtime and the original proof
profiles are checked unchanged. Supply the two roots printed by `test_sidekick_app.py`:

```sh
python3 Scripts/test_sidekick_app_compaction.py --app "/path/to/Debug/Sentient OS.app" \
  --source-root "/path/to/sentient-sidekick-app-chatgpt-fixture" \
  --source-root "/path/to/sentient-sidekick-app-claude-fixture"
```

Each clone begins with 13 completed tasks and no summary. Five additional actual prompt-bar
submissions exercise the normal scheduler:

1. Three ordinary acknowledgment requests, without message-tool or STATUS hints. Each must
   save an explicit answer. At 14 and 15 tasks, the real debounce finishes without a summary.
2. After task 16 finishes and schedules compaction, task 17 starts immediately and asks a real
   Continue/Pause question. Its recovery field is held focused through the existing UI action
   while the worker runs. The same foreground task/question must remain active when the first
   summary is installed; the real Continue response must then complete that task successfully.
3. Task 18 receives the accepted summary in its actual `SidekickInteraction.historyContext`.
   It must recall the original project codename, earlier native verification code and current
   user-edited memory marker, without new native or script inspection or answers in the prompt.

The test observes the pending-work state through a read-only DEBUG getter. It never invokes
the compactor directly, substitutes its inference, changes thresholds or cancels work to make
the test pass. It waits for the worker to finish naturally and verifies complete coverage of
the eligible source prefix. Separate SQLite checks compare original event payload bytes,
summary boundaries/source references/timestamps, actual foreground intervals, the context
passed to the next prompt, unchanged memory, and a subsequent process reopen. Test windows
must remain visible, but history-only submissions do not require Sentient to own foreground
focus; ordinary Sidekick also works while another app is active.

Summary text is inspected as well as its structure. This caught an overconfident statement
that a failed read had never happened. The compaction prompt now explicitly states that a
missing result means no confirming result was recorded, and failed/stopped/interrupted status
does not establish that nothing was read, sent, changed or created. Original records remain
available for verification; summaries are not evidence of physical effects.

Final automatic-compaction acceptance on 2026-10-16 passed for **both ChatGPT and Claude**:
five additional normal prompt submissions and 60 in-app checks per provider, plus independent
SQLite verification. Each profile ended with 18 tasks and two contiguous summaries covering
sequences 1–6 and 7–10, exactly the eligible prefix while retaining the recent 15 tasks.
The first summary committed during the active foreground turn, and the real following prompt
received that accepted text. It correctly returned the earlier native verification code,
project codename and user-edited memory marker. Original event payload bytes, memory and the
source profiles were unchanged; relaunch preserved summaries and history without extra work.

Both providers were rerun after the uncertainty-instruction improvement. The final summaries
explicitly retained uncertainty about failed/stopped effects. The fixture validator checks
that property and rejects the earlier overconfident failed-read summary. The 65 deterministic
context/compaction assertions and the full Debug/Release builds also passed with the updated
instruction. These tests establish automatic scheduling, foreground continuity, summary
installation and delivery into subsequent context; they do not claim that natural-language
summaries are infallible or that this short fixture required relying exclusively on summaries.


## Conversation UI follow-up

`AppState.sidekickPresentation` owns the Home presentation, persistent in-process card model,
reading position, selection state and bounded transcript window. `SidekickConversation` owns
the shared draft, reply reference, navigation request and durable projection. Neither view
appearance nor animation completion controls provider execution or persistence.

Home has two presentations of the same conversation. Suggestions expose a history peek;
the cards gather into Proactive while history comes into focus. The composer stays anchored.
Sending an accepted request, opening a notch response, a live task/question, or new attention
selects conversation. Ordinary reopening restores the presentation; a safe first visit after
a fresh daily briefing can restore suggestions. A draft or active task defers that return.
The card model survives window and page changes; refreshing suggestions preserves live edits.

### Storage and rendering bounds

* Store transcript queries filter visible event kinds before limiting. Initial pages contain
  up to 40 records and 1 MiB of payload; the viewport keeps at most 100 loaded records.
  Earlier/later pages and exact-target neighborhoods preserve cursors and scroll anchors.
* UI search excludes checkpoints, activity and task-start payloads at the SQL boundary.
  Activity is read only through an expanded inline work header, in bounded pages. Telemetry is never a conversation row.
* Additive `read_events` receipts mark only incoming messages actually visible in active Home.
  The old read watermark remains compatible. Opening Home, viewing a peek, or an automatic
  notch preview does not consume an entire unread prefix. Reset removes receipts with history.
* Partial transcript/incoming/answer indexes avoid scanning tool-heavy histories for UI pages.
  Generation checks and request tokens reject stale loads/search failures after reset or a
  newer navigation request. Failed reads preserve the current page and existing database.
  Initial loading and explicit destinations share one cancellable navigation task. Automatic
  refresh yields to selection, scrolling, search and history navigation; a revision arriving
  during a page read remains pending until a current snapshot is loaded. Ending selection or
  returning to the bottom resumes deferred arrivals without requiring another message.
  An accepted Home send explicitly navigates to latest without reopening or activating a
  window. Explicit navigation takes precedence over reading position; automatic arrivals do
  not. Moving focus from selected history to the composer releases automatic-scroll protection.
* Native Foundation Markdown supplies CommonMark/GFM structure and source ranges. Native
  selectable text supports lists, quotes, code, horizontally scrolling tables and safe links.
  Parsing is cached (80 entries / 12 MiB); parsed input is capped at 64 KiB and 300 blocks.
  Longer original text remains available through an explicit disclosure. No remote images load.
* A selected range maps to an exact contiguous source substring, including inline formatting
  and Unicode. A small nonactivating Reply panel appears above it, without a context menu.
  It hides on scrolling, navigation, selection changes, window changes or view replacement.
  Whole-message Reply uses the same durable reference. The unrelated draft survives questions.

### Input and attention

`CommandCoordinator.submit` returns durable acceptance. `SidekickComposer.sendDraft` is the
single action used by Home and the signed-app acceptance lab. A rejected send preserves the
draft and quote. A running task permits drafting but does not silently queue a request.
Return sends; Shift-Return inserts a newline at the native editor's selection. Cmd-F opens
history search; Escape from Home editing/search does not cancel a preparing notch task.

High-priority committed messages request notch attention. Ordinary updates stay in history;
model instructions request a high-priority final note. `SidekickAttentionPolicy` separates
unread data from presentation opportunities: no replay on launch/Home closure, coalescing
while typing/questions/selection own attention, and generation-safe timers. Opening Home
or reading the previewed record clears its active notch presentation. Hover and text selection
pause retraction independently. Questions may retract but remain pending until answered,
explicitly stopped, or their underlying task ends. Home and notch resolve the same question.

The original fixed-canvas, top-flush, nonactivating panel and silhouette click-through rules
remain. Message height is bounded and cached; shell and pointer geometry share the same
measurement. Blur/scale reveals are interruptible. The pop-out opens the exact stored message.

### Visual and performance contract

Sentient's black identity is retained in either system appearance. Neutral surfaces and white
ink are accompanied by fine cached grain and clearly visible signature-color light near the
top. Solid-color blurred shapes drift slowly; there is no full-window purple theme. The
composer and controls use native Liquid Glass on macOS 26+, including system edge/reflection
behavior, with a neutral material fallback on supported older systems. Reading content stays
quiet; no animation rewrites text or simulates typing of an already complete answer.

One ambient clock runs at a reduced cadence and changes transforms of cached shapes. It
pauses for hidden/inactive surfaces, scrolling, text selection, Reduce Motion and Low Power
Mode. Direct transitions use native SwiftUI animation. Reduce Transparency uses opaque
surfaces; no independent animation clock is attached to every message.

### Reproducible UI acceptance

* `Scripts/test_sidekick_backend.py`: complete production storage, migration, run, memory,
  tools, context, lifecycle and diagnostics fixtures (no real provider).
* `Scripts/test_sidekick_markdown.py`, `test_sidekick_presentation.py`,
  `test_sidekick_attention.py`, `test_sidekick_notch_layout.py`: native rendering/source
  selection, navigation races, attention policy and geometry fixtures.
* `Scripts/test_sidekick_ui.py --app <signed-debug-app>`: isolated actual-app Home at 1100x820
  and 840x680, selections, replies, search, questions, accessibility and appearance variants,
  plus a real own-window motion recording. A reusable nonactivating Reply panel is verified
  without right-click. All content is synthetic; no provider task runs in this fixture.
* `SidekickNativeNotchLab`: the real physical NSPanel, interrupted and completed retracts,
  fixed canvas, top alignment, focus preservation, pending-question retention, and cleanup.
  Metadata records whether the current display really has a hardware cutout.
* `Scripts/test_sidekick_app.py --app <signed-debug-app>`: actual Codex/Claude requests through
  the new composer's submission action, native computer-use fixture, follow-ups, questions,
  Stop, memory, migration and reopen, independently verified against SQLite.

Rendering uses ScreenCaptureKit restricted to exact current-process windows. Ordinary
`cacheDisplay` omitted GPU-backed SwiftUI content and is not accepted as visual evidence.
The optional selected-text capture includes only the validated owned Reply child panel.
The native-notch raw alpha capture is retained; its review PNG is composited over black so
image viewers cannot exaggerate transparent glow pixels. Motion recording has bounded frame
buffering, no audio/cursor, explicit completion/timeouts, and frame/drop metadata. The tests
never change system permissions or capture unrelated windows. All lab entries and controls
are compiled out of Release.

### UI acceptance status — October 17, 2026

The black, textured, top-lit Sentient presentation and automatic selected-text Reply are
implemented. Debug and Release builds succeeded. `git diff --check` is clean.

* Offline: 1,249 assertions passed (890 backend, 153 presentation, 142 Markdown,
  44 attention, 20 notch-layout). This includes migration, storage, memory/context,
  diagnostics, stale-generation/navigation races and concurrent-arrival handling.
* Signed actual-app UI: all 60 checks passed, with 17 state snapshots and the physical
  notch panel on a display with a hardware cutout. Exact selection quoting, floating
  Reply/focus, search keyboard focus, initial deep links, explicit return to latest,
  composer answers, draft retention, accessibility variants and appearance were checked.
  The final own-window motion recording wrote 240 frames over 4.23 seconds with zero
  writer-backpressure drops. This is recording evidence, not a whole-app FPS benchmark.
* Final-build ChatGPT: six actual requests passed through `SidekickComposer.sendDraft`,
  including native typing/clicking, context-only recall, question/answer, Stop, post-Stop
  recall and a selected-quote reply. Seven legacy tasks and relaunch/storage/memory
  preservation were independently verified. Malformed-source migration/repair also passed.
* Remaining: the final-build Claude end-to-end rerun. An earlier UI build passed the full
  six-request Claude suite. The latest attempt failed on the first native app-state read
  with `NativeComputerUseFailure.timeout` (`-10005`); it is not counted as a pass. The user
  reported unreliable in-flight internet and deferred retry until landing. That timeout
  classification alone does not establish a network cause. No provider test is running.

Final UI evidence is under
`/private/tmp/sentient-sidekick-ui-capture-retry/sentient-sidekick-app-ui-aavo41ha`.
Final-build ChatGPT evidence is under
`/private/tmp/sentient-sidekick-ui-provider-resumed/sentient-sidekick-app-chatgpt-7ibvxvjg`;
the adjacent Claude fixture `sentient-sidekick-app-claude-vh8pvy9x` retains the failed attempt.
Manual fixture closures were recorded as aborts. One unlocked ScreenCaptureKit attempt
returned `-3811`; a fresh-process retry passed all UI checks without relaxing capture or
content assertions. Live rendering was tested on this Mac (macOS 27); the older macOS
material fallback was compiled, not exercised on an older OS.

After landing, rerun only the pending provider against the final signed Debug build:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 Scripts/test_sidekick_app.py \
  --app '/tmp/sentient-sidekick-ui-debug/Build/Products/Debug/Sentient OS.app' \
  --provider claude --skip-migration-failure \
  --artifacts /tmp/sentient-sidekick-ui-claude-after-landing
```

The separate malformed-migration probe is skipped here because it already passed on the
final build; ordinary migration and reopen verification remain part of this Claude run.

### Overview polish follow-up — October 17, 2026

Subsequent UI-only changes replace overlapping percentage-positioned cards with measured
spreads: up to two columns in smaller windows and three in wide windows, two rows when
their actual heights fit, otherwise a pager. The normal 1100×820 fixture shows four cards,
840×680 shows two, and 1440×900 shows six. No text is scaled down to force a fit. Multiline
cautions participate in the measured header so they cannot cover cards or transcript text.

The Proactive button now exists only while cards are collapsed. It has a stable invisible
layout anchor for their staggered upward morph; chat reveals slightly later to avoid two
layers of readable text competing during the transition. A local, own-window scroll policy
collapses the overview on deliberate upward input, ignores the composer and unrelated
windows, and consumes only that gesture's momentum. Background-window scrolling is supported.
Coalesced mouse-wheel input and precise trackpad input have separate distance thresholds.
Hidden pages are excluded from both hit testing and the accessibility tree.

Colored shapes now travel farther, rotate and breathe on shorter cycles, using the same
single 18Hz clock/cached shapes. Pausing freezes their phase; resuming no longer jumps to
a wall-clock-derived position. Reduce Motion and Low Power retain a static atmosphere.

Validation for this follow-up:

* `test_sidekick_overview_layout.py`: 480 geometry configurations / 9,769 assertions passed,
  covering card counts, variable measured heights, safe spacing, paging, resizing and page clamps.
* `test_sidekick_overview_scroll.py`: 97 assertions passed, including natural-scroll inversion,
  coalesced wheels, precise thresholds, reversal, horizontal input, scope and momentum release.
* Signed UI fixture: 60 checks passed and 21 rendered states were captured. Visual review included
  narrow/normal/wide overviews, long cautions in overview/chat, selection, and the physical notch;
  the suite also covers accessibility and appearance variants.
  The latest 4.24-second motion recording wrote 240 frames with no writer-backpressure drops.
* Live CUA inspection confirmed Proactive disappears on expansion, paging exposes all six
  suggestions while hidden pages disappear from accessibility, upward scrolling on either page
  opens chat, subsequent chat scrolling works, and composer scrolling does not collapse cards.
* Debug and Release builds succeeded; `git diff --check` is clean. No provider calls were made
  in this follow-up, per the user's request to defer the full provider suite.

Current rendered evidence:
`/private/tmp/sentient-sidekick-overview-final/sentient-sidekick-app-ui-c1ylzddd/ui-snapshots`.
The live-interaction fixture and receipts are under
`/private/tmp/sentient-sidekick-overview-interaction/sentient-sidekick-app-ui-3difumxx`.
For manual inspection, `test_sidekick_ui.py --hold-seconds 600` keeps the isolated, provider-disabled
preview open. Creating `ui-hold-complete` inside that owned fixture resumes its remaining checks.

### Conversation chrome refinement — October 17, 2026

Message rows no longer repeat Sidekick, timestamps, reply icons or Done/Steps controls.
Copy and a context-aware date appear in a reserved hover gutter on both user and assistant
messages, without shifting layout. Copy/Reply are also context-menu and accessibility actions.
The native selectable renderer retains Copy-selection and floating Reply-to-selection, plus
whole-message Copy/Reply actions; copying uses the complete original source, including content
beyond the Markdown parser's rendering cap.

`SidekickTranscriptLayout` derives visible rows without changing persisted events. It emits
one work header per visible task, removes redundant terminal footers, preserves standalone
stopped/failed/legacy outcomes, and remaps hidden terminal search destinations to their visible
response. Time breaks occur on human messages after a strict 30-minute gap, not on a slow answer.
Date formatting accounts for the local calendar, year and DST. Only an explicitly recorded
user stop is labelled Stopped by you; other cancellations remain Stopped.

`transcriptTaskStates` now returns startedAt and hasActivity through the existing bounded bulk
snapshot query. It never decodes activity payloads or adds a schema migration. Missing starts
and the existing legacy-start namespace yield unknown duration: legacy conversion copied one
date to both start/end and cannot establish execution time. Presentation retains metadata and
expanded task IDs only for its bounded loaded page. Metadata-only refresh preserves rows,
scroll position and explicit navigation, with cancellation/revision/generation fences.

`SidekickWorkDisclosure` expands in the normal layout. It lazily reads up to 40 activity events
per page, coalesces lifecycle pairs off the main actor, exposes human labels/app icons, and
keeps raw details in nested inline disclosures. Empty/failed loads remain recoverable. Failure
explanations stay available even without recorded tools. Only a visible running task updates
its elapsed label every second; no clock is attached to every historical message.

The synthetic UI fixture now contains eight explicitly identified activity records (four
operations), a meaningful time gap, hover captures and an inline expansion capture. These
are fixture data, not executed app actions; provider_calls remains zero. The review build
passed 63 actual-app UI checks with 24 captured states. CUA verified opening/closing activity,
scrolling through its steps, nested details, whole-message right-click Reply, selected-text
Reply, exact quote scope and draft retention.

Review evidence:
`/private/tmp/sentient-sidekick-chat-review/sentient-sidekick-app-ui-jyfjv0d5`.
Debug and Release builds of the finished code succeeded. The final capture attempt was
blocked by the Mac locking (`screenLocked`, before fixture messages were seeded); it is
retained at `/private/tmp/sentient-sidekick-chat-final/sentient-sidekick-app-ui-g365igpw` and
must not be counted as a visual pass. A final unlocked capture remains pending.

### Home navigation and suggestion dismissal — October 17, 2026

Home no longer advertises AI knowledge connections. Knowledge's header now has a quiet labeled
Use with your AIs action in both Constellation and Reader. It opens the existing optional setup
explanation without navigating away from a note or changing the sharing state. The existing
ConnectAIsView remains the only owner of consent and connection controls.

Proactive cards reveal a small upper-left X on hover. Its extended hover region does not alter
the measured card size. Context-menu and accessibility Dismiss suggestion actions use the same
existing dismissal path; a running task continues independently of its card. A source review
identified and fixed a delayed-envelope race: the opening delay now cancels with view lifetime,
and its callback checks current entry existence and dismissal state before opening the letter.

The isolated UI fixture now also requests a hovered-card capture (25 total expected states).
The latest Debug and Release builds pass, the runner parses successfully, and `git diff --check`
is clean. The Mac remains locked and
Xcode Preview timed out, so the new Knowledge placement, pointer-to-X hit test, envelope rapid
dismissal, and final chat capture still require an unlocked live review. No provider tests were run.

### Full validation resumed — October 17, 2026 (desktop portion blocked)

The user authorized rerunning the complete suite. The identified Codex Computer Use helper was
terminated before testing; no testing-agent computer-use calls were made afterward. macOS still
reported the session locked, so native action and visual stages were not launched or counted as passes.

Fresh current-source results under `/tmp/sentient-full-validation-20261017`:

- 17 deterministic backend/rendering/state/layout suites passed, totaling 11,354 assertions
  (including 9,769 overview geometry assertions across 480 configurations).
- Real ChatGPT direct, Claude direct, and Claude bridge fixtures passed. The bridge exercised its
  synthetic native endpoint, not a real desktop action. Real default compaction ran concurrently
  with direct foreground work: measured overlap 8,105 ms for ChatGPT and 6,888 ms for Claude.
  These provider and compaction fixtures passed 80 checks in total.
- Signed-app headless seed → malformed migration → repair passed 26 app checks and 11 independent
  checks. The old source was retained, no tasks/events or memory were created, repair restored exact
  source bytes, and database semantics were unchanged. This is not a successful-import/relaunch test.
- Owned-process, parser, and deterministic local Codex endpoint fixtures passed 54 checks after
  improving the DEBUG-only receipt classifier. The previously unknown notice is confirmed as an
  unadvertised fast service tier being omitted for the synthetic model catalog. No production tier
  settings or pass/fail rules changed, and no raw provider error text is retained. The parser now
  tests complete, incomplete, and unrelated notices. Real-provider fixtures recorded zero error events.
- Rebuilt signed Debug app passed; the runner also rejected the Release app without launching it.
  Provenance confirms the only code change during this pass was the DEBUG receipt classifier/tests.

Still required after unlock: both providers' actual six-request composer/native acceptance runs,
their five-request automatic-compaction/reopen extensions, the 25-state Home/notch UI fixture, and
live review of Knowledge placement and card dismissal. `progress.json` distinguishes these pending
checks from the passes above; receipts, source/binary hashes, logs and failed-warning investigation
evidence are retained beside it. No production conversation or memory was changed.

### Settings transition — October 17, 2026

Added a scoped Home ↔ Settings reveal from the Home gear anchor. SwiftUI owns reversal/removal;
Home's state stays mounted and the composer releases focus/ignores hidden Return submissions.
Knowledge presentation and its unsaved-edit guard remain separate. `MainNavigation` now records
actual route pairs and ignores a delayed Knowledge approval after navigation reset.

`Scripts/test_settings_transition.py` compiles complete production geometry/navigation types:
2,997 checks pass, including bounds, overshoot, resize, missing/invalid anchors, route restrictions,
pane deep links, deferred approval/cancel, and reset fencing. The actual-app UI fixture now also
captures Settings opening/open/closing, restored Home and Reduce Motion, records a reversible
Settings motion clip, and checks draft retention and hidden composer focus. Its expected image
count is 30. The optional manual hold now runs in the actual retained RootView shell after the
automatic captures, so Settings and Knowledge navigation are available in that preview.
These new native captures remain pending while the Mac is locked; geometry tests are not a
claim that the final animation or pointer/focus behavior has been visually verified.
Final signed Debug and Release builds passed; `git diff --check` is clean. Build logs, focused
test output and source hashes are recorded in `/tmp/sentient-settings-transition-validation/result.json`.

### Unlocked native validation and legacy compaction fix — October 17, 2026

The identified external computer-use helper was stopped before the native run. The first Claude
attempt used the ambiguous display name Sentient OS while multiple instances were running and
timed out before any action. Exact-path model-free capture passed. The acceptance prompt now
requires the fixture's absolute bundle path on every native call, and both Swift and independent
Python validation enforce it. No production transport or target-selection behavior was bypassed.
Both providers then passed six actual composer requests each, real native text entry/click/token
verification, history-only follow-up, question/answer, Stop, selected reply, migration and reopen.
The two profiles contain 7 legacy + 6 actual tasks each (61 Claude / 63 ChatGPT events). The source
profiles passed 134 stage checks and 134 separate read-only SQL/artifact audit assertions.

The first app compaction extension exposed a real semantic defect: a model summary of legacy
failed-read status acknowledged missing evidence but then asserted the note had not been read.
The independent checker rejected that run even though the structural app checks passed.

`SidekickContext.legacySummary` now extracts the maximal bounded leading run of complete imported
tasks with exact legacy start/request/end IDs and only checkpoint records between them. It keeps
the literal typed records, source IDs, times and recorded outcomes under a fixed evidence-limit
label: effects are unconfirmed; app status is not proof an action did or did not occur. It batches
whole tasks with useful literal excerpts, accounts for actual JSON/UTF-8 size, and marks shortened
fields explicitly. Unfit metadata leaves the watermark unchanged, with no inference fallback.
Mixed prefixes compact the legacy portion first; rich conversations still use model inference.
The existing generation/source fences, cancellation, atomic installation and original records are
unchanged. Compaction telemetry adds the existing aggregate `migrated_tasks` count for this path;
no message content is logged.

All nine backend suites passed again, including 160 context/compaction assertions (up from 65).
The regression supplies a contradictory fake summarizer and proves it is never called for legacy
data; mixed prefixes, exact evidence, byte/task boundaries, refusal, stale/reset and cancellation
remain covered. Fresh actual-app extensions passed five additional requests per provider and
120 stage checks. Both ended with 18 tasks and contiguous summaries covering 1–6 and 7–10;
all 10 extracted records match their originals exactly. A separate read-only audit passed 140
assertions across both clones. Original events/source profiles, user-edited memory and reopened
state are unchanged. The accepted first summary was present in the following real interaction
context, and the response recalled the prior code, native token and memory marker correctly.

Limits of that evidence: extraction installed during a running foreground task, before its
question appeared; it was observed while that question was pending. Short original exchanges
also still fit in context, so recall is not proof of exclusive reliance on a summary. These
extensions now test deterministic legacy extraction, not an LLM call. Separate real rich-history
compactor + foreground fixtures passed 30 checks per provider, with measured concurrent execution
overlap of 7,629 ms (ChatGPT) and 5,104 ms (Claude).

Evidence lives under `/tmp/sentient-full-validation-20261017`: `native-exact-target`,
`compaction-fixed`, `providers/*-rich-pair-result.json`, and the respective independent audit JSONs.
The initial failed runs remain under `native` and `compaction`; they are not counted as passes.
macOS relocked after the provider checks. The 31-state visual fixture (now also checking the empty
retry box), both motion clips and live interaction review remain pending until the next unlock.

### Final visual acceptance — October 17, 2026

Completed the unlocked visual pass and repeated it after refinement. Final evidence:
`/tmp/sentient-full-validation-20261017/ui-final/sentient-sidekick-app-ui-7dv_d2s9`.
The signed actual-app fixture passed 69 checks and independent PNG/database validation, with
31 captured states, 49 synthetic tasks, 205 synthetic events and zero provider calls. Home and
Settings motion clips completed with 230 and 231 written frames respectively, zero writer
backpressure drops and zero unavailable frames after capture began. These bounded recordings
are visual/capture evidence, not a full app frame-rate benchmark.

Live CUA review verified card reflow/dismissal, an envelope opened then immediately dismissed
without a later letter reopening, upward scroll into the Proactive dock, inline activity expansion,
whole-message Reply and exact selected-word floating Reply without right-clicking. Draft and
reading position survived Settings navigation. Knowledge's optional AI entry fits both graph
and reader, including the full Back/Edit/Trash/Reveal header. Its popover preserves unsaved notes;
the Home navigation Save/Discard/Cancel guard and Cancel preservation were exercised on synthetic
notes. The empty retry input and hover-only message chrome were also reviewed in the captures.

This pass found and fixed an AppKit/SwiftUI interaction gap: native text from the invisible
transcript could still appear in the overview's accessibility tree. The retained transcript now
disables interaction and ignores its accessibility subtree; native text views honor enabled state
for hit testing, focus, menus and queued reply actions, while preserving text/selection. The final
live overview exposes only its cards/composer, and chat restores the native actions correctly.
Fifteen focused regressions were added (175 Markdown checks now pass). The optional AI popover's
footer contrast was also raised after visual review. A suspected missing-text animation artifact
was inspected at original resolution and retracted; the source frames are intact.

Final Debug and Release builds passed. The fixture finished its integrity checks and closed;
the testing agent's computer-use helper was terminated so it cannot block Sentient. All test
results, retained failures/fixes, source/binary fingerprints and the 18-item live/capture review
are indexed by `/tmp/sentient-full-validation-20261017/progress.json`. No production conversation,
memory, account connections or source preferences were changed, and nothing was shipped.
