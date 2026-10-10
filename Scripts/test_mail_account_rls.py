#!/usr/bin/env python3
"""Run feedback-list permission and schema checks against a local, migrated PostgreSQL database.
Usage: python3 Scripts/test_mail_account_rls.py postgresql://postgres:postgres@127.0.0.1:54322/postgres
Requires psql. Remote hosts are refused; all fixtures are rolled back.
"""
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    database = urlparse(sys.argv[1])
    if (database.scheme not in ('postgres', 'postgresql')
            or database.hostname not in ('127.0.0.1', 'localhost', '::1')
            or database.query or database.fragment):
        raise SystemExit('Use an explicit loopback PostgreSQL URL without connection overrides.')
    psql = shutil.which('psql')
    if not psql:
        raise SystemExit('psql is required to run these local database checks.')
    tests = Path(__file__).resolve().parents[1] / 'supabase/tests'
    sql = '\n'.join((tests / name).read_text() for name in
                    ('feedback_contacts.sql', 'onboarding_contacts.sql', 'yc_company_welcomes.sql'))
    subprocess.run([psql, '-X', '--set=ON_ERROR_STOP=1', '--dbname', sys.argv[1]],
                   input='BEGIN;\n' + sql + '\nROLLBACK;\n', text=True, check=True)


if __name__ == '__main__':
    main()
