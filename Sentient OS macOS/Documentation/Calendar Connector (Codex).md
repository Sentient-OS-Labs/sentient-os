# Calendar Connector (Codex)

Google Calendar is the **second cloud source** — a twin of Gmail (see `Gmail Connector (Codex).md`). It
can't be read on-device, so we both **fetch and summarize** it through the user's own **Codex Google
Calendar connector** — OpenAI's account-level `codex_apps/google_calendar.*` tools (`get_profile`,
`search_events`, `read_event`, and the write tools `create_event` / `delete_event`), reached by
`codex exec`. No on-device model touches the calendar.

Code: `Ingestion/CalendarConnect.swift` · UI: `Views/CalendarConnectSheet.swift` + the Calendar chip in
`Views/Dev/DevToolsView.swift`. The add-event **write** path is separate — `ProactiveExecutor.fireCalendar`.

## How a user connects
1. **Calendar chip** in the dev SOURCES grid → opens the connect popup.
2. **Connect Calendar** → opens OpenAI's hosted connector page
   (`chatgpt.com/apps/google-calendar/connector_…`); the user links Google there. The connection lands
   in their OpenAI account, so `codex exec` picks it up automatically.
3. **I'm done** → 3 s settle, then `probeConnected()` — a `codex exec` that must reply exactly
   `YES`/`NO`. YES lights up **Finish**; NO prompts a reconnect.
4. **Finish** → marks Calendar connected + selected. The chip now behaves like any other source.

## How reads work (rides the existing iterative stack)
Calendar flows through the **same INITIAL / ITERATIVE buttons** as every other connector — it's just a
source, run as its own cloud "leg" in `ProcessingView` (twin to the Gmail leg), shown in the same
takeover. No `IterativeRun` / on-device model involved.

- **Initial** (`runInitial`) — the last **year** as **12 MONTHLY `codex exec` calls**, newest month
  first. One dense **summary per month**, keeping ONLY the genuinely important events. Monthly chunking
  keeps each context window bounded and gives per-month progress; the windows are rolling 30-ish-day
  spans anchored at today, contiguous and **past-only** (future events ride the proactive fetch, not the
  knowledge base).
- **Iterative** (`runIterative`) — one call covering events since the high-water mark
  (start time in `[mark, now)`), then the mark advances. Falls back to initial if never run.

Each monthly/iterative summary becomes one ephemeral **`CycleNote`** in bucket `"calendar"`
(`kind: .calendar`, `reminderFlagged = has_action_items`). The existing **"tell cloud"** buttons fold
them into the vault — `VaultCloud` is source-agnostic, so **no knowledge-base code changed**. Pointer =
run start (a little overlap on the next run beats a boundary gap).

## The read prompt curates RUTHLESSLY
A calendar is mostly routine, so the prompt **keeps only what matters** — real meetings, interviews,
trips, appointments, deadlines, events with specific people — and **drops the noise**: recurring
standups, "Lunch", focus-time/"do not schedule" blocks, generic holds, declined events. A quiet window
→ `notable: false`, `summary: ""`. Attribution guard: a calendar event is the user's *schedule*, not a
claim about who they are (don't absorb an attendee's job/biography into the user). PII-light: never
transcribe meeting-link tokens or dial-in PINs.

Structured reply (`--output-schema`): `{ event_count, notable, has_action_items, summary }` (mirrors
Gmail's shape; `additionalProperties:false` required — see Gmail doc's schema gotcha).

## The proactive fetch — the one thing Gmail doesn't have
`fetchProactiveContext()` is a **separate** read used only by Proactive Intelligence. Unlike the
curated source read, it does **NOT** filter — it dumps the user's **last 7 days + next 24 hours** of
events (ALL of them) as a compact, chronological text block. That block is injected into **BOTH**
proactive stages:
- **PART 1 — Decide** (`Proactive.findActionItems(…, calendarContext:)`) — a `## THE USER'S LIVE
  CALENDAR` section, pre-fetched as text so PART 1 stays hermetic/tool-free. Lets the judge reason
  about time-sensitivity (prep for tomorrow's meeting, a free slot that makes a proposal possible).
- **PART 2 — Research & Prepare** (`ProactiveResearch.researchAndPrepare(…, calendarContext:)`) — the
  same block as a grounding surface: confirm free/busy, get an event's real time, catch a thing already
  on the calendar. PART 2 may still call the live Calendar tool to read a specific event in more detail.

Reply (`--output-schema`): `{ connected, events_text }` — `connected:false` ⇒ proactive runs without
calendar context. The dev "proactive system" / "research + prepare" buttons fetch this when Calendar is
connected, then pass it into the call. (The judge already lists Calendar among its sources, so the
calendar *summaries* from the source reads flow into PART 1 with zero prompt change; the live fetch is
extra grounding on top.)

## Writes (add an event) — `bypassApprovals`, already built
Writing an event is **not** in `CalendarConnect` — it's `ProactiveExecutor.fireCalendar` (the proactive
executor's calendar channel), which the user fires with one tap. **[MEASURED June 21]** the calendar
write tools behave **exactly like Gmail's `send_email`**: `create_event` is **approval-gated** and
returns `"user cancelled MCP tool call"` headless under a read-only sandbox + `approval_policy=never`.
The fix is the same flag — **`Invocation.bypassApprovals = true`** →
`--dangerously-bypass-approvals-and-sandbox` (no approvals, no sandbox; trusted app-authored prompts
only) — which `fireCalendar` already sets. Verified live end-to-end: create → read-back → delete all
succeed under the bypass flag. So the write path needed **no change**; all of `CalendarConnect`'s reads
are read-only and need no bypass.

## Models & effort (the light cloud tier, like Gmail)
`gpt-5.4-mini` / `.medium` carries every Calendar **read** (connect-check, monthly/iterative summaries,
the proactive fetch) — calendar data is small and structured. The **write** (executor) uses the default
`gpt-5.5` / `.high`. Set via `CodexCLI.Invocation.model` + `.effort`.

| Call | Model | Effort | Sandbox |
|---|---|---|---|
| Connect-check (`probeConnected`) | `gpt-5.4-mini` | `medium` | read-only |
| Reads (`runInitial`/`runIterative`) | `gpt-5.4-mini` | `medium` | read-only |
| Proactive fetch (`fetchProactiveContext`) | `gpt-5.4-mini` | `medium` | read-only |
| Add-event (`ProactiveExecutor.fireCalendar`) | `gpt-5.5` | `high` | **bypassApprovals** |

## Gotchas (measured live, June 21)
- **The connector works regardless of `--ignore-user-config`.** The calendar tools are account-level
  (`codex_apps/google_calendar.*`), visible to `codex exec` either way — same as Gmail. `includeUserConfig`
  defaults `true`, so the user's `~/.codex` + MCP servers load and the connector works.
- **Read tools pass under the read-only sandbox**; only the *write* tools are approval-gated (above).
- All Calendar reads pass `webSearch = false` — the calendar is the only source they need.

## Not yet / next
- **Dev-only surface** (the `dbg.calendar.*` prefs + the chip in DevToolsView), exactly like Gmail. The
  real onboarding/connectors UI is Phase 5.
- **Scheduler wiring:** when the real proactive trigger lands, it should fetch the calendar context
  **once** and pass it to both PART 1 and PART 2 (the two dev buttons each fetch independently today).
