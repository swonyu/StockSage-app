# Intraday Research Foundation Implementation Plan

> **For agentic workers:** Use executing-plans inline. Owner requires this task
> only, no new tasks/subagents. Existing wt/coverage remains the isolated workspace.

**Goal:** Collect a small versioned minute archive and reproduce honest offline
baseline/LightGBM comparisons without changing the running trading app.

**Architecture:** One research CLI plus a standard-library test file. SQLite keeps
raw source responses and validated bars together; hashed manifests bind reports
to the immutable input and exact runner. No server or app integration.

**Tech Stack:** Python3.12+, sqlite3, zoneinfo, urllib, unittest; optional LightGBM.

## Global constraints

Use the numerical limits/splits/costs in the approved design, and keep all raw
data and venv files under ignored .research/. Never log credentials, follow
redirects, overwrite archives/reports, change Swift/app settings, restart Qwen,
submit trades, push, or merge. No claim of profitable or live-ready models.

## Task1: bounded immutable collection

Files: tools/intraday_research.py, tools/test_intraday_research.py, .gitignore.
Interfaces: validate_payload(payload,symbol,start,end)->list[dict];
collect(symbols,start,end,output,fetch)->dict; load_archive(path)->(manifest,bars).

- [x] Write failing unittest cases for malformed/duplicate/nonfinite/out-of-range
  bars, symbol/date bounds, redirect refusal and no-overwrite/hash verification.
- [x] Implement fixed-host/header-auth collection and private SQLite manifests.
- [x] Run `python3 -m unittest discover -s tools -p test_intraday_research.py -v`.

Example invariant exercised by the tests:
```python
with self.assertRaises(ResearchError):
    validate_payload({"ticker":"AAPL", "status":"OK", "adjusted":False,
                      "results":[bar,bar], "resultsCount":2},
                     "AAPL", "2026-08-31", "2026-09-04")
```

## Task2: completed-bar features and frozen comparisons

Interfaces: examples(bars,horizon,delay)->(samples,quality);
partition(samples,train_through,valid_through)->(train,valid,test);
simulate(samples,predictions,bars,threshold,cost_bps)->dict;
benchmark(archive,output,train_through,valid_through,lightgbm)->dict.

- [x] Write failing tests for feature-prefix invariance, missing minutes,
  strictly-later entry, same-session exits, partition isolation, whole shares,
  no leverage, cash conservation, costs, ties and unavailable marks.
- [x] Implement the three stdlib candidates, fixed optional LightGBM fit,
  validation-only threshold choice and frozen test/delay/cost reporting.
- [x] Exercise the complete collect/load/benchmark path with deterministic fake
  provider data, requiring an engineering-only report and reproducible results.
- [x] Run the complete research test file and existing stdlib import self-check.

Example signal contract:
```python
self.assertGreater(sample["entry_t"], sample["signal_t"])
self.assertEqual(sample["exit_t"]-sample["entry_t"], 15*60_000)
self.assertEqual(sample["date"], ny_date(sample["exit_t"]))
```

## Task3: live small sample and evidence

- [x] Collect the ten symbols and five sessions named in the design; preserve
  exact counts, missingness and failure state. HTTP errors never become success.
- [x] If needed create a research-only venv, install the small LightGBM dependency
  with a recorded version, then execute the one fixed CPU/thread-bounded fit.
- [x] Run predeclared split/scenarios, inspect all outputs, self-review every
  money/data boundary and run the regression suite again after any fixes.
- [x] Record commands, results, ceilings and remaining work in research README
  and HANDOFF. Explicit staging/heredoc commit on wt/coverage; keep unpushed.

No Swift changed: Python regressions and live artifact checks are the relevant
gate. macOS/iPhone1830/1827 previous gates are historical, not rerun or newly
claimed. No native UI/model certification is implied by this research delivery.

## Executed evidence

2026-09-08: initial red ImportError before implementing the CLI;15 stdlib checks
passed. Added intratrade drawdown and real LightGBM determinism/partition tests:
final17/17 pass in the isolated Python3.12 environment. LightGBM4.6.0 needed
Homebrew libomp23.1.0; SciPy1.15.3 failed macOS27 Mach-O validation, corrected
by replacing only that research-venv wheel with SciPy1.18.1. NumPy2.2.6 unchanged.
No loader bypass or binary patch. The earlier import-check shell also ran a
successful WhatsApp self-check afterward, so its shell exit0 was NOT interpreted
as a successful import; the actual failure and corrected17-test gate are recorded.

Real archive .research/archives/20260908-five-session-smoke-v1:19,500 RTH minutes,
50 complete390-minute stock-sessions, ten raw hashes checked, no credential value
in DB. Two offline benchmark runs reproduced all32 scenarios, validation choices
and model hash exactly.3/1/1 sessions,1650/550/550 examples; no missing feature
buckets,200 end-of-day labels excluded. One measured run0.43s/79,822,848-byte max
RSS/zero swaps. All reports remain engineering-only and not promotable.
