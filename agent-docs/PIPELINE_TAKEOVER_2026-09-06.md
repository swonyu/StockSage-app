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
  - [x] Thread measured spreads through ALL current cost/ranking/gate/export consumers,
    retaining conservative floors/slippage/fees; preserve historical backtest assumptions.
  - [x] Same-millisecond TRADE sequence through StreamState, Store/coalescing, scan and cache.
  - [x] Compact card presentation with shared visible/VoiceOver copy and component render.
  - [ ] Full populated UI verification and authenticated endpoint smoke.
    - 21:32 credential-presence check was blocked by the credential-access guard.
      No key was read, no authenticated request sent, no guard bypass attempted.
      Keep live smoke pending; independent stages may proceed. Full-screen QA
      must not overwrite the owner's running binary/state or open a second Stocks socket.
- [x] M3 Benzinga earnings first in the source chain, confirmed/projected from provider status (code/tests; live verification pending).
  - [x] Verify docs and official SDK range/sort parameters; add request/parser/gate/chain fixtures.
  - [x] Red build demonstrates the missing provider and chain/input interfaces (no tests executed).
  - [x] Implement provider first in chain; preserve 24h rejection gate and answer provenance.
  - [x] Preserve confirmed/projected distinction and actual provider in rendered catalyst copy.
  - [x] Focused then serialized canonical macOS/iPhone gates; record and commit explicit paths.
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

20:43 measured-cost checkpoint supersedes the earlier data/UI-only limitation.
`StockSageExpectedValue`, `StockSageCapitalAllocator`, `StockSageDecisionSnapshot`,
`StockSageTodayPlan` and all `MarketsView` net-RR/ledger/copy callers now use the
same idea NBBO selector. Floors/other legs and historical defaults remain intact.
Cost inputs survive scans/price updates, expire at5s, and clear on auth/policy loss.
Detail/copy re-resolve the selected idea from the store. Shared netRR(for:) also
fixes cards' previous omission of short financing. Focused macOS50/50; canonical
broad macOS1664/1664 and iPhone1664/1664, same three explicit opt-in exclusions.
Bundles and exact limitations are in HANDOFF's20:43 entry.

Condition eligibility: `/v3/reference/conditions?asset_class=stocks&data_type=quote&limit=1000`,
one request per stream start, header auth/no redirects. Accept only a complete,
unambiguous mapping for non-legacy stock quote condition with UTP R (UQDF§7.5.2.2);
unknown conditions or ANY indicators fall back to default costs. This narrow
policy is intentional; verify indicator semantics and live payloads before
expanding it. Reference validity24h, no automatic retry until restart. It is a
cost-observation filter, not a halt detector or permission to execute an order.
The live provider smoke and populated visual checks have NOT been done.

Tape security: header auth only; next pages require HTTPS api.massive.com, the
same exact endpoint/symbol, normal443 port, no userinfo/fragment/API-key query;
redirects are disabled. Invalid/repeated cursors, invalid rows and cap truncation
remain visible. Unknown venue IDs never resolve to Nasdaq by listing tape.
Budget: at most6 tape pages per opening, plus one reference request per24hours
while the process lives. Quotes add Q traffic to the SAME Stocks connection;
message volume depends on the market, not a guaranteed exact doubling.

21:13 trade-ordering checkpoint: equal timestamps now accept only a strictly
larger exact Int64 Massive T sequence for the same symbol. Unknown/invalid
sequences and other providers still cannot break ties; Q-channel ordering stays
independent. The optional sequence survives Store buffering, scan publication,
board/idea replacement and disk cache rebuild. A genuinely later unsequenced
poll clears the old sequence; advice/analysis time are untouched. Checking every
existing observation separately also prevents a corrupt future timestamp from
masking another valid clock and permitting a rollback. Mismatched quote/key
symbols are rejected at merge and full-refresh ingress.
Two regressions were demonstrated red before implementation. Focused42/42,
canonical macOS1670/1670 and iPhone1670/1670 passed; same3 explicit opt-in exclusions.
Exact bundles, the corrected test compilation error and remaining limits are in
HANDOFF's21:13 entry. No actual provider smoke or populated new-branch visual QA.

Keep the one-second live-badge expiration timer and change-only publication:
publishing a timestamp on every trade bypassed the Store's 500 ms coalescing.

21:29 compact-card checkpoint: US cards reuse the coalesced Q book and a shared
exchange reference. Bid/ask prices/share sizes, venues, SIP timestamp and observed
spread are identically represented in pixels and the explicit VoiceOver label.
Unknown IDs stay unknown. Static "last observed, not a fill quote" copy avoids
per-card timers and false freshness; historical observed spread never replaces
the existing fresh/qualified money input. Nil/invalid books remain explicit.
Final broad macOS1672/1672 and iPhone1671/1671 passed, same3 opt-in exclusions.
The one additional Mac test renders the real component at320pt; the resulting
image was inspected. Full populated app UI/VoiceOver and live provider smoke
remain unverified. Exact result bundles and limitations are in HANDOFF21:29.

21:46 M3 code/test checkpoint: StockSageMassiveEarnings is first in the existing
per-symbol chain, followed by unchanged EODHD/Yahoo/history fallbacks. Strict
complete-page parser (100 rows,400 days), UTC today-inclusive selection,
date_status-only confirmation and conservative duplicate status resolution.
Real empty answers and unavailable/malformed responses remain distinct. Status
probe before the sweep;401/402/403 cache24h; header auth/no redirects. Daily
answer TTL and4-wide pacing remain. The real catalyst view passes the observed
source; no longer falsely labels Benzinga dates as Yahoo. Provider-projected
means estimated calendar date, not the app's history-derived .projected status.
Focused103/103, final broad1681/1681 macOS and1680/1680 iOS; same3 opt-in
exclusions. All build handles completed. Exact evidence/errors/limits in HANDOFF.
Credential hook blocked the earlier live check; do not bypass or infer account
entitlement from that denial. Continue M4 independently; full live/UI QA pending.
