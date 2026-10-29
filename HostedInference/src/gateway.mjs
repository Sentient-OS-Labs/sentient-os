// Authenticated streaming Anthropic gateway with persistent reservations and safe usage receipts.
// Setup and contract: ../README.md. createGateway injection is for tests; default export is fail-closed.
import { bearer, boundedJSON, digest, errorResponse, randomToken, ServiceError } from './errors.mjs';
import { PURPOSES, estimateCost, prepareMessage, readProductionConfig, validateConfiguration } from './policy.mjs';
import { supabaseServices } from './supabase.mjs';

const encoder = new TextEncoder();
const responseJSON = body => Response.json(body, { headers: { 'cache-control': 'no-store' } });
const jsonHeaders = { 'content-type': 'application/json' };

export function createGateway({ ledger, authenticate, config, upstream = fetch, observe = () => {}, debugShapes = false }) {
  validateConfiguration(config);
  if (!ledger?.call || !authenticate) throw new Error('A ledger and token validator are required');
  const snapshotResponse = body => responseJSON({ ...body, maximum_output_tokens: config.maximumOutputTokens });
  const credentials = async request => {
    const token = bearer(request, { allowAPIKey: true });
    if (!/^hrt_[a-f0-9]{64}$/.test(token)) throw new ServiceError('authentication_required', 401);
    return { token_hash: await digest(token) };
  };
  const upstreamHeaders = () => ({ ...jsonHeaders, 'x-api-key': config.upstreamKey,
    'anthropic-version': '2023-06-01', ...(config.betas ? { 'anthropic-beta': config.betas } : {}) });
  async function countTokens(body, signal) {
    const allowed = ['model', 'messages', 'system', 'tools', 'tool_choice', 'thinking', 'context_management'];
    const data = Object.fromEntries(allowed.filter(key => body[key] !== undefined).map(key => [key, body[key]]));
    let response;
    try {
      response = await upstream('https://api.anthropic.com/v1/messages/count_tokens', {
        method: 'POST', headers: upstreamHeaders(), body: JSON.stringify(data),
        redirect: 'error', signal,
      });
    } catch { throw new ServiceError('upstream_unavailable', 503); }
    if (!response.ok) throw upstreamError(response.status);
    let counted;
    try { counted = await boundedJSON(response, 128_000); } catch { throw new ServiceError('upstream_unavailable', 502); }
    if (!Number.isSafeInteger(counted.input_tokens) || counted.input_tokens < 0) throw new ServiceError('invalid_upstream_usage', 502);
    if (counted.input_tokens > config.maximumInputTokens) throw new ServiceError('context_limit_exceeded', 413);
    return { input_tokens: counted.input_tokens };
  }
  return async function handle(request, context = {}) {
    const requestID = crypto.randomUUID();
    try {
      const url = new URL(request.url);
      if (url.search || url.hash) throw new ServiceError('invalid_request');
      const path = url.pathname;
      if (path === '/health' && request.method === 'GET') return responseJSON({ status: 'ok' });
      if (path === '/v1/usage' && request.method === 'GET') {
        const principal_id = await authenticate(bearer(request));
        return snapshotResponse(await ledger.call('usage', { principal_id }));
      }
      if (path === '/v1/runs' && request.method === 'POST') {
        const principal_id = await authenticate(bearer(request));
        const body = await boundedJSON(request, 4096);
        if (Object.keys(body).some(key => key !== 'purpose') || !PURPOSES.has(body.purpose)) throw new ServiceError('invalid_purpose');
        const run_token = randomToken();
        const run = await ledger.call('create', { principal_id, purpose: body.purpose,
          token_hash: await digest(run_token), model: config.model });
        return snapshotResponse({ ...run, run_token });
      }
      const control = path.match(/^\/v1\/runs\/([a-f0-9-]{36})\/(heartbeat|pause|resume|finish)$/i);
      if (control && request.method === 'POST') {
        const auth = await credentials(request);
        const body = request.body ? await boundedJSON(request, 4096) : {};
        if (Object.keys(body).length) throw new ServiceError('invalid_request');
        return snapshotResponse(await ledger.call(control[2], { ...auth, run_id: control[1] }));
      }
      if ((path === '/v1/models' && request.method === 'GET') || (path === '/v1/messages/count_tokens' && request.method === 'POST')) {
        const auth = await credentials(request);
        const run = await ledger.call('probe', auth);
        if (run.model !== config.model) throw new ServiceError('model_configuration_changed', 409);
        if (path === '/v1/models') return responseJSON({ data: [{ id: run.model, type: 'model', display_name: run.model }],
          has_more: false, first_id: run.model, last_id: run.model });
        const body = await boundedJSON(request, config.maximumBodyBytes);
        if (body.model !== run.model) throw new ServiceError('model_not_allowed');
        // Apply the same tool and feature wall to token counting. A count cannot invoke a
        // separate hosted tool or read a provider file on behalf of the caller.
        const prepared = prepareMessage({ ...body, max_tokens: 1, stream: true }, run.model, config);
        return responseJSON(await countTokens(prepared.body, AbortSignal.any([request.signal, AbortSignal.timeout(15_000)])));
      }
      if (path !== '/v1/messages' || request.method !== 'POST') throw new ServiceError('not_found', 404);
      const auth = await credentials(request);
      const run = await ledger.call('inspect', auth);
      if (run.model !== config.model) throw new ServiceError('model_configuration_changed', 409);
      const body = await boundedJSON(request, config.maximumBodyBytes);
      if (debugShapes) {
        const name = value => typeof value === 'string' && /^[A-Za-z0-9_]{1,80}$/.test(value) ? value : '[other]';
        observe({ event: 'fixture_request_shape', keys: Object.keys(body).map(name),
          tool_types: Array.isArray(body.tools) ? [...new Set(body.tools.map(tool => name(tool.type ?? 'custom')))] : [] });
      }
      const prepared = prepareMessage(body, run.model, config);
      const inputHash = await digest(JSON.stringify(prepared.body));
      // CLI SDKs do not all expose idempotency headers. Identical messages in the same run
      // default to one admission; callers can explicitly request a new attempt with a new key.
      const idempotency = request.headers.get('idempotency-key') ?? request.headers.get('x-idempotency-key') ?? inputHash;
      if (!/^[A-Za-z0-9_.:-]{1,128}$/.test(idempotency)) throw new ServiceError('invalid_idempotency_key');
      // Read-only token counting is bounded separately and cannot create a billable request.
      await ledger.call('probe', auth);
      await countTokens(prepared.body, AbortSignal.any([request.signal, AbortSignal.timeout(15_000)]));
      const reservationStarted = performance.now();
      const reservation = await ledger.call('reserve', { ...auth, idempotency_key: idempotency,
        request_hash: inputHash, reserve_microusd: prepared.reserveMicrousd });
      const controller = new AbortController();
      const combined = AbortSignal.any([controller.signal, request.signal]);
      let timedOut = false;
      const quotaDeadlineMS = run.purpose === 'sidekick'
        ? Math.max(0, reservation.remaining_seconds * 1000 - (performance.now() - reservationStarted))
        : config.requestTimeoutMS;
      const deadline = setTimeout(() => { timedOut = true; controller.abort(); }, Math.min(config.requestTimeoutMS, quotaDeadlineMS));
      let leaseTimer;
      let finalized = false;
      let finalizePromise;
      const finalize = (usage, status) => {
        if (finalizePromise) return finalizePromise;
        finalized = true;
        clearTimeout(deadline);
        clearTimeout(leaseTimer);
        finalizePromise = ledger.call('settle', { ...auth, request_id: reservation.request_id,
          actual_microusd: usage ? estimateCost(usage, config.pricing) : null,
          usage: usage ?? {}, status }).catch(() => {
            // A committed reservation survives a settlement outage. Never invent a refund.
            observe({ event: 'settlement_pending', request_id: reservation.request_id });
          });
        return finalizePromise;
      };
      const checkLease = async () => {
        if (finalized) return;
        try { await ledger.call('heartbeat', auth); }
        catch { controller.abort(); return; }
        if (!finalized) leaseTimer = setTimeout(checkLease, config.leaseCheckMS);
      };
      leaseTimer = setTimeout(checkLease, config.leaseCheckMS);
      let response;
      try {
        response = await upstream('https://api.anthropic.com/v1/messages', {
          method: 'POST', headers: upstreamHeaders(), body: JSON.stringify(prepared.body),
          redirect: 'error', signal: combined,
        });
      } catch {
        await finalize(null, timedOut ? 'timeout' : 'unknown');
        throw new ServiceError('upstream_unavailable', 503);
      }
      if (!response.ok || !response.body) {
        // A definite upstream HTTP rejection carries no successful inference receipt.
        // Server errors can have an uncertain execution outcome, so retain their reservation.
        await finalize(response.status >= 400 && response.status < 500 ? {} : null, 'rejected');
        await response.body?.cancel();
        throw upstreamError(response.status);
      }
      const stream = streamWithAccounting(response.body, {
        signal: combined,
        abort: () => controller.abort(),
        finalize,
        observe,
        maximumEventBytes: config.maximumBodyBytes,
      });
      // Workers must retain settlement work after a disconnect; the stream's completion
      // promise settles only after the conservative/actual ledger write has been attempted.
      context.waitUntil?.(stream.done);
      return new Response(stream.readable, { status: 200, headers: {
        'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-store',
        'x-request-id': requestID, 'x-hosted-request-id': reservation.request_id,
        'x-hosted-run-id': run.run_id, 'x-hosted-model': run.model,
      } });
    } catch (error) {
      observe({ event: 'request_rejected', code: error instanceof ServiceError ? error.code : 'internal_error', request_id: requestID });
      return errorResponse(error, requestID);
    }
  };
}

function upstreamError(status) {
  if (status === 429) return new ServiceError('upstream_rate_limited', 503);
  if (status === 400 || status === 413) return new ServiceError('upstream_request_rejected', 400);
  return new ServiceError('upstream_unavailable', 503);
}

export function streamWithAccounting(body, { signal, abort, finalize, maximumEventBytes = 8_000_000 }) {
  const reader = body.getReader();
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let buffer = '';
  let usage = {};
  let sawStart = false;
  let sawFinalUsage = false;
  let sawStop = false;
  let closed = false;
  let resolveDone;
  const done = new Promise(resolve => { resolveDone = resolve; });
  const finish = async status => {
    if (closed) return;
    closed = true;
    signal.removeEventListener('abort', onAbort);
    try { await finalize(sawStart && sawFinalUsage && sawStop ? usage : null, status); }
    finally { resolveDone(); }
  };
  const onAbort = () => {
    reader.cancel().catch(() => {});
    // A downstream reader that stops pulling must not strand a reservation forever.
    void finish('cancelled');
  };
  signal.addEventListener('abort', onAbort, { once: true });
  const readable = new ReadableStream({
    async pull(controller) {
      if (closed) return;
      try {
        let produced = false;
        while (!produced) {
        if (signal.aborted) throw new Error('aborted');
        const { done: ended, value } = await reader.read();
        if (ended) {
          buffer += decoder.decode();
          if (buffer.trim()) throw new Error('truncated_sse');
          if (!sawStop || !sawFinalUsage) throw new Error('missing_terminal_receipt');
          await finish('completed');
          controller.close();
          return;
        }
        buffer = (buffer + decoder.decode(value, { stream: true })).replace(/\r\n/g, '\n');
        if (encoder.encode(buffer).byteLength > maximumEventBytes) throw new Error('oversized_event');
        let boundary;
        while ((boundary = buffer.indexOf('\n\n')) !== -1) {
          const frame = buffer.slice(0, boundary);
          buffer = buffer.slice(boundary + 2);
          const data = frame.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
          if (data) {
            const event = JSON.parse(data);
            if (event.type === 'error') throw new Error('provider_stream_error');
            if (event.type === 'message_start') {
              if (sawStart) throw new Error('duplicate_message_start');
              sawStart = true;
              usage = cleanUsage(event.message?.usage);
            } else if (event.type === 'message_delta' && event.usage) {
              // Anthropic usage fields in stream deltas are cumulative, never additive.
              const next = cleanUsage(event.usage);
              for (const [key, value] of Object.entries(next)) {
                if (value < (usage[key] ?? 0)) throw new Error('decreasing_usage');
                usage[key] = value;
              }
              if (Object.hasOwn(next, 'output_tokens')) sawFinalUsage = true;
            } else if (event.type === 'message_stop') {
              if (!sawStart || !sawFinalUsage || sawStop) throw new Error('invalid_terminal_receipt');
              sawStop = true;
            }
          }
          controller.enqueue(encoder.encode(frame + '\n\n'));
          produced = true;
        }
        }
      } catch {
        abort();
        await reader.cancel().catch(() => {});
        await finish(signal.aborted ? 'cancelled' : 'unknown');
        // Never emit a provider error payload, which may echo input data or credentials.
        try {
          controller.enqueue(encoder.encode('event: error\ndata: {"type":"error","error":{"type":"hosted_stream_interrupted","message":"The hosted response was interrupted."}}\n\n'));
          controller.close();
        } catch { /* The downstream may already have disconnected. */ }
      }
    },
    async cancel() {
      abort();
      await reader.cancel().catch(() => {});
      await finish('cancelled');
    },
  });
  return { readable, done };
}

function cleanUsage(value) {
  if (!value || typeof value !== 'object') throw new Error('missing_usage');
  const allowed = ['input_tokens', 'output_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens'];
  const result = {};
  for (const key of allowed) {
    if (value[key] === undefined) continue;
    if (!Number.isSafeInteger(value[key]) || value[key] < 0) throw new Error('invalid_usage');
    result[key] = value[key];
  }
  return result;
}

export default {
  async fetch(request, env, context) {
    try {
      const services = supabaseServices({ url: env.SUPABASE_URL, publishableKey: env.SUPABASE_PUBLISHABLE_KEY,
        serviceRoleKey: env.SUPABASE_SERVICE_ROLE_KEY });
      return await createGateway({ ...services, config: readProductionConfig(env) })(request, context);
    } catch { return errorResponse(new ServiceError('service_not_configured', 503), crypto.randomUUID()); }
  },
};
