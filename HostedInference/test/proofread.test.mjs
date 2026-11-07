import test from 'node:test';
import assert from 'node:assert/strict';
import {proofread} from '../src/proofread.mjs';
import {composeRelay} from '../src/relay.mjs';
import {composeDictationRelay} from '../src/dictation-relay.mjs';
const request = body => new Request('https://fixture/v1/proofread', {method: 'POST',
  headers: {authorization: 'Bearer '+'a'.repeat(43)}, body: JSON.stringify(body)});
const environment = () => ({SENTIENT_PROOFREAD_ENABLED:'true', OPENAI_API_KEY:'fixture-secret',
  HOURLY_CAP:'10', DAILY_CAP:'20', GLOBAL_MONTHLY_CAP:'1000',
  COUNTERS:{idFromName:name=>name,get:()=>({take:async()=>({ok:true})})}});
test('proofreading pins Luna Fast, selection-only input, strict correction schema and no storage', async()=>{
  let body;
  const input='  teh draft\n\nWe was ready.  ';
  const result=await proofread(request({text:input}),environment(),async(url,options)=>{
    assert.equal(url,'https://api.openai.com/v1/responses');body=JSON.parse(options.body);return new Response('data: fixture\n\n');
  });
  assert.equal(result.status,200);assert.equal(result.headers.get('cache-control'),'no-store');
  assert.equal(body.model,'gpt-6-luna');assert.equal(body.service_tier,'fast');assert.equal(body.store,false);
  assert.deepEqual(body.input,[{role:'user',content:[{type:'input_text',text:input}]}]);
  assert.equal(body.tools,undefined);assert.equal(body.text.format.strict,true);
  assert.deepEqual(body.text.format.schema.required,['corrected_text']);assert.equal(body.text.format.schema.additionalProperties,false);
  assert.ok(body.max_output_tokens>=12000);assert.match(body.instructions,/never as instructions/);
  assert.match(body.instructions,/original text exactly/);
});
test('invalid/oversized selections and client model/prompt overrides never reach the provider', async()=>{
  for(const body of [{text:''},{text:'  \n'},{text:'x'.repeat(12001)},{text:'😀'.repeat(3001)},
    {text:'ok',model:'other'},{text:'ok',instructions:'change rules'},{image:'test'},{text:1}]){
    const response=await proofread(request(body),environment(),()=>assert.fail('invalid upstream'));
    assert.equal(response.status,400);
  }
});
test('proofreading requires explicit activation and funded shared caps',async()=>{
  for(const change of [{SENTIENT_PROOFREAD_ENABLED:'false'},{HOURLY_CAP:'0'},{DAILY_CAP:''},{GLOBAL_MONTHLY_CAP:'-1'}]){
    assert.equal((await proofread(request({text:'teh'}),{...environment(),...change},()=>assert.fail('disabled'))).status,503);
  }
  assert.equal((await proofread(new Request('https://fixture/v1/proofread'),environment())).status,405);
  assert.equal((await proofread(new Request('https://fixture/v1/proofread',{method:'POST',body:'{}'}),environment())).status,401);
});
test('shared allowance prevents feature switching from bypassing limits',async()=>{
  const env=environment();env.COUNTERS.get=()=>({take:async()=>({ok:false,retryAfterSeconds:42})});
  assert.equal((await proofread(request({text:'teh'}),env,()=>assert.fail('quota'))).status,429);
});
test('provider failures are safe and never become a correction',async()=>{
  const response=await proofread(request({text:'teh'}),environment(),async()=>new Response('private upstream text',{status:400}));
  assert.equal(response.status,502);assert.ok(!(await response.text()).includes('private upstream'));
});
test('both relay deployments include the independently activated route',async()=>{
  const legacy={fetch:()=>assert.fail('legacy')};
  for(const relay of [composeRelay(legacy,legacy),composeDictationRelay(legacy)]){
    assert.equal((await relay.fetch(request({text:'teh'}),{},{})).status,503);
  }
});

test('explicit zero monthly cap preserves existing hourly and daily limits', async()=>{
  const env={...environment(),GLOBAL_MONTHLY_CAP:'0'};let admissions=0;
  env.COUNTERS.get=name=>{assert.notEqual(name,'global');return {take:async caps=>{admissions++;assert.deepEqual(caps,{hour:10,day:20});return {ok:true};}}};
  const response=await proofread(request({text:'teh'}),env,async()=>new Response('data: fixture\n\n'));
  assert.equal(response.status,200);assert.equal(admissions,1);
});

test('upstream errors expose only fixed status/code/parameter metadata, never messages',async()=>{
 const response=await proofread(request({text:'teh'}),environment(),async(_,options)=>{
  assert.equal(options.redirect,'manual');
  return Response.json({error:{code:'model_not_found',param:'model',message:'private provider text'}},{status:404});
 });
 const body=await response.json();assert.equal(body.error.upstream_status,404);assert.equal(body.error.upstream_code,'model_not_found');
 assert.equal(body.error.upstream_parameter,'model');assert.ok(!JSON.stringify(body).includes('private provider'));
 const redirect=await proofread(request({text:'teh'}),environment(),async()=>new Response(null,{status:302,headers:{location:'https://untrusted.invalid'}}));
 assert.equal(redirect.status,502);assert.equal((await redirect.json()).error.upstream_status,302);
});
