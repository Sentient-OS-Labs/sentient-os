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
npm run tail                             # live structure-only logs
```

Local: `npm run dev` with an `OPENAI_API_KEY=...` line in `.dev.vars` (git-ignored).

Change a cap: edit `[vars]` in `wrangler.toml` and deploy, or set it in the Cloudflare dashboard
under the Worker's variables, which takes effect without a deploy.

## Rules

- **Never log a body.** Logs carry sizes, timings, and status codes only. `console.log` of any
  request or response content is a bug.
- **The prompt is duplicated** in `Sentient OS macOS/Double Tap/DoubleTapInference.swift` for the
  app's direct-key path (Dev Tools). Change both or neither.
- **Costs are the relay's.** Every admitted request is about 9 cents at current sol rates. The
  caps are the budget; the global ceiling is the seatbelt.

Related: `Sentient OS macOS/Double Tap/Documentation - Double Tap.md` (the app side).
