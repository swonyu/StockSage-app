# Intraday research foundation

Owner approved the hybrid approach at14:12 +03 on2026-09-08: keep StockSage/Qwen,
add minute-history research and compare predictors before paper/live promotion.
This first independently useful milestone is a bounded archive and benchmark,
not a forecasting claim or a change to the app's financial decisions.

## Decisions

- Work inline in the existing clean wt/coverage; preserve all other worktrees.
- A Python command in tools/ owns collection and offline evaluation. SQLite,
  JSON and unittest use the standard library. Optional LightGBM is isolated in a
  research venv, never installed into the running Qwen environment.
- Collect at most10 explicitly named US symbols over at most14 calendar days per
  immutable archive. Existing Massive credentials only, sent in a Bearer header.
  No credential arguments, URLs, logs, redirects, paid services or model downloads.
- Preserve raw successful responses, SHA256, retrieval times and unadjusted minute
  OHLCV. Reject malformed, duplicate, unordered, incomplete/paginated responses.
  Missing intervals are not zero-volume bars and are never forward-filled.
- Data stays in ignored .research/ with private permissions. Repeated collections
  use new paths, so provider corrections do not silently rewrite old observations.
- Build five-minute bars only from five consecutive regular-session minutes in
  America/New_York. Features use20 consecutive completed five-minute bars, reset
  daily. Entry is one minute AFTER the last feature bar closes; exit15 minutes
  later, both at observed one-minute opens. Drop overnight and missing-label
  windows with explicit counts. These are hypothetical fills, not NBBO evidence.
- Explicit whole-session train/validation/test boundaries apply to every symbol;
  no random split. Assert label exits precede the next partition's first signal.
- Candidates: zero-return/no-trade,15-minute momentum, its reversal, optional
  one fixed LightGBM configuration. Four entry thresholds (0/5/10/20bps) are
  compared on validation only; the selected threshold is frozen for test.
- Long-only simulated USD10,000 account, whole shares, no leverage, max five
  simultaneous positions, max20% equity per entry. Charge half the round-trip
  cost assumption on each side. Process exits before entries; mark every minute
  using observed opens, fail if a held position cannot be marked. Drawdown is
  minute-open sampled, not intrabar or gap-through-stop risk.
- Cost scenarios1/5/10/50bps round-trip;5bps used for validation selection, NOT
  an actual Derayah tariff. Include a six-minute entry-delay stress. Publish
  portfolio net return, sampled drawdown, turnover, trade count, daily equity,
  prediction MAE and the trial count. Never select a winner using test results.
- Every report is engineering-only/not-promotable: today's selected universe is
  not point-in-time, historical publication/correction latency is unknown, broker
  minimums/FX/NBBO fills are unpriced and the first sample is intentionally short.

## First live check

Ten explicitly preselected familiar liquid symbols: AAPL,MSFT,NVDA,AMZN,GOOGL,
META,TSLA,ORCL,QCOM,APP;2026-08-31 through2026-09-04. Train through09-02,
validate09-03, held-out test09-04. This is a plumbing/quality check, NOT a strategy
selection period. Do not tune a failed strategy to this one test day.

## Next milestones, not claimed by this delivery

Point-in-time universe/calendar/corporate-action handling; larger chronological
walk-forward data; verified broker costs/quotes; Kronos/Chronos under identical
targets and costs; prospective paper ledger; optional app integration only after
evidence. Keep Qwen running as requested at13:45; no second resident LLM.

Sources: StockSage-Intraday-Case-Study.pdf pp8–9; Massive custom aggregate docs:
https://massive.com/docs/rest/stocks/aggregates/custom-bars (checked2026-09-08).
