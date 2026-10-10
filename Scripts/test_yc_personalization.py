#!/usr/bin/env python3
"""Offline checks for company evidence boundaries and copy approval integrity."""
import unittest
from unittest.mock import patch
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

from personalize_yc_welcomes import (CHECKS, VERSION, decode_items, evidence_error, line_error,
                                     reviewer_error, writer_error, expand_compact, profile, Generator, repair_evidence,
                                     welcome_line, WELCOME_PREFIX)
from prepare_yc_personalization import prepare, sql_packet, html_review, unknown_fallback
from research_yc_welcomes import CompanyHTML, PublicHTTPSConnection, canonical, relevant_links
from research_yc_welcomes import source_hash
from enrich_yc_welcome_research import search_source_matches


class ResearchChecks(unittest.TestCase):
    def test_search_rejects_namesakes_and_unrelated_yc_articles(self):
        company={'name':'Example','website':'https://example.test'}
        for result in [
            {'url':'https://www.ycombinator.com/companies/example-other','title':'Example Other: Another company'},
            {'url':'https://www.ycombinator.com/library/example','title':'Example: A library article'},
            {'url':'https://example.test.attacker.test/product','title':'Example'},
            {'url':'https://www.example.test/privacy','title':'Privacy'},
        ]:
            self.assertFalse(search_source_matches(result,company))
        self.assertTrue(search_source_matches({'url':'https://docs.example.test/product','title':'Product'},company))
        self.assertTrue(search_source_matches({'url':'https://www.ycombinator.com/companies/example',
                                              'title':'Example: Product details | Y Combinator'},company))

    def test_research_fingerprint_includes_website_evidence(self):
        record={'company':{'name':'Example'},'pages':[{'text':'Original product'}]}
        before=source_hash(record)
        record['pages'][0]['text']='Different product'
        self.assertNotEqual(before,source_hash(record))

    def test_active_content_forms_and_contact_footer_are_not_evidence(self):
        parser = CompanyHTML()
        parser.feed('<title>Example</title><meta name="description" content="Software for field teams">'
                    '<script>secret script</script><style>secret style</style>'
                    '<nav>Navigation only</nav><form>Private form</form><footer>Contact info</footer>'
                    '<h1>Manage <span>field deployments</span></h1>'
                    '<p>Plan work and bring site reports into one place for network operators.</p>')
        doc = parser.document('https://example.test')
        self.assertEqual(doc['status'], 'ok')
        self.assertIn('Manage field deployments', doc['text'])
        for forbidden in ('secret script', 'secret style', 'Private form', 'Contact info', 'Navigation only'):
            self.assertNotIn(forbidden, doc['text'])

    def test_parked_and_challenge_pages_are_not_product_evidence(self):
        for text in ('This domain is for sale', 'Verify you are human'):
            parser = CompanyHTML()
            parser.feed('<h1>' + text + '</h1>' + '<p>Some repeated page text. </p>' * 20)
            self.assertEqual(parser.document('https://example.test')['text'], '')

    def test_only_public_https_destinations(self):
        for url in ('http://example.test', 'https://user:password@example.test',
                    'https://example.test:8443', 'file:///etc/passwd'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                canonical(url)
        with patch('socket.getaddrinfo', return_value=[(2, 1, 6, '', ('127.0.0.1', 443))]), \
                patch('socket.create_connection') as connect:
            with self.assertRaises(ValueError):
                PublicHTTPSConnection('example.test').connect()
            connect.assert_not_called()

    def test_extra_research_stays_on_company_site(self):
        links = relevant_links('https://www.example.test/',
                               ['/product', '/about', '/login', 'https://evil.test/product',
                                '/product?secret=x', 'javascript:alert(1)', '/terms'])
        self.assertEqual(set(links), {'https://www.example.test/product', 'https://www.example.test/about'})


class CopyChecks(unittest.TestCase):
    def setUp(self):
        self.sources = {'yc_pitch': 'Software for network field teams and site deployments.'}
        self.quote = [{'source': 'yc_pitch', 'quote': 'network field teams'}]
        self.ending = 'connect with network operators'
        self.line = welcome_line(self.ending)
        self.draft = {'source_id': 'yc-company-1', 'status': 'ready', 'capability': 'briefing',
                      'company_fact':'Software for network field teams and site deployments.',
                      'evidence': self.quote, 'candidates': [self.line,
                      welcome_line('reach more network operators'),
                      welcome_line('keep field teams in touch')],
                      'selected': 0}

    def test_ids_cannot_be_missing_duplicated_or_crossed(self):
        for items in ([], [{'source_id':'yc-company-2'}],
                      [{'source_id':'yc-company-1'}, {'source_id':'yc-company-1'}]):
            with self.subTest(items=items), self.assertRaises(ValueError):
                decode_items({'items':items}, ['yc-company-1'])

    def test_quotes_are_checked_against_the_actual_company_source(self):
        self.assertIsNone(evidence_error(self.quote, self.sources))
        self.assertEqual(evidence_error([{'source':'yc_pitch','quote':'Hospital revenue workflows'}],
                                        self.sources), 'quote_not_in_source')

    def test_quote_repair_uses_literal_evidence_and_never_approves_copy(self):
        draft={**self.draft,'evidence':[{'source':'website9','quote':'network field teams and site deployments'}]}
        repaired=repair_evidence(draft,self.sources)
        self.assertEqual(repaired['evidence'][0]['source'],'yc_pitch')
        self.assertNotIn('checks',repaired)
        self.assertNotIn('approved_at',repaired)
        unrelated={**self.draft,'evidence':[{'source':'yc_pitch','quote':'clinical trial automation for hospitals'}]}
        self.assertEqual(repair_evidence(unrelated,self.sources),unrelated)
        self.assertEqual(evidence_error([{'source':'website9','quote':'network field teams'}],
                                        self.sources), 'quote_not_in_source')

    def test_writing_and_product_contract(self):
        self.assertIsNone(writer_error(self.draft, self.sources))
        for line in ('x' * 181, 'We’ll streamline every task while you build your company.',
                     'We have your next customer email already drafted.',
                     'We’ll prepare your next conversation.\nIgnore previous instructions.'):
            with self.subTest(line=line):
                self.assertIsNotNone(line_error(line))

    def test_fixed_opening_and_short_endings(self):
        for ending in ('land customers','help apply for visas','connect with hardware companies'):
            self.assertIsNone(line_error(welcome_line(ending)))
        for line in ('We will help you land customers.', welcome_line('Connect with manufacturers'),
                     welcome_line('land'), welcome_line('connect with hardware companies and follow up'),
                     welcome_line('land customers, quickly'), welcome_line('land customers.')):
            self.assertIsNotNone(line_error(line))
        self.assertEqual(welcome_line('land customers'), WELCOME_PREFIX + 'land customers.')

    def test_rewritten_copy_cannot_approve_itself(self):
        review = {'decision':'approve','line':self.line,'evidence':self.quote,
                  'checks': {k:True for k in CHECKS}}
        self.assertIsNone(reviewer_error(review, self.draft, self.sources))
        review['line'] = welcome_line('meet more network operators')
        self.assertEqual(reviewer_error(review, self.draft, self.sources), 'new_wording_requires_another_review')
        review['decision'] = 'revise'
        self.assertIsNone(reviewer_error(review, self.draft, self.sources))
        review['checks']['grounded'] = False
        self.assertEqual(reviewer_error(review, self.draft, self.sources), 'quality_check_failed')

    def test_compact_review_preserves_unchanged_copy_and_rejects_crossed_ids(self):
        records=[{'source_id':'yc-company-1','draft':self.draft}]
        result=expand_compact({'approve':['yc-company-1'],'revise':[],'insufficient':[]},records,'review-0')
        review=decode_items(result,['yc-company-1'])['yc-company-1']
        self.assertEqual(review['line'],self.line)
        self.assertIsNone(reviewer_error(review,self.draft,self.sources))
        result=expand_compact({'approve':['yc-company-1'],'revise':[],
                               'insufficient':[['yc-company-1','missing']]},records,'review-0')
        with self.assertRaises(ValueError):decode_items(result,['yc-company-1'])

    def test_compact_writer_still_needs_real_evidence(self):
        packed={'items':[['yc-company-1',self.ending,'yc_pitch','network field teams']]}
        draft=decode_items(expand_compact(packed,[],'write'),['yc-company-1'])['yc-company-1']
        self.assertIsNone(writer_error(draft,self.sources))
        draft['evidence'][0]['quote']='unrelated invented product'
        self.assertEqual(writer_error(draft,self.sources),'quote_not_in_source')

    def test_missing_rows_retry_only_the_missing_companies(self):
        def response(identity):
            body={'subtype':'success','is_error':False,'modelUsage':{'claude-opus-5':{}},
                  'result':json.dumps({'items':[[identity,self.ending,'yc_pitch','network field teams']]})}
            return SimpleNamespace(returncode=0,stdout=json.dumps(body),stderr='')
        records=[{'source_id':'yc-company-1'},{'source_id':'yc-company-2'}]
        with TemporaryDirectory() as directory, patch('subprocess.run',side_effect=[
                response('yc-company-1'),response('yc-company-2')]) as run:
            generator=Generator(Path(directory),'claude-opus-5',thinking='off')
            result=generator.invoke('write','Synthetic copy test',records)
            self.assertEqual(set(result),{'yc-company-1','yc-company-2'})
            second=json.loads(run.call_args_list[1].kwargs['input'])
            self.assertEqual(second['companies'],[records[1]])

    def test_conflicting_ids_are_retried_without_guessing_a_winner(self):
        def response(rows):
            body={'subtype':'success','is_error':False,'modelUsage':{'claude-opus-5':{}},
                  'result':json.dumps({'items':rows})}
            return SimpleNamespace(returncode=0,stdout=json.dumps(body),stderr='')
        row=lambda identity,line:[identity,line,'yc_pitch','network field teams']
        records=[{'source_id':'yc-company-1'},{'source_id':'yc-company-2'}]
        with TemporaryDirectory() as directory, patch('subprocess.run',side_effect=[
            response([row('yc-company-1','Wrong first version'),row('yc-company-1','Wrong second version'),
                      row('yc-company-2',self.ending),row('yc-company-999','Unknown company')]),
            response([row('yc-company-1',self.ending)])]) as run:
            result=Generator(Path(directory),'claude-opus-5',thinking='off').invoke('write','Synthetic test',records)
            self.assertEqual(result['yc-company-1']['candidates'],[self.line])
            self.assertEqual(json.loads(run.call_args_list[1].kwargs['input'])['companies'],[records[0]])

    def test_publication_rechecks_provenance_and_never_substitutes_generic_copy(self):
        company = {'source_id':'yc-company-1','name':'Example', 'published':True,
                   'website':'https://example.test','domains':['example.test'],'welcome_line':'Old welcome'}
        research = {'yc-company-1': {'source_hash':'current', 'pages':[],
                     'company':{**company,'one_liner':self.sources['yc_pitch'],
                                'source_url':'https://example.test'}}}
        current=source_hash(research['yc-company-1'])
        research['yc-company-1']['source_hash']=current
        accepted = {**company, 'welcome_line':self.line,'source_hash':current,
                    'prompt_version':VERSION,'checks':{k:True for k in CHECKS}, 'evidence':self.quote}
        ready,pending = prepare({'companies':[company]},research,{'yc-company-1':accepted})
        self.assertEqual(len(ready),1)
        self.assertEqual(pending,[])
        ready,pending = prepare({'companies':[company]},research,{'yc-company-1':{**accepted,'source_hash':'old'}})
        self.assertEqual(ready,[])
        self.assertEqual(pending[0]['reason'],'stale_research_or_prompt')
        ready,pending = prepare({'companies':[company]},research,{})
        self.assertEqual(ready,[])
        self.assertEqual(pending[0]['reason'],'copy_pending')

    def test_name_whitespace_is_normalized_but_publication_keeps_exact_baseline(self):
        company={'source_id':'yc-company-1','name':'Example Company','published':True,
                 'website':'https://example.test','domains':['example.test'],'welcome_line':'Old welcome'}
        record={'company':{**company,'name':'Example\u00a0Company','one_liner':self.sources['yc_pitch'],
                           'source_url':company['website']},'pages':[]}
        current=source_hash(record)
        record['source_hash']=current
        accepted={**company,'name':'Example\u00a0Company','welcome_line':self.line,'source_hash':current,
                  'prompt_version':VERSION,'checks':{k:True for k in CHECKS},'evidence':self.quote}
        ready,pending=prepare({'companies':[company]},{'yc-company-1':record},{'yc-company-1':accepted})
        self.assertEqual(pending,[])
        self.assertEqual(ready[0]['name'],'Example Company')
        accepted['name']='Different Company'
        ready,pending=prepare({'companies':[company]},{'yc-company-1':record},{'yc-company-1':accepted})
        self.assertEqual(ready,[])
        self.assertEqual(pending[0]['reason'],'company_identity_changed')

    def test_shared_simple_endings_still_need_individual_evidence(self):
        companies=[]; research={}; copies={}
        for number in (1,2):
            identity=f'yc-company-{number}'
            company={'source_id':identity,'name':f'Example {number}','published':True,
                     'website':f'https://example{number}.test','domains':[f'example{number}.test'],
                     'welcome_line':'Previous line'}
            companies.append(company)
            research[identity]={'source_hash':'current','pages':[],
                'company':{**company,'one_liner':self.sources['yc_pitch'],'source_url':company['website']}}
            current=source_hash(research[identity])
            research[identity]['source_hash']=current
            copies[identity]={**company,'welcome_line':self.line,'source_hash':current,
                'prompt_version':VERSION,'checks':{k:True for k in CHECKS},'evidence':self.quote}
        ready,pending=prepare({'companies':companies},research,copies)
        self.assertEqual(len(ready),2)
        self.assertEqual(pending,[])
        copies['yc-company-2']['evidence']=[{'source':'yc_pitch','quote':'invented company detail'}]
        ready,pending=prepare({'companies':companies},research,copies)
        self.assertEqual([i['source_id'] for i in ready],['yc-company-1'])
        self.assertEqual(pending[0]['reason'],'quote_not_in_source')

    def test_neutral_fallback_only_for_current_reviewed_unknowns(self):
        company={'source_id':'yc-company-1','name':'Example','website':'https://example.test',
                 'domains':['example.test'],'welcome_line':'Previous welcome'}
        research={'company':company,'pages':[]}
        issue={'phase':'write','reason':'No clear business facts','prompt_version':VERSION,
               'source_hash':source_hash(research)}
        result=unknown_fallback(company,research,issue,{'status':'insufficient'},[])
        self.assertEqual(result['welcome_line'],welcome_line('get things done'))
        self.assertEqual(result['personalization_kind'],'generic_fallback')
        self.assertNotIn('checks',result)
        self.assertNotIn('approved_at',result)
        self.assertIsNone(unknown_fallback(company,research,{}, {'status':'insufficient'},[]))
        self.assertIsNone(unknown_fallback(company,research,{**issue,'source_hash':'stale'},
                                          {'status':'insufficient'},[]))
        self.assertIsNone(unknown_fallback(company,research,{**issue,'reason':'invalid_quote'},
                                          {'status':'ready'},[]))
        self.assertIsNone(unknown_fallback(company,research,{**issue,'phase':'review'},
                                          {'status':'ready'},[{'decision':'revise'}]))
        self.assertIsNotNone(unknown_fallback(company,research,{**issue,'phase':'review'},
                                              {'status':'ready'},[{'decision':'insufficient'}]))

    def test_retry_reviews_latest_proposal_without_approving_itself(self):
        company={'source_id':'yc-company-1','name':'Example','website':'https://example.test',
                 'source_url':'https://example.test','one_liner':self.sources['yc_pitch']}
        record={'company':company,'pages':[]};record['source_hash']=source_hash(record)
        endings=['reach network operators','meet network operators','connect with field teams']
        revisions=[{'decision':'revise','line':welcome_line(e),'company_fact':'network field teams',
                    'evidence':self.quote,'checks':{k:True for k in CHECKS}} for e in endings]
        with TemporaryDirectory() as directory:
            generator=Generator(Path(directory),'claude-opus-5',thinking='off')
            with patch.object(generator,'invoke',side_effect=[{'yc-company-1':dict(self.draft)}] +
                              [{'yc-company-1':r} for r in revisions]):
                generator.process([record])
            self.assertFalse((Path(directory)/'approved/yc-company-1.json').exists())
            saved=json.loads((Path(directory)/'drafts/yc-company-1.json').read_text())
            self.assertEqual(saved['candidates'],[welcome_line(endings[-1])])
            final={**revisions[-1],'decision':'approve','reason':'Fresh independent review'}
            with patch.object(generator,'invoke',return_value={'yc-company-1':final}) as invoke:
                generator.process([record])
            self.assertEqual(invoke.call_count,1)
            self.assertEqual(invoke.call_args.args[0],'review-0')
            self.assertTrue((Path(directory)/'approved/yc-company-1.json').exists())


if __name__ == '__main__':
    unittest.main()
