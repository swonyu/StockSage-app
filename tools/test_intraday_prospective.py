"""Prospective timing/replay checks; synthetic bars never constitute evidence."""
import copy
import fcntl
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import intraday_comparison as p
import intraday_prospective as q
import intraday_research as r
from test_intraday_research import fixture, payload


class FakeClock:
    def __init__(self,value): self.value=value
    def read(self): return self.value


def frozen(temporary):
    root=Path(temporary)/'pilot'; clock=FakeClock(q.schedule()[0]-10*r.MINUTE)
    with patch.object(p.k,'verify_assets'),patch.object(p.c,'verify_assets'):
        q.initialize(root,clock)
    return root,clock


def fake_fetch(symbol,day,end,clock):
    bars=[b for b in fixture(symbol,day) if b['t']<=clock.read()]
    return json.dumps(payload(bars,symbol)).encode()


def fake_worker(group,batch,output,seconds):
    events=q.read(batch)['events']; r.private_directory(output)
    rows=[{'id':e['id'],'returns':{'1':.001,'6':.002}} for e in events]
    values={'candidate':group,'bundle_sha256':r.digest(batch),'sources':p.source_hashes()}
    if group=='baselines': values['candidates']={n:rows for n in q.NAMES[:4]}
    else: values['rows']=rows
    q.durable(output/'predictions.json',values)


class ProspectiveTests(unittest.TestCase):
    def test_causal_features_match_historical_math(self):
        bars=fixture()
        for sample in r.examples(bars,15,6)[0]:
            t=sample['signal_t']
            event=q.event_input(bars,'AAPL',t)
            self.assertEqual(event['x'],sample['x'])
            self.assertEqual(event,q.event_input([b for b in bars if b['t']<t],'AAPL',t))
        with self.assertRaises(r.ResearchError): q.event_input(bars[1:],'AAPL',bars[100]['t'])

    def test_context_trust_boundary_before_optional_imports(self):
        e=q.event_input(fixture(),'AAPL',fixture()[100]['t'])
        p.validate_events([e])
        for mutate in (lambda x:x['context']['y_t'].pop(),
                       lambda x:x['context']['x_t'].reverse(),
                       lambda x:x['context']['ohlc'][0].append(1),
                       lambda x:x.update(id='foreign')):
            bad=copy.deepcopy(e); mutate(bad)
            with self.assertRaises(r.ResearchError): p.validate_events([bad])
        with self.assertRaises(r.ResearchError): p.validate_events([e,e])

    def test_schedule_waiting_lock_and_private_immutability(self):
        self.assertEqual(len(q.schedule()),90)
        self.assertEqual(q.schedule()[-1],q.at(q.DAYS[-1],'15:25'))
        with tempfile.TemporaryDirectory() as temp:
            root,clock=frozen(temp); calls=[]
            self.assertEqual(q.tick(root,lambda:calls.append('fetch'),clock=clock)['status'],'waiting')
            self.assertEqual(calls,[])
            with (root/'tick.lock').open('a') as lock:
                fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                self.assertEqual(q.tick(root,clock=clock)['status'],'already_running')
            self.assertEqual((root/'recipe.json').stat().st_mode&0o777,0o600)
            with self.assertRaises(FileExistsError): q.durable(root/'recipe.json',{})
            with (root/'recipe.json').open('a') as handle: handle.write(' ')
            with self.assertRaises(r.ResearchError): q.tick(root,clock=clock)

    def test_exact_missed_deadline_and_restart_never_retry(self):
        with tempfile.TemporaryDirectory() as temp:
            root,clock=frozen(temp); clock.value=q.schedule()[0]+6*r.MINUTE; calls=[]
            result=q.tick(root,lambda:calls.append('fetch'),clock=clock)
            self.assertEqual(result['actions'],['missed_deadline'])
            self.assertEqual(q.tick(root,lambda:calls.append('fetch'),clock=clock)['status'],'waiting')
            self.assertEqual(calls,[])
            next_t=q.schedule()[1]; clock.value=next_t+20_000
            folder=r.private_directory(root/str(next_t))
            q.durable(folder/'started.json',{'observed_at_ms':clock.value,'signal_t':next_t})
            self.assertEqual(q.tick(root,lambda:calls.append('fetch'),clock=clock)['actions'],['interrupted_no_retry'])
            clock.value=q.schedule()[0]-1
            with self.assertRaises(r.ResearchError): q.tick(root,clock=clock)

    def test_ready_time_not_start_time_and_equality_is_late(self):
        with tempfile.TemporaryDirectory() as temp:
            root,clock=frozen(temp); t=q.schedule()[0]; clock.value=t+10_000; calls=[]
            def runner(group,batch,output,seconds):
                calls.append((group,seconds)); fake_worker(group,batch,output,seconds)
                clock.value+=dict(baselines=49_999,kronos=1,chronos=300_000)[group]
            q.tick(root,lambda:lambda *a:fake_fetch(*a,clock),runner,clock)
            folder=root/str(t)
            self.assertEqual(q.read(folder/'baselines.receipt.json')['eligible'],{'1':True,'6':True})
            self.assertEqual(q.read(folder/'kronos.receipt.json')['eligible'],{'1':False,'6':True})
            self.assertEqual(q.read(folder/'chronos.receipt.json')['eligible'],{'1':False,'6':False})
            self.assertTrue(all(0<seconds<=120 for _,seconds in calls))
            q.tick(root,lambda:lambda *a:fake_fetch(*a,clock),runner,clock)
            self.assertEqual(len(calls),3)
            self.assertTrue(all(max(e['context']['x_t'])<t for e in q.read(folder/'inputs.json')['events']))

    def test_missing_or_delayed_context_is_not_a_partial_success(self):
        for invalid in ('gap','delayed'):
            with tempfile.TemporaryDirectory() as temp:
                root,clock=frozen(temp); t=q.schedule()[0]; clock.value=t+1000; called=[]
                def fetch(symbol,day,end):
                    value=json.loads(fake_fetch(symbol,day,end,clock))
                    if invalid=='gap':
                        value['results'].pop(0); value['resultsCount']-=1
                    else: value['status']='DELAYED'
                    return json.dumps(value).encode()
                q.tick(root,lambda:fetch,lambda *a:called.append(1),clock)
                self.assertEqual(q.read(root/str(t)/'result.json')['status'],'input_failed')
                self.assertFalse((root/str(t)/'inputs.json').exists())
                self.assertEqual(called,[])

    def test_outcomes_are_later_separate_hash_checked_and_keep_denominator(self):
        with tempfile.TemporaryDirectory() as temp:
            root,clock=frozen(temp); t=q.schedule()[0]; clock.value=t+1000
            q.tick(root,lambda:lambda *a:fake_fetch(*a,clock),fake_worker,clock)
            prediction=root/str(t)/'kronos/predictions.json'; before=r.digest(prediction)
            folder=r.private_directory(root/'score-fixture')
            bars=[b for s in p.SYMBOLS for b in fixture(s,q.DAYS[0])]
            with self.assertRaises(r.ResearchError): q.score_day(root,q.DAYS[0],folder,bars,clock)
            clock.value=q.at(q.DAYS[0],'16:01')
            q.score_day(root,q.DAYS[0],folder,bars,clock)
            result=q.read(folder/'scores.json')
            self.assertEqual(result['denominator'],2160)
            self.assertEqual(result['scored'],120)
            self.assertEqual(result['common_six_model_symbol_delay_events'],20)
            self.assertEqual(before,r.digest(prediction))
            with prediction.open('a') as handle: handle.write(' ')
            with self.assertRaises(r.ResearchError): q.score_day(root,q.DAYS[0],folder,bars,clock)

    def test_clock_discontinuities_fail_closed(self):
        with patch.object(q.time,'time_ns',side_effect=[1_000_000_000,1_001_000_000,999_000_000]), \
             patch.object(q.time,'monotonic_ns',side_effect=[0,1_000_000,2_000_000]):
            clock=q.Clock(); self.assertEqual(clock.read(),1001)
            with self.assertRaises(r.ResearchError): clock.read()
        with patch.object(q.time,'time_ns',side_effect=[1_000_000_000,4_000_000_000]), \
             patch.object(q.time,'monotonic_ns',side_effect=[0,1_000_000]):
            with self.assertRaises(r.ResearchError): q.Clock().read()

    def test_empty_reservation_is_an_interruption_not_a_replay(self):
        with tempfile.TemporaryDirectory() as temp:
            root,clock=frozen(temp); t=q.schedule()[0]; clock.value=t+1000
            r.private_directory(root/str(t)); called=[]
            result=q.tick(root,lambda:called.append('fetch'),clock=clock)
            self.assertEqual(result['actions'],['interrupted_no_retry'])
            self.assertEqual(called,[])

    def test_after_close_collection_is_once_and_labels_stay_out_of_worker(self):
        with tempfile.TemporaryDirectory() as temp:
            root,clock=frozen(temp); t=q.schedule()[0]; clock.value=t+1000; called=[]
            def fetch(symbol,day,end):
                called.append(symbol); return fake_fetch(symbol,day,end,clock)
            q.tick(root,lambda:fetch,fake_worker,clock)
            self.assertEqual(len(called),10)
            clock.value=q.at(q.DAYS[0],'16:01')
            result=q.tick(root,lambda:fetch,fake_worker,clock)
            self.assertEqual(result['actions'].count('missed_deadline'),17)
            self.assertIn('outcomes_scored',result['actions'])
            self.assertEqual(len(called),20)
            q.tick(root,lambda:fetch,fake_worker,clock)
            self.assertEqual(len(called),20)
            self.assertEqual(q.read(root/('outcomes-'+q.DAYS[0])/'scores.json')['scored'],120)

    def test_future_dated_provider_rows_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            clock=FakeClock(q.schedule()[0])
            fetch=lambda s,d,e:json.dumps(payload(fixture(s,d),s)).encode()
            with self.assertRaises(r.ResearchError):
                q.snapshot(Path(temp),'AAPL',q.DAYS[0],fetch,clock)


if __name__=='__main__': unittest.main()
