#!/usr/bin/env python3
"""Verify support-report SQL in a rolled-back schema on an explicit local Supabase database.

Requires psql and --db-url postgresql://...@127.0.0.1:54322/postgres.
Hosted database URLs are rejected; this runner never applies a production migration.
"""
from pathlib import Path
import argparse
import re
import subprocess
import tempfile
import uuid
from urllib.parse import urlsplit

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--db-url", required=True, help="Local Supabase PostgreSQL URL")
args = parser.parse_args()
parsed = urlsplit(args.db_url)
if parsed.scheme not in {"postgres", "postgresql"} or parsed.hostname not in {"localhost", "127.0.0.1", "::1"} or parsed.query or parsed.fragment:
    parser.error("--db-url must use a loopback host without URL query parameters or fragments")

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
    subprocess.run(['psql', '--no-psqlrc', '--set=ON_ERROR_STOP=1', '--dbname', args.db_url,
                    '--file', str(path)], check=True, timeout=50)
