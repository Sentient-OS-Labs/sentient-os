# Gmail connector — explicit account source

Gmail is an optional cloud source reached through the user's OpenAI-hosted Gmail app. Linking the
Google account on OpenAI is distinct from enabling Gmail in Sentient.

## Authorization

Production reads require all three conditions:

```swift
ModelBackend.connectorsAvailable && connected && selected
```

`SourceSelection.isAuthorized(.gmail)` is the only predicate. It gates ingestion, proactive
research, scheduled/dev entry points, and sends. The explicit connection probe is the sole
pre-selection exception.

The probe policy exposes only Gmail `get_profile`. Import exposes only `search_emails` and
`read_email`. Proactive research receives `search_emails`, `read_email`, and `read_email_thread`
only when Gmail is authorized. The send path exposes only `send_email` for the confirmed action;
it does not retry with an app-wide approval or sandbox bypass.

All policies ignore user Codex config and rules, block memories, unrelated apps, user MCP servers,
and plugins, and disable web unless the separate proactive-research policy allows it.

## Reads

Initial ingestion reads four weekly windows in parallel, capped at the newest 300 threads per
window. It searches metadata/snippets and opens only messages that appear important. Iterative
ingestion reads since the durable high-water mark. Each retained window becomes one source-tagged
`CycleNote` in bucket `gmail`; no raw email is written to the store.

## User controls

- **Stop using in Sentient** sets `selected=false`, keeps the OpenAI link, and deletes the Gmail
  summary bucket and cursor immediately. This privacy action is allowed below the four-source
  recommendation.
- **Manage connection on OpenAI** opens the Gmail app page and makes no claim that Sentient revoked
  the account connection.
- **Remove imported knowledge and rebuild** disables Gmail, deletes all derived knowledge and
  proactive artifacts, then rebuilds from remaining selected sources. A full rebuild is necessary
  because the synthesized vault has source-level, not claim-level, lineage.

The Settings source card shows link/enablement state, last successful content-free access receipt,
and whether vault provenance says Gmail may still be represented.
