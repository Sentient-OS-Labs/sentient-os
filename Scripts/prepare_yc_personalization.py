#!/usr/bin/env python3
"""Prepare a searchable local copy review and guarded SQL; never deploy.

The baseline is the existing private catalog. Every approved line is revalidated against its
research, prompt version and review before inclusion. SQL updates welcome text/version only,
and aborts if the published baseline changed. Research and company data remain outside git.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
from pathlib import Path

from fetch_yc_companies import save_json
from personalize_yc_welcomes import CHECKS, VERSION, SUPPORTED_VERSIONS, evidence_error, line_error, profile, welcome_line
from prepare_yc_welcomes import quote
from research_yc_welcomes import source_hash


def prepare(catalog, research, copies):
    target = {c['source_id']: c for c in catalog['companies'] if c['published']}
    approved, pending = [], []
    for identity, company in target.items():
        evidence = research.get(identity)
        item = copies.get(identity)
        reason = None
        if not evidence:
            reason = 'research_missing'
        elif not item:
            reason = 'copy_pending'
        elif (item.get('source_hash') != source_hash(evidence)
              or evidence.get('source_hash') != source_hash(evidence)
              or item.get('prompt_version') not in SUPPORTED_VERSIONS):
            reason = 'stale_research_or_prompt'
        elif (item.get('source_id') != identity
              or ' '.join(item.get('name', '').split()) != ' '.join(company['name'].split())):
            reason = 'company_identity_changed'
        elif set(item.get('checks', {})) != CHECKS or not all(v is True for v in item['checks'].values()):
            reason = 'review_incomplete'
        else:
            reason = line_error(item.get('welcome_line')) or evidence_error(item.get('evidence'), profile(evidence)['sources'])
        if reason:
            pending.append({'source_id':identity, 'name':company['name'], 'reason':reason})
        else:
            # YC descriptions can use nonbreaking spaces; SQL must guard the exact live name.
            approved.append({**item, 'name':company['name'], 'website':company['website'], 'domains':company['domains'],
                             'previous_line':company['welcome_line']})
    # Short outcomes may legitimately repeat. Each company still needs its own evidence/review.
    return approved, pending


def sql_packet(items):
    if not items:
        return '-- No approved changes. Nothing to publish.\n'
    tuples = ',\n'.join('(' + ','.join(quote(i[k]) for k in ('source_id','name','website','previous_line','welcome_line')) + ')'
                       for i in items)
    return f'''-- Prepared for explicit publication approval. Company text only; no contacts or mappings.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';
set local standard_conforming_strings = on;
create temporary table welcome_copy_updates (
 source_id text primary key, expected_name text not null, expected_website text not null, expected_line text not null,
 new_line text not null check (length(new_line) between 20 and 180)
) on commit drop;
insert into welcome_copy_updates values
{tuples};
-- Lock the exact target rows before testing for a stale baseline.
select c.id from public.yc_companies c join welcome_copy_updates u using(source_id) for update of c;
do $check$
begin
 if (select count(*) from welcome_copy_updates) <> {len(items)} then
  raise exception 'Personalization packet coverage changed';
 end if;
 if exists (
  select 1 from welcome_copy_updates u left join public.yc_companies c using(source_id)
  where c.id is null or not c.published or c.name is distinct from u.expected_name
     or c.website is distinct from u.expected_website
     or c.welcome_line is distinct from u.expected_line
 ) then
  raise exception 'Company welcome baseline changed; regenerate the publication packet';
 end if;
end
$check$;
update public.yc_companies c
set welcome_line=u.new_line, content_version=c.content_version+1, reviewed_at=now()
from welcome_copy_updates u where c.source_id=u.source_id;
commit;
'''


def unknown_fallback(company, research, issue, draft, reviews):
    """An explicit neutral fallback for a reviewed unknown, never a claim of personalization."""
    if (not issue or issue.get('source_hash') != source_hash(research)
            or issue.get('prompt_version') != VERSION):
        return None
    unknown = (issue.get('phase') == 'write' and draft.get('status') == 'insufficient') or (
        issue.get('phase') == 'review' and reviews and reviews[-1].get('decision') == 'insufficient')
    if not unknown:
        return None
    return {'source_id':company['source_id'], 'name':company['name'],
            'website':company['website'], 'domains':company['domains'],
            'previous_line':company['welcome_line'], 'welcome_line':welcome_line('get things done'),
            'personalization_kind':'generic_fallback', 'evidence':[],
            'company_fact':'Company facts are insufficient or conflicting.',
            'review_reason':'Neutral fallback, not personalized copy. ' + str(issue.get('reason', '')),
            'source_hash':issue['source_hash'], 'prompt_version':VERSION}


def html_review(items, pending):
    # Escape '<' so even malicious source content cannot close this inert JSON script element.
    data = json.dumps(items, ensure_ascii=False).replace('<', '\\u003c')
    return '''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sentient · Company welcome review</title>
<style>
:root{color-scheme:dark;font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#08090b;color:#eee}
body{max-width:1150px;margin:64px auto;padding:0 28px}h1{font-size:34px;font-weight:500;margin:0 0 14px}
p,.meta{color:#9498a4;line-height:1.6}.label{font:11px ui-monospace,monospace;letter-spacing:2px;color:#a4adc8}
input{box-sizing:border-box;width:100%;background:#12151b;color:white;border:1px solid #303540;border-radius:12px;padding:15px 18px;font:inherit;margin:20px 0}
article{border:1px solid #252932;background:#101217;border-radius:16px;padding:24px;margin:16px 0}
h2{font-size:20px;font-weight:500;margin:0}.line{font-size:21px;line-height:1.5;margin:18px 0 22px;color:#fafafa}
details{color:#a0a5b1;font-size:13px}summary{cursor:pointer}a{color:#a4bdf8;text-decoration:none;margin-right:16px}
blockquote{border-left:2px solid #46516b;padding-left:14px;margin-left:0}.old{color:#737b8d}
button{background:#eceef3;color:#121319;border:0;border-radius:20px;padding:10px 18px;font:inherit;cursor:pointer;margin:16px 0}
</style><body><div class="label">SENTIENT OS · PRIVATE COPY REVIEW</div>
<h1>A welcome that knows what they’re building.</h1>
<p>''' + str(len(items)) + ' staged welcomes · ' + str(len(pending)) + ''' pending personalization. These lines have not been published. Neutral fallbacks are marked in their review evidence.</p>
<input id="search" aria-label="Search companies or copy" placeholder="Search company, domain, or welcome line…">
<div class="meta" id="count"></div><main id="cards"></main><button id="more">Show more</button>
<script type="application/json" id="data">''' + data + '''</script>
<script>
const data=JSON.parse(document.getElementById('data').textContent);let limit=40;
const search=document.getElementById('search'),cards=document.getElementById('cards');
function add(tag,text,parent,cls){const el=document.createElement(tag);el.textContent=text;if(cls)el.className=cls;parent.appendChild(el);return el}
function render(){const q=search.value.toLowerCase();const rows=data.filter(x=>[x.name,x.website,x.welcome_line].join(' ').toLowerCase().includes(q));cards.replaceChildren();
document.getElementById('count').textContent=rows.length+' companies';
for(const row of rows.slice(0,limit)){const card=add('article','',cards);add('h2',row.name,card);add('div',row.domains.join(' · '),card,'meta');add('div',row.welcome_line,card,'line');
const details=add('details','',card);add('summary','Company context and review evidence',details);add('p',row.company_fact,details);add('p','Previously: '+row.previous_line,details,'old');add('p',row.review_reason,details);
for(const e of row.evidence){add('blockquote',e.quote,details);const a=add('a','View source',details);if(/^https:\/\//.test(e.url)){a.href=e.url;a.target='_blank';a.rel='noopener noreferrer';}}
}document.getElementById('more').hidden=rows.length<=limit;}
search.addEventListener('input',()=>{limit=40;render()});document.getElementById('more').addEventListener('click',()=>{limit+=40;render()});render();
</script></body></html>'''


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--catalog', type=Path, required=True)
    p.add_argument('--research-dir', type=Path, required=True)
    p.add_argument('--copy-dir', type=Path, required=True)
    p.add_argument('--output-dir', type=Path, required=True)
    p.add_argument('--unknown-fallback', action='store_true',
                   help='Stage an explicitly neutral welcome only for reviewed companies with unclear facts')
    args = p.parse_args()
    repo = Path(__file__).resolve().parents[1]
    out = args.output_dir.resolve()
    if out == repo or repo in out.parents:
        p.error('Keep company copy and evidence outside the repository')
    out.mkdir(parents=True, exist_ok=True, mode=0o700)
    catalog = json.loads(args.catalog.read_text())
    research = {x.stem:json.loads(x.read_text()) for x in (args.research_dir/'companies').glob('yc-company-*.json')}
    copies = {x.stem:json.loads(x.read_text()) for x in (args.copy_dir/'approved').glob('yc-company-*.json')}
    issues = {x.stem:json.loads(x.read_text()) for x in (args.copy_dir/'issues').glob('yc-company-*.json')}
    approved, pending = prepare(catalog, research, copies)
    fallbacks = []
    by_id = {c['source_id']:c for c in catalog['companies']}
    for item in pending:
        issue = issues.get(item['source_id'], {})
        if (item['reason'] == 'copy_pending' and issue.get('prompt_version') in SUPPORTED_VERSIONS
                and issue.get('source_hash') == research.get(item['source_id'], {}).get('source_hash')):
            item.update(reason=issue['phase'] + '_needs_review', detail=issue['reason'])
            if args.unknown_fallback:
                identity = item['source_id']
                draft_path = args.copy_dir/'drafts'/(identity + '.json')
                draft = json.loads(draft_path.read_text()) if draft_path.exists() else {}
                review_paths = sorted((args.copy_dir/'reviews').glob(identity + '-*.json'), key=lambda f:f.stat().st_mtime_ns)
                reviews = [json.loads(f.read_text()) for f in review_paths]
                fallback = unknown_fallback(by_id[identity], research[identity], issue, draft, reviews)
                if fallback:
                    fallbacks.append(fallback)
    approved.sort(key=lambda i:i['name'].casefold())
    save_json(out/'approved-copy.json', approved)
    save_json(out/'pending-copy.json', pending)
    publication = sorted(approved + fallbacks, key=lambda i:i['name'].casefold())
    save_json(out/'fallback-copy.json', fallbacks)
    save_json(out/'publication-copy.json', publication)
    # Keep a full staged catalog so a later, successful publication can become the next baseline.
    # This file is not the current-catalog pointer and does not claim to reflect production.
    staged = json.loads(json.dumps(catalog))
    lines = {i['source_id']:i['welcome_line'] for i in publication}
    for company in staged['companies']:
        if company['source_id'] in lines:
            company['welcome_line'] = lines[company['source_id']]
    staged['personalization_stage'] = {'published':False, 'approved':len(approved), 'pending':len(pending),
                                     'generic_fallbacks':len(fallbacks)}
    save_json(out/'staged-catalog.json', staged)
    report = {'target':len(approved)+len(pending), 'approved':len(approved), 'pending':len(pending),
              'unique_lines':len({i['welcome_line'] for i in approved}),
              'generic_fallbacks':len(fallbacks), 'ready_to_publish':len(publication),
              'unresolved':len(pending)-len(fallbacks),
              'pending_reasons':dict(Counter(i['reason'] for i in pending)),
              'prompt_version':VERSION, 'prepared_at':datetime.now(timezone.utc).isoformat(),
              'published':False}
    save_json(out/'review-report.json', report)
    rollback=[{**item,'previous_line':item['welcome_line'],'welcome_line':item['previous_line']} for item in publication]
    for name, content in [('publish-copy.sql',sql_packet(publication)), ('rollback-copy.sql',sql_packet(rollback)),
                          ('review.html',html_review(publication,pending))]:
        path=out/name
        path.write_text(content)
        path.chmod(0o600)
    print(json.dumps(report,indent=2))


if __name__ == '__main__':
    main()
