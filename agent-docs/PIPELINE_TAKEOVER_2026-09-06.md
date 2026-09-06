# Pipelines 4/5 — single-session continuation

Owner confirmed the other Codex task was stopped at 19:43 +03. Its app state was
independently idle and no compiler/build process remained. All work is now inline
in the original session, on the existing `wt/coverage` worktree. No new workers,
pushes, actual trades, service purchases, or local model training.

## Completed before takeover

- `52205dc`: M1 Massive snapshots.
- `6873f2b`: M1b adjusted daily history.
- Seven uncommitted M2/provider-cutover files inherited and preserved.

## Current checklist

- [x] M2 finish the Massive stream and shared quote ordering; broad device gates.
- [ ] M2b live NBBO, measured-spread cost input, bounded on-demand tape, exchange attribution.
  - [x] Authenticated Q subscription on the existing socket; independent quote/trade clocks,
    500 ms quote publication; detail bid/ask panel with five-second spread freshness.
  - [x] On-demand trades/quotes tape (seven-day window, three pages ×100 per channel),
    24-hour exchange reference, MIC-based Nasdaq filtering and explicit partial/error states.
  - [ ] Thread measured spreads through ALL current cost/ranking/gate/export consumers,
    retaining conservative floors/slippage/fees; preserve historical backtest assumptions.
  - [ ] Compact card presentation, same-millisecond TRADE sequence through Store, populated
    UI verification and authenticated endpoint smoke. Quote sequences are already ordered.
- [ ] M3 Benzinga earnings first in the source chain, confirmed/projected from provider status.
- [ ] M4 Massive news/insights with bounded, cited narration.
- [ ] M5 truthful per-observation provider labels and paid-plan configuration.
- [ ] M5b split-aware journal comparisons without rewriting the journal.
- [ ] M6 ratings, guidance, 8-K, dividends and Form 4, with dated provenance and entitlement failures.
- [ ] P5 tickets, crossing alerts, separate paper automation/store, broker integration as below.
- [ ] Proactive native Chat using the approved V3 design and existing transport.
- [ ] Prioritized money/accounting corrections from FULL_REVIEW.
- [ ] Canonical macOS + iPhone 17 Pro (gate) tests, populated UI checks, integration and HANDOFF.

## Corrections to historical workflow scripts

The scripts are implementation proposals, not authority to contradict the owner.
Active quote routing is Massive then explicitly labelled Yahoo fallback; EODHD
retirement is intentional. Analyst Ratings and Corporate Guidance are already
purchased; entitlement failures still need honest handling, not new purchases.

M2/M2b WebSocket `t` is **milliseconds**, not the nanoseconds stated in parts of
the old workflow. REST trades/quotes use `sip_timestamp` in **nanoseconds**.
Massive explicitly documents batched multi-event arrays. Auth success alone does
not prove subscription delivery; quiet/unseen symbols remain eligible for polling.
Snapshot, poll, single-symbol, stream and scan publication cannot rewind a dated
price or replace it with an undated one. An undated seed stays unknown/stale.

M2b will distinguish tape/listing from execution venue. Resolve Nasdaq using the
reference response's `mic == "XNAS"`, never a guessed ID. A Nasdaq-filtered SIP
quote is not a proprietary Nasdaq feed and is not necessarily a two-sided Nasdaq
book. Two half-spreads (entry + exit) equal one full spread in the round-trip
model; do not halve round-trip costs accidentally. Preserve existing conservative
spread floors until separately validated, and preserve slippage/fees.

P5 execution-assist is the newer script, but its hypothetical scopes, generic JSON
portfolio decoding, old Sahm-only framing and permanent never-executes language
are not the final design. The owner requires real Derayah buy/sell/cancel/modify,
manual and explicitly enabled risk-bounded automation. OIDC discovery alone is
not a verified brokerage contract. Do not invent endpoint schemas or claim that
mock/read-only flows complete execution. Keep paper trades out of the real journal
and calibration. No development test may place a real order.

## Verified protocol references (2026-09-06)

- https://massive.com/docs/websocket/quickstart — auth, one Stocks connection, event batches.
- https://massive.com/docs/websocket/stocks/trades — `ev:T`, `sym`, `p`, `t` milliseconds, `q`, `x`.
- https://massive.com/docs/websocket/stocks/quotes — `ev:Q`, bid/ask price, size and exchange; `t` milliseconds, sequence resets daily.
- https://massive.com/docs/rest/stocks/trades-quotes/trades — trade records, nanosecond timestamps, `next_url`.
- https://massive.com/docs/rest/stocks/trades-quotes/quotes — NBBO records, nanosecond timestamps, `next_url`.
- https://massive.com/docs/rest/stocks/market-operations/exchanges — ID/MIC mapping; filter stocks/us.

## Verification so far

- M2 committed as `4514e8b` (no push).
- macOS stream pass: 10/10, zero skipped/failed;
  `/private/tmp/stocksage-m2-handoff-20260906-1945.xcresult`.
- Expanded merge/snapshot/stream pass: 34/34, zero skipped/failed;
  `/private/tmp/stocksage-m2-ingress-retry-20260906-1951.xcresult`.
- Preceding expanded attempt did not execute tests: an extra parenthesis in a new
  test fixture caused compilation failure (exit 65); corrected before the pass.
- These are focused checks, not the full final gate or live endpoint smoke.
- Final macOS broad suite (after stream-publication throttling): **1,649/1,649**,
  zero failures and zero skips among selected tests. Explicitly excluded
  `CalibrationPersistRunTests`, `LiveUniverseVerificationTests`, and
  `StrategyBaselineMeasurementTests`: opt-in network/measurement jobs, not ordinary
  unit tests. Result:
  `/private/tmp/stocksage-m2-broad-macos-20260906-1956.xcresult`.
- Final iPhone broad run: **1,649/1,649**, zero failures/skips among selected
  tests, with the same three opt-in suites explicitly excluded. iPhone 17 Pro
  (gate), iOS 26.5, arm64. Result:
  `/private/tmp/stocksage-m2-broad-ios-20260906-1957.xcresult`.
- M2b NBBO-focused: 15/15 macOS, 15/15 iOS. Quote-book locked/crossed/one-sided
  states withhold the spread; the final conservative locked-book rule is in the iOS pass.
- M2b tape + NBBO + stream + snapshots: **38/38 macOS**,
  `/private/tmp/stocksage-m2b-tape-macos-20260906-2014.xcresult`.
  Subsequent broad macOS: **1,660/1,660**, zero failures/skips among selected tests;
  `/private/tmp/stocksage-m2b-broad-macos-20260906-2014.xcresult`.
  The same three opt-in network/measurement suites were explicitly excluded.
  Broad iOS: **1,660/1,660**, zero failures/skips among selected tests, same three
  explicit exclusions; `/private/tmp/stocksage-m2b-broad-ios-20260906-2016.xcresult`.

M2b data/UI checkpoint intentionally does NOT claim measured costs are integrated:
the detail panel explicitly says ranking/tickets still use estimated costs. The
next change must cover `StockSageExpectedValue`, `StockSageCapitalAllocator`,
`StockSageDecisionSnapshot`, `StockSageTodayPlan` and every `MarketsView` net-RR,
ledger and copy-plan caller together. Do not change symbol-only historical
backtests to today's spread (lookahead). Keep the full-spread round-trip convention,
the existing US8bps spread floor, and other cost legs. Preserve live quote identity
and expiry across Store scans/price updates; clear cost inputs on auth/policy loss.
Before treating quotes as cost evidence, check condition/indicator eligibility;
the current panel is observational, never an execution guarantee.

Tape security: header auth only; next pages require HTTPS api.massive.com, the
same exact endpoint/symbol, normal443 port, no userinfo/fragment/API-key query;
redirects are disabled. Invalid/repeated cursors, invalid rows and cap truncation
remain visible. Unknown venue IDs never resolve to Nasdaq by listing tape.
Budget: at most6 tape pages per opening, plus one reference request per24hours
while the process lives. Quotes add Q traffic to the SAME Stocks connection;
message volume depends on the market, not a guaranteed exact doubling.

M2b continuation note: the current price comparator deliberately rejects equal
timestamps. Add provider/channel-scoped sequence ordering for distinct ticks in
the same millisecond when implementing tick/quote metadata; never let an unknown
sequence or a different provider replace an equal-time observation arbitrarily.
Keep the one-second live-badge expiration timer and change-only publication:
publishing a timestamp on every trade bypassed the Store's 500 ms coalescing.
