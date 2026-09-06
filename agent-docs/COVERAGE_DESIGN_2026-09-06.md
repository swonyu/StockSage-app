# Coverage design — every tracked stock: catalyst on file + live quotes (2026-09-06)

Owner directive (verbatim, 10:05 +03): "i want every stock to have a catalyst on file and every stock
tracking should be live" · "i dont care if it would cost" · "do it all". Cost-side owner gates WAIVED;
provider rate limits + the honesty floor still bind. Work branch `wt/coverage` (worktree
`~/StockSage-wt/coverage`, base 9b1f4fa on review-followups-2026-09-06). Investigator: Opus read-only
pass at HEAD 9b1f4fa; every line below cites file:line as of that commit.

Tracked = watchlist (`StockSageStore.userSymbols`, UserDefaults `stocksage_user_symbols`) ∪ board
(`StockSageStore.ideas` over `trackedDefs`: `StockSageUniverse.worldwide` ∪ userSymbols = 901 names:
28 Tadawul + `^TASI.SR` + 872 NASDAQ) ∪ portfolio (`StockSagePortfolio.shared.positions`) ∪ journal
open (`StockSageJournalStore.shared.open`).

## A — catalysts today
1. Computed for every symbol with cached history (`refreshCatalysts`, StockSageStore.swift:1823-1833) but
   DISPLAYED only for `displayedIdeas` (MarketsView.swift:4470, 4685-4691).
2. Kinds (precedence, StockSageCatalystWatch.swift:123-178): earnings (Yahoo `quoteSummary
   calendarEvents`, StockSageEarnings.swift:57-68; `.SR` is "Equity" so attempted — whether Yahoo returns
   Saudi dates is UNVERIFIED) · volumeMove (RVOL≥3.0 AND |move|≥4%, StockSageCatalyst.swift:26-56) ·
   extreme · regime (board-wide) · seasonality (top-15 EV, 10y monthly) · none. 8-K filings are on-tap,
   US-only, never persisted.
3. NOTHING persisted: `catalysts`/`earningsDates` are in-memory @Published (StockSageStore.swift:1668,
   1814, comment at 2309). No TTL, no negative caching. `refreshEarnings` no-ops on a known date but
   records NOTHING on a miss ⇒ every nil symbol is re-fetched every launch (:1693-1699).
4. Zero-catalyst symbol: card says "No dated catalyst on file … not fetched yet, or the source declined"
   (StockSageCatalystWatch.swift:283-288) — cannot distinguish "asked, nothing" from "never asked";
   calendar drops it (`kind != .none`, :346).
5. Caps: earnings prefetch 15 (store :1704-1715) and 30 (view CatalystsSection.swift:168-178), 4-parallel.
   Stale guards one instant apart: fetch > -86_400 (:1697), derive >= -86_400 (:1684), engine >= (:132).
   Dates UTC en_US_POSIX (:110-114), buckets UTC (:314-330).

## A — design (persist the NEGATIVE observation, never a fabricated catalyst)
A1 NEW `StockSageCatalystRecordCache.swift` (shape of StockSageQuoteCache.swift:70-86): `Record {symbol,
   earningsDate: Date?, checkedAt: Date, source: String}`. Test: round trip, nil date keeps checkedAt,
   corrupt ⇒ nil. 0 calls.
A2 StockSageStore: `earningsCheckedAt: [String: Date]`; `refreshEarnings` stamps checkedAt on BOTH
   outcomes; TTL guard `earningsCheckTTL = 24h` replaces the `== nil` guard; load cache in init beside
   loadCachedQuotes (:218), save after sweeps. Test: nil stamps; inside-TTL no refetch; straddle at 24h.
A3 StockSageCatalystWatch: `Inputs.earningsCheckedAt: Date?` (default nil); split `noneItem`: with
   checkedAt → "No known catalyst as of <date>", source "Yahoo calendarEvents (no date returned)",
   date = checkedAt; without → today's "not checked yet", date nil. Calendar includes dated .none in a
   distinct negative-record bucket (flag on the entry), undated stays out. Tests: strings verbatim,
   bucket membership, property-sweep axis.
A4 StockSageStore: `trackedSymbols(board:watchlist:portfolio:journalOpen:)` pure union (+ instance
   `trackedSymbolsUnion`); `refreshEarningsForTracked()` TTL-gated over the union (FULL board — owner
   waived cost), 4-parallel, `Task.isCancelled` between chunks. ≈900 Yahoo quoteSummary calls / 24h.
A5 CatalystsSection: pass `earningsCheckedAt`; DELETE the local prefix(30) prefetch (one sweep, not two);
   style negative rows distinctly (*Soft tokens only); fix the "top 30" empty-state string.

## B — live tracking today
1. Stream: `StockSageLiveStream.start(symbols:)` with `store.symbols` (MarketsView.swift:553-556,
   key 297-299, toggle `stocksage.liveStream` default true) ⇒ 872 US names on ONE socket, NO cap in
   code (:157-163). Tick flush 500 ms (StockSageStore.swift:1767). Poll: auto-refresh 285 s `.full`
   (901 names) (MarketsView.swift:557-564); monitor 180 s `.core` (61) ×2 thermal
   (StockSageMonitor.swift:88,115,126-129). Heal Q1: scope/marketIsTrading/backoff/cap 40
   (StockSageStore.swift:1976-2036). N2: `marketsWatchlistOnly` skips `.core` ⇒ Tadawul loses its poll
   (StockSageMonitor.swift:59,102-104). Q5 watchdog 45 s (StockSageLiveStream.swift:100-121).
2. Tadawul = Yahoo-only, un-streamable (StockSageEODHD.swift:10-16, deliberate). 872 stream, 29 cannot.
3. "Live" = `freshnessStale(asOf:now:)` = `asOf.map { > 3600 } ?? true` (MarketsView.swift:9528-9530);
   row rule 48h/6h nil⇒stale (StockSageModels.swift:84-90).
4. Budget TODAY: 12.63 sweeps/h × 872 + 640 ≈ 11,650 EODHD REST calls/h (100k/day allowance, enforced
   nowhere) ⇒ ~8.6 h app-open/day; ~950 Yahoo/h for 29 `.SR`.

## B — design (live for every tracked symbol while CUTTING provider load)
B1 `trackedDefs` includes off-board watchlist/portfolio/journal symbols (today `currentPrice(for:)`
   has NO price for an off-board holding, StockSageStore.swift:117).
B2 `TrackedScope.streamGap` = tracked − `StockSageLiveStream.shared.subscribed`, filtered by the
   existing `marketIsTrading` (:2027). Pure `streamGapCandidates(tracked:subscribed:isTrading:)`.
B3 MarketsView timers: streamGap every 60 s (open hours only), `.full` slowed to 900 s; manual /
   pull-to-refresh / tab-open stay `.full`; thermal brake ×2 via pure `refreshIntervals(thermal:)`.
B4 Stream from the tracked union, not `store.symbols`.
B5 `maxSubscriptionsPerConnection` from EODHD docs (UNVERIFIED — look up first); chunk across
   connections; `subscribed` = union actually sent; never silently over-subscribe.
Q11 (do first): a throttled sweep must not erase last-good cache entries (merge over previous, keep old
   marketTime so stale reads stale). N2: streamGap/Tadawul sweep runs regardless of watchlist-only.
FAIL-CLOSED, do not touch: freshnessStale `?? true`; QuoteFreshness nil⇒stale; mergeLiveQuote `asOf:
   q.marketTime` (no `?? Date()`, Q9); refresh mirror loop likewise; 50% coverage guard (:1939);
   sample/cached notification suppression (StockSageMonitor.swift:159).
Budget AFTER: EODHD REST 4×872 = 3,488/h (0 during US close); Yahoo chart 60×29 = 1,740/h during
   Tadawul's 5 h ⇒ 8,700/day; quoteSummary ≤ |tracked| per 24 h. Headroom 8.6 h → ~28 h/day.

## Decisions taken (owner directives resolve every gate the brief raised)
full-board catalyst sweep · 60 s streamGap / 900 s full · Tadawul 60 s · streamGap regardless of
watchlist-only · fix Q11 first · "No known catalyst as of <d Mon yyyy>" + source · measure/lookup the WS
cap before choosing it.

## Execution plan (worker pipeline, cheap models; script saved by the Workflow tool)
Stage 1 parallel, own worktrees `~/StockSage-wt/cov-{a1,a3,tracked,stream}` (branches `wt/cov-*`): A1 ·
A3 · TRACKED (union fn only) · STREAM (docs lookup + B5). Integrate: cherry-pick onto `wt/coverage`,
gate + `tools/runtests.sh` unfiltered. Stage 2 sequential on `wt/coverage`: T4 = A2+A4+B1 · T5 =
B2+Q11+N2 · T6 = B3+B4+A5+thermal. Review: two Opus lenses (honesty/fail-closed; correctness/
concurrency) → fix pass → final gate. Then cherry-pick onto review-followups-2026-09-06 and run the
canonical xcodebuild gate on macOS + iOS.
Script: ~/.claude/projects/-Users-saleh-StockSage-wt-ui/d1ce9e6b-22eb-4405-ba77-65e67a42f96b/workflows/scripts/stocksage-coverage-wf_5ecce5fc-973.js
First run wf_5ecce5fc-973 (10:15 +03): all 11 agents refused — account monthly spend limit; session
window resets 10:30 +03. Nothing was written to any worktree by that run.

Correction 10:21 +03: that run DID create four clean worktrees (cov-a1/a3/stream/tracked, 0 commits, 0 edits); removed before the retry.
