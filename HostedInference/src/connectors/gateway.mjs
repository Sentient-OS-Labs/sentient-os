// Principal-authenticated connection management and capability-authenticated tool execution.
// Persistent connections outlive tasks; task sessions never outlive the acknowledged run lease.
import { bearer, boundedJSON, digest, errorResponse, randomToken, ServiceError } from '../errors.mjs';
import { services, toolsFor, prepareTool } from './catalog.mjs';
import { mutationReceipt, normalizeResult } from './results.mjs';

const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value);
const json = body => Response.json(body, { headers: { 'cache-control': 'no-store' } });
function fields(body, allowed, required = allowed) {
  if (Object.keys(body).some(k => !allowed.includes(k)) || required.some(k => !Object.hasOwn(body,k))) throw new ServiceError('invalid_request');
}
function capability(request) {
  const token = bearer(request);
  if (!/^hct_[a-f0-9]{64}$/.test(token)) throw new ServiceError('authentication_required',401);
  return digest(token);
}
const canonical = value => JSON.stringify(value, function(key, child) {
  return child && typeof child === 'object' && !Array.isArray(child)
    ? Object.fromEntries(Object.keys(child).sort().map(k => [k, child[k]])) : child;
});
export function createConnectorGateway({ ledger, authenticate, provider, config }) {
  const call = (operation, args) => ledger.call(operation, args);
  async function complete(record) {
    if (record.status === 'pending' && record.upstream_id && await provider.account(record)) {
      const completed=await call('complete_attempt', { principal_id: record.principal_id, attempt_id: record.attempt_id });
      return completed.status;
    }
    return record.status;
  }
  async function cleanup() {
    const { items } = await call('cleanup_list', {});
    for (const item of items) {
      try {
        if(!(await call('cleanup_claim',item)).claimed)continue;
        await provider.remove(item.kind,item.upstream_id,item.auth_config); await call('cleanup_done',item);
      }
      catch(error) {
        await call('cleanup_delay',{...item,seconds:error.details?.retry_after??60}).catch(()=>{});
        // Persistent outbox retains only identifiers; a later bounded sweep retries.
      }
    }
  }
  async function handle(request, context = {}) {
    try {
      const url = new URL(request.url), path = url.pathname;
      if(request.url.length>4096)throw new ServiceError('invalid_request');
      if (path === '/v1/connectors/callback' && request.method === 'GET') {
        const state = url.searchParams.get('state');
        if (!state || !/^[a-f0-9]{64}$/.test(state)) throw new ServiceError('invalid_attempt',400);
        const record = await call('callback', { state_hash: await digest(state) });
        // Callback status/account IDs are untrusted. Only the stored attempt and current
        // provider account state can finish OAuth; polling uses exactly this same path.
        if (record.status === 'pending' && record.upstream_id && await provider.account(record)) {
          await call('complete_attempt', { state_hash: await digest(state), attempt_id: record.attempt_id });
        }
        return new Response('<!doctype html><meta charset="utf-8"><title>Sentient connection</title><p>Return to Sentient to finish connecting. You may close this tab.</p>',
          { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'referrer-policy': 'no-referrer',
            'content-security-policy': "default-src 'none'; frame-ancestors 'none'", 'x-content-type-options': 'nosniff' } });
      }
      if (url.search || url.hash) throw new ServiceError('invalid_request');
      if (path === '/v1/connectors' && request.method === 'GET') {
        const principal_id = await authenticate(bearer(request));
        return json({ ...await call('list',{ principal_id }), services: Object.keys(config.authConfigs) });
      }
      if (path === '/v1/connectors/connect' && request.method === 'POST') {
        const principal_id = await authenticate(bearer(request));
        const body = await boundedJSON(request,4096);
        fields(body,['service','connection_id','label'],['service','label']);
        if (!Object.hasOwn(services,body.service) || !config.authConfigs[body.service]) throw new ServiceError('connector_not_configured',503);
        if (body.connection_id && !uuid(body.connection_id) || typeof body.label !== 'string' || !body.label.trim()
          || body.label.length > 100 || /[\x00-\x1f]/.test(body.label)) throw new ServiceError('invalid_request');
        if (body.connection_id) {
          const accounts = await call('list',{principal_id});
          if (!accounts.connections.some(c => c.id===body.connection_id && c.service===body.service)) throw new ServiceError('connection_not_found',404);
        }
        const state = randomToken().slice(4), id = crypto.randomUUID();
        const record = await call('begin',{principal_id,...body,id,state_hash:await digest(state),auth_config:config.authConfigs[body.service]});
        let link;
        try {
          link = await provider.link(record,`${config.callbackBaseURL}/v1/connectors/callback?state=${state}`);
          await call('bind_attempt',{principal_id,attempt_id:id,upstream_id:link.upstream_id});
        } catch (error) {
          await call('cancel',{principal_id,attempt_id:id}).catch(()=>{});
          if (link) await call('cleanup_enqueue',{kind:'connection',upstream_id:link.upstream_id,auth_config:record.auth_config}).catch(()=>{});
          throw error;
        }
        return json({attempt_id:id,connection_id:record.connection_id,generation:record.generation,
          redirect_url:link.redirect_url,expires_at:record.expires_at});
      }
      const attempt = path.match(/^\/v1\/connectors\/attempts\/([a-f0-9-]{36})(\/cancel)?$/);
      if(attempt&&!uuid(attempt[1]))throw new ServiceError('invalid_request');
      if (attempt && (request.method==='GET' && !attempt[2] || request.method==='POST' && attempt[2])) {
        const principal_id = await authenticate(bearer(request));
        if (attempt[2]) { await call('cancel',{principal_id,attempt_id:attempt[1]}); context.waitUntil?.(cleanup()); return json({status:'cancelled'}); }
        const record = await call('attempt',{principal_id,attempt_id:attempt[1]});
        const status = await complete({...record,principal_id});
        return json({status,connection_id:record.connection_id,generation:record.generation});
      }
      const disconnect = path.match(/^\/v1\/connectors\/([a-f0-9-]{36})\/disconnect$/);
      if(disconnect&&!uuid(disconnect[1]))throw new ServiceError('invalid_request');
      if (disconnect && request.method==='POST') {
        const principal_id=await authenticate(bearer(request));
        const body=await boundedJSON(request,1024);fields(body,['revoke_provider'],[]);
        if(body.revoke_provider!==undefined && typeof body.revoke_provider!=='boolean')throw new ServiceError('invalid_request');
        await call('disconnect',{principal_id,connection_id:disconnect[1],revoke_provider:body.revoke_provider===true});
        context.waitUntil?.(cleanup());
        return json(await call('list',{principal_id}));
      }
      const review=path.match(/^\/v1\/connectors\/([a-f0-9-]{36})\/(uncertain-actions|resolve-action)$/);
      if(review&&!uuid(review[1]))throw new ServiceError('invalid_request');
      if(review) {
        const principal_id=await authenticate(bearer(request));
        if(review[2]==='uncertain-actions'&&request.method==='GET')return json(await call('uncertain_actions',{principal_id,connection_id:review[1]}));
        if(review[2]==='resolve-action'&&request.method==='POST') {
          const body=await boundedJSON(request,4096);fields(body,['operation_id','outcome']);
          if(!uuid(body.operation_id)||!['reported_completed','allow_retry'].includes(body.outcome))throw new ServiceError('invalid_request');
          await call('resolve_action',{principal_id,connection_id:review[1],...body});return json({status:'reviewed'});
        }
        throw new ServiceError('not_found',404);
      }
      if (path==='/v1/connectors/capabilities' && request.method==='POST') {
        // Only the app's principal credential can delegate tools. An inference ticket in a
        // CLI cannot promote itself into cloud actions or attach additional accounts.
        const principal_id=await authenticate(bearer(request));
        const body = await boundedJSON(request,4096); fields(body,['run_id','connection_id','generation','mode']);
        if (!uuid(body.run_id) || !uuid(body.connection_id) || !Number.isSafeInteger(body.generation) || body.generation<1 || !['read','action'].includes(body.mode)) throw new ServiceError('invalid_request');
        if(config.readOnly && body.mode!=='read')throw new ServiceError('tool_not_allowed',403);
        const capability_token=randomToken().replace('hrt_','hct_'), token_hash=await digest(capability_token);
        const record=await call('prepare',{...body,principal_id,id:crypto.randomUUID(),capability_hash:token_hash});
        let session;
        try {
          // Exact ownership is checked again before creating a session, never used as a Done gate.
          if (!await provider.account(record)) throw new ServiceError('connection_required',409);
          session=await provider.session(record);
          await call('bind_session',{token_hash,session_id:session});
        } catch (error) {
          await call('close',{token_hash}).catch(()=>{});
          if (session || error.sessionID) await call('cleanup_enqueue',{kind:'session',upstream_id:session ?? error.sessionID,auth_config:record.auth_config}).catch(()=>{});
          throw error;
        }
        return json({capability_token,connection_id:record.connection_id,generation:record.generation,
          tools:toolsFor(record.service,record.mode).map(({name,description,inputSchema,write})=>({name,description,inputSchema,write}))});
      }
      if (path==='/v1/connectors/close' && request.method==='POST') {
        await call('close',{token_hash:await capability(request)}); context.waitUntil?.(cleanup()); return json({status:'closed'});
      }
      if (path==='/v1/connectors/check' && request.method==='POST') {
        const token=bearer(request);
        if (!/^hrt_[a-f0-9]{64}$/.test(token)) throw new ServiceError('authentication_required',401);
        const body=await boundedJSON(request,4096);fields(body,['connections']);
        if (!Array.isArray(body.connections) || body.connections.length>20 || body.connections.some(x=>!uuid(x))) throw new ServiceError('invalid_request');
        await call('check_run',{run_token_hash:await digest(token),connections:body.connections});
        return json({status:'active'});
      }
      if (path==='/v1/connectors/execute' && request.method==='POST') {
        const auth={token_hash:await capability(request)};
        const body=await boundedJSON(request,64_000);fields(body,['tool','arguments','operation_id']);
        if (!uuid(body.operation_id)) throw new ServiceError('invalid_request');
        const record=await call('admit',auth);
        const prepared=prepareTool(record.service,record.mode,body.tool,body.arguments), tool=prepared.tool;
        const queryHash=await digest(canonical({...body.arguments,cursor:undefined}));
        if (body.arguments.cursor) {
          const cursor=await call('cursor_get',{...auth,cursor_id:body.arguments.cursor,tool:tool.name,request_hash:queryHash});
          prepared.arguments[tool.cursorField]=cursor.value;
        }
        // Normalize through the reviewed mapping first: equivalent calendar offsets and
        // omitted defaults must not turn a retry into a second external mutation.
        const request_hash=await digest(canonical({tool:tool.upstream,arguments:prepared.arguments}));
        const reservationStarted=performance.now();
        const reservation=await call('reserve',{...auth,operation_key:body.operation_id,request_hash,tool:tool.name,is_write:tool.write});
        if (reservation.replay) {
          if (tool.write && reservation.status==='completed') return json({status:'completed',receipt:reservation.receipt,replayed:true});
          throw new ServiceError(tool.write?'write_outcome_unknown':'read_already_dispatched',409);
        }
        const controller=new AbortController();
        let timer, deadline, done=false;
        const acknowledge=(value,sentAt)=>{
          clearTimeout(deadline);
          const remaining=Date.parse(value.lease_expires_at)-Date.parse(value.server_time)-(performance.now()-sentAt);
          if (!(remaining>0)) {controller.abort();return;}
          deadline=setTimeout(()=>controller.abort(),remaining);
          timer=setTimeout(async()=>{
            const sent=performance.now();
            try {const latest=await call('inspect',auth);if(!done)acknowledge(latest,sent);}catch{controller.abort();}
          },Math.min(1500,remaining));
        };
        acknowledge(reservation,reservationStarted);
        try {
          const data=await provider.execute(record,tool,prepared.arguments,AbortSignal.any([request.signal,controller.signal]));
          // A disconnect/generation change prevents release of late results too.
          await call('inspect',auth);
          if(tool.write) {
            const receipt=mutationReceipt(tool,data,body.arguments);
            await call('settle',{...auth,operation_id:reservation.operation_id,status:'completed',receipt});
            return json({status:'completed',receipt});
          }
          const normalized=normalizeResult(tool,data,body.arguments);
          let cursor=null;
          if(normalized.next!==null) cursor=(await call('cursor_put',{...auth,tool:tool.name,request_hash:queryHash,value:normalized.next})).cursor;
          await call('settle',{...auth,operation_id:reservation.operation_id,status:'completed',receipt:{}});
          return json({status:'completed',data:normalized.data,cursor});
        } catch(error) {
          const settlement=call('settle',{...auth,operation_id:reservation.operation_id,status:tool.write?'unknown':'failed',receipt:{}}).catch(()=>{});
          context.waitUntil?.(settlement);await settlement;
          if(tool.write) throw new ServiceError('write_outcome_unknown',409);
          throw error;
        } finally {done=true;clearTimeout(timer);clearTimeout(deadline);controller.abort();}
      }
      throw new ServiceError('not_found',404);
    } catch(error) { return errorResponse(error,crypto.randomUUID()); }
  }
  return {handle,cleanup};
}
