# Private intraday research

This is a separate offline research tool, not the StockSage signal engine. It
does not change Qwen, app badges, trade sizing, journal records or broker orders.
The first milestone is a reproducible data/benchmark check, **not an edge claim**.

## Reproduce

From the repository root. Collection and the three simple baselines use Python
3.12+ standard library only. The optional fixed LightGBM fit uses a private venv:

```sh
# First-time setup only; keep this separate from Qwen's Python environment.
python3.12 -m venv .research/venv
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install libomp
.research/venv/bin/python -m pip install --only-binary=:all: \
  lightgbm==4.6.0 numpy==2.2.6 scipy==1.18.1

.research/venv/bin/python -m unittest discover -s tools -p 'test_intraday*.py' -v
```

macOS27 rejected the old SciPy1.15.3 wheel's `_spropack` Mach-O zero-fill section;
SciPy1.18.1 imports and passes this suite. Homebrew libomp23.1.0 was the working
runtime. No binary patch, loader-security bypass or global Python change.

Read-only provider access uses the app's existing `stocksage.massive.key` in
`SA.StockSage` preferences, falling back to `MASSIVE_API_KEY`. Do not put a key on
the command line or in a file under this repo. TLS is verified; credentials are
header-only; redirects and pagination are rejected rather than followed. Archives
are at most ten unique alphabetic tickers by fourteen past calendar days. Choose
a NEW output path for every run; existing data and reports are never overwritten.

```sh
python3 tools/intraday_research.py collect \
  --symbols AAPL MSFT NVDA AMZN GOOGL META TSLA ORCL QCOM APP \
  --start 2026-08-31 --end 2026-09-04 \
  --output .research/archives/20260908-five-session-smoke-v1

.research/venv/bin/python tools/intraday_research.py benchmark \
  --archive .research/archives/20260908-five-session-smoke-v1 \
  --output .research/runs/20260908-five-session-smoke-v1 \
  --train-through 2026-09-02 --valid-through 2026-09-03 --lightgbm
```

The executed paths above already exist on the owner's Mac. Reuse the archive for
offline runs with a new report directory. Omit `--lightgbm` to use only the
standard-library candidates; the optional LightGBM test will explicitly skip if
that package is not installed. Never mistake that skip for model verification.

## What is measured

- SQLite stores raw successful responses with SHA256/retrieval time, and validated
  unadjusted regular-session one-minute bars. A manifest checksum binds the DB;
  failed/partial collections cannot be benchmarked. Raw and normalized prices
  remain private under ignored `.research/` (directories0700, data files0600).
- Five consecutive minutes form a completed five-minute bar; twenty consecutive
  bars form the feature window. Missing minutes are never filled. Local sessions
  use America/New_York/DST and reset daily. Missing/overnight targets are counted.
- Features: past5/15/60-minute returns,95-minute return volatility, last-bar range,
  relative100-minute volume and time of day. No future prices, news or outcomes
  are features. Entry is a minute AFTER the signal closes, exit fifteen minutes
  after entry, using observed minute opens as hypothetical fills.
- Whole dates partition every symbol identically. Training label exits must precede
  the first validation signal; validation exits precede the first test signal.
  The optional LightGBM model sees training only:50 rounds,7 leaves,depth3,
  learning rate0.05,50-row minimum leaf,L2=1,seed7,one CPU thread.
- No-trade, momentum, reversal and LightGBM each select one of0/5/10/20bps entry
  thresholds on validation only at5bps assumed round-trip cost. All16 attempted
  policies are recorded. No candidate is selected/promoted using the test day.
- USD10,000 simulated equity; long-only, whole shares, no borrowing; at most five
  simultaneous positions and20% equity per entry. Exits precede new entries.
  Half the assumed round-trip cost is applied to actual notional on each side.
  Held positions are marked every minute; missing marks fail instead of hiding risk.
- Test costs:1/5/10/50bps round-trip, with1-minute entry delay and a separate
  6-minute stress. The latter loses an additional end-of-day sample per symbol;
  its sample count is explicit, not represented as an identical trade cohort.
- Reports retain all32 scenario results, individual simulated fills/fees, daily
  equity, minute-open drawdown, turnover, MAE, source/runner/model hashes and exact
  library parameters/versions. `promotable` is always false in this milestone.

## Executed 2026-09-08

Ten real Massive responses:38,899 raw minute observations,19,500 regular-session
bars, all390 expected minutes in each of50 stock-sessions. No missing five-minute
buckets or feature-window gaps.200 end-of-day candidate labels excluded; no
zero-volume entry/exit exclusions. Train1,650 examples (3 days), validation550
(1 day), test550 (1 day); delayed stress540 test examples.

17 offline tests passed including the actual LightGBM fit. Independent replay
verified ten raw hashes, all normalized session counts, absence of the active
credential in the DB, and exact repeated equality of the model hash, validation
choices and all32 scenarios. Benchmark wall0.43s, maximum RSS79,822,848 bytes,
peak memory footprint62,358,032 bytes; zero swaps in that measured run.

At the predeclared1-minute delay/5bps assumed cost on **one** held-out day:

| Candidate | Trades | Simulated portfolio net return |
|---|---:|---:|
| No-trade | 0 | 0.000% |
| Momentum | 36 | -0.311% |
| Reversal | 32 | -0.410% |
| LightGBM | 0 | 0.000% |

All validation-selected thresholds were20bps. LightGBM not trading is neither a
profitable-model finding nor a reason to retune against the observed test day.
These results test plumbing only. Do not annualize them or infer weekly returns.

## Predeclared multi-archive walk-forward pilot

`intraday_walkforward.py` reuses the same collector, features, fixed models and
simulator. It adds a sourced2026 exchange calendar and rolls20 training sessions,
5 validation sessions and up to5 disjoint test sessions. June1–August31 has64
scheduled sessions:8 folds,39 test sessions,4 days in the last test block.
The ten-symbol universe is unchanged and still NOT point-in-time.

```sh
.research/venv/bin/python tools/intraday_walkforward.py collect \
  --output .research/studies/20260908-jun-aug-v1 \
  --start 2026-06-01 --end 2026-08-31 \
  --symbols AAPL MSFT NVDA AMZN GOOGL META TSLA ORCL QCOM APP

.research/venv/bin/python tools/intraday_walkforward.py check \
  --study .research/studies/20260908-jun-aug-v1

.research/venv/bin/python tools/intraday_walkforward.py run \
  --study .research/studies/20260908-jun-aug-v1 \
  --output .research/runs/20260908-jun-aug-v1
```

The immutable `study.json` is written before network access, naming symbols,
dates, thresholds, costs, delays and both runner hashes. Collection is bounded
to95 calendar days/10 tickers, in14-day chunks (70 requests for this study).
An explicit `--resume` reuses verified complete chunks, preserves failed attempts,
and refuses changed specifications/code. It never automatically retries an auth
failure or replaces a corrupt complete archive. At most three attempts per chunk.

Quality requires every scheduled minute of every symbol/session:249,600 expected
minutes for this study. No dropping bad stocks/days, forward filling, or scoring
through a gap. `run` preserves `quality.json` and stops before performance/model
output on a coverage failure. A missing aggregate is not automatically a vendor
defect: a halt or absence of qualifying trades also needs investigation.

Each model refits on training only; threshold selection stays validation-only at
the same assumed5bps cost. All128 validation policies and32 aggregate cost/delay
scenarios remain visible. Each scenario carries its own capital and high-water
mark across test folds; no reset toUSD10k and no double-counted test dates. Daily
equity, losing days, fees, turnover, fold boundaries/model hashes and feature/label
exclusions are retained. Earlier test dates may enter later training after those
dates have elapsed. No overall winner is selected on test results.

This report omits duplicate per-fill logs and prediction MAE; fills are reproducible
from the archived bars and saved fold models. The first smoke report retains both.
No new dependency, app integration, Qwen inference or real-order capability.

Calendar: [Nasdaq2026 schedule](https://www.nasdaq.com/market-activity/stock-market-holiday-schedule),
[July3 closure notice](https://www.nasdaqtrader.com/TraderNews.aspx?id=ETA2026-31),
[NYSE2026 calendar](https://www.nyse.com/publicdocs/nyse/ICE_NYSE_2026_Yearly_Trading_Calendar.pdf).
June19/July3 are closed; July2 is a full equity session. Nov27/Dec24 close at13:00ET.
Dates outside2026 are refused until a new authoritative calendar is verified.
This is a scheduled calendar, not historical halt or publication-availability data.

### Executed walk-forward result — 2026-09-08

All70 requests succeeded on the first attempt:516,031 raw observations and
249,600 scheduled minutes across64 sessions/640 stock-sessions. Zero missing
minutes, five-minute bucket gaps, feature-window gaps or zero-volume label
exclusions. The1/6-minute variants exclude2,560/3,200 end-of-day labels respectively.
Held-out test dates are **July8–August31** (39 sessions), not the full collection
period. Earlier June dates supply the initial training and validation partitions.

At the predeclared1-minute delay/5bps **assumed** round-trip cost:

| Candidate | Trades | Simulated net return | Minute-open drawdown | Losing days |
|---|---:|---:|---:|---:|
| No-trade | 0 | 0.000% | 0.000% | 0 |
| Momentum | 2056 | -17.878% | 18.184% | 33 |
| Reversal | 1942 | -17.347% | 18.678% | 28 |
| LightGBM | 127 | -1.646% | 2.128% | 9 |

Every active candidate also loses in every other tested cost/delay scenario,
including1bps round trip. Lower loss from less trading is not a profitable edge,
superior predictive-skill proof, or evidence for5% weekly returns. These dates
are now observed research data; do not retune against them and call the next run
an untouched test. No strategy was promoted to StockSage/Qwen or real orders.

Independent checks verified all70 raw response hashes/counts, active-credential
absence and0600 DB permissions. Two offline executions reproduce all8 fitted
model files,128 validation policies,32 scenarios and report markdown exactly.
Per-fold capital/cash/caps and39 unique daily equity entries checked independently.
26 regression tests pass, including an actual two-fold fit/replay and changed-code
refusal. Benchmark7.91s wall,324,141,056-byte maxRSS,306,791,096-byte peak footprint,
zero swaps; no local GPU inference or Qwen environment changes.

Private reports: `.research/runs/20260908-jun-aug-v1{,-recheck}/report.{md,json}`.
Study SHA256: `7e549e6e820a505e5b0c04809ae881116813805d832b9a8485e1c279f14b7858`.
Collection SHA256: `325244f569b45ac614e2565b5826119ffbdd2492074a6dba7595506dd07777c2`.

## Required before investment conclusions

Larger prespecified walk-forward evaluation; point-in-time universe/delisting and
exchange-calendar coverage; publication/revision availability; real broker fees,
minimums,FX and NBBO execution assumptions; impact/capacity and settlement rules;
day-block uncertainty and multiple-testing adjustment; prospective frozen paper
record. Missing future-label exclusion can introduce tradability selection bias.
Minute-open drawdown misses intrabar risk; the baseline has no protective stop.
Shorts/borrow, overnight holds and real orders are intentionally unsupported.

Kronos/Chronos comparison and app integration are subsequent milestones, not
implemented or validated here. Do not replace the
existing app's price-history or money paths with this smoke runner.

Sources checked2026-09-08:
[Massive custom bars](https://massive.com/docs/rest/stocks/aggregates/custom-bars),
[LightGBM4.6 parameters](https://lightgbm.readthedocs.io/en/v4.6.0/Parameters.html),
[macOS OpenMP dependency](https://lightgbm.readthedocs.io/en/v4.6.0/Installation-Guide.html),
[SciPy loader issue](https://github.com/scipy/scipy/issues/25635).
