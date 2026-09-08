#!/usr/bin/env python3
"""Compose bounded private archives into a predeclared retrospective pilot.

Reuse the existing research runner; no app integration or real-order capability.
Calendar scope deliberately stops at 2026; do not guess future exchange dates.
"""
from collections import defaultdict
from datetime import date, datetime, timedelta
import argparse
import json
import os
from pathlib import Path
import sqlite3
import sys

import intraday_research as r

CLOSED = {"01-01","01-19","02-16","04-03","05-25","06-19","07-03","09-07","11-26","12-25"}
EARLY = {"11-27","12-24"}
CALENDAR_SOURCE = "https://www.nasdaq.com/market-activity/stock-market-holiday-schedule"
CALENDAR_VERSION = "2026 scheduled US equities; checked 2026-09-08; not unscheduled halts"


def parse_day(value):
    try:
        parsed=date.fromisoformat(value)
        if parsed.isoformat()!=value: raise ValueError()
        return parsed
    except ValueError:
        raise r.ResearchError("Dates must be YYYY-MM-DD.") from None


def scheduled_minutes(day):
    d=parse_day(day)
    if d.year!=2026: raise r.ResearchError("Only the sourced 2026 calendar is supported; verify a new year first.")
    if d.weekday()>=5 or day[5:] in CLOSED: return 0
    return 210 if day[5:] in EARLY else 390


def chunks(start,end):
    first,last=parse_day(start),parse_day(end)
    if not 0<=(last-first).days<95:
        raise r.ResearchError("Pilot limit is 1–95 calendar days.")
    scheduled_minutes(start); scheduled_minutes(end)
    result=[]
    while first<=last:
        stop=min(last,first+timedelta(days=13))
        result.append((first.isoformat(),stop.isoformat()))
        first=stop+timedelta(days=1)
    return result


def session_dates(start,end):
    first,last=parse_day(start),parse_day(end)
    return [(first+timedelta(days=i)).isoformat() for i in range((last-first).days+1)
            if scheduled_minutes((first+timedelta(days=i)).isoformat())]


def fold_dates(days):
    if days!=sorted(set(days)) or len(days)<26:
        raise r.ResearchError("Need at least26 ordered unique sessions for20/5/5 walk-forward.")
    return [{"train":days[i-25:i-5],"validation":days[i-5:i],"test":days[i:i+5]}
            for i in range(25,len(days),5)]


def read_json(path):
    try:
        value=json.loads(Path(path).read_text())
        if not isinstance(value,dict): raise ValueError()
        return value
    except (ValueError,OSError): raise r.ResearchError("Study metadata missing or malformed.") from None


def collect_study(root,start,end,symbols,resume=False,fetch=None):
    ranges=chunks(start,end)
    for first,last in ranges: r.check_request(symbols,first,last)
    expected={"schema":1,"start":start,"end":end,"symbols":symbols,"chunks":ranges,
              "train_sessions":20,"validation_sessions":5,"test_sessions":5,
              "calendar_source":CALENDAR_SOURCE,"calendar_version":CALENDAR_VERSION,
              "models":["zero","momentum","reversal","lightgbm"],
              "thresholds":list(r.THRESHOLDS),"costs":list(r.COSTS),"delays":[1,6],
              "selection_cost_bps":5,"universe":"current hand-selected names; NOT point-in-time",
              "promotion":"prohibited: retrospective research with unverified real execution costs",
              "runner_sha256":r.digest(__file__),"base_sha256":r.digest(r.__file__)}
    # JSON canonical form makes persisted range tuples compare by value.
    expected=json.loads(json.dumps(expected))
    root=Path(root)
    if root.exists():
        if not resume: raise r.ResearchError("Study exists; explicit --resume is required.")
        old=read_json(root/"study.json")
        if any(old.get(k)!=v for k,v in expected.items()):
            raise r.ResearchError("Study specification changed; resume refused.")
        if (root/"collection.json").exists():
            load_study(root)  # Includes all archive checksums before returning idempotently.
            return read_json(root/"collection.json")
    else:
        r.private_directory(root)
        r.write_json(root/"study.json",{**expected,"created_at":r.utc_now()})
    collected=[]
    for first,last in ranges:
        complete=None
        for attempt in range(1,4):
            path=root/f"chunk-{first}-{last}-attempt{attempt}"
            if path.exists():
                # Retain genuinely failed attempts. A corrupt complete archive is an error,
                # never an excuse to silently replace historical inputs with a fresh fetch.
                if read_json(path/"manifest.json").get("status")=="failed": continue
                manifest,_=r.load_archive(path)
            else:
                if fetch is None: fetch=r.provider_fetcher()
                manifest=r.collect(symbols,first,last,path,fetch)
            if manifest.get("symbols")!=symbols or manifest.get("start")!=first or manifest.get("end")!=last:
                raise r.ResearchError("Chunk metadata differs from the frozen study.")
            complete={"path":path.name,"archive_sha256":manifest["archive_sha256"],"start":first,"end":last}
            break
        if complete is None: raise r.ResearchError("Three failed chunk attempts retained; investigate before another collection.")
        collected.append(complete)
    result={"schema":1,"status":"complete","study_sha256":r.digest(root/"study.json"),"archives":collected}
    r.write_json(root/"collection.json",result)
    return result


def load_study(root):
    root=Path(root); study=read_json(root/"study.json"); collection=read_json(root/"collection.json")
    if collection.get("schema")!=1 or collection.get("status")!="complete" or collection.get("study_sha256")!=r.digest(root/"study.json"):
        raise r.ResearchError("Study collection is incomplete, altered or unsupported.")
    ranges=chunks(study["start"],study["end"])
    archives=collection.get("archives",[])
    if len(archives)!=len(ranges): raise r.ResearchError("Study has missing or extra archive chunks.")
    bars=[]; seen=set(); outside=0
    for record,(first,last) in zip(archives,ranges):
        allowed={f"chunk-{first}-{last}-attempt{i}" for i in range(1,4)}
        if record.get("path") not in allowed or record.get("start")!=first or record.get("end")!=last:
            raise r.ResearchError("Archive reference is outside the frozen chunk set.")
        manifest,rows=r.load_archive(root/record["path"])
        if (manifest.get("archive_sha256")!=record.get("archive_sha256") or manifest.get("provider")!="Massive"
            or manifest.get("adjusted") is not False or manifest.get("interval")!="1 minute"
            or manifest.get("symbols")!=study["symbols"] or manifest.get("start")!=first or manifest.get("end")!=last):
            raise r.ResearchError("Archive identity/schema mismatch.")
        for row in rows:
            key=(row["symbol"],row["t"])
            if key in seen or row["symbol"] not in study["symbols"]:
                raise r.ResearchError("Duplicate or unexpected symbol across archives.")
            seen.add(key)
            day=r.ny_date(row["t"]); minutes=scheduled_minutes(day)
            local=datetime.fromtimestamp(row["t"]/1000,r.NY)
            if not minutes or local.hour*60+local.minute>=570+minutes:
                outside+=1
                continue
            bars.append(row)
    by_session=defaultdict(set)
    for b in bars: by_session[(b["symbol"],r.ny_date(b["t"]))].add(b["t"])
    issues=[]; missing=0; expected_count=0
    days=session_dates(study["start"],study["end"])
    for day in days:
        opening=int(datetime.fromisoformat(day+"T09:30:00").replace(tzinfo=r.NY).timestamp()*1000)
        expected={opening+i*r.MINUTE for i in range(scheduled_minutes(day))}
        for symbol in study["symbols"]:
            actual=by_session.get((symbol,day),set()); lost=expected-actual
            expected_count+=len(expected); missing+=len(lost)
            if lost or actual-expected:
                issues.append({"symbol":symbol,"date":day,"missing":len(lost),
                               "first_missing_timestamps":sorted(lost)[:10],"unexpected":len(actual-expected)})
    quality={"valid":not issues,"calendar_source":CALENDAR_SOURCE,"sessions":len(days),
             "expected_minutes":expected_count,"actual_minutes":len(bars),"missing_minutes":missing,
             "trimmed_outside_scheduled_session":outside,"issues":issues}
    return study,bars,quality


def run_study(root,output):
    study,bars,quality=load_study(root)
    if study.get("runner_sha256")!=r.digest(__file__) or study.get("base_sha256")!=r.digest(r.__file__):
        raise r.ResearchError("Research code differs from the predeclared study; do not score with a changed recipe.")
    output=r.private_directory(output)
    r.write_json(output/"quality.json",quality)
    if not quality["valid"]:
        raise r.ResearchError("Scheduled-minute coverage failed; quality.json records gaps. No performance was scored.")
    dates=session_dates(study["start"],study["end"]); folds=fold_dates(dates)
    variants={delay:r.examples(bars,15,delay) for delay in (1,6)}
    bars_by_day=defaultdict(list)
    for b in bars: bars_by_day[r.ny_date(b["t"])].append(b)
    states={}; fold_results=[]
    for index,fold in enumerate(folds):
        train_days=set(fold["train"]); valid_days=set(fold["validation"]); test_days=set(fold["test"])
        train=[s for s in variants[1][0] if s["date"] in train_days]
        valid=[s for s in variants[1][0] if s["date"] in valid_days]
        tests={delay:[s for s in variants[delay][0] if s["date"] in test_days] for delay in (1,6)}
        # Assert actual label intervals, not just names of intended partitions.
        r.partition(train+valid+tests[1],fold["train"][-1],fold["validation"][-1])
        predictors,fit,model=r.fit_predictors(train,True)
        model_path=output/f"fold-{index+1}-lightgbm.txt"
        model.save_model(str(model_path)); model_path.chmod(0o600)
        valid_bars=[b for day in fold["validation"] for b in bars_by_day[day]]
        test_bars=[b for day in fold["test"] for b in bars_by_day[day]]
        detail={"fold":index+1,"dates":fold,"fit":fit,"model_sha256":r.digest(model_path),
                "validation":[],"frozen_thresholds":{},"test":[]}
        for name,predict in predictors.items():
            predictions=predict(valid); choices=[]
            for threshold in r.THRESHOLDS:
                value=r.simulate(valid,predictions,valid_bars,threshold,5)
                choices.append((threshold,value))
                detail["validation"].append({"model":name,"threshold":threshold,"net_return":value["net_return"],"trades":value["trades"]})
            chosen=max(choices,key=lambda t:(t[1]["net_return"],-t[1]["trades"],t[0]))[0]
            detail["frozen_thresholds"][name]=chosen
            for delay,rows in tests.items():
                predictions=predict(rows)
                for cost in r.COSTS:
                    key=(name,delay,cost)
                    state=states.setdefault(key,{"ending_equity":10000.,"peak_equity":10000.,"max_drawdown":0.,
                                                 "fees":0.,"trades":0,"daily_equity":{},"traded_notional":0.})
                    opening=state["ending_equity"]
                    result=r.simulate(rows,predictions,test_bars,chosen,cost,
                                      initial_equity=opening,prior_peak=state["peak_equity"])
                    result.pop("trade_log")  # Reproducible from archived bars/model; avoid duplicating every fill in256 summaries.
                    detail["test"].append({"model":name,"entry_delay_minutes":delay,"round_trip_cost_bps":cost,
                                           "initial_equity":opening,"examples":len(rows),**result})
                    state["traded_notional"]+=result["turnover"]*opening
                    state["ending_equity"]=result["ending_equity"]; state["peak_equity"]=result["peak_equity"]
                    state["max_drawdown"]=max(state["max_drawdown"],result["max_drawdown"])
                    state["fees"]+=result["fees"]; state["trades"]+=result["trades"]
                    if state["daily_equity"].keys() & result["daily_equity"].keys():
                        raise r.ResearchError("Test dates overlap; equity would be counted twice.")
                    state["daily_equity"].update(result["daily_equity"])
        fold_results.append(detail)
    results=[]
    for (name,delay,cost),state in states.items():
        values=[10000.,*state["daily_equity"].values()]
        results.append({"model":name,"entry_delay_minutes":delay,"round_trip_cost_bps":cost,
                        "net_return":state["ending_equity"]/10000.-1,
                        "losing_days":sum(b<a for a,b in zip(values,values[1:])),
                        "turnover":state["traded_notional"]/10000.,**state})
    report={"schema":1,"status":"retrospective selected-universe pilot","promotable":False,
            "created_at":r.utc_now(),"study_sha256":r.digest(Path(root)/"study.json"),
            "runner_sha256":r.digest(__file__),"base_sha256":r.digest(r.__file__),
            "calendar_source":CALENDAR_SOURCE,"quality":quality,"folds":fold_results,
            "feature_quality":{delay:value[1] for delay,value in variants.items()},
            "total_tried_policies":16*len(folds),"results":results,
            "test_sessions":sum(len(f["test"]) for f in folds),
            "limitations":["Hand-selected current universe is NOT point-in-time; survivorship/selection bias remains.",
                "Scheduled calendar is verified, not historical halt/publication/correction availability.",
                "Hypothetical minute-open fills; actual broker fees/minimums/FX/NBBO/impact/settlement unverified.",
                "No risk stop; long-only, unlevered fractional equity allocations with whole shares.",
                "Earlier test outcomes may enter later training only after they occurred; test blocks never overlap.",
                "No statistical significance or model superiority claimed; no candidate selected on test.",
                "Longer history is not prospective paper trading or evidence for5-percent weekly returns.",
                "Delays have differing end-of-day sample sets; all counts and all cost scenarios retained."]}
    r.write_json(output/"report.json",report)
    lines=["# Walk-forward research — retrospective pilot", "", "**Not promotable; no real orders or app changes.**", "",
           f"{len(folds)} rolling20/5/5-session folds;{report['test_sessions']} disjoint test sessions;{quality['actual_minutes']:,} scheduled minutes.",
           f"{report['total_tried_policies']} validation-only policies; simulated capital/high-water carried across folds.", "",
           "| Candidate | Delay min | RT cost bps | Net return | Minute-open drawdown | Trades | Losing days |",
           "|---|---:|---:|---:|---:|---:|---:|"]
    for x in results:
        lines.append(f"| {x['model']} | {x['entry_delay_minutes']} | {x['round_trip_cost_bps']} | {x['net_return']:.3%} | {x['max_drawdown']:.3%} | {x['trades']} | {x['losing_days']} |")
    lines.extend(["", "## Limitations", "", *["- "+v for v in report["limitations"]], ""])
    with (output/"report.md").open("x") as handle: handle.write("\n".join(lines))
    (output/"report.md").chmod(0o600)
    return report


def main():
    os.umask(0o077)
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest="command",required=True)
    c=sub.add_parser("collect"); c.add_argument("--output",type=Path,required=True)
    c.add_argument("--start",required=True); c.add_argument("--end",required=True)
    c.add_argument("--symbols",nargs="+",required=True); c.add_argument("--resume",action="store_true")
    for name in ("check","run"):
        p=sub.add_parser(name); p.add_argument("--study",type=Path,required=True)
        if name=="run": p.add_argument("--output",type=Path,required=True)
    args=parser.parse_args()
    try:
        if args.command=="collect":
            result=collect_study(args.output,args.start,args.end,args.symbols,args.resume)
            print(json.dumps({"status":result["status"],"archives":len(result["archives"])}))
        elif args.command=="check":
            quality=load_study(args.study)[2]; print(json.dumps(quality,indent=2))
            return 0 if quality["valid"] else 1
        else:
            result=run_study(args.study,args.output)
            print(json.dumps({"status":result["status"],"promotable":False,"folds":len(result["folds"]),
                              "test_sessions":result["test_sessions"],"report":str(args.output/"report.md")}))
    except (r.ResearchError,OSError,sqlite3.Error) as error:
        print("Research stopped: "+(str(error) if isinstance(error,r.ResearchError) else type(error).__name__),file=sys.stderr)
        return 1
    return 0


if __name__=="__main__": sys.exit(main())
