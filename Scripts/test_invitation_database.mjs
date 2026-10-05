// Runs the real SQL under a rollback, optionally including pending migrations.
// Usage: node Scripts/test_invitation_database.mjs [--migration <filename> | --with-migration]
// --with-migration applies the entire migration chain against an empty schema.
import { readFileSync, readdirSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { parseArgs } from 'node:util';

const root = fileURLToPath(new URL('../', import.meta.url));
const { values } = parseArgs({ options: {
  'with-migration': { type: 'boolean' },
  migration: { type: 'string' },
} });
if (values['with-migration'] && values.migration) throw new Error('Choose one migration mode');
const directory = mkdtempSync(join(tmpdir(), 'sentient-invite-sql-'));
try {
  const migrationDirectory = join(root, 'supabase/migrations');
  const files = values['with-migration']
    ? readdirSync(migrationDirectory).filter(name => name.endsWith('.sql')).sort()
    : values.migration ? [values.migration] : [];
  const migration = files.map(name => readFileSync(join(migrationDirectory, name), 'utf8')).join('\n');
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
