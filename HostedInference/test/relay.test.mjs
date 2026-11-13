import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {composeRelay} from '../src/relay.mjs';
const source=await readFile(new URL('../relay/legacy-doubletap.mjs',import.meta.url),'utf8');
const provenance=JSON.parse(await readFile(new URL('../relay/provenance.json',import.meta.url)));
assert.equal(createHash('sha256').update(source).digest('hex'),provenance.legacy_sha256);
// Substitute only the Workers built-in base class, preserving every deployed route/counter line.
const legacyModule=await import('data:text/javascript;base64,'+Buffer.from(source.replace('import { DurableObject } from "cloudflare:workers";',
  'class DurableObject { constructor(ctx,env){this.ctx=ctx;this.env=env;} }')).toString('base64'));
test('composed relay preserves real legacy health, auth, drafting stream and counter namespace',async()=>{
  const values=new Map(),objects=new Map();let upstreamCalls=0,hostedCalls=0;
  const env={OPENAI_API_KEY:'fixture-openai',MODEL:'fixture-model',HOURLY_CAP:'10',DAILY_CAP:'20',GLOBAL_MONTHLY_CAP:'100',
    COUNTERS:{idFromName:name=>name,get:id=>{if(!objects.has(id))objects.set(id,new legacyModule.Counter({storage:{
      get:async key=>values.get(id+key),put:async(key,value)=>values.set(id+key,value)}},{}));return objects.get(id);}}};
  const gateway=composeRelay(legacyModule.default,{fetch:async()=>{hostedCalls++;return new Response('hosted');}});
  assert.equal(await(await gateway.fetch(new Request('https://fixture/health'),env,{})).text(),'ok');
  assert.equal((await gateway.fetch(new Request('https://fixture/v1/draft',{method:'POST',body:'{}'}),env,{})).status,401);
  const original=globalThis.fetch;
  try{
    globalThis.fetch=async(url,options)=>{upstreamCalls++;assert.equal(url,'https://api.openai.com/v1/responses');assert.equal(options.headers.authorization,'Bearer fixture-openai');const body=JSON.parse(options.body);assert.equal(body.model,env.MODEL);assert.equal(body.reasoning.effort,'low');return new Response('data: fixture\n\n');};
    const result=await gateway.fetch(new Request('https://fixture/v1/draft',{method:'POST',headers:{authorization:'Bearer '+'a'.repeat(64)},body:JSON.stringify({image:'AAAA',knowledgeBase:'Synthetic fixture'})}),env,{});
    assert.equal(result.status,200);assert.equal(await result.text(),'data: fixture\n\n');assert.equal(result.headers.get('x-relay-model'),'fixture-model');
    assert.equal(upstreamCalls,1);assert.equal(objects.size,2);assert.equal(hostedCalls,0);
  }finally{globalThis.fetch=original;}
});
test('new routes require activation and preserve SDK queries and authenticated request bodies',async()=>{
  let seen;
  const gateway=composeRelay({fetch:async()=>new Response('legacy')},{fetch:async request=>{seen={path:new URL(request.url).pathname,query:new URL(request.url).search,header:request.headers.get('authorization'),body:await request.text()};return new Response('hosted');}});
  const make=()=>new Request('https://fixture/hosted/v1/messages?beta=true',{method:'POST',headers:{authorization:'Bearer fixture-run'},body:'{"fixture":true}'});
  assert.equal((await gateway.fetch(make(),{},{})).status,503);assert.equal(seen,undefined);
  assert.equal(await(await gateway.fetch(make(),{SENTIENT_HOSTED_ROUTES_ENABLED:'true'},{})).text(),'hosted');
  assert.deepEqual(seen,{path:'/v1/messages',query:'?beta=true',header:'Bearer fixture-run',body:'{"fixture":true}'});
  assert.equal(await(await gateway.fetch(new Request('https://fixture/v1/messages'),{},{})).text(),'legacy');
});
