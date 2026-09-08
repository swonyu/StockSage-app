"""Offline regression gate; synthetic prices are never investment evidence."""
from datetime import datetime, timedelta
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from zoneinfo import ZoneInfo

import intraday_research as r


def fixture(symbol="AAPL", day="2026-08-31", slope=0.01):
    start = datetime.fromisoformat(day + "T09:30:00").replace(tzinfo=ZoneInfo("America/New_York"))
    rows = []
    for i in range(390):
        price = 100 + slope * i
        rows.append({"symbol": symbol, "t": int((start + timedelta(minutes=i)).timestamp()*1000),
                     "o": price, "h": price+0.03, "l": price-0.02,
                     "c": price+0.01, "v": 1000+i})
    return rows


def payload(rows, symbol="AAPL"):
    return {"ticker": symbol, "status": "OK", "adjusted": False,
            "resultsCount": len(rows), "results": [{k:v for k,v in x.items() if k != "symbol"} for x in rows]}


class ResearchTests(unittest.TestCase):
    def test_payload_contract(self):
        bars = fixture()
        self.assertEqual(len(r.validate_payload(payload(bars), "AAPL", "2026-08-31", "2026-09-04")),390)
        for field, value in [("ticker","MSFT"),("adjusted",True),("status","ERROR"),
                             ("resultsCount",2),("next_url","https://untrusted.example")]:
            bad = payload(bars); bad[field] = value
            with self.subTest(field=field), self.assertRaises(r.ResearchError):
                r.validate_payload(bad,"AAPL","2026-08-31","2026-09-04")

    def test_bad_bars_fail_closed(self):
        for field,value in [("o",float("nan")),("v",-1),("h",1),("t",123),
                            ("c",True),("l",0),("v",float("inf")),("v",10**1000)]:
            rows = fixture(); rows[0][field] = value
            with self.subTest(field=field), self.assertRaises(r.ResearchError):
                r.validate_payload(payload(rows),"AAPL","2026-08-31","2026-09-04")
        for rows in [fixture()[::-1],fixture()[:1]*2]:
            with self.assertRaises(r.ResearchError):
                r.validate_payload(payload(rows),"AAPL","2026-08-31","2026-09-04")
        with self.assertRaises(r.ResearchError):
            r.validate_payload(payload(fixture()),"AAPL","2026-09-01","2026-09-04")

    def test_redirects_are_never_followed(self):
        self.assertIsNone(r.NoRedirect().redirect_request(None,None,302,"redirect",{},"https://other.example"))

    def test_collection_and_hash_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)/"archive"
            m = r.collect(["AAPL"],"2026-08-31","2026-08-31",path,
                          lambda *a: json.dumps(payload(fixture())).encode())
            self.assertEqual(m["status"],"complete")
            self.assertEqual(len(r.load_archive(path)[1]),390)
            self.assertEqual((path/"archive.sqlite3").stat().st_mode & 0o777,0o600)
            with self.assertRaises(r.ResearchError):
                r.collect(["AAPL"],"2026-08-31","2026-08-31",path,lambda *a: b"")
            with (path/"archive.sqlite3").open("ab") as handle:
                handle.write(b"corrupted")
            with self.assertRaises(r.ResearchError): r.load_archive(path)

    def test_collection_limits_precede_network(self):
        called = []
        with tempfile.TemporaryDirectory() as temporary:
            for symbols,start,end in [(["AAPL","AAPL"],"2026-08-31","2026-09-04"),
                                      (["../../AAPL"],"2026-08-31","2026-09-04"),
                                      (["AAPL"],"20260831","20260904"),
                                      (["AAPL"],"2026-08-01","2026-09-04"),
                                      (["AAPL"],"2026-09-04","2026-08-31")]:
                with self.assertRaises(r.ResearchError):
                    r.collect(symbols,start,end,Path(temporary)/"bad",lambda *a: called.append(1))
        self.assertEqual(called,[])

    def test_failed_collection_is_not_usable(self):
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/"bad"
            with self.assertRaises(r.ResearchError):
                r.collect(["AAPL"],"2026-08-31","2026-08-31",path,lambda *a:b'{"status":"ERROR"}')
            with self.assertRaises(r.ResearchError): r.load_archive(path)

    def test_completed_features_and_later_same_session_fills(self):
        samples,q = r.examples(fixture(),15,1)
        self.assertTrue(samples)
        for sample in samples:
            self.assertGreater(sample["entry_t"],sample["signal_t"])
            self.assertEqual(sample["exit_t"]-sample["entry_t"],15*60_000)
            self.assertEqual(sample["date"],r.ny_date(sample["exit_t"]))
        self.assertGreater(q["missing_or_overnight_labels"],0)

    def test_future_prices_cannot_change_features(self):
        original=fixture(); baseline,_=r.examples(original,15,1)
        cutoff=baseline[0]["signal_t"]
        changed=[dict(b) for b in original]
        for b in changed:
            if b["t"]>=cutoff:
                for k in ("o","h","l","c"): b[k]*=2
        altered,_=r.examples(changed,15,1)
        self.assertEqual(baseline[0]["x"],altered[0]["x"])
        self.assertNotEqual(baseline[0]["entry"],altered[0]["entry"])

    def test_gaps_are_not_filled(self):
        bars=fixture(); gap=bars[51]["t"]
        samples,q=r.examples([b for b in bars if b["t"]!=gap],15,1)
        self.assertGreater(q["incomplete_five_minute_buckets"],0)
        self.assertTrue(all(not (s["signal_t"]-100*60_000 <= gap < s["signal_t"]) for s in samples))

    def test_dst_uses_exchange_local_time(self):
        for day in ("2026-03-06","2026-03-09"):
            samples,_=r.examples(fixture(day=day),15,1)
            self.assertTrue(samples)
            self.assertEqual(samples[0]["date"],day)
        self.assertEqual(fixture(day="2026-03-06")[0]["t"]%86_400_000,
                         fixture(day="2026-03-09")[0]["t"]%86_400_000+3_600_000)

    def test_partition_whole_dates_and_purged_boundaries(self):
        bars=sum([fixture(day=d) for d in ("2026-08-31","2026-09-01","2026-09-02")],[])
        samples,_=r.examples(bars,15,1)
        train,valid,test=r.partition(samples,"2026-08-31","2026-09-01")
        self.assertLess(max(s["exit_t"] for s in train),min(s["signal_t"] for s in valid))
        self.assertLess(max(s["exit_t"] for s in valid),min(s["signal_t"] for s in test))
        with self.assertRaises(r.ResearchError): r.partition(samples,"2026-09-02","2026-09-03")

    def test_cash_costs_and_zero_prediction(self):
        bars=fixture(slope=0); samples,_=r.examples(bars,15,1); samples=samples[:1]
        no_trade=r.simulate(samples,[0],bars,0,5)
        self.assertEqual(no_trade["trades"],0)
        self.assertEqual(no_trade["net_return"],0)
        gross=r.simulate(samples,[.01],bars,0,0)
        net=r.simulate(samples,[.01],bars,0,5)
        self.assertEqual(gross["ending_equity"],10000)
        self.assertAlmostEqual(net["ending_equity"],9999.05)
        self.assertLess(net["net_return"],gross["net_return"])

    def test_position_caps_and_no_duplicate_symbol(self):
        bars=sum([fixture(symbol=s) for s in ("AAPL","MSFT","NVDA","AMZN","META","APP")],[])
        samples,_=r.examples(bars,15,1)
        result=r.simulate(samples,[.01]*len(samples),bars,0,10)
        self.assertLessEqual(result["max_positions"],5)
        self.assertGreaterEqual(result["minimum_cash"],0)
        self.assertLessEqual(result["max_entry_equity_fraction"],.20+1e-10)
        self.assertTrue(all(float(t["shares"]).is_integer() for t in result["trade_log"]))

    def test_missing_mark_fails_instead_of_hiding_drawdown(self):
        bars=fixture(); samples,_=r.examples(bars,15,1); samples=samples[:1]
        gap=samples[0]["entry_t"]+60_000
        with self.assertRaises(r.ResearchError):
            r.simulate(samples,[.01],[b for b in bars if b["t"]!=gap],0,5)

    def test_drawdown_marks_open_positions_between_entry_and_exit(self):
        bars=fixture(slope=0); samples,_=r.examples(bars,15,1); samples=samples[:1]
        dip=samples[0]["entry_t"]+5*60_000
        for b in bars:
            if b["t"]==dip: b["o"]=50
        result=r.simulate(samples,[.01],bars,0,0)
        self.assertEqual(result["ending_equity"],10000)
        self.assertAlmostEqual(result["max_drawdown"],.10)

    @unittest.skipUnless(importlib.util.find_spec("lightgbm"),"optional isolated LightGBM runtime")
    def test_lightgbm_fit_is_deterministic_and_training_only(self):
        bars=sum([fixture(day=d) for d in ("2026-08-31","2026-09-01","2026-09-02")],[])
        samples,_=r.examples(bars,15,1)
        train,valid,test=r.partition(samples,"2026-08-31","2026-09-01")
        predictors,metadata,_=r.fit_predictors(train,True)
        first=predictors["lightgbm"](test)
        for s in valid+test: s["y"]+=100
        again,_,_=r.fit_predictors(train,True)
        self.assertEqual(first,again["lightgbm"](test))
        self.assertEqual(metadata["parameters"]["num_threads"],1)
        self.assertEqual(metadata["training_rows"],len(train))

    def test_report_end_to_end_and_reproducibility(self):
        bars=sum([fixture(day=d) for d in ("2026-08-31","2026-09-01","2026-09-02")],[])
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            r.collect(["AAPL"],"2026-08-31","2026-09-02",root/"data",
                      lambda *a:json.dumps(payload(bars)).encode())
            first=r.benchmark(root/"data",root/"one","2026-08-31","2026-09-01",False)
            second=r.benchmark(root/"data",root/"two","2026-08-31","2026-09-01",False)
            self.assertFalse(first["promotable"])
            self.assertEqual(first["results"],second["results"])
            self.assertEqual(first["selection_partition"],"validation only")
            self.assertEqual(first["tried_policies"],12)
            self.assertEqual(len(first["results"]),24)
            self.assertTrue((root/"one"/"report.md").exists())
            with self.assertRaises(r.ResearchError):
                r.benchmark(root/"data",root/"one","2026-08-31","2026-09-01",False)


if __name__=="__main__": unittest.main()
