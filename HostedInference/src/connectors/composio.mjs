// Only this server-side adapter knows the Composio project key. No SDK default retries,
// arbitrary hosts, MCP headers, account state or provider error bodies cross the gateway.
import { boundedJSON, ServiceError } from '../errors.mjs';
import { services, toolsFor } from './catalog.mjs';
import { reviewedVersions } from './versions.mjs';

const base = 'https://backend.composio.dev/api/v3.1';
const identifier = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,160}$/.test(value);
export function readConnectorConfig(env) {
  let authConfigs;
  try { authConfigs = JSON.parse(env.COMPOSIO_AUTH_CONFIGS ?? '{}'); } catch { throw new ServiceError('connectors_not_configured', 503); }
  if (!env.COMPOSIO_API_KEY || !env.CONNECTOR_CALLBACK_BASE_URL) throw new ServiceError('connectors_not_configured', 503);
  const callback = new URL(env.CONNECTOR_CALLBACK_BASE_URL);
  if (callback.protocol !== 'https:' || callback.username || callback.password || callback.search || callback.hash || !['/','/hosted','/hosted/'].includes(callback.pathname)) {
    throw new ServiceError('connectors_not_configured', 503);
  }
  for (const [service, id] of Object.entries(authConfigs)) if (!Object.hasOwn(services, service) || !identifier(id)) throw new ServiceError('connectors_not_configured', 503);
  return { apiKey: env.COMPOSIO_API_KEY, authConfigs, callbackBaseURL: callback.origin + (callback.pathname.startsWith('/hosted') ? '/hosted' : '') };
}
export function composioClient({ apiKey, fetcher = fetch }) {
  if (!apiKey) throw new ServiceError('connectors_not_configured', 503);
  async function request(path, method = 'GET', body, signal, maximum = 1_048_576) {
    let response;
    try {
      response = await fetcher(base + path, { method, headers: { 'x-api-key': apiKey, 'content-type': 'application/json' },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }), redirect: 'error',
        signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(30_000)]) : AbortSignal.timeout(15_000) });
    } catch { throw new ServiceError('connector_upstream_unavailable', 503); }
    if (!response.ok) {
      await response.body?.cancel();
      const retry = Math.min(300, Math.max(1, Number(response.headers.get('retry-after')) || 5));
      if (response.status === 429) throw new ServiceError('connector_rate_limited', 429, { retry_after: retry });
      if (response.status === 404) throw new ServiceError('connector_upstream_not_found', 404);
      if (response.status >= 400 && response.status < 500) throw new ServiceError('connector_upstream_rejected', 502);
      throw new ServiceError('connector_upstream_unavailable', 503);
    }
    if (response.status === 204) return null;
    try { return await boundedJSON(response, maximum); }
    catch { throw new ServiceError('connector_invalid_response', 502); }
  }
  const pathID = value => { if (!identifier(value)) throw new ServiceError('connector_invalid_response', 502); return value; };
  return {
    async link(record, callbackURL) {
      const response = await request('/connected_accounts/link', 'POST', {
        user_id: record.composio_user, auth_config_id: record.auth_config, callback_url: callbackURL,
        alias: 'sentient_attempt_' + pathID(record.attempt_id),
        experimental: { account_type: 'PRIVATE' },
      });
      const url = new URL(response.redirect_url);
      if (url.protocol !== 'https:' || url.hostname !== 'connect.composio.dev' || url.username || url.password || url.hash
        || !url.pathname.startsWith('/link/') || url.href.includes(apiKey) || !identifier(response.connected_account_id)) throw new ServiceError('connector_invalid_response', 502);
      return { upstream_id: response.connected_account_id, redirect_url: url.href };
    },
    async account(record) {
      const response = await request(`/connected_accounts/${pathID(record.upstream_id)}`);
      // IDs originate only from this principal's server-created attempt. The provider's
      // ownership field is deprecated; require it when returned, and also verify configuration.
      if (response.id !== record.upstream_id || response.user_id && response.user_id !== record.composio_user
        || response.toolkit?.slug !== services[record.service] || response.auth_config?.id !== record.auth_config
        || response.experimental?.account_type === 'SHARED') throw new ServiceError('connection_ownership', 403);
      if(['FAILED','EXPIRED','INACTIVE','REVOKED','DISABLED'].includes(response.status)) throw new ServiceError('connection_required',409);
      return response.status === 'ACTIVE' && !response.is_disabled && !response.auth_config?.is_disabled;
    },
    async session(record) {
      const toolkit = services[record.service];
      const response = await request('/tool_router/session', 'POST', {
        user_id: record.composio_user, toolkits: { enable: [toolkit] },
        auth_configs: { [toolkit]: record.auth_config }, connected_accounts: { [toolkit]: [record.upstream_id] },
        tools: { [toolkit]: { enable: toolsFor(record.service, record.mode).map(t => t.upstream) } },
        manage_connections: { enable: false, enable_wait_for_connections: false, enable_connection_removal: false },
        workbench: { enable: false, enable_tool_execution: false, enable_proxy_execution: false },
        proxy_execute: { enable: false }, instant: false, search: { enable: false }, execute: { enable_multi_execute: false },
        preload: { tools: 'all' }, multi_account: { enable: false },
      });
      const sessionID=pathID(response.session_id); // mcp.url / mcp.headers are deliberately discarded.
      try {
        const inventory=await request(`/tool_router/session/${sessionID}/tools?limit=100`);
        const expected=toolsFor(record.service,record.mode);
        if (!Array.isArray(inventory.items) || inventory.next_cursor || expected.some(tool=>
          !inventory.items.some(item=>item.slug===tool.upstream && item.version===reviewedVersions[tool.upstream]))) {
          throw new ServiceError('connector_contract_changed',503);
        }
      } catch(error) {
        // Creation succeeded; retain the ID on this typed internal error for durable cleanup.
        const failure=new ServiceError(error.code ?? 'connector_contract_changed',503);
        failure.sessionID=sessionID;throw failure;
      }
      return sessionID;
    },
    async execute(record, tool, args, signal) {
      const response = await request(`/tool_router/session/${pathID(record.session_id)}/execute`, 'POST', {
        tool_slug: tool.upstream, arguments: args, account: record.upstream_id, enable_auto_workbench_offload: false,
      }, signal);
      if(JSON.stringify(response.data??{}).includes(apiKey))throw new ServiceError('connector_invalid_response',502);
      if (response.result_type !== 'completed' || response.error != null || !response.data || typeof response.data !== 'object'
        || response.data.successful === false || response.data.ok === false || response.data.error) {
        // An HTTP-200 failure may occur after a write reached the provider. Keep it uncertain.
        throw new ServiceError('connector_execution_failed', 502);
      }
      if (tool.textDownload) {
        const payload = response.data.data ?? response.data;
        const file = payload.downloaded_file_content;
        if (payload.export_size_limit_exceeded || !file || !['text/plain','text/markdown'].includes(file.mimetype)) throw new ServiceError('connector_file_unavailable',422);
        let url;
        try { url = new URL(file.s3url); } catch { throw new ServiceError('connector_file_unavailable',422); }
        // Only a provider-returned S3 file URL is accepted. Never forward authentication,
        // follow redirects, accept a client URL, or expose the presigned link to the CLI.
        if (url.protocol!=='https:' || url.username || url.password || url.port || url.hash ||
          !/^(?:[a-z0-9.-]+\.)?s3(?:[.-][a-z0-9-]+)?\.amazonaws\.com$/.test(url.hostname)) throw new ServiceError('connector_file_unavailable',422);
        let fileResponse;
        try { fileResponse = await fetcher(url.href,{method:'GET',redirect:'error',signal:AbortSignal.any([signal,AbortSignal.timeout(15_000)])}); }
        catch { throw new ServiceError('connector_file_unavailable',422); }
        if (!fileResponse.ok || !fileResponse.body || Number(fileResponse.headers.get('content-length'))>256_000) {
          await fileResponse.body?.cancel();throw new ServiceError('connector_file_unavailable',422);
        }
        const reader=fileResponse.body.getReader(), chunks=[];let count=0;
        try {
          while(true){const {done,value}=await reader.read();if(done)break;count+=value.byteLength;
            if(count>256_000)throw new ServiceError('connector_file_unavailable',422);chunks.push(value);}
          const bytes=new Uint8Array(count);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.byteLength;}
          return {downloaded_file_content:new TextDecoder('utf-8',{fatal:true}).decode(bytes)};
        } catch {throw new ServiceError('connector_file_unavailable',422);}
        finally{await reader.cancel().catch(()=>{});reader.releaseLock();}
      }
      return response.data;
    },
    async remove(kind, upstreamID, authConfig) {
      // A 404 from the wrong project's key is not proof that the original credential was
      // deleted. First establish access to the exact auth config that created this object.
      const configuration=await request(`/auth_configs/${pathID(authConfig)}`);
      if(configuration.id!==authConfig)throw new ServiceError('connection_ownership',403);
      if (kind === 'session') {
        try {
          const result=await request(`/tool_router/session/${pathID(upstreamID)}`, 'DELETE');
          if(result?.session_id!==upstreamID || result.deleted!==true)throw new ServiceError('connector_invalid_response',502);
        }
        catch (e) { if (e.code !== 'connector_upstream_not_found') throw e; }
      } else {
        // A delete alone removes Composio's record; it is not proof of provider revocation.
        // Retiring a replaced/cancelled record is not provider-wide grant revocation:
        // revoking an old OAuth grant can invalidate the user's newly reconnected account.
        if(kind==='account') {
          try {
            const result=await request(`/connected_accounts/${pathID(upstreamID)}/revoke`, 'POST', {});
            if(result?.connected_account?.id!==upstreamID || result.connected_account.status!=='REVOKED'
              || !Array.isArray(result.revoked_tokens))throw new ServiceError('connector_invalid_response',502);
          }
          catch (e) { if (e.code === 'connector_upstream_not_found') return; throw e; }
        }
        try {
          const result=await request(`/connected_accounts/${pathID(upstreamID)}`, 'DELETE');
          if(result?.success!==true)throw new ServiceError('connector_invalid_response',502);
        }
        catch (e) { if (e.code !== 'connector_upstream_not_found') throw e; }
      }
    },
  };
}
