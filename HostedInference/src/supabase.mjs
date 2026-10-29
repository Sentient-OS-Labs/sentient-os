// Supabase validates caller tokens; restricted RPCs provide the sole persistent quota ledger.
// Setup and contract: ../README.md. No client-provided identity is trusted.
import { ServiceError } from './errors.mjs';

export function supabaseServices({ url, publishableKey, serviceRoleKey, fetcher = fetch }) {
  const base = new URL(url);
  if (base.protocol !== 'https:' || base.username || base.password || base.search || base.hash) {
    throw new Error('Supabase requires an HTTPS origin');
  }
  if (!publishableKey || !serviceRoleKey) throw new Error('Supabase credentials are required');
  async function safeJSON(response) {
    if (!response.ok) throw new ServiceError('service_unavailable', 503);
    const text = await response.text();
    if (text.length > 128_000) throw new ServiceError('service_unavailable', 503);
    try { return JSON.parse(text); } catch { throw new ServiceError('service_unavailable', 503); }
  }
  const authenticate = async token => {
    let response;
    try {
      response = await fetcher(new URL('/auth/v1/user', base), {
        headers: { apikey: publishableKey, authorization: `Bearer ${token}` },
        redirect: 'error', signal: AbortSignal.timeout(10_000),
      });
    } catch { throw new ServiceError('authentication_unavailable', 503); }
    if (response.status === 401 || response.status === 403) throw new ServiceError('authentication_required', 401);
    const user = await safeJSON(response);
    if (!/^[0-9a-f-]{36}$/i.test(user.id ?? '') || user.banned_until && Date.parse(user.banned_until) > Date.now()) {
      throw new ServiceError('authentication_required', 401);
    }
    return user.id;
  };
  const call = async (operation, args) => {
    let response;
    try {
      response = await fetcher(new URL('/rest/v1/rpc/hosted_inference', base), {
        method: 'POST', headers: {
          apikey: serviceRoleKey, authorization: `Bearer ${serviceRoleKey}`, 'content-type': 'application/json',
        },
        body: JSON.stringify({ operation, args }), redirect: 'error', signal: AbortSignal.timeout(15_000),
      });
    } catch { throw new ServiceError('ledger_unavailable', 503); }
    const result = await safeJSON(response);
    if (result.error) throw new ServiceError(result.error, result.status ?? 429, result.details ?? {});
    return result;
  };
  return { authenticate, ledger: { call } };
}
