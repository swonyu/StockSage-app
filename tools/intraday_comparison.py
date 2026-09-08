#!/usr/bin/env python3
"""Fixed retrospective model comparison; offline, private and never promotable."""
import argparse
from collections import defaultdict
from datetime import datetime
import importlib.metadata as metadata
import json
import math
import os
from pathlib import Path
import signal
import statistics
import sys
import time

import intraday_chronos as c
import intraday_kronos as k
import intraday_research as r
import intraday_walkforward as w

DAYS=('2026-07-08','2026-07-09','2026-07-10','2026-07-13','2026-07-14')
SYMBOLS=tuple(sorted(('AAPL','MSFT','NVDA','AMZN','GOOGL','META','TSLA','ORCL','QCOM','APP')))
MODEL_SHA='079d5bd6392983a62c1f36c337b849197ec4d0f1bd4993fa35015e6f89520836'
STUDY_SHA='7e549e6e820a505e5b0c04809ae881116813805d832b9a8485e1c279f14b7858'
COLLECTION_SHA='325244f569b45ac614e2565b5826119ffbdd2492074a6dba7595506dd07777c2'


def schedule():
    events=[]
    for day in DAYS:
        start=int(datetime.fromisoformat(day+'T11:10:00').replace(tzinfo=r.NY).timestamp()*1000)
        for minute in range(0,25,5):
            t=start+minute*r.MINUTE
            events.extend({'id':f'{s}:{t}','symbol':s,'signal_t':t} for s in SYMBOLS)
    return events


def source_hashes():
    return {Path(p).name:r.digest(p) for p in (__file__,r.__file__,w.__file__,k.__file__,c.__file__)}


def aligned(events,rows,delay):
    if type(delay) is not int or delay not in (1,6): raise r.ResearchError('Unsupported delay.')
    try:
        values={row['id']:row['returns'][str(delay)] for row in rows}
        if len(values)!=len(rows) or set(values)!={e['id'] for e in events}: raise ValueError()
        if any(type(v) not in (int,float) or not math.isfinite(v) for v in values.values()): raise ValueError()
        return [values[e['id']] for e in events]
    except (KeyError,TypeError,ValueError):
        raise r.ResearchError('Missing/duplicate/foreign/nonfinite forecast; no partial scoring.') from None


def prepare(study_root,model_path,root):
    study_root=Path(study_root)
    if (r.digest(study_root/'study.json')!=STUDY_SHA or r.digest(study_root/'collection.json')!=COLLECTION_SHA
        or r.digest(model_path)!=MODEL_SHA): raise r.ResearchError('Source study or saved LightGBM differs.')
    root=r.private_directory(root)
    recipe={'schema':1,'status':'already-observed exploratory comparison','promotable':False,
            'created_at':r.utc_now(),'sources':source_hashes(),'events':schedule(),
            'study_sha256':STUDY_SHA,'collection_sha256':COLLECTION_SHA,'lightgbm_sha256':MODEL_SHA,
            'lightgbm_train_through':'2026-06-29','threshold':.0005,'costs_bps':list(r.COSTS),'delays':[1,6],
            'kronos_assets':k.ASSETS,'chronos_assets':c.ASSETS,'seed':7,
            'limits':'one CPU thread per model, serial processes,2GB/300s check; no training or network',
            'policy':'all250 events required; record quality defects, no repair/drop/winner selection'}
    r.write_json(root/'recipe.json',recipe)
    study,bars,quality=w.load_study(study_root)
    if (not quality['valid'] or sorted(study['symbols'])!=list(SYMBOLS)
        or study['runner_sha256']!=r.digest(w.__file__) or study['base_sha256']!=r.digest(r.__file__)):
        raise r.ResearchError('Study quality/source identity failed.')
    test_bars=[b for b in bars if r.ny_date(b['t']) in DAYS]
    grouped=defaultdict(list)
    for b in test_bars: grouped[b['symbol'],r.ny_date(b['t'])].append(b)
    events=[{**e,'context':k.context(grouped[e['symbol'],r.ny_date(e['signal_t'])],e['symbol'],e['signal_t'])}
            for e in schedule()]
    samples={}
    for delay in (1,6):
        rows,_=r.examples(test_bars,15,delay)
        index={f"{s['symbol']}:{s['signal_t']}":s for s in rows}
        if any(e['id'] not in index for e in events): raise r.ResearchError('Required label absent; do not drop event.')
        samples[str(delay)]=[index[e['id']] for e in events]
    if any(a['x']!=b['x'] for a,b in zip(samples['1'],samples['6'])):
        raise r.ResearchError('Delay unexpectedly changes historical features.')
    import numpy as np
    import lightgbm as lgb
    if lgb.__version__!='4.6.0': raise r.ResearchError('Use the pinned LightGBM environment.')
    booster=lgb.Booster(model_file=str(model_path))
    predictors,_,_=r.fit_predictors([],False)
    predictors['lightgbm']=lambda rows:booster.predict(np.asarray([s['x'] for s in rows]),num_threads=1).tolist()
    baseline={}
    for name,predict in predictors.items():
        values=predict(samples['1'])
        baseline[name]=[{'id':e['id'],'returns':{'1':p,'6':p}} for e,p in zip(events,values,strict=True)]
        aligned(events,baseline[name],1)
    for filename,data in [('inputs.json',{'events':events}),('samples.json',samples),('baselines.json',baseline)]:
        r.write_json(root/filename,data)
    r.write_json(root/'bundle.json',{'schema':1,'recipe_sha256':r.digest(root/'recipe.json'),
        'files':{f:r.digest(root/f) for f in ('inputs.json','samples.json','baselines.json')}})
    return {'status':'prepared','events':len(events),'root':str(root)}


def load_bundle(root,filename):
    root=Path(root); bundle=w.read_json(root/'bundle.json'); recipe=w.read_json(root/'recipe.json')
    if (bundle.get('schema')!=1 or bundle.get('recipe_sha256')!=r.digest(root/'recipe.json')
        or recipe.get('sources')!=source_hashes() or recipe.get('events')!=schedule()
        or filename not in ('inputs.json','samples.json','baselines.json')):
        raise r.ResearchError('Comparison recipe/source mismatch.')
    path=root/filename
    if path.stat().st_size>8_000_000 or r.digest(path)!=bundle['files'].get(filename):
        raise r.ResearchError('Comparison bundle changed/oversized.')
    value=w.read_json(path)
    if filename=='inputs.json':
        try:
            actual=[{key:e[key] for key in ('id','symbol','signal_t')} for e in value['events']]
            if actual!=schedule(): raise ValueError()
        except (KeyError,TypeError,ValueError):
            raise r.ResearchError('Input events differ from the complete frozen schedule.') from None
    return value


def predict(root,candidate,assets,output):
    if candidate not in ('kronos','chronos'): raise r.ResearchError('Unknown fixed model.')
    events=load_bundle(root,'inputs.json')['events']; assets=Path(assets).resolve()
    (k.verify_assets if candidate=='kronos' else c.verify_assets)(assets)
    versions=(c.VERSIONS if candidate=='chronos' else {'torch':'2.14.0','numpy':'2.2.6',
        'pandas':'2.2.2','einops':'0.8.1','huggingface-hub':'0.33.1','safetensors':'0.6.2'})
    if any(metadata.version(n)!=v for n,v in versions.items()): raise r.ResearchError('Wrong forecast environment.')
    output=r.private_directory(output)
    run={'schema':1,'candidate':candidate,'bundle_sha256':r.digest(Path(root)/'bundle.json'),
         'sources':source_hashes(),'versions':versions,'created_at':r.utc_now(),'promotable':False}
    r.write_json(output/'run.json',run); start=time.perf_counter()
    def timeout(*_): raise r.ResearchError('Five-minute forecast ceiling exceeded.')
    def offline(event,args):
        if event in ('socket.connect','socket.getaddrinfo','socket.sendto'): raise r.ResearchError('Forecast network refused.')
    def memory_check():
        if k.peak_bytes()>2_000_000_000: raise r.ResearchError('Two-GB forecast memory ceiling exceeded.')
    previous=signal.signal(signal.SIGALRM,timeout); signal.alarm(300)
    try:
        os.environ['HF_HUB_OFFLINE']='1'; os.environ['HF_HUB_DISABLE_IMPLICIT_TOKEN']='1'
        sys.addaudithook(offline); sys.dont_write_bytecode=True
        import numpy as np
        import pandas as pd
        import torch
        from safetensors.torch import load_model
        torch.set_num_threads(1); torch.set_num_interop_threads(1); torch.use_deterministic_algorithms(True)
        torch.manual_seed(7)
        if candidate=='kronos':
            if 'model' in sys.modules: raise r.ResearchError('Conflicting model import; use a fresh process.')
            sys.path.insert(0,str(assets))
            from model import Kronos,KronosTokenizer,KronosPredictor
            model=Kronos(**w.read_json(assets/'predictor/config.json')).eval()
            tokenizer=KronosTokenizer(**w.read_json(assets/'tokenizer/config.json')).eval()
            load_model(model,str(assets/'predictor/model.safetensors'),device='cpu')
            load_model(tokenizer,str(assets/'tokenizer/model.safetensors'),device='cpu')
            predictor=KronosPredictor(model,tokenizer,device='cpu',max_context=512)
        else:
            from chronos.chronos2 import Chronos2CoreConfig,Chronos2Model,Chronos2Pipeline
            with torch.device('cpu'): model=Chronos2Model(Chronos2CoreConfig(**w.read_json(assets/'config.json')))
            load_model(model,str(assets/'model.safetensors'),device='cpu',strict=True)
            predictor=Chronos2Pipeline(model.to(device='cpu',dtype=torch.float32).eval())
        memory_check(); load_seconds=time.perf_counter()-start; rows=[]
        for event in events:
            context=event['context']; torch.manual_seed(7); np.random.seed(7); tick=time.perf_counter()
            with torch.inference_mode():
                if candidate=='kronos':
                    frame=pd.DataFrame(context['ohlc'],columns=['open','high','low','close'])
                    def timestamps(v): return pd.Series(pd.to_datetime(v,unit='ms',utc=True).tz_convert(r.NY).tz_localize(None))
                    xs,ys=timestamps(context['x_t']),timestamps(context['y_t'])
                    prediction=predictor.predict(frame,xs,ys,pred_len=22,T=1.,top_p=.9,top_k=0,sample_count=1,verbose=False)
                    if list(prediction.index)!=list(ys): raise r.ResearchError('Kronos timestamp mismatch.')
                    ohlc=prediction[['open','high','low','close']].to_numpy().tolist()
                    opens=[b[0] for b in ohlc]
                    invalid=sum(not(all(math.isfinite(v) and v>0 for v in b) and b[2]<=min(b[0],b[3])<=max(b[0],b[3])<=b[1]) for b in ohlc)
                    # Null denotes a nonfinite generated field, never a repaired market price.
                    detail={'ohlc':[[v if math.isfinite(v) else None for v in b] for b in ohlc],
                            'invalid_ohlc_steps':invalid}
                else:
                    raw=c.task_input(context)
                    task={'target':np.asarray(raw['target'],dtype=np.float32),
                          'past_covariates':{n:np.asarray(v,dtype=np.float32) for n,v in raw['past_covariates'].items()}}
                    predictions,_=predictor.predict_quantiles([task],prediction_length=22,quantile_levels=[.1,.5,.9],
                        context_length=100,batch_size=4,cross_learning=False,limit_prediction_length=True)
                    if len(predictions)!=1 or tuple(predictions[0].shape)!=(1,22,3): raise r.ResearchError('Chronos shape mismatch.')
                    quantiles=predictions[0][0].tolist(); quality=c.summarize(quantiles)
                    opens=[v[1] for v in quantiles]
                    detail={'open_quantiles':quantiles,'crossed_steps':quality['crossed_steps']}
            memory_check()
            rows.append({'id':event['id'],'returns':{str(d):k.forecast_return(opens,d) for d in (1,6)},
                         'seconds':time.perf_counter()-tick,**detail})
        for delay in (1,6): aligned(events,rows,delay)
        result={**run,'rows':rows,'load_seconds':load_seconds,'wall_seconds':time.perf_counter()-start,'peak_rss_bytes':k.peak_bytes()}
        r.write_json(output/'predictions.json',result)
        return {'status':'predicted','candidate':candidate,'events':len(rows),'wall_seconds':result['wall_seconds'],'peak_rss_bytes':result['peak_rss_bytes']}
    except Exception as error:
        r.write_json(output/'failure.json',{'error_type':type(error).__name__,'peak_rss_bytes':k.peak_bytes()})
        raise
    finally:
        signal.alarm(0); signal.signal(signal.SIGALRM,previous)


def evaluate(root,study_root,kronos,chronos,output):
    events=load_bundle(root,'inputs.json')['events']; samples=load_bundle(root,'samples.json')
    candidates=load_bundle(root,'baselines.json'); quality={}
    for name,path in [('kronos',kronos),('chronos',chronos)]:
        data=w.read_json(Path(path)/'predictions.json')
        if data.get('candidate')!=name or data.get('sources')!=source_hashes() or data.get('bundle_sha256')!=r.digest(Path(root)/'bundle.json'):
            raise r.ResearchError('Forecast provenance does not match comparison.')
        candidates[name]=data['rows']
        quality[name]={'invalid_ohlc_steps':sum(x['invalid_ohlc_steps'] for x in data['rows']) if name=='kronos' else None,
                       'crossed_steps':sum(x['crossed_steps'] for x in data['rows']) if name=='chronos' else None,
                       'artifact_sha256':r.digest(Path(path)/'predictions.json')}
    if set(candidates)!={'zero','momentum','reversal','lightgbm','kronos','chronos'}: raise r.ResearchError('All six candidates required.')
    if r.digest(Path(study_root)/'study.json')!=STUDY_SHA or r.digest(Path(study_root)/'collection.json')!=COLLECTION_SHA:
        raise r.ResearchError('Scoring study differs.')
    _,bars,q=w.load_study(study_root)
    if not q['valid']: raise r.ResearchError('Scoring data quality failed.')
    bars=[b for b in bars if r.ny_date(b['t']) in DAYS]; results=[]
    for name,rows in candidates.items():
        for delay in (1,6):
            predictions=aligned(events,rows,delay); actual=samples[str(delay)]
            if [f"{s['symbol']}:{s['signal_t']}" for s in actual]!=[e['id'] for e in events]: raise r.ResearchError('Label order mismatch.')
            mae=statistics.fmean(abs(p-s['y']) for p,s in zip(predictions,actual,strict=True))
            for cost in r.COSTS:
                result=r.simulate(actual,predictions,bars,.0005,cost)
                results.append({'candidate':name,'delay_minutes':delay,'round_trip_bps':cost,
                                'mae':mae,'examples':len(actual),**result})
    output=r.private_directory(output)
    report={'schema':1,'status':'already-observed exploratory comparison','promotable':False,
            'bundle_sha256':r.digest(Path(root)/'bundle.json'),'sources':source_hashes(),'events':len(events),
            'dates':list(DAYS),'threshold':.0005,'tuned_policies':0,'quality':quality,'results':results,
            'limitations':['Five morning windows on already-observed dates, not full-day/prospective evidence.',
                'Hand-selected universe; model pretraining/publication latency, halts and broker/NBBO/FX costs unverified.',
                'Hypothetical minute-open fills, no stop, long-only whole shares, no borrowing.',
                'Overlapping targets and correlated stocks;250 events are not250 independent trials.',
                'Same clock/targets, different feature representations; lightgbm has volume-derived inputs.',
                'Kronos invalid OHLC retained; only finite positive opens scored. Chronos median ratios are not expected returns.',
                'No winner selected, model promotion or weekly return expectation.']}
    r.write_json(output/'report.json',report)
    lines=['# Fixed exploratory comparison','', '**Already-observed dates; not promotable.**','',
           '| Candidate | Delay | RT bps | MAE bps | Net return | Drawdown | Trades |','|---|---:|---:|---:|---:|---:|---:|']
    for x in results:
        lines.append(f"| {x['candidate']} | {x['delay_minutes']} | {x['round_trip_bps']} | {x['mae']*10000:.2f} | {x['net_return']:.3%} | {x['max_drawdown']:.3%} | {x['trades']} |")
    lines.extend(['','## Limitations','',*['- '+v for v in report['limitations']],''])
    with (output/'report.md').open('x') as handle: handle.write('\n'.join(lines))
    (output/'report.md').chmod(0o600)
    return {'status':report['status'],'events':len(events),'scenarios':len(results),'promotable':False}


def main():
    os.umask(0o077); parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='stage',required=True)
    p=sub.add_parser('prepare')
    for n in ('study','lightgbm','root'): p.add_argument('--'+n,type=Path,required=True)
    p=sub.add_parser('predict'); p.add_argument('--candidate',choices=('kronos','chronos'),required=True)
    for n in ('root','assets','output'): p.add_argument('--'+n,type=Path,required=True)
    p=sub.add_parser('evaluate')
    for n in ('root','study','kronos','chronos','output'): p.add_argument('--'+n,type=Path,required=True)
    a=parser.parse_args()
    try:
        if a.stage=='prepare': result=prepare(a.study,a.lightgbm,a.root)
        elif a.stage=='predict': result=predict(a.root,a.candidate,a.assets,a.output)
        else: result=evaluate(a.root,a.study,a.kronos,a.chronos,a.output)
        print(json.dumps(result)); return 0
    except Exception as error:
        print('Comparison stopped: '+(str(error) if isinstance(error,r.ResearchError) else type(error).__name__),file=sys.stderr)
        return 1


if __name__=='__main__': sys.exit(main())
