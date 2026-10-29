// Server-owned model and request bounds. Request content never sets pricing or the upstream host.
// Setup and contract: ../README.md.
import { ServiceError } from './errors.mjs';

export const PURPOSES = new Set(['sidekick', 'knowledge_bootstrap', 'knowledge_update', 'proactive', 'utility']);

export function validateConfiguration(config) {
  if (!config?.model || !config?.upstreamKey || !config?.pricing) throw new Error('A model, upstream key and pricing are required');
  for (const key of ['input', 'cacheWrite', 'cacheRead', 'output']) {
    if (!Number.isSafeInteger(config.pricing[key]) || config.pricing[key] < 0) throw new Error(`Invalid ${key} price`);
  }
  if (Math.max(config.pricing.input, config.pricing.cacheWrite, config.pricing.output) <= 0) throw new Error('Zero-cost production pricing is forbidden');
  for (const key of ['maximumInputTokens', 'maximumOutputTokens', 'maximumBodyBytes', 'requestTimeoutMS', 'leaseCheckMS']) {
    if (!Number.isSafeInteger(config[key]) || config[key] <= 0) throw new Error(`Invalid ${key}`);
  }
  return config;
}

export function prepareMessage(body, model, config) {
  const allowed = new Set(['model', 'messages', 'system', 'tools', 'tool_choice', 'max_tokens', 'stream',
    'temperature', 'top_p', 'top_k', 'stop_sequences', 'thinking', 'output_config', 'metadata',
    'context_management', 'service_tier']);
  for (const key of Object.keys(body)) if (!allowed.has(key)) throw new ServiceError('unsupported_parameter');
  if (body.model !== model) throw new ServiceError('model_not_allowed');
  if (!Array.isArray(body.messages) || !body.messages.length || body.messages.length > 1000) throw new ServiceError('invalid_messages');
  if (!Number.isSafeInteger(body.max_tokens) || body.max_tokens < 1 || body.max_tokens > config.maximumOutputTokens) {
    throw new ServiceError('output_limit_exceeded');
  }
  if (body.stream !== true) throw new ServiceError('stream_required');
  if (body.service_tier && body.service_tier !== 'auto' && body.service_tier !== 'standard_only') throw new ServiceError('service_tier_not_allowed');
  const tools = body.tools ?? [];
  if (!Array.isArray(tools) || tools.length > 128) throw new ServiceError('invalid_tools');
  // Server tools can have separate usage charges. No hosted execution/search/uploads without
  // a reviewed pricing contract; local custom and computer tools execute only on the Mac.
  const types = new Set(['custom', 'computer_20250124', 'computer_20251124', 'bash_20250124', 'text_editor_20250124', 'text_editor_20250728']);
  for (const tool of tools) {
    if (!tool || typeof tool !== 'object' || (tool.type && !types.has(tool.type))) throw new ServiceError('tool_type_not_allowed');
  }
  // Shared provider credentials must never grant access to another request's provider-side
  // files or a remote URL. Tools may return only inline content through this gateway.
  const inspect = value => {
    if (!value || typeof value !== 'object') return;
    if (Array.isArray(value)) { value.forEach(inspect); return; }
    if (value.file_id !== undefined || value.type === 'container_upload' || value.type === 'url'
      || value.type === 'file') throw new ServiceError('remote_content_not_allowed');
    for (const item of Object.values(value)) inspect(item);
  };
  inspect(body.messages);
  inspect(body.system);
  if (body.thinking?.budget_tokens !== undefined && (!Number.isSafeInteger(body.thinking.budget_tokens) || body.thinking.budget_tokens < 0 || body.thinking.budget_tokens > body.max_tokens)) {
    throw new ServiceError('thinking_limit_exceeded');
  }
  // The context ceiling is the reservation bound, including cache writes. This intentionally
  // reserves more than likely usage; release the unused amount from the provider receipt.
  // No client token estimate or cache hit assertion can reduce this reservation.
  const reserveMicrousd = estimateCost({ input_tokens: config.maximumInputTokens, output_tokens: body.max_tokens }, config.pricing, true);
  return { body: { ...body, model, stream: true, service_tier: 'standard_only' }, reserveMicrousd };
}

export function estimateCost(usage, pricing, reserve = false) {
  const value = name => {
    const n = usage[name] ?? 0;
    if (!Number.isSafeInteger(n) || n < 0) throw new ServiceError('invalid_upstream_usage', 502);
    return n;
  };
  // Prices are integer micro-US-dollars per million tokens, not floating dollar values.
  const input = reserve ? Math.max(pricing.input, pricing.cacheWrite, pricing.cacheRead) : pricing.input;
  const numerator = BigInt(value('input_tokens')) * BigInt(input)
    + BigInt(value('cache_creation_input_tokens')) * BigInt(pricing.cacheWrite)
    + BigInt(value('cache_read_input_tokens')) * BigInt(pricing.cacheRead)
    + BigInt(value('output_tokens')) * BigInt(pricing.output);
  const amount = Number((numerator + 999_999n) / 1_000_000n);
  if (!Number.isSafeInteger(amount)) throw new ServiceError('invalid_upstream_usage', 502);
  return amount;
}

export function readProductionConfig(env) {
  // No live-service default: deployment must explicitly choose and price the real model.
  const number = key => Number(env[key]);
  return validateConfiguration({
    model: env.ANTHROPIC_MODEL,
    upstreamKey: env.ANTHROPIC_API_KEY,
    pricing: { input: number('INPUT_MICROUSD_PER_MILLION'), output: number('OUTPUT_MICROUSD_PER_MILLION'),
      cacheWrite: number('CACHE_WRITE_MICROUSD_PER_MILLION'), cacheRead: number('CACHE_READ_MICROUSD_PER_MILLION') },
    maximumInputTokens: number('MAXIMUM_INPUT_TOKENS'), maximumOutputTokens: number('MAXIMUM_OUTPUT_TOKENS'),
    maximumBodyBytes: number('MAXIMUM_BODY_BYTES'), requestTimeoutMS: number('REQUEST_TIMEOUT_MS'),
    leaseCheckMS: number('LEASE_CHECK_MS'), betas: env.ANTHROPIC_BETAS ?? '',
  });
}
