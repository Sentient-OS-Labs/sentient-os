// Local gateway integration tests. Real PostgreSQL ledger, synthetic credentials and provider.
// Setup: ../README.md.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createFixture, fixtureConfig, fixtureJWT, fixturePrincipal, mockUpstream } from '../src/fixture.mjs';
import worker, { createGateway, streamWithAccounting } from '../src/gateway.mjs';
import { digest, boundedJSON } from '../src/errors.mjs';
import { estimateCost } from '../src/policy.mjs';
import { supabaseServices } from '../src/supabase.mjs';

async function setup(t, options = {}) {
  const fixture = await createFixture(options);
  t.after(() => fixture.db.close());
  const calls = [];
  const upstream = options.upstream ?? (async (url, init) => { calls.push({ url, init }); return mockUpstream(url); });
  const config = { ...fixtureConfig, ...options.config };
  const gateway = createGateway({ ...fixture, config, upstream });
  const request = (path, { token = fixtureJWT, apiKey, body, method = body === undefined ? 'GET' : 'POST', headers = {} } = {}) =>
    gateway(new Request('https://fixture.invalid' + path, { method,
      headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(apiKey ? { 'x-api-key': apiKey } : {}),
        ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
      ...(body !== undefined ? { body: JSON.stringify(body) } : {}) }));
  async function create(purpose = 'sidekick') {
    const response = await request('/v1/runs', { body: { purpose } });
    assert.equal(response.status, 200, await response.clone().text());
    return response.json();
  }
  return { ...fixture, calls, request, create, config, gateway };
}

const message = (model = fixtureConfig.model) => ({ model, max_tokens: 1000, stream: true,
  messages: [{ role: 'user', content: 'Say hello.' }] });

test('SQL migration, role boundaries, UTC clock, caps, purposes and settlement', async t => {
  const fixture = await createFixture();
  t.after(() => fixture.db.close());
  const sql = await readFile(new URL('../../supabase/tests/hosted_inference.sql', import.meta.url), 'utf8');
  await fixture.db.exec(sql);
});

test('API key run authentication, actual cumulative usage and upstream credential replacement', async t => {
  const f = await setup(t);
  const run = await f.create();
  assert.equal(run.model, fixtureConfig.model);
  assert.equal(run.remaining_seconds, 3600);
  assert.equal(run.maximum_output_tokens, fixtureConfig.maximumOutputTokens);
  assert.ok(Date.parse(run.server_time) > 0);
  assert.equal(Date.parse(run.lease_expires_at) - Date.parse(run.server_time), 45_000);
  const response = await f.request('/v1/messages', { token: null, apiKey: run.run_token, body: message(), headers: { 'idempotency-key': 'hello' } });
  assert.equal(response.status, 200, await response.clone().text());
  assert.match(await response.text(), /Local hosted inference fixture is working/);
  const rows = (await f.db.query('select * from public.hosted_inference_requests')).rows;
  assert.equal(rows.length, 1);
  assert.equal(rows[0].status, 'completed');
  assert.equal(rows[0].usage.output_tokens, 9);
  assert.equal(Number(rows[0].charged_microusd), estimateCost({ input_tokens: 32, output_tokens: 9 }, fixtureConfig.pricing));
  assert.ok(Number(rows[0].reserve_microusd) > Number(rows[0].charged_microusd));
  for (const call of f.calls) {
    assert.equal(call.init.headers['x-api-key'], fixtureConfig.upstreamKey);
    assert.equal(call.init.headers.authorization, undefined);
    assert.equal(call.url.startsWith('https://api.anthropic.com/'), true);
  }
  assert.ok(!JSON.stringify(rows).includes('Say hello'));
});

test('conflicting credentials, forged identity and purpose changes cannot dispatch', async t => {
  const f = await setup(t);
  const run = await f.create();
  assert.equal((await f.request('/v1/messages', { token: run.run_token, apiKey: 'different', body: message() })).status, 401);
  assert.equal((await f.request('/v1/runs', { token: 'forged', body: { purpose: 'sidekick' } })).status, 401);
  assert.equal((await f.request(`/v1/runs/${run.run_id}/heartbeat`, { token: run.run_token, body: { purpose: 'knowledge_update' } })).status, 400);
  assert.equal((await f.request('/v1/runs', { body: { purpose: 'unlimited' } })).status, 400);
  assert.equal(f.calls.length, 0);
});

test('simultaneous starts and reserves serialize; replay never dispatches twice', async t => {
  const f = await setup(t);
  const starts = await Promise.all(Array.from({ length: 4 }, () => f.request('/v1/runs', { body: { purpose: 'sidekick' } })));
  assert.equal(starts.filter(result => result.status === 200).length, 1);
  const run = await starts.find(result => result.status === 200).json();
  const runAuth = { token_hash: await digest(run.run_token) };
  const args = { ...runAuth, idempotency_key: 'concurrent', request_hash: '1'.repeat(64), reserve_microusd: 1000 };
  const attempts = await Promise.allSettled(Array.from({ length: 8 }, () => f.ledger.call('reserve', args)));
  assert.equal(attempts.filter(result => result.status === 'fulfilled').length, 1);
  const requestID = attempts.find(result => result.status === 'fulfilled').value.request_id;
  await f.ledger.call('settle', { ...runAuth, request_id: requestID, actual_microusd: 100, status: 'completed' });
  await assert.rejects(f.ledger.call('reserve', args), error => error.code === 'request_already_dispatched');
  const sum = (await f.db.query('select sum(charged_microusd) total from public.hosted_inference_requests')).rows[0].total;
  assert.equal(Number(sum), 100);
});

test('retries through HTTP retain idempotency and reject altered request body', async t => {
  const f = await setup(t);
  const run = await f.create();
  const call = body => f.request('/v1/messages', { token: run.run_token, body, headers: { 'idempotency-key': 'repeat' } });
  await (await call(message())).text();
  const duplicate = await call(message());
  assert.equal(duplicate.status, 409);
  assert.equal((await duplicate.json()).error.code, 'request_already_dispatched');
  const changed = await call({ ...message(), max_tokens: 200 });
  assert.equal((await changed.json()).error.code, 'idempotency_conflict');
  assert.equal(f.calls.filter(call => call.url.endsWith('/messages')).length, 1);
});

test('shared global budget rejects another principal before provider dispatch', async t => {
  const f = await setup(t, { budgetMicrousd: 1000 });
  const a = await f.create();
  const auth = { token_hash: await digest(a.run_token) };
  await f.ledger.call('reserve', { ...auth, idempotency_key: 'a', request_hash: 'a'.repeat(64), reserve_microusd: 900 });
  const second = '10000000-0000-4000-8000-000000000002';
  await f.db.query('insert into auth.users(id) values($1)', [second]);
  const b = await f.ledger.call('create', { principal_id: second, purpose: 'sidekick', token_hash: 'b'.repeat(64), model: 'fixture' });
  await assert.rejects(f.ledger.call('reserve', { token_hash: 'b'.repeat(64), idempotency_key: 'b', request_hash: 'b'.repeat(64), reserve_microusd: 200 }),
    error => error.code === 'service_budget_reached');
  assert.ok(b.run_id);
  assert.equal(f.calls.length, 0);
});

test('pause excludes waiting, stops inference, and resumes with the same purpose', async t => {
  const f = await setup(t);
  const run = await f.create();
  const pause = await f.request(`/v1/runs/${run.run_id}/pause`, { token: run.run_token, body: {} });
  assert.equal((await pause.json()).phase, 'waiting_for_user');
  assert.equal((await f.request('/v1/messages', { token: run.run_token, body: message() })).status, 409);
  const resume = await f.request(`/v1/runs/${run.run_id}/resume`, { token: run.run_token, body: {} });
  assert.equal((await resume.json()).purpose, 'sidekick');
  const end = await f.request(`/v1/runs/${run.run_id}/finish`, { token: run.run_token, body: {} });
  assert.equal((await end.json()).phase, 'completed');
  assert.equal((await f.request('/v1/messages', { token: run.run_token, body: message() })).status, 429);
});

test('upstream errors never echo provider bodies and uncertain failure keeps reserve', async t => {
  const f = await setup(t, { upstream: async url => url.endsWith('count_tokens') ? Response.json({ input_tokens: 10 })
    : new Response('secret provider content and upstream-key', { status: 500 }) });
  const run = await f.create();
  const response = await f.request('/v1/messages', { token: run.run_token, body: message() });
  const text = await response.text();
  assert.equal(response.status, 503);
  assert.doesNotMatch(text, /secret|upstream-key/);
  const row = (await f.db.query('select * from public.hosted_inference_requests')).rows[0];
  assert.equal(row.charged_microusd, row.reserve_microusd);
});

test('model/output/paid tool bounds cannot be client overridden', async t => {
  const f = await setup(t);
  const run = await f.create();
  for (const body of [message('expensive-model'), { ...message(), max_tokens: 100_000 },
    { ...message(), tools: [{ type: 'web_search_20250305', name: 'web_search' }] },
    { ...message(), endpoint: 'https://untrusted.invalid' }, { ...message(), service_tier: 'priority' }]) {
    assert.equal((await f.request('/v1/messages', { token: run.run_token, body })).status, 400);
  }
  assert.equal(f.calls.length, 0);
});

test('actual body size is bounded when content-length is absent', async () => {
  const request = new Request('https://fixture.invalid', { method: 'POST', body: JSON.stringify({ text: 'x'.repeat(1000) }) });
  await assert.rejects(boundedJSON(request, 100), error => error.code === 'request_too_large');
});

test('missing production configuration never falls back to fixture storage or auth', async () => {
  const response = await worker.fetch(new Request('https://fixture.invalid/v1/usage'), {}, {});
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, 'service_not_configured');
});

test('caller auth is checked with Supabase, not decoded without verification', async () => {
  const calls = [];
  const services = supabaseServices({ url: 'https://project.supabase.co', publishableKey: 'public-fixture', serviceRoleKey: 'server-fixture',
    fetcher: async (url, init) => { calls.push({ url, init }); return new Response('denied', { status: 401 }); } });
  await assert.rejects(services.authenticate('forged.payload.signature'), error => error.code === 'authentication_required');
  assert.equal(new URL(calls[0].url).pathname, '/auth/v1/user');
  assert.equal(calls[0].init.headers.apikey, 'public-fixture');
});

test('SSE usage replaces cumulative deltas, accounts cache tokens and supports split CRLF', async () => {
  const events = [
    { type: 'message_start', message: { usage: { input_tokens: 10, output_tokens: 1, cache_read_input_tokens: 100, cache_creation_input_tokens: 50 } } },
    { type: 'message_delta', usage: { output_tokens: 5 } },
    { type: 'message_delta', usage: { output_tokens: 9 } },
    { type: 'message_stop' },
  ];
  const source = events.map(event => `data: ${JSON.stringify(event)}\r\n\r\n`).join('');
  let index = 0;
  const body = new ReadableStream({ pull(controller) {
    if (index >= source.length) controller.close();
    else controller.enqueue(new TextEncoder().encode(source.slice(index, ++index)));
  } });
  let settled;
  const abort = new AbortController();
  const stream = streamWithAccounting(body, { signal: abort.signal, abort: () => abort.abort(), finalize: async (usage, status) => { settled = { usage, status }; } });
  await new Response(stream.readable).text();
  await stream.done;
  assert.equal(settled.status, 'completed');
  assert.deepEqual(settled.usage, { input_tokens: 10, output_tokens: 9, cache_read_input_tokens: 100, cache_creation_input_tokens: 50 });
});

test('truncated and cancelled streams settle conservatively without a fake success', async () => {
  for (const cancel of [false, true]) {
    const abort = new AbortController();
    let settled;
    const body = new ReadableStream({ start(controller) {
      controller.enqueue(new TextEncoder().encode('data: {"type":"message_start","message":{"usage":{"input_tokens":50,"output_tokens":1}}}\n\n'));
      if (!cancel) controller.close();
    } });
    const stream = streamWithAccounting(body, { signal: abort.signal, abort: () => abort.abort(), finalize: async (usage, status) => { settled = { usage, status }; } });
    if (cancel) { const reader = stream.readable.getReader(); await reader.read(); await reader.cancel(); }
    else assert.match(await new Response(stream.readable).text(), /hosted_stream_interrupted/);
    await stream.done;
    assert.equal(settled.usage, null);
  }
});

test('usage distinguishes disabled policy, global exhaustion and personal budget exhaustion', async t => {
  const f = await setup(t);
  await f.db.query('update public.hosted_inference_policy set enabled=false');
  let response = await f.request('/v1/usage');
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, 'service_disabled');
  await f.db.query('update public.hosted_inference_policy set enabled=true,user_daily_microusd=0');
  assert.equal((await f.request('/v1/usage')).status, 503);
  await f.db.query('update public.hosted_inference_policy set user_daily_microusd=100');
  await f.db.query('update public.hosted_inference_daily set charged_microusd=100 where principal_id=$1', [fixturePrincipal]);
  response = await f.request('/v1/usage');
  assert.equal(response.status, 429);
  assert.equal((await response.json()).error.code, 'usage_limit_reached');
  await f.db.query("insert into public.hosted_inference_global(bucket,charged_microusd) values('day:'||(clock_timestamp() at time zone 'UTC')::date::text,10000000)");
  response = await f.request('/v1/usage');
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, 'service_budget_reached');
});

test('no-header retries use body fingerprint, including after SDK-style retry', async t => {
  const f = await setup(t);
  const run = await f.create();
  await (await f.request('/v1/messages', { token: run.run_token, body: message() })).text();
  const duplicate = await f.request('/v1/messages', { token: run.run_token, body: message() });
  assert.equal((await duplicate.json()).error.code, 'request_already_dispatched');
  assert.equal(f.calls.filter(call => call.url.endsWith('/messages')).length, 1);
});

test('provider file references are refused but ordinary tool argument file IDs remain data', async t => {
  const f = await setup(t);
  const run = await f.create();
  const bad = { ...message(), messages: [{ role: 'user', content: [{ type: 'document', source: { type: 'file', file_id: 'someone-elses-provider-file' } }] }] };
  assert.equal((await f.request('/v1/messages', { token: run.run_token, body: bad })).status, 400);
  const good = { ...message(), messages: [{ role: 'assistant', content: [{ type: 'tool_use', id: 'tool-1', name: 'read_drive', input: { file_id: 'a-local-connector-file' } }] },
    { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tool-1', content: 'Example result' }] }] };
  const response = await f.request('/v1/messages', { token: run.run_token, body: good });
  assert.equal(response.status, 200);
  await response.text();
});

test('server remaining-time deadline cancels inference before the normal provider timeout', async () => {
  const settled = [];
  const run = { run_id: crypto.randomUUID(), model: fixtureConfig.model, purpose: 'sidekick', remaining_seconds: 0.025,
    server_time: new Date().toISOString(), lease_expires_at: new Date(Date.now() + 45000).toISOString() };
  const ledger = { call: async (operation, args) => {
    if (operation === 'settle') { settled.push(args); return {}; }
    return { ...run, request_id: crypto.randomUUID() };
  } };
  const gateway = createGateway({ ledger, authenticate: async () => fixturePrincipal,
    config: { ...fixtureConfig, requestTimeoutMS: 3000 },
    upstream: async url => url.endsWith('count_tokens') ? Response.json({ input_tokens: 10 })
      : new Response(new ReadableStream({ start() {} })) });
  const start = performance.now();
  const response = await gateway(new Request('https://fixture.invalid/v1/messages', { method: 'POST',
    headers: { authorization: `Bearer hrt_${'a'.repeat(64)}`, 'content-type': 'application/json' }, body: JSON.stringify(message()) }));
  assert.match(await response.text(), /hosted_stream_interrupted/);
  assert.ok(performance.now() - start < 1000);
  assert.equal(settled.length, 1);
  assert.equal(settled[0].actual_microusd, null);
});

test('an aborted idle downstream gets a terminal stream and conservative settlement', async () => {
  const abort = new AbortController();
  const receipts = [];
  const body = new ReadableStream({ start(controller) {
    controller.enqueue(new TextEncoder().encode('data: {"type":"message_start","message":{"usage":{"input_tokens":20,"output_tokens":1}}}\n\n'));
  } });
  const stream = streamWithAccounting(body, { signal: abort.signal, abort: () => abort.abort(), finalize: async (usage, status) => receipts.push({ usage, status }) });
  // Let the stream fill its high-water mark without a downstream consumer.
  await new Promise(resolve => setTimeout(resolve, 5));
  abort.abort();
  await stream.done;
  assert.match(await new Response(stream.readable).text(), /hosted_stream_interrupted/);
  assert.equal(receipts.length, 1);
  assert.equal(receipts[0].usage, null);
});

test('a model deployment change cannot reuse stale run pricing', async t => {
  const f = await setup(t);
  const run = await f.create();
  await f.db.query('update public.hosted_inference_runs set model=$1 where id=$2', ['old-model', run.run_id]);
  const response = await f.request('/v1/messages', { token: run.run_token, body: message('old-model') });
  assert.equal(response.status, 409);
  assert.equal((await response.json()).error.code, 'model_configuration_changed');
  assert.equal(f.calls.length, 0);
});

test('SDK beta routing marker is accepted without allowing arbitrary queries or headers', async t => {
  const f = await setup(t);
  const run = await f.create();
  const response = await f.request('/v1/messages?beta=true', { token: run.run_token, body: message(), headers: { 'anthropic-beta': 'unapproved-feature' } });
  assert.equal(response.status, 200);
  await response.text();
  assert.equal(f.calls.find(call => call.url.endsWith('/messages')).init.headers['anthropic-beta'], undefined);
  for (const path of ['/v1/messages?beta=false','/v1/messages?beta=true&beta=true','/v1/messages?override=1','/v1/runs?beta=true']) {
    assert.equal((await f.request(path, { token: run.run_token, body: message() })).status, 400);
  }
});

test('terminal usage settles before message_stop is delivered even when upstream EOF stalls', async () => {
  const abort = new AbortController();
  let release;
  const settlement = new Promise(resolve => { release = resolve; });
  const events = [
    { type: 'message_start', message: { usage: { input_tokens: 2, output_tokens: 1 } } },
    { type: 'message_delta', usage: { output_tokens: 5 } },
    { type: 'message_stop' },
  ];
  const body = new ReadableStream({ start(controller) {
    controller.enqueue(new TextEncoder().encode(events.map(event => `data: ${JSON.stringify(event)}\n\n`).join('')));
    // Deliberately no close: message_stop itself is the terminal provider receipt.
  } });
  const stream = streamWithAccounting(body, { signal: abort.signal, abort: () => abort.abort(), finalize: async () => settlement });
  const reader = stream.readable.getReader();
  let delivered = '';
  let stopped = false;
  const consume = (async () => {
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      delivered += new TextDecoder().decode(part.value);
      if (delivered.includes('message_stop')) stopped = true;
    }
  })();
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.equal(stopped, false);
  release();
  await consume;
  await stream.done;
  assert.equal(stopped, true);
});

test('Claude safeguard context and per-turn output settings survive with server-owned betas', async t => {
  const betas = 'context-management-2025-06-27,mid-conversation-output-config-2026-07-01,dangerous-tool-use-2026-09-03';
  const f = await setup(t, { config: { betas } });
  const run = await f.create();
  const body = { ...message(),
    messages: [...message().messages, { role: 'system', content: [], output_config: { effort: 'low' } }],
    context_management: { edits: [{ type: 'clear_thinking_20251015', keep: 'all' }] },
    thinking: { type: 'adaptive', display: 'omitted' },
    safeguards: [{ type: 'dangerous_tool_use', classifier_context: { v: 1, permission_mode: 'auto' } }] };
  const response = await f.request('/v1/messages?beta=true', { token: run.run_token, body,
    headers: { 'anthropic-beta': 'unreviewed-client-beta' } });
  assert.equal(response.status, 200);
  await response.text();
  const dispatch = f.calls.find(call => call.url.endsWith('/messages'));
  assert.deepEqual(JSON.parse(dispatch.init.body).safeguards, body.safeguards);
  assert.deepEqual(JSON.parse(dispatch.init.body).messages[1].output_config, { effort: 'low' });
  assert.equal(dispatch.init.headers['anthropic-beta'], betas);
  const rejected = await f.request('/v1/messages', { token: run.run_token,
    body: { ...body, safeguards: [{ type: 'dangerous_tool_use', classifier_context: {}, disabled: true }] } });
  assert.equal(rejected.status, 400);
  assert.equal((await rejected.json()).error.code, 'safeguard_configuration_not_allowed');
});

test('a stalled heartbeat cannot extend inference past its acknowledged lease', async () => {
  let heartbeatCount = 0;
  const settled = [];
  const run = { run_id: crypto.randomUUID(), model: fixtureConfig.model, purpose: 'knowledge_update', remaining_seconds: 3600,
    server_time: new Date().toISOString(), lease_expires_at: new Date(Date.now() + 60).toISOString() };
  const ledger = { call: async (operation, args) => {
    if (operation === 'settle') { settled.push(args); return {}; }
    if (operation === 'heartbeat') { heartbeatCount++; return new Promise(() => {}); }
    return { ...run, request_id: crypto.randomUUID() };
  } };
  const gateway = createGateway({ ledger, authenticate: async () => fixturePrincipal,
    config: { ...fixtureConfig, requestTimeoutMS: 3000 },
    upstream: async url => url.endsWith('count_tokens') ? Response.json({ input_tokens: 10 })
      : new Response(new ReadableStream({ start() {} })) });
  const start = performance.now();
  const response = await gateway(new Request('https://fixture.invalid/v1/messages', { method: 'POST',
    headers: { authorization: `Bearer hrt_${'a'.repeat(64)}`, 'content-type': 'application/json' }, body: JSON.stringify(message()) }));
  assert.match(await response.text(), /hosted_stream_interrupted/);
  assert.ok(performance.now() - start < 1000);
  assert.equal(heartbeatCount, 1);
  assert.equal(settled.length, 1);
  assert.equal(settled[0].actual_microusd, null);
});

test('a terminal stream with missing input usage retains the full reservation', async () => {
  const abort = new AbortController();
  const receipts = [];
  const body = new Response([
    'data: {"type":"message_start","message":{"usage":{"output_tokens":1}}}\n\n',
    'data: {"type":"message_delta","usage":{"output_tokens":5}}\n\n',
    'data: {"type":"message_stop"}\n\n',
  ].join('')).body;
  const stream = streamWithAccounting(body, { signal: abort.signal, abort: () => abort.abort(),
    finalize: async (usage, status) => receipts.push({ usage, status }) });
  assert.match(await new Response(stream.readable).text(), /hosted_stream_interrupted/);
  assert.equal(receipts.length, 1);
  assert.equal(receipts[0].usage, null);
});
