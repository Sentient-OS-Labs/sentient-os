// Loopback-only production summary relay with an in-process synthetic OpenAI upstream.
import http from 'node:http';
import {summarize} from '../../HostedInference/src/summarize.mjs';
import {proofread} from '../../HostedInference/src/proofread.mjs';
import assert from 'node:assert/strict';
const env = {SENTIENT_SUMMARIZE_ENABLED: 'true', SENTIENT_PROOFREAD_ENABLED: 'true', OPENAI_API_KEY: 'fixture-not-a-key',
  HOURLY_CAP: '100', DAILY_CAP: '100', GLOBAL_MONTHLY_CAP: '1000',
  COUNTERS: {idFromName: value => value, get: () => ({take: async () => ({ok: true})})}};
const event = value => `data: ${JSON.stringify(value)}\r\n\r\n`;
const server = http.createServer(async (req, res) => {
  try {
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    const request = new Request(`http://127.0.0.1${req.url}`, {method: req.method,
      headers: req.headers, body: Buffer.concat(chunks)});
    const response = await (req.url === '/v1/proofread' ? proofread : summarize)(request, env, async (url, options) => {
      assert.equal(url, 'https://api.openai.com/v1/responses');
      const body = JSON.parse(options.body);
      assert.equal(body.model, req.url === '/v1/proofread' ? 'gpt-6-luna' : 'gpt-6.1-terra'); assert.equal(body.service_tier, 'fast');
      const preference = body.input[0].content[0].text;
      if (preference === 'network-error') throw new Error('synthetic provider failure');
      const text = req.url === '/v1/proofread' ? (preference === 'malformed' ? '{"wrong":"text"}' : JSON.stringify({corrected_text: preference.replace('teh','the')})) : 'A clear summary of the café screen.\n\n- One useful detail.';
      const parts = [event({type: 'response.output_text.delta', delta: text})];
      if (preference !== 'interrupted') parts.push(event({type: 'response.completed', response: {status: 'completed', output: [
        {type: 'message', content: [{type: 'output_text', text}]}
      ]}}));
      return new Response(new ReadableStream({async start(controller) {
        for (const part of parts) {
          // Fragment events, Unicode and CRLF at arbitrary byte boundaries.
          const bytes = Buffer.from(part);
          for (let i = 0; i < bytes.length; i += 7) controller.enqueue(bytes.subarray(i, i + 7));
          await new Promise(resolve => setTimeout(resolve, 80));
        }
        controller.close();
      }}));
    });
    res.writeHead(response.status, Object.fromEntries(response.headers));
    if (response.body) for await (const chunk of response.body) res.write(chunk);
    res.end();
  } catch { res.writeHead(500); res.end(); }
});
server.listen(0, '127.0.0.1', () => process.stdout.write(String(server.address().port) + '\n'));
