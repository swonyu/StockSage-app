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

## Kronos CPU compatibility — 2026-09-08

`tools/intraday_kronos.py` is a bounded engineering smoke, **not a new trading
strategy or a change to the previous walk-forward study**. It performs no network
access, training or orders. Reviewed upstream source, configuration and safetensors
must all match the eight exact size/SHA256 pins in `ASSETS` before model import.
Unexpected source/extension/bytecode files are refused. Public downloads were
anonymous and HTTPS-only; MIT LICENSE retained. Assets total114,878,586 bytes.

Official checkpoints: [Kronos-small](https://huggingface.co/NeoQuasar/Kronos-small)
24,741,696 parameters, model revision`901c26c1332695a2a8f243eb2f37243a37bea320`;
[Tokenizer-base](https://huggingface.co/NeoQuasar/Kronos-Tokenizer-base)
revision`0e0117387f39004a9016484a186a908917e22426`. Source pinned to
[Kronos67b630e](https://github.com/shiyu-coder/Kronos/tree/67b630e67f6a18c9e9be918d9b4337c960db1e9a).
The files are private under `.research/kronos-v1/{model,predictor,tokenizer}` plus
LICENSE. Downloaded only three Python files, license, two configs and two weight
files. Do not use arbitrary remote-code loading, pickle weights, auto device
selection or unpinned `main` model downloads in this runner.

Separate runtime, never Qwen's venv or the pinned LightGBM venv:

```sh
# Already installed on this Mac; first-time setup only.
.research/venv/bin/python -m venv .research/kronos-venv
.research/kronos-venv/bin/python -m pip install --only-binary=:all: \
  torch==2.14.0 numpy==2.2.6 pandas==2.2.2 einops==0.8.1 \
  huggingface_hub==0.33.1 safetensors==0.6.2 tqdm==4.67.1

# Assets must already have the pinned files. Choose a NEW report directory.
.research/kronos-venv/bin/python tools/intraday_kronos.py \
  --archive .research/studies/20260908-jun-aug-v1/chunk-2026-06-01-2026-06-14-attempt1 \
  --assets .research/kronos-v1 --output .research/runs/20260908-kronos-compat-v2
```

Only ten fixed June1 events (one per symbol,11:10ET). Each input contains
100 completed consecutive1-minute OHLC bars, ending one minute before signal T.
Future timestamps are computed; no future price/realized target is passed. Forecast
22 minute opens beginning T; delay1 return is opens[16]/opens[1]-1, delay6 is
opens[21]/opens[6]-1. This aligns timestamps with the existing15-minute holdings,
but uses1-minute OHLC sequences rather than the baseline's5-minute OHLCV features.
Equal100-minute elapsed context does NOT mean identical input representation.

The upstream OHLC-only mode pads missing volume/amount for model input; this does
not assert that real volume is zero. We deliberately do not let the upstream
volume-present/amount-absent path synthesize turnover from mean OHLC. See
[upstream preprocessing](https://github.com/shiyu-coder/Kronos/blob/67b630e67f6a18c9e9be918d9b4337c960db1e9a/model/kronos.py#L467).
Fixed CPU/one thread/inference+eval mode/seed7/T1/top_p0.9/top_k0/one sampled path.
Two-GB/5-minute checks prevent automatically expanding this smoke into a big run.

Verified:31 research tests pass. Initial new-test import failed before implementation;
final causal-input tests and existing real LightGBM replay pass. Dependency imports
and pip check succeed. All eight assets and0600 permissions match. Each of ten
forecasts replayed exactly, also across a second fresh process. Median forecast
0.210s, max0.232s in finalv2;6.24s external wall (1.624s import/load), peakRSS
563,970,048 bytes, zero swaps. Initial coldv1 import/load took8.223s. Environment
occupies836MB on disk, assets112MB (`du`); no persistent Kronos server remains.

**Quality finding:15 of220 unique forecast candles violate OHLC ordering.**
All predicted opens were finite/positive; the entire candle is not thereby valid.
Violations: AMZN1,META5,MSFT1,NVDA3,ORCL2,QCOM1,TSLA2; AAPL/APP/GOOGL0.
No prices were silently repaired and none is a verified observation. No P&L,
accuracy, superiority or app-trading-readiness claim from this smoke. Generated
OHLC must not be presented as trustworthy market data.

Self-review removed a subtle future-availability dependency: the first draft reused
the labelled-example selector. The final selector uses only the session clock and
complete past context; a regression removes every future bar and still reproduces
the exact event/input. Outputs on this complete archive are unchanged by the fix.
Private final recipes/reports: `.research/runs/20260908-kronos-compat-v2{,-recheck}/`.
Main report SHA256:`59e581ceedd1aa8fd38fc082b8b129d7fa35118240afed69bad08503ad56f600`.
Initialv1 artifacts remain intact as an audit trail; no report was overwritten.
Qwen61562 and StockSage26453 untouched; previous archive/model/runner hashes unchanged.

[Chronos-2](https://huggingface.co/amazon/chronos-2) was checked only as the subsequent
candidate:119,477,664 parameters,477,930,472-byte weights,Apache2.0,
revision`29ec3766d36d6f73f0696f85560a422f50e8498c`. No Chronos download/inference yet.
The HF official-benchmark API returned47 datasets and no matching forecasting task;
this is not a claim that forecasting benchmarks do not exist. No general
forecasting leaderboard score establishes net intraday trading profitability.
