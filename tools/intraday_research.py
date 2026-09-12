#!/usr/bin/env python3
"""Private, bounded Massive minute archives and offline research benchmarks.

No app mutations, orders, model downloads or automatic promotion. A historical
backfill and a hand-picked universe are NOT point-in-time investment evidence.
"""
import argparse
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import statistics
import sys
import urllib.error
import urllib.request
from zoneinfo import ZoneInfo

NY = ZoneInfo("America/New_York")
MINUTE = 60_000
COSTS = (1, 5, 10, 50)  # round-trip bps, assumptions, never a broker tariff
THRESHOLDS = (0, .0005, .001, .002)
INITIAL_EQUITY = 10_000.0
FEATURES = ("return_5m", "return_15m", "return_60m", "volatility_95m",
            "last_bar_range", "relative_volume_100m", "session_fraction")


class ResearchError(Exception):
    """Sanitized, user-facing failure; never include provider bodies or keys."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def ny_date(timestamp):
    return datetime.fromtimestamp(timestamp/1000, NY).date().isoformat()


def regular(timestamp):
    d = datetime.fromtimestamp(timestamp/1000, NY)
    return d.weekday() < 5 and 570 <= d.hour*60+d.minute < 960


def digest(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def write_json(path, value):
    with Path(path).open("x", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, allow_nan=False)
        handle.write("\n")
    Path(path).chmod(0o600)


def private_directory(path):
    path = Path(path)
    if path.exists() or path.is_symlink():
        raise ResearchError("Output exists; choose a new archive/report directory.")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.mkdir(mode=0o700)
    return path


def check_request(symbols, start, end):
    if not 1 <= len(symbols) <= 10 or len(set(symbols)) != len(symbols):
        raise ResearchError("Specify 1–10 unique US ticker symbols.")
    if any(not re.fullmatch(r"[A-Z]{1,5}", s) for s in symbols):
        raise ResearchError("Only explicit alphabetic US equity tickers are supported.")
    try:
        first, last = date.fromisoformat(start), date.fromisoformat(end)
        if first.isoformat()!=start or last.isoformat()!=end:
            raise ValueError()
    except ValueError:
        raise ResearchError("Dates must be YYYY-MM-DD.") from None
    if not 0 <= (last-first).days < 14:
        raise ResearchError("Each archive must cover 1–14 calendar days.")
    if last >= datetime.now(NY).date():
        raise ResearchError("Historical collection must end before today in New York.")


def credential():
    # The app key lives in its private Keychain. CLI collection requires an explicit
    # environment credential; never extract app secrets or place them in argv.
    key = os.environ.get("MASSIVE_API_KEY", "").strip()
    if not 12 <= len(key) <= 256 or any(not 33 <= ord(c) <= 126 for c in key):
        raise ResearchError("No usable Massive credential; configure MASSIVE_API_KEY for this command. The app’s private Keychain is not read.")
    return key


def provider_fetcher():
    key = credential()
    opener = urllib.request.build_opener(NoRedirect())

    def fetch(symbol, start, end):
        url = (f"https://api.massive.com/v2/aggs/ticker/{symbol}/range/1/minute/{start}/{end}"
               "?adjusted=false&sort=asc&limit=50000")
        request = urllib.request.Request(url, headers={"Authorization": "Bearer " + key,
                                                     "User-Agent": "StockSage-private-research/1"})
        try:
            with opener.open(request, timeout=20) as response:
                body = response.read(10_000_001)
        except urllib.error.HTTPError as error:
            raise ResearchError(f"Massive HTTP {error.code}; collection stopped, no automatic retry.") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise ResearchError("Massive transport failed; collection stopped.") from None
        if len(body) > 10_000_000:
            raise ResearchError("Provider page exceeds the 10 MB ceiling.")
        if key.encode() in body:
            raise ResearchError("Provider echoed a credential; response was not archived.")
        return body
    return fetch


def validate_payload(payload, symbol, start, end):
    if not isinstance(payload, dict) or payload.get("ticker") != symbol:
        raise ResearchError("Provider payload ticker mismatch.")
    if payload.get("status") not in ("OK", "DELAYED") or payload.get("adjusted") is not False:
        raise ResearchError("Expected successful unadjusted historical aggregates.")
    if payload.get("next_url"):
        # ponytail: bounded date chunks only; add validated pagination for larger archives.
        raise ResearchError("Paginated response: split the date range; partial data is not accepted.")
    rows = payload.get("results", [])
    if not isinstance(rows, list) or len(rows) > 50_000 or payload.get("resultsCount", 0) != len(rows):
        raise ResearchError("Invalid aggregate row count.")
    result, previous = [], -1
    for row in rows:
        if not isinstance(row, dict):
            raise ResearchError("Invalid aggregate row.")
        t = row.get("t")
        if type(t) is not int or t <= previous or t % MINUTE != 0:
            raise ResearchError("Duplicate, unordered or non-minute aggregate timestamp.")
        try:
            in_range = start <= ny_date(t) <= end
        except (ValueError, OverflowError, OSError):
            in_range = False
        if not in_range:
            raise ResearchError("Aggregate lies outside the requested local dates.")
        for k in ("o", "h", "l", "c", "v"):
            value = row.get(k)
            try:
                finite = type(value) in (int, float) and math.isfinite(value)
            except OverflowError:
                finite = False
            if not finite:
                raise ResearchError("Nonfinite or missing OHLCV value.")
        if not (0 < row["l"] <= min(row["o"], row["c"]) <= max(row["o"], row["c"]) <= row["h"]
                and row["v"] >= 0):
            raise ResearchError("Invalid OHLC range or negative volume.")
        result.append({"symbol": symbol, "t": t, **{k:float(row[k]) for k in ("o","h","l","c","v")}})
        previous = t
    return result


def collect(symbols, start, end, output, fetch):
    check_request(symbols, start, end)
    output = private_directory(output)
    manifest = {"schema": 1, "status": "incomplete", "provider": "Massive", "adjusted": False,
                "interval": "1 minute", "symbols": symbols, "start": start, "end": end,
                "collected_at": utc_now(), "universe": "owner-selected today; not point-in-time",
                "availability": "historical backfill; publication and correction latency unknown",
                "counts": {}, "responses": {}, "runner_sha256": digest(__file__)}
    database = output/"archive.sqlite3"
    db = sqlite3.connect(database)
    database.chmod(0o600)
    try:
        db.executescript("CREATE TABLE responses(symbol TEXT PRIMARY KEY, received_at TEXT, sha256 TEXT, body BLOB);"
                         "CREATE TABLE bars(symbol TEXT,t INTEGER,o REAL,h REAL,l REAL,c REAL,v REAL,PRIMARY KEY(symbol,t));")
        for symbol in symbols:
            raw = fetch(symbol, start, end)
            try:
                value = json.loads(raw)
            except (ValueError, UnicodeDecodeError):
                raise ResearchError("Provider returned invalid JSON.") from None
            rows = validate_payload(value, symbol, start, end)
            kept = [b for b in rows if regular(b["t"])]
            if not kept:
                raise ResearchError(f"No usable regular-session bars for {symbol}; archive incomplete.")
            received, sha = utc_now(), hashlib.sha256(raw).hexdigest()
            with db:
                db.execute("INSERT INTO responses VALUES(?,?,?,?)", (symbol, received, sha, raw))
                db.executemany("INSERT INTO bars VALUES(?,?,?,?,?,?,?)",
                               [(b["symbol"],b["t"],b["o"],b["h"],b["l"],b["c"],b["v"]) for b in kept])
            days = defaultdict(int)
            for b in kept: days[ny_date(b["t"])]+=1
            manifest["counts"][symbol] = {"raw_minutes":len(rows), "regular_minutes":len(kept),
                                           "by_session":dict(days)}
            manifest["responses"][symbol] = {"sha256":sha,"received_at":received}
        manifest["status"] = "complete"
    except BaseException:
        manifest["status"] = "failed"
        raise
    finally:
        db.close()
        manifest["archive_sha256"] = digest(database)
        write_json(output/"manifest.json", manifest)
    return manifest


def load_archive(path):
    path = Path(path)
    try:
        manifest = json.loads((path/"manifest.json").read_text())
        database = path/"archive.sqlite3"
        if manifest.get("schema") != 1 or manifest.get("status") != "complete":
            raise ResearchError("Archive is incomplete or unsupported.")
        if database.stat().st_size > 128_000_000 or digest(database) != manifest.get("archive_sha256"):
            raise ResearchError("Archive checksum/size failed; do not benchmark altered inputs.")
        db = sqlite3.connect(database.resolve().as_uri()+"?mode=ro", uri=True)
        db.row_factory = sqlite3.Row
        try:
            bars = [dict(b) for b in db.execute("SELECT * FROM bars ORDER BY symbol,t")]
        finally:
            db.close()
    except (OSError, ValueError, sqlite3.Error):
        raise ResearchError("Archive could not be read or validated.") from None
    if not bars:
        raise ResearchError("Archive contains no bars.")
    return manifest, bars


def feature_vector(window, signal):
    """Existing seven features from twenty completed five-minute bars; no labels."""
    closes=[b["c"] for b in window]
    returns=[b/a-1 for a,b in zip(closes,closes[1:])]
    mean_volume=statistics.fmean(b["v"] for b in window)
    local=datetime.fromtimestamp(signal/1000,NY)
    return [closes[-1]/closes[-2]-1,closes[-1]/closes[-4]-1,closes[-1]/closes[-13]-1,
            statistics.pstdev(returns),(window[-1]["h"]-window[-1]["l"])/closes[-1],
            window[-1]["v"]/mean_volume if mean_volume else 0,
            (local.hour*60+local.minute-570)/390]


def examples(bars, horizon=15, delay=1):
    if type(horizon) is not int or horizon <= 0 or type(delay) is not int or delay < 1:
        raise ResearchError("Horizon must be positive; entry delay must be at least one minute.")
    minutes = {(b["symbol"],b["t"]):b for b in bars if regular(b["t"])}
    if len(minutes) != len(bars):
        raise ResearchError("Benchmark requires unique regular-session bars.")
    buckets = defaultdict(list)
    for b in minutes.values(): buckets[(b["symbol"],b["t"]//(5*MINUTE)*(5*MINUTE))].append(b)
    quality = {"incomplete_five_minute_buckets":0, "feature_windows_with_gaps":0,
               "missing_or_overnight_labels":0, "zero_volume_labels":0}
    sessions = defaultdict(list)
    for (symbol,t), rows in sorted(buckets.items()):
        rows.sort(key=lambda b:b["t"])
        if [b["t"] for b in rows] != [t+i*MINUTE for i in range(5)]:
            quality["incomplete_five_minute_buckets"]+=1
            continue
        sessions[(symbol,ny_date(t))].append({"t":t,"c":rows[-1]["c"],
            "h":max(b["h"] for b in rows),"l":min(b["l"] for b in rows),"v":sum(b["v"] for b in rows)})
    samples = []
    for (symbol,day), rows in sorted(sessions.items()):
        for i in range(19,len(rows)):
            window=rows[i-19:i+1]
            if any(b["t"] != window[0]["t"]+j*5*MINUTE for j,b in enumerate(window)):
                quality["feature_windows_with_gaps"]+=1
                continue
            signal=window[-1]["t"]+5*MINUTE
            entry_t=signal+delay*MINUTE; exit_t=entry_t+horizon*MINUTE
            entry, exit_bar=minutes.get((symbol,entry_t)),minutes.get((symbol,exit_t))
            if not entry or not exit_bar or ny_date(exit_t)!=day:
                quality["missing_or_overnight_labels"]+=1
                continue
            if entry["v"] <= 0 or exit_bar["v"] <= 0:
                quality["zero_volume_labels"]+=1
                continue
            x=feature_vector(window,signal)
            samples.append({"symbol":symbol,"date":day,"signal_t":signal,"entry_t":entry_t,
                            "exit_t":exit_t,"entry":entry["o"],"exit":exit_bar["o"],"x":x,
                            "y":exit_bar["o"]/entry["o"]-1})
    samples.sort(key=lambda s:(s["signal_t"],s["symbol"]))
    return samples, quality


def partition(samples, train_through, valid_through):
    try:
        if date.fromisoformat(train_through) >= date.fromisoformat(valid_through):
            raise ValueError()
    except ValueError:
        raise ResearchError("Training boundary must precede validation boundary (YYYY-MM-DD).") from None
    groups=([s for s in samples if s["date"]<=train_through],
            [s for s in samples if train_through<s["date"]<=valid_through],
            [s for s in samples if s["date"]>valid_through])
    if not all(groups):
        raise ResearchError("Train, validation and test each need usable whole-session examples.")
    if any(max(s["exit_t"] for s in a)>=min(s["signal_t"] for s in b) for a,b in zip(groups,groups[1:])):
        raise ResearchError("Overlapping label intervals across partitions.")
    return groups


def simulate(samples, predictions, bars, threshold, cost_bps, *, initial_equity=INITIAL_EQUITY, prior_peak=None):
    if len(samples)!=len(predictions) or any(not math.isfinite(p) for p in predictions):
        raise ResearchError("Missing/nonfinite predictions.")
    if not samples or not math.isfinite(cost_bps) or not 0<=cost_bps<=1000 or not math.isfinite(threshold) or threshold<0:
        raise ResearchError("Invalid simulation inputs.")
    if not math.isfinite(initial_equity) or initial_equity<=0 or (prior_peak is not None and
            (not math.isfinite(prior_peak) or prior_peak<initial_equity)):
        raise ResearchError("Invalid starting capital or historical high-water equity.")
    prices={(b["symbol"],b["t"]):b["o"] for b in bars}
    events=defaultdict(list)
    for sample,prediction in zip(samples,predictions):
        if prediction>threshold: events[sample["entry_t"]].append((prediction,sample))
    cash=initial_equity; peak=prior_peak if prior_peak is not None else initial_equity
    minimum_cash=cash; drawdown=turnover=fees=0.0
    max_positions=0; max_fraction=0.0; positions={}; trades=[]; daily={}
    half_cost=cost_bps/20_000
    dates={s["date"] for s in samples}
    for t in range(min(s["entry_t"] for s in samples),max(s["exit_t"] for s in samples)+MINUTE,MINUTE):
        def mark(symbol):
            value=prices.get((symbol,t))
            if value is None or not math.isfinite(value) or value<=0:
                raise ResearchError("Missing minute-open mark for an exposed position; drawdown cannot be verified.")
            return value
        # Mark holdings before processing any fills. Missing marks never become stale prices.
        marks={symbol:mark(symbol) for symbol in positions}
        for symbol,position in list(positions.items()):
            if position["exit_t"]==t:
                notional=position["shares"]*marks[symbol]; fee=notional*half_cost
                cash+=notional-fee; fees+=fee; turnover+=notional
                trades.append({**position,"symbol":symbol,"exit_price":marks[symbol],"exit_fee":fee,
                               "net_pnl":notional-fee-position["entry_notional"]-position["entry_fee"]})
                del positions[symbol]
        for score,sample in sorted(events.get(t,[]),key=lambda pair:(-pair[0],pair[1]["symbol"])):
            symbol=sample["symbol"]
            if symbol in positions or len(positions)>=5: continue
            price=mark(symbol)
            equity=cash+sum(p["shares"]*marks[s] for s,p in positions.items())
            budget=min(cash,.20*equity)
            shares=math.floor(budget/(price*(1+half_cost)))
            if shares<1: continue
            notional=shares*price; fee=notional*half_cost
            cash-=notional+fee; fees+=fee; turnover+=notional
            positions[symbol]={"entry_t":t,"exit_t":sample["exit_t"],"shares":shares,
                               "entry_price":price,"entry_notional":notional,"entry_fee":fee,"prediction":score}
            marks[symbol]=price
            max_fraction=max(max_fraction,notional/equity)
        equity=cash+sum(p["shares"]*marks[s] for s,p in positions.items())
        peak=max(peak,equity); drawdown=max(drawdown,1-equity/peak)
        minimum_cash=min(minimum_cash,cash); max_positions=max(max_positions,len(positions))
        if ny_date(t) in dates: daily[ny_date(t)]=equity
        if cash < -1e-7: raise ResearchError("Cash conservation failed: simulation would borrow.")
    if positions: raise ResearchError("Simulation ended with unclosed positions.")
    return {"ending_equity":cash,"net_return":cash/initial_equity-1,"max_drawdown":drawdown,"peak_equity":peak,
            "trades":len(trades),"turnover":turnover/initial_equity,"fees":fees,
            "minimum_cash":minimum_cash,"max_positions":max_positions,
            "max_entry_equity_fraction":max_fraction,"daily_equity":daily,"trade_log":trades}


def fit_predictors(train, use_lightgbm):
    predictors={"zero":lambda rows:[0.0]*len(rows),
                "momentum":lambda rows:[s["x"][1] for s in rows],
                "reversal":lambda rows:[-s["x"][1] for s in rows]}
    metadata={"features":FEATURES,"training_rows":len(train)}
    model=None
    if use_lightgbm:
        try:
            import numpy as np
            import lightgbm as lgb
            import scipy
        except (ImportError,OSError):
            raise ResearchError("LightGBM unavailable; install the documented isolated research environment.") from None
        params={"objective":"regression","metric":"l1","num_leaves":7,"max_depth":3,
                "learning_rate":.05,"min_data_in_leaf":50,"lambda_l2":1.0,
                "seed":7,"deterministic":True,"force_col_wise":True,"num_threads":1,"verbosity":-1}
        model=lgb.train(params,lgb.Dataset(np.asarray([s["x"] for s in train]),
                         label=np.asarray([s["y"] for s in train]),feature_name=list(FEATURES)),num_boost_round=50)
        predictors["lightgbm"]=lambda rows:model.predict(np.asarray([s["x"] for s in rows]),num_threads=1).tolist()
        metadata.update({"lightgbm_version":lgb.__version__,"numpy_version":np.__version__,
                         "scipy_version":scipy.__version__,"parameters":params,"boost_rounds":50})
    return predictors,metadata,model


def benchmark(archive, output, train_through, valid_through, use_lightgbm=False):
    if Path(output).exists(): raise ResearchError("Report exists; choose a new output path.")
    manifest,bars=load_archive(archive)
    samples,quality=examples(bars,15,1)
    train,valid,test=partition(samples,train_through,valid_through)
    predictors,fit,model=fit_predictors(train,use_lightgbm)
    _,_,delayed=partition(examples(bars,15,6)[0],train_through,valid_through)
    frozen={}; validation=[]; results=[]
    for name,predict in predictors.items():
        predictions=predict(valid)
        trials=[]
        for threshold in THRESHOLDS:
            score=simulate(valid,predictions,bars,threshold,5)
            trials.append((threshold,score))
            validation.append({"model":name,"threshold":threshold,"net_return":score["net_return"],"trades":score["trades"]})
        selected=max(trials,key=lambda trial:(trial[1]["net_return"],-trial[1]["trades"],trial[0]))[0]
        frozen[name]=selected
        for delay,rows in ((1,test),(6,delayed)):
            predicted=predict(rows)
            mae=statistics.fmean(abs(p-s["y"]) for p,s in zip(predicted,rows))
            for cost in COSTS:
                result=simulate(rows,predicted,bars,selected,cost)
                results.append({"model":name,"entry_delay_minutes":delay,"round_trip_cost_bps":cost,
                                "threshold":selected,"examples":len(rows),"prediction_mae":mae,**result})
    report={"schema":1,"created_at":utc_now(),"status":"engineering smoke only","promotable":False,
            "archive_sha256":manifest["archive_sha256"],"runner_sha256":digest(__file__),
            "symbols":manifest["symbols"],"period":[manifest["start"],manifest["end"]],
            "train_through":train_through,"valid_through":valid_through,
            "partition_counts":{"train":len(train),"validation":len(valid),"test":len(test)},
            "session_counts":{k:len({s["date"] for s in rows}) for k,rows in (("train",train),("validation",valid),("test",test))},
            "quality":quality,"fit":fit,"selection_partition":"validation only",
            "selection_cost_bps":5,"tried_policies":len(predictors)*len(THRESHOLDS),
            "frozen_thresholds":frozen,"validation":validation,"results":results,
            "limitations":["Selected present-day universe: survivorship/selection bias not removed.",
                "Historical backfill is not historical publication availability; provider corrections unknown.",
                "Missing future labels are excluded: potential tradability-selection bias; counts disclosed.",
                "Bar opens are hypothetical fills; actual spread, NBBO, queueing and market impact unmeasured.",
                "Broker minimum commissions, FX and exact account restrictions are unpriced.",
                "Regular-session weekdays only; no authoritative holiday/half-day/halts calendar.",
                "Minute-open sampled drawdown is not intrabar risk; no protective stop modeled.",
                "No statistical significance, durable edge or 5-percent-weekly conclusion from this smoke test.",
                "Delay stress can exclude different end-of-day samples; row counts are disclosed.",
                "No model selection on test; all candidates/scenarios reported; no promotion to app/orders."]}
    output=private_directory(output)
    if model is not None:
        model.save_model(str(output/"lightgbm.txt"))
        (output/"lightgbm.txt").chmod(0o600)
        report["model_sha256"]=digest(output/"lightgbm.txt")
    write_json(output/"report.json",report)
    lines=["# Intraday research — engineering smoke only", "", "**Not promotable. No real orders or app decisions changed.**", "",
           f"Period: {manifest['start']} through {manifest['end']}. Train through {train_through}; validate through {valid_through}.",
           f"Rows: {report['partition_counts']}. Sessions: {report['session_counts']}.",
           f"Validation-only policies tried: {report['tried_policies']}; fixed5bps assumed selection cost.",
           "USD10,000 simulated capital; long-only, whole shares, five positions,20% maximum allocation per entry.", "",
           "| Candidate | Delay min | Cost RT bps | Test rows | Trades | Net return | Minute-open drawdown | Turnover |",
           "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for x in results:
        lines.append(f"| {x['model']} | {x['entry_delay_minutes']} | {x['round_trip_cost_bps']} | {x['examples']} | {x['trades']} | {x['net_return']:.3%} | {x['max_drawdown']:.3%} | {x['turnover']:.2f}x |")
    lines.extend(["", "## Limitations", "", *["- "+s for s in report["limitations"]], "", "## Provenance", "",
                  f"Archive SHA256: `{report['archive_sha256']}`", f"Runner SHA256: `{report['runner_sha256']}`", ""])
    with (output/"report.md").open("x") as handle: handle.write("\n".join(lines))
    (output/"report.md").chmod(0o600)
    return report


def main():
    os.umask(0o077)
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest="command",required=True)
    c=sub.add_parser("collect"); c.add_argument("--symbols",nargs="+",required=True)
    c.add_argument("--start",required=True); c.add_argument("--end",required=True)
    c.add_argument("--output",type=Path,required=True)
    b=sub.add_parser("benchmark"); b.add_argument("--archive",type=Path,required=True)
    b.add_argument("--output",type=Path,required=True)
    b.add_argument("--train-through",required=True); b.add_argument("--valid-through",required=True)
    b.add_argument("--lightgbm",action="store_true")
    args=parser.parse_args()
    try:
        if args.command=="collect":
            check_request(args.symbols,args.start,args.end)
            report=collect(args.symbols,args.start,args.end,args.output,provider_fetcher())
            print(json.dumps({"status":report["status"],"counts":report["counts"]},indent=2))
        else:
            report=benchmark(args.archive,args.output,args.train_through,args.valid_through,args.lightgbm)
            print(json.dumps({"status":report["status"],"promotable":report["promotable"],
                              "partition_counts":report["partition_counts"],"report":str(args.output/"report.md")},indent=2))
    except (ResearchError,OSError,sqlite3.Error) as error:
        print("Research stopped: "+(str(error) if isinstance(error,ResearchError) else type(error).__name__),file=sys.stderr)
        return 1
    return 0


if __name__=="__main__": sys.exit(main())
