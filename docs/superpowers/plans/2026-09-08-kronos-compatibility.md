# Kronos compatibility implementation plan

> Execute inline with executing-plans. This is the next bounded step in the
> owner-approved research sequence; no subagents or app promotion.

**Goal:** Verify the official small time-series model can make reproducible,
causal forecasts on CPU before paying the runtime cost of a full comparison.

**Architecture:** One optional Python tool loads only pinned local safetensors
and reviewed source. Reuse the private archive loader. Existing baseline and
walk-forward code remain byte-identical so their source-pinned replay survives.

**Tech stack:** Separate `.research/kronos-venv`, Python3.12/PyTorch/pandas;
standard-library context/output checks and unittest. No Qwen environment changes.

## Frozen compatibility design

- Official source `shiyu-coder/Kronos` revision
  `67b630e67f6a18c9e9be918d9b4337c960db1e9a`, MIT. Retain LICENSE.
- `NeoQuasar/Kronos-small` revision`901c26c1332695a2a8f243eb2f37243a37bea320`,
  24,741,696 parameters,98,980,656-byte safetensors. Tokenizer-base revision
  `0e0117387f39004a9016484a186a908917e22426`,15,842,368-byte safetensors.
  Download only these weights/configs and four reviewed source/license files;
  exact size/hash verification precedes imports. No arbitrary remote code/pickle.
- Explicit CPU, one PyTorch thread, no MPS/GPU/device auto-detection, inference
  mode and model/tokenizer.eval(); no training or second language model server.
- Ten events only: fixed11:10ET event per archived symbol on the first date,
  taken from the June1–14 archive. Engineering compatibility, not performance.
- A context is exactly100 completed consecutive one-minute OHLC bars before
  signal T; all timestamps same New York session. The model sees no future price,
  outcome, exit label or validation/test target. Future timestamps are computed.
- Forecast22 one-minute opens beginning T. Return for delay d is
  `opens[d+15]/opens[d]-1`, d in{1,6}. This aligns with current delayed minute-open
  fills; it is not an interpolated five-minute close. Input frequency differs
  from the study's initial five-minute proposal and is explicitly labelled.
- Use the upstream supported OHLC-only path: missing volume/amount are model
  placeholders, never represented as actual zero market activity. Upstream
  otherwise synthesizes amount from volume*mean(OHLC); do not silently do that.
- T=1.0,top_p=0.9,top_k=0,sample_count=1,seed7; reset RNG per event and replay.
  Predictions must be finite positive opens with22 rows/exact timestamps.
  Record other OHLC invariant violations rather than pretending generated bars
  are observations. No real P&L/model superiority claim from this smoke.
- Measure import/load and forecast latency/maxRSS. Stop before a larger run if
  it exceeds2GB peak RSS or5 minutes; do not auto-expand symbols/samples/device.
- Anonymous public downloads only, no credentials, cloud/purchases, Qwen restart,
  Swift changes, app inputs, orders, pushes or merges.

## Task1: causal bridge and pinned local loader

Files: tools/intraday_kronos.py, tools/test_intraday_kronos.py.
Interfaces: context(bars,symbol,signal_t)->dict; forecast_return(opens,delay)->float;
smoke(archive,assets,output)->dict. Only `smoke` imports optional model libraries.

- [x] Add tests: context ignores future price changes, rejects a missing minute/
  mixed session; delay1 maps indices1/16 and delay6 maps6/21; malformed prices,
  wrong prediction length and altered/missing assets are rejected.
  Example: `assert forecast_return(list(range(100,122)),1)==116/101-1`.
- [x] Implement the minimal local loader and ten-event smoke; output JSON is
  private/immutable with hashes, versions, seed/device, exact event IDs and times.
- [x] Run `.research/venv/bin/python -m unittest discover -s tools -p 'test_intraday*.py' -v`.

## Task2: runtime check and evidence

- [x] Create isolated venv with PyTorch2.14.0, NumPy2.2.6, pandas2.2.2,
  einops0.8.1, huggingface_hub0.33.1, safetensors0.6.2, tqdm4.67.1. Omit unused
  plotting/web UI/finetuning dependencies. Verify imports and pip check.
- [x] Download/verify pinned assets, execute ten forecasts twice on CPU and
  measure resources; stop on failure without substituting a different model.
- [x] Record exact evidence in HANDOFF/research README and commit explicit paths.

Chronos-2 metadata checked only:119,477,664 parameters,477,930,472-byte weights,
Apache2.0, revision`29ec3766d36d6f73f0696f85560a422f50e8498c`. Not loaded in this step.
Official HF benchmark API returned47 datasets and no matching forecasting task;
no applicable trading-performance leaderboard was found there. Model cards'
general forecasting claims do not establish StockSage profitability.

Sources checked2026-09-08: https://github.com/shiyu-coder/Kronos,
https://huggingface.co/NeoQuasar/Kronos-small,
https://huggingface.co/NeoQuasar/Kronos-Tokenizer-base,
https://huggingface.co/amazon/chronos-2.

Executed:31 tests pass; ten forecasts repeat exactly, including a second process.
Median0.210s per forecast,563,970,048-byte peakRSS. All eight assets match pins.
15/220 unique generated candles fail OHLC ordering; no correction or promotion.
The clock-only selector is tested with all future bars removed. Original labelled-
selector artifacts retained; finalv2 forecasts identical, with the cause corrected.
Full evidence and commands in tools/intraday_research.md and HANDOFF.md.
