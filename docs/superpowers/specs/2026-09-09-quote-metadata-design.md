# Bid/ask foundation: preserve quote evidence

Continuation of the owner-approved September 9 execution-realism recommendation.
The first bounded slice repairs information loss at the existing REST quote parser;
it does not switch native fills to quotes or enable the broker relay.

Keep the entire REST `conditions` array in `StockSageNBBO`, with a scalar compatibility
property for the existing WebSocket writer. Only an exactly-one condition continues
through the existing cost qualifier; unknown/multiple conditions are not guessed.
Preserve indicators, distinguishing absent (empty) from malformed (nil). Preserve
positive participant/exchange timestamps separately from SIP time; invalid timestamps
remain nil. Downstream execution must check both clocks, not substitute SIP receipt
time for exchange event time. No new fill eligibility is introduced in this slice.

Approaches considered: reuse the existing NBBO type (chosen); a second REST-only
quote type (duplicated state and consumers); directly implement fills on today's
parser (loses the very evidence that fill validation needs). No new dependency.

Self-review and inline plan: reproduce dropped condition/indicator fields with the
actual parser; normalize metadata without changing prices/sizes/sequence; test missing,
null, malformed, multiple and unknown metadata, and retain stale/future exchange times
without calling them fresh. Verify WebSocket scalar compatibility and unchanged cost
rules. Run focused and canonical Mac/iPhone tests; document source and bundle hashes.
The writing-plans skill is unavailable, so this is the bounded implementation plan.

The existing settlement build stays staged. Do not interrupt the running app's
02:55 Riyadh close-out for this work. Installation must use a completely tested
combined bundle; no untested artifact or older coverage-only build.

Source: [Massive REST quotes](https://massive.com/docs/rest/stocks/trades-quotes/quotes)
and [WebSocket quotes](https://massive.com/docs/websocket/stocks/quotes), verified
September 9, 2026. REST sizes are shares; `participant_timestamp` and `sip_timestamp`
are separate clocks. The array of conditions must not be silently discarded.

## Executed evidence — September 9, 02:56 Riyadh

Actual parser regression:10 tests,2 expected issues, exit65. Focused53 passed;
canonical macOS1879 and iPhone1876 passed, exit0. Logs/xcresults and the exact
tested Mac bundle: `/private/tmp/stocksage-quote-metadata-20260909.TOIoUz/`.
Installed only after the native USO/TSM close-out actually completed at02:55:36.
Strict codesign and whole-bundle checksum comparison passed; installed dylibSHA256
`b9cb247620be106b4ca0c68ce8849623b6f624512e0054e302121b5b2e7e7c8b`.
All prior account IDs retained and exactly one T+1 activation recorded at startup.
No quote-based fill consumer or trading-policy change was added in this slice.
