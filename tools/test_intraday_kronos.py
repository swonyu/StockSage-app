"""Causal time-series input/output checks; never network/model downloads."""
from pathlib import Path
import tempfile
import unittest

import intraday_research as r
import intraday_kronos as k
from test_intraday_research import fixture


class KronosTests(unittest.TestCase):
    def test_event_selection_needs_no_future_bars(self):
        bars=fixture(); signal=bars[100]['t']
        expected=k.first_contexts(bars,['AAPL'])
        self.assertEqual(expected,k.first_contexts([b for b in bars if b['t']<signal],['AAPL']))
        self.assertEqual(expected['AAPL']['y_t'][0],signal)

    def test_context_has_only_completed_prices(self):
        bars=fixture(); signal=bars[100]['t']
        first=k.context(bars,'AAPL',signal)
        for bar in bars:
            if bar['t']>=signal:
                for field in ('o','h','l','c'): bar[field]*=10
        self.assertEqual(first,k.context(bars,'AAPL',signal))
        self.assertEqual(len(first['ohlc']),100)
        self.assertEqual(first['x_t'][-1],signal-r.MINUTE)
        self.assertEqual(first['y_t'],[signal+i*r.MINUTE for i in range(22)])
        self.assertEqual(set(first),{'ohlc','x_t','y_t'})

    def test_gaps_duplicates_and_session_crossings_are_rejected(self):
        bars=fixture(); signal=bars[100]['t']
        for bad in (bars[1:],bars+[bars[0]],fixture(day='2026-09-01')):
            with self.assertRaises(r.ResearchError): k.context(bad,'AAPL',signal)
        with self.assertRaises(r.ResearchError): k.context(bars,'MSFT',signal)
        with self.assertRaises(r.ResearchError): k.context(bars,'AAPL',signal+1)
        bars[0]['o']=float('nan')
        with self.assertRaises(r.ResearchError): k.context(bars,'AAPL',signal)

    def test_forecast_prices_use_exact_delay_and_horizon(self):
        prices=list(range(100,122))
        self.assertEqual(k.forecast_return(prices,1),116/101-1)
        self.assertEqual(k.forecast_return(prices,6),121/106-1)
        for bad in (prices[:-1],[float('nan')]*22,[0]*22,[-1]*22,[True]*22):
            with self.assertRaises(r.ResearchError): k.forecast_return(bad,1)
        with self.assertRaises(r.ResearchError): k.forecast_return(prices,0)

    def test_unknown_assets_never_import(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(r.ResearchError): k.verify_assets(Path(temp))
            p=Path(temp)/'model'; p.mkdir()
            (p/'__init__.py').write_text('raise AssertionError("must not import")')
            with self.assertRaises(r.ResearchError): k.verify_assets(Path(temp))


if __name__=='__main__': unittest.main()
