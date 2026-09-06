# HANDOFF — StockSage-app (written 2026-09-06 05:55 +03, session fe29f7aa, Claude Fable 5.1)

## Pipeline 4 M4 news checkpoint — 2026-09-06 22:27 +03

Explain now requests Massive `/v2/reference/news` first, with the existing EODHD
news path as fallback only when no usable primary items are available. One
request per Explain, at most five articles within the preceding seven days,
newest first; at most one EODHD fallback request. No new timer, subscription,
pagination, dependency, model invocation trigger, or trading/ranking input.
The documented feed updates hourly, not live. An empty selection is never a
complete "no news" finding. Existing EODHD fallback budget:10 API credits/request.

Article ticker membership is required. Sentiment/reasoning must match the requested
ticker and a documented positive/negative/neutral label; missing/unknown/conflicting
insights are omitted. Provider/publisher, title, bounded excerpt, date and safe
link survive the actual NewsItem→CitedSource→prompt/UI path. Sentiment occupies
a second line under the SAME citation number, labelled provider commentary in
the UI. Both narrator backends retain the unchanged number/citation checks;
these are NOT semantic truth or predictive-edge checks. External source prose
is explicitly untrusted data, not instructions. No profitability claim.

Shared news boundary rejects future dates, invalid limits/windows and unsafe
links (non-HTTPS, userinfo, or URLs over2048 bytes). Titles/publishers/excerpts/
reasoning have whole-word budgets, avoiding truncated numeric tokens. Results
are deduplicated before limiting. Missing Massive status is allowed by its
optional schema; present non-OK/wrong-type status or malformed envelopes fall
through. HTTP200, external-access and cancellation checks surround requests;
redirects are disabled and Massive auth stays in the header. No secrets logged.

The source list now exposes publisher, excerpt and sentiment, even when narration
is withheld/unavailable. Prompt and UI share a POSIX/Gregorian UTC date formatter.
Native Link semantics remain; an explicit plain SwiftUI label fixed ImageRenderer's
unsupported native-link placeholder. The final actual component render at320pt
was inspected: `/private/tmp/stocksage-news-sources-320.png`. Synthetic component
QA only, not full populated-app, live-model or VoiceOver interaction verification.

Verified references:
- https://massive.com/docs/rest/stocks/news
- https://raw.githubusercontent.com/massive-com/client-python/master/massive/rest/reference.py
  (`list_ticker_news`: published_utc range modifiers and endpoint)

Verification (serialized xcodebuild; xcresulttool independently checked counts):
- Regression red:15 executed,12 passed/3 failed, exit65. Future date, unsafe link,
  unbounded snippet tests caught real existing defects.
  `/private/tmp/stocksage-m4-red-20260906-2156.xcresult`.
- First implementation build: nested Swift Testing #require macro in the render
  fixture failed compilation; no tests executed. Corrected before all passes.
  `/private/tmp/stocksage-m4-focused-20260906-2210.xcresult`.
- Focused:56/56 passed both before and after render/URL-budget hardening.
  `/private/tmp/stocksage-m4-focused-retry-20260906-2211.xcresult` and
  `/private/tmp/stocksage-m4-render-20260906-2223.xcresult`.
- Final macOS:1693/1693, zero selected failures/skips.
  `/private/tmp/stocksage-m4-broad-macos-20260906-2225.xcresult`.
- Final iPhone17Pro(gate), iOS26.5:1691/1691, zero selected failures/skips.
  `/private/tmp/stocksage-m4-broad-ios-20260906-2227.xcresult`.
  Same three canonical exclusions:CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests.

Live verification was NOT run. Owner authorized a credential retry at22:03;
PreToolUse denied the explicit presence-only check again. At22:09 the owner
removed the file-guard entry: hooks.json remained valid, but the active tool
guard still rejected access. The assistant changed no security configuration,
read no key, and attempted no alternate access path. Reopening the task/file
did not verify a guard reload. Do not infer key absence or entitlement failure.

Owner's running app PID11897/binary and main worktree's unrelated pbxproj/review
artifacts were preserved. No push, real trade, model load or new worker.
Next concrete stage: M5 quote provenance. `MarketsView.sourceTagLabel` still
hardcodes Yahoo and LiveQuote/StockSageQuote/StockSageIdea/history/cache do not
carry provider metadata. Fix that through accepted observations, not by guessing
from a configured key. Keep the approved Massive→Yahoo route; do not resurrect
the old script's EODHD picker or claim the residual EODHD dependencies are gone.

## Pipeline 4 M3 earnings checkpoint — 2026-09-06 21:46 +03

`StockSageMassiveEarnings` now precedes EODHD calendar → Yahoo → history projection
in the existing per-symbol chain. It uses the documented `/benzinga/v1/earnings`
with ticker, date.gte/date.lte, date.asc and a100-row cap over400 days. Dates use
UTC calendar-day precision (including today until midnight), not an invented
release time. Only date_status sets confirmation: confirmed=true, projected=false.
A provider estimate is still a calendar observation with the existing estimated
suffix; it is NOT the app's distinct history-derived .projected record.

Malformed envelopes/rows/statuses/dates, mismatched symbols and partial pages are
unavailable, not checked-empty. Empty valid responses remain answered(nil).
Conflicting statuses on duplicate same-day rows cannot upgrade confirmation.
One status-only probe precedes a US earnings sweep;401/402/403 from either that
probe or a later query suppress this provider for24h, persisted locally. Other
failures do not claim an entitlement rejection. Header-only auth, redirects
disabled, external-access/cancellation gates checked before and after requests.
Existing per-symbol24h answer TTL, fallback order and four-wide sweep remain.

The catalyst card now receives the actual chain source instead of hardcoding
Yahoo. Its general caveat also names the attributed calendar provider. Unknown
provenance is explicit in the real view. No new model inference or order path.

Verified references:
- https://massive.com/docs/rest/partners/benzinga/earnings
- https://raw.githubusercontent.com/massive-com/client-python/master/massive/rest/benzinga.py
  (list_benzinga_earnings: date range modifiers and endpoint)

Verification, serialized canonical xcodebuild tests:
- Initial red build: missing provider/chain/input interfaces, exit65; NO tests
  executed. `/private/tmp/stocksage-m3-red-20260906-2139.xcresult`.
- First implementation build: three Swift Testing nested-try fixture errors,
  exit65; NO tests executed. Fixed before all following passes.
- Focused **103/103**, zero failures/skips:
  `/private/tmp/stocksage-m3-focused-retry-20260906-2141.xcresult`.
  One additional empty/stale-first-source fallback test added afterward.
- Final broad macOS **1,681/1,681**, zero failures/skips among selected tests:
  `/private/tmp/stocksage-m3-broad-macos-20260906-2144.xcresult`.
- Final broad iPhone17Pro(gate), iOS26.5 **1,680/1,680**, zero failures/skips
  among selected tests: `/private/tmp/stocksage-m3-broad-ios-20260906-2145.xcresult`.
- Same three opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. Counts checked
  with xcresulttool. Existing unrelated compiler warnings remain. All handles done.

M2b live smoke remains pending: the credential-access hook blocked even a
key-presence check at21:32. No key was read; no guard was bypassed. This is NOT
evidence of a missing key or rejected Massive entitlement. No live probe was run.
Full populated app/VoiceOver QA is also pending; the owner app/binary was not
replaced or relaunched. No model job, real order, push or main project.pbxproj edit.
Next independent stage: M4 news/insights and cited narration, then remaining
M5/M5b/M6/P5/Chat/Derayah work and final integration. M3 is code/test-complete,
not live-verified. Current request budget supersedes the earlier one-call/day
proposal: see the implementation note in COVERAGE_DESIGN_2026-09-06.md.

## Pipeline 4 M2b compact-card checkpoint — 2026-09-06 21:29 +03

US idea cards now show the existing coalesced bid/ask observation: prices, share
sizes, Massive SIP attribution, absolute SIP time, bid/ask venues and observed
spread. The SAME copy is included in the card's overriding VoiceOver label.
Unknown venue IDs remain explicitly unknown until the shared exchange reference
resolves; reference loading reuses the stream's existing startup task and the
24-hour reference cache. No per-card request, socket or timer was added.

The strip deliberately says "last observed, not a fill quote", not "Live". It
does not claim a displayed historical spread is cost-eligible. Existing money
callers still use spreadBps(at:), with five-second freshness and condition
qualification unchanged. One-sided, locked/crossed, zero-size and invalid-number
books do not display a computed spread; a missing book says costs are estimated.
Tadawul cards are unchanged.

Verification (serialized xcodebuild, independently read xcresulttool summaries):
- Focused macOS: **11/11**, zero failures/skips, before the venue-label addition:
  `/private/tmp/stocksage-nbbo-compact-focused-20260906-2120.xcresult`.
- Final broad macOS: **1,672/1,672**, zero failures/skips among selected tests:
  `/private/tmp/stocksage-nbbo-compact-broad-macos-20260906-2124.xcresult`.
- Final broad iPhone17Pro(gate), iOS26.5: **1,671/1,671**, zero failures/skips
  among selected tests:
  `/private/tmp/stocksage-nbbo-compact-broad-ios-20260906-2127.xcresult`.
- Same explicit opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. The extra Mac
  test renders the actual compact component at320pt via ImageRenderer. Inspected
  `/private/tmp/stocksage-nbbo-compact-320.png`: all four lines visible. This is
  component-only QA with synthetic data, NOT full populated app/VoiceOver QA.

All build handles completed. git diff --check is clean. No live authenticated
smoke, real order, model job, push or change to the owner's running app binary.
M2b's remaining verification is populated UI and authenticated provider smoke;
then M3–M6, P5, approved Chat/Derayah work and final integration. Main
project.pbxproj and its unrelated work remain untouched.

Owner asked why the goal looks stalled at21:27. The product goal record is still
marked blocked from earlier, but the separate overnight heartbeat was verified
ACTIVE/every15minutes in this task. That stale goal status does not describe this
implementation checkpoint. Available goal tools cannot resume/reset that status;
do not falsely mark the whole objective complete to remove the badge.

## Pipeline 4 M2b trade-ordering checkpoint — 2026-09-06 21:13 +03

Same-millisecond trades now retain Massive's exact64-bit `q` through the parser,
authenticated StreamState,500ms Store buffer, board/idea merge, scan publication
and quote-cache round trip. Only a strictly larger known T-channel sequence for
the same symbol can break a timestamp tie. Quotes keep their independent Q
sequence. Later timestamps win even when sequence resets; unsequenced later
polls clear old metadata, and legacy caches decode to unknown. No sequence is
invented from a timestamp, price, provider arrival order or another channel.
Stop/target, advice and analysis time remain unchanged by live-price replacement.

The shared ingress also fixes a second regression: taking max(boardTime,ideaTime)
let a corrupt future value mask a valid clock, allowing an older price to replace
both. Each existing observation is now checked independently before accepting a
tick/merge. Quote symbols must match their dictionary keys. Existing undated and
future-time fail-closed rules remain; unknown equal-time provenance stays blocked.
Protocol: https://massive.com/docs/websocket/stocks/trades (`t` milliseconds;
`q` increasing, per-ticker, gaps permitted). This is last-trade ordering, not a
new trade-condition/execution-eligibility policy.

Verification, serialized canonical xcodebuild tests:
- Red: both new regression tests failed against the old code, exit65,
  `/private/tmp/stocksage-sequence-red-20260906-2104.xcresult`.
- The first expanded attempt failed compilation on a test tuple inferred as
  Int rather than Int64 and executed no tests; explicit fixture typing fixed it.
- Focused **42/42**, zero failures/skips:
  `/private/tmp/stocksage-sequence-focused-retry-20260906-2107.xcresult`.
- Broad macOS **1,670/1,670**, zero failures/skips among selected tests:
  `/private/tmp/stocksage-sequence-broad-macos-20260906-2109.xcresult`.
- Broad iPhone17Pro(gate), iOS26.5 **1,670/1,670**, zero failures/skips among
  selected tests: `/private/tmp/stocksage-sequence-broad-ios-20260906-2110.xcresult`.
- Same explicit opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. Counts were
  independently read with xcresulttool; no live provider success is implied.
  Existing compiler warnings in allocation/EV and Massive timestamp fixtures remain.

All build handles completed. No live smoke, new-branch populated visual QA,
actual order, model job, push or change to the owner's running app binary.
M2b still needs compact cards and visual/authenticated smoke, followed by M3–M6,
P5, approved Chat/Derayah work and integration. Main project.pbxproj stays untouched.
The owner's ORCL question was answered from their existing running app: no idea
or directory match, with action=All and Any signal strength. This was observation
of the OLD app, not new-branch QA. The baked universe membership restriction in
StockSageQuoteService excludes ORCL; no universe policy was changed or scan run.

## Pipeline 4 M2b measured-cost checkpoint — 2026-09-06 20:43 +03

Current EV/ranking, allocator cost gates, decision snapshots, Today plan and
Markets card/detail/copy/ledger paths now select costs from the SAME idea NBBO.
Qualified fresh US spreads can only raise the existing8bps spread floor. The
full quoted width represents both half-spread crossings; slippage, fees and
per-order minimums are unchanged estimates. Historical backtests, paper candle
simulation and journal slippage benchmarks still use their original defaults.
The shared idea net-RR helper also includes short financing on cards, matching
the detail/ranking path that already included it.

Eligibility is deliberately narrow: one bounded, header-authenticated reference
request per stream start resolves Massive condition IDs from UTP `R` (regular
two-sided NBBO), with no guessed numeric ID. Only non-legacy, non-exchange-specific
stock quote conditions qualify, and only when no indicators are supplied.
Unknown/flagged/malformed metadata, incomplete/duplicate reference records,
reference failure, expired reference, stale/future/locked/crossed/one-sided quotes
all retain default costs. Indicator-bearing quotes remain visible, not cost
evidence, until their semantics are verified. This is NOT trading-halt detection
or execution authorization. Reference retry is on restart, not a polling loop.

The authenticated book propagates at500ms, with a shared one-second expiration
invalidation; money helpers check exact age (5s inclusive). Withdrawals, auth loss
and stop clear cost inputs. Scan and trade-price replacement preserve fresh NBBO
without changing the analysis time. Detail/copy actions re-resolve the store,
so a selected sheet's older value cannot retain a withdrawn cost quote.

References:
- https://massive.com/docs/rest/stocks/market-operations/condition-codes
- https://massive.com/docs/websocket/stocks/quotes
- https://www.utpplan.com/DOC/uqdfspecification.pdf (section7.5.2.2)

Verification:50/50 focused macOS tests, then canonical broad tests **1,664/1,664
passed on EACH platform**, zero failures/skips among selected tests. Explicit
exclusions remain CalibrationPersistRunTests, LiveUniverseVerificationTests and
StrategyBaselineMeasurementTests (opt-in network/measurement). Result bundles:
- `/private/tmp/stocksage-m2b-cost-macos-20260906-2040.xcresult` (focused)
- `/private/tmp/stocksage-m2b-cost-broad-macos-20260906-2038.xcresult`
- `/private/tmp/stocksage-m2b-cost-broad-ios-20260906-2040.xcresult`

All run handles completed; no compiler remains. Existing warnings in allocation
optimizer/EV tests remain. No live provider smoke, populated visual QA, real order,
model load/conversion or push. **M2b overall remains incomplete:** compact cards,
same-time trade sequence through Store, visual QA and authenticated smoke remain.

## Pipeline 4 M2b data/UI checkpoint — 2026-09-06 20:18 +03

The existing Massive connection now subscribes to `Q.` alongside `T.`. Quote
and trade freshness remain independent, with500ms quote publication. The detail
sheet shows bid/ask prices, share sizes, venue attribution and SIP time. Spread
is withheld when older than5s, future-dated, locked, crossed or one-sided.
Distinct same-time QUOTES use exact64-bit per-symbol sequence ordering; the
separate same-time TRADE-to-Store sequence change remains pending.

The on-demand Tape sheet reads `/v3/trades` and `/v3/quotes`, pinned to one symbol
and a seven-day window, capped at3pages ×100rows per channel. Partial results,
invalid rows, entitlement errors and invalid/repeated cursors stay visible.
Bearer authorization is header-only; pagination rejects other hosts/paths/ports,
userinfo, fragments and API-key queries, and redirects are disabled.
The exchange reference is cached24h in process; Nasdaq filtering uses `mic=XNAS`,
never a guessed numeric ID or tape-C listing. Filtered quote sides are not NBBO.

Shared numeric decoding now rejects JSON booleans and fractional/overflowing
integer metadata, retaining exact integer spelling before a Double fallback.

Verification: canonical `xcodebuild test`, parallel testing disabled, **1,660
passed on macOS and1,660 on iPhone 17 Pro (gate)/iOS26.5**, zero failures/skips
among selected tests. The same three opt-in network/measurement suites listed
under M2 were explicitly excluded. Result bundles:

- `/private/tmp/stocksage-m2b-broad-macos-20260906-2014.xcresult`
- `/private/tmp/stocksage-m2b-broad-ios-20260906-2016.xcresult`

**M2b is not complete:** the panel explicitly states ranking/tickets still use
estimated costs. Next: measured spread through every ranking/gate/export caller,
conservative cost floors and quote-condition eligibility, compact card display,
trade sequence propagation, populated visual QA and authenticated endpoint smoke.
No live provider call, actual order, model load or push was performed by this gate.
Continue the remaining checklist in `agent-docs/PIPELINE_TAKEOVER_2026-09-06.md`.

## Pipeline 4 M2 — 2026-09-06 20:00 +03, Codex single-session takeover

Owner stopped the separate pipeline task; its uncommitted M2 changes were
preserved and completed on `wt/coverage`. Massive replaces the active EODHD
stream/quote route; Yahoo remains the fallback. The stream consumes every event
in a batch, preserves authorization across informational statuses, handles send
failures, and cancels stale connection callbacks/retries. Auth alone does not
prove delivery: per-symbol coverage expires 45 seconds after the last accepted
trade. Status publication changes only on transitions, with a one-second expiry
timer; Store price writes retain their 500 ms coalescing.

All quote ingress paths now share ordering/validation: full refresh, targeted,
monitor/gap polls, stream flushes and scan publication cannot rewind a dated
price. Undated seeds remain unknown, corrupt future cache values can recover,
off-board ideas update without creating board rows, and row UUIDs survive polls.

Canonical `xcodebuild test`, separate result bundles, parallel testing disabled:

- macOS arm64: **1,649 passed, 0 failed**, bundle
  `/private/tmp/stocksage-m2-broad-macos-20260906-1956.xcresult`.
- iPhone 17 Pro (gate), iOS 26.5: **1,649 passed, 0 failed**, bundle
  `/private/tmp/stocksage-m2-broad-ios-20260906-1957.xcresult`.
- Both explicitly exclude `CalibrationPersistRunTests`,
  `LiveUniverseVerificationTests`, `StrategyBaselineMeasurementTests` (opt-in
  network/measurement jobs). Zero skips among selected tests; excluded suites
  are not claimed tested. Counts independently read with `xcresulttool`.
- One earlier expanded-test attempt failed compilation on a fixture typo and
  executed no tests; corrected before the focused and broad successful runs.

Not yet verified: live endpoint smoke, per-observation provenance UI, NBBO/tape,
same-millisecond sequence ordering, remaining M3–M6, pipeline 5, final integration.
Continue via `agent-docs/PIPELINE_TAKEOVER_2026-09-06.md`. No push or real order.

Written early under the good-spender `⚠ APPROACHING LIMIT` directive (projection only — this
session is the sole spend in the 7-day window; the EWMA is a read-burst artefact).

## Environment blocker — RESOLVED 09:44 +03 (licence accepted; `xcodebuild`, `/usr/bin/git`, Homebrew work again)
Until 09:44 +03 Xcode 26.6 (17F113) had an unaccepted licence, so `/usr/bin/git`, `xcodebuild`, `xcrun`
and `brew` all refused with "You have not agreed to the Xcode license agreements". Everything below
about "tests NOT run" refers to commits made before that. The iOS 26.5 simulator platform (~8 GB)
was still downloading at 09:49 +03 (owner-approved) — the iOS `xcodebuild test` leg is pending it.

Workarounds used while it was blocked (kept — they are fast gates in their own right):
- git: call `/Applications/Xcode.app/Contents/Developer/usr/bin/git` directly.
- compile gate: `swiftc -typecheck` on `StockSage/Sources/**` for BOTH platforms — script at the
  session scratchpad `tc_stocksage.sh macos|ios` (flags mirror the pbxproj: Swift 6, MainActor
  default isolation, MemberImportVisibility, 26.5 targets). Baseline at 02ab1a0: clean on both,
  ~40 s each. Superseded the same day by `tools/gate.sh` (emit-module, both platforms + test-target
  type-check) and **`tools/runtests.sh`, which EXECUTES the whole Swift Testing suite without xcodebuild**
  (swiftc-built testable dylib + Testing.framework runner, throwaway HOME). `xcodebuild … test` itself
  still needs the licence; commits before 09:30 +03 say "tests NOT run" because the runner did not exist yet.

## Repo state at handoff
- `main` = 02ab1a0, **16 commits ahead of origin/main, unpushed** (all iPhone UI work, Jul 28–29).
- Worktree `~/StockSage-uiwork` on `ios-colour-overhaul` at the same commit, clean.
- Work branch for this session: `review-followups-2026-09-06` (off 02ab1a0).
- Backlog source of truth: `agent-docs/REVIEW_2026-07-28_claude.md` (Part 6 staged plan; Part 3
  UI list). `agent-docs/IOS_REVIEW_2026-07-27.md` is fully FIXED — not a queue.

## Done this session (branch `review-followups-2026-09-06`, 3 commits, tree clean, NOT merged, NOT pushed)
- d21cec5 — review #2 "Open heat"→"Planned heat X% of Y% cap" (honesty-critical), #8 iPhone sheet
  detents + grabber (detail sheet .medium/.large, Settings + Browse .large), #10 Reduce-Motion gates on
  the LIVE pulse and refresh spinner, #17c dead `fontMicro` removed.
- 0aac115 — review #7 `.touchHitArea()` on 13 icon/text-only controls (hit shape only, no layout
  change); #9 21 hardcoded font literals → @ScaledMetric tokens in MarketsTodayActionsCard,
  ExecutionQualityPanel, MarketSessionClockView (byte-identical at default Dynamic Type).
- ba82689 — Q3 `defer { isRefreshing = false }` for the whole refresh cycle; Q6 `addSymbol` passes
  `marketTime`; Q7 `quoteAsOf` max-merge; C2 rebalance sort symbol tiebreak.
Every commit: swiftc -typecheck clean on BOTH platforms; tests NOT run (licence). Skipped on purpose:
the #7 stepper relocation to the bottom bar (structural), Q8 (must follow Q4), and every owner-decision item.

## Batch 2 — 2026-09-06 08:30 +03 (workflow wf_02b04e3a-62a: 16 items, 7 isolated worktrees, 29 agents, 76 min)
All 16 items landed and were cherry-picked onto this branch in dependency order (cache → store → stream →
eodhd → fixture → ui2 → ui), `tools/gate.sh all` green after EVERY group (emit-module macOS + iOS +
test-target type-check). Tests still NOT executed (licence). Each group had an adversarial two-lens review;
every blocker/major was fixed in a `fixup(...)` commit except one the fix pass correctly rejected (the
reviewer flagged Q8 landing before Q4 inside the ui worktree — the merge order lands Q4 first).

| Item | Commit(s) | Note |
|---|---|---|
| Q4 marketTime in quote cache Entry | d131554 | review: clean |
| Q1 heal sweep scoped + capped + backoff | 2be3bd2, a73444f | keeps existing `healBatchCap`/`marketIsTrading` gate (superset); pure `healCandidates` pinned by 6 tests |
| Q9 mirror sweep prices onto ideas | 988da1f, 3bf5994 | fixup: `mergeLiveQuote` no longer fabricates `asOf: Date()` — nil stays unknown |
| P3 O(1) `symbolIndex` | 91d32c3 | also rebuilt in addSymbol/removeSymbol (review omitted them) |
| Q5 stream auth classifier + watchdog | 084b16f, 98690dc | fixup: MarketsView now OBSERVES the stream so the LIVE dot redraws |
| Q10 EODHD parser parity | 22ab017, 1f49ccb | fixup: `parseRealTime([String: Any])` overload so the isFinite guard is testable |
| P2 fixture real spark + clique alloc | 299f009, 45f50bc, 9c79c8f, 80a109c | fixup: per-idea varied spark (a shared spark made a degenerate all-1.0 clique) |
| UI#5 fontCaveat / section header 15 | d25ad97 | 3 calibration labels re-pointed (review said 2) |
| UI#13 iOS watchlist remove + reason | 864129a | |
| UI#15 ideasHeader two tiers | b613ec0 | analysis-timestamp line left untouched (one ternary, always visible) |
| UI#16 minWidth fields + wrap | 4140e3a, 37ffd0d | fixup: 4 other widened-field rows also wrapped |
| UI#6 dangerSoft badges + text sweep | 02a95c3 | static `actionColorForTest` seams + guard test |
| UI#3 ViewThatFits metric rows | c591a18 | 5 rows split (idea card exact per review; 4 others minimal) |
| UI#4 `.explain()` shim | 93c6ede | ~13 honesty-bearing `.help` sites converted; sheet stop line not found by text |
| Q8 banner fail-closed | 774522d | shared `MarketsView.freshnessStale(asOf:now:)` |

Minor review findings left OPEN on purpose (small, do after tests can run): Q5 ping has no pong deadline and
`armWatchdog()` re-allocates per frame; Q1 evaluates `marketIsTrading` for every row before the scope filter;
Q1 backoff `before` lookup is a linear scan (could use `symbolIndex`); the same O(n) `currentPrice` scan
still exists in MarketsRiskAllocationSection (unwired file) and `fxRateAge`; `capTruncates` passes the cap
as a literal 40.

Also this session: `tools/gate.sh` (95b54e2) committed as the licence-blocked compile gate; Ollama 0.33.3 +
`qwen3.8` (27B) installed on this Mac for the new Catalysts tab's optional local explanation backend
(see the Catalysts section once it lands).

## wt/ui — 2026-09-06 09:20 +03 (worktree /Users/saleh/StockSage-wt/ui, branch wt/ui, base e619739) — restored 09:58, dropped by mistake at 09:50
Two commits, `tools/gate.sh all` green after each (macos=OK ios=OK tests=OK; tests type-checked, NOT
executed — licence). good-spender was turned ON for good mid-run (user directive, saved to memory).

| Commit | What |
|---|---|
| 648c425 (wt/ui 4cfa3f9) | fixup(UI#6): the 9 realized-stats + risk-analytics ideaMetric sites → dangerSoft via a new static seam `MarketsView.signedMetricColor(positive:positiveColor:)`, pinned by `SignedMetricColorTests` (BacktestVerdictColorTests.swift) |
| dd578ae (wt/ui 1d2637c) | fixup(UI#6): the remaining 17 small-text raw-danger sites (+2 mixed-helper consumers: `hc` heat text, healthColor verdict text) across MarketsView + MarketsRiskAllocationSection; 25 icon/fill/stroke/background sites keep raw danger. Sonnet diff review: APPROVE, 1 minor (watchlist arrow icon inherits dangerSoft with its text) |

Owner call, NOT changed: white text on a raw-danger FILL — STOP TRADING banner (~3316), "Confirm close"
button (~3631), "DO NOT TRADE" chips (~5877 and ~6998 → BestOpportunityActionCard:9881). Same 3.41:1
class UI#6 fixed on the sell badge, but these are stop/destructive surfaces where the red fill is the
convention — decide badge treatment (pastel fill + dark ink) vs keep.
RESOLVED 2026-09-06 09:35 +03 — owner approved; landed as 0897fea (badgeInk + gateChipColor seams, test-pinned, gate green).

Landed on review-followups-2026-09-06 as 648c425 + dd578ae (cherry-picked clean, gate re-run there —
see merge_gate.log). Licence accepted 2026-09-06 09:44 +03; canonical gate run at 09:47 +03: macOS build OK, macOS
test OK — 1,426 tests in 166 suites passed (Swift Testing, 14.2 s; first EXECUTED run since Jul 29).
iOS leg BLOCKED at first: Xcode 26.6 needs the iOS 26.5 simulator platform (the 27.0 beta runtime is
not an eligible destination); owner approved `xcodebuild -downloadPlatform iOS` (~8 GB) at 09:49 +03.
Next: iOS leg result (see merge_gate.log), then push. Spend (good-spender estimate): run closed at $28.27 vs $3.00 est (9.42x OVER — ~30 Fable-tier
classifier agents ran inside an ultracode workflow before it was stopped on the good-spender directive).

## Catalysts tab — NEW (owner request 2026-09-06, workflows wf_3c5d578a-629 + wf_41e9e30c-825; 10 commits cba3f92..d382cc0)
"A new tab that shows, for the same ideas as the Ideas tab, the key catalyst to watch and explains why" —
BOTH per-idea cards AND a date-ordered calendar; the why is engine rationale always, plus an OPTIONAL
model-written paragraph on tap (owner chose "both" / "both").

| Piece | File | Notes |
|---|---|---|
| Engine | `StockSage/Sources/StockSage/StockSageCatalystWatch.swift` | pure; precedence earnings(imminent/soon) → volume move → earnings(clear) → range extreme → risk-off regime (long ideas only) → reliable seasonality → none; every string lives here; UTC-fixed dates; past earnings (>24h) never shown |
| Narrator | `StockSageCatalystNarrator.swift` | routes over Apple FoundationModels (on-device) and the local server; facts list → ≤80 words, ticker-only, no new numbers; foreign-number guard withholds output; every paragraph labelled with its SOURCE + model |
| Local server client | `StockSageLocalModelServer.swift` | Ollama native `/api/chat` (think:false, num_ctx 4096) or OpenAI-compatible `/v1/chat/completions`; probe; backends auto / on-device only / local server only / off; loopback default; non-loopback WARNS FIRST (banner + per-card) |
| View | `StockSage/Sources/Views/CatalystsSection.swift` | header (mode picker, regime line, always-visible caveat, sample-data label, "Explanation model" settings), lazy cards, calendar buckets Today/Tomorrow/This week/Later/No date on file; earnings fetched for ≤30 shown ideas, ≤4 parallel; 8-K filings on tap (US) |
| Wiring | `MarketsView.swift` (d49a903) | `MarketSection.catalysts` between Ideas and All, icon calendar.badge.clock, `CatalystsSection(ideas: displayedIdeas, store: store) { selectedIdea = $0 }` — same projected board, same order |
| Tests | `StockSageCatalystWatchTests` (12), `…NarratorTests` (13), `…LocalModelServerTests` (9), `CatalystsSectionTests` (3), `…PropertyTests` (11, 52,500-combination oracle sweep) | all EXECUTED green via `tools/runtests.sh` |

Reviews: tab review found 2 blockers (past earnings shown as imminent; calendar dropped the RVOL "unvalidated"
caveat) + 2 majors (UTC vs local day; eager cards) — fixed f098044. Backend review found 2 blockers (LAN warning not
visible at the Explain action; label named the CURRENT model setting, not the generating one) + 1 major (auto
fallback untested) — fixed 39ec0d0/3410c82.

Local model on this Mac (owner "okay"): Ollama 0.33.3 standalone under `~/.local/opt/ollama`, LaunchAgent
`com.ollama.serve` on 127.0.0.1:11434 (keep-alive 24h), model `qwen3.8` (27B Q4_K_M, MTP speculative decoding on).
Measured: quiet Mac 15–53 tok/s ≈ 3–10 s per paragraph; with Swift compilers running 7–11 tok/s. MLX 4-bit + MTP
drafter via mlx-vlm was ~1.3× faster steady-state (3.7–6.3 s) — NOT made the default; venv at `~/.local/venvs/mlx`,
34 GB of A/B artefacts (Ollama tag `qwen3.8:27b-mlx`, HF cache) left on disk for the owner to delete or keep.

## EXECUTED test results
**Canonical `xcodebuild -scheme StockSage -destination 'platform=macOS' … test` on the tab branch (rebased onto
5c547f1), 2026-09-06 09:53 +03: `✔ Test run with 1476 tests in 171 suites passed after 26.920 seconds` — ** TEST
SUCCEEDED ** (n=1,476 executed, 0 failed).** iOS leg: pending the 26.5 simulator platform download (other session).

tools/runtests.sh (macOS arm64, 09:40 +03), before the licence was accepted:
`✔ Test run with 1474 tests in 170 suites passed after 29.967 seconds` on d382cc0's tree (n=1,474 executed, 0 failed).
Earlier the same runner passed 1,446/1,446 on d49a903 (batch 2 + tab wiring) and 33/33 on the catalyst suites.
Not executed: SwiftUI rendering (no simulator/app run), the Apple on-device model path (needs an Apple
Intelligence device), live Yahoo/SEC/Ollama network paths beyond the read-only Ollama probes.

Canonical gate on BOTH platforms at HEAD 5b3f2a4 (2026-09-06 10:01 +03, wt/ui session): macOS test
1,476/1,476 in 171 suites; iOS test 1,476/1,476 in 171 suites on an iPhone 17 Pro simulator (iOS 26.5
23F77, platform downloaded 09:49–09:54 +03, 8.52 GB). HEAD unchanged during the run. Not pushed.
Uncommitted `StockSage.xcodeproj/project.pbxproj` reorder (104+/91−, no semantic change) left for its owner.

## Next actions
1. Owner: `sudo xcodebuild -license accept`, then the canonical `xcodebuild … test` on macOS AND the iOS 27
   simulator (the runner covers macOS only; iOS is emit-module-checked). Open the app: Ideas → Catalysts tab,
   both modes; tap Explain with Apple Intelligence on; set Backend = Local server with Ollama running.
2. Merge `review-followups-2026-09-06` → `main` when green; push `main` (was 16 ahead before this branch).
3. Backlog: the minor review findings listed under Batch 2 above; remaining OPEN review items are the
   owner-decision ones (Q11, C1 wording, M1 retention, UI#11 iPad, UI#1 crown, F1 dead engines) + P2-memo
   (allocator memo, `StockSageStore` + `MarketsView` capitalAllocationCard), UI#3's remaining rows if any.
4. Decide on the MLX server as default (needs a launch agent; ~1–2 s faster per tap) and on deleting the 34 GB
   of A/B model files.
5. The background sweep session's work (`wt/ui`) is ALREADY on this branch (648c425, dd578ae, 0897fea —
   see the wt/ui section above); its worktree `~/StockSage-wt/ui` can be removed once it has run the
   iOS test leg and pushed.

## W4 — local-model retrieval-first internet access (2026-09-06, worktree cov-w4, branch wt/cov-w4)
Citable sources for the on-tap Catalyst "Explain" paragraph: EODHD news (`StockSageNewsService`,
new), the last 8-K (`StockSageDisclosureService`, existing), and insider Form 4 activity
(`StockSageInsider`, existing — now also gated by `ToolPolicy.isExternalAllowed`, closing the one
feed in this subsystem that hit the network unconditionally). `StockSageCatalystNarrator.facts(for:sources:)`
appends one numbered `[n] YYYY-MM-DD <source>: <title> — <snippet> (<link>)` line per source; the
model may cite `[n]` and both the existing number fence AND the new `citationsValid(_:sourceCount:)`
gate must pass before a response is shown as `.text` — otherwise `.withheld`. US/NASDAQ-only via
`StockSageEODHD.covers`, matching the sibling SAHMK/Tadawul task being cancelled (12:57 +03 scope
change) — nothing here touches Tadawul or `.SR` symbols.

**EODHD news cost**: `/api/news` is billed 5 API calls per request PLUS 5 more per ticker named in
the request — one call for one symbol therefore spends 10 calls against the 100k/day EODHD
allowance, separate from and in addition to the existing quote path's per-symbol cost.

**Privacy**: tapping "Explain" now also sends the symbol to eodhd.com (news) and sec.gov (8-K
filings, insider Form 4 trades) directly from the device, in addition to whichever narrator
backend (on-device Apple Intelligence or the local server) answers the paragraph. The Catalysts
tab header states this unconditionally, alongside the existing non-loopback warning.

Gate: `GATE repo=cov-w4 macos=OK ios=OK tests=OK`. Tests: filtered StockSageInsiderTests 10/10,
StockSageNewsService 12/12, StockSageCatalystNarratorTests 23/23; unfiltered suite 1,551/1,551
tests in 177 suites, 0 failed (tools/runtests.sh, EXECUTED, 65.3s). No network hit in any test —
all fixtures are hand-derived pure-parse inputs; `ToolPolicy.override` gating test uses the
pre-existing `ToolPolicyTestLock` seam.
