#!/usr/bin/env python3
"""Validate permitted company/founder data and prepare a reviewable SQL import; never deploy.

Usage: python3 Scripts/prepare_yc_welcomes.py input.json --output /private/path/import.sql
Input: {"reuse_basis":"company_provided|yc_authorized|licensed|synthetic|public_directory_and_yc_cli|yc_cli", "companies":[
  {"source_id":"...", "name":"...", "website":"https://...", "source_url":"https://...",
   "welcome_line":"...", "domains":["company.example"], "logo_path":null,
   "published":false, "founders":[{"source_id":"...", "first_name":"...", "last_name":"...",
   "source_url":"https://..."}]}]}
Publication requires an explicit per-company display_approved=true as well as published=true.
Unpublished reference records may have website=null and domains=[]. source_status is optional.
Omitting founders preserves existing associations; providing a list reconciles current founders.
Existing welcome copy is preserved during catalog refreshes unless --replace-welcome-copy is set.
Source material, generated SQL and real records belong outside the public repository.
"""
import argparse
import json
import os
import re
import unicodedata
from pathlib import Path
from urllib.parse import urlsplit

SHARED = set('gmail.com googlemail.com outlook.com hotmail.com live.com msn.com icloud.com '
             'me.com mac.com yahoo.com ymail.com aol.com proton.me protonmail.com pm.me hey.com '
             'fastmail.com mail.com'.split())
DOMAIN = re.compile(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}')
LOGO = re.compile(r'[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+\.(png|jpg|webp)')


def text(value, maximum, empty=False):
    if (not isinstance(value, str) or len(value) > maximum or (not value and not empty)
            or value != value.strip() or any(unicodedata.category(c) == 'Cc'
                or 0x202a <= ord(c) <= 0x202e or 0x2066 <= ord(c) <= 0x2069 for c in value)):
        raise ValueError('Invalid or oversized text field')
    return value


def https(value):
    text(value, 2048)
    url = urlsplit(value)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or any(c.isspace() for c in value):
        raise ValueError('Source and website URLs must be HTTPS without credentials')
    return value


def quote(value):
    return 'null' if value is None else "'" + value.replace("'", "''") + "'"


def prepare(document, replace_welcome_copy=False):
    if not isinstance(document, dict) or document.get('reuse_basis') not in (
            'company_provided', 'yc_authorized', 'licensed', 'synthetic', 'public_directory_and_yc_cli', 'yc_cli'):
        raise ValueError('Specify the permitted reuse basis for this input')
    companies = document.get('companies')
    if not isinstance(companies, list) or not companies or len(companies) > 20000:
        raise ValueError('Expected a bounded, nonempty company list')
    statements = [f"-- Declared reuse basis: {document['reuse_basis']}", 'begin;',
                  "set local lock_timeout = '5s';", 'set local standard_conforming_strings = on;']
    seen_ids, seen_domains, founder_values = set(), set(), {}
    for company in companies:
        if not isinstance(company, dict):
            raise ValueError('Expected company objects')
        source_id = text(company['source_id'], 100)
        if source_id in seen_ids:
            raise ValueError('Duplicate company source ID')
        seen_ids.add(source_id)
        name = text(company['name'], 100)
        website = https(company['website']) if company.get('website') is not None else None
        source_url = https(company['source_url'])
        status = company.get('source_status')
        if status is not None and status not in ('Active', 'Inactive', 'Acquired', 'Public'):
            raise ValueError('Unrecognized source status')
        line = text(company['welcome_line'], 180)
        logo = company.get('logo_path')
        if logo is not None and not LOGO.fullmatch(text(logo, 180)):
            raise ValueError('Logo must be a curated bucket-relative image path')
        published = company.get('published', False)
        if not isinstance(published, bool) or (published and company.get('display_approved') is not True):
            raise ValueError('Publication requires explicit display approval')
        domains = company['domains']
        if not isinstance(domains, list) or len(domains) > 32 or (published and (not domains or not website)):
            raise ValueError('Published companies require a website and 1–32 reviewed domains')
        for domain in domains:
            text(domain, 253)
            if not DOMAIN.fullmatch(domain) or domain in SHARED or domain in seen_domains:
                raise ValueError('Invalid, shared or ambiguous company domain')
            seen_domains.add(domain)
        company_id = f'(select id from public.yc_companies where source_id={quote(source_id)})'
        statements.append(f'''insert into public.yc_companies
 (source_id,name,website,source_url,welcome_line,logo_path,published,reviewed_at,source_status)
 values ({quote(source_id)},{quote(name)},{quote(website)},{quote(source_url)},{quote(line)},
 {quote(logo)},{str(published).lower()},{'now()' if published else 'null'},{quote(status)})
 on conflict (source_id) do update set name=excluded.name,website=excluded.website,
 source_url=excluded.source_url,{'welcome_line=excluded.welcome_line,' if replace_welcome_copy else ''}logo_path=excluded.logo_path,
 published=excluded.published,reviewed_at=excluded.reviewed_at,source_status=excluded.source_status,retrieved_at=now(),
 content_version=public.yc_companies.content_version+1;''')
        remaining = f" and domain not in ({','.join(map(quote,domains))})" if domains else ''
        statements.append(f'delete from public.yc_company_domains where company_id={company_id}{remaining};')
        for domain in domains:
            statements.append(f'''insert into public.yc_company_domains(domain,company_id,reviewed_at,source_url)
 values ({quote(domain)},{company_id},now(),{quote(source_url)})
 on conflict(domain) do update set reviewed_at=excluded.reviewed_at,source_url=excluded.source_url,
 company_id=case when public.yc_company_domains.company_id=excluded.company_id
 then excluded.company_id else null end;''')  # NOT NULL rejects reassignment atomically.
        founders = company.get('founders', [])
        if not isinstance(founders, list) or len(founders) > 50:
            raise ValueError('Expected a bounded founder list')
        if 'founders' in company:
            statements.append('update public.yc_founder_companies set current_founder=false '
                              f'where company_id={company_id};')
        seen_founders = set()
        for founder in founders:
            if not isinstance(founder, dict):
                raise ValueError('Expected founder objects')
            fid = text(founder['source_id'], 100)
            if fid in seen_founders:
                raise ValueError('Duplicate founder within one company')
            seen_founders.add(fid)
            values = (text(founder['first_name'], 100), text(founder.get('last_name', ''), 100, empty=True),
                      https(founder['source_url']))
            if fid in founder_values and founder_values[fid] != values:
                raise ValueError('Conflicting records for the same founder')
            founder_values[fid] = values
            statements.append(f'''insert into public.yc_founders(source_id,first_name,last_name,source_url)
 values ({quote(fid)},{','.join(map(quote,values))})
 on conflict(source_id) do update set first_name=excluded.first_name,last_name=excluded.last_name,
 source_url=excluded.source_url,retrieved_at=now();''')
            current = founder.get('current_founder', True)
            if not isinstance(current, bool):
                raise ValueError('current_founder must be boolean')
            statements.append(f'''insert into public.yc_founder_companies(founder_id,company_id,current_founder)
 values ((select id from public.yc_founders where source_id={quote(fid)}),{company_id},{str(current).lower()})
 on conflict(founder_id,company_id) do update set current_founder=excluded.current_founder;''')
    statements.append('commit;')
    return '\n\n'.join(statements) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--replace-welcome-copy', action='store_true',
                        help='Explicitly replace existing welcome text as well as catalog metadata')
    args = parser.parse_args()
    try:
        sql = prepare(json.loads(args.input.read_text()), replace_welcome_copy=args.replace_welcome_copy)
    except (ValueError, KeyError) as error:
        parser.error(str(error))
    # Exclusive creation protects an earlier reviewed import; 0600 keeps reference data private.
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        output.write(sql)
    print('Prepared a SQL import for review. No database was contacted.')


if __name__ == '__main__':
    main()
