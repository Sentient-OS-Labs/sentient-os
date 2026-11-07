// Exercise actual token admission SQL and gateway using a synthetic provider, no live credits.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createFixture, fixtureJWT, fixturePrincipal} from '../src/fixture.mjs';
import {createScribeGateway} from '../src/scribe.mjs';
import {ServiceError} from '../src/errors.mjs';

async function fixture() {
  const f = await createFixture();
  await f.db.exec(`create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;`);
  await f.db.exec(await readFile(new URL('../../supabase/migrations/20261105010000_hosted_dictation.sql', import.meta.url), 'utf8'));
  const ledger = {async call(operation, args) {
    const {rows} = await f.db.query('select public.hosted_dictation($1,$2) r', [operation, args]);
    const value = rows[0].r;
    if (value.error) throw new ServiceError(value.error, value.status);
    return value;
  }};
  let calls = 0, fail = false;
  const key = 'server-secret-fixture';
  const handler = createScribeGateway({authenticate: f.authenticate, ledger, enabled: true, apiKey: key,
    upstream: async (url, init) => {
      calls++;
      assert.equal(url, 'https://api.elevenlabs.io/v1/single-use-token/realtime_scribe');
      assert.equal(init.headers['xi-api-key'], key);
      assert.equal(init.redirect, 'manual');
      if (fail) return new Response('private provider detail', {status: 429});
      return Response.json({token: 'sutkn_' + 'a'.repeat(40)});
    }});
  async function request(body = {}, token = fixtureJWT, path = '/v1/dictation/token') {
    const response = await handler(new Request('https://fixture.example' + path, {
      method: 'POST', headers: {authorization: 'Bearer ' + token, 'content-type': 'application/json'}, body: JSON.stringify(body),
    }));
    assert.equal(response.headers.get('cache-control'), 'no-store');
    const text = await response.text();
    assert(!text.includes(key)); assert(!text.includes('private provider detail'));
    return {status: response.status, body: JSON.parse(text)};
  }
  const enable = () => f.db.exec(`update public.hosted_dictation_policy set enabled=true,
    user_daily_tokens=20,global_daily_tokens=30,global_monthly_tokens=50,user_minute_tokens=6`);
  return {...f, ledger, request, enable, calls: () => calls, fail: () => {fail = true;}};
}

test('dictation admission is authenticated, disabled by default, and validates client parameters', async () => {
  const f = await fixture();
  try {
    assert.equal((await f.request({}, 'wrong')).status, 401);
    assert.equal((await f.request()).status, 503);
    assert.equal(f.calls(), 0);
    await f.enable();
    for (const body of [{model: 'other'}, {principal_id: fixturePrincipal}, [], null]) {
      assert.equal((await f.request(body)).status, 400);
    }
    assert.equal((await f.request({}, fixtureJWT, '/v1/dictation/token?key=wrong')).status, 400);
    const result = await f.request();
    assert.equal(result.status, 200);
    assert.deepEqual(Object.keys(result.body).sort(), ['token', 'zero_retention']);
    assert.equal(result.body.zero_retention, false);
    assert.equal(f.calls(), 1);
  } finally { await f.db.close(); }
});

test('concurrent token attempts reserve persistent quotas and failures remain counted', async () => {
  const f = await fixture();
  try {
    await f.enable();
    await f.db.exec('update public.hosted_dictation_policy set user_minute_tokens=2');
    const results = await Promise.all(Array.from({length: 6}, () => f.request()));
    assert.equal(results.filter(r => r.status === 200).length, 2);
    assert.equal(results.filter(r => r.status === 429).length, 4);
    assert.equal(f.calls(), 2);
    await f.db.exec("update public.hosted_dictation_issuance set created_at=now()-interval '2 minutes'");
    f.fail();
    assert.equal((await f.request()).status, 503);
    assert.equal((await f.db.query('select count(*)::int n from public.hosted_dictation_issuance')).rows[0].n, 3);
    assert.equal(f.calls(), 3);
  } finally { await f.db.close(); }
});

test('global limits cannot be bypassed by a second installation or a new minute', async () => {
  const f = await fixture();
  try {
    await f.enable();
    await f.db.exec('update public.hosted_dictation_policy set global_daily_tokens=1');
    await f.ledger.call('issue', {principal_id: fixturePrincipal});
    const second = '10000000-0000-4000-8000-000000000002';
    await f.db.query('insert into auth.users(id) values($1)', [second]);
    await assert.rejects(() => f.ledger.call('issue', {principal_id: second}), e => e.code === 'dictation_service_limit');
    await f.db.exec("update public.hosted_dictation_issuance set created_at=date_trunc('day',now())-interval '1 second'; update public.hosted_dictation_policy set global_monthly_tokens=1");
    // This assertion is only month-stable when yesterday belongs to this month; use a same-month date.
    await f.db.exec("update public.hosted_dictation_issuance set created_at=date_trunc('month',now())");
    await assert.rejects(() => f.ledger.call('issue', {principal_id: second}), e => e.code === 'dictation_service_limit');
    await f.db.exec('set role authenticated');
    await assert.rejects(() => f.db.query('select * from public.hosted_dictation_issuance'));
    await assert.rejects(() => f.db.query("select public.hosted_dictation('issue','{}')"));
  } finally { await f.db.close(); }
});

test('caller-scoped RPC admits only its verified JWT identity without administrator access', async () => {
  const f = await fixture();
  try {
    await f.enable();
    await f.db.exec(`set role authenticated`);
    const unauthenticated = await f.db.query('select public.reserve_dictation_token() r');
    assert.equal(unauthenticated.rows[0].r.error, 'authentication_required');
    await f.db.query("select set_config('request.jwt.claim.sub',$1,false)", [fixturePrincipal]);
    assert.equal((await f.db.query('select public.reserve_dictation_token() r')).rows[0].r.accepted, true);
    await assert.rejects(() => f.db.query("select public.hosted_dictation('issue','{}')"));
    await assert.rejects(() => f.db.query('select * from public.hosted_dictation_issuance'));
    await f.db.exec('reset role');
    const rows = (await f.db.query('select principal_id from public.hosted_dictation_issuance')).rows;
    assert.deepEqual(rows, [{principal_id: fixturePrincipal}]);
  } finally { await f.db.close(); }
});
