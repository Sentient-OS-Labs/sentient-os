// Read-only delivery of the exact archives approved by the signed macOS app.
// No account tokens, uploads, directory listings or inference requests enter this service.
import approved from '../../Sentient OS macOS/Cloud/BundledCodexRelease.json' with { type: 'json' };

const artifacts = new Map([approved.cli, approved.helper].map(a => [`/releases/${a.filename}`, a]));
export const release = approved;

export function byteRange(value, size) {
  const match = /^bytes=(\d*)-(\d*)$/.exec(value);
  if (!match || (!match[1] && !match[2])) return null;
  let start, end;
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return null;
    start = Math.max(0, size - suffix); end = size - 1;
  } else {
    start = Number(match[1]); end = match[2] ? Number(match[2]) : size - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= size || end < start) return null;
    end = Math.min(end, size - 1);
  }
  return { offset: start, length: end - start + 1 };
}

const error = (status, message, extra = {}) => new Response(message, {
  status, headers: { 'Cache-Control': 'no-store', 'Content-Type': 'text/plain', ...extra },
});

export default {
  async fetch(request, env) {
    if (!['GET', 'HEAD'].includes(request.method)) return error(405, 'Method not allowed', { Allow: 'GET, HEAD' });
    const path = new URL(request.url).pathname;
    if (path === '/health') return new Response(request.method === 'HEAD' ? null : 'ok', { headers: { 'Cache-Control': 'no-store' } });
    if (path === '/releases/manifest.json') {
      const manifest = { target: approved.target, cli: publicArtifact(approved.cli), helper: publicArtifact(approved.helper) };
      return new Response(request.method === 'HEAD' ? null : JSON.stringify(manifest), {
        headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' },
      });
    }
    const artifact = artifacts.get(path);
    if (!artifact) return error(404, 'Release not found');
    const key = path.slice(1);
    try {
      const metadata = await env.RELEASES.head(key);
      if (!metadata || metadata.size !== artifact.bytes) return error(503, 'Release unavailable', { 'Retry-After': '60' });
      const etag = `"sha256-${artifact.sha256}"`;
      const headers = new Headers({
        'Content-Type': artifact.filename.endsWith('.zip') ? 'application/zip' : 'application/gzip',
        'Content-Disposition': `attachment; filename="${artifact.filename}"`,
        'Cache-Control': 'public, max-age=31536000, immutable',
        'X-Content-Type-Options': 'nosniff',
        'Accept-Ranges': 'bytes', ETag: etag,
        'Last-Modified': metadata.uploaded.toUTCString(),
      });
      const matches = request.headers.get('If-None-Match')?.split(',').some(v => v.trim().replace(/^W\//, '') === etag || v.trim() === '*');
      if (matches) return new Response(null, { status: 304, headers });
      if (request.method === 'HEAD') {
        headers.set('Content-Length', String(metadata.size));
        return new Response(null, { headers });
      }
      let range;
      const requestedRange = request.headers.get('Range');
      const ifRange = request.headers.get('If-Range');
      const allowRange = !ifRange || ifRange === etag || (!ifRange.startsWith('"') && !ifRange.startsWith('W/')
        && Number.isFinite(Date.parse(ifRange)) && Math.floor(metadata.uploaded.getTime() / 1000) <= Math.floor(Date.parse(ifRange) / 1000));
      if (requestedRange && allowRange) {
        range = byteRange(requestedRange, metadata.size);
        if (!range) return error(416, 'Range not satisfiable', { 'Content-Range': `bytes */${metadata.size}` });
      }
      const object = await env.RELEASES.get(key, { onlyIf: { etagMatches: metadata.etag }, ...(range ? { range } : {}) });
      if (!object || !('body' in object)) return error(503, 'Release changed; retry', { 'Retry-After': '60' });
      headers.set('Content-Length', String(range ? range.length : metadata.size));
      if (range) headers.set('Content-Range', `bytes ${range.offset}-${range.offset + range.length - 1}/${metadata.size}`);
      return new Response(object.body, { status: range ? 206 : 200, headers });
    } catch {
      return error(503, 'Release temporarily unavailable', { 'Retry-After': '60' });
    }
  },
};

function publicArtifact({ version, filename, bytes, sha256 }) {
  return { version, path: `/releases/${filename}`, bytes, sha256 };
}
