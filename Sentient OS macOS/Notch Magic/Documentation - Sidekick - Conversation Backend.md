# Sidekick conversation backend

One durable local conversation connects Home, the notch, voice and user-started proactive cards.
The app owns conversation history and task lifecycle independently of provider processes. Codex,
Claude and supported custom providers continue through the existing frontier dispatch and tool policy.

## Files and ownership

| File | Responsibility |
|---|---|
| `SidekickConversationStore.swift` | SQLite/WAL transactions, event identity, legacy migration, queries, read state, reset generations and interrupted-task recovery. |
| `SidekickConversationRun.swift` | Durable messages and questions, sanitized activity, interruption context and final-answer fallback. |
| `SidekickConversation.swift` | Observable projection, draft/reply/navigation state, teardown and the single background compaction job. |
| `SidekickConversationTools.swift` · `SidekickToolServer.swift` | Explicit messages, history search/read, questions, memory and idempotent RPC handling. |
| `SidekickContext.swift` · `SidekickCompactor.swift` | Recent exchanges, quoted replies, older summary segments and isolated summary generation. |
| `SidekickInstructionStore.swift` · `SidekickPersonalization.swift` | Editable Markdown memory, migration, atomic saves and conflict handling. |
| `CommandRunModel.swift` · `CommandCoordinator.swift` | The shared task owner, Stop/drain, outcome recording and adopted card tasks. |
| `Diagnostics/SidekickDiagnostics.swift` | Bounded categorical diagnostics without conversation or memory contents. |
| `Views/Sidekick/` | Conversation presentation, Markdown, composer, activity disclosure and retained reading state. |

## Storage and migration

The store is `Application Support/SentientOS/Sidekick/Conversation.sqlite`; the adjacent
`SidekickMemory.md` holds editable instructions. Events carry stable IDs, task and attempt IDs,
sequence numbers and bounded payloads. Transactions persist accepted messages before the app
acknowledges delivery. Identical retries are idempotent; changed payloads under an existing ID fail.

Legacy saved requests and outcomes migrate once, preserving available facts without inventing old
answers. Unfinished tasks recover as interrupted. Old questions remain historical after restart;
they cannot recreate live continuations or restart actions. Corrupt or newer-schema stores report an
error rather than being overwritten as empty history.

Visible conversation text comes from explicit user-facing messages. Activity retains bounded,
sanitized tool details. Native computer-use and arbitrary command result bodies are metadata-only;
screenshots, accessibility trees, raw reasoning and opaque shell output do not become another
conversation transcript. Questions, actual answers and uncertain interrupted operations preserve
continuity separately.

## Task lifecycle and completion

All requests use the existing app-owned execution lock. A proactive card adopts that same task owner;
view disappearance cannot discard execution or its outcome. Stop cancels owned work and holds the
lock until cleanup drains. It retains factual partial state and does not invent success for an
unconfirmed external action.

`message_user` persists an update or answer. Final answers may provide `completion=done|could_not`;
the final STATUS sentinel remains a compatibility fallback. Message delivery and task success are
separate. Completion is resolved only after a clean provider termination and applicable connector
action-evidence checks. Contradictory refusal wins; later substantive work invalidates an earlier
completion claim. Failed saves and cached retries cannot revive stale claims.

Questions and actual answers persist with stable references. Historical content and summaries are
context, never new authorization. Missing-answer fallbacks describe only the observed outcome.

## Context, compaction and memory

Each new task receives current memory, bounded recent exchanges, relevant task outcomes and older
summary segments. Reply references identify a stored message and optional exact quote. Search/read
tools can recover older text. Original visible history stays on disk when context is summarized.

One debounced background worker summarizes completed prefixes. It uses tool-disabled provider
execution without foreground messaging, app-control or connector capabilities. A validated summary
installs only if its source sequence and store generation are still current. Newer messages remain
exact. Failure, quota or slow inference leaves the previous summary and bounded recent history usable;
foreground tasks do not wait for compaction.

The main agent and Settings edit the same plain Markdown memory file. Migration preserves prior
instructions; saves are atomic and detect conflicting edits. A saved memory change survives a later
failed or stopped task. Factory reset preserves this user setting; full uninstall removes app-owned
local data.

## Presentation and clearing

Home and notch use the same committed state. Read watermarks reflect what the user viewed.
Questions and final responses request attention when their conversation is not visible; ordinary
progress stays quiet. Drafts, reply references and reading position survive page transitions.

Clear chat uses exclusive conversation maintenance: cancel pending submissions and compaction,
stop/drain the active task, then transactionally clear history, summaries and read state. A stop
timeout preserves data. Reset rotates the store generation and marks legacy import consumed, so
late writes or old defaults cannot recreate erased history. Clear chat preserves knowledge and
`SidekickMemory.md`. Factory reset and uninstall share the same generation safeguards.

## Verification

From the repository root, with Xcode's developer tools selected:

```sh
python3 Scripts/test_sidekick_backend.py
python3 Scripts/test_agent_completion_envelopes.py
python3 Scripts/test_sidekick_presentation.py
python3 Scripts/test_sidekick_markdown.py
```

The backend runner executes nine production-code suites covering storage, transcript projection,
migration, run recording, memory, tools, context, lifecycle and diagnostics. Fixtures use temporary
files/databases and inert external collaborators. They exercise failure injection, retry identity,
interrupted work, reset races, context bounds and reporting boundaries.

The signed Debug app also provides isolated UI fixtures through `test_sidekick_ui.py`,
`test_sidekick_clear_ui.py` and `test_sidekick_polish.py`. Pass `--app` with an isolated,
development-signed build. These fixtures create synthetic history and app-owned windows, prohibit
provider calls, independently inspect saved state and capture their own windows. The polish runner
supports `--small-onboarding`, `--invitation` and `--discovery` for focused layouts and controls.

Live-provider and native-helper acceptance are separate from offline fixtures and may require a
signed app, an authenticated provider and macOS permissions. Run them only in a deliberately isolated
profile. A successful compilation or deterministic fixture does not establish live-service, upgrade,
physical keyboard or overnight-wake acceptance.

## Related documentation

See `Documentation - Sidekick - General.md`, `Documentation - Sidekick - Notch Window & Visual.md`,
`Driver/Documentation - Native Computer Use.md`, `Ingestion/Documentation - Ingestion Pipeline.md`
and `Diagnostics/Documentation - Diagnostics (Sentry & TelemetryDeck).md`.
