#!/usr/bin/env python3
"""Offline import checks. All records are fictional; no database or directory is contacted."""
import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from prepare_yc_welcomes import prepare


def fixture():
    return {'reuse_basis': 'synthetic', 'companies': [{
        'source_id': 'test-acme', 'name': 'Acme', 'website': 'https://acme.example',
        'source_url': 'https://directory.example/acme', 'welcome_line': 'Keep customer follow-ups moving.',
        'domains': ['acme.example'], 'published': True, 'display_approved': True,
        'founders': [{'source_id': 'test-founder', 'first_name': 'Maya', 'last_name': "O’Connor",
                      'source_url': 'https://directory.example/maya'}],
    }]}


class ImportChecks(unittest.TestCase):
    def test_missing_website_is_retained_only_as_an_unpublished_reference(self):
        data = fixture()
        company = data['companies'][0]
        company.update(website=None, domains=[], published=False, source_status='Inactive')
        sql = prepare(data)
        self.assertNotIn('not in ()', sql)
        self.assertIn("'Inactive'", sql)
        company['published'] = True
        with self.assertRaises(ValueError):
            prepare(data)

    def test_refuses_unreviewed_publishing_and_ambiguous_domains(self):
        cases = []
        for field, value in [('display_approved', False), ('published', 'true'),
                             ('domains', ['gmail.com']), ('domains', ['Acme.example']),
                             ('domains', ['acme.example', 'acme.example']),
                             ('domains', ['acme.example.evil/redirect']),
                             ('logo_path', '../secret.png'), ('website', 'https://user:pass@acme.example'),
                             ('name', 'Acme\u202e'), ('welcome_line', 'x' * 181)]:
            bad = fixture()
            bad['companies'][0][field] = value
            cases.append(bad)
        bad = fixture()
        second = copy.deepcopy(bad['companies'][0])
        second['source_id'] = 'different-company'
        bad['companies'].append(second)
        cases.extend([bad, [], {'companies': []}, {'reuse_basis': 'synthetic', 'companies': [42]}])
        for bad in cases:
            with self.subTest(document=bad), self.assertRaises(ValueError):
                prepare(bad)

    def test_founder_conflicts_and_explicit_reconciliation(self):
        data = fixture()
        statement = 'update public.yc_founder_companies set current_founder=false'
        self.assertIn(statement, prepare(data))
        data['companies'][0].pop('founders')
        self.assertNotIn(statement, prepare(data))
        data = fixture()
        data['companies'][0]['founders'] *= 2
        with self.assertRaises(ValueError):
            prepare(data)

    def test_quotes_are_data_and_drafts_stay_unpublished(self):
        data = fixture()
        data['companies'][0]['name'] = "O'Connor\\Acme"
        data['companies'][0]['published'] = False
        sql = prepare(data)
        self.assertIn("'O''Connor\\Acme'", sql)
        self.assertIn('standard_conforming_strings = on', sql)
        self.assertIn('null,false,null', sql)
        self.assertTrue(sql.endswith('commit;\n'))
        self.assertNotIn('onboarding_contact_emails', sql)
        self.assertNotIn('auth.users', sql)

    def test_cli_writes_private_file_without_overwriting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            input_file, output_file = root / 'input.json', root / 'import.sql'
            input_file.write_text(json.dumps(fixture()))
            command = [sys.executable, str(Path(__file__).with_name('prepare_yc_welcomes.py')),
                       str(input_file), '--output', str(output_file)]
            first = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(os.stat(output_file).st_mode & 0o777, 0o600)
            before = output_file.read_bytes()
            second = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(second.returncode, 0)
            self.assertEqual(output_file.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
