#!/usr/bin/env python3
"""Collect bounded company website evidence for the enabled YC welcome catalog.

Real records and checkpoints must stay outside the repository. This performs public HTTPS
GETs only, honors robots.txt, pins connections to public IPs, and never writes to Supabase.
Usage: python3 Scripts/research_yc_welcomes.py --catalog /private/catalog.json \
  --companies /private/cli-companies.json --output-dir /private/research
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
from html.parser import HTMLParser
import http.client
import ipaddress
import json
import re
import socket
import ssl
import time
from urllib.parse import urljoin, urlsplit, urlunsplit
from urllib.robotparser import RobotFileParser
import zlib

from fetch_yc_companies import save_json
from pathlib import Path

AGENT = 'SentientCompanyResearch/1.0'
MAX_BYTES = 1_500_000
MAX_TEXT = 9_000
SKIP = {'script', 'style', 'noscript', 'svg', 'nav', 'footer', 'form', 'button'}
PARKED = ('this domain is for sale', 'buy this domain', 'domain is parked',
          'the domain is available for purchase', 'verify you are human',
          'just a moment...', 'enable javascript and cookies to continue')


def clean(value):
    return re.sub(r'\s+', ' ', value or '').strip()


def source_hash(record):
    return hashlib.sha256(json.dumps({'company':record['company'], 'pages':record['pages']},
                                     sort_keys=True).encode()).hexdigest()


def canonical(url):
    parsed = urlsplit(url)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
            or parsed.port not in (None, 443)):
        raise ValueError('Only credential-free HTTPS company URLs are allowed')
    host = parsed.hostname.encode('idna').decode('ascii').lower()
    return urlunsplit(('https', host, parsed.path or '/', parsed.query, ''))


class PublicHTTPSConnection(http.client.HTTPSConnection):
    def connect(self):
        records = socket.getaddrinfo(self.host, self.port, type=socket.SOCK_STREAM)
        if not records or any(not ipaddress.ip_address(r[4][0]).is_global for r in records):
            raise ValueError('Non-public network destination')
        error = None
        for _, _, _, _, address in records[:2]:
            try:
                raw = socket.create_connection((address[0], self.port), timeout=self.timeout)
                try:
                    self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
                except Exception:
                    raw.close()
                    raise
                return
            except OSError as exc:
                error = exc
        raise error or OSError('No reachable public address')


def get(url, redirects=4):
    for attempt in range(redirects + 1):
        url = canonical(url)
        parsed = urlsplit(url)
        connection = PublicHTTPSConnection(parsed.hostname, timeout=7,
                                          context=ssl.create_default_context())
        try:
            connection.request('GET', urlunsplit(('', '', parsed.path, parsed.query, '')),
                               headers={'User-Agent': AGENT, 'Accept': 'text/html,text/plain',
                                        'Accept-Encoding': 'identity'})
            response = connection.getresponse()
            if response.status in (301, 302, 303, 307, 308):
                if attempt == redirects or not response.getheader('Location'):
                    raise ValueError('Invalid or excessive redirects')
                url = urljoin(url, response.getheader('Location'))
                continue
            status = response.status
            if status >= 400:
                return {'url': url, 'status': status, 'text': '', 'content_type': ''}
            declared = response.getheader('Content-Length')
            if declared and int(declared) > MAX_BYTES:
                raise ValueError('Oversized response')
            deadline = time.monotonic() + 12
            chunks = []
            size = 0
            while size <= MAX_BYTES:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError('Response deadline exceeded')
                if connection.sock:
                    connection.sock.settimeout(min(7, remaining))
                chunk = response.read1(min(65536, MAX_BYTES + 1 - size))
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
            body = b''.join(chunks)
            if len(body) > MAX_BYTES:
                raise ValueError('Oversized response')
            encoding = response.getheader('Content-Encoding', '').lower()
            if encoding in ('gzip', 'deflate'):
                decoder = zlib.decompressobj(31 if encoding == 'gzip' else 15)
                body = decoder.decompress(body, MAX_BYTES + 1)
                if len(body) > MAX_BYTES or decoder.unconsumed_tail:
                    raise ValueError('Oversized decompressed response')
            elif encoding not in ('', 'identity'):
                raise ValueError('Unsupported response encoding')
            kind = response.getheader('Content-Type', '').lower()
            if kind and not any(t in kind for t in ('text/', 'application/xhtml')):
                raise ValueError('Non-text response')
            charset = re.search(r'charset=["\']?([\w-]+)', kind)
            text = body.decode(charset.group(1) if charset else 'utf-8', errors='replace')
            return {'url': url, 'status': status, 'text': text, 'content_type': kind}
        finally:
            connection.close()
    raise ValueError('Redirect limit')


class CompanyHTML(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.hidden = []
        self.in_title = False
        self.title = []
        self.description = ''
        self.parts = []
        self.links = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag in SKIP:
            self.hidden.append(tag)
        if self.hidden:
            return
        if tag == 'title':
            self.in_title = True
        if tag == 'meta' and values.get('name', values.get('property', '')).lower() in ('description', 'og:description'):
            self.description = clean(values.get('content', ''))[:1500]
        if tag == 'a' and values.get('href'):
            self.links.append(values['href'])
        if tag in ('p', 'div', 'br', 'h1', 'h2', 'h3', 'li', 'section'):
            self.parts.append('\n')

    def handle_endtag(self, tag):
        if tag in self.hidden:
            del self.hidden[self.hidden.index(tag):]
        if tag == 'title':
            self.in_title = False

    def handle_data(self, data):
        if self.hidden:
            return
        if self.in_title:
            self.title.append(data)
        self.parts.append(' ' + data)

    def document(self, url):
        lines = list(dict.fromkeys(clean(x) for x in ''.join(self.parts).splitlines() if clean(x)))
        title = clean(' '.join(self.title))[:300]
        body = '\n'.join(lines)
        text = '\n'.join(x for x in [title, self.description, body] if x)[:MAX_TEXT]
        blocked = any(phrase in text.lower()[:2000] for phrase in PARKED)
        return {'url': url, 'title': title, 'text': '' if blocked else text,
                'status': 'unusable' if blocked or len(text) < 80 else 'ok'}


def relevant_links(base, links):
    base_host = urlsplit(base).hostname.removeprefix('www.')
    candidates = []
    for link in links:
        try:
            url = canonical(urljoin(base, link))
            p = urlsplit(url)
            if p.hostname.removeprefix('www.') != base_host or p.query or url == canonical(base):
                continue
            if re.search(r'/(login|sign-in|signup|privacy|terms|legal|careers|jobs|contact|pricing)(/|$)', p.path, re.I):
                continue
            match = re.search(r'/(product|platform|solutions|use-cases|customers|about)(/|$)', p.path, re.I)
            if match and not re.search(r'\.(pdf|png|jpg|zip)$', p.path, re.I):
                candidates.append((len(p.path.split('/')), url))
        except (ValueError, UnicodeError):
            continue
    return list(dict.fromkeys(url for _, url in sorted(candidates)))[:2]


def research(company, cli, output, max_pages=2, retry=False):
    identity = company['source_id']
    if not re.fullmatch(r'yc-company-\d+', identity):
        raise ValueError('Invalid company source ID')
    profile = {k: cli.get(k, '') for k in ('id', 'name', 'batch', 'one_liner', 'long_description',
                                          'industry', 'subindustry', 'tags', 'visibility', 'source_url')}
    profile.update(source_id=identity, website=company['website'], domains=company['domains'])
    fingerprint = hashlib.sha256(json.dumps(profile, sort_keys=True).encode()).hexdigest()
    path = output / 'companies' / (identity + '.json')
    if path.exists():
        previous = json.loads(path.read_text())
        if previous.get('profile_hash') == fingerprint and not retry:
            return previous['website_status']
    pages = []
    errors = []
    status = 'unavailable'
    try:
        home = canonical(company['website'])
        root = urlsplit(home)
        robots_url = urlunsplit((root.scheme, root.netloc, '/robots.txt', '', ''))
        robots_response = get(robots_url)
        robots = RobotFileParser(robots_url)
        if robots_response['status'] in (401, 403, 429) or robots_response['status'] >= 500:
            raise ValueError('Robots temporarily unavailable or restricted')
        robots.parse(robots_response['text'].splitlines() if robots_response['status'] < 400 else [])
        if not robots.can_fetch(AGENT, home):
            raise ValueError('Robots disallows company page')
        delay = robots.crawl_delay(AGENT) or 0
        if delay > 30:
            raise ValueError('Robots crawl delay exceeds research time budget')
        if delay:
            time.sleep(delay)
        response = get(home)
        if response['status'] >= 400:
            raise ValueError('Homepage HTTP ' + str(response['status']))
        parser = CompanyHTML()
        parser.feed(response['text'])
        document = parser.document(response['url'])
        if document['status'] == 'ok':
            pages.append(document)
            status = 'ok'
            links = relevant_links(response['url'], parser.links)
            # Rich homepages already explain the product; extra pages are for sparse ones.
            if len(document['text']) < 1800:
                for url in links[:max_pages - 1]:
                    if not robots.can_fetch(AGENT, url):
                        continue
                    delay = robots.crawl_delay(AGENT)
                    time.sleep(min(max(delay or 0.3, 0.3), 60))
                    try:
                        extra = get(url)
                        if extra['status'] < 400:
                            parser = CompanyHTML()
                            parser.feed(extra['text'])
                            doc = parser.document(extra['url'])
                            if doc['status'] == 'ok':
                                pages.append(doc)
                    except (OSError, ValueError, http.client.HTTPException) as exc:
                        errors.append(type(exc).__name__)
        else:
            status = 'unusable'
    except (OSError, ValueError, http.client.HTTPException, UnicodeError) as exc:
        errors.append(str(exc)[:180])
    result = {'company': profile, 'profile_hash': fingerprint, 'website_status': status,
              'pages': pages, 'errors': errors,
              'researched_at': datetime.now(timezone.utc).isoformat()}
    result['source_hash'] = source_hash(result)
    save_json(path, result)
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path, required=True)
    parser.add_argument('--companies', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--workers', type=int, default=12)
    parser.add_argument('--limit', type=int)
    parser.add_argument('--retry-unavailable', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    output = args.output_dir.resolve()
    if output == repo or repo in output.parents:
        parser.error('Keep company research outside the repository')
    if not 1 <= args.workers <= 24:
        parser.error('Use 1–24 bounded website workers')
    (output / 'companies').mkdir(parents=True, exist_ok=True, mode=0o700)
    catalog = [c for c in json.loads(args.catalog.read_text())['companies'] if c['published']]
    cli = {c['id']: c for c in json.loads(args.companies.read_text())}
    if any(c['source_id'].removeprefix('yc-company-') not in cli for c in catalog):
        parser.error('CLI export does not cover all enabled companies')
    catalog.sort(key=lambda c: (cli[c['source_id'].removeprefix('yc-company-')]['batch'] != 'F26', c['source_id']))
    catalog = catalog[:args.limit] if args.limit else catalog
    counts = {}
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(research, c, cli[c['source_id'].removeprefix('yc-company-')], output,
                               retry=args.retry_unavailable and (output / 'companies' / (c['source_id'] + '.json')).exists()
                               and json.loads((output / 'companies' / (c['source_id'] + '.json')).read_text()).get('website_status') != 'ok')
                   for c in catalog]
        for index, future in enumerate(as_completed(futures), 1):
            status = future.result()
            counts[status] = counts.get(status, 0) + 1
            if index % 25 == 0 or index == len(catalog):
                report = {'completed': index, 'target': len(catalog), 'website_status': counts,
                          'updated_at': datetime.now(timezone.utc).isoformat()}
                save_json(output / 'website-report.json', report)
                print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
