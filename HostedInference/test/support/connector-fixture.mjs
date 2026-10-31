// Disposable SQL and synthetic Composio transport shared by gateway and actual-app acceptance tests.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createFixture, fixturePrincipal } from '../../src/fixture.mjs';
import { digest, ServiceError } from '../../src/errors.mjs';
import { createConnectorGateway } from '../../src/connectors/gateway.mjs';
import { composioClient } from '../../src/connectors/composio.mjs';
import { catalog, prepareTool, services } from '../../src/connectors/catalog.mjs';
import { reviewedVersions } from '../../src/connectors/versions.mjs';

export const other='10000000-0000-4000-8000-000000000002';
const secret='server-only-project-key-fixture';
export async function fixture({dataDir}={}) {
  const f=await createFixture({dataDir});
  if(!(await f.db.query("select to_regclass('public.hosted_connector_policy') present")).rows[0].present)
    await f.db.exec(await readFile(new URL('../../../supabase/migrations/20261030010000_hosted_connectors.sql',import.meta.url),'utf8'));
  await f.db.query('insert into auth.users(id) values($1) on conflict do nothing',[other]);
  await f.db.exec(`update public.hosted_connector_policy set enabled=true,pricing_verified=true,call_microusd=250,
    user_daily_calls=300,background_daily_calls=300,global_daily_calls=1000,global_monthly_calls=30000,
    user_daily_microusd=100000,global_monthly_microusd=10000000,requests_per_minute=300`);
  const ledger={async call(op,args){let result;try{result=await f.db.query('select public.hosted_connectors($1,$2::jsonb) r',[op,JSON.stringify(args)]);}catch(e){console.error('Fixture SQL',op,e.message);throw e;} const r=result.rows[0].r;
    if(r.error)throw new ServiceError(r.error,r.status??400);return r;}};
  const accounts=new Map(),sessions=new Map(),requests=[];let sequence=0,failMode=null,pagesPerWindow=2;
  const fetcher=async(url,options)=>{
    assert.equal(new URL(url).origin,'https://backend.composio.dev');assert.equal(options.headers['x-api-key'],secret);
    assert.equal(options.redirect,'error');const body=options.body?JSON.parse(options.body):{};requests.push({url,body});
    const path=new URL(url).pathname;
    if(path.includes('/auth_configs/'))return Response.json({id:path.split('/').at(-1)});
    if(path.endsWith('/tools')) {
      const session=sessions.get(path.split('/').at(-2));
      return Response.json({items:Object.values(session.tools).flatMap(v=>v.enable).map(slug=>({slug,version:reviewedVersions[slug]})),next_cursor:null});
    }
    if(path.endsWith('/connected_accounts/link')) {
      const id='ca_'+(++sequence);accounts.set(id,{id,user_id:body.user_id,auth_config:{id:body.auth_config_id},toolkit:{slug:body.auth_config_id.replace('ac_','')},status:'ACTIVE',experimental:{account_type:'PRIVATE'}});
      return Response.json({connected_account_id:id,redirect_url:'https://connect.composio.dev/link/'+id,expires_at:new Date(Date.now()+600000).toISOString()});
    }
    if(path.endsWith('/tool_router/session')) {
      const id='session_'+(++sequence);sessions.set(id,body);return Response.json({session_id:id,mcp:{url:'https://example.invalid',headers:{'x-api-key':secret}}});
    }
    if(path.endsWith('/execute')) {
      if(failMode==='once'){failMode=null;throw new Error('synthetic transient failure');}
      if(failMode==='timeout')throw new Error('provider secret '+secret);
      if(failMode==='oversize')return Response.json({result_type:'completed',error:null,data:{content:'x'.repeat(2_000_000)}});
      if(failMode==='wait')return await new Promise((resolve,reject)=>options.signal.addEventListener('abort',()=>reject(new Error('aborted')),{once:true}));
      if(body.tool_slug==='GMAIL_FETCH_EMAILS'){
        const page=body.arguments.page_token==='opaque-provider-token'?1:Number(body.arguments.page_token?.replace('fixture-page-','')??0);
        const next=page+1<pagesPerWindow?(page===0?'opaque-provider-token':'fixture-page-'+(page+1)):null;
        return Response.json({result_type:'completed',error:null,data:{messages:[{messageId:'abcdef0011223344',subject:'Synthetic meeting'}],...(next?{nextPageToken:next}:{})}});
      }
      if(body.tool_slug==='GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID')return Response.json({result_type:'completed',error:null,data:{messageId:'abcdef0011223344',threadId:'abcdef0011223355',subject:'Synthetic meeting',messageText:'Quartz milestone: fixture review complete.'}});
      if(body.tool_slug==='GMAIL_SEND_EMAIL')return Response.json({result_type:'completed',error:null,data:{id:'sent-fixture',threadId:'thread-fixture'}});
      if(body.tool_slug==='GOOGLECALENDAR_CREATE_EVENT')return Response.json({result_type:'completed',error:null,data:{response_data:{id:'event-fixture',summary:body.arguments.summary,
        start:{dateTime:body.arguments.start_datetime+'Z',timeZone:'UTC'},end:{dateTime:body.arguments.end_datetime+'Z',timeZone:'UTC'}}}});
      if(failMode==='failed')return Response.json({result_type:'failed',error:'private provider error',data:{}});
      return Response.json({result_type:'completed',error:null,data:{id:'object-fixture'}});
    }
    const match=path.match(/connected_accounts\/([^/]+)(\/revoke)?$/);
    if(match){
      if(match[2])return Response.json({revoked_tokens:['access_token','refresh_token'],connected_account:{id:match[1],status:'REVOKED'}});
      if(options.method==='DELETE'){accounts.delete(match[1]);return Response.json({success:true});}
      return accounts.has(match[1])?Response.json(accounts.get(match[1])):new Response(null,{status:404});
    }
    if(options.method==='DELETE'){const id=path.split('/').at(-1);sessions.delete(id);return Response.json({session_id:id,deleted:true});}
    throw new Error('unexpected fixture path '+path);
  };
  const provider=composioClient({apiKey:secret,fetcher});
  const config={authConfigs:Object.fromEntries(Object.entries(services).map(([s,t])=>[s,'ac_'+t])),callbackBaseURL:'https://sentient.fixture'};
  const gateway=createConnectorGateway({ledger,provider,config,authenticate:async token=>{
    if(token==='principal-a')return fixturePrincipal;if(token==='principal-b')return other;throw new ServiceError('authentication_required',401);
  }});
  const pending=[];
  const request=async(path,body,token='principal-a',method=body===undefined?'GET':'POST')=>{
    const response=await gateway.handle(new Request('https://sentient.fixture'+path,{method,headers:{authorization:'Bearer '+token,'content-type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})}),{waitUntil:p=>pending.push(p)});
    const raw=await response.text();assert(!raw.includes(secret));return {status:response.status,body:raw.startsWith('{')?JSON.parse(raw):raw};
  };
  async function connect(service='gmail',token='principal-a',connection_id) {
    const start=await request('/v1/connectors/connect',{service,label:'Fixture account',...(connection_id?{connection_id}:{})},token);
    assert.equal(start.status,200,JSON.stringify(start));
    const finish=await request('/v1/connectors/attempts/'+start.body.attempt_id,undefined,token);assert.equal(finish.body.status,'completed');
    return start.body;
  }
  async function run(purpose='sidekick',principal=fixturePrincipal){const token='hrt_'+'1'.repeat(63)+(principal===other?'2':'1');
    const result=await f.ledger.call('create',{principal_id:principal,purpose,model:'claude-fixture',token_hash:await digest(token)});return {...result,token,principal};}
  async function prepare(connection,run,mode='read') {return request('/v1/connectors/capabilities',{run_id:run.run_id,connection_id:connection.connection_id,generation:connection.generation,mode},run.principal===other?'principal-b':'principal-a');}
  return {...f,inferenceLedger:f.ledger,ledger,gateway,request,connect,run,prepare,requests,accounts,sessions,setFailure:v=>failMode=v,setPages:v=>pagesPerWindow=v,
    async close(){await Promise.allSettled(pending);await f.db.close();}};
}
