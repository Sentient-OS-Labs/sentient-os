// Compose dictation and explicit quick actions with the existing Worker. Dictation uses
// the caller JWT for its quota RPC; screen/text actions use the existing relay identity.
import {bearer, boundedJSON, errorResponse, ServiceError} from './errors.mjs';
import {proofread} from './proofread.mjs';
import {summarize} from './summarize.mjs';
import {createScribeGateway} from './scribe.mjs';

export function composeDictationRelay(legacy, fetcher = fetch) {
  return {
    ...legacy,
    async fetch(request, env, context) {
      const url = new URL(request.url);
      if (url.pathname === '/v1/proofread') return proofread(request, env, fetcher);
      if (url.pathname === '/v1/summarize') return summarize(request, env, fetcher);
      if (!url.pathname.startsWith('/hosted/v1/dictation')) return legacy.fetch(request, env, context);
      try {
        const token = bearer(request);
        const base = new URL(env.SUPABASE_URL);
        if (base.protocol !== 'https:' || base.username || base.password || base.search || base.hash
            || !env.SUPABASE_PUBLISHABLE_KEY) throw new ServiceError('dictation_not_configured', 503);
        const headers = {apikey: env.SUPABASE_PUBLISHABLE_KEY, authorization: `Bearer ${token}`};
        async function call(path, method = 'GET') {
          let response;
          try {
            response = await fetcher(new URL(path, base), {method, headers: {...headers, 'content-type': 'application/json'},
              ...(method === 'POST' ? {body: '{}'} : {}), redirect: 'manual',
              signal: AbortSignal.any([request.signal, AbortSignal.timeout(10_000)])});
          } catch { throw new ServiceError('dictation_unavailable', 503); }
          if (!response.ok) {
            await response.body?.cancel();
            throw new ServiceError(response.status === 401 || response.status === 403 ? 'authentication_required' : 'dictation_unavailable',
              response.status === 401 || response.status === 403 ? 401 : 503);
          }
          return boundedJSON(response, 64_000);
        }
        url.pathname = url.pathname.slice('/hosted'.length);
        return await createScribeGateway({
          authenticate: async () => {
            const user = await call('/auth/v1/user');
            if (!/^[a-f0-9-]{36}$/i.test(user.id ?? '') || user.banned_until && Date.parse(user.banned_until) > Date.now()) {
              throw new ServiceError('authentication_required', 401);
            }
            return user.id;
          },
          ledger: {async call() {
            const result = await call('/rest/v1/rpc/reserve_dictation_token', 'POST');
            if (result.error) throw new ServiceError(result.error, result.status ?? 429);
            if (result.accepted !== true) throw new ServiceError('dictation_unavailable', 503);
            return result;
          }},
          apiKey: env.ELEVENLABS_API_KEY, enabled: env.SCRIBE_ENABLED === 'true',
          zeroRetention: env.SCRIBE_ZERO_RETENTION === 'true', upstream: fetcher,
        })(new Request(url, request));
      } catch (error) { return errorResponse(error, crypto.randomUUID()); }
    },
  };
}
