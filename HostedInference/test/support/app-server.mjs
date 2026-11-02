// Loopback-only production gateway + real SQL + synthetic Composio/Anthropic endpoints.
// Used by Scripts/test_hosted_connectors.py. Never imported by a deployed Worker.
import http from 'node:http';
import {Readable} from 'node:stream';
import {fixture} from './connector-fixture.mjs';
import {fixturePrincipal,fixtureConfig} from '../../src/fixture.mjs';
import {createGateway} from '../../src/gateway.mjs';
import {createConnectorGateway} from '../../src/connectors/gateway.mjs';
import {composioClient} from '../../src/connectors/composio.mjs';
import {ServiceError} from '../../src/errors.mjs';
import {readFile} from 'node:fs/promises';
const live=process.argv.includes('--live-composio');
if(live&&(!process.env.COMPOSIO_ACCEPTANCE_ROOT||!process.env.COMPOSIO_DEV_KEY_FILE||!process.env.COMPOSIO_DEV_CONFIG_FILE))throw new Error('Explicit private acceptance configuration required');
const f=await fixture({dataDir:live?process.env.COMPOSIO_ACCEPTANCE_ROOT+'/database':undefined});let modelCalls=0,failReads=false,toolResults=0,selectionCalls=0,summaryCalls=0;
const trace=[];
const principalToken=live?'acceptance_'+crypto.randomUUID()+crypto.randomUUID():'principal-a';
const authenticate=async token=>{if(token!==principalToken)throw new ServiceError('authentication_required',401);return fixturePrincipal;};
let connectorGateway=f.gateway;
if(live)await f.db.exec('update public.hosted_connector_policy set user_daily_calls=20,background_daily_calls=20,global_daily_calls=20,global_monthly_calls=20,call_microusd=0,pricing_verified=true');
function events(content,reason='end_turn') {
  const frames=[{type:'message_start',message:{id:'msg_'+crypto.randomUUID(),type:'message',role:'assistant',model:fixtureConfig.model,
    content:[],stop_reason:null,stop_sequence:null,usage:{input_tokens:100,output_tokens:1}}}];
  for(const [index,block]of content.entries()){
    frames.push({type:'content_block_start',index,content_block:block.type==='tool_use'?{...block,input:{}}:{type:'text',text:''}});
    frames.push({type:'content_block_delta',index,delta:block.type==='tool_use'?{type:'input_json_delta',partial_json:JSON.stringify(block.input)}:{type:'text_delta',text:block.text}});
    frames.push({type:'content_block_stop',index});
  }
  frames.push({type:'message_delta',delta:{stop_reason:reason,stop_sequence:null},usage:{output_tokens:40}},{type:'message_stop'});
  return new Response(frames.map(x=>`event: ${x.type}\ndata: ${JSON.stringify(x)}\n\n`).join(''),{headers:{'content-type':'text/event-stream'}});
}
const inference=createGateway({ledger:f.inferenceLedger,authenticate,config:fixtureConfig,upstream:async(url,options)=>{
  if(url.endsWith('/count_tokens'))return Response.json({input_tokens:100});
  const body=JSON.parse(options.body);modelCalls++;
  const blocks=body.messages.flatMap(x=>Array.isArray(x.content)?x.content:[]);
  const requested=blocks.find(x=>x.type==='tool_use'&&x.input?.message_id==='abcdef0011223344');
  const received=blocks.filter(x=>x.type==='tool_result'&&x.tool_use_id===requested?.id);
  trace.push({tools:body.tools?.map(x=>x.name),blockTypes:blocks.map(x=>x.type),requested:Boolean(requested),received:received.length,verified:JSON.stringify(received).includes('Quartz milestone')});
  if(trace.length>16)trace.shift();
  const prompt=JSON.stringify(body.messages);
  const selecting=prompt.includes('Choose at most three gmail items');
  const summarizing=prompt.includes('Summarize this bounded page of gmail');
  if(selecting||summarizing){
    if(body.tools?.some(x=>x.name!=='StructuredOutput'))throw new Error('Knowledge summary exposed an external tool');
    if(selecting)selectionCalls++;else summaryCalls++;
    const result=selecting?{selected_ids:['abcdef0011223344']}:{item_count:1,notable:true,has_action_items:false,
      summary:'The user is preparing the synthetic Quartz milestone review.',tool_failure:''};
    const outputTool=body.tools?.find(x=>x.name==='StructuredOutput');
    if(outputTool&&!blocks.some(x=>x.type==='tool_use'&&x.name==='StructuredOutput'))
      return events([{type:'tool_use',id:'toolu_schema_'+crypto.randomUUID(),name:outputTool.name,input:result}],'tool_use');
    return events([{type:'text',text:JSON.stringify(result)}]);
  }
  if(received.length){
    if(!JSON.stringify(received).includes('Quartz milestone'))return events([{type:'text',text:'STATUS: COULD_NOT The fixture result was not returned.'}]);
    toolResults+=received.length;return events([{type:'text',text:'Synthetic connector read verified.\nSTATUS: DONE'}]);
  }
  const tool=body.tools?.find(x=>x.name.includes('gmail_read')||x.description?.includes('from one message in this Gmail account'));
  if(tool)return events([{type:'tool_use',id:'toolu_fixture_'+crypto.randomUUID(),name:tool.name,input:{message_id:'abcdef0011223344'}}],'tool_use');
  const wait=body.tools?.find(x=>x.name==='WaitForMcpServers');
  if(wait)return events([{type:'tool_use',id:'toolu_wait_'+crypto.randomUUID(),name:wait.name,input:{}}],'tool_use');
  return events([{type:'text',text:'STATUS: COULD_NOT Required fixture tool was not exposed.'}]);
}});
const server=http.createServer(async(req,res)=>{
  try {
    const path=new URL(req.url,'http://127.0.0.1').pathname;
    if(path==='/__fixture/status'){
      const operations=(await f.db.query('select tool,status,count(*)::int count from public.hosted_connector_operations group by tool,status')).rows;
      const runs=(await f.db.query('select purpose,phase,count(*)::int count from public.hosted_inference_runs group by purpose,phase')).rows;
      res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({modelCalls,toolResults,selectionCalls,summaryCalls,operations,runs,trace}));return;
    }
    if(!live&&path==='/__fixture/fail-reads'){failReads=!failReads;f.setFailure(failReads?'timeout':null);res.end('ok');return;}
    if(!live&&path==='/__fixture/fail-next'){f.setFailure('once');res.end('ok');return;}
    if(!live&&path==='/__fixture/many-pages'){f.setPages(24);res.end('ok');return;}
    if(!live&&path==='/__fixture/one-page'){f.setPages(1);res.end('ok');return;}
    const controller=new AbortController();res.on('close',()=>{if(!res.writableEnded)controller.abort();});
    const request=new Request('http://127.0.0.1:'+server.address().port+req.url,{method:req.method,headers:req.headers,signal:controller.signal,
      ...(req.method==='GET'?{}:{body:Readable.toWeb(req),duplex:'half'})});
    const response=path.startsWith('/v1/connectors')?await connectorGateway.handle(request,{waitUntil:p=>p.catch(()=>{})}):await inference(request,{waitUntil:p=>p.catch(()=>{})});
    res.writeHead(response.status,Object.fromEntries(response.headers));if(response.body)for await(const chunk of response.body)res.write(chunk);res.end();
  }catch{res.writeHead(500);res.end('fixture failure');}
});
server.listen(0,'127.0.0.1',async()=>{
  const url='http://127.0.0.1:'+server.address().port;
  if(live){
    const apiKey=(await readFile(process.env.COMPOSIO_DEV_KEY_FILE,'utf8')).trim();
    const config=JSON.parse(await readFile(process.env.COMPOSIO_DEV_CONFIG_FILE,'utf8'));
    const expectedScopes={gmail:'https://www.googleapis.com/auth/gmail.readonly',
      'google-calendar':'https://www.googleapis.com/auth/calendar.events.readonly','google-drive':'https://www.googleapis.com/auth/drive.readonly'};
    for(const [service,id]of Object.entries(config.auth_configs??{})){
      if(!expectedScopes[service]||!/^ac_[A-Za-z0-9_-]+$/.test(id))throw new Error('Invalid acceptance auth config');
      const response=await fetch('https://backend.composio.dev/api/v3.1/auth_configs/'+id,
        {headers:{'x-api-key':apiKey},redirect:'error',signal:AbortSignal.timeout(10_000)});
      const value=await response.json(),scopes=value.credentials?.scopes;
      if(!response.ok||value.id!==id||!Array.isArray(scopes)||scopes.length!==1||scopes[0]!==expectedScopes[service]
        ||value.credentials?.user_scopes?.length)throw new Error('Read-only acceptance scopes required');
    }
    connectorGateway=createConnectorGateway({ledger:f.ledger,authenticate,provider:composioClient({apiKey}),
      config:{authConfigs:config.auth_configs,callbackBaseURL:url,readOnly:true}});
  }
  process.stdout.write(JSON.stringify({url,principal_token:principalToken})+'\n');
});
for(const signal of ['SIGINT','SIGTERM'])process.on(signal,()=>{server.closeAllConnections();server.close(async()=>{await f.close();process.exit(0);});});
