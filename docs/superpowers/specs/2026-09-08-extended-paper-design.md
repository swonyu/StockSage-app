# Extended-hours native paper simulation

Owner approved at23:54 Riyadh on2026-09-08: native Qwen paper research, entries
and exits in pre-market, regular and after-hours. Combined base d13ab2b; task
01a0822f-6195-7f81-b4dc-6a0402fcaa4b handed this task sole writer/install ownership.

## Contract

- Use the existing New York session clock: weekday pre-market, regular and
  after-hours, 04:00 inclusive to20:00 exclusive, automatically following DST.
  Weekends/closed phases remain ineligible. Existing holiday-calendar limitation
  remains disclosed; fresh actual observations are still required.
- One shared paper-session predicate controls research scheduling, new decision
  proposals, pending fills and sampled stop/target exits. Do not change the
  global market clock or unrelated execution policies.
- Preserve later-than-decision Massive SIP observations, finite positive prices,
  two-minute freshness/expiry, cash/position limits, assumed costs, no duplicate
  replay, no backfill, persistence/lease protection, and Hold/Avoid doing nothing.
- UI names the extended window and continues to label fills as simulation.
  Fixed10bps costs do not measure actual spread/depth or extended-hours liquidity.
- IBKR relay stays OFF, outsideRth stays false, and free-trial accounts remain
  diagnostic-only. No broker-order submission or real trading is authorized.
- Preserve all combined Qwen/Form4/copied-plan changes, the existing local model
  process, and frozen prospective research. No new dependencies or agents.

## Inline implementation and verification plan

1. Add deterministic red tests at the real session predicate and Book.settle
   seams: pre/regular/post boundaries, DST/weekends, later-only extended fills
   and stop exits, and closed-session expiry without fills.
2. Replace the regular-hours predicate at every native paper call site; update
   status/policy wording and operation documentation.
3. Run focused paper tests, review all callers and unchanged relay/frozen files,
   then final canonical macOS and iPhone17Pro(gate) tests serially.
4. Stage/verify the tested Mac bundle, normally quit the existing app, verify its
   exit, keep the old bundle recoverably, install and reopen. Observe actual
   native research/ledger state without forcing a Buy or fabricating a fill.
5. Record exact evidence in HANDOFF; commit explicit paths, no merge or push.

Source: [Nasdaq trading schedule](https://www.nasdaq.com/market-activity/stock-market-holiday-schedule),
verified2026-09-08. The simulator does not prove broker entitlement or liquidity.

## Executed evidence

- Actual red:8 tests/8 issues, exit65. Focused final:8 tests passed in0.018s.
- Final serial canonical gates:1851 macOS tests (56.610s) and1848 iPhone tests
  (55.500s), both exit0 with the existing three exclusions.
- 46 research tests passed in2.330s; frozen research and IBKR source unchanged.
- Logs/results: `/private/tmp/stocksage-extended-paper-20260908.fL0dYG/`.
- Verified installation at00:01 Riyadh on September9; prior app recoverable in
  Trash. Actual after-hours ORCL research completed21:01:13 UTC with Hold and
  no order. No forced fill, broker acceptance or native visual test is claimed.
- Exact bundle hash, process/lease checks and limitations are in HANDOFF.
