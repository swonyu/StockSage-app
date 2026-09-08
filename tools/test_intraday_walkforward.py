"""Calendar and multi-archive regression checks; all prices here are synthetic."""
from datetime import date, timedelta
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import intraday_research as r
import intraday_walkforward as w
from test_intraday_research import fixture, payload


def fake_fetch(symbol, start, end):
    rows=[]
    day=date.fromisoformat(start)
    while day<=date.fromisoformat(end):
        count=w.scheduled_minutes(day.isoformat())
        rows.extend(fixture(symbol,day.isoformat())[:count])
        day+=timedelta(days=1)
    return json.dumps(payload(rows,symbol)).encode()


class WalkforwardTests(unittest.TestCase):
    def test_sourced_calendar(self):
        self.assertEqual(w.scheduled_minutes("2026-07-02"),390)
        for day in ("2026-06-19","2026-07-03","2026-09-07","2026-12-25","2026-09-06"):
            self.assertEqual(w.scheduled_minutes(day),0)
        self.assertEqual(w.scheduled_minutes("2026-11-27"),210)
        self.assertEqual(w.scheduled_minutes("2026-12-24"),210)
        with self.assertRaises(r.ResearchError): w.scheduled_minutes("2027-01-04")

    def test_chunks_are_bounded_and_contiguous(self):
        parts=w.chunks("2026-06-01","2026-08-31")
        self.assertEqual(len(parts),7)
        self.assertEqual(parts[0][0],"2026-06-01")
        self.assertEqual(parts[-1][1],"2026-08-31")
        for start,end in parts: self.assertLess((date.fromisoformat(end)-date.fromisoformat(start)).days,14)
        for left,right in zip(parts,parts[1:]):
            self.assertEqual(date.fromisoformat(left[1])+timedelta(days=1),date.fromisoformat(right[0]))
        with self.assertRaises(r.ResearchError): w.chunks("2026-01-01","2026-08-31")

    def test_test_folds_never_overlap(self):
        days=w.session_dates("2026-06-01","2026-08-31")
        self.assertEqual(len(days),64)
        folds=w.fold_dates(days)
        self.assertEqual(len(folds),8)
        tests=[d for fold in folds for d in fold["test"]]
        self.assertEqual(tests,days[25:])
        self.assertEqual(len(tests),len(set(tests)))
        self.assertEqual(len(folds[-1]["test"]),4)
        for fold in folds:
            self.assertEqual(len(fold["train"]),20)
            self.assertEqual(len(fold["validation"]),5)
            self.assertLess(fold["train"][-1],fold["validation"][0])
            self.assertLess(fold["validation"][-1],fold["test"][0])

    def test_complete_collection_can_resume_without_network(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)/"study"
            w.collect_study(root,"2026-08-31","2026-09-02",["AAPL"],fetch=fake_fetch)
            study,bars,quality=w.load_study(root)
            self.assertTrue(quality["valid"])
            self.assertEqual(len(bars),1170)
            before=r.digest(root/"study.json")
            def forbidden(*args): self.fail("completed archive must not refetch")
            w.collect_study(root,"2026-08-31","2026-09-02",["AAPL"],resume=True,fetch=forbidden)
            self.assertEqual(before,r.digest(root/"study.json"))
            with self.assertRaises(r.ResearchError):
                w.collect_study(root,"2026-08-31","2026-09-02",["MSFT"],resume=True,fetch=forbidden)

    def test_missing_minute_is_a_quality_failure_not_silent_exclusion(self):
        def missing(symbol,start,end):
            p=json.loads(fake_fetch(symbol,start,end)); p["results"].pop(30); p["resultsCount"]-=1
            return json.dumps(p).encode()
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)/"study"
            w.collect_study(root,"2026-08-31","2026-09-02",["AAPL"],fetch=missing)
            _,_,quality=w.load_study(root)
            self.assertFalse(quality["valid"])
            self.assertEqual(quality["missing_minutes"],1)
            self.assertEqual(quality["issues"][0]["symbol"],"AAPL")
            with self.assertRaises(r.ResearchError): w.run_study(root,Path(temp)/"report")
            self.assertTrue((Path(temp)/"report"/"quality.json").exists())
            self.assertFalse((Path(temp)/"report"/"report.json").exists())

    def test_failed_attempt_is_retained_on_explicit_resume(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)/"study"
            with self.assertRaises(r.ResearchError):
                w.collect_study(root,"2026-08-31","2026-09-02",["AAPL"],fetch=lambda *a:b'{}')
            failed=next(root.glob("chunk-*-attempt1"))
            before=r.digest(failed/"archive.sqlite3")
            w.collect_study(root,"2026-08-31","2026-09-02",["AAPL"],resume=True,fetch=fake_fetch)
            self.assertEqual(before,r.digest(failed/"archive.sqlite3"))
            self.assertTrue(w.load_study(root)[2]["valid"])
            self.assertEqual(len(list(root.glob("chunk-*"))),2)

    def test_tampered_collection_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)/"study"
            w.collect_study(root,"2026-08-31","2026-09-02",["AAPL"],fetch=fake_fetch)
            original=r.digest
            def changed_recipe(path):
                return "changed" if Path(path).resolve()==Path(w.__file__).resolve() else original(path)
            with patch.object(r,"digest",side_effect=changed_recipe):
                with self.assertRaises(r.ResearchError): w.run_study(root,Path(temp)/"changed-code")
                with self.assertRaises(r.ResearchError):
                    w.collect_study(root,"2026-08-31","2026-09-02",["AAPL"],resume=True,fetch=fake_fetch)
            plan=json.loads((root/"study.json").read_text()); plan["symbols"]=["MSFT"]
            (root/"study.json").write_text(json.dumps(plan))
            with self.assertRaises(r.ResearchError): w.load_study(root)

    def test_capital_and_high_water_carry_across_folds(self):
        bars=fixture(slope=0); samples,_=r.examples(bars); samples=samples[:1]
        result=r.simulate(samples,[.01],bars,0,5,initial_equity=9000,prior_peak=11000)
        self.assertAlmostEqual(result["ending_equity"],8999.15)
        self.assertGreater(result["max_drawdown"],1-9000/11000)
        self.assertEqual(result["peak_equity"],11000)
        self.assertAlmostEqual(result["net_return"],8999.15/9000-1)
        with self.assertRaises(r.ResearchError):
            r.simulate(samples,[.01],bars,0,5,initial_equity=-1)

    @unittest.skipUnless(importlib.util.find_spec("lightgbm"),"optional isolated LightGBM runtime")
    def test_full_rolling_run_replays_and_preserves_capital(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            w.collect_study(root/"study","2026-06-01","2026-07-16",["AAPL"],fetch=fake_fetch)
            first=w.run_study(root/"study",root/"one")
            second=w.run_study(root/"study",root/"two")
            self.assertFalse(first["promotable"])
            self.assertEqual(len(first["folds"]),2)
            self.assertEqual(first["test_sessions"],7)
            self.assertEqual(first["folds"],second["folds"])
            self.assertEqual(first["results"],second["results"])
            self.assertEqual(len(first["results"]),32)
            prior,later=first["folds"]
            for left,right,total in zip(prior["test"],later["test"],first["results"]):
                self.assertEqual(left["ending_equity"],right["initial_equity"])
                self.assertEqual(total["ending_equity"],right["ending_equity"])
                self.assertGreaterEqual(total["max_drawdown"],left["max_drawdown"])
                self.assertEqual(len(total["daily_equity"]),7)
                self.assertGreaterEqual(right["minimum_cash"],0)
            self.assertTrue(any(x["initial_equity"]!=10000 for x in later["test"]))


if __name__=="__main__": unittest.main()
