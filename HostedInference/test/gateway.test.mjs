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
