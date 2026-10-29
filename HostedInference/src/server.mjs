// Loopback Node development server. --fixture is explicit, isolated and never a production fallback.
// Setup and contract: ../README.md. This server never logs request headers or bodies.
import http from 'node:http';
import { Readable } from 'node:stream';
import { once } from 'node:events';
import worker, { createGateway } from './gateway.mjs';
import { readProductionConfig } from './policy.mjs';

const fixture = process.argv.includes('--fixture');
const live = process.argv.includes('--live-upstream');
if (live && !fixture) throw new Error('--live-upstream is only used with the explicit local fixture');
const port = Number(process.env.PORT ?? 8788);
if (!Number.isSafeInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port');
let handler;
let database;
if (fixture) {
  const { createFixture, fixtureConfig, fixtureJWT, mockUpstream } = await import('./fixture.mjs');
  const testBudget = live ? Number(process.env.HOSTED_TEST_BUDGET_MICROUSD) : 10_000_000;
  if (live && (!Number.isSafeInteger(testBudget) || testBudget < 1 || testBudget > 5_000_000)) {
    throw new Error('Live local tests require an explicit positive HOSTED_TEST_BUDGET_MICROUSD of at most $5');
  }
  const services = await createFixture({ budgetMicrousd: testBudget });
  database = services.db;
  handler = createGateway({ ...services, config: live ? readProductionConfig(process.env) : fixtureConfig,
    upstream: live ? fetch : mockUpstream });
  process.stdout.write(`Fixture authentication: ${fixtureJWT}\n`);
} else {
  // Validate configuration before listening. Production mode also requires persistent Supabase.
  readProductionConfig(process.env);
  for (const key of ['SUPABASE_URL','SUPABASE_PUBLISHABLE_KEY','SUPABASE_SERVICE_ROLE_KEY']) {
    if (!process.env[key]) throw new Error(`${key} is required`);
  }
  handler = (request, context) => worker.fetch(request, process.env, context);
}
const server = http.createServer(async (incoming, outgoing) => {
  const abort = new AbortController();
  incoming.on('aborted', () => abort.abort());
  outgoing.on('close', () => { if (!outgoing.writableEnded) abort.abort(); });
  try {
    const request = new Request(`http://127.0.0.1:${port}${incoming.url}`, {
      method: incoming.method, headers: incoming.headers, signal: abort.signal,
      ...(incoming.method !== 'GET' && incoming.method !== 'HEAD' ? { body: Readable.toWeb(incoming), duplex: 'half' } : {}),
    });
    const response = await handler(request, { waitUntil: promise => { promise.catch(() => {}); } });
    outgoing.writeHead(response.status, Object.fromEntries(response.headers));
    if (response.body) for await (const chunk of response.body) {
      if (!outgoing.write(chunk)) await once(outgoing, 'drain');
    }
    outgoing.end();
  } catch {
    abort.abort();
    if (!outgoing.headersSent) outgoing.writeHead(503, { 'content-type': 'application/json' });
    outgoing.end('{"error":{"type":"service_unavailable"}}');
  }
});
server.listen(port, '127.0.0.1', () => process.stdout.write(`Hosted inference ${fixture ? 'fixture' : 'gateway'}: http://127.0.0.1:${port}\n`));
for (const signal of ['SIGINT','SIGTERM']) process.on(signal, () => {
  server.close(async () => { await database?.close(); process.exit(0); });
  server.closeAllConnections();
});
