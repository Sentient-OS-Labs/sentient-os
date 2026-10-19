#!/usr/bin/env python3
"""Run real SQL in an isolated, rolled-back schema. Never applies a production migration."""
from pathlib import Path
import re
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
schema = 'computer_check_verify_' + uuid.uuid4().hex
migration = (root / 'supabase/migrations/20261019010000_computer_use_support_reports.sql').read_text()
migration = re.sub(r'(?m)^(begin|commit);\s*$', '', migration)
tests = (root / 'supabase/tests/computer_use_support_reports.sql').read_text()
sql = (migration + '\n' + tests).replace('public.', schema + '.').replace('auth.users', schema + '.auth_users')
sql = f'''begin;
set local statement_timeout = '30s';
set local lock_timeout = '3s';
create schema {schema};
grant usage on schema {schema} to anon, authenticated;
create table {schema}.auth_users(id uuid primary key);
{sql}
rollback;
'''
with tempfile.TemporaryDirectory(prefix='sentient-support-sql-') as directory:
    path = Path(directory) / 'verify.sql'
    path.write_text(sql); path.chmod(0o600)
    subprocess.run(['supabase', 'db', 'query', '--linked', '--project-ref', 'hjqedlalhfoxwehxhton',
                    '--file', str(path), '--output', 'json'], check=True, timeout=50)
