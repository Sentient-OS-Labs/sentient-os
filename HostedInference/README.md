# Hosted inference gateway

This directory contains a Cloudflare-compatible streaming Anthropic gateway and a loopback Node
development server. Supabase Postgres is the only accounting authority. The gateway owns the
Anthropic key; the Mac receives a random credential scoped to one immutable-purpose run. The
production handler never imports the local fixture or falls back to in-memory accounting.

The migration installs the service **disabled with zero funded budgets**. No deployment, funded
policy, production database change, or provider credential is included here.

## Local verification

Use Node 22 or newer:

```sh
cd HostedInference
npm ci
npm test
node src/server.mjs --fixture
```

The fixture listens only on `127.0.0.1:8788`. It uses the actual migration and RPC in an isolated
PostgreSQL WASM database, a synthetic identity (`local-fixture-token`), and a fake provider. Its
database disappears on shutdown. `@electric-sql/pglite` is a development-only dependency;
the production Worker has no package dependencies.

Tests cover authenticated boundaries, actual request byte bounds, UTC midnight accounting,
the exact 3,600-second ceiling, pause/resume, stale leases, shared budgets, concurrency,
reservation settlement, retries, cumulative SSE usage, cancellation, and safe upstream errors.
The SQL assertions also live in `../supabase/tests/hosted_inference.sql` for an isolated local
Supabase database. They must not be run against production. WASM tests exercise PostgreSQL
functions and submitted concurrent calls; they do not benchmark a multi-process production DB.

An explicitly authorized, bounded live-provider test can use `--fixture --live-upstream`.
It requires the model, upstream key and pricing configuration below plus
`HOSTED_TEST_BUDGET_MICROUSD` (positive, at most 5,000,000, which is $5). The server binds to
loopback and funds only its disposable fixture ledger. It does not authenticate to Supabase.
Load secrets through the process environment; never put them in shell history or this repository.
Restarting this fixture creates a fresh test budget; it is a developer tool, not a subsidy boundary.

## HTTP contract

All responses use `Cache-Control: no-store`. Dates are ISO 8601 UTC timestamps. Run control and
inference accept `Authorization: Bearer <run_token>` or `x-api-key: <run_token>`; conflicting
credentials are rejected. Run creation and usage require a Supabase caller JWT in the Bearer
header. The gateway validates that JWT through Supabase Auth, not by trusting decoded claims.
The client enrolls or refreshes its independent anonymous Supabase identity directly.

| Request | Body | Result |
| --- | --- | --- |
| `GET /health` | None | Process health only; not proof of funded/available inference |
| `GET /v1/usage` | None | Daily active-time allowance |
| `POST /v1/runs` | `{ "purpose": "sidekick" }` | Run snapshot plus `run_token` |
| `POST /v1/runs/{id}/heartbeat` | `{}` | Account elapsed time and renew active lease |
| `POST /v1/runs/{id}/pause` | `{}` | Enter explicit user-wait state; no pending inference allowed |
| `POST /v1/runs/{id}/resume` | `{}` | Resume active lease; repeated resume is idempotent |
| `POST /v1/runs/{id}/finish` | `{}` | End the run; late provider receipts can still settle |
| `GET /v1/models` | None | The model pinned to this run |
| `POST /v1/messages/count_tokens` | Anthropic token-count body | Bounded provider token count |
| `POST /v1/messages` | Anthropic Messages body, `stream: true` | SSE, with accounting |

Purposes are `sidekick`, `knowledge_bootstrap`, `knowledge_update`, `proactive`, and `utility`.
They are immutable after creation. Sidekick has one foreground run per principal; all other
purposes share one background-run slot. Every purpose shares the principal's daily funded
budget and the service's daily/monthly funded budget. Bootstrap additionally has a lifetime
budget; other background purposes share a daily background budget. A caller cannot obtain an
unfunded bypass by describing an arbitrary request as knowledge work.

Example run snapshot (the token is returned only at creation):

```json
{
  "run_id": "00000000-0000-4000-8000-000000000001",
  "purpose": "sidekick",
  "model": "operator-configured-model",
  "maximum_output_tokens": 16000,
  "phase": "running",
  "server_time": "2026-10-29T12:00:00+00:00",
  "lease_expires_at": "2026-10-29T12:00:45+00:00",
  "daily_limit_seconds": 3600,
  "used_seconds": 123.456,
  "remaining_seconds": 3476.544,
  "reset_at": "2026-10-30T00:00:00+00:00",
  "policy_version": 1
}
```

Errors have the Anthropic-compatible outer shape
`{ "type": "error", "error": { "type": "code", "code": "code", "message": "safe text" } }`.
Quota/lifecycle errors also carry current usage fields inside `error` and at the top level.
Run creation, controls and usage include `maximum_output_tokens`; the local runtime must configure
its provider request output ceiling to this value. Usage reports 503 when service policy is
disabled/unfunded or the global budget is exhausted, and 429 when the shared personal dollar
budget is exhausted. Exhausted Sidekick time alone leaves usage readable so background work
can remain available; a new Sidekick run is still refused.
`daily_time_exhausted`, `usage_limit_reached` and `request_rate_limited` use 429;
`service_budget_reached` and `service_disabled` use 503;
`run_expired` uses 429; `run_paused` and `run_busy` use 409.
Authentication errors use 401/403. Provider errors become safe fixed categories, without the
provider body. A failed stream emits `hosted_stream_interrupted` and retains conservative
accounting when no complete usage receipt exists.

## Active time and reservations

The database records active wall time through a server-issued lease. Default running leases
last 45 seconds, shortened to the remaining daily allowance. The client should heartbeat about
every eight seconds while local tools run and cancel local actions at the acknowledged lease
deadline if renewal fails. The gateway also checks/renews the lease during upstream inference.
`server_time` permits a monotonic local deadline based on `lease_expires_at - server_time`,
anchored conservatively to the request's local send time without trusting the device wall clock.
This server clock cannot prove how a modified client uses its own local tools.

Pause waits last at most 24 hours without renewal and do not consume active time. A paused run
cannot call the model. Admission, every control transition and status reads account preceding
active intervals. Crash accounting ends at the last lease expiration. Cross-midnight intervals
are split into UTC days; device clocks and timezones cannot create allowances.

Before each billable request, the gateway token-counts and checks the input ceiling. It reserves
the **entire configured input ceiling at the highest configured input/cache price**, plus the
requested capped output at output price. This is intentionally conservative: admission can
fail near a remaining dollar budget even if a cache hit would have made the request cheaper.
`MAXIMUM_INPUT_TOKENS` must cover the selected model's supported input usage; account for token
counting estimates when selecting the accepted ceiling. Actual input, cache creation, cache
reads and cumulative output receipts release unused reservations. Cache-write pricing must
cover the most expensive supported cache TTL. These are cost estimates at configured rates,
not a replacement for reconciling provider billing.

Reservation and shared budget increments occur in one transaction. Settlement uses the original
request's day/month even after a midnight boundary. An uncertain upstream outcome or failed
settlement keeps the full reservation charged. A receipt over the reservation charges the full
amount, potentially closing later admission; it is never discarded to make a dashboard look
within budget. Operational reconciliation is needed for missing receipts; automatic refunds
on a timeout would create a spending bypass.

`Idempotency-Key` (or `x-idempotency-key`) scopes a request within its run. Without that header,
the normalized message-body hash is used. Reusing the same key cannot dispatch a second provider
request. The server returns `request_already_dispatched`, or `idempotency_conflict` for a changed
body. Request content is not persisted for replay. A deliberate fresh attempt needs a fresh key
or run. Unknown local mutations must be inspected before replaying an agent action.

## Production configuration

The Worker entry point is `src/gateway.mjs`. `wrangler.toml` has no live route and disables
Workers request observability by default. The production handler requires all of:

- `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SERVICE_ROLE_KEY`
- `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL`
- `INPUT_MICROUSD_PER_MILLION`, `OUTPUT_MICROUSD_PER_MILLION`,
  `CACHE_WRITE_MICROUSD_PER_MILLION`, `CACHE_READ_MICROUSD_PER_MILLION`
- `MAXIMUM_INPUT_TOKENS`, `MAXIMUM_OUTPUT_TOKENS`, `MAXIMUM_BODY_BYTES`
- `REQUEST_TIMEOUT_MS`, `LEASE_CHECK_MS`
- Optional `ANTHROPIC_BETAS`, controlled by the operator rather than forwarded from the client

Prices are nonnegative integer **micro-US-dollars per million tokens**. For example a documented
$3/million token price is 3,000,000 in this configuration; this is an arithmetic example, not a
claim about the selected model's current price. Set the model to a verified Anthropic model ID.
The application integration has selected `claude-sonnet-5-5`; the server deliberately supplies
no unpriced default. Configure the upstream request deadline and lease checks so a check occurs
well before lease expiry. Keep Supabase gateway RPC access restricted to `service_role`.

Apply the migration only through the team's approved deployment process. Fund and enable the
singleton `hosted_inference_policy` row explicitly after choosing daily per-user, background,
bootstrap, global daily, and global monthly budgets. Keep all budgets positive for purposes
intended to run. Disabling `enabled` stops new inference and renewals; finish and settlement
remain available. Raising limits is an operator action, not an app preference.

The gateway accepts inline content and local/custom computer tools. Provider file references,
remote content URLs, and separately billed hosted search/execution tools are refused pending a
reviewed usage and pricing policy. Client headers never choose an upstream host, API key,
priority tier, beta capability or unpriced model. Connector OAuth grants stay on the Mac.

No request/response content is stored in the ledger. It contains pseudonymous principal/run
identifiers, token counts, times, amounts, statuses and payload hashes used for idempotency.
Do not turn on body/header capture in infrastructure logs. Anonymous enrollment remains
vulnerable to fresh-identity abuse; production rollout still requires enrollment protections,
finite aggregate funding, provider billing reconciliation and a tested operational kill switch.
An anonymous installation credential is not a verified unique person. This code supplies no
human-uniqueness guarantee. Keep production disabled until the team's enrollment abuse controls
and funded rollout policy are ready; a 60-minute per-identity timer cannot substitute for them.
