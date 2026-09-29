// Runs the real SQL under a rollback, optionally including the unapplied migration.
// Usage: node Scripts/test_invitation_database.mjs [--with-migration]
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const directory = mkdtempSync(join(tmpdir(), 'sentient-invite-sql-'));
try {
  const migration = process.argv.includes('--with-migration')
    ? readFileSync(join(root, 'supabase/migrations/20260929120000_invitation_program.sql'), 'utf8') : '';
  const test = readFileSync(join(root, 'supabase/tests/invitation_program.sql'), 'utf8');
  const path = join(directory, 'verify.sql');
  writeFileSync(path, `begin;\n${migration}\n${test}\nrollback;\n`, { mode: 0o600 });
  const result = spawnSync('supabase', ['db', 'query', '--linked', '--project-ref', 'hjqedlalhfoxwehxhton', '--file', path, '--output', 'json'], { encoding: 'utf8' });
  process.stdout.write(result.stdout ?? '');
  process.stderr.write(result.stderr ?? '');
  process.exitCode = result.status ?? 1;
} finally {
  rmSync(directory, { recursive: true, force: true });
}
