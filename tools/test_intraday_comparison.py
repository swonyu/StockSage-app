"""Fixed-schedule and strict event-join regression; no optional models/network."""
import copy
from pathlib import Path
import tempfile
import unittest

import intraday_comparison as p
import intraday_research as r


class ComparisonTests(unittest.TestCase):
    def test_fixed_schedule_and_fail_closed_join(self):
        events=p.schedule()
        self.assertEqual(len(events),250)
        self.assertEqual(len({e['id'] for e in events}),250)
        self.assertEqual({r.ny_date(e['signal_t']) for e in events},set(p.DAYS))
        predictions=[{'id':e['id'],'returns':{'1':.001,'6':.002}} for e in events]
        self.assertEqual(p.aligned(events,list(reversed(predictions)),1),[.001]*250)
        for bad in (predictions[:-1],predictions+[predictions[0]],
                    [{'id':'foreign','returns':{'1':0.,'6':0.}}]+predictions[1:]):
            with self.assertRaises(r.ResearchError): p.aligned(events,bad,1)
        for value in (float('nan'),float('inf'),True,'0.01'):
            bad=copy.deepcopy(predictions); bad[0]['returns']['1']=value
            with self.assertRaises(r.ResearchError): p.aligned(events,bad,1)
        bad=copy.deepcopy(predictions); del bad[0]['returns']['6']
        with self.assertRaises(r.ResearchError): p.aligned(events,bad,6)
        with self.assertRaises(r.ResearchError): p.aligned(events,predictions,0)

    def test_source_and_input_hashes_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            r.write_json(root/'recipe.json',{'sources':p.source_hashes(),'events':p.schedule()})
            r.write_json(root/'inputs.json',{'events':p.schedule()})
            r.write_json(root/'bundle.json',{'schema':1,'recipe_sha256':r.digest(root/'recipe.json'),
                'files':{'inputs.json':r.digest(root/'inputs.json')}})
            self.assertEqual(p.load_bundle(root,'inputs.json'),{'events':p.schedule()})
            with (root/'inputs.json').open('a') as handle: handle.write(' ')
            with self.assertRaises(r.ResearchError): p.load_bundle(root,'inputs.json')
            with self.assertRaises(r.ResearchError): p.load_bundle(root,'../inputs.json')

    def test_valid_hashes_cannot_hide_partial_schedule(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            r.write_json(root/'recipe.json',{'sources':p.source_hashes(),'events':p.schedule()})
            r.write_json(root/'inputs.json',{'events':p.schedule()[:-1]})
            r.write_json(root/'bundle.json',{'schema':1,'recipe_sha256':r.digest(root/'recipe.json'),
                'files':{'inputs.json':r.digest(root/'inputs.json')}})
            with self.assertRaises(r.ResearchError): p.load_bundle(root,'inputs.json')


if __name__=='__main__': unittest.main()
