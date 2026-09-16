# Direct MCP connections

Sentient can own a user's OAuth connection to a supported remote MCP service and use that connection
through either frontier engine. The provider handles browser sign-in; Sentient stores the grant in
the Mac's Keychain and supplies access headers to the selected CLI for each run. The initial catalog
contains Granola, Notion and Linear. Provider definitions live in the existing registry packs.

Direct connections have independent account identities. Their stable source slug is
`direct-<connection UUID>`. A routed task or prepared card additionally records the grant generation
in its target, so reconnecting an account cannot silently retarget older work. Hosted connectors
remain separate records, even when they belong to the same service.

| File | Responsibility |
|---|---|
| `DirectMCPModels.swift` | Provider definitions, connection/grant values, tool fingerprints and typed errors. |
| `DirectMCPAuth.swift` | Validated OAuth discovery, public-client registration, PKCE, exchange, refresh and revocation. |
| `DirectMCPCallback.swift` | Bounded loopback HTTP listener that consumes one verified authorization response. |
| `DirectMCPHTTP.swift` | Cookie-free, bounded requests to the provider's pinned HTTPS origins; redirects are refused. |
| `DirectMCPStore.swift` | Connection metadata in preferences, complete grants in Keychain, and cross-process refresh locks. |
| `DirectMCPProbe.swift` | Native MCP initialization and a complete paginated tool inventory. |
| `DirectMCPIdentity.swift` | Optional account/workspace identity from an actual provider response. |
| `DirectMCPConnections.swift` | Interactive attempts, verification, reconnect recovery, disconnect and cleanup. |
| `DirectMCPRuntime.swift` | Immutable task attachments, engine configuration, helper entry points and active-run cancellation. |

**Connecting.** In Settings → Knowledge Sources → Connectors, the user opens a service's pill and
selects **Connect** in its popup. Setup asks for an account label for that service, then the user
approves access in their browser. The callback verifies
state and uses S256 PKCE. Discovery validates the issuer, resource and endpoints; supported scopes
come from the resource challenge/metadata, with the provider's explicit offline-access requirement.
Registration information is saved before browser interaction so a retry can reuse it.

After exchange, Sentient fetches the live tool inventory and classifies it using the existing
classification rules. The model receives tool definitions as data, with tools disabled and a scratch
working directory. The result must exactly cover the captured inventory. A fingerprint and policy
revision prevent stale classifications from activating changed tools. A connection becomes usable
only when a nonempty permitted tool set remains.

Account labels are user choices. A provider-supplied email/workspace is shown only when an actual,
recognized account-info response establishes it. Granola uses `get_account_info`; Notion uses
`notion-fetch` with `id: "self"`. Notion's stable user/workspace IDs bind the account independently
of its display name. Provider account errors leave the connection requiring attention, even if
the OAuth exchange itself succeeded. If a previously established identity disappears or
changes, verification fails. A grant without that optional response retains its explicit OAuth
connection and label; Sentient does not infer an email or workspace from a model's answer.

**Running a task.** `ConnectorRegistry.server(for:)` remains the resolution seam. `FrontierRun`
prepares direct attachments before dispatch, pins the backend and connection generation, and ties
the child task to disconnect cancellation. Both engines use per-run configuration. Direct servers
never enter the hosted catalog-ID fallback.

Codex receives `mcp_servers` definitions with explicit `enabled_tools` and scoped approval. Claude
normal runs use named allows under `dontAsk`. Its computer-use mode additionally uses explicit ask
rules and a `PermissionRequest` hook: only a matching captured tool receives approval, and a missing
or failed hook leaves a headless request denied. Known excluded tools are also removed by name.

The same app executable handles `--direct-mcp-headers` and `--direct-mcp-policy` before SwiftUI or
diagnostics initialize. Their arguments contain a connection lease and permitted names, not bearer
or refresh tokens. The header helper reads/renews the grant and writes the access header directly
to the CLI's pipe. The policy helper validates the grant and returns a permission decision.
These controls scope ordinary tool execution; they are not an isolation boundary against arbitrary
code running as the same macOS user.

`Cloud/MCPCallEvidence.swift` parses successful tool receipts from both engines. A direct connector
action with no confirmed permitted call is unconfirmed. The action wrapper still evaluates the
completion sentinel; a receipt proves tool execution, not every semantic detail of the requested
outcome. Failed or uncertain direct actions do not automatically replay through computer use.

**Persistence and recovery.** Preferences use `mcp.connectors.direct` for non-secret connection
metadata. Grants use the dedicated Keychain service `ai.sentient-os.app.direct-mcp.v1`; neither CLI
owns these records. A complete access/refresh pair is updated together with `SecItemUpdate`, adding
a record only when none exists. Per-grant locks serialize refresh, replacement and deletion across
the app and helper processes. Refresh results are saved before use, including rotated refresh tokens.
Missing replacement refresh tokens preserve the old value. Invalid grants require reconnect;
invalid clients mark the registration for replacement.

An interrupted or failed reauthentication restores an existing grant only when a newer attempt or
replacement grant has not taken its place. Disconnect advances the generation, cancels active work,
attempts supported remote revocation, and removes local records. Native probes check the generation
between requests. Reset and Uninstall enumerate the Keychain namespace independently of the
preferences index, so orphan or malformed records can be removed. An unavailable Keychain produces
an honest retry state instead of a successful cleanup message. Local deletion and confirmed remote
revocation are distinct outcomes.

**Knowledge use.** Direct source selection and checkpoints use the existing MCP source pipeline.
The checkpoint origin includes the connection generation. BYOM can use direct connections while
hosted account connectors retain their existing gates. KB eligibility additionally requires a
provider's `kbVerified` flag and reviewed read tools. That flag remains off for the initial providers
until their live reader curation is completed. Granola's candidate surface is restricted to
`list_meetings` and `get_meetings`, with a bounded prompt and observed read receipts. A notable
Granola summary requires a successful content read; a quiet result requires a successful list call.
Notion's reviewed read surface contains `notion-fetch` and `notion-list-recent-pages`. Its live
transport check uses one recent page's metadata; that check does not enable KB ingestion.

Content returned by a connector is processed by the user's selected frontier provider. Keychain
custody does not imply that cloud-model inference occurs on the Mac. The connection sheet states
this data flow before sign-in.

**Verification.** The connector lab's `directcheck` command checks PKCE, callback handling, metadata
validation, token parsing, Keychain updates/cleanup, account generations, receipt checks and engine
configuration. `Scripts/test_direct_mcp_runtime.py` drives both installed CLIs against local fake
model and MCP servers, including forbidden tools, header renewal, concurrent rotation, terminal
failures, reconnect cancellation and cleanup. Two independent accounts exposing the same tool
name are exercised through both engines. Its credentials and records are synthetic.

Notion's browser exchange, native account binding, tool inventory and rotating refresh have been
verified. Both real engines passed a bounded Notion metadata read through the direct connection.
Granola's browser exchange, grant storage, inventory and refresh have also been exercised; its
content reader remains unverified. Public discovery has been checked for all three catalog
providers. Linear's browser flow and live tools have not been field-tested.

`directread` accepts `LAB_SLUG=notion` or `granola` and `LAB_ENGINE=codex` or `claude`.
The Notion case lists at most one recent page; the Granola case lists this week's meeting metadata.
`directkbtrial` is a separate bounded Granola content-reader trial. These model-mediated tests
require explicit permission for the data disclosure and do not write the knowledge base.
Successful transport checks do not establish KB-reader curation.

Related: `Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md`,
`Cloud/Documentation - Cloud - ClaudeCLI (the claude -p engine).md`,
`Sources/Documentation - Sources - Cloud (Gmail, Calendar).md`,
`Views/Settings/Documentation - Settings.md`, and
`Documentation - General - Self-Testing (Eval Harness).md`.
