// Issues single-use Scribe credentials to authenticated installations. Audio goes directly
// from the Mac to ElevenLabs. Persistent limits bound token issuance, not session duration.
import {bearer, boundedJSON, errorResponse, ServiceError} from './errors.mjs';

export function createScribeGateway({authenticate, ledger, apiKey, enabled, zeroRetention = false, upstream = fetch}) {
  return async request => {
    try {
      const url = new URL(request.url);
      if (url.pathname !== '/v1/dictation/token' || request.method !== 'POST') throw new ServiceError('not_found', 404);
      if (url.search || url.hash) throw new ServiceError('invalid_request');
      const principal_id = await authenticate(bearer(request));
      const body = await boundedJSON(request, 1024);
      if (!body || Array.isArray(body) || Object.keys(body).length) throw new ServiceError('invalid_request');
      if (!enabled || !apiKey) throw new ServiceError('dictation_not_configured', 503);
      // Reserve before contacting the provider. Unknown outcomes remain counted; no automatic retry.
      await ledger.call('issue', {principal_id});
      let response;
      try {
        response = await upstream('https://api.elevenlabs.io/v1/single-use-token/realtime_scribe', {
          method: 'POST', headers: {'xi-api-key': apiKey}, redirect: 'manual',
          signal: AbortSignal.any([request.signal, AbortSignal.timeout(8000)]),
        });
      } catch { throw new ServiceError('dictation_unavailable', 503); }
      if (!response.ok) {
        await response.body?.cancel();
        throw new ServiceError(response.status === 429 ? 'dictation_rate_limited' : 'dictation_unavailable', 503);
      }
      const result = await boundedJSON(response, 16_384);
      if (typeof result.token !== 'string' || !/^[\x21-\x7e]{16,8192}$/.test(result.token)) {
        throw new ServiceError('dictation_unavailable', 502);
      }
      return Response.json({token: result.token, zero_retention: zeroRetention},
        {headers: {'cache-control': 'no-store'}});
    } catch (error) { return errorResponse(error, crypto.randomUUID()); }
  };
}
