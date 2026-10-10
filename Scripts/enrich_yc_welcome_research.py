#!/usr/bin/env python3
"""Retry sparse company evidence using the YC CLI's public search index.

Only the company's own domain and an exactly named YC company profile are accepted.
Search excerpts remain labeled as excerpts. No contacts, images, or credentials are retained.
Run before generating that company's copy; changed evidence invalidates an earlier approval.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit

from fetch_yc_companies import save_json
from research_yc_welcomes import source_hash


def search_source_matches(result, company):
    parsed = urlsplit(result.get('url', ''))
    host = (parsed.hostname or '').lower().removeprefix('www.')
    domain = (urlsplit(company['website']).hostname or '').lower().removeprefix('www.')
    if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.port not in (None, 443):
        return False
    if domain and (host == domain or host.endswith('.' + domain)):
        return not re.search(r'/(privacy|terms|legal|login|signup|careers|jobs)(/|$)', parsed.path)
    if host != 'ycombinator.com' or not re.fullmatch(r'/companies/[^/]+/?', parsed.path):
        return False
    title = re.sub(r'\s+', ' ', result.get('title', '')).strip()
    name = re.sub(r'\s+', ' ', company['name']).strip()
    return title.casefold().startswith(name.casefold() + ':')


def enrich(path, cache_dir):
    record = json.loads(path.read_text())
    company = record['company']
    domain = urlsplit(company['website']).hostname.removeprefix('www.')
    query = {'query':f'"{company["name"]}" {domain} company product',
             'include_domains':domain + ',ycombinator.com', 'num_results':6}
    key = hashlib.sha256(json.dumps(query, sort_keys=True).encode()).hexdigest()
    cache = cache_dir / (company['source_id'] + '-' + key + '.json')
    if cache.exists():
        results = json.loads(cache.read_text())
    else:
        process = subprocess.run(['yc', 'tools', 'run', 'web.search', '--input', json.dumps(query), '--json'],
                                 text=True, capture_output=True, timeout=100)
        if process.returncode:
            raise RuntimeError('YC public search failed')
        outer = json.loads(process.stdout)
        results = [{k:r.get(k, '') for k in ('url','title','highlights')}
                   for r in outer.get('result', {}).get('results', [])]
        save_json(cache, results)
    # Recheck cached excerpts too: a namesake or unrelated YC article is not evidence.
    pages = [p for p in record['pages'] if p.get('kind') != 'search_index_excerpt']
    seen = {p['url'] for p in pages}
    added = 0
    for result in results:
        if added == 3:
            break
        if not search_source_matches(result, company) or result['url'] in seen:
            continue
        highlights = result['highlights']
        if isinstance(highlights, list):
            highlights = '\n'.join(str(x) for x in highlights)
        text = (str(result['title']) + '\n' + str(highlights)).strip()[:9000]
        if len(text) < 80:
            continue
        pages.append({'url':result['url'], 'title':result['title'], 'text':text,
                      'status':'ok', 'kind':'search_index_excerpt'})
        seen.add(result['url'])
        added += 1
    record.update(pages=pages, search_enriched=True, search_researched_at=datetime.now(timezone.utc).isoformat())
    record['source_hash'] = source_hash(record)
    save_json(path, record)
    return {'source_id':company['source_id'], 'search_pages':added}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--research-dir', type=Path, required=True)
    parser.add_argument('--ids', required=True, help='Comma-separated source IDs requiring more evidence')
    args = parser.parse_args()
    root = args.research_dir.resolve()
    repo = Path(__file__).resolve().parents[1]
    if root == repo or repo in root.parents:
        parser.error('Keep company evidence outside the repository')
    cache = root/'search-cache'
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    ids = set(args.ids.split(','))
    if any(not re.fullmatch(r'yc-company-\d+', i) for i in ids):
        parser.error('Invalid company source ID')
    paths = [root/'companies'/(i + '.json') for i in sorted(ids)]
    if any(not p.exists() for p in paths):
        parser.error('Requested research record is missing')
    results=[]
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures={pool.submit(enrich, path, cache):path.stem for path in paths}
        for future in as_completed(futures):
            try:
                result=future.result()
            except Exception as error:
                result={'source_id':futures[future], 'error':type(error).__name__}
            results.append(result)
            print(json.dumps(result), flush=True)
    save_json(root/'search-retry-report.json', results)


if __name__ == '__main__':
    main()
