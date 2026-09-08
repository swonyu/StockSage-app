"""Offline boundary regression; no model, GPU or network needed."""
import copy
from pathlib import Path
import tempfile
import unittest

import intraday_chronos as c
import intraday_kronos as k
import intraday_research as r
from test_intraday_research import fixture


class ChronosTests(unittest.TestCase):
    def test_causal_inputs_forecast_contract_and_assets(self):
        bars=fixture(); signal=bars[100]['t']
        inputs=k.first_contexts(bars,['AAPL'])['AAPL']
        task=c.task_input(inputs)
        self.assertEqual(set(task),{'target','past_covariates'})
        self.assertEqual(set(task['past_covariates']),{'high','low','close'})
        self.assertEqual(task['target'],[b['o'] for b in bars[:100]])
        past=k.first_contexts([b for b in bars if b['t']<signal],['AAPL'])['AAPL']
        self.assertEqual(task,c.task_input(past))
        task['target'][0]=99999
        self.assertNotEqual(task['target'][0],inputs['ohlc'][0][0])
        quantiles=[[99+i,100+i,101+i] for i in range(22)]
        result=c.summarize(quantiles)
        self.assertEqual(result['median_open_ratio_by_delay'],{'1':116/101-1,'6':121/106-1})
        self.assertEqual(result['crossed_steps'],0)
        crossed=copy.deepcopy(quantiles); crossed[0]=[101,100,99]
        self.assertEqual(c.summarize(crossed)['crossed_steps'],1)
        self.assertEqual(crossed[0],[101,100,99])  # No silent repair.
        for bad in (quantiles[:-1],[[1,2]]*22,[[1,True,3]]*22,
                    [[1,float('nan'),3]]*22,[[1,0,3]]*22,[[1,float('inf'),3]]*22):
            with self.assertRaises(r.ResearchError): c.summarize(bad)
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(r.ResearchError): c.verify_assets(Path(temporary))
            (Path(temporary)/'config.json').write_text('{}')
            with self.assertRaises(r.ResearchError): c.verify_assets(Path(temporary))


if __name__=='__main__': unittest.main()
