// These fixtures are reduced JSON Schemas retrieved from Composio's authenticated v3.1 API.
// They verify our mapping against the provider contract rather than restating our own schemas.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {catalog,prepareTool} from '../src/connectors/catalog.mjs';
import {reviewedVersions} from '../src/connectors/versions.mjs';
import {normalizeResult,mutationReceipt} from '../src/connectors/results.mjs';
const contracts=JSON.parse(await readFile(new URL('./fixtures/composio-contracts.json',import.meta.url)));
function sample(schema,key='') {
  if(schema.type==='array')return [];
  if(key==='start')return '2026-10-01T12:00:00Z';if(key==='end')return '2026-10-01T13:00:00Z';
  if(key==='timezone')return 'UTC';if(['to'].includes(key))return 'fixture@example.invalid';
  if(key==='channel')return 'C123ABC';if(key==='timestamp'||key==='thread_ts')return '1234567.123456';
  if(key.endsWith('_id'))return 'abcdef0011223344';return 'Synthetic fixture';
}
function check(schema,value,root=schema) {
  if(schema.$ref)return check(root.$defs[schema.$ref.split('/').at(-1)],value,root);
  if(schema.anyOf){assert(schema.anyOf.some(s=>{try{check(s,value,root);return true;}catch{return false;}}));return;}
  if(schema.enum)assert(schema.enum.includes(value));
  if(schema.type==='object'){
    assert(value&&typeof value==='object'&&!Array.isArray(value));
    for(const key of schema.required??[])assert(Object.hasOwn(value,key),'missing '+key);
    for(const [key,child]of Object.entries(value)){
      const rule=schema.properties?.[key]??(typeof schema.additionalProperties==='object'?schema.additionalProperties:null);
      assert(rule,'unknown upstream field '+key);check(rule,child,root);
    }
  }else if(schema.type==='array'){assert(Array.isArray(value));for(const child of value)check(schema.items,child,root);}
  else if(schema.type==='integer'){assert(Number.isInteger(value));if(schema.minimum!==undefined)assert(value>=schema.minimum);if(schema.maximum!==undefined)assert(value<=schema.maximum);}
  else if(schema.type==='string'){assert.equal(typeof value,'string');}
  else if(schema.type==='boolean')assert.equal(typeof value,'boolean');
}
for(const [name,tool]of Object.entries(catalog))test('reviewed live schema: '+name,()=>{
  const c=contracts[name];assert(c);assert.equal(c.slug,tool.upstream);assert.equal(reviewedVersions[c.slug],c.version);
  const args=Object.fromEntries(tool.inputSchema.required.map(key=>[key,sample(tool.inputSchema.properties[key],key)]));
  check(c.input,prepareTool(tool.service,tool.write?'action':'read',name,args).arguments);
});
test('current result envelopes preserve pagination, empty Gmail, event IDs and Outlook acceptance',()=>{
  assert.deepEqual(normalizeResult(catalog.gmail_search,{data:{resultSizeEstimate:0},successful:true}),{data:{items:[]},next:null});
  assert.equal(normalizeResult(catalog.outlook_mail_list,{data:{value:[],next_page_token:'opaque','@odata.nextLink':'https://graph.microsoft.com/path'}}).next,'opaque');
  assert.throws(()=>normalizeResult(catalog.outlook_mail_list,{data:{value:[],'@odata.nextLink':'https://graph.microsoft.com/path'}}));
  assert.equal(mutationReceipt(catalog.google_calendar_create,{data:{response_data:{id:'event-fixture'}}}).id,'event-fixture');
  assert.equal(mutationReceipt(catalog.outlook_mail_send,{data:{status_code:202,body:null}}).outcome,'accepted');
  assert.throws(()=>mutationReceipt(catalog.outlook_mail_send,{data:{status_code:200}}));
});
