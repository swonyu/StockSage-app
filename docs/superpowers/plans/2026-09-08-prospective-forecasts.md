# Prospective Forecast Recorder Implementation Plan

> **For agentic workers:** Use executing-plans inline. The owner requires this
> session only; no subagents or separate tasks. Routine reconfirmation is waived.

**Goal:** Record forecasts before their hypothetical entries, including failures
and missed deadlines, without placing orders or changing StockSage.

**Architecture:** A finite CLI invoked by the existing 15-minute heartbeat.
Exclusive, fsynced private files and a nonblocking process lock preserve each
attempt. Existing feature math and isolated CPU model workers are reused.

**Tech Stack:** Python stdlib; existing LightGBM, Kronos and Chronos environments.

## Global constraints / frozen protocol

- Ten existing symbols; September 8,9,10,11,14, 2026. These are regular sessions
  in the [NYSE calendar](https://www.nyse.com/publicdocs/nyse/ICE_NYSE_2026_Yearly_Trading_Calendar.pdf).
- Signals 11:10–15:25 America/New_York every15min:90 batches/900 symbol-events.
- Exactly100 completed preceding minute bars. No future outcomes in model inputs.
- Original June29 LightGBM fit and existing pinned small forecasters; no training,
  selection, tuning, model downloads, app promotion or real/simulated broker orders.
- Entry delays1/6min, hold15min; ready time strictly BEFORE entry, equality is late.
  A 15-minute heartbeat does not guarantee either deadline. Late/missed events
  remain in the denominator. No automatic retry or historical forecast backfill.
- Receipt times are local wall/monotonic clock observations, not trusted external
  timestamps. Clock jumps over2s fail closed. All ten inputs required per batch.
- CPU workers serial, at most120s each and bounded by remaining6min deadline.
  After16:01 ET, one read-only daily outcome collection, no automatic retry.
  Outcome errors are explicit; scoring is forecast error, not portfolio P&L.
- All artifacts ignored in .research/prospective/;0700 directories/0600 files.
  No push/merge, model-server changes or unrelated worktree edits.

## Task1 — causal reuse and regression

Files: tools/intraday_research.py, tools/intraday_comparison.py,
tools/test_intraday_prospective.py. Extract feature_vector(window,signal) from
examples verbatim; extract predict_events(events,candidate,assets,output,sha)
from the historical worker and validate past-context shapes before model imports.

- [x] Write/run a failing fixture test, then reuse the existing math:
```python
historical = r.examples(fixture())[0][0]
event = q.event_input(fixture(), 'AAPL', historical['signal_t'])
assert event['x'] == historical['x']
assert event == q.event_input([b for b in fixture() if b['t'] < historical['signal_t']],
                              'AAPL', historical['signal_t'])
```
- [x] Run `.research/venv/bin/python -m unittest discover -s tools -p 'test_intraday*.py'`.

## Task2 — one-shot capture, clocks and outcome separation

Create tools/intraday_prospective.py: init/tick/worker commands. init freezes
recipe/sources/fit/assets before the first signal. tick records due missed slots,
reserves one due slot, archives fetch timing/raw bytes, emits past-only inputs,
executes workers and writes eligibility receipts. Existing incomplete attempts
become interrupted, never retried. Fetch factory is deferred until actually due.
After each session, outcome snapshots score only sealed predictions, checking
hashes and eligibility; unavailable labels do not become zero returns.

- [x] Test waiting makes zero network/model calls, exact deadline exclusion,
  missed-slot/restart behavior, source/hash changes, clock rollback and malformed
  context rejection. Run tests red, implement, run green.
- [x] Test daily outcome scoring cannot run early and never changes predictions.
- [x] Replay existing context inputs in fresh model processes to verify shared
  worker numerical parity. Earlier reports remain pinned to ebf95be sources.

## Task3 — freeze and schedule

- [x] Self-review timing, secret handling, crash/restart and late-record boundaries.
- [x] Freeze a private pilot before September8 11:10 ET; run waiting preflight.
- [x] Update research README/HANDOFF and existing automation prompt, preserving
  cadence and all owner constraints. Commit explicit paths with required heredoc.

No profitability claim, no promotion gate passed, no newly executed Swift gates.

## Executed evidence

46 research tests pass;11 cover this recorder. Empty-reservation and future-bar
regressions were observed failing before fixes. Two fresh runs per CPU model
match the previous ten-event/two-delay forecasts and quality exactly; six fixture
panels reproduce ebf95be features and quality counts. Frozen13:26:30.492 UTC,
recipe46d72e280a3ef2d4d715ce03c2979170de8217b4c4b9c58735cde9576196525a.
Two real waiting ticks made zero prospective attempts. One separate AAPL current
day feed probe passed. Existing same-session automation prompt saved/verified,
ACTIVE every15min. Detailed measurements and limitations are in HANDOFF.md.
