import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { byteRange, release } from '../src/index.mjs';

const artifact = release.cli;
const url = `https://downloads.example/releases/${artifact.filename}`;
function bucket(options = {}) {
  const calls = [];
  const metadata = { size: artifact.bytes, etag: 'object-version', uploaded: new Date('2026-10-02T00:00:00Z') };
  return { calls, RELEASES: {
    async head(key) { calls.push(['head', key]); return options.missing ? null : { ...metadata, ...options.metadata }; },
    async get(key, options) {
      calls.push(['get', key, options]);
      const body = options.range
        ? Uint8Array.from({ length: options.range.length }, (_, i) => (i + options.range.offset) % 256)
        : new TextEncoder().encode('streamed body');
      return { ...metadata, body };
    },
  } };
}

test('only approved GET/HEAD paths can touch storage', async () => {
  const env = bucket();
  for (const method of ['PUT', 'POST', 'DELETE', 'PATCH']) {
    assert.equal((await worker.fetch(new Request(url, { method }), env)).status, 405);
  }
  for (const path of ['/auth.json', '/releases/', '/releases/unknown.zip', '/.codex/plugins/cache/']) {
    assert.equal((await worker.fetch(new Request(`https://downloads.example${path}`), env)).status, 404);
  }
  assert.equal(env.calls.length, 0);
});

test('HEAD describes the full archive without reading its body', async () => {
  const env = bucket();
  const response = await worker.fetch(new Request(url, { method: 'HEAD', headers: { Range: 'bytes=0-9' } }), env);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Content-Length'), String(artifact.bytes));
  assert.equal(await response.text(), '');
  assert.equal(env.calls.length, 1);
});

test('range and resumed range return matching bytes and lengths', async () => {
  const env = bucket();
  const first = await worker.fetch(new Request(url, { headers: { Range: 'bytes=0-9' } }), env);
  const next = await worker.fetch(new Request(url, { headers: { Range: 'bytes=10-19', 'If-Range': first.headers.get('ETag') } }), env);
  for (const response of [first, next]) {
    assert.equal(response.status, 206);
    assert.equal(response.headers.get('Content-Length'), '10');
  }
  assert.equal(next.headers.get('Content-Range'), `bytes 10-19/${artifact.bytes}`);
  const data = [...new Uint8Array(await first.arrayBuffer()), ...new Uint8Array(await next.arrayBuffer())];
  assert.deepEqual(data, Array.from({ length: 20 }, (_, i) => i));
  assert.equal(env.calls[1][2].onlyIf.etagMatches, 'object-version');
});

test('stale If-Range restarts the full download', async () => {
  const response = await worker.fetch(new Request(url, { headers: { Range: 'bytes=10-19', 'If-Range': '"old"' } }), bucket());
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Content-Range'), null);
});

test('invalid or multiple ranges fail without fetching a body', async () => {
  for (const range of [`bytes=${artifact.bytes}-`, 'bytes=9-1', 'bytes=-0', 'bytes=0-2,5-8', 'bytes=999999999999999999999-', 'garbage']) {
    const env = bucket();
    const response = await worker.fetch(new Request(url, { headers: { Range: range } }), env);
    assert.equal(response.status, 416);
    assert.equal(response.headers.get('Content-Range'), `bytes */${artifact.bytes}`);
    assert.equal(env.calls.length, 1);
  }
});

test('range parsing clamps ends and supports suffixes', () => {
  assert.deepEqual(byteRange('bytes=-4', 10), { offset: 6, length: 4 });
  assert.deepEqual(byteRange('bytes=-20', 10), { offset: 0, length: 10 });
  assert.deepEqual(byteRange('bytes=8-99', 10), { offset: 8, length: 2 });
  assert.deepEqual(byteRange('bytes=8-', 10), { offset: 8, length: 2 });
});

test('conditional GET returns 304 without downloading a body', async () => {
  const env = bucket();
  const response = await worker.fetch(new Request(url, { headers: { 'If-None-Match': `W/"sha256-${artifact.sha256}"` } }), env);
  assert.equal(response.status, 304);
  assert.equal(env.calls.length, 1);
});

test('missing, wrong-sized, or inaccessible releases return uncached failures', async () => {
  for (const env of [bucket({ missing: true }), bucket({ metadata: { size: 1 } }), { RELEASES: { async head() { throw new Error('down'); } } }]) {
    const response = await worker.fetch(new Request(url), env);
    assert.equal(response.status, 503);
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
  }
});

test('object replacement between HEAD and GET fails closed', async () => {
  const env = bucket();
  env.RELEASES.get = async () => ({ size: artifact.bytes });
  assert.equal((await worker.fetch(new Request(url), env)).status, 503);
});

test('public release information contains only distribution metadata', async () => {
  const response = await worker.fetch(new Request('https://downloads.example/releases/manifest.json'), bucket());
  const value = await response.json();
  assert.deepEqual(Object.keys(value.cli).sort(), ['bytes', 'path', 'sha256', 'version']);
  assert.equal(value.cli.sha256, release.cli.sha256);
  assert.equal(value.helper.sha256, release.helper.sha256);
});
