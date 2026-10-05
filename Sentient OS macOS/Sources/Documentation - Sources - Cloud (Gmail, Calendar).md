# Sources: hosted Gmail, Calendar, Slack and Outlook (Sources/)

These are the **hosted-connector paths** for Gmail and Google Calendar. Sentient both fetches and
summarizes them
through the user's own hosted connectors, per engine: on the ChatGPT backend, OpenAI's account-level
`codex_apps/gmail.*` / `codex_apps/google_calendar.*` tools reached by `codex exec`; on the Claude
backend, the **claude.ai Gmail and Google Calendar connectors** reached by `claude -p`
(`mcp__claude_ai_Gmail__*` / `mcp__claude_ai_Google_Calendar__*` — the ClaudeCLI doc's connector
section). No on-device model touches them, and no Sentient server is involved. They ride
subscription-account auth, so the chips lock on a custom frontier model and on free/go ChatGPT plans.
All runs go through `FrontierRun`, so this file's prompts and parsing serve both engines unchanged.

For locally analyzed email and calendar instead, choose **Apple Mail and Apple Calendar**. Those
read data already synced to the Mac and work with any supported frontier backend, without a
ChatGPT or Claude subscription. Gmail or Google Calendar data can be available locally through those
Apple apps; “hosted” here describes this connector path, not an inherent property of the service.

## Files

| File | Job |
|---|---|
| `GmailConnect.swift` | The Gmail source: connect probe, the initial read (4 weekly summaries in parallel), the iterative read (since the mark), and the disciplined weekly prompt. |
| `CalendarConnect.swift` | The Calendar source: connect probe, the initial read (12 monthly summaries), the iterative read, and `fetchProactiveContext()` (the live calendar block both proactive stages receive). |
| `MCPSource.swift` | Shared hosted-source orchestration, bounded retries, privacy filtering and atomic summary/checkpoint commits. |
| `SlackSource.swift` | Slack's bounded discovery, selected-thread reads and native receipt validation. |
| `OutlookMailSource.swift` · `OutlookCalendarSource.swift` | Outlook's source-specific windows, evidence validation and inspected-item counts. |
| `Views/CloudConnectSheet.swift` | The one connect sheet both sources share (in `Views/`). |

Writes (send an email, create an event) do NOT live here; they are `ProactiveExecutor`'s gmail and
calendar channels (see the Proactive doc).

## Connecting

`CloudConnectSheet(.gmail)` / `.calendar` is reachable from Settings → Knowledge Sources, the home's
Analysis popover, onboarding's ready screen, and Dev Tools. Flow: **Connect** opens the ENGINE'S
connector page (`GmailConnect.connectorURL` / `CalendarConnect.connectorURL` pick per backend:
OpenAI's hosted connector page on ChatGPT, claude.ai's connector directory on Claude; the sheet's
copy follows, and the sources group header reads "Through Your ChatGPT" / "Through Your Claude")
where the user links Google. Calendar's **Done** saves the user's declaration and selects the source.
Gmail's **Done** reads and saves the connected email address directly: Codex discovers the address from its
connector metadata; Claude Gmail reads one sent thread's metadata directly, without a model turn.
The connection flow discloses cloud storage inline before Done; no additional popup appears. One distinct sender from messages marked
SENT is saved automatically. Empty, ambiguous or unavailable results are skipped without asking for
an email address. A missing connection returns to the picker without being marked linked.
No message bodies, subjects or snippets are requested by this address-collection step. Only the
email address is queued in Keychain until the feedback list accepts it; connector metadata is not
retained in that list. “Stop reading” turns off knowledge selection; it does not unlink the provider
or remove an address from the founder-feedback list.

Outlook Mail's connector popup uses the same automatic collection flow on Done, reading Codex metadata or Claude
Microsoft 365 `get_me`. Email-only storage, access controls and retention are documented in `Cloud/Mail Accounts/Documentation - Connected Email
Accounts.md`. Message ingestion and its existing per-run identity checks remain independent.

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

Models: the luna tier for every read (`gpt-6-luna` on codex, `haiku` on claude; medium effort, low
for the connect probe), read-only sandbox, web search off for calendar. Sending an email or creating
an event runs on the flagship tier in the executor.

## Slack and Outlook knowledge reads

These sources use `MCPSource` on the selected subscription backend. Slack samples recent messages;
Outlook Mail initially reads four weekly windows, and Outlook Calendar reads twelve monthly windows
on the default calendar. Each connector commits its summaries and checkpoint together only after
every window succeeds. A failed read leaves existing notes and progress available for retry.

Slack requires every attempted search and selected-thread read to succeed. A quiet result also
requires all three discovery lanes. Search result content is decoded separately from pagination
metadata, and only a complete empty-page response establishes zero results. Words quoted inside
messages do not change the discovery count.

Privacy filtering discards the entire sensitive summary before storage or display while preserving
only its anonymous inspected-item count. Source-specific validation still runs; Outlook Calendar
requires that count to match the events in the native receipts, including for a quiet result.

The processing card retains a useful summary when a later committed window is quiet. Starting a new
source or run resets that card, so an earlier summary cannot imply success for a new read.

## Facts worth knowing

- The connectors are account-level on both engines, so they work whether or not the user's own CLI config is loaded (`includeUserConfig`).
- OpenAI strict output schemas need `additionalProperties: false` on the object and every property in `required`, or codex fails with `invalid_json_schema`.
- **codex:** read tools pass under the read-only sandbox; only the WRITE tools (`send_email`, `create_event`) are approval-gated headless, and the executor pre-approves them per run with the sandbox intact (`CodexCLI.Invocation.approveConnectorWrites`).
- **claude:** headless, EVERY connector call is denied unless an allow rule names it (measured 2026-08-23 — auto mode denies them too), so the probes and reads set `Invocation.claudeConnectorReads`, which pre-approves the curated read-only tools (`ClaudeCLI.ConnectorTools`); write tools stay structurally denied on read runs. The executor's fires map `approveConnectorWrites` to a scoped allow.
- Progress events (`GmailConnect.Progress`, `CalendarConnect.Progress`) map each window onto the same bar and "just processed" card `ProcessingView` shows for on-device items; the Gmail windows arrive in completion order because they run in parallel.

## Related docs

`Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md`, `Cloud/Documentation - Cloud - ClaudeCLI (the claude -p engine).md` (the claude.ai connectors and the read allow rules), `Proactive/Documentation - Proactive Intelligence.md` (the calendar context and the write channels), `Cloud/Documentation - Cloud - Plan Gate (CodexAuth).md` (why the chips lock).
