#!/usr/bin/env python3
"""Pinned, CPU-only Kronos compatibility smoke. No download, training or trading."""
import argparse
from datetime import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import resource
import signal
import sys
import time

import intraday_research as r

SOURCE_REVISION='67b630e67f6a18c9e9be918d9b4337c960db1e9a'
MODEL_REVISION='901c26c1332695a2a8f243eb2f37243a37bea320'
TOKENIZER_REVISION='0e0117387f39004a9016484a186a908917e22426'
ASSETS={
    'model/__init__.py':(412,'f8f856ca3fedadcaac97e196be23d1aeda1c3c9ffe8903d66d43ea3bcac6240c'),
    'model/module.py':(23426,'a07edbadc0e96804c8158c021bbc6063bb7cc43b34d7fc470d5c8ff2005a409f'),
    'model/kronos.py':(30133,'0a5f90282e2039c2de0771473419715c845def154896dbd0f5747837e6241032'),
    'LICENSE':(1062,'acb2d194d378204e5f2be4dcd24d39ecac437903620c790c3315a96dab388fdc'),
    'predictor/config.json':(228,'5e0f6a605d5f81b5c9b559fe5cf716a1acb041c744e6f41bd05b097b7a685396'),
    'predictor/model.safetensors':(98980656,'b082dfcbd8e8c142a725c8bbb99781802f38fec81210e13479effb32b3c3e020'),
    'tokenizer/config.json':(301,'2366e7ccfec76cbc19cf3c4c1b9c5d901be336ca1e83f2d2292c9bff381b77a2'),
    'tokenizer/model.safetensors':(15842368,'59d85f6af76a2c3b8240ea06cb21db4213b4eeca053f246b23e29cf832fc6bee'),
}


def verify_assets(root):
    root=Path(root)
    try:
        for name,(size,sha) in ASSETS.items():
            path=root/name
            if path.is_symlink() or path.stat().st_size!=size or r.digest(path)!=sha:
                raise r.ResearchError('Pinned Kronos asset mismatch; import refused.')
        # Avoid an unchecked extension/bytecode taking precedence over reviewed Python.
        if {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()}!=set(ASSETS):
            raise r.ResearchError('Unexpected file in pinned Kronos assets; import refused.')
    except OSError:
        raise r.ResearchError('Pinned Kronos assets missing/unreadable; no automatic download.') from None


def context(bars,symbol,signal_t):
    if type(signal_t) is not int or signal_t%(5*r.MINUTE):
        raise r.ResearchError('Signal must be a completed five-minute boundary.')
    rows=sorted((b for b in bars if b['symbol']==symbol and signal_t-100*r.MINUTE<=b['t']<signal_t),key=lambda b:b['t'])
    expected=[signal_t-i*r.MINUTE for i in range(100,0,-1)]
    future=[signal_t+i*r.MINUTE for i in range(22)]
    if [b['t'] for b in rows]!=expected or any(not r.regular(t) or r.ny_date(t)!=r.ny_date(signal_t) for t in expected+future):
        raise r.ResearchError('Context must contain100 unique consecutive completed same-session minutes.')
    values=[[b[k] for k in ('o','h','l','c')] for b in rows]
    for o,h,l,c in values:
        if not all(type(v) in (int,float) and math.isfinite(v) and v>0 for v in (o,h,l,c)) or not l<=min(o,c)<=max(o,c)<=h:
            raise r.ResearchError('Context OHLC prices are invalid.')
    return {'ohlc':values,'x_t':expected,'y_t':future}


def forecast_return(opens,delay):
    if delay not in (1,6) or len(opens)!=22 or any(type(v) not in (int,float) or not math.isfinite(v) or v<=0 for v in opens):
        raise r.ResearchError('Expected22 finite positive forecast opens and delay1 or6.')
    return opens[delay+15]/opens[delay]-1


def first_contexts(bars,symbols):
    if not bars or not 1<=len(symbols)<=10 or len(set(symbols))!=len(symbols):
        raise r.ResearchError('Smoke requires1–10 unique first-session symbols and archived bars.')
    first_day=min(r.ny_date(b['t']) for b in bars)
    # The event is chosen from the session clock, never availability of future labels.
    signal_t=int(datetime.fromisoformat(first_day+'T11:10:00').replace(tzinfo=r.NY).timestamp()*1000)
    return {symbol:context(bars,symbol,signal_t) for symbol in sorted(symbols)}


def peak_bytes():
    value=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return value if sys.platform=='darwin' else value*1024


def smoke(archive,assets,output):
    assets=Path(assets).resolve(); verify_assets(assets)
    if 'model' in sys.modules: raise r.ResearchError('Conflicting imported model package; use a fresh process.')
    manifest,bars=r.load_archive(archive)
    selected=first_contexts(bars,manifest['symbols'])
    output=r.private_directory(output)
    recipe={'schema':1,'status':'compatibility only','promotable':False,'archive_sha256':manifest['archive_sha256'],
            'runner_sha256':r.digest(__file__),'base_sha256':r.digest(r.__file__),
            'source_revision':SOURCE_REVISION,'model_revision':MODEL_REVISION,'tokenizer_revision':TOKENIZER_REVISION,
            'assets':ASSETS,'device':'cpu','threads':1,'seed':7,'T':1.0,'top_p':.9,'top_k':0,'sample_count':1,
            'input':'100 completed1m OHLC bars; volume/amount omitted, not observed zero',
            'target':'forecast minute opens[d+15]/opens[d]-1; d=1,6; no realized labels supplied',
            'events':{s:v['y_t'][0] for s,v in selected.items()},'created_at':r.utc_now()}
    r.write_json(output/'recipe.json',recipe)
    start=time.perf_counter()
    def timeout(*_): raise r.ResearchError('Five-minute compatibility ceiling exceeded.')
    previous=signal.signal(signal.SIGALRM,timeout); signal.alarm(300)
    try:
        os.environ['HF_HUB_OFFLINE']='1'; os.environ['HF_HUB_DISABLE_IMPLICIT_TOKEN']='1'
        sys.dont_write_bytecode=True
        import numpy as np
        import pandas as pd
        import torch
        import safetensors
        from safetensors.torch import load_model
        torch.set_num_threads(1); torch.set_num_interop_threads(1)
        torch.use_deterministic_algorithms(True)
        sys.path.insert(0,str(assets))
        from model import Kronos,KronosTokenizer,KronosPredictor
        tokenizer=KronosTokenizer(**json.loads((assets/'tokenizer/config.json').read_text())).eval()
        model=Kronos(**json.loads((assets/'predictor/config.json').read_text())).eval()
        load_model(tokenizer,str(assets/'tokenizer/model.safetensors'),device='cpu')
        load_model(model,str(assets/'predictor/model.safetensors'),device='cpu')
        predictor=KronosPredictor(model,tokenizer,device='cpu',max_context=512)
        load_seconds=time.perf_counter()-start; results=[]
        if peak_bytes()>2_000_000_000: raise r.ResearchError('Two-GB compatibility memory ceiling exceeded.')
        for symbol,inputs in selected.items():
            frame=pd.DataFrame(inputs['ohlc'],columns=['open','high','low','close'])
            def timestamps(values):
                return pd.Series(pd.to_datetime(values,unit='ms',utc=True).tz_convert(r.NY).tz_localize(None))
            xs,ys=timestamps(inputs['x_t']),timestamps(inputs['y_t'])
            trials=[]; durations=[]
            for _ in range(2):
                torch.manual_seed(7); np.random.seed(7); tick=time.perf_counter()
                with torch.inference_mode():
                    prediction=predictor.predict(frame,xs,ys,pred_len=22,T=1.0,top_p=.9,top_k=0,sample_count=1,verbose=False)
                durations.append(time.perf_counter()-tick)
                if list(prediction.index)!=list(ys): raise r.ResearchError('Forecast timestamp alignment failed.')
                trials.append(prediction[['open','high','low','close']].to_numpy())
                if peak_bytes()>2_000_000_000: raise r.ResearchError('Two-GB compatibility memory ceiling exceeded.')
            if not np.array_equal(trials[0],trials[1]): raise r.ResearchError('Seeded forecast replay differs.')
            opens=trials[0][:,0].tolist()
            returns={str(d):forecast_return(opens,d) for d in (1,6)}
            violations=sum(not (all(math.isfinite(float(v)) and v>0 for v in (o,h,l,c)) and l<=min(o,c)<=max(o,c)<=h)
                           for o,h,l,c in trials[0])
            results.append({'symbol':symbol,'signal_t':inputs['y_t'][0],'opens':opens,'predicted_return_by_delay':returns,
                            'ohlc_invariant_violations':violations,'replay_identical':True,'seconds':durations,
                            'input_sha256':hashlib.sha256(json.dumps(inputs,sort_keys=True).encode()).hexdigest()})
        report={**recipe,'status':'compatibility smoke completed','load_seconds':load_seconds,
                'wall_seconds':time.perf_counter()-start,'peak_rss_bytes':peak_bytes(),
                'versions':{'torch':torch.__version__,'numpy':np.__version__,'pandas':pd.__version__,'safetensors':safetensors.__version__},
                'results':results,'limitations':['No trading performance or prediction accuracy measured.',
                    '1m OHLC-only inputs differ from5m engineered OHLCV features; equal100-minute elapsed context only.',
                    'One sampled path is stochastic; seed replay is reproducibility, not uncertainty calibration.',
                    'Forecast prices are generated hypotheses, not verified market facts; invalid OHLC is counted.',
                    'Future comparison requires prespecified development/holdout dates and the same costs/account simulator.']}
        r.write_json(output/'report.json',report)
        return report
    except Exception as error:
        r.write_json(output/'failure.json',{'status':'failed','error_type':type(error).__name__,'peak_rss_bytes':peak_bytes()})
        raise
    finally:
        signal.alarm(0); signal.signal(signal.SIGALRM,previous)


def main():
    os.umask(0o077)
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive',type=Path,required=True)
    parser.add_argument('--assets',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    try:
        result=smoke(args.archive,args.assets,args.output)
        print(json.dumps({'status':result['status'],'events':len(result['results']),
                          'wall_seconds':result['wall_seconds'],'peak_rss_bytes':result['peak_rss_bytes'],'promotable':False}))
    except Exception as error:
        print('Kronos stopped: '+(str(error) if isinstance(error,r.ResearchError) else type(error).__name__),file=sys.stderr)
        return 1
    return 0


if __name__=='__main__': sys.exit(main())
