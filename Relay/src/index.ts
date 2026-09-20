// The Double Tap relay. A macOS client POSTs {image, knowledgeBase}; the Worker checks the caller's
// caps, builds the OpenAI Responses request itself (model, reasoning, prompt, `store: false`), adds
// Sentient's key, and streams OpenAI's Server-Sent Events straight back. Nothing is stored: no
// bodies on disk, no bodies in logs, only sizes, timings, and status codes.
//
// The prompt and every model setting live HERE, not in the client, so the relay can only ever
// produce Double Tap replies: it is useless as a general proxy for the model.
//
// Routes: POST /v1/draft (the call) · GET /health.
// Auth: `Authorization: Bearer <identity>`, a random secret the app mints once and keeps in its
// Keychain. The Worker never stores it; a SHA-256 of it is the counter key.

import { Counter, type Caps } from "./counter";

export { Counter };

export interface Env {
  OPENAI_API_KEY: string;
  COUNTERS: DurableObjectNamespace<Counter>;
  MODEL: string;
  HOURLY_CAP: string;
  DAILY_CAP: string;
  GLOBAL_MONTHLY_CAP: string;
  MAX_IMAGE_BASE64_BYTES: string;
  MAX_KNOWLEDGE_BASE_BYTES: string;
}

const OPENAI_RESPONSES = "https://api.openai.com/v1/responses";
const MAX_OUTPUT_TOKENS = 600;
/** Idle time allowed between upstream bytes; the client's own deadline is shorter (30 s total). */
const UPSTREAM_TIMEOUT_MS = 25_000;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return new Response("ok", { headers: { "cache-control": "no-store" } });
    }
    if (request.method !== "POST" || url.pathname !== "/v1/draft") {
      return json({ error: "not_found" }, 404);
    }
    const started = Date.now();

    // 1. Identity: a bearer secret, shaped like the app mints it (base64url, 32+ bytes).
    const identity = bearer(request);
    if (!identity) return json({ error: "identity_required" }, 401);
    const counterKey = await sha256Hex(identity);

    // 2. Size ceilings before reading the body.
    const maxImage = int(env.MAX_IMAGE_BASE64_BYTES, 2_000_000);
    const maxKB = int(env.MAX_KNOWLEDGE_BASE_BYTES, 700_000);
    const declared = Number(request.headers.get("content-length") ?? 0);
    if (declared > maxImage + maxKB + 4096) return json({ error: "too_large" }, 413);

    let body: { image?: unknown; knowledgeBase?: unknown };
    try {
      body = (await request.json()) as typeof body;
    } catch {
      return json({ error: "bad_json" }, 400);
    }
    const image = typeof body.image === "string" ? stripDataURL(body.image) : "";
    const knowledgeBase = typeof body.knowledgeBase === "string" ? body.knowledgeBase : "";
    if (!image || image.length > maxImage || !/^[A-Za-z0-9+/=]+$/.test(image)) {
      return json({ error: "bad_image" }, 400);
    }
    if (!knowledgeBase || knowledgeBase.length > maxKB) return json({ error: "bad_knowledge_base" }, 400);

    // 3. Caps: the caller's hour and day, then the global month if switched on.
    const userCaps: Caps = { hour: int(env.HOURLY_CAP, 0), day: int(env.DAILY_CAP, 0) };
    const user = env.COUNTERS.get(env.COUNTERS.idFromName(counterKey));
    const verdict = await user.take(userCaps);
    if (!verdict.ok) {
      return json({ error: "cap_reached", window: verdict.window, retryAfterSeconds: verdict.retryAfterSeconds },
                  429, { "retry-after": String(verdict.retryAfterSeconds) });
    }
    const globalCap = int(env.GLOBAL_MONTHLY_CAP, 0);
    if (globalCap > 0) {
      const global = env.COUNTERS.get(env.COUNTERS.idFromName("global"));
      const g = await global.take({ month: globalCap });
      if (!g.ok) return json({ error: "budget_reached", retryAfterSeconds: g.retryAfterSeconds }, 503);
    }

    // 4. Upstream: the request is built here, so the client controls nothing but its two inputs.
    const upstreamBody = JSON.stringify({
      model: env.MODEL,
      stream: true,
      store: false,
      max_output_tokens: MAX_OUTPUT_TOKENS,
      reasoning: { effort: "none" },
      input: [{
        role: "user",
        content: [
          { type: "input_image", detail: "auto", image_url: `data:image/jpeg;base64,${image}` },
          { type: "input_text", text: INSTRUCTIONS + knowledgeBase },
        ],
      }],
    });
    let upstream: Response;
    try {
      upstream = await fetch(OPENAI_RESPONSES, {
        method: "POST",
        headers: { authorization: `Bearer ${env.OPENAI_API_KEY}`, "content-type": "application/json" },
        body: upstreamBody,
        signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
      });
    } catch (error) {
      console.log(`draft upstream_unreachable ${label(error)} ${Date.now() - started}ms`);
      return json({ error: "upstream_unreachable" }, 502);
    }
    if (!upstream.ok || !upstream.body) {
      const detail = (await upstream.text()).slice(0, 300);
      console.log(`draft upstream_${upstream.status} ${Date.now() - started}ms`);
      return json({ error: "upstream_error", status: upstream.status, detail }, 502);
    }

    // 5. Stream it back untouched. Sizes and timing only; never content.
    console.log(`draft ok image=${image.length} kb=${knowledgeBase.length} headers=${Date.now() - started}ms`);
    return new Response(upstream.body, {
      status: 200,
      headers: {
        "content-type": "text/event-stream; charset=utf-8",
        "cache-control": "no-store",
        "x-relay-model": env.MODEL,
      },
    });
  },
} satisfies ExportedHandler<Env>;

// MARK: helpers

function bearer(request: Request): string | null {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+([A-Za-z0-9_-]{32,128})$/.exec(header);
  return match ? match[1] : null;
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function stripDataURL(image: string): string {
  const comma = image.startsWith("data:") ? image.indexOf(",") : -1;
  return comma >= 0 ? image.slice(comma + 1) : image;
}

function int(value: string | undefined, fallback: number): number {
  const n = Number.parseInt(value ?? "", 10);
  return Number.isFinite(n) ? n : fallback;
}

function label(error: unknown): string {
  return error instanceof Error ? error.name : "error";
}

function json(payload: unknown, status: number, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...extraHeaders },
  });
}

// MARK: the prompt (the same text the app uses on its direct-key path; keep the two in step)

const INSTRUCTIONS = `**Reply immediately. Do not reason, plan, or deliberate before answering: read the screen, decide, and write the output straight away.**

You are Double Tap, a feature of Sentient OS on this Mac. The user just double-tapped a key while their cursor sat in a text box. The screenshot is their screen at that moment.

Who the user is: the person the knowledge base below describes. They own this Mac and the account on screen: "me" in an email's recipients, the sending side of a chat. Write as them, never as anyone else in the thread.

Step 1: decide whether the focused text box is a reply box for an EMAIL or a MESSAGE (chat, DM, SMS, iMessage, WhatsApp, Slack, Discord, LinkedIn, and the like) that the user is replying to. Code editors, terminals, search fields, forms, notes, documents, spreadsheets, address bars, and a blank compose window with no message to answer are NOT.

If it is NOT, output exactly:
NOT_A_MESSAGE

If it IS, write the reply the user would send:
- Answer the most recent message addressed to the user in the thread the reply box belongs to. Other replies visible on screen are context only; never copy them.
- Write in the user's own voice, grounded in the knowledge base. Use only facts you can see on screen or find in the knowledge base; never invent commitments, dates, or details.
- Match the medium: a chat reply is one or two short casual lines; an email reply has a greeting and a sign-off with the user's first name.
- No em dashes.
Output ONLY the reply text, nothing else. **Answer now, without thinking first.**

=== KNOWLEDGE BASE (everything Sentient knows about the user) ===

`;
