# Same-Day Paper Trading Implementation Plan

> **For agentic workers:** Use executing-plans inline. The owner requires all work
> in this session; no subagents or new tasks.

**Goal:** Enforce a same-day paper lifecycle and provide current intraday evidence.

**Architecture:** Extend the existing paper Book/session helpers and bounded
Massive HTTP client. Keep deterministic exits independent of model availability.

**Tech Stack:** Swift/Foundation, Swift Testing, existing Massive and MLX services.

## Global Constraints

04:00–20:00 New York sessions;19:55 entry cutoff/exit requests;120s later-only
observations and expiry; initial10000USD,2000USD per entry,five whole-share long
positions,no margin;100 discovery candidates,four workers; no broker submission.

### Task1: Same-day lifecycle

Files: StockSage/Sources/StockSage/StockSagePaperAutomation.swift,
StockSageTests/StockSagePaperAutomationTests.swift.

Interfaces: `entryWindowOpen(Date)->Bool`, `dayExitDue(openedAt:Date,now:Date)->Bool`,
`Book.enforceDayLimit(at:Date)` called by settlement before examining observations.

- [x] Add a regression that proposes before19:55, cancels an unfilled buy at19:55,
  requests a held position's exit, refuses a same-time fill, then closes with a
  later eligible observation. Test overnight carry, DST and no new buys while overdue.
- [x] Run the focused paper suite before production changes and record red.
- [x] Implement session-calendar helpers; add entry guards in propose and settle;
  call day-limit enforcement even without quotes. Closed-session overdue holdings
  remain visible and cannot be marked falsely closed.
- [x] Test and apply a one-time atomic activation under the existing writer lease:
  cancel pre-policy pending entries, retain holdings/exits/history, reset research
  due once, and preserve subsequent research timing across restarts.

### Task2: Intraday evidence and rollout

Files: StockSage/Sources/StockSage/StockSageMassiveTicks.swift,
StockSageTests/StockSageMassiveTicksTests.swift,
StockSage/Sources/Views/StockSagePaperAutomationPanel.swift, HANDOFF.md.

Interface: `intradayFacts(symbol:from:now:) async -> Intraday?`, backed by
`parseIntradayFacts(Data,symbol:from:now:)->Intraday?`. The value carries facts,
the evidence timestamp and its freshness limit.

- [x] Reuse authorized/no-redirect data helper for `/v2/aggs/ticker/SYMBOL/range/1/minute/FROM_MS/TO_MS`.
  Reject wrong ticker/status, pagination, bad OHLC/volume, duplicate/non-minute
  timestamps and incomplete future bars. Require two completed bars, last age≤180s.
  If bars are unavailable, reuse condition-checked fresh trades: two distinct
  participant timestamps, last age≤120s, explicitly not synthetic candles.
- [x] Append exact dated OHLCV observations as facts; replace only the paper prompt's
  weekly horizon. Assert the same-day prompt and parser behavior in focused tests.
- [x] Apply the01:09 review extension: shared four-way position-price fallback,
  actual intraday citations required for new Buy opinions, distinct request versus
  verification errors, cycle timing/counts and100 visible decisions. Test concurrency
  and citation boundaries; preserve all existing execution safeguards.
- [x] Run final canonical xcodebuild tests, projectStockSage.xcodeproj,
  schemeStockSage,Debug,jobs2,parallel-testing-enabledNO, DerivedData
  `/private/tmp/stocksage-qwen-context-20260908/DerivedData`, macOSarm64 then
  iOS Simulator3B0B0FE2-C39B-4B04-9E32-C8CCB93DA3AA. Preserve exclusions
  CalibrationPersistRunTests,LiveUniverseVerificationTests,StrategyBaselineMeasurementTests.
- [x] Update panel/HANDOFF, verify signed tested bundle, normal quit, retain old
  bundle in Trash, install/reopen, verify lease and actual ledger. Commit explicit
  paths with required heredoc/coauthor style; do not push.
