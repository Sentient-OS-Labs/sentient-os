// Local-only PostgreSQL WASM fixture: tests exercise the real migration and accounting RPC.
// This module is never imported by the production Worker. Setup: ../README.md.
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
import { ServiceError } from './errors.mjs';

export const fixturePrincipal = '10000000-0000-4000-8000-000000000001';
export const fixtureJWT = 'local-fixture-token';

export async function createFixture({ budgetMicrousd = 10_000_000, enabled = true } = {}) {
  const db = new PGlite();
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth; create table auth.users(id uuid primary key);
    insert into auth.users(id) values ('${fixturePrincipal}');
  `);
  const migration = await readFile(new URL('../../supabase/migrations/20261029010000_hosted_inference.sql', import.meta.url), 'utf8');
  await db.exec(migration);
  await db.query(`update public.hosted_inference_policy set enabled=$1,
    user_daily_microusd=$2,background_daily_microusd=$2,bootstrap_lifetime_microusd=$2,
    global_daily_microusd=$2,global_monthly_microusd=$2`, [enabled, budgetMicrousd]);
  const ledger = { async call(operation, args) {
    const result = await db.query('select public.hosted_inference($1,$2::jsonb) as result', [operation, JSON.stringify(args)]);
    const value = result.rows[0].result;
    if (value.error) throw new ServiceError(value.error, value.status ?? 429, value.details ?? {});
    return value;
  } };
  return { db, ledger, authenticate: async token => {
    if (token !== fixtureJWT) throw new ServiceError('authentication_required', 401);
    return fixturePrincipal;
  } };
}

export const fixtureConfig = {
  model: 'claude-local-fixture', upstreamKey: 'fixture-only-not-a-provider-key',
  pricing: { input: 3_000_000, output: 15_000_000, cacheWrite: 6_000_000, cacheRead: 300_000 },
  maximumInputTokens: 200_000, maximumOutputTokens: 16_000, maximumBodyBytes: 8_000_000,
  requestTimeoutMS: 120_000, leaseCheckMS: 10_000, betas: '',
};

export function mockUpstream(url) {
  if (url.endsWith('/count_tokens')) return Response.json({ input_tokens: 32 });
  const events = [
    { type: 'message_start', message: { id: 'msg_fixture', type: 'message', role: 'assistant', model: fixtureConfig.model,
      content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 32, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } } },
    { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
    { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Local hosted inference fixture is working.' } },
    { type: 'content_block_stop', index: 0 },
    { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 9 } },
    { type: 'message_stop' },
  ];
  return new Response(events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(''),
    { headers: { 'content-type': 'text/event-stream' } });
}
