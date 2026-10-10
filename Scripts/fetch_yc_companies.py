#!/usr/bin/env python3
"""Fetch the YC company inventory and websites through the authenticated YC CLI.

Writes a private JSON snapshot outside this repository. No Supabase writes, contacts,
or guessed email addresses. Batches are paged independently to avoid search-result caps.
Successful batch checkpoints allow interrupted imports to resume in the same directory.
"""
import argparse
import csv
import io
import json
import os
from pathlib import Path
import re
import subprocess
import time
from datetime import datetime, timezone

STATUSES = ['Active', 'Inactive', 'Acquired', 'Public']
FIELDS = ('website,long_description,small_logo_thumb_url,industry,subindustry,tags,visibility,'
          'active_founders.user_id,inactive_founders.user_id')


def save_json(path, data):
    temporary = path.with_suffix(path.suffix + '.tmp')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2)
    temporary.chmod(0o600)
    temporary.replace(path)


def call(arguments):
    for attempt in range(5):
        result = subprocess.run(['yc', 'tools', 'run', 'search.companies', '--input',
                                 json.dumps(arguments), '--json'], capture_output=True, text=True)
        if result.returncode:
            if 'rate_limited' in result.stderr or '429' in result.stderr:
                delay = re.search(r'"retry_after"\s*:\s*"?(\d+)', result.stderr)
                seconds = max(1, int(delay.group(1))) if delay else 60
                print(f'YC rate limit: waiting {seconds} seconds before retry.', flush=True)
                time.sleep(seconds)
                continue
            raise RuntimeError('YC CLI request failed; no catalog was completed.')
        response = json.loads(result.stdout)['result']
        if response.get('status') != 'success':
            raise RuntimeError('YC CLI returned an unsuccessful result.')
        return response
    raise RuntimeError('YC CLI retry limit reached; resume from saved batch checkpoints.')


def list_field(value):
    if not value:
        return []
    return [part.strip().strip('"') for part in next(csv.reader([value], skipinitialspace=True))
            if part.strip().strip('"')]


def website_field(value):
    value = (value or '').strip()
    # The CLI CSV serializer prefixes URLs with an Excel-safe apostrophe.
    if value.startswith("'"):
        value = value[1:]
    return value or None


def normalize(row):
    identifier = row.get('id', '')
    if not identifier.isdigit() or row.get('status') not in STATUSES:
        raise ValueError('Unexpected company ID or non-YC status.')
    active = list_field(row.get('active_founders.user_id', ''))
    inactive = list_field(row.get('inactive_founders.user_id', ''))
    if not all(value.isdigit() for value in active + inactive):
        raise ValueError('Unexpected founder ID format.')
    return {
        'id': identifier, 'name': row['name'].strip(), 'batch': row['batch'],
        'status': row['status'], 'website': website_field(row.get('website')),
        'one_liner': row.get('one_liner', '').strip(),
        'long_description': row.get('long_description', '').strip(),
        'small_logo_thumb_url': website_field(row.get('small_logo_thumb_url')),
        'industry': row.get('industry', ''), 'subindustry': row.get('subindustry', ''),
        'tags': list_field(row.get('tags', '')), 'visibility': row.get('visibility', ''),
        'source_url': 'https://bookface.ycombinator.com/company/' + identifier,
        'active_founder_ids': active, 'inactive_founder_ids': inactive,
    }


def fetch_batch(batch, expected, request=call):
    rows = {}
    for page in range((expected + 199) // 200):
        response = request({'filters': {'status': STATUSES, 'batch': batch},
                            'limit': 200, 'page': page, 'extra_fields': FIELDS})
        if response.get('total_count') != expected:
            raise ValueError('YC batch count changed during import; start a fresh snapshot.')
        page_rows = list(csv.DictReader(io.StringIO(response.get('csv_results', ''))))
        if len(page_rows) != min(200, expected - page * 200):
            raise ValueError('YC returned an incomplete page; refusing a partial catalog.')
        for item in page_rows:
            row = normalize(item)
            if row['batch'] != batch or row['id'] in rows:
                raise ValueError('YC pagination returned duplicate or unexpected records.')
            rows[row['id']] = row
    if len(rows) != expected:
        raise ValueError('YC batch coverage mismatch.')
    return list(rows.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', required=True, type=Path)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    repository = Path(__file__).resolve().parents[1]
    if output == repository or repository in output.parents:
        parser.error('Store real YC data outside the code repository.')
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    checkpoint = output / 'batches'
    checkpoint.mkdir(mode=0o700, exist_ok=True)
    counts = call({'group_counts_by': 'batch', 'filters': {'status': STATUSES}})
    groups = counts['counts']
    if sum(groups.values()) != counts['total'] or not groups:
        raise ValueError('Incomplete YC batch counts.')
    save_json(output / 'batch-counts.json', counts)
    companies = {}
    for batch, count in sorted(groups.items()):
        if not re.fullmatch(r'[A-Za-z0-9]+', batch):
            raise ValueError('Unexpected batch identifier.')
        path = checkpoint / (batch + '.json')
        cached = json.loads(path.read_text()) if path.exists() else None
        if cached and cached.get('batch') == batch and cached.get('count') == count and cached.get('fields') == FIELDS:
            rows = cached['companies']
        else:
            rows = fetch_batch(batch, count)
            save_json(path, {'batch': batch, 'count': count, 'fields': FIELDS, 'companies': rows})
        if len(rows) != count or len({r['id'] for r in rows}) != count:
            raise ValueError('Incomplete cached batch.')
        for row in rows:
            if row['id'] in companies:
                raise ValueError('Company appeared in multiple primary batches.')
            companies[row['id']] = row
        print(f'YC company coverage: {len(companies)}/{counts["total"]} ({batch})', flush=True)
    if len(companies) != counts['total']:
        raise ValueError('Incomplete company inventory.')
    save_json(output / 'cli-companies.json', sorted(companies.values(), key=lambda r: int(r['id'])))
    save_json(output / 'fetch-report.json', {
        'source': 'yc_cli.search.companies', 'fetched_at': datetime.now(timezone.utc).isoformat(),
        'companies': len(companies), 'batches': groups,
        'with_website': sum(bool(c['website']) for c in companies.values()),
    })
    print(f'COMPLETE: {len(companies)} YC companies fetched through the CLI.', flush=True)


if __name__ == '__main__':
    main()
