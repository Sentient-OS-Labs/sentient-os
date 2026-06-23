# Gmail Connector (Codex)

Gmail is the **first cloud source** (Google Calendar is the second — see `Calendar Connector
(Codex).md`; same shape). It can't be read on-device (no local DB), so we both **fetch and
summarize** it through the user's own **Codex Gmail connector** — OpenAI's account-level
`codex_apps/gmail.*` tools, reached by `codex exec`. No on-device model touches Gmail.

Code: `Ingestion/GmailConnect.swift` · UI: `Views/GmailConnectSheet.swift` + the Gmail chip in
`Views/DevToolsView.swift`.

## How a user connects
1. **Gmail chip** in the dev SOURCES grid → opens the connect popup.
2. **Connect Gmail** → opens OpenAI's hosted connector page
   (`chatgpt.com/apps/gmail/connector_…`); the user links Google there. The connection lands in
   their OpenAI account, so `codex exec` picks it up automatically.
3. **I'm done** → 3 s settle, then `probeConnected()` — a `codex exec` that must reply exactly
   `YES`/`NO`. YES lights up **Finish**; NO prompts a reconnect.
4. **Finish** → marks Gmail connected + selected. The chip now behaves like any other source.

## How reads work (rides the existing iterative stack)
Gmail flows through the **same INITIAL / ITERATIVE buttons** as every other connector — it's just a
source. The "start" button routes a selected Gmail to `GmailConnect` instead of the on-device takeover.

- **Initial** (`runInitial`) — the last month as **4 weekly `codex exec` calls**, newest week first.
  One dense **summary per week** (the user's decision). Weekly chunking is load-bearing: a heavy inbox
  is ~430 threads/week and a whole month in one call would blow the model's input cap.
- **Iterative** (`runIterative`) — one call covering everything since the high-water mark
  (`after:<epoch>`), then the mark advances. Falls back to initial if never run.

Each weekly/iterative summary becomes one ephemeral **`CycleNote`** in bucket `"gmail"`
(`kind: .gmail`, `reminderFlagged = has_action_items`). The existing **"tell cloud"** buttons merge
them into the vault — `VaultCloud` is source-agnostic. Pointer = run start (a few hours of overlap on
the next run beats a boundary gap).

## The weekly prompt is deliberately disciplined
A naive "summarize this week" cost **220k tokens for a mere count** in testing — codex over-reads. So
the prompt: searches on metadata/snippets via `gmail.search_emails`, **caps at the newest 300
threads**, and only opens (`gmail.read_email`) the handful of threads that look genuinely important
(a real ask, a deadline, a personal/financial/work matter — never newsletters/receipts). Output is one
dense summary with an explicit **action-items** section, built to feed the proactive engine.

Structured reply (`--output-schema`): `{ thread_count, notable, has_action_items, summary }`.

## Models & effort (per the model tiers)
The light model carries the Gmail tier; gpt-5.5 carries the knowledge base. Set via
`CodexCLI.Invocation.model` + `.effort`:

| Call | Model | Effort |
|---|---|---|
| Connect-check (`probeConnected`) | `gpt-5.4-mini` | `medium` |
| Gmail reads (`runInitial`/`runIterative`) | `gpt-5.4-mini` | `medium` |
| Initial vault build (`VaultGenerator`) | `gpt-5.5` | `xhigh` |
| KB update + proactive + everything else | `gpt-5.5` | `high` |

⚠️ On a **ChatGPT-account** auth (no API key) only **gpt-5.5** and the **gpt-5.4** family are
available — `gpt-5.4-spark`, `gpt-5.5-codex`, and the gpt-5/5.5 `-mini`s are all rejected. `gpt-5.4-mini`
is the light model we landed on for Gmail [MEASURED June 15]. `.high` is the `Invocation` default (the initial vault build overrides to `.xhigh`).

## Gotchas (measured live, June 15)
- **The Gmail connector works regardless of `--ignore-user-config`.** The Gmail tools are
  account/server-side (`codex_apps/gmail.*`), visible to `codex exec` whether the user's config is
  loaded or not — measured live with `--ignore-user-config` ON. So **no CodexCLI change was needed**
  for Gmail. (Note: `Invocation.includeUserConfig` now defaults to `true`, so by default
  `--ignore-user-config` is NOT passed and the user's `~/.codex` config + MCP servers ARE loaded —
  the connector works either way.)
- **OpenAI strict output schemas require `"additionalProperties": false`** on the object *and* every
  property in `required`, or `codex exec` fails with `invalid_json_schema`. The weekly schema has both.
- **No `CodexCLI` change at all** — `probeConnected` and the reads use the existing
  `CodexCLI.Invocation` (read-only sandbox; the connector works under it).

## Not yet / next
- **Proactive reconciliation:** proactive currently keys on *per-item* `reminderFlagged` summaries; a
  weekly Gmail blob needs *mining* (extract its action items). The weekly summary is shaped for this
  (explicit action-items section), but the proactive consumer isn't built yet.
- **Connection detection** is a `codex exec` YES/NO probe (the user's chosen UX). A cheaper
  `codex plugin list` poll exists but is unused by design.
- Dev-only surface for now (the `dbg.*` prefs + DevToolsView); the real onboarding/connectors UI is Phase 5.
