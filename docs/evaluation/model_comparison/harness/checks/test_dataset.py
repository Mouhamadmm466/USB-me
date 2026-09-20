"""Dataset invariants and independent arithmetic checks; no network or model calls."""
import collections
import copy
import datetime as dt
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch
from zoneinfo import ZoneInfo
import pilot
import viewer

ROOT = pathlib.Path(__file__).resolve().parents[1]

class DatasetChecks(unittest.TestCase):
    def setUp(self):
        self.data = pilot.load_cases()
        self.by_key = {c['coverage_key']: c for c in self.data['cases']}

    def test_150_cases_and_all_ten_tools_in_each_tier(self):
        self.assertEqual(collections.Counter(c['difficulty'] for c in self.data['cases']), pilot.TIER_COUNTS)
        for tier in pilot.TIER_COUNTS:
            cases = [c for c in self.data['cases'] if c['difficulty'] == tier]
            self.assertEqual({c['expected']['tool'] for c in cases} - {None}, set(pilot.TOOLS))
            self.assertEqual({c['id'] for c in cases}, {tier[0].upper()+str(i) for i in range(1,51)})

    def test_authoring_source_matches_shipped_dataset(self):
        spec = importlib.util.spec_from_file_location('case_authoring', ROOT/'datasets/build_cases.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.dataset, self.data)

    def test_duplicate_requests_and_invalid_action_contracts_are_rejected(self):
        mutations = ('duplicate_request','duplicate_coverage','wrong_count','missing_argument','wrong_confirmation')
        for mutation in mutations:
            data=copy.deepcopy(self.data)
            if mutation=='duplicate_request': data['cases'][1]['input']['user_request']=data['cases'][0]['input']['user_request']
            elif mutation=='duplicate_coverage': data['cases'][1]['coverage_key']=data['cases'][0]['coverage_key']
            elif mutation=='wrong_count': data['cases'].pop()
            elif mutation=='missing_argument': del data['cases'][0]['expected']['arguments']['message']
            else: data['cases'][0]['expected']['requires_confirmation']=False
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as td:
                root=pathlib.Path(td)
                (root/'cases.json').write_text(json.dumps(data))
                with patch.object(pilot,'ROOT',root), self.assertRaises(ValueError): pilot.load_cases()

    def test_environment_overrides_do_not_leak_labels(self):
        case=self.by_key['choose-the-explicitly-second-repeated-hour']
        req=pilot.make_request(self.data,case,'system')
        inp=json.loads(req['messages'][1]['content'])
        self.assertEqual(inp['environment']['now'],'2026-10-31T12:00:00-04:00')
        self.assertEqual(inp['environment']['timezone'],'America/New_York')
        self.assertNotIn('expected',inp)
        self.assertNotIn('tags',inp)
        self.assertNotIn('coverage_key',inp)
        self.assertEqual(self.data['environment']['now'],'2026-09-19T12:00:00-04:00')

    def test_temporal_answer_keys_against_independent_datetime_math(self):
        for key,minutes in [('cross-a-year-boundary-after-correcting-an-interval',20),('cross-into-leap-day-with-a-changed-reminder-delay',90),('carry-a-relative-reminder-across-midnight',30)]:
            case=self.by_key[key]
            now=dt.datetime.fromisoformat(case['environment']['now'])
            self.assertEqual(pilot.timestamp(case['expected']['arguments']['due_at']),now+dt.timedelta(minutes=minutes))
        zone=ZoneInfo('America/New_York')
        c=self.by_key['preserve-elapsed-duration-across-the-autumn-clock-change']
        start=dt.datetime(2026,11,1,1,30,tzinfo=zone,fold=0).astimezone(dt.timezone.utc)
        end=start+dt.timedelta(minutes=90)
        self.assertEqual(pilot.timestamp(c['expected']['arguments']['starts_at']),start)
        self.assertEqual(pilot.timestamp(c['expected']['arguments']['ends_at']),end)
        c=self.by_key['choose-the-explicitly-second-repeated-hour']
        second=dt.datetime(2026,11,1,1,30,tzinfo=zone,fold=1)
        self.assertEqual(pilot.timestamp(c['expected']['arguments']['due_at']),second.astimezone(dt.timezone.utc))

    def test_fixed_clock_and_compact_prompts_fit_the_planned_scope(self):
        # A character-size regression bound, not a tokenizer measurement.
        prompt=(ROOT/'system_prompt.txt').read_text()
        for c in self.data['cases']:
            request=pilot.make_request(self.data,c,prompt)
            self.assertLess(sum(len(m['content']) for m in request['messages']),10000)

    def test_reports_keep_legacy_and_new_denominators(self):
        self.assertEqual(pilot.planned_tiers({'planned_cases':9}),dict(easy=3,medium=3,hard=3))
        self.assertEqual(pilot.planned_tiers({'planned_cases':150,'planned_by_tier':pilot.TIER_COUNTS}),pilot.TIER_COUNTS)
        with tempfile.TemporaryDirectory() as td:
            directory=pathlib.Path(td)
            report={'status':'incomplete','planned_cases':150,'planned_by_tier':pilot.TIER_COUNTS,'results':[]}
            pilot.write_report(directory,report)
            self.assertIn('| easy | 0 / 50 |',(directory/'report.md').read_text())
            self.assertIn('0 / 50',(directory/'report.html').read_text())
            report['planned_cases']=9
            del report['planned_by_tier']
            pilot.write_report(directory,report)
            self.assertIn('| easy | 0 / 3 |',(directory/'report.md').read_text())
            self.assertIn('0 / 3',(directory/'report.html').read_text())

    def test_validate_has_no_model_or_container_access(self):
        with patch.object(pilot,'http_json',side_effect=AssertionError('No HTTP allowed')), patch.object(pilot,'command',side_effect=AssertionError('No external command allowed')):
            self.assertEqual(len(pilot.load_cases()['cases']),150)

if __name__=='__main__': unittest.main()
