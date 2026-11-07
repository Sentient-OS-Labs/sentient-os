// Shared admission and bounded OpenAI transport for explicit screen/text actions.
// An explicit monthly cap of zero preserves the operator’s existing uncapped-month policy.
import {boundedJSON, digest, ServiceError} from './errors.mjs';
const nonnegative = value => value != null && String(value).trim() !== '' && Number.isSafeInteger(Number(value)) && Number(value) >= 0 ? Number(value) : null;
const positive = value => Number.isSafeInteger(Number(value)) && Number(value) > 0 ? Number(value) : null;
export async function screenAction(request, env, flag, maximumBytes, validate) {
  if (request.method !== 'POST') throw new ServiceError('method_not_allowed', 405);
  const caps = {hour: positive(env.HOURLY_CAP), day: positive(env.DAILY_CAP)};
  const globalCap = nonnegative(env.GLOBAL_MONTHLY_CAP);
  if (env[flag] !== 'true' || !env.OPENAI_API_KEY || !env.COUNTERS || !caps.hour || !caps.day || globalCap === null)
    throw new ServiceError('service_disabled', 503);
  const identity = /^Bearer\s+([A-Za-z0-9_-]{32,128})$/.exec(request.headers.get('authorization') ?? '')?.[1];
  if (!identity) throw new ServiceError('authentication_required', 401);
  const body = await boundedJSON(request, maximumBytes);
  validate(body);
  const personal = await env.COUNTERS.get(env.COUNTERS.idFromName(await digest(identity))).take(caps);
  if (!personal.ok) throw new ServiceError('usage_limit_reached', 429, {retry_after_seconds: personal.retryAfterSeconds});
  if (globalCap > 0) {
    const global = await env.COUNTERS.get(env.COUNTERS.idFromName('global')).take({month: globalCap});
    if (!global.ok) throw new ServiceError('service_budget_reached', 503);
  }
  return body;
}
export async function openAIStream(request, env, body, upstream = fetch) {
  let response;
  try {
    response = await upstream('https://api.openai.com/v1/responses', {
      method: 'POST', redirect: 'manual',
      headers: {authorization: `Bearer ${env.OPENAI_API_KEY}`, 'content-type': 'application/json'},
      signal: AbortSignal.any([request.signal, AbortSignal.timeout(30_000)]), body: JSON.stringify(body),
    });
  } catch { throw new ServiceError('upstream_unavailable', 502); }
  if (!response.ok || !response.body) {
    // Workerd supports manual redirect handling. Treat every redirect as a rejection, and
    // expose only fixed diagnostic categories, never an upstream message or request content.
    const detail = await boundedJSON(response, 16_000).catch(() => null);
    const codes = new Set(['model_not_found', 'invalid_api_key', 'insufficient_quota', 'rate_limit_exceeded',
      'unsupported_parameter', 'unsupported_value', 'invalid_value', 'invalid_type', 'invalid_json_schema', 'permission_denied']);
    const parameters = new Set(['model', 'service_tier', 'reasoning', 'reasoning.effort', 'max_output_tokens', 'text.format', 'text.format.schema', 'input', 'store']);
    throw new ServiceError('upstream_unavailable', 502, {upstream_status: response.status,
      ...(codes.has(detail?.error?.code) ? {upstream_code: detail.error.code} : {}),
      ...(parameters.has(detail?.error?.param) ? {upstream_parameter: detail.error.param} : {}),
    });
  }
  return new Response(response.body, {headers: {'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-store', 'x-relay-model': body.model}});
}
