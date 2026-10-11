// Runs the real SQL under a rollback, optionally including pending migrations.
// Usage: node Scripts/test_invitation_database.mjs [--isolated | --migration <filename> | --with-migration]
// --isolated uses disposable tables/functions and Auth fixtures in a rolled-back schema.
// --with-migration applies the entire migration chain against an empty schema.
import { readFileSync, readdirSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { parseArgs } from 'node:util';
import { randomUUID } from 'node:crypto';

const root = fileURLToPath(new URL('../', import.meta.url));
const { values } = parseArgs({ options: {
  'with-migration': { type: 'boolean' },
  migration: { type: 'string' },
  isolated: { type: 'boolean' },
} });
if ([values['with-migration'], values.migration, values.isolated].filter(Boolean).length > 1) {
  throw new Error('Choose one migration mode');
}
const directory = mkdtempSync(join(tmpdir(), 'sentient-invite-sql-'));
try {
  const migrationDirectory = join(root, 'supabase/migrations');
  const files = values['with-migration'] || values.isolated
    ? readdirSync(migrationDirectory).filter(name => name.endsWith('.sql')
      && (!values.isolated || /invit(e|ation)/.test(name))).sort()
    : values.migration ? [values.migration] : [];
  const migration = files.map(name => readFileSync(join(migrationDirectory, name), 'utf8')).join('\n');
  const test = readFileSync(join(root, 'supabase/tests/invitation_program.sql'), 'utf8');
  const path = join(directory, 'verify.sql');
  let sql = `${migration}\n${test}`;
  if (values.isolated) {
    const schema = `invite_verify_${randomUUID().replaceAll('-', '')}`;
    sql = sql.replaceAll('public.', `${schema}.`)
      .replaceAll('auth.users', `${schema}.auth_users`)
      .replaceAll("table_schema = 'public'", `table_schema = '${schema}'`);
    sql = `create schema ${schema};
grant usage on schema ${schema} to anon, authenticated;
create table ${schema}.auth_users (id uuid primary key, aud text, role text, is_anonymous boolean);
${sql}`;
  }
  writeFileSync(path, `begin;\nset local statement_timeout = '30s';\nset local lock_timeout = '3s';\n${sql}\nrollback;\n`, { mode: 0o600 });
  const result = spawnSync('supabase', ['db', 'query', '--linked', '--project-ref', 'hjqedlalhfoxwehxhton', '--file', path, '--output', 'json'], { encoding: 'utf8' });
  process.stdout.write(result.stdout ?? '');
  process.stderr.write(result.stderr ?? '');
  process.exitCode = result.status ?? 1;
} finally {
  rmSync(directory, { recursive: true, force: true });
}
