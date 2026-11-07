import test from 'node:test';
import assert from 'node:assert/strict';
import {composeDictationRelay} from '../src/dictation-relay.mjs';

test('dictation wrapper preserves existing routes and uses only the caller JWT for admission', async () => {
  const calls = [];
  const legacy = {fetch: async request => new Response('legacy:' + new URL(request.url).pathname)};
  const handler = composeDictationRelay(legacy, async (url, init) => {
    const u = new URL(url); calls.push(u.pathname);
    if (u.hostname === 'api.elevenlabs.io') {
      assert.equal(init.headers['xi-api-key'], 'synthetic-elevenlabs-key');
      return Response.json({token: 'sutkn_abcdefghijklmnopqrstuv'});
    }
    assert.equal(u.hostname, 'project.supabase.co');
    assert.equal(init.headers.authorization, 'Bearer caller-jwt');
    assert.equal(init.headers.apikey, 'public-key');
    assert.equal(init.redirect, 'manual');
    if (u.pathname === '/auth/v1/user') return Response.json({id: '10000000-0000-4000-8000-000000000001'});
    assert.equal(u.pathname, '/rest/v1/rpc/reserve_dictation_token');
    assert.equal(init.body, '{}');
    return Response.json({accepted: true});
  });
  const env = {SUPABASE_URL:'https://project.supabase.co',SUPABASE_PUBLISHABLE_KEY:'public-key',
    ELEVENLABS_API_KEY:'synthetic-elevenlabs-key',SCRIBE_ENABLED:'true'};
  for (const path of ['/health','/v1/draft','/hosted/v1/messages']) {
    assert.equal(await (await handler.fetch(new Request('https://relay.test'+path),env)).text(), 'legacy:'+path);
  }
  assert.equal(calls.length,0);
  const result = await handler.fetch(new Request('https://relay.test/hosted/v1/dictation/token',{
    method:'POST',headers:{authorization:'Bearer caller-jwt','content-type':'application/json'},body:'{}'}),env);
  assert.equal(result.status,200);
  assert.equal((await result.json()).token,'sutkn_abcdefghijklmnopqrstuv');
  assert.deepEqual(calls,['/auth/v1/user','/rest/v1/rpc/reserve_dictation_token','/v1/single-use-token/realtime_scribe']);
});
