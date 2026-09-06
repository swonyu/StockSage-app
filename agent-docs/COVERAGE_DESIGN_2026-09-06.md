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

## Follow-up scope (2026-09-06 10:5x)

Three research passes (Sonnet) fed this step; each is condensed at
`research_earnings_sources_2026-09-06.md`, `research_tadawul_realtime_2026-09-06.md`,
`research_local_model_internet_2026-09-06.md` (scratchpad, not in-repo — copy pasted below where a
decision depends on it, so this doc stays the durable record).

**Earnings sources (condensed).** Yahoo `calendarEvents` gives a 2-element `earningsDate` RANGE plus
`isEarningsDateEstimate`, which the app parser (StockSageEarnings.swift:71-83, pre-W1) discarded —
min-epoch only, flag ignored. EODHD's `/api/calendar/earnings` is plan-gated (probe status only, never
assume the tier); it has NO Tadawul coverage at any tier (matches StockSageEODHD.swift's own measured
gap) but DOES expose `Earnings.History` off the fundamentals endpoint (10 calls/request, owner-waived)
— a genuine PROJECTION source for US names with ≥3 past reports. Alpha Vantage / FMP / Nasdaq.com were
surveyed and rejected for this step (low daily caps, Tadawul absent/unverified, or docs 403'd).
Recommended chain, adopted below: EODHD calendar (if the tier allows) → Yahoo (read the flag) →
projection from history; Tadawul has no EODHD or AV/FMP path at all, so it falls to Yahoo
`earningsHistory` (unverified live — see below) or `.unchecked`.

**Tadawul real-time (condensed).** Yahoo's own docs (help.yahoo.com/kb/SLN2310.html) say `.SAU`/Tadawul
quotes carry a HARD 15-minute delay via ICE Data Services — never "live" for `.SR ` regardless of poll
cadence; this doc's own §B budget numbers are unaffected (they're about REST call volume, not
staleness) but the "live" label logic must never claim otherwise for `.SR`. No measured vendor (EODHD,
Twelve Data, Polygon, AV, FMP, Finnhub) carries real Tadawul depth; the one Tadawul-licensed real-time
option surveyed is SAHMK (Pro tier $499/mo, WS + REST, `is_delayed` per tick) — an owner-gated
provisioning decision (account + key), not something this step can wire blind. Until that key exists,
Tadawul earnings projection has no data source beyond Yahoo's own `earningsHistory` module.

**Local-model internet access (condensed, not this step's scope).** A retrieval-first design
(Option A: a narrow `StockSageNewsService` hitting EODHD `/api/news`, numbered sources, citation
validation) was scoped for a LATER step — giving the on-device model real news/internet grounding.
Explicitly NOT built here; W1 below is catalyst-DATE coverage only. Flagged so the next session doesn't
re-research it from scratch.

**W1 decisions (this step).**
- Record model gets `status` (dateKnown/projected/notApplicable/unchecked), `confirmed`,
  `dateRangeEnd`, `sourcesAsked`, `projectionBasis` — all DEFAULTED via a hand-written
  `init(from:)` (verified empirically: Swift's synthesized `Decodable` does NOT fall back to a
  property's default value for a missing key — a hand-written decode init was required to make a
  pipeline-1 record on disk, missing every W1 field, still decode). No file-version bump: the
  shape is additive-with-defaults, not breaking.
- Chain per tracked EQUITY (assetClass == "Equity"; everything else ⇒ `notApplicable`, no network):
  EODHD calendar (skipped for 24h after a 401/402/403 probe result) → Yahoo calendarEvents (now
  reading `isEarningsDateEstimate` + the range) → projection (US: EODHD fundamentals
  `Earnings.History`, ≥3 past dates, median gap of the last ≤8 gaps; Tadawul: Yahoo
  `earningsHistory` module, same math, UNVERIFIED live this session — Yahoo's keyless endpoint was
  429-rate-limited on this Mac's IP all day (see research file) so a live Tadawul probe could not be
  confirmed; the parser is written defensively against Yahoo's documented shape and falls through
  to `.unchecked` + a SAHMK TODO if the module is empty/absent, never a guess) → `.unchecked` with
  `sourcesAsked` recording what was actually tried.
- EODHD's calendar carries no explicit confirmation flag (unlike Yahoo's `isEarningsDateEstimate`);
  `actual` is populated only once a report has already happened, so a NEXT-earnings (future) row
  from this endpoint is always `confirmed: false` — documented in `StockSageEODHDCalendar.swift`,
  not guessed.
- Engine precedence: `.projectedEarnings` sits between `.earnings` (clear) and `.extreme` — a
  projected date is more actionable than "price at a recent high/low" but less than an actually
  scheduled report. `notApplicable` only changes the NO-OTHER-CATALYST fallback text (an index/fund
  can still show a volume-move/regime/seasonality catalyst); `unchecked` reuses the existing dated/
  undated "none known" copy unchanged.

## Pipeline 4 — Massive migration (design)

Owner decision (repo facts, 2026-09-06): vendor = Massive (massive.com, formerly Polygon.io,
renamed 2025-10-30; `api.polygon.io`/`api.massive.com` both valid during transition), plan
Advanced ($199/mo, non-professional, SIP consolidated tape, **unlimited REST calls**, WebSocket
with **unlimited symbols and ONE connection** for the Stocks product) + Benzinga Earnings add-on
($99/mo). Every endpoint below was fetched THIS session (WebFetch + the browser render for the two
pages WebFetch's fetch cache returned as JS-shell-only) — URLs cited inline, full list in
`docsCited`. Investigator: read-only pass at HEAD bdb1284 (pipelines 1-3 landed); every code
citation below is file:line as of that commit.

### REST endpoints

| Purpose | Method + path | Key params | Doc |
|---|---|---|---|
| Full-market snapshot (ALL tickers, 1 call) | `GET /v2/snapshot/locale/us/markets/stocks/tickers` | `tickers` (comma list, omit for all 10,000+), `include_otc` | rest/stocks/snapshots/full-market-snapshot.md |
| Single-ticker snapshot | `GET /v2/snapshot/locale/us/markets/stocks/tickers/{stocksTicker}` | — | rest/stocks/snapshots/single-ticker-snapshot.md |
| Previous close (OHLC) | `GET /v2/aggs/ticker/{stocksTicker}/prev` | `adjusted` (default true) | rest/stocks/aggregates/previous-day-bar.md |
| Benzinga earnings | `GET /benzinga/v1/earnings` | `ticker`, `date`, `date.gte`/`date.lte`, `importance` (0-5), `limit` (max 50,000) | rest/partners/benzinga/earnings.md |
| Stocks news | `GET /v2/reference/news` | `ticker`, `limit` (max 1000), `published_utc` | rest/stocks/news.md |
| Reference tickers | `GET /v3/reference/tickers` | `ticker`, `market`, `exchange`, `search`, `active`, `limit` (max 1000) | rest/stocks/tickers/all-tickers.md |
| REST trades | `GET /v3/trades/{stockTicker}` | `timestamp[.gte/.gt/.lte/.lt]`, `order`, `limit`, `sort` | rest/stocks/trades-quotes/trades.md |
| REST quotes | `GET /v3/quotes/{stockTicker}` | same shape as trades | rest/stocks/trades-quotes/quotes.md |
| Reference exchanges | `GET /v3/reference/exchanges` | `asset_class`, `locale` | rest/stocks/market-operations/exchanges.md |

Every path above is `https://massive.com/docs/<path>` (append `.md` for the raw-markdown AI
mirror — confirmed live: "Markdown versions of every documentation page (just append .md to any
URL)", websocket/quickstart page).

**Full-market snapshot** response: `ticker`, `day`/`prevDay`/`min` (each an OHLCV object),
`lastTrade` (price/size/timestamp), `lastQuote` (bid/ask), `updated` (int timestamp),
`todaysChange`/`todaysChangePerc`, `fmv` (Business-plan only). This is the "1 call per sweep for
all tickers" the budget below assumes — pass all 872 tracked US symbols in `tickers` (case-
sensitive, comma-separated) rather than omitting the param (which would pull all 10,000+ and waste
bandwidth on names we don't track).

**Benzinga earnings** response carries `date_status: "projected" | "confirmed"` (exactly the field
repo facts named), plus `estimated_eps`/`actual_eps`, `estimated_revenue`/`actual_revenue`,
`eps_surprise_percent`/`revenue_surprise_percent`, `fiscal_period`/`fiscal_year`, `importance`.
Real-time updates; historical data from 2010-04-30. Critically, `date.gte`/`date.lte` filter
WITHOUT requiring `ticker` — one date-range call can return upcoming earnings across many
companies at once (see budget below), not one call per symbol.

**Stocks news** `results[].insights[]` carries `sentiment` + `sentiment_reasoning` PER TICKER
(a multi-ticker article can have different sentiment per company) — exactly the shape repo facts
named. Flagged as a FUTURE option for W4's retrieval-first narrator sources
(`StockSageNewsService`, currently wired to EODHD `/api/news` per the W1 follow-up notes above) —
NOT built this step, same "flagged so the next session doesn't re-research it" pattern used
elsewhere in this doc.

### WebSocket — connection, auth, subscribe, message shapes

Source: `websocket/quickstart` + `websocket/stocks/overview` (WebFetch returned only nav/headers
for these two — the docs site appears to lazy-render body content client-side for THESE pages
specifically, unlike the channel-detail `.md` pages above which returned full bodies; confirmed
full content via the browser tool's rendered DOM instead — quoted verbatim below).

Connect (one connection per asset class by default — matches repo facts' "ONE connection for the
Stocks product"):
```
wss://socket.massive.com/stocks       (real-time, Advanced plan)
wss://delayed.massive.com/stocks      (15-min delayed)
```
Server→client on connect: `[{"ev":"status","status":"connected","message":"Connected Successfully"}]`

Auth (client→server, separate message — NOT a query param like today's EODHD `?api_token=`):
```json
{"action":"auth","params":"YOUR_API_KEY"}
```
Server→client: `[{"ev":"status","status":"auth_success","message":"authenticated"}]`

Subscribe (client→server, channel-prefixed ticker, comma-joined, `*` wildcard for "every ticker"
on that channel — mixed channels in one message are fine):
```json
{"action":"subscribe","params":"T.AAPL,Q.AAPL,AM.AAPL,T.MSFT,Q.MSFT,AM.MSFT"}
```
Server bundles MULTIPLE events into one JSON-array frame during high-volume periods — e.g. two
trades in one message:
```json
[{"ev":"T","sym":"MSFT","i":"50578","x":4,"p":215.9721,"s":100,"t":1611082428813,"z":3},
 {"ev":"T","sym":"MSFT","i":"12856","x":4,"p":215.989,"s":1,"c":[37],"t":1611082428814,"z":3}]
```

Channels (`websocket/stocks/overview`, feed table) — path shown is the doc's own `WS /stocks/X`
label, not a second host:
- `/stocks/T` Trades — fields: `ev`,`sym`,`x`(exchange),`i`(trade id),`z`(tape),`p`(price),
  `s`(size),`ds`(decimal size),`c`(conditions array),`t`(SIP ts, Unix ms),`pt`(participant ts),
  `q`(sequence),`trfi`,`trft`. (websocket/stocks/trades.md)
- `/stocks/Q` Quotes (NBBO) — `ev`("Q"),`sym`,`bp`/`bs`/`bx` (bid price/size/exchange),
  `ap`/`as`/`ax` (ask price/size/exchange), `t` (SIP ts, Unix ms). Real-time only on Advanced/
  Business+Expansion. (websocket/stocks/quotes.md)
- `/stocks/A` Aggregates per-second — `ev`,`sym`,`v`/`dv`/`av`/`dav`(volume variants),
  `op`/`o`/`h`/`l`/`c`/`vw`/`a`,`s`/`e` (start/end Unix ms),`otc` (bool, present only if true).
  (websocket/stocks/aggregates-per-second.md)
- `/stocks/AM` Aggregates per-minute — same field set as `/A`, one bar per minute; subscribe
  token `AM.<ticker>`. (websocket/stocks/aggregates-per-minute.md)
- `/stocks/LULD`, `/stocks/NOI`, `/business/stocks/FMV` also exist (limit-up/limit-down, NYSE net
  order imbalance, Business-plan-only fair market value) — out of scope for this migration, not
  fetched in detail.

Timestamps are Unix (seconds-since-epoch UTC for the `t`-in-seconds convention the overview page
states, though the trade/quote/aggregate examples above show millisecond `t`/`s`/`e` — the per-
channel doc's own field table is the authority per field, not the overview's generic timestamp
note; verify the exact unit against the live payload before wiring, same "measure, don't guess"
rule as B5's EODHD cap was found under).

**vs. today's EODHD protocol** (StockSageLiveStream.swift) — this is a rewrite, not a config
change:
- Auth: EODHD embeds the key in the connection URL query string (`?api_token=`, :219); Massive
  sends a separate `{"action":"auth",...}` message after connecting and waits for `auth_success`.
- Subscribe: EODHD sends `{"action":"subscribe","symbols":"AAPL,MSFT"}` (bare tickers, one
  implicit trade channel, :229-234); Massive needs channel-prefixed tokens (`T.`/`Q.`/`AM.`) and
  can multiplex channels in one message.
- Frame shape: EODHD sends one JSON OBJECT per message (`authStatus`/`parseTick` each parse a
  single object, :268-275); Massive sends a JSON ARRAY that can bundle several events — the
  parser must iterate the array and switch on each element's `ev`.
- Connection cap: EODHD caps at `maxSubscriptionsPerConnection = 50` (:59, forcing 872÷50 ≈ 18
  chunked connections today, `StockSageLiveStreamConnection` × N, StockSageLiveStream.swift:148-
  163); Massive Advanced is unlimited-symbols/one-connection — `connections` collapses to a
  single always-one-element array, the chunking loop and `maxSubscriptionsPerConnection` delete
  outright (not a config bump — the whole reason they exist goes away).

### Symbol mapping

Tracked base universe today (post 2026-07-16 restriction, StockSageQuoteService.swift:552-556):
`StockSageUniverse.worldwide` = 872 bare US tickers (`nasdaqListed` allowlist, :443-534, counted
this session: exactly 872) passing `isAllowedUniverseSymbol` (:535-538: `.SR` suffix OR in
`nasdaqListed`) + 28 Tadawul `.SR` names + `^TASI.SR` = 901, matching the pipeline-1 doc's count
above.

- **The 872 bare US tickers already match Massive's ticker symbology 1:1** — no prefix, no
  suffix, no translation layer. `AAPL` on the board is `AAPL` to Massive's REST and WS alike.
- **Class-share tickers (BRK.B-style): verified ZERO exist in the current allowlist.** Checked
  this session: `python3` regex over the `nasdaqListed` literal block found 0 tickers containing
  a `.`; a whole-file regex for any US-looking dotted ticker (`"[A-Z]{1,5}\.[A-Z]{1,2}"` minus the
  24 known Yahoo non-US exchange suffixes actually in use: `.SR .L .DE .PA .T .HK .SS .KS .NS .TW
  .SI .AX .SA .MX .TO .SW .AS .MC .MI .ST .AE .QA .CA .JO`) also returned nothing. Every dotted
  ticker in the file is a Yahoo *non-US exchange* suffix, none of which pass `isAllowedUniverseSymbol`
  anyway (they don't end in `.SR` and aren't in `nasdaqListed`) — so they were never migration
  candidates regardless. If a class-share name is added to the allowlist later, Massive/Polygon
  uses the identical dot convention (`BRK.B`) — the same string works unchanged on both vendors,
  no mapping code needed even then.
- **Tadawul `.SR` + `^TASI.SR` (29 names) are OUT OF SCOPE for Massive.** Not verified against a
  fetched Massive doc page this step (no page was found or fetched that enumerates supported
  exchanges/markets by country), but consistent with the `/v3/reference/tickers` sample's `market`
  enum (`stocks, crypto, fx, otc, indices` — no Saudi/GCC market type) and with Massive/Polygon's
  known US-equities-plus-global-crypto/fx scope. These 29 stay on Yahoo exactly as today — never a
  migration candidate, so "nothing may silently drop a symbol" is satisfied by construction, not
  by a fallback path that has to fire.
- The broader `groups`/`catalogExtra` international literals (London, Frankfurt, Tokyo, Hong Kong,
  Shanghai, Seoul, Mumbai, Taipei, Singapore, Sydney, São Paulo, Mexico City, Toronto, Zurich,
  Amsterdam, Madrid, Milan, Stockholm, Dubai, Doha, Cairo, Johannesburg, world indices, FX pairs —
  the pre-2026-07-16 2,420-name catalog) are already filtered OUT of `worldwide`/tracked by
  `isAllowedUniverseSymbol` and stay that way; this migration doesn't touch them, doesn't revive
  them, and doesn't need to map them.

### Original proposed budget — superseded by implemented-budget notes below

Pre-migration (pipeline-3 doc, "Budget AFTER" above): EODHD REST 4×872 = 3,488/h (0 during US
close) + Yahoo chart 60×29 = 1,740/h during Tadawul's 5h window (8,700/day) + quoteSummary
≤872/24h for earnings.

Post-migration, 872 US names on Massive:
- **WebSocket**: 0 REST calls. One connection, one subscribe message, continuous push for trades
  (+quotes if bid/ask is wanted) — replaces both the EODHD REST poll AND EODHD's 18-connection WS
  chunk for these names.
- **REST snapshot reconciliation**: 1 call per sweep for all 872 tickers (the endpoint takes the
  full comma-joined list in one request regardless of count). Recommend keeping the existing
  thermal-aware streamGap cadence (`refreshIntervals`, MarketsView.swift:321-323, currently 30s
  normal / 60s thermally-stressed) as a WS-gap backstop rather than the primary live path — cost is
  no longer the constraint (Advanced = unlimited REST), so the cadence choice is about staleness-
  during-a-WS-drop, not budget. At 60s: 60 calls/hour flat, ANY tracked-symbol count (down from
  3,488/h — a ~98.3% cut) — this also folds in `prevDay` (no separate previous-close call needed
  per sweep; that endpoint is only needed for a single ad-hoc lookup outside a sweep).
- **Benzinga earnings**: today's chain does up to 872 EODHD-calendar calls/24h under a per-symbol
  TTL (A2/A4 above). Benzinga's `date.gte`/`date.lte` filters work WITHOUT a `ticker` — one call
  covering "today → +180 days" returns upcoming earnings for every company Benzinga tracks in that
  window (`limit` up to 50,000 — one page almost certainly covers 180 days), joined locally against
  the 872-symbol allowlist. **≈1 call/24h** replaces ≈872/24h.
- **Tadawul + `^TASI.SR` (29 names)**: unchanged, still Yahoo, still ~1,740/h during the 5h
  Tadawul session — Massive doesn't touch this budget line at all.

Total after migration (excluding on-demand `/v3/trades`, `/v3/quotes`, single-ticker snapshot, and
news lookups, which are drill-down calls, not swept): **~60 Massive REST calls/hour + 1 Massive
WS connection + ~1 Benzinga call/day**, vs. **~3,488 EODHD REST calls/hour** today for the same
872 names — while gaining tick-level freshness (WS) the old 30s/900s poll never had for the
streamGap remainder. Tadawul's 1,740/h Yahoo line is untouched either way.

### Cutover plan

- **M1 — Reference validation.** Pull `/v3/reference/tickers` (paginated, `limit` max 1000) and
  confirm all 872 `nasdaqListed` symbols resolve `active: true`; log the (expected: 0) misses.
  Read-only, no code change.
- **M2 — REST snapshot cutover.** New `StockSageMassiveSnapshot.swift` calling `GET
  /v2/snapshot/locale/us/markets/stocks/tickers?tickers=<872 names>` on the collapsed single
  reconciliation timer (replaces the streamGap/full split for these 872 names only); map
  `day`/`prevDay`/`lastTrade`/`updated` onto the existing `LiveQuote` shape (`marketTime` ←
  `updated`, `previousClose` ← `prevDay.c`). EODHD/Yahoo untouched for the 29 Tadawul names.
- **M3 — WebSocket cutover.** Rewrite `StockSageLiveStreamConnection` for Massive's protocol
  (auth message → wait `auth_success` → one subscribe message covering the full 872-symbol union
  → parse array-framed `T`/`Q`/`AM`/`status` events). Delete `maxSubscriptionsPerConnection` and
  the chunking loop (StockSageLiveStream.swift:59,148-163) — Advanced's unlimited-symbols/one-
  connection means `connections` is always length 1.
- **M4 — Earnings cutover.** New `StockSageBenzingaEarnings.swift` (shape of
  `StockSageEODHDCalendar.swift`) calling `GET /benzinga/v1/earnings?date.gte=...&date.lte=...`;
  wire as the FIRST closure ahead of `eodhdCalendar` in `StockSageCatalystChain.resolve`
  (StockSageCatalystChain.swift:44-51); `date_status` maps directly onto `Outcome.confirmed`
  (`"confirmed"` → `true`, `"projected"` → `false`) instead of inferring confirmation from Yahoo's
  `isEarningsDateEstimate` or EODHD's always-false-for-a-future-date rule. EODHD calendar → Yahoo →
  projection stay as the fallback chain for anything Benzinga doesn't cover.
- **M5 — Flip the default.** Once M2-M4 are gated + visually verified on `wt/coverage`, flip the
  872 US names' default quote/stream/earnings source from EODHD/Yahoo to Massive. EODHD stays
  wired (never deleted) as the fallback per repo facts; Tadawul + `^TASI.SR` remain on Yahoo
  permanently — they were never Massive candidates, not a fallback path that "kicks in."

Each of M2-M4 needs its own hand-derived fixture set (spec-fidelity: expected values come from the
sample JSON quoted above or an independent hand derivation, never from the code under test) and its
own gate + `tools/runtests.sh` pass before M5 — this section is the design brief, not the
implementation; M2-M5 are future steps, explicitly not built in this pipeline-4 step.

### Implemented earnings path — 2026-09-06 21:46 +03 (supersedes proposal budget)

The current takeover checklist uses the workflow's stage numbering: M3 is
earnings. `StockSageMassiveEarnings` now queries one due US symbol at a time,
reusing the existing per-symbol24h answer TTL and4-wide sweep. It does NOT use
the earlier all-market180-day bulk proposal, so the estimate of one Benzinga
call/day above is NOT an implemented budget. Current cost is one status-only
probe per eligible sweep plus one request per due US symbol when access remains
available. A complete answer TTL-gates that symbol for24h.401/402/403 suppress
this provider globally for24h; transient failures remain unobserved and may be
retried on a later sweep. No claim of an exact account-wide rate limit is made.

Each query is bounded to100 rows over UTC today through+400days, date ascending.
Partial or malformed payloads fall through rather than claiming completeness;
no speculative pagination/all-market cache was added. This follows the later M3
workflow's per-symbol contract and needs live measurements before optimization.
Fields and parameters verified against:
https://massive.com/docs/rest/partners/benzinga/earnings
https://raw.githubusercontent.com/massive-com/client-python/master/massive/rest/benzinga.py

Confirmation comes only from date_status (projected stays estimated); duplicate
same-day conflicts cannot upgrade it. Actual EPS/importance are not evidence of
date confirmation. The visible source comes from the chain record. Future time
within a calendar day is not asserted; time is deliberately unused. No live
entitlement claim: the credential guard blocked the agent's presence check and
was not bypassed. Canonical macOS1681/iPhone1680 selected tests passed; HANDOFF
records exact result bundles and remaining full UI/live checks.

### M4 implementation and news budget correction —22:27 +03

The earlier "future option" news section is now implemented through the existing
on-tap Explain source flow. Massive `/v2/reference/news` uses ticker,
published_utc.gte/lte, descending publication time and limit5. Its feed updates
hourly; it is not labelled live. One request per Explain, not five requests per
symbol. At most one existing EODHD news fallback request when no usable Massive
items remain (existing budget10 EODHD API credits). No polling or pagination.
Five articles and a seven-day window are a bounded selection, not completeness.

Provider/publisher attribution and only the requested ticker's optional sentiment
travel together through the numbered source into both model backends and the UI.
The sentiment is source commentary, not an app trading signal; unchanged numeric
and citation-index fences do not prove semantic truth. The viewer can inspect the
actual bounded excerpts/reasoning and UTC dates even when narration is withheld.
Shared parsers reject future articles and unsafe/oversized links, constrain all
supplied text at whole-word boundaries, and omit conflicting/malformed insights.
Missing or denied feeds remain unavailable, not an invented no-news observation.

### M5 actual routing/provenance and implemented budget —2026-09-06

The takeover M5 is source attribution/configuration, not the differently numbered
old cutover proposal. Massive→Yahoo routing is already active. No EODHD quote
picker is restored; EODHD calendar/news fallbacks still exist. The shared macOS/iOS
settings field describes the actual routing and warns that the connection test
only probes snapshots, not every purchased add-on. No new purchases or credential
storage/access changes. No live account entitlement has been verified.

Price-source metadata is attached by the parser/stream that supplied that price:
Massive SIP, Massive daily bars, Yahoo, Yahoo bars, or the dormant EODHD parser.
Samples are explicit. Metadata travels with price/time/sequence through accepted
updates, scan publication and both caches; missing old-cache metadata is unknown,
never inferred from key presence. It does not certify freshness or execution venue.
The header/banner date one accepted observation, not the entire tracked universe.

These are code-derived request budgets, NOT measured account usage. Work time,
closed sessions, caches, failures, missed stream coverage and owner activity change
the actual rate. The earlier flat60/h, one872-ticker request, oneearnings/day and
fixed1,740/h Saudi figures do not describe this implementation:

| Path | Implemented bound / cadence |
| --- | --- |
| Quotes for a requested set | With a key: ceil(covered US /250) snapshot calls, then one Yahoo chart lookup for each unsupported or missing ticker.872 US names need4 chunks, not1. Yahoo permits up to3 HTTP attempts on429/503; Massive snapshots have no retry loop. |
| Stream gap | Only trading symbols without recent authenticated trade coverage; rotating cap20, foreground sleep30s (60s thermal), shared25s sweep-start floor with monitor. At most one snapshot chunk per gap sweep, plus≤20 Yahoo lookups if all fall back. Ideal foreground rate≤120 sweeps/hour; the shared floor bounds combined callers to≤144 starts/hour (steady-state), not a promise of refreshing every name every30s. |
| Full board | Foreground sleep900s (1800s thermal), plus explicit launch/manual refreshes. An unchanged901-name curated set is872 US +29 Saudi/index:4 snapshots +29 Yahoo lookups per successful full sweep, before failures/healing/FX/user holdings. Four such sweeps/hour means16 snapshots +116 Yahoo lookups, NOT the whole app's total. |
| Monitor | Separate180s sleep (360s thermal), plus cycle work. Core/watchlist/holdings requests and armed price-alert lookups remain; they are not eliminated by WebSockets. Stream-gap calls share the25s floor, but normal core refreshes do not. |
| Heal / infrastructure | Full/core refresh may retry≤40 stale, open-venue candidates, with existing no-advance backoff; SAR conversion is another single-symbol Yahoo request per refresh. Both are additional to the table's base sweep counts. |
| History / scans | One request per missing eligible US daily history to Massive; unsupported/failed histories fall back to one Yahoo lookup (up to3 attempts). Cache/chunk reuse remains. Non-daily intervals use Yahoo. This is not a single batched history request. |
| Stream / references | One Stocks socket, authenticated T+Q subscription; event traffic has no fixed hourly count. Quote-condition reference once per stream start, exchange reference cached24h in process. No second Stocks socket added. |
| Earnings / news / tape | Use the implemented M3/M4 and takeover M2b budgets: per-due-symbol earnings with24h answer TTL, on-tap≤5 news articles, on-tap≤3×100 pages per tape channel. No new M5 network calls. |

The20-name gap cap is retained to protect the existing Yahoo fallback. In a
complete872-name US stream outage, a single rotating gap pass needs44 sweeps:
about22min at ideal30s cadence, plus work time (full/core sweeps may update names
sooner). This is a known freshness ceiling, not "all names live every30s".
Changing that cap requires a separately tested fallback/load policy, not merely
an assumption that a paid Massive plan removes Yahoo's throttling.

Source anchors: StockSageMassive.maxTickersPerRequest/fetchSnapshots,
StockSageQuoteService.fetchQuotes/get/fetchHistory,
StockSageStore.refreshStreamGap/healStaleQuotes/refreshInfraFX,
MarketsView.refreshIntervals and StockSageMonitor.start/runCycle.

Contract verified from https://massive.com/docs/rest/stocks/news and the official
https://raw.githubusercontent.com/massive-com/client-python/master/massive/rest/reference.py
(`list_ticker_news`). Final selected gates:1693 macOS,1691 iPhone, all passing;
HANDOFF contains exact bundles, the initial red defects, the fixture compile
correction, and conditional live/full-UI limitations. No authenticated request
was made while the active credential guard continued denying the check.
