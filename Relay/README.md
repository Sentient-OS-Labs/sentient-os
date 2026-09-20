# The Double Tap relay (Cloudflare Worker)

The server half of Double Tap when Sentient pays for the model. The app sends one screenshot and
the user's whole knowledge base; the Worker adds Sentient's OpenAI key, enforces per-user caps,
and streams the model's reply back. It stores nothing: no bodies on disk, no bodies in logs.

## What it does, in order

1. **Identity.** `Authorization: Bearer <secret>`. The app mints a random secret once and keeps
   it in its Keychain; the Worker hashes it and uses the hash as the counter key. No accounts.
2. **Size checks.** The declared length, then the two fields: `image` (base64 JPEG, data-URL
   prefix tolerated) and `knowledgeBase` (text). Ceilings are config values.
3. **Caps.** Per identity, `HOURLY_CAP` and `DAILY_CAP` in one Durable Object per user (strongly
   consistent). `GLOBAL_MONTHLY_CAP` across everyone is the kill switch against bulk-minted
   identities; it ships at 0 (off).
4. **The model call.** Built here: `gpt-5.6-sol`, reasoning off, `store: false`, the prompt
   prepended server-side. The client controls only its two inputs, so the relay cannot be used
   as a general model proxy.
5. **The stream.** OpenAI's Server-Sent Events pass through untouched. The app parses them with
   the same code it uses for a direct call.

Responses the app handles: `401 identity_required`, `400 bad_image` / `bad_knowledge_base`,
`413 too_large`, `429 cap_reached` (with `window` and `Retry-After`), `503 budget_reached`,
`502 upstream_error` / `upstream_unreachable`.

## Files

| File | Job |
|---|---|
| `src/index.ts` | The Worker: routes, identity, size checks, caps, the OpenAI request, the pass-through stream, and the prompt. |
| `src/counter.ts` | The `Counter` Durable Object: hour / day / month fixed-window counts per key. |
| `wrangler.toml` | Name, bindings, migrations, and the config values (`[vars]`). Secrets never go here. |

## Running it

```
cd Relay
npm install
npx wrangler login                       # once, opens the browser
echo -n "sk-..." | npx wrangler secret put OPENAI_API_KEY
npm run deploy                           # prints the workers.dev URL
npx wrangler tail --format json > /tmp/relay-tail.txt 2>&1 &   # live structure-only logs, to a file
```

The deployed address is `https://sentient-doubletap-relay.sentient-doubletap-relay.workers.dev`
(Worker name, then the account's workers.dev subdomain); the app carries it as
`DoubleTapInference.defaultRelayURL`. Every draft logs one line,
`draft ok image=… kb=… parse=…ms caps=…ms upstream=…ms total=…ms`, and the tail event beside it
carries `cpuTime` and `wallTime`. Run the tail with a plain `&` into a file; under `nohup` or a
subshell it produces nothing.

Local: `npm run dev` with an `OPENAI_API_KEY=...` line in `.dev.vars` (git-ignored; delete it
after). `--var HOURLY_CAP:2` on `wrangler dev` is the quick way to watch a 429 happen.

Change a cap: edit `[vars]` in `wrangler.toml` and deploy, or set it in the Cloudflare dashboard
under the Worker's variables, which takes effect without a deploy.

## What it measured (2026-09-20, five drafts, one identity, distinct screenshots)

| Step | Warm identity | First call of a new identity |
|---|---|---|
| Parse the ~500 KB body | 3 to 9 ms | 6 ms |
| Cap check (Durable Object round trip) | 24 to 28 ms | 190 to 300 ms (object created) |
| OpenAI response headers | 0.4 to 0.9 s | 0.4 s |
| Worker CPU per draft | 5 to 11 ms | |

Seen from the app: first text in 1.6 to 2.4 s cold, reply complete in 2.3 to 3.1 s, about
0.3 to 0.5 s over a direct call. The second upload leg is most of it: the Worker has to hold the
whole body before it can forward it. Smart Placement is on and will move the Worker toward
OpenAI's backend once it has seen enough traffic.

## Account notes

- **Plan.** A new account is on Workers Free: 100,000 requests a day and a 10 ms CPU ceiling per
  request. Drafts measure 5 to 11 ms of CPU, so upgrade to Workers Paid ($5/month, 30 s ceiling)
  before real users.
- **Browser Integrity Check.** workers.dev rejects generic scripting user agents (Cloudflare error
  1010) before the Worker runs; `Python-urllib` is blocked, curl and CFNetwork pass. The app
  sends `SentientOS-DoubleTap/<version> (macOS)` explicitly.
- **Email verification** is required before the first deploy; wrangler reports Cloudflare error
  10034 until it is done.

## Rules

- **Never log a body.** Logs carry sizes, timings, and status codes only. `console.log` of any
  request or response content is a bug.
- **The prompt is duplicated** in `Sentient OS macOS/Double Tap/DoubleTapInference.swift` for the
  app's direct-key path (Dev Tools). Change both or neither.
- **Costs are the relay's.** Every admitted request is about 9 cents at current sol rates. The
  caps are the budget; the global ceiling is the seatbelt.

Related: `Sentient OS macOS/Double Tap/Documentation - Double Tap.md` (the app side).
