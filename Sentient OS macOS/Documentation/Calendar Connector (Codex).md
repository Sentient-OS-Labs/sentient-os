# Google Calendar connector — explicit account source

Google Calendar is an optional cloud source reached through the user's OpenAI-hosted Calendar app.
ChatGPT/Codex authentication, the OpenAI account link, and Sentient enablement are separate states.

## Authorization and tools

Every production read requires `SourceSelection.isAuthorized(.calendar)`, defined as connector
support plus connected plus selected. The connection probe is an explicit user action and exposes
only `get_profile` before selection.

| Operation | Exact tools |
|---|---|
| connection probe | `get_profile` |
| initial/iterative import | `search_events`, `read_event` |
| proactive context | `search_events` |
| create action | `create_event` only |
| update action | `update_event` only |

Create and update are separate policies; both write tools are never enabled by default. Existing
proactive cards currently create events and therefore request only `create_event`. A disabled
source cannot be read or written from scheduler, dev tools, proactive processing, or the executor.

Every run ignores user config/rules and blocks memories, unrelated apps, user MCP servers, plugins,
and web. Write failure does not broaden the tool set or retry with danger bypass.

## Reads and provenance

Initial ingestion summarizes twelve monthly windows. Iterative ingestion reads since the durable
high-water mark. Proactive context independently reads the last seven days and next 24 hours only
when Calendar remains authorized. Retained imports are source-tagged summaries in bucket
`calendar`; no raw event bodies are persisted by the connector.

Successful vault swaps update source-level provenance with the number of Calendar summaries handed
to synthesis. This does not claim which sentence or note came from an individual event. Vaults
created before provenance are reported as legacy/unknown until rebuilt.

## User controls

Stopping use keeps the OpenAI connection, disables Sentient access, and clears the Calendar bucket
and cursor. Managing the connection opens OpenAI's app page. Removing imported knowledge performs a
confirmed full derived-data reset and rebuild from remaining sources because surgical claim removal
cannot be proven safe.
