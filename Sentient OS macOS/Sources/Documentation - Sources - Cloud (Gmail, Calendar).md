# Sources: Gmail and Google Calendar (Sources/)

The two cloud sources. Neither can be read on-device, so Sentient both **fetches and summarizes** them
through the user's own Codex connectors (OpenAI's account-level `codex_apps/gmail.*` and
`codex_apps/google_calendar.*` tools, reached by `codex exec`). No on-device model touches them, and no
Sentient server is involved. Both ride the ChatGPT-account auth inside codex, so they only exist on the
ChatGPT backend (locked chips on a custom frontier model and on free/go plans).

## Files

| File | Job |
|---|---|
| `GmailConnect.swift` | The Gmail source: connect probe, the initial read (4 weekly summaries in parallel), the iterative read (since the mark), and the disciplined weekly prompt. |
| `CalendarConnect.swift` | The Calendar source: connect probe, the initial read (12 monthly summaries), the iterative read, and `fetchProactiveContext()` (the live calendar block both proactive stages receive). |
| `Views/CloudConnectSheet.swift` | The one connect sheet both sources share (in `Views/`). |

Writes (send an email, create an event) do NOT live here; they are `ProactiveExecutor`'s gmail and
calendar channels (see the Proactive doc).

## Connecting

`CloudConnectSheet(.gmail)` / `.calendar` is reachable from Settings → Knowledge Sources, the home's
Analysis popover, onboarding's ready screen, and Dev Tools. Flow: **Connect** opens OpenAI's hosted
connector page (`GmailConnect.connectorURL` / `CalendarConnect.connectorURL`) where the user links
Google; **Done** waits 1 s, then runs `probeConnected()`, a `codex exec` (`gpt-5.6-luna`, low effort,
read-only) that must reply exactly YES or NO. YES persists `dbg.gmail.connected` + `dbg.run.gmail`
(calendar twins), shows a green beat, and auto-dismisses; NO shows a quiet retry line. The "Stop
reading …" link fully disconnects (both flags cleared); reconnecting is the whole flow again.

## How reads work

Both sources produce one ephemeral `CycleNote` per window in their own bucket (`gmail` / `calendar`),
which the knowledge-base build/update treats like any other summary. The bucket pointer is set to the
run start; a little overlap next run beats a boundary gap.

**Gmail**
- `runInitial`: the last month as **4 weekly `codex exec` calls, fired in parallel** (a task group; the mark is set once all four finish; any failure aborts so a retry re-runs all four). Weekly chunks keep each call's context bounded (a heavy inbox is ~430 threads a week).
- `runIterative`: one call covering everything since the mark (`after:<epoch>`), then the mark advances. Falls back to initial when Gmail has never been read.
- The weekly prompt is deliberately disciplined because codex over-reads: search on metadata and snippets, consider at most the newest 300 threads, open only the handful that look genuinely important, and never newsletters or receipts. Output is a structured reply (`--output-schema`): `{thread_count, notable, has_action_items, summary}`, with an explicit action-items section that the proactive judge can mine. `notable: false` means a quiet week (nothing recorded, no diagnostic); a reply that will not parse or lacks the `notable` key is a shape mismatch and emits `gmail.parse.shape_mismatch`.

**Calendar**
- `runInitial`: the last **year** as **12 monthly calls**, newest month first, past-only (future events belong to the proactive fetch, not the knowledge base). Each summary keeps only what matters (real meetings, interviews, trips, appointments, deadlines) and drops standups, "Lunch", focus-time blocks, and declined events. Reply: `{event_count, notable, has_action_items, summary}`.
- `runIterative`: events with a start time in `[mark, now)`.
- **`fetchProactiveContext()`** is separate and deliberately uncurated: the last 7 days plus the next 24 hours, every event, as a compact chronological text block (`{connected, events_text}`). `ProactiveCycle` fetches it once and injects it into both the judge and the research prompts, so the judge can reason about time-sensitivity while staying tool-free.

Models: `gpt-5.6-luna` for every read (medium effort; low for the connect probe), read-only sandbox,
web search off for calendar. Sending an email or creating an event runs on the default `gpt-5.6-sol`
in the executor.

## Facts worth knowing

- The connectors are account-level, so they work whether or not the user's `~/.codex` config is loaded (`includeUserConfig`).
- OpenAI strict output schemas need `additionalProperties: false` on the object and every property in `required`, or codex fails with `invalid_json_schema`.
- Read tools pass under the read-only sandbox. Only the WRITE tools (`send_email`, `create_event`) are approval-gated headless; the executor pre-approves them per run with the sandbox intact (`CodexCLI.Invocation.approveConnectorWrites`).
- Progress events (`GmailConnect.Progress`, `CalendarConnect.Progress`) map each window onto the same bar and "just processed" card `ProcessingView` shows for on-device items; the Gmail windows arrive in completion order because they run in parallel.

## Related docs

`Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md`, `Proactive/Documentation - Proactive Intelligence.md` (the calendar context and the write channels), `Cloud/Documentation - Cloud - Plan Gate (CodexAuth).md` (why the chips lock).
