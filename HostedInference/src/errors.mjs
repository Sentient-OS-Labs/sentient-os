// Safe service errors: response bodies and logs never include provider payloads or credentials.
// Setup and contract: ../README.md.
export class ServiceError extends Error {
  constructor(code, status = 400, details = {}) {
    super(code);
    this.code = code;
    this.status = status;
    this.details = details;
  }
}

export function errorResponse(error, requestID) {
  const known = error instanceof ServiceError;
  const code = known ? error.code : 'service_unavailable';
  const status = known ? error.status : 503;
  return Response.json({
    type: 'error',
    error: { type: code, code, message: safeMessage(code), ...(known ? error.details : {}) },
    request_id: requestID,
    ...(known ? error.details : {}),
  }, { status, headers: { 'cache-control': 'no-store', 'x-request-id': requestID } });
}

function safeMessage(code) {
  const messages = {
    authentication_required: 'Sign in to hosted inference again.',
    daily_time_exhausted: 'Your daily hosted Sidekick allowance is used up.',
    usage_limit_reached: 'The hosted usage allowance has been reached.',
    service_budget_reached: 'Hosted inference is temporarily unavailable.',
    run_expired: 'This hosted run has expired. Start a new run.',
    run_busy: 'A request is already running.',
    request_already_dispatched: 'This request was already dispatched. Check its status before retrying.',
    service_disabled: 'Hosted inference is not enabled.',
    upstream_unavailable: 'The model service is temporarily unavailable.',
  };
  return messages[code] ?? 'The hosted request could not be completed.';
}

export function bearer(request, { allowAPIKey = false } = {}) {
  const authorization = request.headers.get('authorization');
  const match = authorization?.match(/^Bearer ([^\s]+)$/i);
  if (authorization && !match) throw new ServiceError('authentication_required', 401);
  const key = allowAPIKey ? request.headers.get('x-api-key') : null;
  if (key && match && key !== match[1]) throw new ServiceError('conflicting_credentials', 401);
  const token = match?.[1] ?? key;
  if (!token || token.length > 8192 || /\s/.test(token)) throw new ServiceError('authentication_required', 401);
  return token;
}

export async function digest(value) {
  const bytes = new TextEncoder().encode(value);
  const hashed = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(hashed), b => b.toString(16).padStart(2, '0')).join('');
}

export function randomToken() {
  return 'hrt_' + Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2, '0')).join('');
}

export async function boundedJSON(request, maximumBytes) {
  if (Number(request.headers.get('content-length')) > maximumBytes) throw new ServiceError('request_too_large', 413);
  if (!request.body) throw new ServiceError('invalid_request', 400);
  const reader = request.body.getReader();
  const chunks = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > maximumBytes) {
        await reader.cancel();
        throw new ServiceError('request_too_large', 413);
      }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const data = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.byteLength; }
  let object;
  try { object = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(data)); }
  catch { throw new ServiceError('invalid_json', 400); }
  if (!object || typeof object !== 'object' || Array.isArray(object)) throw new ServiceError('invalid_request', 400);
  return object;
}
