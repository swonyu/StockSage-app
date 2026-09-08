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

## Chronos-2 CPU compatibility — frozen scope, 2026-09-08

Before download/inference: use the same ten June1 11:10ET contexts from the
Kronos smoke, reusing its clock-only selector and exact delayed-open return helper.
Chronos-2 revision `29ec3766d36d6f73f0696f85560a422f50e8498c`, Apache2.0,
477,930,472-byte safetensors (SHA256
`ddcda3c7508bf2528087723e98a20707cc04b7f370ae275a9fd88078ddba4f42`).
Only local pinned configuration/weights; no remote code, downloads at inference,
training, GPU/MPS, model server, paid service, app integration, orders or push.

Use a separate `.research/chronos-venv`, official chronos-forecasting2.3.1,
torch2.14.0,transformers5.16.1,accelerate1.14.0,numpy2.2.6,pandas2.2.2,einops0.8.1.
CPU one thread, float32, seed7, inference/eval; ten independent forecasts twice,
fresh-process replay, 2GB peak-RSS check and five-minute time ceiling. Do not
expand workload automatically on failure. Download public assets anonymously;
retain wheel provenance/license and exact asset hashes in ignored `.research/`.

Target:100 completed minute opens, with matching high/low/close as past-only
covariates, no future covariates or realized labels. Forecast22 steps starting T,
quantiles0.1/0.5/0.9. Delay d in{1,6}: median-open[d+15]/median-open[d]-1.
This ratio of marginal price medians is NOT the median return or a confidence
interval for returns. Measure positive/finite prices and quantile crossings,
not OHLC consistency (only open is forecast). Never silently sort/repair output.
This is a compatibility test, not accuracy/P&L evidence or a fair speed ranking
against Kronos's sampled six-feature decoder. June–August is already observed;
future strategy comparisons must preserve that disclosure and freeze their rules.

### Executed compatibility result

`tools/intraday_chronos.py` reuses the original archive reader, Kronos causal
context selector and delay helper without changing any previous research runner.
Constructs Chronos2Model directly from verified local JSON, loads strict
safetensors on CPU; never calls a Hub/remote-code loader. A process-local Python
audit hook refuses socket connect/DNS/sendto calls in addition to HF offline mode.
This is a narrow offline guard, not a general OS-level network sandbox.
Immutable recipe records code/package-source hashes, versions, events and limits
before inference. Runtime/package inventory and all forecasts stay private.

```sh
# Already installed; reproduction setup only, not needed each run.
.research/venv/bin/python -m venv .research/chronos-venv
.research/chronos-venv/bin/python -m pip install --only-binary=:all: \
  chronos-forecasting==2.3.1 torch==2.14.0 transformers==5.16.1 \
  accelerate==1.14.0 numpy==2.2.6 pandas==2.2.2 einops==0.8.1 safetensors==0.8.0

# Pinned assets must already exist; choose a NEW output directory.
.research/chronos-venv/bin/python tools/intraday_chronos.py \
  --archive .research/studies/20260908-jun-aug-v1/chunk-2026-06-01-2026-06-14-attempt1 \
  --assets .research/chronos-v1 --output .research/runs/20260908-chronos-compat-v1
.research/venv/bin/python -m unittest discover -s tools -p 'test_intraday*.py' -v
```

All32 research tests pass, including real LightGBM regressions. The new offline
regression initially failed before implementation, then passed causal input
mapping/no-future-bars, exact delay ratios, malformed quantile rejection and
missing/altered asset checks. A crossed-quantile fixture is counted, not repaired.
All ten inputs/events/hashes exactly match the Kronos compatibility report.
Ten events replayed within the process and in a second fresh process: all
660 open-price quantiles, delay ratios and quality counts identical. All prices
finite/positive; **0/220 steps cross the selected0.1/0.5/0.9 quantiles**. This is
not accuracy or empirical interval-coverage evidence, and cannot be compared with
Kronos's full OHLC invariant check: Chronos forecasts only open in this variant.
The upstream predict_quantiles API's second output is named mean but is actually
the median; we explicitly select the0.5 column and never label it expected return.

Measured first run: median0.02065s/max0.03425s per forecast,59.110s cold import/load,
60.13s external wall,1,345,732,608-byte maxRSS,822,724,096-byte peak footprint,
zero swaps. Second fresh process:4.10s external wall,1,344,389,120-byte maxRSS,
zero swaps. Both exited0 within2GB/5-minute checks; no resident Chronos server.
Disk:980MB isolated environment and464MB assets (`du`). Qwen/Kronos/LightGBM
environments untouched. This timing is not a controlled speed leaderboard.

Model/config files0600 and SHA256 verified. The official2.3.1 wheel (80,559 bytes,
SHA256`d9d00ec9b1621235bfb26685638bf054885f4c000863678f1c775dfab2697496`)
is retained in `.research/chronos-package-v1/`; all18 installed source/license
files match it byte-for-byte. Apache LICENSE/NOTICE remain installed. pip check
passes. Full transitive runtime versions are recorded in the private report.
Reports/recipes: `.research/runs/20260908-chronos-compat-v1{,-recheck}/`.
Main report SHA256:`b3e4794d37470da9fff5c8b592ca9204796100098c79c99e29dbbd55f4d7b628`.

Sources checked2026-09-08: [official model card](https://huggingface.co/amazon/chronos-2),
[official source](https://github.com/amazon-science/chronos-forecasting),
[published package2.3.1](https://pypi.org/project/chronos-forecasting/2.3.1/).
The model-selection skill informed official-source/checkpoint verification, not
a claim of trading superiority. No strategy promotion, Swift/app change or push.

## Fixed comparative pilot — prespecified 2026-09-08

Before inference/scoring: use the first previous walk-forward test block,
July8/9/10/13/14,2026, and the same ten symbols. Exactly five clock-selected
signals per day at11:10/11:15/11:20/11:25/11:30ET:250 events total. No event
selection using returns, labels, prediction quality or realized tradeability.
Missing required context/labels is a whole-study failure, not a dropped row.
This narrow morning-window subset is engineering/exploratory evidence on already-
seen dates, not an untouched holdout, a full-day strategy or a profitability test.

Six candidates: zero,15-minute momentum,reversal,previous fold1 LightGBM,
Kronos-small and Chronos-2. No fitting, fine-tuning or threshold search here.
Reuse the saved LightGBM trained onJune1–29,11,000 rows, model SHA256
`079d5bd6392983a62c1f36c337b849197ec4d0f1bd4993fa35015e6f89520836`.
Keep all previous runner/checkpoint hashes and model settings unchanged. Both
forecasters consume the same100 completed minute OHLC bars; LightGBM retains
its original5-minute OHLCV engineered features (not equal information).

Fixed entry threshold strictly greater than5bps gross predicted return for all
candidates; this is a new prespecified policy, NOT the earlier validation-selected
thresholds. Report all1/5/10/50bps assumed RT cost scenarios and1/6-minute entry
delays,48 combinations; carry the sameUSD10k cash account across all five dates.
Reuse exact delayed-open15-minute targets, deterministic ranking/tie-breaks,
long-only whole-share/max5 positions/20%-entry/no-borrow simulator. No stops.
No-trade is the counterfactual; prediction MAE is calculated on all250 events,
not only trades. No candidate is selected on the resulting table.

Model subprocesses receive only an immutable context bundle; labels and baseline
predictions are separate hash-bound files for scoring. Fresh process per model,
CPU1 thread, existing environments/assets only, one seed7 path for Kronos and
open-price0.1/0.5/0.9 quantiles for Chronos. No network, downloads or training.
Every finite positive-open forecast is scored; record invalid Kronos OHLC and
Chronos crossings without repair or exclusion. Nonfinite/unusable opens or missing/
duplicate/unmatched event IDs fail scoring for the entire study. No "best effort"
candidate dropping. Each inference process remains under2GB/5-minute checks;
run serially, repeat both once, and compare all output values before reporting.

Prospective protocol remains a separate required next milestone: lock versions,
rules and event schedule before the first live observation; append retrieval and
prediction-completion timestamps before the permitted entry; reject late signals;
retain missed/failed events and provider corrections without backdating records.
Only score realized outcomes after their timestamps. No automatic app/broker
integration or capital allocation from this retrospective comparison.

### Executed fixed comparison

`tools/intraday_comparison.py` composes the existing archive/calendar/context,
delay and simulator helpers. All four earlier research runners remain byte-
identical. No retraining: the pinned fold1 LightGBM artifact is reused. The exact
250 clock-selected inputs are separate from500 labels (two delays). Independent
checks confirm all input timestamps precede signal T and both entry/exit indices
match the labels. A private recipe precedes processing; hashes bind code, source
study, saved fit, contexts, labels and baseline predictions. Model stages read
the context file only, not the label/baseline files. Prediction IDs must join the
entire fixed schedule. No missing-candidate or failed-event partial results.

Final artifacts: `.research/comparisons/20260908-first-fold-v3/` with recipe,
bundle,inputs,samples,baselines JSON; `kronos-v1{,-recheck}/` and
`chronos-v1{,-recheck}/` hold independent prediction runs;
`evaluation-v1{,-recheck}/` hold all48 scenarios and complete trade logs.

```sh
.research/venv/bin/python tools/intraday_comparison.py prepare \
  --study .research/studies/20260908-jun-aug-v1 \
  --lightgbm .research/runs/20260908-jun-aug-v1/fold-1-lightgbm.txt \
  --root .research/comparisons/20260908-first-fold-v3

# Execute serially, in their existing isolated environments. New output paths only.
.research/kronos-venv/bin/python tools/intraday_comparison.py predict \
  --root .research/comparisons/20260908-first-fold-v3 --candidate kronos \
  --assets .research/kronos-v1 --output .research/comparisons/20260908-first-fold-v3/kronos-v1
.research/chronos-venv/bin/python tools/intraday_comparison.py predict \
  --root .research/comparisons/20260908-first-fold-v3 --candidate chronos \
  --assets .research/chronos-v1 --output .research/comparisons/20260908-first-fold-v3/chronos-v1
.research/venv/bin/python tools/intraday_comparison.py evaluate \
  --root .research/comparisons/20260908-first-fold-v3 \
  --study .research/studies/20260908-jun-aug-v1 \
  --kronos .research/comparisons/20260908-first-fold-v3/kronos-v1 \
  --chronos .research/comparisons/20260908-first-fold-v3/chronos-v1 \
  --output .research/comparisons/20260908-first-fold-v3/evaluation-v1
```

At the fixed1-minute delay/5bps **assumed** round-trip cost, five morning windows:

| Candidate | Return-prediction MAE bps | Simulated net return | Trades |
|---|---:|---:|---:|
| No-change / no-trade |25.576|0.000%|0|
| Momentum |39.201|-1.195%|46|
| Reversal |34.694|-0.179%|36|
| Saved LightGBM |25.778|0.000%|0|
| Kronos-small |30.443|-0.052%|32|
| Chronos-2 |27.903|-0.886%|33|

Neither forecaster beats no-change MAE in this primary window. No-trade LightGBM
does not demonstrate a trading edge. Kronos is positive only at1-minute/1bps
(+0.167%) among its eight scenarios;5bps flips it negative. At6-minute/5bps,
Kronos-0.244%,Chronos-0.411%. All costs/delays remain in the report. These are
already-seen selected-stock windows with correlated/overlapping targets, not
independent trials, verified broker costs or evidence for future/weekly returns.
No candidate was selected or promoted. Prospective paper recording is NOT yet
implemented by this delivery; the protocol above describes what remains required.

Quality: Kronos124/5,500 generated OHLC steps violate ordering; finite positive
opens were still evaluated, never silently repaired or excluded. A nonfinite
generated non-open field is represented as null, not a replacement price. Chronos
0/5,500 selected-quantile crossings; OHLC check explicitly not applicable. Counts
refer to forecast steps in overlapping windows, not5,500 independent observations.

All35 research tests pass, including full-fit LightGBM regressions. New schedule,
strict ID joins and changed-hash tests pass. Self-review added a red/green regression
showing even internally valid hashes must not permit a249-event input bundle.
Earlier v1/v2 bundles retained. v1 Kronos completed, then Chronos correctly refused
the changed source hash before model load. Finalv3 only adds that boundary guard
and uses null for inapplicable quality metrics. Contexts/labels/baseline files are
byte-identical across all three; v1 andv3 Kronos forecasts also match exactly.

Both final model processes repeated once: all250-event predictions/quality counts
identical; all48 scenarios/trade logs and markdown replay exactly. Independent
cash/PnL reconciliation, five-position/20%-entry caps and five daily equity values
pass for both reports. No swaps; finalfirst-run resources: Kronos94.54s wall,
555,319,296-byte peakRSS (median0.367s forecast);Chronos15.54s wall,
1,336,983,552-byte peakRSS (median0.0354s forecast). Rechecks104.69s/16.69s and
556,056,576/1,335,803,904 bytes. All under2GB/5-minute checks, serial forecasters,
no resident forecast server. Preparation1.77s initial/3.38s intermediate, scoring
1.38s/236,978,176-byte peakRSS. Timings are not a controlled speed comparison.

Final recipe SHA256:`b54d6bd501656137924d8f76eec638e36a80892a0d424a072342e674f87a4ff8`.
Bundle SHA256:`b514c3a2971c637fc3d02198bf1ae95953470cd2af48d34a6a9f4cc5317d0e5b`.
Report SHA256:`53bcf5f0ff47adc5ead5e432dba41fc2178888dcfa6146889c7997c78891052c`.
All private files0600 and ignored. Qwen and StockSage remain running unchanged;
no new dependencies/downloads, app/Swift change, real orders, merge or push.

## Prospective forecast recorder — frozen 2026-09-08

`intraday_prospective.py` is a finite research recorder, not a paper broker. It
reuses the historical seven-feature math and CPU forecast worker. It never
changes app badges, the journal, portfolio capital or real orders.

Frozen private pilot: `.research/prospective/20260908-five-session-v1/`.
Recipe SHA256:`46d72e280a3ef2d4d715ce03c2979170de8217b4c4b9c58735cde9576196525a`.
Frozen at2026-09-08 13:26:30.492 UTC, before the first15:10 UTC signal.
Ten existing symbols, September8/9/10/11/14,11:10–15:25 New York every15min:
90 batches/900 symbol-events. First signal18:10 Riyadh; after-close scoring is
eligible from23:01 Riyadh. The scheduled sessions use the existing verified2026
[US calendar](https://www.nasdaq.com/market-activity/stock-market-holiday-schedule);
unscheduled closures and halts remain a limitation, never synthesized as bars.

Each due batch requires100 consecutive completed minutes for every symbol.
Current-day aggregate snapshots are separately archived with receipt times and
hashes; worker inputs contain only past context/features. Delayed/missing/invalid
or future-dated provider rows fail closed. Inputs do not depend on future labels.
The June29 LightGBM fit and existing pinned small checkpoints are unchanged.
Workers run serially on CPU, one thread, with a120s subprocess timeout additionally
bounded by remaining time to the6-minute deadline; peakRSS checks remain2GB.

Predictions are validated, hashed and fsynced before recording ready time.
Readiness must be strictly before the hypothetical1/6-minute entry; equality is
late. A15-minute heartbeat cannot guarantee either deadline. Missed slots and
interrupted reservations are never replayed. Missing candidates, late forecasts,
and missing outcome prices remain explicit in the denominator; no silently
selected winner. One failed batch does not overwrite earlier records. The
nonblocking pilot-wide lock prevents simultaneous ticks.

After16:01 ET, one daily outcome collection can score15-minute-open returns.
Only eligible forecasts get error scores; each day retains2160 model/delay rows
and reports the common eligible six-model panel count. These are forecast errors,
NOT actual fills, trading profits or portfolio returns. A failed/interrupted
outcome collection is preserved without automatic retry. No outcome snapshot is
fetched when there are no eligible forecasts. Maximum950 snapshot requests for this
entire pilot; most waiting wakeups perform no network or model work.

Files are application-level append-only/exclusive,0700 directories/0600 files;
they are not externally timestamped or tamper-proof. Local wall/monotonic clock
discontinuities over2s and backwards time fail closed. No provider correction
history, NBBO/spread measurement, execution proof or independent market edge is
established. Account simulation using this evidence is a separate later step.

The existing same-task15-minute heartbeat now runs:

```sh
cd /Users/saleh/StockSage-wt/coverage
.research/venv/bin/python tools/intraday_prospective.py tick \
  --root .research/prospective/20260908-five-session-v1
```

Do not rerun `init`, edit frozen source/recipe files, or backfill forecasts. A
source mismatch pauses this pilot. The first actual tick returned `waiting`,
actions empty, zero forecast attempts; genuine market results are still pending.
Qwen is deliberately left ON. No new daemon, dependency or model download.

Verification:46 research tests pass (11 prospective cases), including a red/green
empty-reservation regression, exact-deadline exclusion, no-network waiting,
future-provider rejection, clock jumps, interruption, immutable/hash guards,
causal feature parity, and one-shot after-close scoring with complete denominator.
Six fixture panels exactly match `ebf95be` examples AND quality counts. Two fresh
process runs of each model match all six previous candidates on ten fixed events
and both delays, including quality fields; elapsed seconds are excluded from
numerical comparison. Checks:`.research/checks/20260908-prospective-workers-v1/`
and`-v2/`. Final replay:baselines0.184s/74,465,280-byte peakRSS;Kronos4.135s/
542,818,304 bytes;Chronos4.032s/1,326,923,776 bytes. All workers exited.
Final parity SHA256:`a6d3dda512e8e1c1bf1543384bd37dbd79e36cb108ec81f62e80f2efbed570da`.

Separate one-request live feed preflight at13:31:30.551 UTC:Massive AAPL current
day snapshot validated,296 raw minutes, one completed RTH minute(09:30 ET),
30.551s since that bar ended. Existing header credential worked; no value logged.
Private evidence:`.research/checks/20260908-current-feed-preflight-v1/`. This is
outside the pilot, not a forecast or proof that every other provider works.

Extraction changes the research/comparison source hashes. Earlier reports remain
valid evidence for their pinned `ebf95be` source, not freshly replayable under
this changed HEAD. No old archives, recipes or reports were rewritten to hide it.
