#!/usr/bin/env python3
"""Offline checks for CLI CSV decoding and complete inventory pagination."""
import csv
import io
import unittest

from fetch_yc_companies import fetch_batch, normalize


def company(identifier):
    return {'id': str(identifier), 'name': 'Example Company', 'batch': 'F26',
            'status': 'Active', 'website': "'https://www.example.test", 'visibility': 'batch',
            'active_founders.user_id': '"123", "456"'}


def result(rows, total):
    stream = io.StringIO()
    writer = csv.DictWriter(stream, fieldnames=company(1).keys())
    writer.writeheader()
    writer.writerows(rows)
    return {'total_count': total, 'csv_results': stream.getvalue()}


class FetchChecks(unittest.TestCase):
    def test_cli_website_and_batch_only_companies_are_retained(self):
        row = normalize(company(1))
        self.assertEqual(row['website'], 'https://www.example.test')
        self.assertEqual(row['visibility'], 'batch')
        self.assertEqual(row['active_founder_ids'], ['123', '456'])
        self.assertEqual(row['inactive_founder_ids'], [])
        raw = company(2)
        raw['website'] = ''
        self.assertIsNone(normalize(raw)['website'])

    def test_second_page_is_required(self):
        calls = []
        def request(args):
            calls.append(args)
            start = args['page'] * 200
            return result([company(i) for i in range(start, min(201, start + 200))], 201)
        rows = fetch_batch('F26', 201, request)
        self.assertEqual(len(rows), 201)
        self.assertEqual([a['page'] for a in calls], [0, 1])
        self.assertTrue(all('website' in a['extra_fields'] for a in calls))
        self.assertTrue(all('long_description' in a['extra_fields'] for a in calls))

    def test_company_pitch_and_multiline_description_survive(self):
        row = company(1)
        row['one_liner'] = '  Software for field teams  '
        row['long_description'] = 'First paragraph.\r\n\r\nA second paragraph, with commas.'
        normalized = normalize(row)
        self.assertEqual(normalized['one_liner'], 'Software for field teams')
        self.assertEqual(normalized['long_description'], row['long_description'])
        self.assertEqual(normalize(company(2))['long_description'], '')

    def test_partial_duplicate_or_changed_pages_abort(self):
        for response in (result([company(1)], 2), result([company(1), company(1)], 2),
                         result([company(1), company(2)], 3)):
            with self.subTest(response=response), self.assertRaises(ValueError):
                fetch_batch('F26', 2, lambda _: response)

    def test_unrelated_records_are_rejected(self):
        for field, value in [('status', 'Not YC'), ('id', '../123'),
                             ('active_founders.user_id', 'not-an-id')]:
            row = company(1)
            row[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                normalize(row)


if __name__ == '__main__':
    unittest.main()
