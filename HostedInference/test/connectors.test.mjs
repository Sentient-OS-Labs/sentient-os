import test from 'node:test';
import assert from 'node:assert/strict';
import {fixture,other} from './support/connector-fixture.mjs';
import {fixturePrincipal} from '../src/fixture.mjs';
import {digest} from '../src/errors.mjs';
import {catalog,prepareTool} from '../src/connectors/catalog.mjs';
import {composioClient} from '../src/connectors/composio.mjs';
import {supabaseServices} from '../src/supabase.mjs';

test('Supabase identity and ledger responses are bounded while streaming, including missing length headers',async()=>{
  let cancelled=0;
  const services=supabaseServices({url:'https://fixture.supabase.invalid',publishableKey:'fixture-public',serviceRoleKey:'fixture-server',
    fetcher:async()=>new Response(new ReadableStream({pull(controller){controller.enqueue(new Uint8Array(64_001));},cancel(){cancelled++;}}))});
  await assert.rejects(()=>services.authenticate('fixture-principal'),e=>e.code==='service_unavailable');
  await assert.rejects(()=>services.connectorLedger.call('list',{}),e=>e.code==='service_unavailable');
  assert.equal(cancelled,2);
});

test('disconnect removes only the intended connection; provider grant revocation is explicit',async()=>{
  for(const revoke_provider of [false,true]){
    const f=await fixture();try{
      const c=await f.connect();
      assert.equal((await f.request('/v1/connectors/'+c.connection_id+'/disconnect',{revoke_provider:'true'})).status,400);
      await f.ledger.call('disconnect',{principal_id:fixturePrincipal,connection_id:c.connection_id,revoke_provider});
      assert.equal((await f.request('/v1/connectors/connect',{service:'gmail',label:'Fixture',connection_id:c.connection_id})).status,409);
      const response=await f.request('/v1/connectors/'+c.connection_id+'/disconnect',{revoke_provider});
      assert.equal(response.body.connections[0].status,revoke_provider?'revocation_pending':'disconnect_pending');
      await f.gateway.cleanup();
      assert.equal((await f.request('/v1/connectors')).body.connections[0].status,'disconnected');
      assert.equal(f.requests.some(r=>r.url.endsWith('/revoke')),revoke_provider);
    }finally{await f.close();}
  }
});
test('cleanup requires exact project access and positive provider receipts before acknowledging removal',async()=>{
  for(const kind of ['account','connection','session']){
    const calls=[];
    const provider=composioClient({apiKey:'fixture-key',fetcher:async(url)=>{
      calls.push(url);
      if(url.includes('/auth_configs/'))return Response.json({id:'ac_fixture'});
      return Response.json({});
    }});
    await assert.rejects(()=>provider.remove(kind,'object_fixture','ac_fixture'),e=>e.code==='connector_invalid_response');
    assert.equal(calls.length,2);
  }
  let calls=0;
  const wrongProject=composioClient({apiKey:'fixture-key',fetcher:async()=>{calls++;return new Response(null,{status:404});}});
  await assert.rejects(()=>wrongProject.remove('connection','object_fixture','ac_original'),e=>e.code==='connector_upstream_not_found');
  assert.equal(calls,1);
});
test('cancelled and disconnected pending OAuth records remain pending until their upstream removal is acknowledged',async()=>{
  for(const cancel of [false,true]) {
    const f=await fixture();try{
      const started=await f.request('/v1/connectors/connect',{service:'gmail',label:'Fixture'});
      await f.ledger.call(cancel?'cancel':'disconnect',{principal_id:fixturePrincipal,
        ...(cancel?{attempt_id:started.body.attempt_id}:{connection_id:started.body.connection_id})});
      assert.equal((await f.request('/v1/connectors')).body.connections[0].status,'disconnect_pending');
      assert.equal(f.accounts.size,1);
      await f.gateway.cleanup();
      assert.equal(f.accounts.size,0);
      assert.equal((await f.request('/v1/connectors')).body.connections[0].status,'disconnected');
    }finally{await f.close();}
  }
});

test('real migration: OAuth, exact session scope, credential containment, bounded pagination and read ledger',async()=>{
  const f=await fixture();try{
    const c=await f.connect(),run=await f.run(),prepared=await f.prepare(c,run);assert.equal(prepared.status,200);
    const cap=prepared.body.capability_token;assert(cap.startsWith('hct_'));assert(!prepared.body.tools.some(t=>t.write));
    const session=[...f.sessions.values()][0];assert.deepEqual(session.connected_accounts,{gmail:['ca_1']});
    assert.equal(session.workbench.enable,false);assert.equal(session.proxy_execute.enable,false);assert.equal(session.manage_connections.enable,false);assert.equal(session.instant,false);
    const args={start:'2026-10-01T00:00:00Z',end:'2026-10-02T00:00:00Z'};
    const page1=await f.request('/v1/connectors/execute',{tool:'gmail_search',arguments:args,operation_id:crypto.randomUUID()},cap);
    assert.equal(page1.status,200,JSON.stringify(page1));assert.equal(page1.body.data.items.length,1);assert(page1.body.cursor);
    const forged=await f.request('/v1/connectors/execute',{tool:'gmail_search',arguments:{...args,cursor:crypto.randomUUID()},operation_id:crypto.randomUUID()},cap);assert.equal(forged.status,409);
    const page2=await f.request('/v1/connectors/execute',{tool:'gmail_search',arguments:{...args,cursor:page1.body.cursor},operation_id:crypto.randomUUID()},cap);
    assert.equal(page2.body.cursor,null);assert.equal(f.requests.filter(r=>r.url.endsWith('/execute')).at(-1).body.arguments.page_token,'opaque-provider-token');
    assert.equal((await f.db.query("select count(*)::int n from public.hosted_connector_operations where status='completed'")).rows[0].n,2);
  }finally{await f.close();}
});
test('two accounts for one user retain exact execution selection and independent disconnection',async()=>{
  const f=await fixture();try{
    const first=await f.connect(),second=await f.connect(),run=await f.run();
    const one=await f.prepare(first,run),two=await f.prepare(second,run);
    const read=cap=>f.request('/v1/connectors/execute',{tool:'gmail_read',arguments:{message_id:'abcdef0011223344'},operation_id:crypto.randomUUID()},cap.body.capability_token);
    assert.equal((await read(one)).status,200);assert.equal((await read(two)).status,200);
    const executions=f.requests.filter(r=>r.url.endsWith('/execute'));
    assert.equal(executions[0].body.account,'ca_1');assert.equal(executions[1].body.account,'ca_2');
    await f.request('/v1/connectors/'+first.connection_id+'/disconnect',{});
    assert.equal((await read(one)).status,409);assert.equal((await read(two)).status,200);
    assert.equal(f.requests.filter(r=>r.url.endsWith('/execute')).at(-1).body.account,'ca_2');
  }finally{await f.close();}
});
test('ownership, stale generations, background action denial and account-preserving reconnect cancellation',async()=>{
  const f=await fixture();try{
    const c=await f.connect(),r=await f.run('knowledge_update'),p=await f.prepare(c,r);
    assert.equal((await f.request('/v1/connectors/capabilities',{run_id:r.run_id,connection_id:c.connection_id,generation:c.generation,mode:'read'},r.token)).status,401);
    assert.equal((await f.prepare(c,r,'action')).status,403);
    const otherRun=await f.run('sidekick',other);assert.equal((await f.prepare(c,otherRun)).status,404);
    assert.equal((await f.request('/v1/connectors/capabilities',{run_id:otherRun.run_id,connection_id:c.connection_id,generation:c.generation,mode:'read'})).status,404);
    assert.equal((await f.request('/v1/connectors/'+c.connection_id+'/disconnect',{},'principal-b')).status,404);
    const attempt=await f.request('/v1/connectors/connect',{service:'gmail',label:'Fixture',connection_id:c.connection_id});
    assert.equal((await f.request('/v1/connectors/execute',{tool:'gmail_read',arguments:{message_id:'abcdef0011223344'},operation_id:crypto.randomUUID()},p.body.capability_token)).status,409);
    assert.equal((await f.prepare(c,r)).status,409);
    await f.request('/v1/connectors/attempts/'+attempt.body.attempt_id+'/cancel',{});
    const list=await f.request('/v1/connectors');assert.equal(list.body.connections[0].status,'active');
    assert.equal(list.body.connections[0].generation,2);
  }finally{await f.close();}
});
test('writes replay confirmed receipts and uncertain writes block future dispatch, including new capabilities',async()=>{
  const f=await fixture();try{
    const c=await f.connect(),r=await f.run(),p=await f.prepare(c,r,'action'),cap=p.body.capability_token;
    const args={to:'synthetic@example.invalid',subject:'Fixture only',body:'Fixture'},operation_id=crypto.randomUUID();
    const body={tool:'gmail_send',arguments:args,operation_id};
    assert.equal((await f.request('/v1/connectors/execute',body,cap)).body.receipt.id,'sent-fixture');
    assert.equal((await f.request('/v1/connectors/execute',body,cap)).body.replayed,true);
    assert.equal(f.requests.filter(r=>r.url.endsWith('/execute')).length,1);
    assert.equal((await f.request('/v1/connectors/execute',{...body,arguments:{...args,body:'changed'}},cap)).status,409);
    f.setFailure('timeout');
    assert.equal((await f.request('/v1/connectors/execute',{...body,arguments:{...args,body:'Second requested message'},operation_id:crypto.randomUUID()},cap)).body.error.code,'write_outcome_unknown');
    const p2=await f.prepare(c,r,'action');
    assert.equal((await f.request('/v1/connectors/execute',{...body,operation_id:crypto.randomUUID()},p2.body.capability_token)).body.error.code,'write_outcome_unknown');
    assert.equal(f.requests.filter(r=>r.url.endsWith('/execute')).length,2);
  }finally{await f.close();}
});
test('read-only wall rejects broad tools, owner selectors, pagination URLs and extra write arguments',async()=>{
  for(const tool of Object.values(catalog)) {
    assert.throws(()=>prepareTool(tool.service,'read','COMPOSIO_MULTI_EXECUTE_TOOL',{}));
    assert.throws(()=>prepareTool(tool.service,'action',tool.name,{user_id:'another-user'}));
    if(tool.write)assert.throws(()=>prepareTool(tool.service,'read',tool.name,{}));
  }
  assert.throws(()=>prepareTool('gmail','read','gmail_search',{start:'2026-10-01T00:00:00Z',end:'2026-10-02T00:00:00Z',cursor:'https://evil.invalid'}));
  assert.throws(()=>prepareTool('google-calendar','action','google_calendar_create',{title:'Fixture',start:'2026-01-01T00:00:00Z',end:'2028-12-31T00:00:00Z'}));
  assert.throws(()=>prepareTool('slack','action','slack_send',{channel:'C123ABC',text:'<!channel> Broadcast'}));
});
test('disabled funding, per-user quotas, pause and finish forbid connector work without removing accounts',async()=>{
  const f=await fixture();try{
    const c=await f.connect(),r=await f.run(),p=await f.prepare(c,r),cap=p.body.capability_token;
    const body={tool:'gmail_read',arguments:{message_id:'abcdef0011223344'},operation_id:crypto.randomUUID()};
    await f.db.exec('update public.hosted_connector_policy set user_daily_calls=0');
    assert.equal((await f.request('/v1/connectors/execute',body,cap)).body.error.code,'connector_usage_limit');
    await f.ledger.call('close',{token_hash:await digest(cap)});
    const p2=await f.prepare(c,r);
    await f.ledger.call('inspect',{token_hash:await digest(p2.body.capability_token)});
    await f.ledger.call('close',{token_hash:await digest(p2.body.capability_token)});
    await f.ledger.call('list',{principal_id:fixturePrincipal});
    await f.ledger.call('disconnect',{principal_id:fixturePrincipal,connection_id:c.connection_id});
    await f.gateway.cleanup();assert.equal(f.accounts.size,0);assert.equal(f.sessions.size,0);
    const list=await f.request('/v1/connectors');assert.equal(list.body.connections[0].status,'disconnected');
  }finally{await f.close();}
});

test('OAuth denial, expiry, wrong principal and forged callback cannot activate accounts',async()=>{
  const f=await fixture();try{
    const started=await f.request('/v1/connectors/connect',{service:'gmail',label:'Fixture'});
    assert.equal((await f.request('/v1/connectors/attempts/'+started.body.attempt_id,undefined,'principal-b')).status,404);
    assert.equal((await f.request('/v1/connectors/callback?state='+'f'.repeat(64))).status,404);
    const link=f.requests.find(r=>r.url.endsWith('/connected_accounts/link'));
    assert(!link.body.callback_url.includes('principal-a'));
    const account=[...f.accounts.values()][0];account.status='FAILED';
    assert.equal((await f.request('/v1/connectors/attempts/'+started.body.attempt_id)).body.error.code,'connection_required');
    account.status='ACTIVE';
    await f.db.query("update public.hosted_connector_attempts set expires_at=now()-interval '1 second' where id=$1",[started.body.attempt_id]);
    assert.equal((await f.request('/v1/connectors/attempts/'+started.body.attempt_id)).body.status,'expired');
    assert.equal((await f.request('/v1/connectors')).body.connections[0].status,'connecting');
    await f.gateway.cleanup();assert.equal(f.accounts.size,0);
    assert(!f.requests.some(r=>r.url.endsWith('/revoke')));
  }finally{await f.close();}
});
test('replacement attempt generations, cancellation races and retirement preserve the intended grant',async()=>{
  const f=await fixture();try{
    const c=await f.connect(),r=await f.run();
    const old=await f.request('/v1/connectors/connect',{service:'gmail',label:'Fixture',connection_id:c.connection_id});
    const current=await f.request('/v1/connectors/connect',{service:'gmail',label:'Fixture',connection_id:c.connection_id});
    assert.equal((await f.prepare({...c,generation:current.body.generation},r)).body.error.code,'connection_required');
    await f.request('/v1/connectors/attempts/'+old.body.attempt_id+'/cancel',{});
    assert.equal((await f.request('/v1/connectors')).body.connections[0].status,'connecting');
    assert.equal((await f.request('/v1/connectors/attempts/'+current.body.attempt_id)).body.status,'completed');
    await f.gateway.cleanup();assert.equal(f.accounts.size,1);
    assert(!f.requests.some(r=>r.url.endsWith('/revoke')));
    const p=await f.prepare({...c,generation:current.body.generation},r);assert.equal(p.status,200);
  }finally{await f.close();}
});
test('run waits, expiry and disconnect cancel execution capabilities without new allowances',async()=>{
  const f=await fixture();try{
    const c=await f.connect(),r=await f.run(),p=await f.prepare(c,r),token_hash=await digest(p.body.capability_token);
    const auth={token_hash:await digest(r.token)};
    await f.inferenceLedger.call('pause',auth);
    assert.equal((await f.request('/v1/connectors/check',{connections:[c.connection_id]},r.token)).status,200);
    assert.equal((await f.request('/v1/connectors/execute',{tool:'gmail_read',arguments:{message_id:'abcdef0011223344'},operation_id:crypto.randomUUID()},p.body.capability_token)).body.error.code,'run_paused');
    await f.inferenceLedger.call('resume',auth);
    const reserved=await f.ledger.call('reserve',{token_hash,operation_key:crypto.randomUUID(),request_hash:'a'.repeat(64),tool:'gmail_read',is_write:false});
    await assert.rejects(()=>f.inferenceLedger.call('pause',auth),e=>e.code==='run_busy');
    await f.ledger.call('settle',{token_hash,operation_id:reserved.operation_id,status:'completed',receipt:{}});
    await f.inferenceLedger.call('finish',auth);
    assert.equal((await f.request('/v1/connectors/check',{connections:[c.connection_id]},r.token)).status,409);
    await f.gateway.cleanup();assert.equal(f.sessions.size,0);
  }finally{await f.close();}
});
test('active long tool calls abort on disconnect and keep uncertain writes charged',async()=>{
  const f=await fixture();try{
    const c=await f.connect(),r=await f.run(),p=await f.prepare(c,r,'action');f.setFailure('wait');
    const pending=f.request('/v1/connectors/execute',{tool:'gmail_send',arguments:{to:'fixture@example.invalid',subject:'Fixture',body:'Fixture'},operation_id:crypto.randomUUID()},p.body.capability_token);
    while(!f.requests.some(r=>r.url.endsWith('/execute')))await new Promise(resolve=>setTimeout(resolve,10));
    await f.ledger.call('disconnect',{principal_id:fixturePrincipal,connection_id:c.connection_id});
    assert.equal((await pending).body.error.code,'write_outcome_unknown');
    const row=(await f.db.query("select status,charged_microusd::int cost from public.hosted_connector_operations")).rows[0];
    assert.equal(row.status,'unknown');assert(row.cost>0);
  }finally{await f.close();}
});
test('new connector tables and RPC are inaccessible to ordinary app roles',async()=>{
  const f=await fixture();try{
    const rows=(await f.db.query("select has_function_privilege('anon','public.hosted_connectors(text,jsonb)','execute') anon, has_function_privilege('authenticated','public.hosted_connectors(text,jsonb)','execute') authed, has_table_privilege('authenticated','public.hosted_connector_accounts','select') tables")).rows[0];
    assert.deepEqual(rows,{anon:false,authed:false,tables:false});
    const c=await f.connect();f.accounts.get('ca_1').user_id='different-owner';const r=await f.run();
    assert.equal((await f.prepare(c,r)).status,403);
    assert.equal(f.sessions.size,0);
  }finally{await f.close();}
});

test('uncertain-write review belongs to the principal, waits for settlement and never replays or refunds',async()=>{
  const f=await fixture();try{
    const c=await f.connect(),r=await f.run(),p=await f.prepare(c,r,'action');f.setFailure('timeout');
    await f.request('/v1/connectors/execute',{tool:'gmail_send',arguments:{to:'fixture@example.invalid',subject:'Fixture',body:'Fixture'},operation_id:crypto.randomUUID()},p.body.capability_token);
    const list=await f.request('/v1/connectors/'+c.connection_id+'/uncertain-actions');assert.equal(list.body.actions.length,1);
    const review={operation_id:list.body.actions[0].id,outcome:'allow_retry'},path='/v1/connectors/'+c.connection_id+'/resolve-action';
    assert.equal((await f.request(path,review,p.body.capability_token)).status,401);
    assert.equal((await f.request(path,review,'principal-b')).status,404);
    assert.equal((await f.request(path,review)).body.error.code,'resolution_not_ready');
    await f.inferenceLedger.call('finish',{token_hash:await digest(r.token)});
    await f.db.exec("update public.hosted_connector_operations set created_at=now()-interval '3 minutes'");
    const before=f.requests.filter(r=>r.url.endsWith('/execute')).length;
    assert.equal((await f.request(path,review)).status,200);
    assert.equal(f.requests.filter(r=>r.url.endsWith('/execute')).length,before);
    const row=(await f.db.query('select status,receipt,charged_microusd::int cost from public.hosted_connector_operations')).rows[0];
    assert.equal(row.status,'resolved');assert.equal(row.receipt.outcome,'user_allow_retry');assert(row.cost>0);
  }finally{await f.close();}
});

test('cleanup claims serialize retries and remain bounded while admissions are disabled',async()=>{
  const f=await fixture();try{
    await f.ledger.call('cleanup_enqueue',{kind:'session',upstream_id:'session_cleanup_fixture',auth_config:'ac_gmail'});
    await f.db.exec('update public.hosted_connector_policy set enabled=false');
    const results=await Promise.all([f.ledger.call('cleanup_claim',{kind:'session',upstream_id:'session_cleanup_fixture'}),
      f.ledger.call('cleanup_claim',{kind:'session',upstream_id:'session_cleanup_fixture'})]);
    assert.equal(results.filter(r=>r.claimed).length,1);
    await f.ledger.call('cleanup_delay',{kind:'session',upstream_id:'session_cleanup_fixture',seconds:300});
    assert.equal((await f.ledger.call('cleanup_list',{})).items.length,0);
  }finally{await f.close();}
});

test('equivalent event offsets share a mutation identity and verified instants',async()=>{
  const f=await fixture();try{
    const c=await f.connect('google-calendar'),r=await f.run(),p=await f.prepare(c,r,'action');
    const first={title:'Fixture event',start:'2026-10-01T12:00:00Z',end:'2026-10-01T13:00:00Z'};
    const execute=arguments_=>f.request('/v1/connectors/execute',{tool:'google_calendar_create',arguments:arguments_,operation_id:crypto.randomUUID()},p.body.capability_token);
    assert.equal((await execute(first)).body.receipt.id,'event-fixture');
    const repeat=await execute({...first,start:'2026-10-01T05:00:00-07:00',end:'2026-10-01T06:00:00-07:00'});
    assert.equal(repeat.body.replayed,true);assert.equal(f.requests.filter(r=>r.url.endsWith('/execute')).length,1);
  }finally{await f.close();}
});

test('invalid argument traffic is throttled before provider dispatch',async()=>{
  const f=await fixture();try{
    const c=await f.connect(),r=await f.run(),p=await f.prepare(c,r);
    await f.db.exec('update public.hosted_connector_policy set requests_per_minute=1');
    const result=await f.request('/v1/connectors/execute',{tool:'COMPOSIO_PROXY_EXECUTE',arguments:{url:'https://example.invalid'},operation_id:crypto.randomUUID()},p.body.capability_token);
    assert.equal(result.status,429);assert.equal(f.requests.filter(r=>r.url.endsWith('/execute')).length,0);
  }finally{await f.close();}
});
