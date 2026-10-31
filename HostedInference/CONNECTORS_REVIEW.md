# Hosted cloud connectors

The source includes an optional hosted connector implementation. The provider picker remains
hidden, and both accounting policies install disabled with zero funded allowances. Publishing
this source does not deploy the service, approve an OAuth app or enable funded usage.

## Routing and ownership

Only the Sentient-hosted engine uses this adapter. ChatGPT and Claude keep their subscription
connectors, custom providers keep their existing routing, and local sources and direct
Notion/Granola keep their existing paths. Hosted accounts use distinct local UUIDs and
generation-qualified task targets. They never borrow a subscription account's saved choice.

The Mac's separate anonymous hosted principal authenticates account management and delegates
tools to a run it owns. The gateway generates an opaque Composio user ID; client-supplied
upstream user, account, session, configuration and URL values are not accepted. Labels are
user-entered convenience names, not verified email addresses. Each OAuth attempt selects a
specific connection; multiple accounts get separate rows and knowledge choices.

The Composio project key and OAuth credentials stay server-side. In particular, session MCP
URLs/headers are discarded. The CLI receives only access to an authenticated local Sentient
tool server. Its inference ticket cannot mint a connector capability. A delegated capability
is confined to one account generation, one run, and a read or action tool allowlist. Both
argument validation and upstream argument construction run on the server. There are no
generic proxy, workbench, connection-management, shell or multi-execution escape tools.

`src/connectors/catalog.mjs` owns the supported operations and `versions.mjs` records reviewed
tool versions. Preparing a session checks the provider's current inventory against those
versions before execution. A changed inventory requires review. This is admission validation,
not an upstream version pin: the session execution API has no version argument. Provider-side
behavior changes during a session remain a runtime risk; response validation and uncertain-write
handling remain active.

## Supported scope

| Service | Knowledge / reads | Requested Sidekick actions | Deliberate limits |
| --- | --- | --- | --- |
| Gmail | Bounded search, pagination, message text | Plain-text send and reply | No attachments, forwarding, archive/delete or labels |
| Google Calendar | Primary calendar, expanded recurring events | Single timed event, optional explicit invitees | No secondary calendars, all-day/recurring creation or existing-event edits |
| Google Drive | Modified-file metadata, Google Docs and small UTF-8 text | New plain-text file in My Drive | No binary extraction, existing-file edits or sharing changes; text reads use temporary staging |
| Slack | Search, threads, user lookup, existing conversations | Plain-text message or thread reply | No new DM creation, uploads, edits, deletion or administration |
| Outlook Mail | Primary mailbox list and message reads | Plain-text send and reply | No shared mailbox, attachments, forwarding or mailbox changes; sensitivity filtering fails closed |
| Outlook Calendar | Primary calendar view | Single timed event, optional explicit invitees | Same creation limits as Google Calendar; sensitivity filtering fails closed |

These are implemented adapter capabilities, not claims of live acceptance for every provider.
An OAuth app's scopes can be broader than this execution surface; the gateway still enforces
the narrower surface. Slack app approval and Microsoft tenant policy can prevent authorization.

## Execution and recovery

`HostedConnectorToolServer` attaches the same account-bound tools to structured Claude work
and the native Codex → Claude bridge. Every foreground Sidekick request keeps the unified
main-agent executor. `HostedConnectorAuthorization` captures requested write accounts from the
current command with a bounded tool-free scope call before external content is read. It does
not choose an executor or run a connector-only task. Account ambiguity, stale generations and
failed scope capture retain read-only tools. Computer reads have no send/create tools. Background capabilities are always
read-only, including proactive research. The existing 3,600 active seconds per UTC day,
acknowledged lease, explicit user waits, cancellation and shared inference budgets remain.

Disconnect/reconnect immediately invalidate generations and prepared tasks. Server execution
checks the current account and run before reservation, during long calls and before releasing
results. The Mac checks local changes and polls remote invalidation. A user-wait pause cannot
pause accounting while a connector operation is still dispatched.

Normal Disconnect removes only the exact Composio connection. A separately confirmed Revoke
service access action asks Composio to revoke the provider grant first, which can affect other
connections using the same OAuth app. Unsupported or transient revocation remains visibly
pending; users can also remove access in the service's own account settings. Local reset and
uninstall wait for deletion of the saved connections and do not silently discard unfinished
cleanup. Replaced and cancelled records use delete-only cleanup to preserve newer grants.

A persistent cleanup outbox removes cancelled authorization records, retired connections and
closed sessions. It verifies the original project's auth configuration and positive provider
receipts. Cron must remain configured even when new hosted admissions are disabled. A lost
upstream creation response may leave an unbound, unused session or uncompleted authorization
record; reconcile those through the Composio dashboard using the opaque user and attempt alias.
Never treat an unknown creation outcome as permission to adopt an arbitrary account.

Writes reserve an operation before dispatch. Confirmed identical mutations in the same run
return the original receipt, including across newly prepared capabilities. Uncertain writes
stay charged and quarantine further writes for that account. The native executor stops and
structured actions do not automatically fall back to computer use after an uncertain result.
The account's review UI lets the user inspect the service and report completion or explicitly
permit a later new attempt. This does not replay anything, refund the call or manufacture a
provider receipt. A receipt means creation/provider acceptance, not message delivery.

## Knowledge pipeline

Done commits the explicit per-account choice without a health, content or model probe.
Read outcomes do not change that choice or its admission to the next processing attempt.
OAuth completion checks authorization metadata only. Explicitly disconnected accounts remain
selected but require reconnection before execution.

`HostedConnectorSource` performs deterministic bounded reads, followed by tool-free structured
summaries. It pages fixed windows, optionally reads up to three selected items per page,
filters private material through the existing summary policy, and commits each summary with
its cursor in one SwiftData transaction. Initial coverage is 28 days for mail/Drive/Slack and
one year for calendars. Each attempt admits at most 20 pages. It never calls a partial import
complete or advances the high-water mark past unfinished coverage. Subsequent runs resume.
Expired cursors atomically retire the unfinished window's pending summaries before rereading.
Initial-creation recovery retains completed stages and resumes the hosted reader's atomic page
checkpoints. Restarting every hosted stage would prevent sources larger than the per-run page
budget from ever finishing. Existing subscription-reader replay behavior is preserved.
Reconnect generations retire pending summaries from the previous generation.

Source notes feed the existing merge inputs, confined knowledge tools, staging validation and
atomic publication/recovery paths. Completed decodable summaries do not require native
receipts, query choreography or prose patterns. Explicit final failure, unreadable output,
privacy rejection, account changes and failed storage remain actual failures. A recovered
read retry does not leave the successful run failed.

## Privacy, OAuth and cost decisions

Current official sources reviewed for this implementation:

- [Sessions and MCP](https://docs.composio.dev/docs/sessions-via-mcp)
- [Token custody](https://docs.composio.dev/docs/security/token-custody)
- [Data retention](https://docs.composio.dev/docs/security/data-retention)
- [Zero Data Retention eligibility](https://docs.composio.dev/docs/security/zero-data-retention)
- [Production readiness](https://docs.composio.dev/docs/production-readiness)
- [Pricing](https://composio.dev/pricing)
- [v3.1 connected accounts API](https://docs.composio.dev/reference/api-reference/connected-accounts)

Before activation, the operator must verify the selected project's plan, OAuth ownership,
scopes, branding and retention policy against the provider's current terms. Tool arguments,
results and temporary file staging can have different retention rules. The product disclosure
must match the deployed configuration. It describes server/Composio credential custody and
processing; it does not claim these credentials live only in the Mac's Keychain or promise
universal Zero Data Retention.

Connector accounting is independent of Anthropic token accounting. Reserve one call and the
operator-configured conservative marginal cost before every dispatch; charge failed/uncertain
attempts too. Enforce per-user UTC daily calls, background calls, cost, global daily/monthly
calls and monthly cost. Only an explicitly verified zero marginal price may use zero cost;
call limits still apply. Included calls are a shared organization resource, not free unlimited
usage. Do not infer production funding from the development allowance.

The SQL also reserves upstream request units for metadata, execution and cleanup, limits
active operations, and respects bounded retry delays. Reads may retry once through the app;
writes are never automatically retried. Align production limits with the actual organization
plan, other projects' use, and provider-side quotas. Subscription fees, overage and any future
add-ons require an operator decision and must be reflected in the funded policy.

## Local verification

Offline tests exercise the gateway, SQL ledger, account isolation, read/write policies,
pagination, cancellation and recovery with synthetic services. Actual-app fixtures additionally
exercise durable SwiftData state, CLI tool attachment, bounded imports and the connection view.
These checks do not establish live Google, Slack or Outlook acceptance. Approved OAuth apps,
tenant policies and authorized real-account tests are separate rollout requirements.

```sh
cd HostedInference
npm ci
npm test
```

Run the actual Debug app with isolated data and real CLI processes:

```sh
python3 Scripts/test_hosted_connectors.py --app '/absolute/isolated/Debug/Sentient OS.app/Contents/MacOS/Sentient OS'
```

This uses synthetic providers and actual SQL, SwiftData, Claude CLI and Codex/Claude bridge.
The fixture native tool does not inspect the desktop. The CLI software is copied/downloaded
from the pinned release and verified; no personal CLI login or application data is copied.

With account-owner authorization, separate read-only Google auth configs and a server-only
development key, `Scripts/test_hosted_connectors_live.py` opens the actual connection sheets,
performs one unique-marker search in a one-day window per service and deletes the exact test
connections. It never sends messages, creates calendar events, enumerates an inbox, or calls a
real model. Private credentials and receipts remain outside the repository. Browser OAuth
consent is still required. No real Slack/Microsoft access or external write is assumed.
An interrupted local acceptance run can remove its exact stored test records using
`node HostedInference/test/support/cleanup-live-acceptance.mjs <marked-test-root> <key-file>`.
It accepts only an owned fixture database, verifies account ownership, and never revokes a
shared provider grant or enumerates a user's content.

## Operator-owned rollout

1. Human-test the supported journeys
   and failures, including multiple accounts, expired authorization, explicit source choice,
   resumed analysis, native task cancellation and uncertain-write review. Test actual native
   desktop permissions, signed builds and production enrollment separately.
2. Select separate staging/production Composio projects and OAuth apps. Verify app scopes,
   tenant approval, retention eligibility and least-privilege project keys. Keep legacy proxy,
   workbench, triggers and webhooks disabled unless separately designed and reviewed.
3. Apply the hosted-inference migration first, then
   `supabase/migrations/20261030010000_hosted_connectors.sql` to a disposable staging database.
   Exercise real Supabase Auth and multi-process concurrency. Both policies remain disabled.
4. Inspect the live relay immediately before packaging and record its current version and
   bindings privately. Preserve existing secrets; a changed baseline requires a fresh review.
5. Bundle `relay/index.mjs` with a dry run, then run `Scripts/prepare_hosted_relay.py --help`.
   The preparer only reads live state and writes a review package. It verifies version/source
   and preserves existing secret and Durable Object bindings. It never uploads or deploys.
   `relay/wrangler.example.toml` is a local template, not a production deployment command.
6. Review the composed bundle: existing root Double Tap routes and `Counter` stay unchanged;
   hosted routes live only under `/hosted/*`, guarded by `SENTIENT_HOSTED_ROUTES_ENABLED`.
   Preserve existing bindings/routes and cron jobs. Review the proposal to disable raw Worker
   observability so OAuth query state and provider payloads are not logged.
7. Supply only on the chosen server: `COMPOSIO_API_KEY`, `COMPOSIO_AUTH_CONFIGS` (service-slug
   to auth-config-ID JSON), `CONNECTOR_CALLBACK_BASE_URL` (HTTPS `/hosted` base), existing
   Supabase service/auth configuration, inference model/prices, and required existing secrets.
   Configure scheduled cleanup. Do not assume a secret exists on another Worker.
8. Approve explicit inference and connector funding, abuse controls and rate limits. Exercise
   staging quotas and kill switches. Apply reviewed production migrations/configuration only
   through the team's deployment process; enable policies/routes only after acceptance.
9. Point the app's `SENTIENT_INFERENCE_URL` to the approved HTTPS `/hosted` endpoint. Provider
   UI exposure is a separate product decision; this source leaves it hidden.
   Verify signed Debug/Release builds, enrollment, callback return and durable saves on-device.
10. Confirm the implementation works in manual acceptance, then update the deployment documentation.
    Preserve a sanitized verification record and the
    precise unresolved service gaps; do not include credentials or personal account details.
