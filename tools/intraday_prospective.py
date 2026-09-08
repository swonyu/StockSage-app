#!/usr/bin/env python3
"""Finite prospective forecast recorder. No orders, training, downloads or app writes."""
import argparse
from datetime import datetime
import fcntl
import hashlib
import importlib.metadata as metadata
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time

import intraday_comparison as p
import intraday_research as r

RESEARCH=Path(__file__).resolve().parents[1]/'.research'
FIT=RESEARCH/'runs/20260908-jun-aug-v1/fold-1-lightgbm.txt'
DAYS=('2026-09-08','2026-09-09','2026-09-10','2026-09-11','2026-09-14')
GROUPS=('baselines','kronos','chronos')
NAMES=('zero','momentum','reversal','lightgbm','kronos','chronos')


def at(day,hhmm):
    return int(datetime.fromisoformat(day+'T'+hhmm+':00').replace(tzinfo=r.NY).timestamp()*1000)


def schedule():
    if any(p.w.scheduled_minutes(day)!=390 for day in DAYS):
        raise r.ResearchError('Frozen session calendar mismatch.')
    return [at(day,'11:10')+m*r.MINUTE for day in DAYS for m in range(0,256,15)]


def protocol():
    return {'schema':1,'signal_times':schedule(),'symbols':list(p.SYMBOLS),'models':list(NAMES),
        'sources':{**p.source_hashes(),Path(__file__).name:r.digest(__file__)},
        'lightgbm_sha256':p.MODEL_SHA,'lightgbm_train_through':'2026-06-29',
        'kronos_assets':{n:list(v) for n,v in p.k.ASSETS.items()},
        'chronos_assets':{n:list(v) for n,v in p.c.ASSETS.items()},
        'delays_minutes':[1,6],'hold_minutes':15,'threshold':.0005,'costs_bps':list(r.COSTS),
        'calendar':p.w.CALENDAR_SOURCE,'promotable':False,
        'policy':'all10 past contexts; one attempt; serial CPU workers <=120s and deadline; no late backfill',
        'outcomes':'one collection per session after16:01 ET; forecast errors only, not trades or P&L',
        'clock':'local wall/monotonic clocks; >2s drift refused; not trusted external timestamps',
        'limits':'scheduled bars only; no halt calendar, NBBO, real fills or provider correction history'}


class Clock:
    def __init__(self):
        self.wall=time.time_ns()/1_000_000
        self.mono=time.monotonic_ns()/1_000_000
        self.last=self.wall

    def read(self):
        wall=time.time_ns()/1_000_000
        elapsed=time.monotonic_ns()/1_000_000-self.mono
        if wall<self.last or abs(wall-self.wall-elapsed)>2000:
            raise r.ResearchError('Local clock moved; timing eligibility refused.')
        self.last=wall
        return wall


def durable(path,value,raw=False):
    """Exclusive private write, including directory fsync; never overwrite a receipt."""
    path=Path(path)
    body=value if raw else (json.dumps(value,indent=2,allow_nan=False)+'\n').encode()
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as handle:
        handle.write(body); handle.flush(); os.fsync(handle.fileno())
    fd=os.open(path.parent,os.O_RDONLY)
    try: os.fsync(fd)
    finally: os.close(fd)


def read(path,sha=None):
    path=Path(path)
    if path.is_symlink() or path.stat().st_size>2_000_000 or (sha and r.digest(path)!=sha):
        raise r.ResearchError('Prospective artifact hash/type/size mismatch.')
    return p.w.read_json(path)


def failure(error):
    return {'error_type':type(error).__name__,
            'reason':str(error) if isinstance(error,r.ResearchError) else 'See private attempt record; no automatic retry.'}


def initialize(root,clock=None):
    clock=clock or Clock(); now=clock.read()
    if now>=schedule()[0]: raise r.ResearchError('Pilot must be frozen before its first signal; no backdating.')
    if r.digest(FIT)!=p.MODEL_SHA: raise r.ResearchError('Saved LightGBM changed; do not retrain.')
    p.k.verify_assets(RESEARCH/'kronos-v1'); p.c.verify_assets(RESEARCH/'chronos-v1')
    root=r.private_directory(root)
    durable(root/'recipe.json',{'protocol':protocol(),'created_at_ms':now})
    completed=clock.read()
    if completed>=schedule()[0]: raise r.ResearchError('Freeze completed late; pilot not usable.')
    durable(root/'frozen.json',{'recipe_sha256':r.digest(root/'recipe.json'),'frozen_at_ms':completed})
    return {'status':'frozen','batches':len(schedule()),'symbol_events':len(schedule())*len(p.SYMBOLS),
            'first_signal_ms':schedule()[0],'recipe_sha256':r.digest(root/'recipe.json')}


def load(root):
    frozen=read(root/'frozen.json'); recipe=read(root/'recipe.json',frozen['recipe_sha256'])
    if (recipe.get('protocol')!=protocol() or
        not recipe['created_at_ms']<=frozen['frozen_at_ms']<schedule()[0]):
        raise r.ResearchError('Frozen protocol/source/timestamp mismatch; pilot paused.')
    return frozen


def event_input(bars,symbol,t):
    ctx=p.k.context(bars,symbol,t)
    past=sorted((b for b in bars if b['symbol']==symbol and t-100*r.MINUTE<=b['t']<t),key=lambda b:b['t'])
    if any(type(b['v']) not in (int,float) or not math.isfinite(b['v']) or b['v']<0 for b in past):
        raise r.ResearchError('Invalid past volume.')
    window=[]
    for i in range(0,100,5):
        group=past[i:i+5]
        window.append({'c':group[-1]['c'],'h':max(b['h'] for b in group),
                       'l':min(b['l'] for b in group),'v':sum(b['v'] for b in group)})
    x=r.feature_vector(window,t)
    if any(not math.isfinite(v) for v in x): raise r.ResearchError('Nonfinite past features.')
    return {'id':f'{symbol}:{t}','symbol':symbol,'signal_t':t,'context':ctx,'x':x}


def snapshot(folder,symbol,day,fetch,clock):
    started=clock.read(); raw=fetch(symbol,day,day); received=clock.read()
    if len(raw)>1_000_000: raise r.ResearchError('Live daily snapshot exceeds1MB.')
    durable(folder/(symbol+'.raw.json'),raw,raw=True)
    durable(folder/(symbol+'.receipt.json'),{'fetch_started_ms':started,'received_ms':received,
            'sha256':hashlib.sha256(raw).hexdigest(),'symbol':symbol,'day':day})
    try: payload=json.loads(raw)
    except (ValueError,UnicodeDecodeError): raise r.ResearchError('Provider JSON invalid.') from None
    bars=r.validate_payload(payload,symbol,day,day)
    if payload['status']!='OK': raise r.ResearchError('Delayed snapshot is not eligible for this pilot.')
    if any(b['t']>received for b in bars): raise r.ResearchError('Provider returned future-dated bars.')
    return bars


def worker(batch,sha,candidate,output):
    value=read(batch,sha); events=value['events']; p.validate_events(events)
    if candidate!='baselines':
        return p.predict_events(events,candidate,RESEARCH/(candidate+'-v1'),output,sha)
    if r.digest(FIT)!=p.MODEL_SHA: raise r.ResearchError('Saved fit changed.')
    if any(metadata.version(n)!=v for n,v in {'lightgbm':'4.6.0','numpy':'2.2.6','scipy':'1.18.1'}.items()):
        raise r.ResearchError('Wrong baseline environment.')
    if any(len(e['x'])!=7 or any(type(v) not in (int,float) or not math.isfinite(v) for v in e['x']) for e in events):
        raise r.ResearchError('Malformed past-only feature vector.')
    def offline(event,args):
        if event in ('socket.connect','socket.getaddrinfo','socket.sendto'): raise r.ResearchError('Worker network refused.')
    sys.addaudithook(offline)
    import lightgbm as lgb
    import numpy as np
    predictors,_,_=r.fit_predictors([],False)
    booster=lgb.Booster(model_file=str(FIT))
    predictors['lightgbm']=lambda rows:booster.predict(np.asarray([e['x'] for e in rows]),num_threads=1).tolist()
    candidates={n:[{'id':e['id'],'returns':{'1':v,'6':v}} for e,v in zip(events,fn(events),strict=True)]
                for n,fn in predictors.items()}
    for rows in candidates.values(): p.aligned(events,rows,1)
    if p.k.peak_bytes()>2_000_000_000: raise r.ResearchError('Baseline memory ceiling exceeded.')
    output=r.private_directory(output)
    durable(output/'predictions.json',{'candidate':candidate,'bundle_sha256':sha,'sources':p.source_hashes(),
        'candidates':candidates,'promotable':False,'peak_rss_bytes':p.k.peak_bytes()})
    return {'status':'predicted','candidate':candidate,'events':len(events)}


def run_worker(candidate,batch,output,seconds):
    env=os.environ.copy(); env.pop('MASSIVE_API_KEY',None); env.pop('EODHD_API_TOKEN',None)
    env.update({'OMP_NUM_THREADS':'1','OPENBLAS_NUM_THREADS':'1','MKL_NUM_THREADS':'1',
                'PYTHONDONTWRITEBYTECODE':'1','HF_HUB_OFFLINE':'1','HF_HUB_DISABLE_IMPLICIT_TOKEN':'1'})
    python=RESEARCH/('venv' if candidate=='baselines' else candidate+'-venv')/'bin/python'
    with (output.parent/(candidate+'.log')).open('x') as log:
        os.chmod(log.name,0o600)
        result=subprocess.run([str(python),__file__,'worker','--batch',str(batch),'--sha',r.digest(batch),
            '--candidate',candidate,'--output',str(output)],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=seconds)
    if result.returncode: raise r.ResearchError('Forecast process failed; see private sanitized worker log.')


def candidate_rows(path,events,sha,group):
    value=read(path)
    if value.get('bundle_sha256')!=sha or value.get('candidate')!=group or value.get('sources')!=p.source_hashes():
        raise r.ResearchError('Forecast provenance mismatch.')
    rows=value['candidates'] if group=='baselines' else {group:value['rows']}
    if set(rows)!=(set(NAMES[:4]) if group=='baselines' else {group}):
        raise r.ResearchError('Missing candidate; no partial comparison.')
    for v in rows.values():
        for d in (1,6): p.aligned(events,v,d)
    return rows


def capture(folder,t,fetch,clock,runner):
    deadline=t+6*r.MINUTE; snapshots=r.private_directory(folder/'snapshots'); events=[]
    try:
        for s in p.SYMBOLS:
            if clock.read()>=deadline: raise r.ResearchError('Input deadline missed; no retry.')
            bars=snapshot(snapshots,s,r.ny_date(t),fetch,clock)
            events.append(event_input(bars,s,t))
        durable(folder/'inputs.json',{'events':events,
            'snapshots':{s:r.digest(snapshots/(s+'.receipt.json')) for s in p.SYMBOLS}})
    except Exception as error:
        durable(folder/'result.json',{'status':'input_failed',**failure(error)})
        return 'input_failed'
    sha=r.digest(folder/'inputs.json'); outcomes={}
    for group in GROUPS:
        try:
            remaining=(deadline-clock.read())/1000
            if remaining<=0: raise r.ResearchError('Forecast deadline missed.')
            output=folder/group
            runner(group,folder/'inputs.json',output,min(120,remaining))
            path=output/'predictions.json'
            candidate_rows(path,events,sha,group)
            # Parent seals the worker's bytes before observing availability time.
            prediction_sha=r.digest(path)
            with path.open('rb') as handle: os.fsync(handle.fileno())
            fd=os.open(output,os.O_RDONLY)
            try: os.fsync(fd)
            finally: os.close(fd)
            ready=clock.read()
            receipt={'status':'recorded','ready_at_ms':ready,'prediction_sha256':prediction_sha,
                     'inputs_sha256':sha,'eligible':{str(d):ready<t+d*r.MINUTE for d in (1,6)}}
        except Exception as error:
            receipt={'status':'failed',**failure(error)}
        durable(folder/(group+'.receipt.json'),receipt); outcomes[group]=receipt
    durable(folder/'result.json',{'status':'attempted','groups':outcomes})
    return 'attempted'


def score_day(root,day,folder,bars,clock):
    """Outcome-only stage; unavailable/late forecasts remain in the denominator."""
    if day not in DAYS or clock.read()<at(day,'16:01'):
        raise r.ResearchError('Outcome scoring is not yet eligible.')
    prices={(b['symbol'],b['t']):b for b in bars}; rows=[]
    for t in (t for t in schedule() if r.ny_date(t)==day):
        event_dir=root/str(t); forecasts={}; eligible={}
        if (event_dir/'result.json').exists() and read(event_dir/'result.json').get('status')=='attempted':
            inputs=read(event_dir/'inputs.json'); events=inputs['events']; sha=r.digest(event_dir/'inputs.json')
            for group in GROUPS:
                receipt_path=event_dir/(group+'.receipt.json')
                if not receipt_path.exists(): continue
                receipt=read(receipt_path)
                if receipt.get('status')!='recorded': continue
                path=event_dir/group/'predictions.json'; read(path,receipt['prediction_sha256'])
                if (receipt['inputs_sha256']!=sha or receipt['ready_at_ms']<t or
                    receipt['eligible']!={str(d):receipt['ready_at_ms']<t+d*r.MINUTE for d in (1,6)}):
                    raise r.ResearchError('Timing/input receipt mismatch.')
                values=candidate_rows(path,events,sha,group)
                forecasts.update({n:{v['id']:v for v in vs} for n,vs in values.items()})
                eligible.update({n:receipt['eligible'] for n in values})
        for symbol in p.SYMBOLS:
            for d in (1,6):
                entry=prices.get((symbol,t+d*r.MINUTE)); exit_bar=prices.get((symbol,t+(d+15)*r.MINUTE))
                y=exit_bar['o']/entry['o']-1 if entry and exit_bar and min(entry['v'],exit_bar['v'])>0 else None
                for name in NAMES:
                    prediction=forecasts.get(name,{}).get(f'{symbol}:{t}')
                    timely=eligible.get(name,{}).get(str(d),False)
                    status='missing_forecast' if prediction is None else 'late' if not timely else 'missing_outcome' if y is None else 'scored'
                    pred=prediction['returns'][str(d)] if prediction else None
                    rows.append({'id':f'{symbol}:{t}','model':name,'delay':d,'status':status,
                                 'prediction':pred,'observed_return':y,
                                 'absolute_error':abs(pred-y) if status=='scored' else None})
    shared={(v['id'],v['delay']) for v in rows if v['status']=='scored'}
    shared-={(v['id'],v['delay']) for v in rows if v['status']!='scored'}
    durable(folder/'scores.json',{'day':day,'promotable':False,'rows':rows,
        'denominator':len(rows),'scored':sum(v['status']=='scored' for v in rows),
        'common_six_model_symbol_delay_events':len(shared),
        'meaning':'prospectively timed forecast errors, NOT fills or portfolio returns'})
    return len(rows)


def tick(root,fetch_factory=None,runner=run_worker,clock=None):
    root=Path(root); clock=clock or Clock()
    if root.is_symlink(): raise r.ResearchError('Symlinked pilot root refused.')
    frozen=load(root)
    # ponytail: one pilot-wide lock; this recorder has one owner and <=90 batches.
    fd=os.open(root/'tick.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'a') as lock:
        try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: return {'status':'already_running'}
        now=clock.read(); actions=[]; fetch=None
        previous=[frozen['frozen_at_ms']]
        for t in schedule():
            folder=root/str(t)
            if folder.exists():
                if folder.is_symlink(): raise r.ResearchError('Symlinked event directory refused.')
                if not (folder/'result.json').exists():
                    if not (folder/'started.json').exists():
                        durable(folder/'started.json',{'signal_t':t,'observed_at_ms':now,
                                                       'recovered_empty_reservation':True})
                    durable(folder/'result.json',{'status':'interrupted_no_retry'})
                    actions.append('interrupted_no_retry')
                previous.append(read(folder/'started.json')['observed_at_ms'])
                if read(folder/'result.json').get('status')=='attempted':
                    for group in GROUPS:
                        path=folder/(group+'.receipt.json')
                        if path.exists(): previous.append(read(path).get('ready_at_ms',0))
        for day in DAYS:
            path=root/('outcomes-'+day)/'result.json'
            if path.exists(): previous.append(read(path).get('completed_at_ms',0))
        if max(previous)>now: raise r.ResearchError('Clock precedes recorded activity; pilot paused.')
        def get_fetch():
            nonlocal fetch
            if fetch is None: fetch=(fetch_factory or r.provider_fetcher)()
            return fetch
        for t in schedule():
            if t>now: break
            folder=root/str(t)
            if folder.exists():
                continue
            r.private_directory(folder)
            observed=clock.read(); durable(folder/'started.json',{'signal_t':t,'observed_at_ms':observed})
            if observed>=t+6*r.MINUTE:
                durable(folder/'result.json',{'status':'missed_deadline'})
                actions.append('missed_deadline')
            else:
                try: actions.append(capture(folder,t,get_fetch(),clock,runner))
                except Exception as error:
                    if not (folder/'result.json').exists():
                        durable(folder/'result.json',{'status':'failed',**failure(error)})
                    raise
        # Labels are deliberately collected after the session, never fed to workers.
        for day in DAYS:
            if clock.read()<at(day,'16:01'): break
            folder=root/('outcomes-'+day)
            if folder.exists():
                if not (folder/'result.json').exists():
                    durable(folder/'result.json',{'status':'interrupted_no_retry'})
                    actions.append('outcomes_interrupted_no_retry')
                continue
            r.private_directory(folder); bars=[]
            try:
                eligible=False
                for t in (t for t in schedule() if r.ny_date(t)==day):
                    event_dir=root/str(t)
                    if read(event_dir/'result.json').get('status')!='attempted': continue
                    for group in GROUPS:
                        receipt=read(event_dir/(group+'.receipt.json'))
                        eligible|=receipt.get('status')=='recorded' and any(receipt['eligible'].values())
                if eligible:
                    for s in p.SYMBOLS: bars.extend(snapshot(folder,s,day,get_fetch(),clock))
                score_day(root,day,folder,bars,clock)
                durable(folder/'result.json',{'status':'scored','completed_at_ms':clock.read()})
                actions.append('outcomes_scored')
            except Exception as error:
                durable(folder/'result.json',{'status':'outcome_failed_no_retry',**failure(error)})
                actions.append('outcome_failed_no_retry')
            break
        terminal=(all((root/str(t)/'result.json').exists() for t in schedule()) and
                  all((root/('outcomes-'+day)/'result.json').exists() for day in DAYS))
        return {'status':'complete' if terminal else 'updated' if actions else 'waiting',
                'actions':actions,'observed_at_ms':clock.read(),
                'next_signal_ms':next((t for t in schedule() if t>clock.read()),None)}


def main():
    os.umask(0o077); parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='stage',required=True)
    for name in ('init','tick'): sub.add_parser(name).add_argument('--root',type=Path,required=True)
    child=sub.add_parser('worker'); child.add_argument('--batch',type=Path,required=True)
    child.add_argument('--sha',required=True); child.add_argument('--candidate',choices=GROUPS,required=True)
    child.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    try:
        if args.stage=='worker': result=worker(args.batch,args.sha,args.candidate,args.output)
        elif args.stage=='init': result=initialize(args.root)
        else: result=tick(args.root)
        print(json.dumps(result)); return 0
    except Exception as error:
        print('Prospective recorder stopped: '+(str(error) if isinstance(error,r.ResearchError) else type(error).__name__),file=sys.stderr)
        return 1


if __name__=='__main__': sys.exit(main())
