# Intraday Walk-forward Implementation Plan

> **For agentic workers:** Use executing-plans inline; owner prohibits new tasks
> or subagents. This extends the hybrid research approved at14:12 +03.

**Goal:** Reuse the tested archive/feature/simulator functions for a larger,
predeclared multi-archive pilot without changing any app decision.

**Architecture:** A separate CLI composes immutable14-day collections and rolls
training/validation/test dates. Only the shared simulator gains optional initial
capital/high-water inputs so test equity is continuous across folds.

**Tech Stack:** Existing Python3.12 research venv/SQLite/LightGBM; no new dependency.

## Fixed design and constraints

- Same ten preselected symbols and fixed models/thresholds as the smoke. June1
  through August31,2026; at most95 calendar days/10 tickers for this milestone.
- Before any fetch, write immutable study.json naming the period, symbols,
  calendar sources and20/5/5-session split. No test-data parameter changes.
- Nasdaq's2026 calendar: June19 and July3 closed; no July2 equity early close.
  Calendar supports only2026, includes all ten closed dates and Nov27/Dec24
  13:00 closes. It is a source-dated scheduled calendar, not a halt-status feed.
- Reuse collect/load_archive; every14-day chunk is separately hashed/private.
  Explicit --resume may reuse complete valid chunks, never overwrite them;
  a failed attempt is retained and at most three uniquely named attempts are
  allowed per chunk. Redirect/auth failures are never automatically retried.
- Merge only same-universe, same-provider/unadjusted archives with non-overlapping
  date ranges. Verify continuous requested calendar coverage and every expected
  symbol/session/minute. Missing scheduled bars fail the quality gate before
  scoring; publish the exact gaps, never discard problematic stocks/sessions.
- Roll20 training sessions,5 validation sessions,5 test sessions, advancing5.
  Last partial test block remains labelled with its actual count. All dates use
  the exchange calendar; training/validation labels must end before next partition.
- Refit the identical LightGBM recipe on training only; threshold on validation
  only. Save model hash and fold boundaries. No overall winner chosen on test.
- Each candidate/cost/delay scenario starts atUSD10k and carries cash/high-water
  equity between test blocks. End-of-day flattening means no positions bridge
  a model change. Fixed long-only/whole-share/five-position/20% caps unchanged.
- Report all32 scenarios, per-fold returns, date-indexed daily equity and losing
  days, sampled drawdown, aggregate fees/trades and all attempted policies. This
  retrospective hand-picked universe remains explicitly NOT point-in-time;
  actual broker fees/NBBO/settlement/halts and model significance remain unverified.
- Research remains unpromotable. No Qwen restart, model downloads, app/Swift/order
  changes, paid services, push, merge, owner-record writes or secret output.

Calendar evidence checked2026-09-08:
https://www.nasdaq.com/market-activity/stock-market-holiday-schedule
https://www.nasdaqtrader.com/TraderNews.aspx?id=ETA2026-31

## Task1: calendar, composition and rolling boundaries

Files: tools/intraday_walkforward.py, tools/test_intraday_walkforward.py.
Interfaces: scheduled_minutes(day)->int; chunks(start,end)->list[tuple[str,str]];
fold_dates(days)->list[dict]; collect_study(root,start,end,symbols,resume=False);
load_study(root)->(study,bars,quality).

- [x] Add regression checks for unsupported calendar years, holiday/half-day hours,
  non-overlapping14-day chunks, disjoint test folds, immutable study resume and
  strict missing-minute detection before performance scoring.
- [x] Implement bounded composition reusing intraday_research, with no network
  in tests (inject the existing fake fetcher).
- [x] Execute both research test files with the existing venv.

Example calendar and rolling invariants:
```python
self.assertEqual(scheduled_minutes("2026-07-02"),390)
self.assertEqual(scheduled_minutes("2026-07-03"),0)
self.assertEqual(scheduled_minutes("2026-11-27"),210)
self.assertEqual(len(test_dates),len(set(test_dates)))
```

## Task2: continuous-capital evaluation and live pilot

Files: tools/intraday_research.py (shared simulator only), new walk-forward CLI,
research README, HANDOFF.
Interface: simulate(...,initial_equity=10000.0,prior_peak=None) gains peak_equity;
run_study(root,output)->dict reuses fit_predictors/examples/simulate.

- [x] Write a regression proving a second fold inherits capital and high-water
  drawdown, with unchanged default one-day behavior and no leverage.
- [x] Implement validation-only rolling selection and all-scenario reporting.
- [x] Collect the predeclared June–August period (70 bounded requests maximum
  per complete attempt); verify quality before benchmarking. Stop on a gap,
  preserve quality evidence, and do not silently change the universe/calendar.
- [x] Run the bounded one-thread pilot; rerun offline for exact reproducibility.
- [x] Update evidence/docs, run all research tests and explicitly commit locally.

No Swift changes: no new Xcode/native acceptance claims. The approved macOS
redesign's remaining native checks are still separate and honestly pending.

Executed:70 successful requests,249,600 complete scheduled minutes;8 folds/39
held-out sessions. Every active model loses at every tested cost/delay.26 tests
pass and two full runs reproduce models, policy choices and all scenarios exactly.
Details and private artifact references are recorded in HANDOFF and the research
README. No strategy promotion, retuning against these test dates, push or merge.
