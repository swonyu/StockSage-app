#!/usr/bin/env python3
"""Bounded offline Chronos-2 CPU compatibility check; never training or trading."""
import argparse
import hashlib
import importlib.metadata as metadata
import json
import math
import os
from pathlib import Path
import signal
import sys
import time

import intraday_kronos as k
import intraday_research as r

MODEL_REVISION='29ec3766d36d6f73f0696f85560a422f50e8498c'
ASSETS={
    'config.json':(1067,'ef1143bfdc9c0376d9a056eefca46cb4b1ec3d0ffacd541ff56feb40fb708031'),
    'model.safetensors':(477930472,'ddcda3c7508bf2528087723e98a20707cc04b7f370ae275a9fd88078ddba4f42'),
}
VERSIONS={'chronos-forecasting':'2.3.1','torch':'2.14.0','transformers':'5.16.1',
          'accelerate':'1.14.0','numpy':'2.2.6','pandas':'2.2.2','einops':'0.8.1','safetensors':'0.8.0'}


def verify_assets(root):
    root=Path(root)
    try:
        if {p.name for p in root.iterdir()}!=set(ASSETS):
            raise r.ResearchError('Expected only pinned Chronos config and safetensors; no automatic download.')
        for name,(size,sha) in ASSETS.items():
            path=root/name
            if path.is_symlink() or path.stat().st_size!=size or r.digest(path)!=sha:
                raise r.ResearchError('Chronos asset checksum/size failed; load refused.')
    except OSError:
        raise r.ResearchError('Chronos assets missing/unreadable; no automatic download.') from None


def task_input(context):
    # Reuse the validated causal OHLC context; never pass y_t or observed labels.
    columns=list(zip(*context['ohlc']))
    return {'target':list(columns[0]),
            'past_covariates':{name:list(columns[i]) for i,name in enumerate(('high','low','close'),1)}}


def summarize(quantiles):
    if (len(quantiles)!=22 or any(len(row)!=3 for row in quantiles)
        or any(type(x) not in (int,float) or not math.isfinite(x) or x<=0 for row in quantiles for x in row)):
        raise r.ResearchError('Expected22 positive finite open-price quantile triples.')
    medians=[row[1] for row in quantiles]
    return {'median_open_ratio_by_delay':{str(d):k.forecast_return(medians,d) for d in (1,6)},
            'crossed_steps':sum(not low<=mid<=high for low,mid,high in quantiles)}


def smoke(archive,assets,output):
    assets=Path(assets).resolve(); verify_assets(assets)
    if any(metadata.version(name)!=version for name,version in VERSIONS.items()):
        raise r.ResearchError('Chronos runtime version mismatch; use the isolated pinned environment.')
    manifest,bars=r.load_archive(archive)
    selected=k.first_contexts(bars,manifest['symbols'])
    output=r.private_directory(output)
    distribution=metadata.distribution('chronos-forecasting')
    recipe={'schema':1,'status':'compatibility only','promotable':False,
            'archive_sha256':manifest['archive_sha256'],'model_revision':MODEL_REVISION,'assets':ASSETS,
            'runner_sha256':r.digest(__file__),'bridge_sha256':r.digest(k.__file__),'base_sha256':r.digest(r.__file__),
            'package_source_hashes':{str(p):r.digest(distribution.locate_file(p)) for p in distribution.files
                                     if str(p).startswith('chronos/') and str(p).endswith('.py')},
            'versions':VERSIONS,'device':'cpu','dtype':'float32','threads':1,'seed':7,
            'context_length':100,'prediction_length':22,'quantiles':[.1,.5,.9],
            'cross_learning':False,'input':'completed1m opens with past-only high/low/close; no future covariates',
            'target':'ratio of marginal median opens[d+15]/opens[d]-1, d=1,6; NOT median return',
            'events':{s:v['y_t'][0] for s,v in selected.items()},'created_at':r.utc_now()}
    r.write_json(output/'recipe.json',recipe)
    start=time.perf_counter()
    def timeout(*_): raise r.ResearchError('Five-minute compatibility ceiling exceeded.')
    def offline(event,args):
        if event in ('socket.connect','socket.getaddrinfo','socket.sendto'):
            raise r.ResearchError('Network access refused in offline compatibility process.')
    def memory_check():
        if k.peak_bytes()>2_000_000_000: raise r.ResearchError('Two-GB compatibility memory ceiling exceeded.')
    previous=signal.signal(signal.SIGALRM,timeout); signal.alarm(300)
    try:
        os.environ['HF_HUB_OFFLINE']='1'; os.environ['HF_HUB_DISABLE_IMPLICIT_TOKEN']='1'
        sys.addaudithook(offline)  # Process-local, intentionally cannot be disabled later.
        import numpy as np
        import torch
        from safetensors.torch import load_model
        from chronos.chronos2 import Chronos2CoreConfig,Chronos2Model,Chronos2Pipeline
        torch.set_num_threads(1); torch.set_num_interop_threads(1)
        torch.use_deterministic_algorithms(True); torch.manual_seed(7)
        with torch.device('cpu'):
            model=Chronos2Model(Chronos2CoreConfig(**json.loads((assets/'config.json').read_text())))
        load_model(model,str(assets/'model.safetensors'),device='cpu',strict=True)
        model=model.to(device='cpu',dtype=torch.float32).eval()
        predictor=Chronos2Pipeline(model)
        memory_check(); load_seconds=time.perf_counter()-start; results=[]
        for symbol,context in selected.items():
            raw=task_input(context)
            task={'target':np.asarray(raw['target'],dtype=np.float32),
                  'past_covariates':{name:np.asarray(values,dtype=np.float32) for name,values in raw['past_covariates'].items()}}
            trials=[]; durations=[]
            for _ in range(2):
                torch.manual_seed(7); np.random.seed(7); tick=time.perf_counter()
                with torch.inference_mode():
                    quantiles,_=predictor.predict_quantiles([task],prediction_length=22,quantile_levels=[.1,.5,.9],
                        context_length=100,batch_size=4,cross_learning=False,limit_prediction_length=True)
                durations.append(time.perf_counter()-tick); memory_check()
                if len(quantiles)!=1 or tuple(quantiles[0].shape)!=(1,22,3):
                    raise r.ResearchError('Chronos output shape/alignment failed.')
                trials.append(quantiles[0][0].cpu().numpy())
            if not np.array_equal(trials[0],trials[1]): raise r.ResearchError('Chronos replay differs.')
            prices=trials[0].tolist()
            results.append({'symbol':symbol,'signal_t':context['y_t'][0],'forecast_t':context['y_t'],
                            'open_quantiles':prices,**summarize(prices),'replay_identical':True,'seconds':durations,
                            'input_sha256':hashlib.sha256(json.dumps(context,sort_keys=True).encode()).hexdigest()})
        report={**recipe,'status':'compatibility smoke completed','load_seconds':load_seconds,
                'wall_seconds':time.perf_counter()-start,'peak_rss_bytes':k.peak_bytes(),'results':results,
                'installed_packages':{d.metadata['Name']:d.version for d in metadata.distributions()},
                'limitations':['No accuracy, P&L or calibrated-uncertainty evidence; not promotable.',
                    'Marginal price quantiles are not joint paths or return confidence intervals.',
                    'Only open is forecast; no OHLC validity comparison with Kronos.',
                    'Input clock/values match Kronos; preprocessing, output tasks and model compute differ.',
                    'Already-observed research dates; no untouched holdout or prospective test.']}
        r.write_json(output/'report.json',report)
        return report
    except Exception as error:
        r.write_json(output/'failure.json',{'status':'failed','error_type':type(error).__name__,'peak_rss_bytes':k.peak_bytes()})
        raise
    finally:
        signal.alarm(0); signal.signal(signal.SIGALRM,previous)


def main():
    os.umask(0o077)
    parser=argparse.ArgumentParser(description=__doc__)
    for option in ('archive','assets','output'): parser.add_argument('--'+option,type=Path,required=True)
    args=parser.parse_args()
    try:
        report=smoke(args.archive,args.assets,args.output)
        print(json.dumps({key:report[key] for key in ('status','wall_seconds','peak_rss_bytes','promotable')}))
    except Exception as error:
        print('Chronos stopped: '+(str(error) if isinstance(error,r.ResearchError) else type(error).__name__),file=sys.stderr)
        return 1
    return 0


if __name__=='__main__': sys.exit(main())
