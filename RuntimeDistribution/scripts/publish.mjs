// Upload only approved archive bytes. Never upload a directory or a user's live CODEX_HOME.
// Usage: npm run publish:archives -- /absolute/path/to/audited/artifacts
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import release from '../../Sentient OS macOS/Cloud/BundledCodexRelease.json' with { type: 'json' };

if (process.argv.length !== 3) throw new Error('Provide the audited archive directory.');
const directory = resolve(process.argv[2]);
for (const artifact of [release.cli, release.helper]) {
  const file = join(directory, artifact.filename);
  const info = await stat(file);
  if (!info.isFile() || info.size !== artifact.bytes) throw new Error(`Wrong archive size: ${artifact.filename}`);
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  if (hash.digest('hex') !== artifact.sha256) throw new Error(`Archive fingerprint mismatch: ${artifact.filename}`);
}
for (const artifact of [release.cli, release.helper]) {
  const args = ['--no-install', 'wrangler', 'r2', 'object', 'put', `sentient-runtime-releases/releases/${artifact.filename}`,
    '--remote', '--file', join(directory, artifact.filename), '--content-type',
    artifact.filename.endsWith('.zip') ? 'application/zip' : 'application/gzip',
    '--cache-control', 'public, max-age=31536000, immutable'];
  const result = spawnSync('npx', args, { stdio: 'inherit', env: { ...process.env, WRANGLER_SEND_METRICS: 'false' } });
  if (result.status !== 0) process.exit(result.status ?? 1);
}
