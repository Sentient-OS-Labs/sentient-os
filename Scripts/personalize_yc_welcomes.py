#!/usr/bin/env python3
"""Generate and independently review company-specific welcome drafts using an authorized CLI.

Run only after the user authorizes Claude workers. Tool access, MCP, hooks and persistence are
disabled for model calls. Checkpoints and source evidence stay outside the repository. This
script NEVER deploys or changes the published catalog, domains, logos, founders or contacts.
"""
import argparse
import difflib
from concurrent.futures import ThreadPoolExecutor, as_completed
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
import unicodedata

from fetch_yc_companies import save_json
from research_yc_welcomes import source_hash

ROOT = Path(__file__).resolve().parent
WRITE_PROMPT = (ROOT / 'yc_welcome_copy_prompt.txt').read_text()
REVIEW_PROMPT = (ROOT / 'yc_welcome_review_prompt.txt').read_text()
VERSION = hashlib.sha256((WRITE_PROMPT + REVIEW_PROMPT).encode()).hexdigest()
SUPPORTED_VERSIONS = {VERSION}
WELCOME_PREFIX = "Can't wait for you to use Sidekick and Double Tap to "
CAPABILITIES = {'drafting', 'briefing', 'context', 'commitments', 'research'}
CHECKS = {'specific', 'grounded', 'capability', 'audience', 'honest', 'writing', 'disclosure'}
LIMIT_ERROR = re.compile(r'rate.limit|usage.limit|out of.*usage|limit reached|hit your limit|'
                         r'credit balance|not logged in|authentication|quota', re.I)


class ModelUnavailable(RuntimeError):
    pass


def tidy(text):
    return re.sub(r'\s+', ' ', text or '').strip()


def welcome_line(ending):
    return WELCOME_PREFIX + ending + '.' if isinstance(ending, str) else ending


def line_error(line):
    if not isinstance(line, str) or not 20 <= len(line) <= 180 or line != line.strip():
        return 'invalid_length_or_whitespace'
    if any(unicodedata.category(c) == 'Cc' or '\u202a' <= c <= '\u202e' or '\u2066' <= c <= '\u2069' for c in line):
        return 'control_character'
    if any(c in line for c in ('—', '\n', '*', '#', '`', '<', '>')):
        return 'invalid_display_format'
    if re.search(r'https?://|\b[\w.+-]+@[\w.-]+\.[a-z]{2,}\b', line, re.I):
        return 'unexpected_link_or_contact'
    if re.search(r'\b(unlock|streamline|supercharge|revolutionize|leverage|seamlessly)\b|'
                 r'while you build\b|focus on what matters|already (drafted|prepared|sent)|'
                 r'automatically send|guarantee', line, re.I):
        return 'unsupported_or_generic_copy'
    if not line.startswith(WELCOME_PREFIX) or not line.endswith('.'):
        return 'incorrect_welcome_template'
    ending = line[len(WELCOME_PREFIX):-1]
    if not 2 <= len(ending.split()) <= 6 or len(ending) > 55:
        return 'ending_not_short'
    if (not ending[:1].islower() or ending != tidy(ending)
            or re.search(r'[^a-zA-Z0-9 \x27\u2019-]', ending)):
        return 'invalid_ending_format'
    return None


def evidence_error(evidence, sources):
    if not isinstance(evidence, list) or not 1 <= len(evidence) <= 5:
        return 'missing_evidence'
    for item in evidence:
        if not isinstance(item, dict):
            return 'invalid_evidence'
        quote, source = item.get('quote'), item.get('source')
        if not isinstance(quote, str) or not 8 <= len(quote) <= 160:
            return 'invalid_quote'
        if source not in sources or tidy(quote).casefold() not in tidy(sources[source]).casefold():
            return 'quote_not_in_source'
    return None


def repair_evidence(draft, sources):
    """Recover a misquoted fragment only from literal source text; a model still reviews the line.

    This cannot approve copy. It replaces a nearly verbatim quote with its substantial exact
    shared phrase, or corrects a source key. Unsupported or short fragments stay rejected.
    """
    if draft.get('status') != 'ready' or not isinstance(draft.get('evidence'), list):
        return draft
    repaired=[]
    for item in draft['evidence']:
        if not isinstance(item,dict) or not isinstance(item.get('quote'),str):
            return draft
        if not evidence_error([item],sources):
            repaired.append(item)
            continue
        quote=tidy(item.get('quote'))
        if not quote:
            return draft
        best=None
        for key, text in sources.items():
            text=tidy(text)
            if quote.casefold() in text.casefold():
                candidate={'source':key,'quote':quote}
            else:
                match=difflib.SequenceMatcher(None,quote,text,autojunk=False).find_longest_match()
                candidate_quote=text[match.b:match.b+match.size].strip()
                # Do not turn a partial word or a generic few words into a citation.
                if match.b and text[match.b-1].isalnum() and candidate_quote[:1].isalnum():
                    candidate_quote=candidate_quote.partition(' ')[2]
                end=match.b+match.size
                if end<len(text) and text[end].isalnum() and candidate_quote[-1:].isalnum():
                    candidate_quote=candidate_quote.rpartition(' ')[0]
                if len(candidate_quote)<max(18,len(quote)*0.65) or len(candidate_quote.split())<3:
                    continue
                candidate={'source':key,'quote':candidate_quote}
            if not evidence_error([candidate],sources) and (best is None or len(candidate['quote'])>len(best['quote'])):
                best=candidate
        if best is None:
            return draft
        repaired.append(best)
    if repaired == draft['evidence']:
        return draft
    return {**draft,'evidence':repaired,'company_fact':repaired[0]['quote'],
            'evidence_repaired':True}


def profile(record, compact=False):
    c = record['company']
    sources = {}
    for key in ('one_liner', 'long_description'):
        if tidy(c.get(key)):
            sources['yc_pitch' if key == 'one_liner' else 'yc_description'] = c[key][:6500]
    urls = {'yc_pitch': c['source_url'], 'yc_description': c['source_url']}
    for i, page in enumerate(record['pages']):
        key = 'website' + str(i)
        sources[key] = page['text'][:6500]
        urls[key] = page['url']
    if compact:
        budget, shortened = 4200, {}
        order = list(dict.fromkeys(['yc_pitch', 'website0', 'yc_description', *sources]))
        for key in order:
            if key not in sources or budget <= 0:
                continue
            cap = 400 if key == 'yc_pitch' else 2400 if key == 'website0' else 1400 if key == 'yc_description' else 900
            shortened[key] = sources[key][:min(cap, budget)]
            budget -= len(shortened[key])
        sources = shortened
    return {'source_id': c['source_id'], 'name': c['name'], 'website': c['website'],
            'sources': sources, 'source_urls': urls}


def decode_items(payload, expected):
    if isinstance(payload, str):
        text = payload.strip()
        if text.startswith('```'):
            text = re.sub(r'^```(?:json)?\s*|\s*```$', '', text)
        payload = json.loads(text)
    items = payload.get('items')
    if not isinstance(items, list) or any(not isinstance(x, dict) for x in items):
        raise ValueError('Missing structured company results')
    ids = [i.get('source_id') for i in items]
    if len(ids) != len(set(ids)) or set(ids) != set(expected):
        raise ValueError('Missing, extra or duplicate company IDs')
    return {i['source_id']: i for i in items}


def expand_compact(payload, records, kind):
    if isinstance(payload, str):
        payload = json.loads(re.sub(r'^```(?:json)?\s*|\s*```$', '', payload.strip()))
    if kind == 'write':
        items=[]
        for row in payload['items']:
            if not isinstance(row, list):
                raise ValueError('Expected compact writer rows')
            if len(row) == 3 and row[1] is None:
                items.append({'source_id':row[0], 'status':'insufficient', 'candidates':[], 'reason':row[2]})
            elif 4 <= len(row) <= 8:
                items.append({'source_id':row[0], 'status':'ready', 'candidates':[welcome_line(row[1])], 'selected':0,
                              'company_fact':row[3],
                              'evidence':[{'source':row[2], 'quote':quote} for quote in row[3:]]})
            else:
                raise ValueError('Invalid compact writer row')
        return {'items':items}
    by_id={r['source_id']:r for r in records}
    items=[]
    for identity in payload['approve']:
        if identity not in by_id:
            items.append({'source_id':identity})
            continue
        draft=by_id[identity]['draft']
        items.append({'source_id':identity, 'decision':'approve',
                      'line':draft['candidates'][draft['selected']], 'company_fact':draft['company_fact'],
                      'evidence':draft['evidence'], 'checks':{k:True for k in CHECKS},
                      'reason':'Independently reviewed against all seven criteria and the source evidence.'})
    for row in payload['revise']:
        if not isinstance(row,list) or len(row) != 4:
            raise ValueError('Invalid compact revision')
        items.append({'source_id':row[0], 'decision':'revise', 'line':welcome_line(row[1]), 'company_fact':row[3],
                      'evidence':[{'source':row[2], 'quote':row[3]}], 'checks':{k:True for k in CHECKS},
                      'reason':'Independent review proposed revised wording.'})
    for row in payload['insufficient']:
        if not isinstance(row,list) or len(row) != 2:
            raise ValueError('Invalid compact rejection')
        items.append({'source_id':row[0], 'decision':'insufficient', 'line':'', 'reason':row[1]})
    return {'items':items}


def writer_error(item, sources):
    if item.get('status') == 'insufficient':
        return None if item.get('candidates') == [] else 'insufficient_with_candidates'
    if item.get('status') != 'ready' or (item.get('capability') is not None and item['capability'] not in CAPABILITIES):
        return 'invalid_writer_status_or_capability'
    candidates = item.get('candidates')
    if not isinstance(candidates, list) or len(candidates) not in (1,3) or not all(isinstance(x, str) for x in candidates):
        return 'invalid_candidate_count'
    if len(set(candidates)) != len(candidates) or type(item.get('selected')) is not int or item['selected'] not in range(len(candidates)):
        return 'invalid_candidate_selection'
    return next((e for c in candidates if (e := line_error(c))), None) or evidence_error(item.get('evidence'), sources)


def reviewer_error(item, draft, sources):
    decision = item.get('decision')
    if decision == 'insufficient':
        return None if not item.get('line') else 'insufficient_with_line'
    if decision not in ('approve', 'revise'):
        return 'invalid_review_decision'
    error = line_error(item.get('line')) or evidence_error(item.get('evidence'), sources)
    if error:
        return error
    checks = item.get('checks')
    if not isinstance(checks, dict) or set(checks) != CHECKS or not all(v is True for v in checks.values()):
        return 'quality_check_failed'
    if decision == 'approve' and item['line'] not in draft['candidates']:
        return 'new_wording_requires_another_review'
    return None


class Generator:
    def __init__(self, output, model, effort='low', thinking='adaptive', full_evidence=False):
        self.output, self.model, self.effort, self.thinking = output, model, effort, thinking
        self.full_evidence = full_evidence
        self.lock = threading.Lock()
        self.calls = 0
        self.models = set()
        self.unavailable = threading.Event()
        for folder in ('calls', 'drafts', 'reviews', 'approved', 'issues', 'model-cwd'):
            (output / folder).mkdir(parents=True, exist_ok=True, mode=0o700)

    def invoke(self, kind, system, records):
        if self.unavailable.is_set():
            raise ModelUnavailable('Model usage or authentication limit; resume after resolving it')
        packed = json.dumps({'companies': records}, ensure_ascii=False)
        digest = hashlib.sha256((VERSION + self.model + self.effort + self.thinking + kind + packed).encode()).hexdigest()
        cache = self.output / 'calls' / (kind + '-' + digest + '.json')
        partial_cache = self.output / 'calls' / (kind + '-' + digest + '-partial.json')
        expected = [r['source_id'] for r in records]
        if cache.exists():
            saved = json.loads(cache.read_text())
            return decode_items(saved['result'], expected)
        collected = {}
        if partial_cache.exists():
            saved = json.loads(partial_cache.read_text())['result']
            ids = [i['source_id'] for i in saved['items']]
            if set(ids) <= set(expected):
                collected = decode_items(saved, ids)
        command = ['claude', '-p', '--model', self.model, '--effort', self.effort, '--tools', '',
                   '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
                   '--disable-slash-commands', '--no-session-persistence', '--setting-sources', '',
                   '--settings', '{"disableAllHooks":true}', '--output-format', 'json',
                   '--system-prompt', system]
        for attempt in range(3):
            started = time.monotonic()
            remaining = [r for r in records if r['source_id'] not in collected]
            if not remaining:
                return collected
            packed = json.dumps({'companies':remaining}, ensure_ascii=False)
            outer = {}
            try:
                process = subprocess.run(command, input=packed, text=True, capture_output=True,
                                         timeout=900, cwd=self.output / 'model-cwd',
                                         env={**os.environ, 'MAX_THINKING_TOKENS':'0'} if self.thinking == 'off' else None)
                try:
                    outer = json.loads(process.stdout)
                except json.JSONDecodeError:
                    if LIMIT_ERROR.search(process.stdout + process.stderr):
                        self.unavailable.set()
                        raise ModelUnavailable('Model usage or authentication limit; resume after resolving it')
                    raise
                if process.returncode or outer.get('is_error') or outer.get('subtype') != 'success':
                    message = str(outer.get('result', ''))
                    if LIMIT_ERROR.search(message):
                        self.unavailable.set()
                        raise ModelUnavailable(message[:300])
                    raise RuntimeError('Model request failed: ' + str(outer.get('subtype')))
                models = list(outer.get('modelUsage', {}))
                if not models or any(not m.startswith('claude-opus-5') for m in models):
                    raise RuntimeError('Expected the authorized Opus 5 model')
                if self.thinking == 'off' and any(m != 'claude-opus-5' for m in models):
                    self.unavailable.set()
                    raise ModelUnavailable('The requested Opus 5 model was replaced; stop before further calls')
                expanded = expand_compact(outer['result'], remaining, kind)
                counts = Counter(i['source_id'] for i in expanded['items'])
                wanted = {r['source_id'] for r in remaining}
                # Ignore unknown IDs and discard BOTH rows for any duplicate. Request missing
                # IDs again; never guess which of two conflicting company records was intended.
                expanded['items'] = [i for i in expanded['items']
                                     if i['source_id'] in wanted and counts[i['source_id']] == 1]
                ids = [i['source_id'] for i in expanded['items']]
                if not ids:
                    raise ValueError('No unambiguous requested company IDs in response')
                result = decode_items(expanded, ids)
                collected.update(result)
                if len(collected) < len(expected):
                    save_json(partial_cache, {'result':{'items':list(collected.values())}, 'models':models})
                    if attempt == 2:
                        raise ValueError('Some company IDs remain missing; valid rows were saved for resume')
                    continue
                result = collected
                save_json(cache, {'result': {'items': list(result.values())}, 'models': models,
                                  'usage': outer.get('usage'), 'effort': self.effort, 'thinking':self.thinking,
                                  'duration': time.monotonic() - started,
                                  'prompt_version': VERSION, 'created_at': datetime.now(timezone.utc).isoformat()})
                partial_cache.unlink(missing_ok=True)
                with self.lock:
                    self.calls += 1
                    self.models.update(models)
                return result
            except ModelUnavailable:
                raise
            except (subprocess.TimeoutExpired, json.JSONDecodeError, ValueError, RuntimeError, KeyError, TypeError) as error:
                save_json(self.output / 'calls' / (kind + '-' + digest + '-error.json'),
                          {'error': str(error)[:300], 'attempt': attempt + 1,
                           'result_for_diagnosis':outer.get('result')})
                if attempt == 2:
                    raise
                time.sleep(10 * (attempt + 1))

    def issue(self, identity, phase, reason, source_hash):
        save_json(self.output / 'issues' / (identity + '.json'),
                  {'source_id': identity, 'phase': phase, 'reason': reason,
                   'source_hash': source_hash, 'prompt_version': VERSION})

    def process(self, records):
        profiles = [profile(r, compact=not self.full_evidence) for r in records]
        by_id = {r['company']['source_id']: r for r in records}
        drafts = {}
        to_write = []
        for p in profiles:
            identity = p['source_id']
            path = self.output / 'drafts' / (identity + '.json')
            saved = json.loads(path.read_text()) if path.exists() else {}
            if saved.get('source_hash') == by_id[identity]['source_hash']:
                saved = repair_evidence(saved, p['sources'])
            if (saved.get('source_hash') == by_id[identity]['source_hash']
                    and saved.get('prompt_version') in SUPPORTED_VERSIONS
                    and saved.get('status') == 'ready' and not writer_error(saved, p['sources'])):
                drafts[identity] = saved
            else:
                to_write.append(p)
        if to_write:
            drafts.update(self.invoke('write', WRITE_PROMPT, to_write))
        ready = []
        for p in profiles:
            identity = p['source_id']
            draft = repair_evidence(drafts[identity], p['sources'])
            draft.update(source_hash=by_id[identity]['source_hash'], prompt_version=VERSION)
            save_json(self.output / 'drafts' / (identity + '.json'), draft)
            error = writer_error(draft, p['sources'])
            if error or draft['status'] != 'ready':
                self.issue(identity, 'write', error or draft.get('reason', 'insufficient'), by_id[identity]['source_hash'])
            else:
                ready.append({**p, 'draft': draft})
        if not ready:
            return len(records)
        # Every revision is reviewed by a fresh invocation before it can become approved.
        for round_number in range(3):
            reviews = self.invoke('review-' + str(round_number), REVIEW_PROMPT, ready)
            revised = []
            for p in ready:
                identity, draft = p['source_id'], p['draft']
                review = reviews[identity]
                if review.get('decision') in ('approve', 'revise'):
                    repaired = repair_evidence({'status':'ready', 'evidence':review.get('evidence')}, p['sources'])
                    if repaired.get('evidence') != review.get('evidence'):
                        # A corrected quote also needs a fresh review; it cannot approve itself.
                        review = {**review, 'decision':'revise', 'evidence':repaired['evidence'],
                                  'company_fact':repaired['company_fact']}
                save_json(self.output / 'reviews' / (identity + '-' + str(round_number) + '.json'), review)
                error = reviewer_error(review, draft, p['sources'])
                if error or review['decision'] == 'insufficient':
                    self.issue(identity, 'review', error or review.get('reason', 'insufficient'), by_id[identity]['source_hash'])
                elif review['decision'] == 'revise':
                    next_draft = {**draft, 'candidates':[review['line']], 'selected':0,
                                  'evidence':review['evidence'], 'company_fact':review['company_fact']}
                    # Resume from the latest validated proposal, not the rejected first draft.
                    save_json(self.output / 'drafts' / (identity + '.json'), next_draft)
                    if round_number == 2:
                        self.issue(identity, 'review', 'revision_limit', by_id[identity]['source_hash'])
                    else:
                        revised.append({**p, 'draft':next_draft})
                else:
                    result = {'source_id': identity, 'name': p['name'], 'welcome_line': review['line'],
                              'company_fact': review['company_fact'],
                              'writer_proposed_capability': draft.get('capability'),
                              'evidence': [{**e, 'url': p['source_urls'][e['source']]} for e in review['evidence']],
                              'checks': review['checks'], 'review_reason': review['reason'],
                              'source_hash': by_id[identity]['source_hash'], 'prompt_version': VERSION,
                              'approved_at': datetime.now(timezone.utc).isoformat()}
                    save_json(self.output / 'approved' / (identity + '.json'), result)
                    (self.output / 'issues' / (identity + '.json')).unlink(missing_ok=True)
            if not revised:
                break
            ready = revised
        return len(records)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--research-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--model', default='opus')
    parser.add_argument('--effort', choices=('low','medium','high'), default='low')
    parser.add_argument('--thinking', choices=('adaptive','off'), default='adaptive')
    parser.add_argument('--full-evidence', action='store_true',
                        help='Use all collected text when retrying difficult or sparse company records')
    parser.add_argument('--workers', type=int, default=3)
    parser.add_argument('--batch-size', type=int, default=96)
    parser.add_argument('--limit', type=int)
    parser.add_argument('--ids', help='Comma-separated company source IDs for a focused retry')
    args = parser.parse_args()
    output = args.output_dir.resolve()
    repo = ROOT.parent
    if output == repo or repo in output.parents:
        parser.error('Keep generated company copy outside the repository')
    if not 1 <= args.workers <= 12 or not 1 <= args.batch_size <= 96:
        parser.error('Use 1–12 bounded text requests and 1–96 companies per batch')
    if args.thinking == 'off' and args.model != 'claude-opus-5':
        parser.error('Thinking off requires the explicit claude-opus-5 model; later models cannot disable it')
    generator = Generator(output, args.model, args.effort, args.thinking, args.full_evidence)
    records = [json.loads(p.read_text()) for p in sorted((args.research_dir / 'companies').glob('yc-company-*.json'))]
    if any(r.get('source_hash') != source_hash(r) for r in records):
        parser.error('Research content changed without an updated evidence fingerprint')
    if args.ids:
        identifiers = set(args.ids.split(','))
        records = [r for r in records if r['company']['source_id'] in identifiers]
        if len(records) != len(identifiers):
            parser.error('Requested research record is missing')
    pending = []
    for record in records:
        path = output / 'approved' / (record['company']['source_id'] + '.json')
        existing = json.loads(path.read_text()) if path.exists() else {}
        if existing.get('source_hash') != record['source_hash'] or existing.get('prompt_version') not in SUPPORTED_VERSIONS:
            pending.append(record)
    pending.sort(key=lambda r: (r['company']['batch'] != 'F26', r['company']['source_id']))
    if args.limit:
        pending = pending[:args.limit]
    total = len(pending)
    completed = 0
    failures = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(generator.process, pending[i:i + args.batch_size]): pending[i:i + args.batch_size]
                   for i in range(0, total, args.batch_size)}
        for future in as_completed(futures):
            try:
                completed += future.result()
            except Exception as error:
                batch = futures[future]
                failures.append({'ids': [r['company']['source_id'] for r in batch], 'error': str(error)[:250]})
            approved = [json.loads(p.read_text()) for p in (output / 'approved').glob('yc-company-*.json')]
            duplicates = {line: n for line, n in Counter(r['welcome_line'] for r in approved).items() if n > 1}
            report = {'scheduled': total, 'completed_this_run': completed, 'approved_total': len(approved),
                      'issues_total': len(list((output / 'issues').glob('*.json'))), 'duplicate_lines': duplicates,
                      'failed_batches': failures, 'model_calls_this_run': generator.calls,
                      'models': sorted(generator.models), 'prompt_version': VERSION,
                      'updated_at': datetime.now(timezone.utc).isoformat()}
            save_json(output / 'generation-report.json', report)
            print(json.dumps({k:v for k,v in report.items() if k not in ('duplicate_lines','failed_batches','prompt_version')}), flush=True)
    if failures:
        raise SystemExit('Some model batches failed; rerun to resume.')


if __name__ == '__main__':
    main()
