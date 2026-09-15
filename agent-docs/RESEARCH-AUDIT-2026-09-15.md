# StockSage — research-pipeline audit, 2026-09-15

Produced by a Claude Code session for **Codex** to act on. Self-contained: every finding
carries its own `file:line` and quoted evidence, so nothing here needs the originating
conversation.

Companion doc (different subject, still current): `HANDOFF-CODEX-2026-09-12.md`.

## Read this before acting

These are the constraints an agent without context walks into. They are not style preferences.

1. **EODHD is removed** (owner, 2026-09-06: "i dont use eodhd anymore"). Massive is the US
   provider. EODHD paths fail closed and must never be proposed or restored as a live fallback.
2. **The honesty floor.** An unknown is never a finding. "We could not check" must never render
   as "we checked and found nothing." Never print a number the input cannot support. The audit
   below confirms this floor currently HOLDS across the research subsystem — the open problems
   are coverage and cost, not dishonesty. Do not regress it while fixing them.
3. **The engine has no proven edge** (measured Deflated Sharpe ≈ 0). Its present value is risk
   discipline. Nothing may be built that implies a forecast is reliable.
4. **25 critique findings already landed** on `claude/model-harness-2026-09-10` (commits
   `659a80b`..`0453c31`). Do not re-derive or re-fix those. See the companion handoff.
5. **Refuted items are listed with their reasons.** They were checked and killed. Re-proposing
   one without new evidence wastes a cycle.

## How this was produced

Six independent audits, one per dimension, each then **adversarially reviewed against the real
code** by a separate agent whose instruction was to refute. Counts:

| Dimension | Findings | Survived | Refuted |
|---|---:|---:|---:|
| Evidence coverage for US / NASDAQ names | 9 | 8 | 2 |
| Universe and selection | 7 | 6 | 1 |
| Model grounding | 5 | 4 | 1 |
| Horizon fitness (1–7 vs 7–14 trading days) | 6 | 5 | 1 |
| Output honesty and usefulness | 6 | 5 | 1 |
| Cost, latency and caching | 9 | 6 | 3 |
| **Total** | **42** | **34** | **9** |

Findings are the auditors' work, verified but **not implemented**. Effort figures are estimates
and were challenged by the reviewer; treat them as order-of-magnitude.

---

## The highest-impact items, across all dimensions

Each dimension's reviewer named its top three. Listed here so a reader can pick without
reading everything.

**Evidence coverage for US / NASDAQ names**

1. No forward earnings date reaches a US research idea — the one fact a 1–7 day hold most needs
2. The scan measures dollar volume and 30+ bars of volume, then hands the model no tradability fact at all
3. Evidence depth silently depends on whether the name happens to be on the owner's board — and the ranking never says so

**Universe and selection**

1. The research universe ignores the owner's NASDAQ-only directive that the ideas universe enforces
2. No instrument-type filter: ETFs consume research slots and can head the top-5 Buy list
3. The owner is never told what fraction of the eligible universe was researched, or where the activity cut line fell

**Model grounding**

1. The "not eligible at capture" reason names a 7-day ratings window that the ratings evidence path stopped using, and blames recency for rows the parser simply could not read
2. The 12,000-byte evidence cap is hardcoded ~1.4 kB below what the model window actually holds, and it is the Benzinga block that pays for the gap
3. The narrator is the last consumer still on the legacy four-bucket error map, so a model timeout reads "Could not reach the local server"

**Horizon fitness (1–7 vs 7–14 trading days)**

1. The two horizons receive byte-identical evidence — ship option (b), the ~5-line caption under the horizon picker (StockSageResearchModesPanel.swift:87–91), then treat option (a) as the roadmap
2. Both horizons are measured endpoint-to-endpoint — store the day-7 close and the max-favorable/max-adverse close from bars fetchReviewObservation already downloads (StockSageHorizonResearch.swift:149–175, StockSageResearchHistory.swift:391)
3. The time stop counts calendar days against an anchor the rest of the engine already treats as trading days (StockSageTimeStop.swift:24 vs StockSageExpectedValue.swift:1071/1127)

**Output honesty and usefulness**

1. The saved-research scoreboard grades every pick against zero, never against the market
2. insiderRow() has no else: a failed — or deliberately withheld — insider check renders as nothing at all
3. The Benzinga panel shows the model the eligibility split and shows the owner the collapsed number

**Cost, latency and caching**

1. Account-level Benzinga entitlement denials are re-learned once per symbol, up to ~2,000 guaranteed-failing paid calls per run
2. One 429 buys up to ~20 full-price Qwen calls on evidence-free names that are then marked "checked"
3. Running both horizons duplicates an entire evidence pass that is not horizon-dependent

---

## Evidence coverage for US / NASDAQ names

Traced one US listing end to end through `StockSageHorizonResearch.analyze` (the only path that produces a US research verdict). What actually fires per symbol: (1) Massive `/v3/reference/tickers` + `/v2/aggs/grouped/.../{session}` once per scan to pick the top 500 by dollar volume; (2) Massive `/v2/aggs/ticker/{sym}/range/1/day` 1y, gated to completed prior sessions; (3) a Benzinga snapshot of SEVEN products (earnings, guidance, ratings, analyst-insights, bulls-bears-say, news, consensus-ratings) plus up to 6 analyst/firm metadata pages; (4) news via the Benzinga news page with a Massive `/v2/reference/news` fallback. That is ~8–14 HTTP calls per symbol, ~4,000–7,000 per full 500-name scan. What does NOT fire, for any name the owner does not already track: the forward earnings-date query, SEC 8-K, Form 4 insider, and dividends. Those four come from `store.catalystChain` / `store.companyEventChecks`, which are populated only over `trackedSymbolsUnion` — and `refreshCompanyEvents` actively evicts every non-tracked key. So for the typical scanned NASDAQ name the fact set prints "Earnings: not checked", "Massive/SEC 8-K: not checked", "Massive/SEC Form 4: not checked", "Full filings were not retrieved" — and still ships a Strong Buy. The honesty floor holds throughout (every gap says "not checked", "bad query" or "unsupported" rather than "none found"); the defect is coverage, not dishonesty. The sharpest problem for the stated 1–7 and 7–14 trading-day horizons: every piece of evidence that reaches the model is BACKWARD-looking. There is no forward calendar at all — no next earnings date, no ex-dividend date — even though the horizon instruction explicitly tells the model to "Consider overnight gaps and missing future catalysts", and even though a correct forward-earnings query already exists in the codebase and is one request per symbol.

### Already good — do not "fix" these

- The honesty floor genuinely holds across this whole subsystem. Every missing feed renders as an explicit negative: `StockSageAIAssessment.swift:66` "Earnings: not checked; date and outcome unknown.", `StockSageMassiveEvents.statusLine` distinguishes "not checked" / "stale check; current coverage unknown" / "unavailable at <date>, not an empty result" / "no qualifying event in the queried N-day window", and `StockSageAIAssessment.swift:86` states plainly "Full filings were not retrieved. Absent evidence is not evidence of absence." I could not find a single place where an unchecked feed renders as a clean negative finding.
- The `notEligibleCount` split added 2026-09-11 (`StockSageBenzinga.swift:206-221`) is exactly right and load-bearing: it keeps "no recent analyst action" distinguishable from "we could not fit it", and separates the per-product cap from byte-budget trimming. The `Projection.text` footer reports all three buckets numerically.
- Review-window arithmetic is trading-day correct, not calendar-day approximated. `StockSageResearchHistory.targetClose(after:horizon:)` walks the verified Nasdaq calendar counting regular-session closes strictly after completion, `benchmarkDay(after:)` takes the next trading day's OPEN as baseline, and `reviewAvailableAt` waits for the entire target New York date to end before accepting the daily aggregate. Horizon = 7 and 14 trading days exactly.
- The credential-generation epoch on every Benzinga page and snapshot (`credentialGeneration`, `isCurrent`, `receiptFailure`) means evidence captured under one key can never be silently reused after a key or policy change — it degrades to `.obsoleteCredential` rather than to a stale answer.
- `completedHistory` (`StockSageHorizonResearch.swift:206-225`) is strict in the right way: prior New York dates only, ≥30 bars, monotonic dates, OHLC internal consistency, and `isLatestCompletedDailyBar` against a verified calendar. Today's partial candle can never become a reference close.
- The ratings evidence window was widened from the 7-day CATALYST window to 45 days with a documented, measured rationale (the owner's own RKLB capture at 31 days) — `StockSageBenzinga.swift:276-288`. That is the right instinct: a catalyst window and an evidence window are different things.
- News degrades correctly. When the Benzinga news page is entitlement-blocked or empty, `StockSageNewsService.observe` falls through to Massive `/v2/reference/news` and records BOTH attempts with their own status and timestamps in `Observation.summary`.

### Verified findings

#### No forward earnings date reaches a US research idea — the one fact a 1–7 day hold most needs

- **Where:** `StockSage/Sources/StockSage/StockSageHorizonResearch.swift:402`
- **Confidence:** high  ·  **Est. effort:** ~20 lines
- **Owner impact:** `catalystChain` is written only by `refreshCatalyst`, which runs over `trackedSymbolsUnion` or when a detail sheet opens (StockSageStore.swift:2487-2501, MarketsView.swift:9464). `companyEventChecks` is worse — `refreshCompanyEvents` at StockSageStore.swift:2275 does `companyEventChecks = companyEventChecks.filter { allowed.contains($0.key) }`, actively evicting every non-tracked symbol. The research scan picks its 500 names by dollar volume and never touches the tracked set, so for the typical scanned NASDAQ name this subscript is nil and the model is told "Earnings: not checked; date and outcome unknown." The owner then reads a Strong Buy for a 1–7 trading-day hold on a name that may report in three sessions, and nothing on the Top Buys row says the calendar was never consulted. The app already has the correct query: `StockSageMassiveEarnings.request` sends `date.gte=today&date.lte=+400d&sort=date.asc`, and `parseNext` returns the earliest confirmed/projected date — one request, and the scan already fires eight to fourteen per symbol.

**Evidence**

```swift
let context = StockSageAIAssessment.Context(idea: idea, earnings: store.catalystChain[item.ticker],
    company: store.companyEventChecks[item.ticker] ?? [:], at: Date(), newsObservation: news, quotedInUSD: true, benzinga: benzinga)
```

**Proposal**

In `analyze`, when `store.catalystChain[item.ticker]` is nil, call `StockSageMassiveEarnings.fetch(item.ticker, now:)` behind the same `evidenceAllowed()` gate as the Benzinga fetch, and pass the resulting Row into the Context as a `StockSageCatalystRecordCache.Record` (the conversion already exists in `StockSageCatalystChain`). Keep the existing 24h `gateKey` denial cache so a 402 skips the rest of the scan. Do not write it into the store — research must stay side-effect-free.

#### The paid Benzinga Earnings call in the scan asks "what was recently revised", not "when is the next report"

- **Where:** `StockSage/Sources/StockSage/StockSageBenzingaClient.swift:428`
- **Confidence:** high  ·  **Est. effort:** ~12 lines
- **Owner impact:** Only `.news` gets date bounds. The earnings query therefore goes out with no `date.gte`, `sort=last_updated.desc` (StockSageBenzinga.swift:54, the `default` arm) and `limit=20`; `Snapshot.init` then keeps `page.records.prefix(3)` — the three most-recently-REVISED earnings rows. A future schedule row does survive the parse (StockSageBenzinga.swift:472 exempts `.earnings` from the `parsed <= checkedAt` guard), but whether it lands in the top three is an artifact of vendor revision ordering, not of the horizon. For a name that just reported and had two quarters restated, the upcoming date is pushed out entirely. So the owner pays for the Earnings add-on 500 times per scan and the answer that arrives is not the one the horizon needs. This is independent of finding #1: even with the store lookup fixed, this request stays mis-shaped.

**Evidence**

```swift
let baseQueries = B.Product.allCases.filter { $0 != .analysts && $0 != .firms }.map { product in
    B.Query(product: product, subject: symbol,
            from: product == .news && bounds.timeIntervalSince1970.isFinite ? bounds.addingTimeInterval(-7 * 86_400).formatted(formatter) : nil,
            through: product == .news && bounds.timeIntervalSince1970.isFinite ? bounds.formatted(formatter) : nil)
```

**Proposal**

Give `.earnings` its own bounds in the same map — `from: bounds` day-string, `through: bounds + ~45 days` — and override its sort to `date.asc` in `Product.sort`. That turns three wasted rows into the next three scheduled releases, at zero extra requests. Guard it so the Chat/board callers that want reported actuals still get the un-windowed shape (add a `Query` flag or a second product case rather than flipping the shared one).

#### Evidence depth silently depends on whether the name happens to be on the owner's board — and the ranking never says so

- **Where:** `StockSage/Sources/Views/StockSageResearchModesPanel.swift:252`
- **Confidence:** high  ·  **Est. effort:** ~35 lines
- **Owner impact:** Because earnings, 8-K, Form 4 and dividends come from the tracked-symbol store, two names sitting side by side in the same Top Buys list can carry completely different evidence: a board name gets earnings + 8-K + insider + dividends + seven Benzinga products; a non-board name gets price history + Benzinga + news and four lines of "not checked". Nothing distinguishes them. `Scan.topBuys` (StockSageHorizonResearch.swift:66-70) ranks purely on `verdict.action` with activity-order ties, so a technicals-only Strong Buy outranks a fully-evidenced Buy. The coverage is visible only by opening the row and expanding the collapsed "Evidence captured" DisclosureGroup (panel line 553) and reading the status lines one by one. The owner's own ranking note (`topBuyRankingNote`) says nothing about evidence depth.

**Evidence**

```swift
Table(rows, selection: $presentation.selected) {
    TableColumn("Stock") { ... }
    TableColumn("Opinion") { ... }
    TableColumn("Daily close") { ... }
```

**Proposal**

`Result` already carries `facts: [String]`. Compute a small coverage tuple at the end of `analyze` — checked/unchecked counts over the feed status lines and the Benzinga product lines — store it on `Result`, render it as a fourth table column ("Evidence 9/13") and as a line in `topBuyRankingNote`. Do not reorder Top Buys on it; just make the difference visible.

#### Dual-class and digit-bearing US tickers get zero news and zero Benzinga evidence, and still produce a verdict

- **Where:** `StockSage/Sources/StockSage/StockSageMassive.swift:91`
- **Confidence:** high  ·  **Est. effort:** ~15 lines
- **Owner impact:** The scan's own admission filter is `StockSageHorizonResearch.validTicker`, `^[A-Z][A-Z0-9.-]{0,31}$` (HorizonResearch.swift:107) — dots, dashes and digits all pass, and the universe selector only checks that. So a high-dollar-volume dual-class listing (BRK.B and friends) enters the top 500. But `StockSageBenzinga.valid(query)` requires `StockSageMassive.covers(subject)` AND all-uppercase-letters, so `B.request` returns nil and all seven products come back `.unavailable(.invalidQuery)`; the projection prints "Earnings: bad query / Ratings: bad query / News: bad query …". `StockSageNewsService.observe` guards on the same `covers`, so news is `.notChecked(.unsupported)` and the Massive generic fallback never even runs. The verdict still ships: `canAssess` passes because an all-unavailable snapshot still yields a non-nil zero-record projection. The owner reads a normal Strong Buy backed by four technical facts, with the reason hidden behind "bad query" — which reads as a bug, not as "this share class is unsupported".

**Evidence**

```swift
nonisolated static func covers(_ symbol: String) -> Bool {
    let ticker = symbol.uppercased()
    return !ticker.isEmpty && !ticker.contains(".") && !ticker.contains("=") &&
        !ticker.contains("-") && !ticker.hasPrefix("^") && ticker.allSatisfy(\.isLetter)
}
```

**Proposal**

Two honest options, and I'd take the first: normalize the symbol for the vendor (dot→dash or dash→dot per the Massive/Benzinga contract, verified against the docs, not guessed) so these names actually get evidence. If the vendor genuinely does not cover them, then refuse an opinion in `analyze` the way the non-USD guard already does — `return .init(note: "Share class not covered by the news and analyst feeds; listing retained, no opinion.")` — rather than emitting a technicals-only verdict that looks like every other one.

#### SEC EDGAR is free, already implemented, and never becomes evidence — while the fact set says filings were not retrieved

- **Where:** `StockSage/Sources/Views/IdeaDetailEvidence.swift:45`
- **Confidence:** high  ·  **Est. effort:** ~30 lines
- **Owner impact:** `StockSageDisclosureService` is keyless, free, and documented as authoritative (it reads `data.sec.gov/submissions/CIK.json` directly). Its only three call sites are `IdeaDetailEvidence.swift:45`, `CatalystsSection.swift:887` and `:953` — all view-layer. No model assessment on any path consumes it, so `StockSageAIAssessment.swift:86` prints "Full filings were not retrieved" for every US idea while the app is one tap away from the filing. Separately, all three call sites hardcode `forms: ["8-K"]`, so the forms that actually kill a 1–7 day US trade — a 424B5 shelf takedown, an S-3, an ATM prospectus supplement — are outside the query entirely, and the `caveat` at DisclosureService.swift:305 correctly says an empty result never means nothing was filed. So the owner is honestly told nothing, about the thing most likely to gap the position.

**Evidence**

```swift
fetchFilings: @escaping FilingsFetch = {
    await StockSageDisclosureService.recentFilings(for: $0, forms: ["8-K"], limit: 5)
},
```

**Proposal**

Two independent changes. (a) In `analyze`, after the Benzinga fetch and behind `evidenceAllowed()`, call `StockSageDisclosureService.recentFilings(for: item.ticker, limit: 5)` and append the dated filings plus `StockSageDisclosureService.caveat` as optional facts — it is keyless, so it costs nothing but latency, and the existing `fittedResearchPrompt` budget already drops optional facts honestly. (b) Widen the default `forms` set to include the offering forms (`424B5`, `S-3`, `S-1`, `8-K`) at all three call sites, and label them distinctly in the fact text. Each is independently shippable.

#### The scan measures dollar volume and 30+ bars of volume, then hands the model no tradability fact at all

- **Where:** `StockSage/Sources/StockSage/StockSageHorizonResearch.swift:259`
- **Confidence:** high  ·  **Est. effort:** ~15 lines
- **Owner impact:** `StockSageResearchUniverse.Receipt` carries `dollarVolume[symbol]` and a ready-made sentence, `detail(for:)` → "Selection activity: $X traded (volume × VWAP) · <session> ET. Not a Buy signal." It goes to `scans[horizon]?.selection` for a tooltip and is never passed to `analyze`, so the model never sees it. `StockSageLiquidity.profile(closes:volumes:)` is a pure function over exactly what `analyze` already holds (`history.closes`, `history.volumes`, ≥30 validated bars) and yields a tier plus the thin-liquidity slippage note — and `Context.facts` has no liquidity line on ANY path, board or research. For a 1–7 trading-day US trade at retail size, whether the name trades $800k/day or $80m/day is the difference between an executable idea and one the owner cannot exit inside the horizon, and the engine's own stated present value is risk discipline.

**Evidence**

```swift
scans[horizon]?.listings = names
scans[horizon]?.selection = selection.receipt
// One manual worker bounds local-model load. No automatic repeat or parallel model requests.
for item in names {
    ...
    let result = await analyze(item)
```

**Proposal**

Pass `selection.receipt` through `start(...)` into the `analyze` closure and append `receipt.detail(for: item.ticker)` plus `StockSageLiquidity.profile(closes: history.closes, volumes: history.volumes)?.note` to `horizonFacts` (mandatory) or to the optional facts. Both strings already exist and already carry their own "not a Buy signal" / "backtest fills assume you didn't move the market" caveats. No new network.

#### The horizon prompt demands overnight-gap reasoning from a fact set that contains no gap data — while `opens` is fetched and discarded

- **Where:** `StockSage/Sources/StockSage/StockSageHorizonResearch.swift:21`
- **Confidence:** high  ·  **Est. effort:** ~25 lines
- **Owner impact:** The instruction names two things the evidence cannot support. "Missing future catalysts" is finding #1. "Overnight gaps" is this one: `history.opens` is fetched, length-checked and OHLC-validated in `completedHistory` (lines 209, 216, 218, 222) and then read by nothing — `levels()` uses only highs/lows/closes for ATR, and `StockSageAdvisor.advise` has no `opens` parameter at all. The only horizon-specific facts are the 7-bar and 14-bar close-to-close returns at lines 405-409, which are identical for both horizons, so the 1–7 day and 7–14 day scans see a byte-identical evidence set. Asked to reason about gaps with no gap evidence, the model can only produce boilerplate — which then reads to the owner as a considered risk assessment.

**Evidence**

```swift
with: "Assess the supplied stock for a \(rawValue) holding horizon, research only. These are trading days, not calendar days. Consider overnight gaps and missing future catalysts. The daily technical rules are background, not independently validated for this horizon.")
```

**Proposal**

Append one mandatory horizon fact derived from data already in hand: the count and largest magnitude of overnight gaps (open[i] vs close[i-1]) over the last ~60 completed bars, phrased as a dated historical observation with the existing "historical, not an expected return" framing. Do NOT wire `StockSageGapRisk` — it requires shares and account equity, and research is deliberately position-free. Around 12 lines in `analyze` plus a small pure helper and its test.

#### A code comment states the ratings evidence window is 30 days; the constant it describes is 45

- **Where:** `StockSage/Sources/StockSage/StockSageBenzinga.swift:534`
- **Confidence:** high  ·  **Est. effort:** ~1 lines
- **Owner impact:** `ratingsEvidenceDays = 45` at line 288, with a carefully argued rationale (the owner's RKLB capture had its freshest action 31 days old, which a 30-day window would have missed by one day — the exact failure the widening exists to fix). The comment at the call site still says 30. Anyone reading the parse path — or auditing whether a six-week-old analyst opinion should be in a 1–7 day evidence set — gets the wrong number from the comment nearest the code. Low blast radius, but in a codebase whose stated priority is that stated numbers match measured ones, a comment that contradicts its own constant is the kind of drift that later gets cited as fact.

**Evidence**

```swift
// Ratings evidence therefore looks back 30 days and keeps
```

**Proposal**

Change 30 to 45 in the comment at line 534, or better, interpolate `\(StockSageBenzinga.ratingsEvidenceDays)` so the two cannot drift again. One line.

### Refuted — checked and killed, with the reason

#### ~~About 2,000 requests per scan go to Benzinga products the owner does not own, with no per-product denial gate~~

The mechanics quoted are real (StockSageBenzingaClient.swift:166-171 caches the denial under `.page(query)`, which carries `query.subject`, so a 402 on one symbol does nothing for the next; cacheTTL is 300s / 30s for news; drain() caps at 3), but the two claims that give it owner impact do not survive. (1) WHICH products 402 is taken from the brief, not from any response or any code path — nothing in the repo records an entitlement result per product, and the news product in particular is wired as the PRIMARY news source with a Massive fallback (StockSageNewsService.observe → /v2/reference/news), which would be a strange shape for a product that always 402s. The "~2,000 known-failing round trips" number therefore cannot be supported by the input, which is exactly the standard this codebase holds. (2) The stated consequence — "which is also why a 500-name scan realistically never finishes and the owner sees Top Buys drawn from whatever prefix completed" — is contradicted by the code: `start(...)` at StockSageHorizonResearch.swift:262-270 walks names in ONE serial loop with one local-model request per name (`researchOutputTokens = 192`, line 12, and the comment at 262: "One manual worker bounds local-model load"). Scan duration is set by the serial local Qwen calls; a 402 returns fast and never holds a slot for the 12s deadline. What remains is a real but owner-invisible cost optimization with an unmeasured denominator — it changes no line the owner reads (the status lines keep saying "entitlement", as the finding itself says) and does not make 1–7 / 7–14 day research better. It should be measured (log one scan's per-product status counts) before it is built, not shipped on a number read from a brief.

#### ~~SEC EDGAR finding, part (b): widen the default `forms` set at all three call sites~~

Part (a) survives and is kept above; part (b) does not, as scoped. The forms set is not the only thing that says "8-K": `StockSageDisclosureService.caveat` is hardcoded "SEC 8-K filings — the moment news became public…" and MarketsView.swift:6708 renders `Text("8-K filed…")` for whatever filing comes back. Adding 424B5 / S-3 / S-1 to `forms` at those call sites would print a shelf takedown as "8-K filed" under an 8-K caveat — a mislabeled record, which is the honesty-floor failure mode this repo cares about most, not a widening. CatalystsSection.swift:953 also asks with `limit: 1` for a CATALYST, where an offering form is a different event class. Doing this honestly needs per-form labels, a per-form caveat, and a decision about what belongs in Catalysts — well past the 30 lines quoted for (a)+(b) together.

### Reviewer notes

VERIFICATION METHOD: opened every cited file; every quoted line below was read, not inferred.

WHAT I CONFIRMED VERBATIM
- HorizonResearch.swift:402-403 — Context takes `store.catalystChain[item.ticker]` and `store.companyEventChecks[item.ticker] ?? [:]`, exactly as quoted.
- StockSageStore.swift:2273-2275 — `let symbols = trackedSymbolsUnion.filter(StockSageMassive.covers)` then `companyEventChecks = companyEventChecks.filter { allowed.contains($0.key) }`. Eviction of non-tracked keys is real. `refreshCatalyst` (2382-2397) is driven by `refreshEarningsForTracked` over `trackedSymbolsUnion`. `analyze` never touches the tracked set, so for a scanned non-board name both subscripts are nil.
- AIAssessment.swift:65-66 `else { result.append("Earnings: not checked; date and outcome unknown.") }`; :86 "Full filings were not retrieved. Absent evidence is not evidence of absence."; MassiveEvents.statusLine:102-113 gives the four distinct states claimed. The honesty floor does hold throughout this subsystem — the "already good" list is accurate, and I could not find a counterexample either.
- MassiveEarnings.request:34-35 — `date.gte`=today, `date.lte`=today+400d, `sort=date.asc`; `parseNext` returns the earliest in-window row; `gateKey` 24h denial gate exists. The correct forward query does exist and is one request.
- BenzingaClient.swift:428-431 — only `.news` receives from/through; Benzinga.swift:46-54 puts `.earnings` in `default: "last_updated.desc"`; Snapshot.init:160 `prefix(max(0, 3 - counts[...]))`; parseRecord:472 `product == .earnings || parsed <= checkedAt`. All four quoted mechanics are real.
- Massive.covers:91-95 and Benzinga.valid:368-369 and NewsService:161 — a dotted/dashed/digit ticker passes `validTicker` (HorizonResearch:107) and the universe selector (ResearchUniverse.select:105) but fails every evidence path. `canAssess` (AIAssessment:99-103) only needs `projection(..., maximumRecords: 0) != nil`, which an all-unavailable snapshot still satisfies — so the verdict does ship.
- Liquidity.swift:58 `profile(closes:volumes:window:)` is pure; `LiquidityProfile.note` carries its own slippage caveat. ResearchUniverse Receipt.detail(for:) carries "Not a Buy signal." No liquidity line exists in `Context.facts` on any path (grepped).
- `opens` in the research path is read only by `completedHistory`'s OHLC validation (lines 208-222); `levels()` uses highs/lows/closes; no overnight-gap statistic exists anywhere in Sources.
- Benzinga.swift:288 `ratingsEvidenceDays = 45` vs :534 comment "looks back 30 days". Confirmed drift.

CORRECTIONS THE IMPLEMENTER MUST CARRY (kept findings, but not as written)
1. Forward earnings (#1): `analyze`'s doc comment (lines 350-356) is a documented contract — "All FOUR are required for an offline test… Measured 2026-09-10: it did — seven Benzinga pages came back 'answered'." `StockSageMassiveEarnings.fetch` reads the real ToolPolicy and real credentials, so it MUST arrive through a fifth injected closure or the existing offline tests start issuing real paid requests. Also, `StockSageCatalystChain` exposes `Outcome`, not a `Record`; the Outcome→Record conversion lives in the store's `publishCatalyst`, so "the conversion already exists" is half true — a small pure converter is needed. Realistic size ~40-60 lines with its test, not 20. Within tolerance, but do not quote 20.
2. Benzinga earnings window (#2): the diagnosis is correct; the proposal is not safe as scoped. `snapshot(for:)` has SIX callers (CatalystsSection:952, MarketsView:269, ChatSection:600, AIAssessment:504, PaperAutomation:829, HorizonResearch:384). Windowing `.earnings` in that shared map deletes every "Reported earnings" row — actual EPS, revenue, surprise (parseRecord:493-527) — from Chat, the idea detail sheet, paper automation and board assessments. The window must be opt-in per call (a parameter on `snapshot(for:)`), and then the `Product.sort` flip is UNNECESSARY: with `date.gte`=today every row returned is already a future schedule row whatever the sort, so `prefix(3)` is safe. `valid(query)` (368-378) already accepts day-string bounds for non-news products and Benzinga tests already exercise `.earnings` with date bounds (StockSageBenzingaTests.swift:105-108), so no pinned test blocks it. With the sort-flip struck, ~12 lines is fair. But this is largely subsumed by #1, which is cheaper and better-shaped; do #1 first and re-evaluate.
3. Evidence depth (#3): the panel has TWO renderers — the macOS `Table` at line 252 and `phoneResults` at ~578 — so a fourth column must land in both or the iPhone keeps the old blindness. Also `coverageDetails` (220-248) is the existing disclosure block and says nothing about per-name evidence depth, so the finding did not miss it. Label the count as checks attempted, never as a quality score. Realistic ~60-80 lines.
5. Dual-class (#5): option (a) is a vendor-contract change and must be read from the Massive/Benzinga docs, not guessed — the finding says so, which is the right instinct. Option (b) is ~3 lines and mirrors the existing non-USD refusal at HorizonResearch:361-363; it is the honest default until the contract is captured. Impact is bounded to the handful of dot/dash/digit symbols that make the top 500 by dollar volume, so rank it below #1/#7/#3.
6. SEC filings (#6a): the proposal names `StockSageDisclosureService.recentFilings`, which returns `[]` for policy denial, no CIK, unreachable and invalid payload alike — indistinguishable from "nothing filed". That is precisely the defect commit 91599ce ("Stop a failed SEC fetch printing as 'we checked, nothing was filed'") exists to prevent, and the repo already ships the right API: `recentFilingsObservation` (line ~277) with its `.answered` / `.unavailable(Failure)` split and per-failure `message`. Use the Observation variant and render the failure as a failed check. With that correction #6a is a strong candidate — it would be fourth on my list, just behind #3.
8. Overnight gaps (#8): "the 1–7 day and 7–14 day scans see a byte-identical evidence set" is overstated — `horizonFacts[0]` embeds `horizon.rawValue` and the system instruction differs per horizon (lines 19-22, 404). The substantive claim stands: the EVIDENCE is identical and contains no gap data while the instruction demands gap reasoning. Note `levels()`'s basis string already ends "overnight gaps can pass the stop", so the caveat exists and only the data is missing.

ORDERING RATIONALE
#1 first because it is the only proposal that adds a forward-looking fact to a horizon defined by forward days, at one request per symbol against a scan that already fires 8-14. #7 second because it costs no network at all, both strings already exist with their own caveats, the capture pattern it needs is already used in the same function (`var isOllama`), and it speaks to the engine's one real present value — risk discipline; whether a name trades $800k or $80m a day decides whether a 7-day idea is exitable. #3 third because it stops an evidence-thin Strong Buy from rendering identically to a fully evidenced one on the row the owner actually reads, and it changes no ranking (correctly — reordering on coverage would imply a reliability the engine does not have). #9 is a one-line true fix; land it with whatever else touches that file, but it is not worth a wave of its own.

---

## Universe and selection

Selection itself is sound in shape: `StockSageResearchUniverse.select` ranks the whole US tape by observed dated dollar volume (volume × VWAP) and takes the top 500 — not alphabetical, not cap-ordered, not a stale hardcoded watchlist, and the code comments actively forbid re-sorting alphabetically. The disclosure copy around it is some of the most honest in the codebase. The problems are elsewhere. First, this universe silently ignores the owner's own 2026-07-16 "ONLY KEEP TADAWUL AND NASDAQ" directive, which is enforced in the Markets/ideas universe (872 baked NASDAQ names) but not here: `primary_exchange` is fetched, displayed, and never used as a predicate, so the saved-and-reviewed research surface spends most of its 500 slots on NYSE/ARCA names the owner deliberately removed. Second, `type` is decoded and never filtered, so ETFs (including leveraged ones) compete for slots against common stock and can occupy the headline top-5 Buy list, each consuming a full evidence pass whose Benzinga earnings/ratings/guidance products are structurally empty. Third, a scan costs roughly 4,000–7,000 API calls, of which ~2,000 are Benzinga products the owner does not own, re-denied once per symbol because entitlement failures are cached per-symbol with no cross-symbol memo — and running both horizons doubles all of it. Fourth, the whole research surface hard-stops on 2027-01-01 (`parts.year == 2026`) and reports the failure as "Check Massive settings", blaming a subsystem that is fine. On reachability: a NASDAQ name only enters a scan if it is a top-500 US name by that day's traded dollars; the receipt already holds the 500th name's dollar volume but never shows it, so the owner cannot tell whether a name they care about missed by a hair or by an order of magnitude.

### Already good — do not "fix" these

- Selection is activity-ranked, not alphabetical or cap-ordered. StockSageResearchUniverse.swift:114 sorts by `activity` descending with the ticker only as a float-tie-break, and StockSageHorizonResearch.swift:256 carries the standing comment `// Selection is activity-ranked BEFORE this safety cap; never sort it alphabetically.` This is the failure mode the dimension was written to catch, and it is explicitly guarded against.
- OTC is excluded twice — at the request (`include_otc=false`, StockSageResearchUniverse.swift:71) and again per-row (`row["otc"] == nil || ... !$0.boolValue`, line 104). Belt and braces, and `market == "stocks"` in the directory filter already keeps Massive's separate `otc` market out of the denominator, so `directoryCount` is not silently inflated with unselectable rows.
- The partial-session case is labeled honestly. `partialSession: calendar.isDate(day, inSameDayAs: now)` renders as "· session-to-date" in `Receipt.summary`, and the prior-session fallback appends "Prior session used for wider verified coverage." A morning run ranked on two hours of tape says so rather than presenting itself as a full session.
- The coverage popover (StockSageResearchModesPanel.swift:222) is unusually candid for selection copy: it names the ranking basis, calls it "an activity-based popularity proxy, not social sentiment or the S&P 500", discloses ETFs and share classes, says "no OTC", and states "Missing observations are not filled alphabetically." Most of the biases in this dimension are disclosed even where they are not fixed.
- `Receipt.detail(for:)` tags the per-name activity number with "Not a Buy signal." — the one place a selection statistic could be misread as a ranking verdict, and it is closed.
- The selection→assessment handoff holds the honesty floor. For the ~500 scanned names that are not in the store's tracked universe, `store.catalystChain[ticker]` is nil and `companyEventChecks[ticker]` is empty; StockSageAIAssessment.swift:66 renders that as "Earnings: not checked; date and outcome unknown." and .unchecked as "unchecked or no usable answer; not proof of no earnings" — an unknown, never a finding.
- The fallback path in `fetch` refuses to launder a revoked permission into a success: `if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }` before any fallback acceptance (StockSageResearchUniverse.swift:148-152).

### Verified findings

#### The research universe ignores the owner's NASDAQ-only directive that the ideas universe enforces

- **Where:** `StockSage/Sources/StockSage/StockSageResearchUniverse.swift:102`
- **Confidence:** high  ·  **Est. effort:** ~12 lines
- **Owner impact:** On 2026-07-16 the owner directed "ONLY KEEP TADAWUL AND NASDAQ", and StockSageQuoteService.swift:529-623 enforces it for the Markets/ideas universe with a baked 872-name `nasdaqListed` set (1,341 other-exchange names dropped). The horizon research scan — the surface whose runs are actually SAVED for 7/14-day review — never got that filter. Its 500 slots are drawn from the whole US tape ranked by dollar volume, so the top of that list is dominated by NYSE and ARCA names (SPY, IWM, the XL* sector funds, the NYSE-listed banks/energy/industrial complex). The owner opens Saved research expecting the universe they curated and gets the universe they deleted. The two surfaces disagree about what 'my market' means, and nothing in the UI says so.

**Evidence**

```swift
guard let listing = known[symbol], listing.active, listing.locale == "us", listing.market == "stocks",
      listing.currency_name?.lowercased() == "usd", StockSageHorizonResearch.validTicker(symbol),

// ...and the exchange field, decoded and carried all the way through, is used only as a label:
// StockSageHorizonResearch.swift:32   let primary_exchange: String?
// StockSageHorizonResearch.swift:377  .init(symbol: item.ticker, market: "US · \(item.primary_exchange ?? "exchange unconfirmed")")
// StockSageResearchModesPanel.swift:518 Text("Type: \(item.type ?? "unconfirmed") · \(item.primary_exchange ?? "exchange unconfirmed")")
```

**Proposal**

Two honest options, and this is a disclosure-or-filter choice rather than an obvious bug. (a) Filter: add `listing.primary_exchange == "XNAS"` to the guard at line 102, add a `nasdaqOnly` flag to `Receipt`, and change the coverage copy at StockSageResearchModesPanel.swift:222 from "Confirmed USD listings, including ETFs and share classes" to name the exchange restriction. Note this shrinks the eligible pool — measure it before shipping, because the fallback at line 141 (`eligibleCount < scanLimit`) starts mattering once the pool is NASDAQ-only. (b) Disclose: keep the whole tape but add the NASDAQ count to the receipt summary ("N of the 500 selected are NASDAQ-listed") so the owner sees the divergence instead of inferring it. Either way the fix is small; the sizing is on whichever the owner wants.

#### No instrument-type filter: ETFs consume research slots and can head the top-5 Buy list

- **Where:** `StockSage/Sources/StockSage/StockSageResearchUniverse.swift:103`
- **Confidence:** high  ·  **Est. effort:** ~6 lines
- **Owner impact:** Dollar-volume ranking on the US tape puts ETFs near the very top — SPY and QQQ outtrade every single stock, and the leveraged single-stock/sector funds (SOXL, TQQQ and friends) sit high in the daily activity table. Each one that lands in the 500 consumes a full evidence pass (one Massive 1y history + seven Benzinga products + a Qwen call) whose earnings, guidance, ratings, insights and consensus products are structurally empty for a fund, then gets an ATR stop/target from `levels()` and can rank into `topBuys` — the five names the panel headlines. The owner's week-horizon shortlist can be a leveraged ETF, sized with a single-stock volatility rule, competing for slots against the common stock they actually research. The panel does disclose ETF inclusion, so this is a slot-allocation defect, not an honesty-floor breach.

**Evidence**

```swift
// `type` is decoded on Listing (StockSageHorizonResearch.swift:31 `let type: String?`),
// rendered in the detail sheet, and never used as a selection predicate. The eligibility
// guard checks active / locale / market / currency / ticker shape / otc — never type:
      listing.currency_name?.lowercased() == "usd", StockSageHorizonResearch.validTicker(symbol),

// and topBuys, the headline output, applies no type filter either:
// StockSageHorizonResearch.swift:64-68
            let strong = listings.filter { results[$0.ticker]?.verdict?.action == .strongBuy }
            let buys = listings.filter { results[$0.ticker]?.verdict?.action == .buy }
            return Array((strong + buys).prefix(StockSageHorizonResearch.topBuyLimit))
```

**Proposal**

Add `(listing.type == "CS" || listing.type == "ADRC")` to the eligibility guard at line 103, or the softer version: keep ETFs eligible but exclude them from `topBuys` and count them in the receipt (`etfCount`) so the owner sees how many of the 500 were funds. The soft version is ~6 lines and needs no decision about ADRs, preferreds or units; the hard filter needs one call from the owner about which `type` values count as researchable.

#### ~2,000 of a scan's ~4,000-7,000 API calls are for Benzinga products the owner does not own, re-denied once per symbol

- **Where:** `StockSage/Sources/StockSage/StockSageBenzingaClient.swift:428`
- **Confidence:** medium  ·  **Est. effort:** ~15 lines
- **Owner impact:** Per scan: ~11-12 directory pages + 1-2 grouped-daily calls + 500 × (1 Massive daily aggregate + 7 Benzinga base products + up to 6 analyst/firm metadata lookups). That is roughly 4,000 calls floor, ~7,000 with metadata misses, for ONE horizon. The owner owns Earnings, Analyst Ratings and Corporate Guidance; analystInsights, bullsBearsSay, news and consensusRatings are four more products fired 500 times each, and because the denial cache is keyed per symbol there is no cross-symbol memo — symbol 2 through 500 each re-learn the same 402/403. That is ~2,000 guaranteed-failing requests per scan, 4,000 if both horizons are run, each one taking a slot in the client's queue and pushing the scan toward the 429 cooldown path. The owner notices this as a scan that takes far longer than 500 model calls should and occasionally stalls on throttling.

**Evidence**

```swift
let baseQueries = B.Product.allCases.filter { $0 != .analysts && $0 != .firms }.map { product in

// Product.allCases = earnings, guidance, ratings, analystInsights, bullsBearsSay,
//                    news, analysts, firms, consensusRatings   (StockSageBenzinga.swift:8-10)
// so seven base products fire PER SYMBOL. Entitlement denials are cached, but the cache key
// carries the symbol (StockSageBenzingaClient.swift:338-343 → `.page(query)`, and
// Query carries `subject`), and the TTL is short:
//   case .news: 30   /  case .consensusRatings: 7_200  /  default: 300   (StockSageBenzinga.swift:25-31)
            let failure: B.Failure = http.statusCode == 401 ? .unauthorized
                : (http.statusCode == 402 || http.statusCode == 403) ? .entitlement : .http(http.statusCode)
```

**Proposal**

Add a per-epoch entitlement memo to StockSageBenzingaClient: when a product returns 401/402/403, record `deniedProducts.insert(product)` alongside the existing capture epoch, and have `page(for:)` short-circuit to `unavailable(query, original, .entitlement)` for any product in that set without a request. It must clear on the same triggers the existing `clearAuthorizationFailures()` and `synchronize()` epoch-reset already use, so re-entitlement is picked up. ~15 lines. Confidence is medium on the premise, not the mechanism: I am taking the owned-add-on list (Earnings, Analyst Ratings, Corporate Guidance) from the brief, not from anything measurable in the tree — one scan's page statuses would confirm or kill it in a minute.

#### The whole research surface stops working on 2027-01-01, and the failure tells the owner to check Massive

- **Where:** `StockSage/Sources/StockSage/StockSageMarketHours.swift:109`
- **Confidence:** high  ·  **Est. effort:** ~20 lines
- **Owner impact:** Today is 2026-09-15; the calendar runs out in fifteen weeks. From 2027-01-01 `sessions(at:)` throws before a single request is made, every `completedHistory` check also fails (it requires `nasdaqDay(at: now) != nil`), and the owner's only signal is a status line telling them to go check their Massive credentials — which are fine. They will re-enter the key, re-probe the provider, and find nothing wrong, because the cause is a hardcoded year in the app. The fail-closed behaviour itself is deliberate and tested (StockSageResearchUniverseTests.swift:45 asserts 2027-01-04 throws), and the `ponytail:` marker at line 103 says "extend from verified notices before 2027, never guess" — so the finding is the expiry date arriving and the message misattributing it, not the design.

**Evidence**

```swift
guard parts.year == 2026, let month = parts.month, let day = parts.day else { return nil }

// every entry point into selection routes through it:
// StockSageResearchUniverse.swift:57  guard ..., let schedule = StockSageMarketHours.nasdaqDay(at: now) else { throw URLError(.dataNotAllowed) }
// and the catch-all renders as:
// StockSageHorizonResearch.swift:291
                    scans[horizon]?.status = "Scan incomplete: US directory or dated market activity could not be verified. Check Massive settings and retry."
```

**Proposal**

Two parts. (1) Extend the table from published 2026 NYSE/NASDAQ holiday notices — ten 2027 holidays plus the two early closes — gated the same way (`parts.year == 2026 || parts.year == 2027`), and note that StockSagePaperAutomation.swift:311-322 already carries a calendar through 2027-01-31, so the two expiry horizons should be unified rather than left one month apart. (2) Give the calendar-coverage failure its own error case so StockSageHorizonResearch.swift:291 can say "This build's trading calendar ends 2026-12-31; the app needs an update" instead of blaming Massive. ~20 lines plus the verified holiday dates.

#### The owner is never told what fraction of the eligible universe was researched, or where the activity cut line fell

- **Where:** `StockSage/Sources/StockSage/StockSageResearchUniverse.swift:21`
- **Confidence:** high  ·  **Est. effort:** ~4 lines
- **Owner impact:** The owner reads "9,800 eligible of 11,300 returned observations" and, two lines away, "Scan finished · 500 listings checked once." Nothing states the relationship: about 5% of the eligible universe was researched and 9,300 names were dropped at a threshold the UI never shows. The practical consequence is on reachability — if the owner wonders why a NASDAQ name they follow never appears in a scan, there is no way to tell whether it missed the cut by 5% or by 50×, and therefore no way to know whether running earlier or later in the session would change anything. The data to answer it is already computed: `chosen` is sorted, so the 500th entry's `activity` IS the cut line.

**Evidence**

```swift
var summary: String {
            "Activity session: \(session) ET\(partialSession ? " · session-to-date" : "") · \(eligibleCount) eligible of \(returnedCount) returned observations."
                + (fallback ? " Prior session used for wider verified coverage." : "")
        }

// the cut line is already in hand and thrown away — `dollarVolume` holds every chosen name's activity:
            dollarVolume: Dictionary(uniqueKeysWithValues: chosen.map { ($0.listing.ticker, $0.activity) })))
```

**Proposal**

Extend `Receipt.summary` (or the coverage popover line at StockSageResearchModesPanel.swift:225, which already prints `directoryCount` and `selection.summary`) with the two numbers the receipt already has: the selected count against `eligibleCount`, and the minimum activity among `chosen` formatted the same way `detail(for:)` formats it. "500 of 9,800 eligible researched; selection cut at $87.4M traded." ~4 lines, no new data, no new request.

#### A single duplicated directory row aborts the entire scan and blames Massive settings

- **Where:** `StockSage/Sources/StockSage/StockSageHorizonResearch.swift:196`
- **Confidence:** medium  ·  **Est. effort:** ~10 lines
- **Owner impact:** `fetchUniverse` walks ~11,000 listings across ~12 paginated requests. `Listing` is `Equatable` over every field, so if one ticker appears on two pages with ANY field differing — a `name` edited between page 3 and page 9 of the same walk, a `primary_exchange` correction, a `type` reclassification — the whole universe fetch throws, the scan never starts, and the owner is told "US directory or dated market activity could not be verified. Check Massive settings and retry" (line 291). One inconsistent row out of eleven thousand costs the entire run, and the message points at credentials that are working.

**Evidence**

```swift
for item in page.results where item.active && item.market == "stocks" && item.locale == "us" {
                if let existing = listings[item.ticker], existing != item { throw URLError(.cannotParseResponse) }
                listings[item.ticker] = item
```

**Proposal**

Keep the first observation, count the conflicts, and surface the count rather than aborting: replace the throw with `conflictCount += 1` (keeping `existing`), thread the count into `Receipt`, and print it in the coverage popover as "N directory entries had conflicting metadata across pages; first observation used." That preserves the honesty (the owner is told the directory was inconsistent) without letting one bad row delete the scan. Keep a hard abort only above a real threshold. ~10 lines including the receipt field and the copy.

### Refuted — checked and killed, with the reason

#### ~~Running both horizons re-selects and re-fetches the identical 500 names from scratch~~

The OBSERVATION is true — I verified it. `start(_:store:)` guards on `task == nil` (StockSageHorizonResearch.swift:307) so the two horizons are two sequential full passes; each calls `StockSageResearchUniverse.fetch` again (line 334) and each `analyze` re-issues the 1y daily history with `cachePolicy: .reloadIgnoringLocalCacheData` (line 124, not 118 as cited). The PROPOSAL is what fails. It says to reuse the first horizon's `Benzinga.Snapshot` 'while the selection session and credential epoch are unchanged'. The epoch gate would not stop this: `isCurrent(_:)` (StockSageBenzingaClient.swift:101-107) is pure epoch equality — it only changes on key/revision/policy change, not on elapsed time — so a snapshot minutes old passes. What silently travels with it is the evidence's own dating: `capturedAt`, every page's `checkedAt`, and the news window `from: bounds - 7d, through: bounds` (StockSageBenzingaClient.swift:430-431) are all stamped from the FIRST run. The second horizon's saved record would then carry a capture time and a news window it never performed, and `StockSageResearchHistory.snapshot` records it as a completed run of its own. That is exactly the defect class the 2026-09-11/12 commits fixed ('Stop a failed SEC fetch printing as "we checked, nothing was filed"', 'date the mark it calls a price'). It survives only if the reused evidence is re-dated and disclosed as captured at the earlier run — at which point it is a change to the saved-record provenance contract, not a cache, and the 60-80 line estimate is well under. The finding itself flags that the horizons may be intentionally independent captures; on this code they are, and that is a feature.

### Reviewer notes

VERIFICATION SUMMARY — every quoted line was opened; 6 of 7 findings hold, 1 refuted as proposed.

WHAT I CONFIRMED VERBATIM
- StockSageResearchUniverse.swift:102-103 — the eligibility guard checks active/locale/market/currency/ticker-shape/otc and NOTHING else. Quoted exactly.
- `primary_exchange` and `type` are decoded (StockSageHorizonResearch.swift:30,32) and used ONLY as labels: StockSageResearchModesPanel.swift:518 ("Type: … · …"), :259 (help tooltip), and StockSageHorizonResearch.swift:377 (the market string). A repo-wide grep finds no other use of either field. Both findings 1 and 2 are correct that neither is ever a predicate.
- StockSageQuoteService.swift:516-528 carries the owner directive comment verbatim ("ONLY KEEP TADAWUL AND NASDAQ", 872 NASDAQ kept / 1,341 dropped) and :621-628 enforces it at `build(_:)`. The divergence between the two surfaces is real.
- StockSageMarketHours.swift:109 `guard parts.year == 2026` — exact. StockSageHorizonResearch.swift:291 error copy — exact. StockSageResearchUniverseTests.swift:45 asserts 2027-01-04 throws, and :53 asserts `request(session: "2027-01-04") == nil`.
- StockSageHorizonResearch.swift:196 duplicate-conflict throw — exact; `Listing` is `Equatable` over all eight fields.
- StockSageBenzingaClient.swift:428 baseQueries — exact, seven products per symbol. Denied pages ARE cached: line 296-300 builds `.unavailable(.entitlement)` and calls `remember(page, key: job.key)`, key from `requestKey` → `.page(query)` carrying `subject`. There is NO cross-symbol memo anywhere — `clearAuthorizationFailures` (110-117) and `synchronize` (119-135) are the only denial-state handlers and both are cache-wide, not product-wide. Mechanism confirmed.
- Receipt.summary (StockSageResearchUniverse.swift:16-19) has no selected-count and no cut line; `chosen` is sorted and `dollarVolume` holds all 500 activities (line 119), so both numbers are in hand. Confirmed.

THREE PLACES THE FINDINGS UNDERSOLD OR OVERSOLD THEMSELVES

1. Finding 2 is MORE serious than written. `scan.topBuys` is not just the headline five — StockSageResearchHistory.swift:124 builds the saved `Prediction` rows from it, with `levels` (the ATR stop/target). So a leveraged ETF that ranks into the top five enters the SAVED 7-/14-trading-day review set carrying a single-stock volatility-sized stop. That is the one surface that could ever measure whether this research is worth anything, and it is the surface the owner opens. This is why I rank it above its stated position.

2. Findings 1 and 2 are CHEAPER than they claim, and I can prove it. The test fixtures already construct listings as `type: "CS", primary_exchange: "XNAS"` (StockSageHorizonResearchTests.swift:117-118, StockSageResearchUniverseTests.swift:10-11, StockSageChatTests.swift:669-670). So (a) "XNAS" and "CS" are the repo's own expected values — the proposed predicates are not invented MIC/type guesses, and (b) neither filter breaks a single pinned test, including the six `topBuys` assertions. Caveat that still stands: fixtures are not a captured Massive spec, so per spec-fidelity the exact enum set ("CS" vs also "ADRC"/"PFD"/"UNIT", "XNAS" vs "XNGS"/"XNMS" tiers) must be confirmed against the vendor doc before shipping a HARD filter. The soft versions need no such confirmation.

3. Finding 4's effort is understated by roughly 3x, and it should be SPLIT. Extending the calendar to 2027 flips assertions in at least four test files — StockSageResearchUniverseTests.swift:45 and :53, StockSageHorizonResearchTests.swift:354-355 ("Calendar year is not verified"), StockSageAIAssessmentTests.swift:461-464. Those are legitimate updates (the verified-year set genuinely grows), not assertion-editing, but "20 lines" is not the real number. The cheap, separable, and higher-value half is part (2): give calendar-coverage failure its own error case so line 291 stops saying "Check Massive settings" about a hardcoded year. Ship that half now; do the calendar extension as dated maintenance before 2027-01-01.

TWO AMENDMENTS REQUIRED BEFORE ANY OF THESE SHIP

- Finding 3's proposal as written would BREACH the honesty floor. It says to short-circuit to `unavailable(query, original, .entitlement)`. StockSageBenzingaEvidenceView.swift:86 renders `.entitlement` as "Unavailable: product access denied" — a statement about a provider response. Emitting that for a symbol whose request was never sent prints a denial the input cannot support for that symbol: "we could not check" rendering as "we checked and were refused". The memo needs its own failure case ("not requested — this product was denied for an earlier symbol in this session") or the finding dies on the floor it was written to protect. With that case plus a test, 15 lines is more like 30-40 — still worth doing, but the premise (which three add-ons are owned) is owner-stated, not measurable in the tree, so measure one scan's page statuses first.
- Finding 5's copy must say "selected", not "researched". A stopped or interrupted scan researches fewer than the 500 it selected (StockSageHorizonResearch.swift:283-287 retains partial results), so "500 of 9,800 eligible researched" would overstate a stopped run. "500 of 9,800 eligible selected; selection cut at $87.4M traded" is the honest form. Four lines is otherwise accurate — both numbers already exist, no new request.

ONE DEMOTION
Finding 6 is real but its frequency claim slides. The title is right, but the body's "One inconsistent row out of eleven thousand costs the entire run" is not the trigger — the trigger requires the SAME ticker to be RETURNED ON TWO PAGES with a differing field. The walk is cursor-paginated and `sort=ticker&order=asc` (line 88), which makes a cross-page duplicate uncommon, and nothing in the tree measures it ever firing. Relaxing a parse-integrity throw on an unmeasured hypothetical is the wrong trade; the defensible half is the same as finding 4's — the message at line 291 blames Massive credentials for something that is not a credential problem. Fix the message once, and both findings' UI half is paid for. Ranked last.

ON THE "ALREADY GOOD" LIST: I spot-checked it and it holds. StockSageAIAssessment.swift:62 and :66 render unchecked/absent earnings exactly as quoted ("unchecked or no usable answer; not proof of no earnings" / "Earnings: not checked; date and outcome unknown."). StockSageResearchUniverse.swift:148-153 refuses to launder a cancelled/revoked fetch into a fallback success, as quoted. The activity-ranking comment at StockSageHorizonResearch.swift:256 and the sort at :114 are both there. Saying so plainly: selection's SHAPE is sound, and the coverage popover at StockSageResearchModesPanel.swift:222 is unusually candid. Every surviving finding is about a field that is fetched and then not used, or a number that is computed and then not shown — not about a broken ranking.

---

## Model grounding

I traced the full evidence path for a US idea: Massive/Benzinga capture → 3-per-product storage cap → `Projection` byte budget → `Context.facts(maximumUTF8Bytes:)` → `fittedResearchPrompt`/`fit` → the model → `validate`/`checkedResponse`. The good news first: almost every drop in that chain IS counted, and the counts go into the prompt itself, not just the UI — `Projection.text` reports sent / not-eligible / capped / trimmed as four separate numbers, and `NewsService.Observation.summary` breaks exclusions into stale / future / missing-date / invalid / provider-excluded per attempt. The output verifier is also stronger than it looks: prose must contain zero digits, enforced twice (a generation schema AND an independent Swift validator that does not trust the schema), so a fabricated figure in reason/risk cannot be accepted — a fabricated number is structurally impossible to pass, which also means there is no false-rejection surface there, because the schema forbids the model from writing numbers in the first place. What I did find is that the *reasons* attached to those counts have drifted out of sync with the code that produces them, and that one of the four model surfaces — the on-device narrator — is the only model call in the app that never sizes its prompt to a context window and has no error case for overflowing one. Roughly 27 of up to 180 provider rows survive the caps, and of those about half survive the byte budget; the byte budget is a hardcoded 12,000 that sits ~1.4 kB below what the model window actually holds, so the seam built to pack evidence to the real window (`fittedResearchPrompt`) is currently a no-op. I did not find any place where an unknown is printed as a finding, and I could not construct a realistic input that makes the fit-trim actually drop the Benzinga block — I say so below rather than rank a hazard I cannot trigger.

### Already good — do not "fix" these

- `StockSageBenzinga.Projection.text` (StockSageBenzinga.swift:216-223) puts the drop accounting INTO THE PROMPT, not just the UI: sent count, `notEligibleCount`, `cappedRecordCount` and `trimmedRecordCount` are four separate numbers plus nine per-product availability states (unchecked / obsolete / bad clock / bad query / partial / empty / ok / failure tag). The model is told what it is missing and why, which is rare and correct.
- `StockSageNewsService.Observation.summary` (StockSageNewsService.swift:75-93) is the best disclosure in the codebase: per-provider status, per-category exclusion counts (stale, future, missing/invalid date, other invalid, provider-excluded), the check timestamp, and a closing "zero usable excerpts does not mean no news". This is exactly the honesty floor working.
- The number fence is enforced TWICE and the generation schema is not trusted. `responseSchema` (StockSageAIAssessment.swift:218-232) constrains generation to digit-free prose, and `validate` (StockSageAIAssessment.swift:326-375) re-checks it in Swift with `numericTokens(...).isEmpty`. A server that ignores the schema still cannot get a numeric claim accepted.
- The two number-failure reasons are genuinely distinguished rather than collapsed: `.foreignNumber` ("introduced a number that is not in the supplied facts") vs `.unboundNumber` / "Figures in prose are not validated for subject, sign, unit or time". The owner can tell a fabricated figure from a correctly-copied one.
- `StockSageLocalModelServer.fit` (StockSageLocalModelServer.swift:264-277) drops only OPTIONAL records, only from the end (so F-numbering of what is kept never shifts), and returns nil rather than sending a prompt with a mandatory cash constraint or risk disclosure quietly removed. `assemble` measures the real strings, not an estimate.
- `evidenceRepairPrompt` + `preservesOpinion` (StockSageAIAssessment.swift:383-399) let the repair pass add citations and nothing else — action/reason/risk must match byte-for-byte, and the temporary all-facts IDs used for the preflight are never published.
- `checkedResponse` relabels rather than discards (StockSageCatalystNarrator.swift:297-330): a paragraph that fails a check is still readable, marked unverified, with the specific reason. Withholding it entirely would have been the lazier and worse choice.
- `StockSageChat.unavailableMessage(for:)` (StockSageChat.swift:38-71) discriminates 14 distinct causes and never interpolates a server's own error text, so a hostile body cannot reach the user and a timeout does not read like a dead server.
- `Context.canAssess` (StockSageAIAssessment.swift:96-111) refuses to spend an inference on a sample or stale quote at all, rather than assessing and disclaiming afterwards.

### Verified findings

#### The "not eligible at capture" reason names a 7-day ratings window that the ratings evidence path stopped using, and blames recency for rows the parser simply could not read

- **Where:** `StockSage/Sources/StockSage/StockSageChat.swift:310`
- **Confidence:** high  ·  **Est. effort:** ~30 lines
- **Owner impact:** The owner asks Chat about a NASDAQ name and reads "Benzinga: 4 sent; 17 not eligible at capture (outside the ratings 7-day or guidance 14-day recency window, or no rating change)". He concludes analyst action older than a week is being thrown away and that widening the window would recover it. Both halves of that sentence are false for ratings: the window is 45 days, and "maintains"/"reiterates" rows are deliberately KEPT (`requireMateriality: false`). Worse, `notEligibleCount` is just `sum(page.excludedCount)`, and `parse` increments `excluded` for ANY row that throws — a malformed row, a bad currency code, a negative revenue, an earnings row dated in the future. So a provider schema change that makes all 20 rows unparseable reports to the owner AND to the model as "20 records weren't recent enough". That is the 2026-09-11 defect class ('we could not check' rendering as 'we checked') re-entering through the explanation string rather than the count. The stale comment at StockSageBenzinga.swift:534 ("Ratings evidence therefore looks back 30 days") shows the drift is accidental — StockSageBenzingaConsumerTests.swift:113 even records that the window was later widened to 45.

**Evidence**

```swift
let benzingaDisclosure = projection.map { p in
    " Benzinga: \(p.records.count) sent; \(p.notEligibleCount) not eligible at capture"
    + " (outside the ratings 7-day or guidance 14-day recency window, or no rating change);"
    + " \(p.cappedRecordCount) capped at 3 per product; \(p.trimmedRecordCount) trimmed to fit."
} ?? ""

// but the ratings evidence path actually says (StockSageBenzinga.swift:538-541):
windowDays: product == .ratings ? StockSageBenzinga.ratingsEvidenceDays : nil,
requireMateriality: product != .ratings)
// with  nonisolated static let ratingsEvidenceDays = 45
```

**Proposal**

Two sizes. Stopgap (~4 lines): fix the parenthetical in StockSageChat.swift:312 to state the real rule — ratings look back `ratingsEvidenceDays` and keep unchanged ratings; guidance uses its 14-day event window — and interpolate `StockSageBenzinga.ratingsEvidenceDays` rather than a literal, so the string cannot drift again. Also correct the stale 30-day comment at StockSageBenzinga.swift:534. Honest version (~30 lines): split `Page.excludedCount` into `outOfWindowCount` and `unreadableCount`, carry both through `Projection` into `Projection.text` (StockSageBenzinga.swift:220) and the Chat disclosure, and add a decoder bound plus a fixture test for each bucket. The second is what the house style actually asks for — an unreadable row and a quiet market are different facts.

#### The on-device narrator is the only model call in the app that never sizes its prompt to a context window, and its error map has no case for overflowing one  _(not explicitly listed as kept — confirm before acting)_

- **Where:** `StockSage/Sources/StockSage/StockSageCatalystNarrator.swift:400`
- **Confidence:** medium  ·  **Est. effort:** ~20 lines
- **Owner impact:** Every other model call in the app checks its prompt against a real budget: `explainViaServer` passes `contextTokens: researchContextTokens` and `completeDetailed` refuses with `.contextBudget` (StockSageLocalModelServer.swift:841); HorizonResearch and PaperAutomation call `fittedResearchPrompt`; the ideas-card assessment calls `fittedPrompt()`. `explainOnDevice` does none of this. It hands FoundationModels whatever `facts(for:sources:benzinga:)` produced — and because that function gives the Benzinga block all of `12_000 − lines − 1` (StockSageCatalystNarrator.swift:176-180), a US idea with a live capture fills it to ~12 kB every time. The only ceiling is the single hardcoded gate at line 497, which is the SAME constant for both backends despite the on-device model having a far smaller window than the 16,384-token server the other constant was derived for. When it overflows, the `default:` branch tells the owner "The on-device model failed — try again" — a retry that cannot ever succeed, for a deterministic size failure, with no mention of size. That reads as a transient hiccup and hides a knowable cause.

**Evidence**

```swift
let briefFacts = facts(for: brief, sources: sources, benzinga: benzinga)
let session = LanguageModelSession(instructions: instructions)
do {
    let response = try await session.respond(
        to: prompt(facts: briefFacts),
        options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 200))
...
} catch {
    return .unavailable(humanOnDeviceError(error))
}

// humanOnDeviceError, line 424-435:
case .guardrailViolation, .refusal:
    return "The on-device model declined this request (content guardrail)."
default:
    return "The on-device model failed — try again."
```

**Proposal**

Two changes. (1) Give `explainOnDevice` its own byte gate derived from the on-device window rather than sharing the server's 12,000, and pack `facts(for:)` down to it with the existing `fit` seam so the shortfall is disclosed instead of thrown — the narrator already has honest language for this at line 498. (2) Add an explicit case to `humanOnDeviceError` for `LanguageModelSession.GenerationError.exceededContextWindowSize` saying the evidence was too large for the on-device model and naming the server backend as the alternative, so "try again" is reserved for things a retry can fix. ~20 lines plus a fixture that asserts the on-device fact set stays under the on-device gate with a full Benzinga capture.

#### The 12,000-byte evidence cap is hardcoded ~1.4 kB below what the model window actually holds, and it is the Benzinga block that pays for the gap

- **Where:** `StockSage/Sources/StockSage/StockSageAIAssessment.swift:34`
- **Confidence:** high  ·  **Est. effort:** ~25 lines
- **Owner impact:** Measured from the constants in the tree: `researchContextTokens` 16,384 − `researchOutputTokens` 192 − 128 framing = 16,064 bytes for system+user; the horizon system string (focusInstructions 481 B + the rewritten assessment instructions 1,334 B, joined) is 2,030 B, leaving 14,034 user bytes. The assembled user prompt is the 12,000-capped fact set (~12,000) + F-prefixes (~170) + the two mandatory horizon facts (~500) ≈ 12,670 — about 1,360 bytes of paid-for context left unused on every US research run. Since Benzinga is the residual claimant (it gets only `12_000 − everything_else − 1`), that headroom is exactly two to three more analyst-ratings/guidance/earnings records — the add-ons the owner pays for — that the window could hold and the app refuses to send. It also means `fittedResearchPrompt`, the seam whose comment says it exists to "pack to the model's real allowance rather than a hardcoded 12,000 bytes", never actually trims anything in this path: the inner cap binds first, so the outer fit is a no-op. (Latent, and I could not construct a realistic input that triggers it: IF the fit ever did trim, the Benzinga projection is the LAST element of `optionalFacts` and `fit` drops from the end, so the first record removed is the entire Benzinga block — nine status lines and every record — reported to the owner as "1 of 25 optional evidence records were omitted" at StockSageHorizonResearch.swift:424. Worth fixing the ordering while the cap is being fixed, not worth ranking on its own.)

**Evidence**

```swift
var facts: [String] { facts(maximumUTF8Bytes: 12_000) }
...
if let benzinga, benzinga.symbol == idea.symbol.uppercased(),
   let projection = StockSageBenzinga.projection(benzinga,
        maximumUTF8Bytes: max(0, maximumUTF8Bytes - result.joined(separator: "\n").utf8.count - 1))

// and at the horizon caller (StockSageHorizonResearch.swift:410-417):
// "Pack to the model's real allowance rather than a hardcoded 12,000 bytes"
let optionalFacts = context.facts(maximumUTF8Bytes: 12_000)
guard let fitted = StockSageAIAssessment.fittedResearchPrompt(
        optional: optionalFacts, mandatory: horizonFacts, ...
```

**Proposal**

Thread the real allowance instead of the constant: compute `StockSageLocalModelServer.maximumUserBytes(system:outputTokens:contextTokens:)` at each caller, subtract the mandatory facts and the F-prefix overhead, and pass the remainder as `maximumUTF8Bytes`. `Context.canAssess` (StockSageAIAssessment.swift:110) compares against the same literal and must move with it — pass the budget in rather than recomputing 12,000 there. While in the file, move the Benzinga projection out of the tail of `optionalFacts` (or mark it mandatory) so a future trim cannot silently take the whole block, and have the trim note name which kinds of record were dropped, not only how many. ~25 lines across three call sites, plus updating the byte-ceiling fixture in StockSageBenzingaConsumerTests.swift:160.

#### The narrator is the last consumer still on the legacy four-bucket error map, so a model timeout reads "Could not reach the local server"

- **Where:** `StockSage/Sources/StockSage/StockSageCatalystNarrator.swift:464`
- **Confidence:** high  ·  **Est. effort:** ~25 lines
- **Owner impact:** Chat was deliberately migrated off this map — StockSageChatSection.swift:665 says so in as many words: it "folds eighteen diagnostic categories into four … a stopped server, a misspelled model ID and a five-minute timeout all produced one identical sentence." Explain still uses it. So when LM Studio is running and simply took longer than the deadline to load the model, the owner is told the server could not be reached and goes to check whether it is running. `.policyDenied` (external access turned off) reports the same way. A `.contextBudget` refusal — which the app raised before any request left the machine — reports as "The local server returned an unexpected response", blaming the server for the app's own guard. The correct category is present in the appended `diagnostic.summary` (it begins `server=timeout`), so the fine print is right and only the headline lies — but the headline is the sentence the owner acts on.

**Evidence**

```swift
private nonisolated static func humanServerError(_ error: StockSageLocalModelServer.ServerError) -> String {
    switch error {
    case .unreachable(let detail):
        return "Could not reach the local server: \(detail)"

// fed by StockSageLocalModelServer.swift:629:
case .timeout, .cancelled, .network, .unavailable, .obsoleteRequest, .policyDenied:
    return .unreachable(diagnostic.summary)
default: return .badResponse(diagnostic.summary)
```

**Proposal**

Replace `humanServerError` with the same `StockSageLocalModelServer.cause(for: diagnostic)` switch Chat already uses in `unavailableMessage(for:)` (StockSageChat.swift:38-71), keeping the `diagnostic.summary` tail. That gets Explain the distinct `.timedOut`, `.contextBudget`, `.modelMissing`, `.networkDenied` and `.unfinished` sentences for free and deletes the last caller of `legacyError`. ~25 lines, mostly deletion, plus pinning two of the new sentences in the narrator tests.

### Refuted — checked and killed, with the reason

#### ~~Records dropped because their PAGE was unusable are counted as "trimmed to fit", the one attribution the file's own doc comment says must never happen~~

The code is quoted correctly (StockSageBenzinga.swift:306 `let total = snapshot.pages.reduce(0) { addCount($0, $1.records.count) }` is not filtered by `usable`), but no reachable input makes `total > candidates.count`, so the misattribution the owner would read cannot occur. Every route to an unusable page that still carries records is closed: (a) credential-generation mismatch — `synchronize()` does `cache.removeAll()` on every epoch change (StockSageBenzingaClient.swift:128), and all four Snapshot constructions in `snapshot(for:)` stamp `original.epoch` on snapshot and pages alike, so a page from a previous generation can never join a newer capture; (b) bad clock and bad query — the `Snapshot(from:)` decoder already rejects any page with `checkedAt > capturedAt` or `!valid(page.query)` (StockSageBenzinga.swift:181-188), and the live path takes `capturedAt = now()` after the fetches; (c) `.unavailable(_)` and invalid-query pages are built by `failed(_:)`/`unavailable(_:_:_:)` with `records: []`; (d) `.notChecked` Benzinga pages are never constructed anywhere in the tree — grep finds the case only in the enum and in `projection`'s own defensive status-line branches. The per-record symbol/vendor filter is indeed a no-op, as the finding says, which means `candidates` equals every record on every usable page. Net: `trimmedRecordCount` in production is exactly the byte-budget drop it claims to be (the per-product cap is applied earlier, in `Snapshot.init`, and lands in `cappedRecordCount`). This is defensive-code hygiene with no owner-visible consequence, not a third cause collapsing into the second — and the finding itself concedes reachability is "narrow" without noticing the cache wipe closes it entirely.

### Reviewer notes

Verified against the tree at 4a18b17. Four of five survive; one dies on reachability.

WHY #1 RANKS FIRST (kept, high confidence, verified verbatim). StockSageChat.swift:310-313 is exactly as quoted. The ratings evidence path is StockSageBenzinga.swift:540-541 `windowDays: product == .ratings ? StockSageBenzinga.ratingsEvidenceDays : nil, requireMateriality: product != .ratings`, with `ratingsEvidenceDays = 45` at :288. So the parenthetical is wrong twice for ratings — the window is 45 days, not 7, and `requireMateriality: false` means unchanged "maintains"/"reiterates" rows are deliberately KEPT, so "or no rating change" describes a rule ratings does not run. Only "guidance 14-day" is right (`Feed.days` = 14 for `.guidance`, StockSageMassiveEvents.swift:33). The collapse claim is also exact: `notEligibleCount` is `snapshot.pages.reduce(0) { addCount($0, $1.excludedCount) }` (StockSageBenzinga.swift:335), and `parse` (:265-273) increments `excluded` both when `parseRecord` returns nil (out of window) and in `catch { excluded += 1 }` (any malformed row, bad currency, negative target, future-dated earnings). A provider schema change that makes 20 rows unparseable therefore prints to the owner AND into the prompt as "20 records weren't recent enough". Two corroborations the finding under-uses: the stale comment is real (StockSageBenzinga.swift:528-534 still says "Ratings evidence therefore looks back 30 days" against a constant of 45), and StockSageBenzingaConsumerTests.swift:109-120 already names this exact rot — "A hard-coded 40 days was outside the window when this test was written and inside it an hour later, when the window was widened to 45 — the same rot that made three other fixtures go vacuous today" — and derives its fixture from `B.ratingsEvidenceDays` for that reason. The Chat disclosure is the one place the literal never got derived. The four-line stopgap is worth doing on its own; note the same stale wording also sits in the `Projection` doc comment at :208 and, in a softer form, inside `Projection.text` itself at :220 ("recency window or no rating change"), so the fix touches three strings, not one. EFFORT CAVEAT on the 30-line "honest version": splitting `Page.excludedCount` means changing a `Codable` struct that is persisted in chat history, so it needs `decodeIfPresent` handling plus a decoder bound plus fixtures — realistically 60-90 lines, i.e. 2-3x the estimate. Still inside the 3x bar, but do not plan it as a half-hour job.

WHY #2 RANKS SECOND (kept, high confidence, arithmetic corrected). The structure is right and the repo's own comments and tests agree with the direction. `var facts: [String] { facts(maximumUTF8Bytes: 12_000) }` is at StockSageAIAssessment.swift:34 as quoted; the Benzinga block really is the residual claimant (`max(0, maximumUTF8Bytes - result.joined().utf8.count - 1)`, :88-90); the horizon caller's own comment at StockSageHorizonResearch.swift:410-412 says it packs "to the model's real allowance rather than a hardcoded 12,000 bytes" and then passes 12,000 anyway. THE BYTE FIGURES ARE OFF, though the conclusion survives: I measured `focusInstructions` at 457 B (not 481), the rewritten assessment instructions at 1,517 B (not 1,334), the joined horizon system string at 1,975/1,976 B (not 2,030), and the user allowance at 14,089/14,088 B (not 14,034). Re-deriving with the real numbers: user prompt ≈ 12,000 (capped facts) + ~130 (F-prefixes over ~28 facts) + ~570 (the horizon mandatory facts) ≈ 12,700, against 14,088 — so the unused headroom is ~1,390 B, not 1,360. Same conclusion, and `fittedResearchPrompt` is confirmed a no-op in this path: the inner cap binds first, so `fit` never trims and `trimmedNote` is always empty. Two things the finding missed that change how the fix must be planned. (a) StockSageTests/StockSageModelHarnessTests.swift:114-134 pins `allowance >= 12_000` for all five evidence-heavy callers, with the comment "Each of these callers caps its compiled facts at 12,000 UTF-8 bytes. If the allowance drops below that, the caller starts failing on every real request" — so 12,000 is a deliberate conservative floor with margin, not an oversight, and raising the pack target must keep that test meaningful rather than edit around it. (b) The constant is load-bearing in five more places than the three call sites named: `canAssess` (:100, and the `facts.joined().utf8.count <= 12_000` check at :110), the narrator's pre-flight gate (StockSageCatalystNarrator.swift:493 and :497), the evidence VIEW (StockSageBenzingaEvidenceView.swift:10), Chat's opening `benzingaBudget` (StockSageChat.swift:294), and `chatBudgetHoldsItsLargestRequiredInput` (ModelHarnessTests:161) which asserts Chat's budget exceeds 12,000 × 2. 25 lines is optimistic; 40-60 is realistic, still inside 3x. The latent ordering hazard the finding flags — Benzinga last in `optionalFacts`, `fit` dropping from the end — is real and correctly labelled as untriggerable today; fixing the ordering while the cap moves is the right call, because raising the pack target is exactly what would make the trim start firing.

WHY #3 RANKS THIRD (kept, high confidence). Verified end to end. StockSageCatalystNarrator.swift:460 `return .unavailable(humanServerError(error.legacyError))` and the four-bucket map at :464-474 are as quoted; `legacyError` at StockSageLocalModelServer.swift:625-632 maps `.timeout, .cancelled, .network, .unavailable, .obsoleteRequest, .policyDenied` to `.unreachable` and everything else to `.badResponse`. The narrator is now the ONLY production consumer of `legacyError` — grep finds just :460 plus the `complete()` wrapper at :972 that has no other caller — so the Chat migration comment at StockSageChatSection.swift:664-668 does describe the seam Explain is still on. The `.contextBudget` case is the sharpest: StockSageLocalModelServer.swift:841 raises it BEFORE the request leaves the machine, and the narrator prints "The local server returned an unexpected response", blaming the server for the app's own guard. Timeout is the most frequent: `explainViaServer` takes the default 90 s, a cold 9B load can exceed that, and the owner is told the server could not be reached. One precision correction to the finding: this does not technically violate the invariant documented at StockSageLocalModelServer.swift:686-690 and pinned by `reachedAndAnsweredFailuresAreNotCalledConnectionProblems` (ModelHarnessTests:438), because none of the six "reached and answered" categories map to `.unreachable` — the harm is real but it is `.timedOut`, `.networkDenied` and `.contextBudget` being misfiled, not a reached-and-answered failure called a connection problem. Note also that `.cancelled` and `.settingsChanged` are usually absorbed upstream by `explain`'s `active()` wrapper, so they are not part of the live harm. Replacing `humanServerError` with `cause(for:)` also has to handle the second call site at :541, which passes `.invalidConfig` with no diagnostic in hand; ~25 lines is fair, and the existing Chat/Sentiment invariant tests give the new narrator strings an obvious pinning pattern.

WHY #4 IS KEPT BUT NOT IN THE TOP THREE. Everything the finding asserts about the code is true: `explainOnDevice` (StockSageCatalystNarrator.swift:393-417) passes `prompt(facts:)` straight to `LanguageModelSession.respond` with no budget; every other model call sizes itself (`explainViaServer` passes `contextTokens: researchContextTokens` at :450; `fittedPrompt()` at StockSageAIAssessment.swift:117-127; `fittedResearchPrompt` at HorizonResearch:414 and PaperAutomation:899); `facts(for:sources:benzinga:)` hands the Benzinga block `12_000 - lines - 1` (:175-178); and the only ceiling is the shared 12,000 gate at :497, which was sized for a 16,384-unit server window. `humanOnDeviceError`'s `default:` really does say "try again" for what would be a deterministic size failure, and `GenerationError.exceededContextWindowSize` exists in FoundationModels on this toolchain, so part (2) of the proposal is cheap and unambiguously right. It ranks fourth because the owner's primary Explain backend is the LM Studio server (on-device is the `.auto` fallback or an explicit `.onDeviceOnly` setting), and because part (1) — "a byte gate derived from the on-device window" — cannot actually be derived: FoundationModels exposes no window-size API, so any constant is a conservative guess rather than a measurement. That does not breach the honesty floor (a budget constant is not a printed claim), but it means the deliverable is "a guessed-low gate plus an honest overflow message", not a measured fix. Whoever takes it should also check it against `statusBudgetExhaustionCannotSilentlyDiscardProviderStates` (StockSageBenzingaConsumerTests.swift:156-185), which pins that oversize facts fail before any model or network probe — a second, smaller on-device gate keeps that test green, but only if it is added alongside the 12,000 gate rather than in place of it.

WHAT I CHECKED AND FOUND GENUINELY GOOD (the summary's "already good" list holds up on inspection): the double number fence is real and independent — `responseSchema` (StockSageAIAssessment.swift:218-232) constrains generation with a literal Unicode numeric-range pattern, and `validate` (:333-377) re-checks in Swift with `introducesForeignNumbers` + `numericTokens(...).isEmpty` after masking F/W references and the full symbol, so a server ignoring the schema still cannot land a numeric claim; `fit` (StockSageLocalModelServer.swift:264-277) drops only optional records, only from the end, and returns nil rather than shipping a prompt with mandatory content removed; `checkedResponse` (StockSageCatalystNarrator.swift:298-317) relabels rather than discards and distinguishes `.foreignNumber` from the unbound-figure case; `Chat.unavailableMessage` (StockSageChat.swift:39-70) discriminates 14 causes and never interpolates server text. I found no place where an unknown is printed as a finding.

---

## Horizon fitness (1–7 vs 7–14 trading days)

The two horizons are real in exactly one layer and nominal everywhere else. Real: the saved-run review counts 7 vs 14 Nasdaq closes on a verified exchange calendar (StockSageResearchHistory.targetClose) — that code is careful and correct. Nominal: the research pipeline feeds the two horizons byte-identical evidence (both 7- and 14-day returns to both, the same context facts, the same ATR levels) and differentiates them solely by one sentence of instruction into a temperature-0.2 sampler with no seed; so the owner cannot tell a horizon difference from sampling noise. Worse, the two places the app does reason about time — earnings proximity buckets and the position time-stop — count CALENDAR days against thresholds calibrated for neither window, which produces the honesty-floor shape the repo cares about most: an idea whose earnings land in the middle of a 7–14 trading-day hold renders the definite claim "no immediate event risk" and takes zero rank penalty. A 7–14 day question is currently NOT answerable from what the app stores: both horizons are measured from the same day-1 open to a single endpoint close, so nothing distinguishes a week-1 mover from a week-2 mover, and the interim bars needed to tell them apart are already fetched and then discarded. The single highest-leverage change is to compute the horizon's window-end date (targetClose already does it) and state, as a mandatory fact and a card line, whether the known earnings date falls inside it.

### Already good — do not "fix" these

- StockSageResearchHistory.targetClose/benchmarkDay (ResearchHistory.swift:301–328) count real Nasdaq trading closes on a verified calendar — DST-safe, half-day aware, and it refuses rather than guesses when the schedule can't be verified. This is the one place the 7 vs 14 distinction is genuinely implemented.
- reviewAvailableAt (ResearchHistory.swift:330–334) waits for the whole New York target date to end before accepting a daily aggregate, so a provider revision can't be recorded as a settled outcome.
- Horizon.focusInstructions (HorizonResearch.swift:17) and the per-horizon rewrite (:21) say out loud "These are trading days, not calendar days" and forbid intraday and >14-day strategies. The app knows the distinction — it just doesn't apply it in the two places that do date math.
- Levels.basis (HorizonResearch.swift:235) states "Existing rules, not horizon-optimized or a forecast. Re-price before considering a trade; overnight gaps can pass the stop." The mismatch in finding #4 is disclosed, not concealed — the fix is to quantify it, not to stop lying.
- The evaluation note (ResearchHistory.swift:400) refuses to call the measured return profit or a win probability, and names its exact basis (next trading day's open → target day's close, one split-adjusted series).
- analyze() refuses an opinion without ≥30 completed prior-session bars including the latest prior session (HorizonResearch.swift:221, :374) rather than opining thinly — and each refusal path returns a note explaining what was missing.
- StockSageCompoundingHorizon.swift is engine-only and unwired (referenced nowhere in Sources but a comment at StockSageConvictionScaler.swift:23), and its caveat constant is unusually blunt. Nothing to fix here — but note it is a weekly-cadence projection with no relation to either trading-day window, so wiring it to a horizon tab later would be a category error.

### Verified findings

#### The time stop counts calendar days against a hold budget the owner sets in a trading-day app, firing before a 7–14 day thesis has started  _(not explicitly listed as kept — confirm before acting)_

- **Where:** `StockSage/Sources/StockSage/StockSageTimeStop.swift:24`
- **Confidence:** high  ·  **Est. effort:** ~35 lines
- **Owner impact:** MarketsView.swift:3597 feeds this `Int(equityHoldDays)`, default 12 (VelocityHoldDays.defaults, ExpectedValue.swift:34). 12 calendar days is about 8 trading days. So a position opened on a 7–14 trading-day thesis gets "⏳ time-stop reached — the capital may compound better elsewhere" at roughly trading day 8, i.e. at the START of the window the research told the owner to hold through. The accessibility label (MarketsView.swift:3600) reinforces it: "held N days, past the 12 day plan". Conversely, nothing ever nudges a 1–7 day position at day 7. The stepper label is the bare unit "d" (MarketsView.swift:7410–7422), so the owner has no way to know which kind of day he is setting.

**Evidence**

```swift
let held = Swift.max(0, Int((now.timeIntervalSince(openedAt) / 86_400).rounded(.down)))
let remaining = daysToHold - held
let exit = held >= daysToHold
...
? "Held \(held) of ~\(daysToHold) planned days — time-stop reached. If the thesis hasn't played out, the capital may compound better elsewhere (this is a clock, not a sell signal)."
```

**Proposal**

Count trading days instead of dividing by 86,400: the exact loop already exists in ResearchHistory.targetClose — walk calendar days from openedAt and count StockSageMarketHours.nasdaqDay(at:)?.trading == true, with a bounded offset and a nil return when the schedule can't be verified (never silently fall back to calendar days). Keep the Crypto branch on calendar days (24/7 is correct there) and say which basis was used in the rationale string. Relabel the two steppers "trading days" / "days (24/7)". Pure function, fully testable, one hand-derived fixture across a weekend and a market holiday.

#### The two horizons receive byte-identical evidence; the only difference reaching the model is one instruction sentence into an unseeded temperature-0.2 sampler

- **Where:** `StockSage/Sources/StockSage/StockSageHorizonResearch.swift:405`
- **Confidence:** high  ·  **Est. effort:** ~5 lines
- **Owner impact:** Both horizons get both the 7- and 14-bar returns; context.facts (AIAssessment.swift:40–95) takes no horizon; levels() takes no horizon. The sole differentiator is Horizon.instructions (:19–22), and StockSageHorizonAnalyzeTests.swift:231 pins exactly that — nothing else is asserted to differ. StockSageLocalModelServer.swift:571/573 sets temperature 0.2 with no seed. So running the same ticker on both tabs the same afternoon can yield Buy on one and Hold on the other, and neither the owner nor the app can say whether that came from the horizon or from the sampler. The UI presents two segmented tabs as two questions; the engine asks approximately one question twice. This is the structural reason findings #1, #4 and #5 all matter — there is currently no input path through which a horizon could change an answer for a defensible reason.

**Evidence**

```swift
for period in [7, 14] {
    if let value = StockSageIndicators.returnOverPeriod(history.closes, period: period), value.isFinite {
        horizonFacts.append("Observed return over the last \(period) completed daily bars: \(value)%. ...")
    }
}
...
let optionalFacts = context.facts(maximumUTF8Bytes: 12_000)   // no horizon parameter
...
levels(history: history, action: verdict.action, at: Date())  // no horizon parameter
```

**Proposal**

Two honest options, not mutually exclusive. (a) Give the horizons real differing inputs — findings #1 and #4 are the two cheapest, both computed from data already in hand. (b) Until then, state the limitation where the owner chooses: one caption under the horizon picker (StockSageResearchModesPanel.swift:85–91) saying plainly that the two runs differ in the requested holding period stated to the model and in the review date, and that the underlying evidence and the entry/stop/target are the same — so a differing verdict between tabs is not itself evidence of a horizon effect. Option (b) is ~5 lines and removes an implicit claim the code cannot back.

#### Entry/stop/target are identical across horizons with no check that the target is reachable inside the horizon's day budget  _(not explicitly listed as kept — confirm before acting)_

- **Where:** `StockSage/Sources/StockSage/StockSageHorizonResearch.swift:226`
- **Confidence:** high  ·  **Est. effort:** ~20 lines
- **Owner impact:** StockSageAdvisor.stopTarget (Advisor.swift:500–521) has no time dimension at all: target = entry + 2 × (k × ATR), so for a 2.5× stop the target sits 5 ATR-days of net drift away. On the 1–7 trading-day card that target has at most 7 sessions to be reached; on the 7–14 card it has 14. The owner sees the identical entry/stop/target number on both tabs, with only a prose hedge to tell him they mean different things. The app already holds every input needed to quantify the gap — ATR is computed three lines above, and StockSageExpectedValue.typicalDailyMove / expectedHoldDays (ExpectedValue.swift:147–165) exist for exactly this arithmetic.

**Evidence**

```swift
nonisolated static func levels(history: StockSagePriceHistory, action: TradeAdvice.Action, at now: Date) -> Levels? {
    ...
    let pair = StockSageAdvisor.stopTarget(action: action, price: entry, atr: atr, realizedVol: vol)
    ...
    basis: "\(StockSageAdvisor.stopMultiple(forVol: vol))× daily ATR stop; target = twice the entry-to-stop distance. Existing rules, not horizon-optimized or a forecast. ..."
```

**Proposal**

Append one computed clause to Levels.basis (and pass `horizon` into levels(), which currently ignores it): "Target sits ≈N× the daily ATR above entry; at this name's recent average daily range that is ≈M sessions — [inside / beyond] the requested 1–7 (or 7–14) trading-day window." It is division, not a forecast, and it is the kind of disclosure the file's existing basis string is already reaching for. Do NOT change the stop/target numbers themselves — that would be a ranking/sizing change needing empirical validation the engine does not have.

#### Both horizons are measured from the same day-1 open to a single endpoint close, so nothing stored can distinguish a week-1 mover from a week-2 mover

- **Where:** `StockSage/Sources/StockSage/StockSageResearchHistory.swift:395`
- **Confidence:** high  ·  **Est. effort:** ~45 lines
- **Owner impact:** benchmarkDay(after:) (:301) is the next trading day for BOTH horizons, and targetClose is a single point at close 7 or close 14. So the fortnight measurement fully contains the week measurement, and only endpoints are kept. A 7–14 pick that peaked on day 3 and gave it all back records identically to one that never moved; a 1–7 pick that hit its target on day 2 and reverted records as a miss. If the owner ever asks the only question that would justify two windows — "do my 7–14 calls actually need the second week, or is the move over by day 5?" — the stored data cannot answer it, and never will under the current schema. The run labels "1–7 trading days" / "7–14 trading days" (HistoryView:29, :94, :214, :335) read as ranges over a measurement that is a point.

**Evidence**

```swift
let baseline = history.opens[baselineIndex]
let targetPrice = history.closes[targetIndex]
let change = targetPrice / baseline - 1
...
note: "Price direction from the next trading day's daily open to the target day's daily close, on the same split-adjusted basis. ..."
```

**Proposal**

fetchReviewObservation (HorizonResearch.swift:149–176) already downloads the full daily bar range from the benchmark day to the target day — the interim sessions are in memory and then dropped. Store two extra Codable fields on Evaluation computed from bars already validated in the existing loop: the close at trading day 7 (for fortnight runs) and the max-favorable and max-adverse close within the window. No extra request, no extra provider surface, no change to the existing endpoint return or to any displayed verdict. Then the two horizons' picks become genuinely comparable and the "range" label becomes true. Codable migration needs care (optional fields, existing saved runs must still decode) — that, not the math, is where the ~40 lines go.

#### There is no horizon AppStorage key at all; the only persisted horizon-shaped setting drives a different subsystem and is permanently ~12 days  _(not explicitly listed as kept — confirm before acting)_

- **Where:** `StockSage/Sources/Views/MarketsView.swift:27`
- **Confidence:** high  ·  **Est. effort:** ~12 lines
- **Owner impact:** The research horizon is plain @State, so it resets to "1–7 trading days" on every launch — a grep for AppStorage across Sources turns up no horizon key. The two keys that look like horizon settings (velocityCryptoHoldDays / velocityEquityHoldDays, equity default 12 per ExpectedValue.swift:34) feed EV/day velocity, the fast-lane ranking, the weekly-R headline and the time stop — none of which consult the research horizon. Net effect: whichever window the owner is working in, the ideas board is ranked on a fixed ~12-day-hold assumption, and the velocity number he is comparing names by answers a third horizon that is neither of the two on the picker.

**Evidence**

```swift
@State private var researchPresentation = StockSageResearchModesPanel.Presentation()
...
@AppStorage("velocityCryptoHoldDays") private var cryptoHoldDays = VelocityHoldDays.defaults.crypto
@AppStorage("velocityEquityHoldDays") private var equityHoldDays = VelocityHoldDays.defaults.equity
```

**Proposal**

Two small, separable moves. (1) Persist the picker with an @AppStorage key so the owner returns to the window he was working in — one line plus a rawValue-backed storage type. (2) More substantively, and worth raising before building: decide whether the research horizon should drive VelocityHoldDays at all. If yes, that changes rank order and therefore needs the empirical-validation gate; if no, the fast-lane section headers (MarketsView.swift:7327/7334, "Equity swing lane (base ~12d)") should say those are calendar-day hold assumptions independent of the research window, so the owner is not silently comparing three different horizons across one screen. The labelling half is ~4 lines and needs no gate.

### Refuted — checked and killed, with the reason

#### ~~Earnings proximity is calendar-day and horizon-blind: a 7–14 trading-day hold is told "no immediate event risk" about earnings inside its own window~~

REFUTED on two independent grounds, both checked in the shipped code.

(1) The sentence it is built around is never rendered. StockSageEarnings.swift:29 does contain "Next earnings ~N days out — no immediate event risk." but EVERY render site is gated so a .clear proximity can never reach it: MarketsView.swift:8539 and :9046 both guard `ep.isWarning` before calling earningsWarningRow (defined :4826, the only Text(ep.note) site at :4830); :5973 and :6063 guard `ep.isWarning`; the one remaining site, the chip tooltip at :5221, is inside `if visibleChips.contains(.earnings)` whose flag is `earningsBadge != nil` (:5178), and earningsWarningBadge returns nil for exactly `.clear` and `.unknown` (StockSageDecisionSnapshot.swift:104–109). `isWarning` is `severity == .imminent || severity == .soon` (StockSageEarnings.swift:20), so `.clear` is false at all five. The affirmative sentence is dead string. The honesty-floor defect the finding describes — an unknown rendered as a finding — does not occur on any surface. StockSageRiskFlags.swift:34–37 likewise emits a flag only for .imminent/.soon.

(2) The proposed fix would be a near-permanent "unknown" on the research surface. HorizonResearch.analyze passes `store.catalystChain[item.ticker]` (StockSageHorizonResearch.swift:402), and catalystChain is populated ONLY for `trackedSymbolsUnion` — board + ideas + watchlist + off-board holdings (StockSageStore.swift:342–349, refreshEarningsForTracked :2487–2491). The scan researches up to 500 activity-ranked US listings (scanLimit, :8), essentially none of which are tracked, so the earnings fact already resolves to StockSageAIAssessment.swift:67 "Earnings: not checked; date and outcome unknown." The proposed mandatory horizonFact would print the "earnings date unknown; not proof none is scheduled" branch for nearly every researched name — a restatement of a fact the prompt already carries.

A third, smaller problem: StockSageMarketHours.nasdaqDay(at:) returns nil for any year other than 2026 (StockSageMarketHours.swift:109, `guard parts.year == 2026`). From roughly mid-November 2026 a 14-trading-day window crosses into 2027 and targetClose returns nil, so the proposed window-end fact would report "unverifiable" for every fortnight run until the table is extended.

The residue worth keeping is narrow: for the handful of top-5 names the owner DOES track, the prompt gives the model a raw ISO earnings date (AIAssessment.swift:65) and never says whether it lands inside the requested window. That is a real but small gap, not the "single highest-leverage change" the summary calls it, and it cannot be the 45-line drop-in described because the window-end helper fails closed for half the calendar year.

### Reviewer notes

VERIFICATION QUALITY: unusually high. Every quoted string exists verbatim and almost every line number is exact — HorizonResearch :221, :226, :235, :374, :404, :405, :413, :441; LocalModelServer :571/:573 (temperature 0.2, `grep -n "seed"` returns nothing — the no-seed claim is confirmed by absence); ResearchHistory :301, :314, :332; HistoryView :29, :94, :214, :335; MarketsView :27, :66/:67, :3597/:3598/:3600, :7327/:7334, :7410–7424; Advisor :500–521, stopMultiple :470–476; HorizonAnalyzeTests :222–238 with the pinned assertion at :231. Only drift: ResearchHistory baseline is :391 not :395 and the evaluation note :402 not :400; MarketsView earnings penalty is :378–381 not :380. None of that changes a claim. CompoundingHorizon is confirmed unwired (one comment at ConvictionScaler.swift:23 plus its own test file).

FINDING #2 IS STRONGER THAN WRITTEN, and for a different reason. The finding argues 12 calendar days ≈ 8 trading days versus a 7–14 trading-day thesis. The sharper, self-contained defect is that the SAME stored number already means trading days everywhere else in the engine: assumedWeeklyRoundTrips divides `tradingDaysForLane` — 5 for an equity lane, 7 all-crypto (StockSageExpectedValue.swift:1127–1131) — by velocityHoldDays (:1071–1074), and expectedHoldDays is distance ÷ typical daily move where the move is per BAR (:153–163). So equityHoldDays = 12 is 12 SESSIONS in the weekly-R cadence and 12 CALENDAR days at StockSageTimeStop.swift:24. The nudge fires ~40% early against the app's own basis, not merely against the research horizon. That makes the fix a consistency repair, not a redefinition, and it makes the proposed "trading days" stepper relabel correct rather than a change of meaning. One cost the finding does not name: nasdaqDay(at:) is 2026-only (MarketHours.swift:109), so a strict trading-day count with "never silently fall back" makes the time-stop nudge disappear entirely from 2027-01-01 until the holiday table is extended. Ship it with that extension, or the nudge dies silently on New Year's Day.

FINDING #4 NEEDS A PHRASING CORRECTION BEFORE IT SHIPS. The arithmetic half is fine and honest: target distance = 2 × stopMultiple × ATR (Advisor.swift:507–516), i.e. 3–5 ATR, and saying so in Levels.basis is division, not prediction. The other half — "≈M sessions — [inside/beyond] the requested window" — asserts net one-ATR-per-session directional drift, which a single ATR cannot support, and states a binary reachability verdict the engine has no edge to back. The repo's own precedent is more careful: expectedHoldDays clamps to 0.4–3× the class base (:163) and is then Jensen-inflated by (1 + CoV²) (:175–183) and labelled "an estimate on an estimate — the UI says so" (:194). If the sessions clause ships, it must reuse that clamped, dispersion-corrected path (computable from the closes levels() already holds) and must not print an inside/beyond verdict. Effort then lands nearer 40–60 lines than 20 — still inside the 3× bar.

FINDING #6 IS TWO CLAIMS OF VERY DIFFERENT QUALITY. Part 1 is correct and trivial: `@State private var researchPresentation` (MarketsView.swift:27), and grepping AppStorage across Sources returns no horizon key, so the picker resets to "1–7 trading days" every launch. Part 2 overstates twice. "The ideas board is ranked on a fixed ~12-day-hold assumption" is wrong — expectedHoldDays computes a per-setup hold (target distance ÷ daily move, clamped 0.4–3× the anchor, then Jensen-inflated), so the effective hold spans roughly 5–36 days across ideas, and the fast-lane header already says "base ~12d" (:7334). "Silently comparing three different horizons across one screen" is also wrong: `ideas` and `research` are separate MarketSection cases (:9920), never co-rendered. Keep part 1; drop part 2's framing.

FINDING #5 IS THE MOST VALUABLE STRUCTURAL ONE AND ITS EFFORT IS IF ANYTHING OVERSTATED. Confirmed: fetchReviewObservation requests the whole benchmark→target range (HorizonResearch.swift:167–168), evaluate() walks every bar for validation (ResearchHistory.swift:369–386) and then reads only opens[baselineIndex] and closes[targetIndex] (:391–393). The interim sessions really are in memory and discarded. The Codable migration the finding calls the expensive part is nearly free — Evaluation already carries `var calendarBasis = ...` with a default (:71), and Swift's synthesized decoder falls back to defaults for missing keys, so optional `var` additions decode old runs unchanged and Document.version needs no bump. Restrict the new fields to CLOSES (as proposed) — max-favorable/adverse from highs/lows would smuggle in an intraday reachability claim the daily bar cannot support.

FINDING #3 IS THE BEST VALUE-PER-LINE IN THE SET and every premise checks out. Both horizons get both the 7- and 14-bar returns (:405–409); context.facts takes no horizon (AIAssessment.swift:37); levels() takes no horizon (:226) and is called without one (:441); the only differentiators are Horizon.instructions (:19–22) and run.horizon's review date. HorizonAnalyzeTests.swift:231–236 pins the instruction difference and asserts nothing else differs. Sampling is temperature 0.2 with no seed. So the segmented picker presents two questions the engine asks approximately once, and a Buy/Hold split across tabs is indistinguishable from sampler noise. Option (b)'s caption is ~5 lines, needs no gate, and removes an implicit claim the code cannot back — the exact shape of the 2026-09-11/12 fixes in the log ("Stop a failed SEC fetch printing as 'we checked, nothing was filed'", "Say which qualified ideas the heat cap never funded"). Ship it before anything else here.

WHAT IS GENUINELY ALREADY GOOD, re-verified: targetClose/benchmarkDay count real Nasdaq closes and return nil rather than guessing (:301–328); reviewAvailableAt waits out the whole New York target date (:332–335); analyze() refuses below 30 completed bars including the latest prior session (:221, :374) with a reason string on every refusal path; Levels.basis already discloses that the levels are not horizon-optimized (:235); the evaluation note refuses to call the measured return profit or a win probability (:402). The finding set's read of these is accurate — nothing to fix in them.

---

## Output honesty and usefulness

The scan-side surfaces are in good shape: StockSageResearchModesPanel separates "checked" from "incomplete" from "not checked", distinguishes five different empty states, splits machine receipts from human explanations, and prints an explicit warning when a Buy has no calculable plan. I found no place in the research panel where a failed check renders as a completed one. The weaknesses are on the two ends of the loop. (1) The REVIEW surface — the only feedback the owner ever gets about whether this research works — scores every pick against zero rather than against the market, and prints the bare phrase "Buy direction supported" for any pick that rose at all. With a measured DSR near zero and positive unconditional US drift over 7 and 14 trading days, that phrase will read positive most of the time for picks with no skill, and it is the only scoreboard in the app. (2) Outcomes, once checked, are unreachable: the home research card has no outcome field at all, so after a check the owner sees "No predictions ready to check." and nothing about what happened. Secondary: the insider row on the idea sheet renders NOTHING on failure (including the deliberate Form 4/A suppression) while the Benzinga block right beneath it says "not captured"; and the Benzinga panel hands the owner the model's raw prompt tokens for nine products while withholding the eligibility split the code itself says was added because collapsing it caused two wrong diagnoses.

### Already good — do not "fix" these

- StockSageResearchModesPanel.swift:356-376 — scanProgress refuses the "we checked" reading out loud: "\(checked)/\(total) checks finished, including incomplete" plus separate "incomplete" and "not checked" counts, with help text "Checks finished includes incomplete opinions; it does not mean every answer passed validation." This is the single best line in the surface.
- StockSageResearchModesPanel.swift:449-466 — emptyState distinguishes five genuinely different nothings: search-filtered, "Waiting for Buy / Strong Buy results" (running), "The collected checks contain no Buy / Strong Buy opinions" (finished), "No results collected" (ran but failed), and the untouched state. None of them reads as a completed negative check.
- StockSageResearchModesPanel.swift:548-551 — a Buy verdict with no calculable levels prints "No valid ATR-based entry/stop/target plan could be calculated. Do not treat this opinion as an order plan." rather than silently omitting the plan rows.
- StockSageResearchModesPanel.swift:487-510 — notePresentation splits the machine receipt (validation=/server=) from the human explanation and files it under "Technical details", and explicitly re-promotes the context-budget omission warning into the human half.
- MarketsView.swift:6697-6699 — disclosureRow renders nothing on an empty 8-K list, with the reason written down: "an empty result means 'nothing found in the window we looked at', not 'nothing was filed', so printing 'no filings' would state a fact this app cannot establish."
- MarketsView.swift:9743-9750 with StockSageAIAssessment.swift:468-474 — the AI badge's no-record fallback is `.avoid`, but `actionColorForTest(.avoid)` is `Color.white.opacity(0.22)`, a neutral chip. "AI not assessed" is therefore not painted as a negative verdict.
- StockSageResearchHistory.swift:437-472 — recordEvaluation refuses to persist an outcome whose own numbers do not reconcile (`change == targetPrice / baseline - 1`, direction re-derived, buyDirectionSupported re-derived), and line 173 stops a failed retry from erasing an already-observed outcome.
- StockSageResearchHistory.swift:387 — evaluate refuses to substitute an adjacent bar for a missing benchmark or target session: "The next trading-date benchmark or the exact target session is missing; no adjacent bar is substituted." Line 401 keeps flat out of the support count entirely.
- StockSageBenzinga.swift:311-325 — the projection's state machine checks obsolete credential, bad clock and bad query BEFORE reporting a record count, so a stale or mismatched capture can never present as coverage.

### Verified findings

#### The saved-research scoreboard grades every pick against zero, never against the market

- **Where:** `StockSage/Sources/Views/StockSageResearchHistoryView.swift:343`
- **Confidence:** high  ·  **Est. effort:** ~180 lines
- **Owner impact:** This is the only place in the app that ever tells the owner whether the research works, and it is graded against a zero threshold. Over 1-7 and 7-14 trading days the unconditional US drift is positive, so a set of Buy picks with no skill whatsoever will collect "Buy direction supported" in the majority of reviews. A pick that rose 3.4% while the Nasdaq rose 4.5% is printed in title3 bold as "Rose · 3.40% / Buy direction supported" — a loss to the market, presented as a hit. Over a few months of runs the owner is reading an accumulating record of green phrases from an engine whose measured Deflated Sharpe is about zero. The note is scrupulous about four other things it is not ("not realized trading profit or a win probability", excludes dividends/fees/costs) and silent about the one that matters most here: it is not compared to anything.

**Evidence**

```swift
Text(direction == .flat ? "Flat · unchanged" :
    "\(direction == .rose ? "Rose" : "Fell") · \(change.formatted(.percent.precision(.fractionLength(2))))")
    .font(.title3.weight(.semibold))
Text(direction == .flat ? "No directional support" :
    (evaluation.buyDirectionSupported == true ? "Buy direction supported" : "Buy direction not supported"))

// and the receipt it renders, StockSageResearchHistory.swift:395-402:
let direction: Evaluation.Direction = targetPrice == baseline ? .flat : (targetPrice > baseline ? .rose : .fell)
let isBuy = prediction.action == "Buy" || prediction.action == "Strong Buy"
... buyDirectionSupported: isBuy && direction != .flat ? direction == .rose : nil,
note: "... Excludes dividends, fees and execution costs; not realized trading profit or a win probability."
```

**Proposal**

Two sizes, and the small one should land regardless. SMALL (~12 lines, view + note only): stop the bare phrase standing alone — render "Buy direction supported vs a zero threshold — not vs the market" and add "No market or sector benchmark is applied; a rise smaller than the index is still printed as support." to the evaluate() note at StockSageResearchHistory.swift:402. That removes the false read without touching persistence. FULL (~150-200 lines incl. tests): fetch one benchmark series per RUN over the identical [benchmarkDay, targetClose] window using the request builder that already exists — StockSageHorizonResearch.dailyHistoryRequest(symbol: "QQQ", …) passes validTicker and parseResearchHistory unchanged, so this needs no new endpoint, no new entitlement, and no EODHD. Add benchmarkSymbol/benchmarkReferencePrice/benchmarkTargetPrice/benchmarkReturn to Evaluation with defaults so existing receipts still decode, extend valid(_:run:) to re-derive benchmarkReturn the same way it already re-derives priceReturn, and render "QQQ over the same window: +4.10% — this pick underperformed by 0.70pt". Note explicitly for the reviewer: this is a SCORECARD DENOMINATOR, not a signal — it must not be wired into advise()/conviction/ranking, which is the thing StockSageRelativeStrength.swift:5-18 ablated to DSR=0 and left unwired.

#### Once an outcome is checked it vanishes: the home research card has no outcome field at all

- **Where:** `StockSage/Sources/Views/StockSageResearchHistoryView.swift:44`
- **Confidence:** high  ·  **Est. effort:** ~60 lines
- **Owner impact:** pendingPredictions (StockSageResearchHistory.swift:189-191) filters out anything evaluated, so the moment the owner does the work of checking a prediction it leaves "Ready for review" and appears nowhere on the home card. After checking everything, the research home reads "No predictions ready to check." — which is literally true and reads as "nothing to see". The result is that the engine's entire feedback loop lives three interactions deep (Saved research → tap a run → scroll to each prediction section) and has no aggregate anywhere; buyDirectionSupported is read in exactly one place in the whole codebase, StockSageResearchHistoryView.swift:348. Meanwhile horizonSection keeps showing the latest run's five picks with their original reasons and no outcome, so a pick that already fell 8% renders identically to one that has never been checked — next to a Research button inviting a new scan.

**Evidence**

```swift
} else {
    Text("No predictions ready to check.").font(.headline)
}

// horizonSection, same file:106-121 — the latest run's picks, with no outcome:
Text("\(index + 1). \(prediction.symbol) · \(prediction.action)")
Text(prediction.name).font(.callout)
Text(prediction.reason).font(.callout).foregroundStyle(.secondary).lineLimit(2)
...
Text("\(run.coverage.checked) listings checked · \(run.coverage.incomplete) incomplete opinions")

// HomeSummary, StockSageResearchHistory.swift:179-187 — every field is about work NOT yet done:
var latest, ready: [Run]; var readyPredictions, waitingPredictions, unavailablePredictions, completedToday = 0; var nextReviewAt: Date?
```

**Proposal**

Add evaluated counts to HomeSummary (evaluatedPredictions, supported, notSupported, flat) — the loop at StockSageResearchHistory.swift:201-220 already visits every run and has the evaluations in hand, so this is a case addition to the existing switch plus four counters. On the card, print one line under "Ready for review" — e.g. "18 checked so far: 10 rose, 6 fell, 2 flat" — with no hit-rate percentage and no win-probability framing, and (paired with finding 1) no support tally until the benchmark exists. In horizonSection, append the checked outcome to each pick row when run.evaluations[prediction.symbol]?.state == .evaluated. ~60 lines plus a homeSummary test in the existing StockSageResearchHistoryTests style.

#### insiderRow() has no else: a failed — or deliberately withheld — insider check renders as nothing at all

- **Where:** `StockSage/Sources/Views/MarketsView.swift:6610`
- **Confidence:** high  ·  **Est. effort:** ~50 lines
- **Owner impact:** recentActivity returns nil for at least five distinct reasons — web access denied, CIK lookup failed, the SEC fetch failed, malformed JSON, and the deliberate Form 4/A suppression — and IdeaDetailEvidence.swift:59 skips the check entirely for any symbol containing a dot. All six collapse into the same pixels: no insider row. The last case is the sharp one: a name where insiders traded and then AMENDED the filing is exactly a name the owner would want flagged, and it renders identically to a card that simply has no insider section. Because the success-with-nothing case does print an explicit sentence ("no open-market share trades in the reviewed filings"), the owner learns to read the row's presence as meaningful — and then reads its absence as "nothing here" rather than "we could not check". The Benzinga block immediately beneath it sets the correct precedent and makes the omission look like an oversight rather than a policy.

**Evidence**

```swift
@ViewBuilder private func insiderRow() -> some View {
    if detailEvidence.insiderLoading {
        Text("Checking SEC filings…")...
    } else if let s = detailEvidence.insiderSummary {
        ... "Insiders: no open-market share trades in the reviewed filings."
    }
}
// no else — and StockSageInsider.swift:194 returns nil ON PURPOSE:
// "An amendment can replace an earlier trade, not add another one. The bounded
//  summary cannot reconcile replacements yet; do not publish the original net."
guard !form4Window.contains(where: { $0.0 == "4/A" }) else { return nil }
// while the Benzinga block 4 lines below it, MarketsView.swift:8657-8660, DOES say so:
} else {
    Text("Benzinga evidence not captured for this detail selection.")
```

**Proposal**

Floor (~8 lines): add the missing else to insiderRow with a truthful generic — "Insider filings were not checked, or could not be summarised for this symbol." That alone closes the silent-failure gap and matches the Benzinga sibling at 8657. Better (~50 lines): give the service a reason. Return an enum from recentActivity (case summary(Summary) / case amended / case unavailable(String)) so the amendment branch at StockSageInsider.swift:194 can surface as "A Form 4 amendment is in the reviewed window; the net insider figure is withheld rather than restated" and a policy/transport failure as "SEC filings were not reachable for this check." The dot-symbol skip at IdeaDetailEvidence.swift:59 should map to its own line too.

#### The Benzinga panel shows the model the eligibility split and shows the owner the collapsed number

- **Where:** `StockSage/Sources/Views/StockSageBenzingaEvidenceView.swift:173`
- **Confidence:** high  ·  **Est. effort:** ~10 lines
- **Owner impact:** The fix landed on 2026-09-11 for the prompt and not for the panel. Projection exposes notEligibleCount, cappedRecordCount and trimmedRecordCount; the view renders none of them and prints only the collapsed omittedRecordCount behind the vague phrase "capture/display bounds". So the owner reading the idea sheet sits with exactly the ambiguity the comment says caused two wrong diagnoses in a single session: "Ratings: partial" plus "4 records omitted" could mean four analyst actions were dropped as older than the 45-day evidence window, or that four fit nowhere in the byte budget. Those call for opposite responses — one means there genuinely is no fresh coverage, the other means the capture is being starved. The per-page counts are technically reachable (checkLabel at line 214 prints "N retained, M excluded") but they are inside a collapsed DisclosureGroup and the word "excluded" carries no reason.

**Evidence**

```swift
if projection.omittedRecordCount > 0 {
    Text("\(projection.omittedRecordCount) records omitted by capture/display bounds.")
}

// what the MODEL's copy carries, StockSageBenzinga.swift:219-221:
"Omitted records: \(omittedRecordCount)",
"Not eligible at capture: \(notEligibleCount) (recency window or no rating change); "
+ "capped per product: \(cappedRecordCount); trimmed to fit: \(trimmedRecordCount)."

// and why that split exists at all, StockSageBenzinga.swift:207-211:
/// Added 2026-09-11 because collapsing this into `omittedRecordCount` made "no recent
/// analyst action" indistinguishable from "we could not fit it", and that ambiguity
/// produced two wrong diagnoses in one session.
```

**Proposal**

Render the split the Projection already computes. Replace the single line at 173-175 with the three buckets in owner words — e.g. "6 provider records were not eligible (outside the recency window, or no rating change) · 2 capped at three per product · 1 trimmed to fit" — reusing projection.notEligibleCount / cappedRecordCount / trimmedRecordCount verbatim, and suppress each clause at zero. Do NOT change Projection.text: that string is the model's contract and is pinned by tests. View-side only, ~10 lines.

#### In the research detail, the entire Benzinga status block is buried as one unformatted "F7:" blob

- **Where:** `StockSage/Sources/Views/StockSageResearchModesPanel.swift:552`
- **Confidence:** medium  ·  **Est. effort:** ~25 lines
- **Owner impact:** The idea sheet gets StockSageBenzingaEvidenceView — a formatted panel with per-product status, source links and capture time. The research surface, which is the one the owner is told to use for 1-7 and 7-14 trading-day decisions, gets the same information as a single multi-line string wedged between "F6:" and "F8:" inside a collapsed disclosure at caption size, with no links. During a 500-symbol scan the Benzinga client is the most likely thing to throttle, so a Strong Buy assembled from price history alone and one assembled with earnings, analyst ratings and guidance are distinguishable only by carefully reading a wall of raw prompt text. Credit where due: the evidence genuinely IS present and nothing is fabricated — this is a legibility failure, not an honesty one. But burying it has the same practical effect as hiding it, because nobody reads it.

**Evidence**

```swift
if !result.facts.isEmpty {
    DisclosureGroup("Evidence captured \(result.at.formatted(date: .abbreviated, time: .shortened))") {
        Text("Model: \(result.model.isEmpty ? "no verified model answer" : result.model) · References: \(result.verdict?.evidence.joined(separator: ", ") ?? "none")")
        ForEach(Array(result.facts.enumerated()), id: \.offset) { index, fact in Text("F\(index + 1): \(fact)") }
    }.font(.caption)
}
// one of those facts is the whole projection — StockSageAIAssessment.swift:92: result.append(projection.text)
// i.e. a ~25-line blob beginning "Massive/Benzinga sample; unverified claims, not execution prices."
```

**Proposal**

In resultDetail, detect the projection fact (it is the one starting with the fixed header "Massive/Benzinga sample; unverified claims") and render it through the same presenter finding 5 introduces, above the F-list rather than inside it — so the research detail leads with "Earnings: 1 of 3 shown · Ratings: rate limited · Guidance: checked, nothing returned" and the raw F-lines stay underneath for audit. The cheapest honest version is smaller still: add a one-line summary to the DisclosureGroup label so the owner knows whether provider evidence reached this verdict without expanding it. ~25 lines; the exact shape depends on how finding 5 is resolved, which is why I rate this medium.

### Refuted — checked and killed, with the reason

#### ~~The owner is shown the model's raw prompt tokens for nine Benzinga products, five of which can never say anything~~

The premise checks out (StockSageBenzinga.Product has exactly 9 cases with those labels, StockSageBenzingaEvidenceView renders projection.statusLines verbatim at its line ~20-22 — NOT line 162, the file is 99 lines long), but the load-bearing half of the proposal breaks the honesty floor. It asks to "hide analysts/firms when their state is 'unchecked'". "unchecked" is the ONLY place the owner learns those two metadata lookups were never attempted; deleting the line makes a not-checked render as nothing — the exact defect this same report raises as finding 3 about insiderRow(), and the exact thing the file's own statusLabel() preserves by giving .notChecked an explicit string ("Not checked") rather than dropping it. The finding also mis-frames "unchecked" as "permanent noise": analysts/firms are keyed on benzinga_id (Product.metadata == true), so "unchecked" there is a real state that varies per capture, not a fixed subscription wall. The salvageable half — one grouped line for entitlement-denied products, and plain wording that separates a permanent entitlement wall from a transient "throttled" — needs no hiding and belongs inside finding 4's view-side presenter, which is where I folded it. Kept separately it would also double-count effort with findings 4 and 6, which all propose the same presenter.

### Reviewer notes

VERIFICATION SUMMARY. Five of six findings survive; one is refuted. Every quoted snippet exists in the tree and says what is claimed. The report's citation hygiene is good for StockSageResearchHistory*.swift, StockSageResearchModesPanel.swift and MarketsView.swift (6610, 8657-8658, 9743-9750 all exact), and systematically wrong for StockSageBenzingaEvidenceView.swift: that file is 99 lines and the finding cites 162, 173-175 and 214. The code is at ~20-22 (statusLines ForEach), ~31-33 (omittedRecordCount line) and 67 (checkLabel). Substance unaffected; line numbers must be corrected before anyone edits.

I also confirmed all nine "already good" claims. They hold, including the two that matter most for calibration: scanProgress (StockSageResearchModesPanel.swift:356-376) and evaluate()'s refusal to substitute an adjacent bar (StockSageResearchHistory.swift:387-390).

=== TOP 3, with what changed under verification ===

1) BENCHMARK-LESS SCOREBOARD — StockSageResearchHistoryView.swift:343-348, receipt at StockSageResearchHistory.swift:395-402. CONFIRMED, and stronger than the report knew: `buyDirectionSupported` is read in exactly ONE place in the whole tree (that line 348); everything else is the model or its tests. So this single string IS the engine's entire feedback surface. The zero threshold is real — `direction = targetPrice == baseline ? .flat : (targetPrice > baseline ? .rose : .fell)`, and the note at line 402 disclaims four things and not the absence of a comparator.
TRIMMED CLAIM: "a set of Buy picks with no skill will collect 'Buy direction supported' in the MAJORITY of reviews" is overstated and not measurable from this code. Individual-stock cross-sections are right-skewed; the median 7-trading-day return of a random US name sits near or just under zero even when the mean is positive. Do not ship that sentence as a justification. The defect stands without it: a pick that rose 3.4% while QQQ rose 4.5% is printed in title3 bold as support, and nothing on screen says what it was compared against.
FEASIBILITY CONFIRMED: StockSageHorizonResearch.dailyHistoryRequest(symbol:from:to:key:) exists at :112, "QQQ" passes validTicker (^[A-Z][A-Z0-9.-]{0,31}$) at :106, and it targets StockSageMassive.host with adjusted=true. No new endpoint, no new entitlement, no EODHD anywhere near it.
TEST-SAFETY CONFIRMED (this is the reason the SMALL fix can land today): StockSageIOSPresentationTests.swift:167 asserts `reveal(labelContaining: "Buy direction supported")` and :182 asserts the flat/not-due case does NOT contain that substring. Appending a suffix ("… vs a zero threshold — not vs the market") keeps :167 passing and cannot trip :182, because "Buy direction not supported" does not contain the contiguous substring. Any rewording that breaks the prefix WILL fail a pinned snapshot test.
ONE CAVEAT ON THE FULL VERSION: checkDue's fetch closure is `(Prediction, Run) -> Observation?` and evaluate() hard-requires `history.symbol == prediction.symbol`, so a benchmark series cannot ride the existing Observation — it needs its own per-run fetch and its own validation branch in valid(_:run:). 150-200 lines is still the right order of magnitude, but it is not a small edit and the benchmark must fail closed (absent benchmark → print nothing, never a zero).

2) insiderRow() SILENT nil — MarketsView.swift:6610-6613. CONFIRMED exactly. No else branch. StockSageInsider.swift:194 `guard !form4Window.contains(where: { $0.0 == "4/A" }) else { return nil }` with the comment verbatim as quoted. IdeaDetailEvidence.swift:59 `guard !symbol.contains("."), isCurrent() else { return }` — dot symbols never even set insiderLoading, so they render nothing too. The Benzinga sibling four lines below at MarketsView.swift:8657-8658 does print "Benzinga evidence not captured for this detail selection.", so the precedent and the asymmetry are both real. This is the one unambiguous honesty-floor VIOLATION in the set — "we could not check" rendering as "nothing here" — and the 8-line floor fix is the highest value-per-line change in the whole report. The 50-line "give the service a reason" version is nearer 80-100 with tests (it changes the InsiderFetch typealias in IdeaDetailEvidence and every call site), still inside 3x.
UNRELATED BUG SPOTTED WHILE VERIFYING, worth a separate ticket: IdeaDetailEvidence.loadInsider sets `insiderLoading = true`, then `guard isCurrent() else { return }` after the await — on a stale generation it returns without clearing the flag, leaving the row stuck on "Checking SEC filings…" forever. Same shape at loadFilings.

3) BENZINGA ELIGIBILITY SPLIT WITHHELD FROM THE OWNER — StockSageBenzingaEvidenceView.swift ~31-33 (cited as 173). CONFIRMED. Projection exposes notEligibleCount, cappedRecordCount and trimmedRecordCount (StockSageBenzinga.swift:206-215); the view renders only the collapsed omittedRecordCount behind "capture/display bounds"; the model's copy gets the full split (:219-221); and the comment at :207-211 is verbatim as quoted, including "produced two wrong diagnoses in one session". View-only, ~10 lines, Projection.text untouched.
TWO WORDING CORRECTIONS THE PROPOSAL MUST TAKE, or it re-commits the sin it is fixing:
  (a) cappedRecordCount IS exactly the 3-per-product cap — verified through Snapshot.init at StockSageBenzinga.swift:157-168 — so "capped at three per product" is accurate. Keep it.
  (b) trimmedRecordCount is NOT purely "trimmed to fit". It is `max(0, omittedRecordCount - cappedRecordCount)` where omittedRecordCount adds `max(0, total - selected.count)` and `total` is summed over ALL snapshot.pages including pages the projection rejected as unusable (obsolete credential, bad clock, wrong symbol — the usable() filter at :300-306). So records dropped for a stale capture land in the "trimmed to fit" bucket. Render that clause as "N not sent in this request" and not "trimmed to fit", or the panel prints a cause the input cannot support. The same looseness already exists in the model prompt; surfacing it to the owner in owner-words is what makes it matter.
  (c) notEligibleCount is the sum of page.excludedCount, which per parse() at :262-270 counts malformed/unparseable rows alongside recency-window and no-rating-change rejects. "(outside the recency window, or no rating change)" is the code's own phrasing but is incomplete; add "or unreadable".

=== THE TWO SURVIVORS I RANKED BELOW THE TOP THREE ===

4) HOME CARD HAS NO OUTCOME FIELD — StockSageResearchHistoryView.swift:44 and 106-121, HomeSummary at StockSageResearchHistory.swift:178-186. CONFIRMED: every HomeSummary field is about work not yet done, horizonSection prints picks with no outcome, and homeSummary's `guard pending > 0 else { continue }` drops a fully-evaluated run out of the card entirely.
TITLE OVERSTATED: outcomes are not "unreachable". Each pick in horizonSection is a Button that sets selectedRun and opens StockSageResearchHistoryDetail, which renders outcome(receipt) inline per prediction (lines 309-315). That is ONE tap from the home card, not three interactions. The accurate defect is narrower and still worth fixing: the card itself carries no outcome and there is no aggregate anywhere in the app.
IMPLEMENTATION SKETCH IS WRONG: "a case addition to the existing switch" does not work. The switch is over `availability(for:run:now:).state`, which only ever returns notDue/due/dataUnavailable — `.evaluated` is dead there — and the `guard pending > 0` above it already skipped every fully-checked run. Counting evaluated predictions means adding a counter ABOVE that guard, reading run.evaluations directly. Still cheap; ~60 lines is fine. Keep the proposal's discipline of printing raw counts with no hit-rate and no support tally until a benchmark exists.

5) BENZINGA STATUS BURIED AS AN F-LINE IN THE RESEARCH DETAIL — StockSageResearchModesPanel.swift:552-557. CONFIRMED, and the chain holds: StockSageAIAssessment.swift ~88-92 appends projection.text into the fact list, StockSageHorizonResearch.swift:403+413 feeds that into result.facts.
ONE THING THE FINDING MISSED, which the implementation must handle: the projection fact is OPTIONAL and can be dropped wholesale by StockSageAIAssessment.fittedResearchPrompt (StockSageHorizonResearch.swift:413-421). So "no projection fact present" has two causes — trimmed to fit, or never captured — and a presenter that renders nothing, or renders "checked, nothing returned", on absence would manufacture exactly the confusion finding 3 is about. The panel does already re-promote the omission count into the human half (notePresentation:505-509), which is a partial mitigation but never says WHICH records went. Correctly rated medium; its dependency on the refuted finding 5's presenter is another reason to land findings 4 then 5 in that order.

=== CHECKED AND FOUND CLEAN ===
No finding proposes EODHD or any live fallback. No finding implies a forecast is reliable. No finding would break a pinned test as long as finding 1's rewording keeps the "Buy direction supported" prefix intact. No effort estimate is off by more than ~2x.

---

## Cost, latency and caching

One "Run" of a horizon scan costs, per symbol: 1 paid Massive 1-year daily-aggregate call, 7 paid Benzinga product calls plus up to 6 analyst/firm metadata calls, up to 1 more paid Massive /v2/reference/news fallback, and 1–2 local Qwen calls at 16,384 context. Times 500 names that is roughly 500 history calls + 3,500 Benzinga base calls + up to 3,000 metadata calls + up to 500 news-fallback calls, before the run pays for the full US ticker directory again (≈12 paginated reference calls, never cached). The loop is strictly sequential (StockSageHorizonResearch.swift:261), so with the two model latencies actually recorded in HANDOFF.md (WM 10.680 s, SPOT 15.653 s) the model alone is ~1.5–2.2 hours of wall clock per horizon — matching HANDOFF's own "Thousands of checks can take hours" and its live observations at 2/500, 87/500, 187/500 and 277/500. All of that spend surfaces exactly five names (topBuyLimit = 5), and the saved run keeps only those five as predictions (StockSageResearchHistory.swift:124). The engineering underneath is good: single-flight dedup, a 3-slot concurrency cap, Retry-After cooldown, an LRU cache, batched 250-ticker snapshots, one grouped-daily call instead of 500 quote calls, and a real same-UTC-day disk history cache. The problem is that almost none of the caching is wired into the research path, and the cache that is wired is sized for the ideas board, not for a 500-name scan. Running both horizons — which is the owner's actual workflow, and the only two horizons that matter — doubles every one of these numbers because the evidence pass is re-done per horizon even though nothing in it is horizon-dependent.

### Already good — do not "fix" these

- Universe selection uses ONE grouped daily-market-summary call to rank 500 names by volume × VWAP (StockSageResearchUniverse.swift:72-78), instead of 500 per-symbol quote calls. The previous-session fallback only fires when eligibleCount < 500 (line 141), so it is not a blind second fetch.
- StockSageMassive.maxTickersPerRequest = 250 with the vendor cap actually cited in the comment (StockSageMassive.swift:97-108): 872 names become 4 requests, not 872.
- StockSageBenzingaClient's transport plumbing is genuinely well built: single-flight dedup by RequestKey, a hard 3-concurrent cap (line 255), a global Retry-After cooldown that survives key/policy toggles (line 129), an epoch that invalidates the whole cache when credentials change, and cache-key compatibility checks so a wider window cannot silently serve a narrower caller.
- fittedResearchPrompt packs evidence to the model's real 16,384-token allowance rather than a hardcoded byte cap, and reports exactly how many optional records were dropped (StockSageHorizonResearch.swift:416-424) — it neither over-sends nor silently truncates.
- The evidence-currency gate between the Benzinga fetch and the news fetch (StockSageHorizonResearch.swift:386-396, with the comment explaining why the two seams stay separate) means a revoked key stops the second paid call instead of paying for it.
- StockSageHistoryCache + StockSageScanChunking.partitionByCacheFreshness/isCacheFreshForToday already implement correct same-UTC-day reuse with a non-shrink serialized writer and an honest staleness rule. The primitive is right; it is just not connected to research.
- The 192-token output budget (researchOutputTokens) keeps per-call generation short — the dominant model cost here is prefill of a ~12 KB prompt, not generation, so this is the right knob already set correctly.

### Verified findings

#### Research refetches a full year of daily bars per symbol although the same-day cache primitive already exists

- **Where:** `StockSage/Sources/StockSage/StockSageHorizonResearch.swift:370`
- **Confidence:** high  ·  **Est. effort:** ~70 lines
- **Owner impact:** Every one of the 500 names gets a fresh `/v2/aggs/.../range/1/day/<1y>` request with `cachePolicy: .reloadIgnoringLocalCacheData` (line 129), and nothing is written back. Meanwhile StockSageScanChunking.partitionByCacheFreshness / isCacheFreshForToday (StockSageScanChunking.swift:76-93) and StockSageHistoryCache (253 bars — "longest active daily lookback (252 periods) plus its starting observation", exactly what a 1y research fetch needs) already do same-UTC-day reuse for the ideas board. So a second Run the same day, or the second horizon, pays 500 more identical calls for bars the app downloaded an hour ago. On a 1–14 trading-day horizon, a completed daily bar from this morning is the same completed daily bar this afternoon.

**Evidence**

```swift
guard let (data, historyResponse) = try? await historyFetch(),
      allowed(), !Task.isCancelled, (historyResponse as? HTTPURLResponse)?.statusCode == 200,
      let raw = parseResearchHistory(data, symbol: item.ticker),
      let history = completedHistory(raw, at: Date()) else {
```

**Proposal**

Load the cache once in `start`, pass `cachedHistory: StockSagePriceHistory?` into `analyze`, and only fetch when `isCacheFreshForToday` is false. Reuse is already fail-safe: `completedHistory(raw, at: Date())` rejects anything that does not end on the latest completed prior session, so a stale cache entry falls through to a fetch instead of lying. Write the fetched histories back with `saveSerialized()` so the second horizon and the ideas board both benefit. Do not touch the ideas board's own cache policy.

#### Account-level Benzinga entitlement denials are re-learned once per symbol, up to ~2,000 guaranteed-failing paid calls per run

- **Where:** `StockSage/Sources/StockSage/StockSageBenzingaClient.swift:428`
- **Confidence:** high  ·  **Est. effort:** ~35 lines
- **Owner impact:** Seven products are requested for every symbol: earnings, guidance, ratings, analystInsights, bullsBearsSay, news, consensusRatings. The owner's add-ons are Earnings, Analyst Ratings and Corporate Guidance, so the rest come back 402/403. The cache key is `.page(query)` and Query includes `subject` (the ticker), so an entitlement denial on AAPL/bullsBearsSay does nothing to stop the identical request for MSFT/bullsBearsSay — and its TTL is only 300 s anyway (StockSageBenzinga.swift:25-31). Entitlement is an account fact, not a symbol fact. With four unentitled products that is ~2,000 paid requests per horizon run, ~4,000 across both, every one of which can only ever return the same denial. Each also adds a round-trip to a scan the owner is already waiting hours on.

**Evidence**

```swift
let baseQueries = B.Product.allCases.filter { $0 != .analysts && $0 != .firms }.map { product in
    B.Query(product: product, subject: symbol, ...)
}
...
private func requestKey(_ query: B.Query) -> RequestKey {
    guard let window = window(query) else { return .page(query) }
```

**Proposal**

Add `deniedProducts: [B.Product: String]` (product → credential epoch) written on `.unauthorized`/`.entitlement`, checked in `page(for:)` before admission, and cleared by `synchronize()` on epoch change and by the existing `clearAuthorizationFailures()` (line 110). The rendered status line stays exactly what it says today ("Unavailable: entitlement"), so nothing becomes less honest — the app just stops asking 499 more times. `recheckAuthorization: true` must bypass the memo so the key field's re-check still works.

#### Running both horizons duplicates an entire evidence pass that is not horizon-dependent

- **Where:** `StockSage/Sources/StockSage/StockSageHorizonResearch.swift:346`
- **Confidence:** high  ·  **Est. effort:** ~130 lines
- **Owner impact:** Inside `analyze`, `horizon` is used in exactly two places: the first element of `horizonFacts` ("Requested holding horizon: …") and `horizon.instructions` for the system prompt. The 1-year history fetch, `buildIdeas`, the Benzinga snapshot and the news observation are all identical for week and fortnight. Both horizons are the two that matter for this owner, and HANDOFF records both being run (a 7–14 scan at 277/500, a 1–7 scan at 87/500). Because the Benzinga TTLs are 30 s (news) and 300 s (everything else) and a scan takes hours, the second horizon's cache is entirely cold: it pays the full ~500 history calls, ~3,500 Benzinga base calls, up to ~3,000 metadata calls and a second directory pagination — for byte-identical evidence.

**Evidence**

```swift
static func analyze(_ item: Listing, horizon: Horizon, store: StockSageStore,
    config: StockSageLocalModelServer.Config, isOllama: Bool, key: String,
```

**Proposal**

Let one pass gather evidence per symbol and issue two model calls against it: `analyze(item, horizons: [Horizon]) -> [Horizon: Result]`. Network spend for the both-horizons workflow halves; model time is unchanged (two calls were always going to happen). The restructure is real — `start`/`scans`/`running`/`activeSymbol` are all single-horizon shaped, and `Scan.at` and the saved-run `startedAt`/`completedAt` would now describe a shared run — so size it as a change to `start`, not a one-liner. Keep the single-horizon path working so the owner can still run just one.

#### The 500-entry LRU is flooded by per-symbol pages and evicts the only cache class a 500-name scan can actually reuse

- **Where:** `StockSage/Sources/StockSage/StockSageBenzingaClient.swift:333`
- **Confidence:** high  ·  **Est. effort:** ~25 lines
- **Owner impact:** Per-symbol product pages can never be hit twice inside one scan — each ticker is visited exactly once. The analysts and firms entries are different: their subject is an analyst/firm ID, they carry an 86,400 s TTL, and the same handful of firms cover hundreds of names, so they are the one genuinely shareable cache class. But the scan writes ~7 per-symbol entries per ticker, so the 500-slot cache fills after roughly 38 symbols and from then on every eviction is drawn from a pool dominated by write-once page entries. Analyst/firm entries that go a few dozen symbols without a hit get evicted and re-requested. With up to 3 analyst + 3 firm lookups per symbol (lines 449-453), that is up to ~2,700 avoidable paid metadata calls across the remaining 460 names.

**Evidence**

```swift
// At most 501 entries here: a linear oldest-access lookup avoids another index.
if cache.count > 500, let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key {
    cache.removeValue(forKey: oldest)
}
```

**Proposal**

Give metadata a protected budget rather than raising the global cap blindly: evict only from the non-metadata partition until the metadata partition exceeds its own cap (say 512 analyst/firm entries). Separately, revisit the 300 s TTL for earnings/guidance/ratings — on a 1–14 trading-day horizon, evidence five minutes old and evidence two hours old are the same evidence, and the Page already carries `checkedAt` and renders it, so a longer TTL does not make any surface less dated. Leave the 30 s news TTL alone.

#### Every network round-trip is serialized behind the model instead of being prefetched during it

- **Where:** `StockSage/Sources/StockSage/StockSageHorizonResearch.swift:260`
- **Confidence:** high  ·  **Est. effort:** ~60 lines
- **Owner impact:** The comment justifies one model worker, which is correct — but the history fetch, the Benzinga snapshot (3 concurrent, 12 s deadline) and the news fallback for symbol N+1 all wait until symbol N's Qwen call returns. With the model latencies actually measured and recorded in HANDOFF.md (WM 10.680 s, SPOT 15.653 s), the evidence phase for the next name would fit entirely inside the current name's inference. Today it is added on top: at ~2–4 s of evidence round-trips per symbol that is roughly 17–33 minutes of pure dead waiting per 500-name horizon, doubled if the owner runs both.

**Evidence**

```swift
// One manual worker bounds local-model load. No automatic repeat or parallel model requests.
for item in names {
    guard valid() else { throw CancellationError() }
    activeSymbol = item.ticker
```

**Proposal**

Make it a one-deep pipeline: start the evidence gather for names[i+1] before awaiting the model for names[i]. Model concurrency stays at one and provider concurrency stays at the client's existing 3 slots, so neither the local-model load nor the Massive rate posture changes. The only semantic effect is that evidence for a symbol is up to one model-call older when it reaches the prompt — `Context.canAssess` already allows 4 hours of analysis age (StockSageAIAssessment.swift:111) and `isRecentResearchPrice` still gates the price, so ~15 extra seconds is well inside the existing contract. Cancellation must tear down the in-flight prefetch, which is where the real work is.

#### One 429 buys up to ~20 full-price Qwen calls on evidence-free names that are then marked "checked"

- **Where:** `StockSage/Sources/StockSage/StockSageBenzingaClient.swift:285`
- **Confidence:** medium  ·  **Est. effort:** ~30 lines
- **Owner impact:** `retryDelay` returns 30 s with no header and up to 300 s with one. During the cooldown every Benzinga query short-circuits to `.throttled` and the Massive news fallback throws `.throttled` too (it shares `admissionFailure`, line 199). But `analyze` still proceeds: a snapshot of all-throttled pages keeps the current credential epoch, so `evidenceAllowed()` passes, and `StockSageBenzinga.projection` returns a valid Projection made only of status lines, so `context.canAssess` passes. At ~13 s per model call, a 300 s cooldown means roughly 20 symbols get a full-cost inference on price history alone, are counted toward `coverage.checked`, and — if the model returns Buy — can occupy one of the five shortlist slots on strictly thinner evidence than their neighbours.

**Evidence**

```swift
if http.statusCode == 429 {
    let until = self.now().addingTimeInterval(Self.retryDelay(
        http.value(forHTTPHeaderField: "Retry-After"), now: self.now()))
    self.cooldownUntil = max(self.cooldownUntil ?? until, until)
}
```

**Proposal**

When the Benzinga snapshot is entirely `.unavailable(.throttled)` AND the news attempt is also throttled, skip the model call and return `.init(note: "Evidence provider throttled; not checked.")`, counting the name as not-checked rather than checked-with-nothing. That is both cheaper and more honest than today's outcome, where a throttled name is indistinguishable in the coverage counters from a fully-evidenced one. Pairs naturally with a "retry throttled names" affordance, which the ideas board already has a precedent for.

### Refuted — checked and killed, with the reason

#### ~~The scan keeps paying for ~450 more names after the displayed shortlist is provably final~~

Mechanism is right, premise is not. topBuys (StockSageHorizonResearch.swift:66-70) is `(strong + buys).prefix(5)`, so a later Strong Buy DISPLACES a Buy — the shortlist is final only once strongBuy count alone reaches 5, which the proposal states correctly but then justifies with the wrong number: HANDOFF.md:313 says '97 Buy/Strong Buy', a COMBINED count. Nothing in the code or the handoff separates the two, so 'five Strong Buys are typically reached in the first tens of names' is an unknown presented as a finding — the exact shape this codebase fixed on 2026-09-11/12. Worse, the app cannot measure it even retroactively: Coverage.buyCount (StockSageResearchHistory.swift:139) lumps .buy and .strongBuy into one integer. The cost side is concrete and the saving is not: an early stop forfeits the '500/500 · 97 Buy/Strong Buy · 31 incomplete' counters the owner's own screenshot shows (HANDOFF.md:313) and requires amending record()'s documented complete-run contract ('Call only after the complete run succeeds', StockSageResearchHistory.swift:118; gate at :148 `run.coverage.checked == run.coverage.requested`). Refused as proposed; split the Strong Buy count out of buyCount first, run two scans, then re-propose on evidence.

#### ~~The full US ticker directory is re-paginated from Massive on every Run and never cached~~

The waste is real (fetchUniverse at :178 paginates every Run, .reloadIgnoringLocalCacheData at :93, no persistence) but two load-bearing claims about the code are false, and both are the honesty-cost argument. (a) 'Receipt.summary, which already prints directoryCount' — it does not: summary (StockSageResearchUniverse.swift:16-19) prints session, partialSession, eligibleCount, returnedCount and the fallback clause only. directoryCount is printed by the VIEWS — StockSageResearchModesPanel.swift:225 renders '<N> active US directory entries considered. Selection requested <timestamp>' and StockSageResearchHistoryView.swift:286 renders '<N> directory listings. Captured <timestamp>' — i.e. a cached directory would render a stale census directly beside a fresh timestamp, on the honesty floor, in two places. (b) 'the existing text already warns that failed pagination cannot certify complete coverage' — that string does not exist anywhere in StockSage/Sources (grep for 'certify' and 'complete coverage' returns nothing relevant). An honest fix therefore needs an as-of date on Receipt, on the PERSISTED SelectionReceipt Codable (StockSageResearchHistory.swift:36-44) and its validator (:429), plus both view strings — well past 65 lines. Payoff: ~12 calls out of ~7,000 per run. Worst honesty-risk-to-saving ratio in the set.

#### ~~The Benzinga 12 s deadline starts when a job is queued, so the last products requested are the ones that systematically time out~~

The arithmetic survives (deadline is stamped in Job's property initializer, StockSageBenzingaClient.swift:40, i.e. at enqueue in wait() :226-227, while drain() only runs 3 at a time :255), but two of its stated impacts are wrong and the third is moot. (a) 'the metadata wave, which runs after the base wave, is even more exposed' is false: metadata Jobs are constructed only after the base snapshot returns (:449-454), so they stamp FRESH 12-second deadlines — at most 6 queries over 2 waves, strictly less exposed than the base wave. (b) 'the SAME products lose every time' is not established: pages() enqueues through a withTaskGroup (:462-474) whose child start order is unspecified, so FIFO by Product.allCases is an assumption, not a fact. (c) If the entitlement memo lands, the base wave drops from 7 queries to 3 — one wave, no queue wait — and this disappears without touching Job/drain. Keep it as the measurement the finding itself asks for, not as a fix. One thing the finding missed and should have led with: drain() at :261-262 finishes a job as `.timedOut` BEFORE the request is ever sent, and that renders as 'timed out' — a provider failure tag for a call that was never made.

### Reviewer notes

VERIFICATION BASE. Every code citation in the surviving findings checks out against the tree at /Users/saleh/StockSage-wt/opus-harness. Line numbers are within a few lines everywhere (analyze is :350 not :346; the history request's cachePolicy is :124 not :129). Every HANDOFF number the findings lean on is real: WM 10.680 s / SPOT 15.653 s (HANDOFF.md:317), 500/500 + 97 Buy/Strong Buy + 31 incomplete (:313), 2/500 (:403), 87/500 (:1559), 187/500 (:439), ~277/500 (:74), "Thousands of checks can take hours" (:1629). No finding proposes EODHD. No finding implies a forecast is reliable. The "what is already good" list is accurate (StockSageMassive.swift:100-104 for the 250 cap, drain's 3-slot cap at :255, the cooldown-survives-toggles comment at :129, the evidence-currency seam at :385-396, researchOutputTokens = 192 at :12).

WHY THE TOP THREE, IN THAT ORDER.

#1 entitlement memo. Confirmed exactly: snapshot() issues all 7 non-metadata products per symbol (StockSageBenzingaClient.swift:428-432); a 402/403 becomes `.unavailable(.entitlement)` (:296-298) and IS cached (:300) — but under `.page(query)` and Query carries `subject` (StockSageBenzinga.swift:59-64), so the denial is a per-ticker fact, and its TTL is 300 s anyway (StockSageBenzinga.swift:24-32, default branch). With Earnings/Ratings/Guidance owned, the other four (analystInsights, bullsBearsSay, news, consensusRatings) are ~2,000 guaranteed-failing paid calls per horizon run. Smallest change, fires on EVERY run regardless of workflow, and it has a second-order win the finding did not claim: dropping 4 of 7 base queries leaves one 3-wide wave, which removes most of the queue-wait exposure that finding #9 is about. ONE CORRECTION TO THE PROPOSAL, and it is the honesty-floor one: a memoized page must NOT be stamped `checkedAt: now()` (that is the shape of unavailable(), :151-153) — nothing was checked at now(). Carry the original denial's checkedAt and epoch, or the app starts printing a fresh timestamp for a call it never made. That plumbing pushes it past 35 lines, but not past ~100.

#2 throttled names. This is the only finding in the set that makes the RESEARCH better rather than cheaper, which is why it outranks the bigger dollar savings. Verified end to end: during cooldown every query short-circuits to `.throttled` via admissionFailure (:147) without being cached, the snapshot still carries the live epoch so evidenceAllowed() passes (StockSageHorizonResearch.swift:378-381), the Massive news fallback shares the same admission gate (:199) so it throttles too, projection() still returns a status-lines-only Projection (StockSageBenzinga.swift:290-330 with maximumRecords: 0), and canAssess (StockSageAIAssessment.swift:97-113) therefore passes on price history alone. So a name with zero external evidence gets a full inference, can validate a Buy on price facts, and lands in the 5-name shortlist next to fully-evidenced names. BUT RE-SCOPE THE FIX — as written it is both over-sized and contract-breaking: "counting the name as not-checked" collides with Coverage.checked = scan.results.count (StockSageResearchHistory.swift:138) and would trip record()'s `checked == requested` gate (:148), exactly the trap finding #1 flagged and this one did not. The correct version is SMALLER and needs no contract change: return `.init(facts: facts, note: "Evidence provider throttled; price history only — not checked.")` with no verdict, so it counts as checked AND lands in `incomplete` (:139), the counter the owner already reads on screen. ~10-15 lines, saves ~20 model calls per cooldown, and removes a thin-evidence name from the shortlist. Note "full-price Qwen calls" is loose — Qwen is local, the cost is wall clock, not cash.

#3 one evidence pass, two horizons. Confirmed: inside analyze, `horizon` appears only in horizonFacts[0] (StockSageHorizonResearch.swift:390) and horizon.instructions (:411). The 1-year fetch, buildIdeas, the Benzinga snapshot and the news observation are byte-identical across week and fortnight, and with TTLs of 30 s / 300 s against a multi-hour scan the second horizon's cache is entirely cold. Largest absolute saving (~500 history + ~3,500 Benzinga + up to ~3,000 metadata calls, plus a second directory pagination) and it serves the owner's actual workflow. Ranked third only because it is the real restructure — start/scans/running/activeSymbol are single-horizon shaped and Scan.at / the saved run's startedAt-completedAt become shared. 130 lines is optimistic but inside 3x. No honesty cost found: two Runs sharing one reference close and one capture time is true and disclosable.

KEPT BUT BELOW THE LINE.

Prefetch pipeline (#7): honesty argument holds — canAssess allows 4 h of analysis age (StockSageAIAssessment.swift:111) and isRecentResearchPrice still gates the price, so ~15 s is well inside the contract. Two things it under-states: the "2–4 s of evidence round-trips per symbol" is assumed, not measured (nothing in HANDOFF times the evidence phase), and prefetching weakens the deliberate ordering at StockSageHorizonResearch.swift:383-386 ("a revoked permission must stop the second one") by exactly one symbol — a Stop press now costs one extra symbol of paid evidence. Also it must be built AFTER the two-horizon merge or it will prefetch the wrong unit of work.

History cache (#2): the primitive is real and the fail-closed argument is correct (completedHistory requires priceSource == .massiveDaily and the latest completed prior session, :205-224), but the finding overstates the hit rate and understates the danger. Hit rate: the cache is written with `universe: historyUniverse` = the ideas board's 901-name Tadawul+NASDAQ set (StockSageStore.swift:954, 1030), which is only partly overlapping with research's top-500-by-dollar-volume US list, and the board's fetchHistory falls back to Yahoo (StockSageQuoteService.swift:226-233), whose entries fail the massiveDaily gate. Danger: StockSageHistoryCache.from() DROPS symbols outside the universe it is handed and save() atomically REPLACES the whole file — a naive write-back with the research universe would destroy the board's same-day entries, which is precisely the CANCEL-01 non-shrink invariant argued at StockSageStore.swift:956-981. Also note the file's own header: "v1 seeds the SIM / backtest path only — it does NOT render the live board (that is an owner-gated, visual-QA-gated product decision)". A safe merge-preserving write-back plus tests is nearer 150-250 lines than 70. And if the two-horizon merge lands first, most of this finding's payoff is already collected.

LRU partition (#5): observation verified (per-symbol pages are write-once, analysts/firms carry an 86,400 s TTL and are the only shareable class, remember()'s global 500 cap at :329-336 evicts from a pool dominated by write-once entries). But the proposal as sized BREAKS A PINNED TEST: StockSageBenzingaClientTests.swift:232-246 `lruIsBoundedAndQueryWindowsDoNotAlias` writes 500 firm entries and asserts `calls == 502` after re-requesting Firm1 — with a 512-entry metadata partition nothing is evicted and it becomes 501. That is a deliberate design change, so the expectation must be re-derived and argued, never edited to pass; it also invalidates the "At most 501 entries here" justification for the linear min() scan at :332. The second half of the proposal (raising the 300 s TTL) saves nothing WITHIN a run — every symbol is visited exactly once — it only matters across runs, which #4 solves better. The all-product TTL test (:214-230) reads product.cacheTTL symbolically, so a TTL change would not break it.

---

## US / NASDAQ calendar — 1–7 and 7–14 trading days

**Facts and dates only. No directional call, no price target, no "what this means."**
Confirmed / projected / unconfirmed are kept apart on purpose — do not flatten them.

TOOLS USED: WebSearch and WebFetch (loaded via ToolSearch), plus local pdftotext to extract the OMB/OIRA PFEI CY2026 schedule and the DOL weekly-claims PDF that WebFetch could only return as binary.

WINDOW DEFINITION (assumption, stated because it moves items across the boundary): today, Tue 2026-09-15, is counted as trading day 1. Window 1 (days 1-7) = Sept 15, 16, 17, 18, 21, 22, 23. Window 2 (days 8-14) = Sept 24, 25, 28, 29, 30, Oct 1, Oct 2. No market holidays or early closes fall inside either window (NYSE confirmed), so trading days map 1:1 to weekdays.

EARNINGS-SEASON POSITION (facts, no interpretation): both windows sit BETWEEN reporting seasons for calendar-quarter filers. Q3 2026 calendar-quarter reporting begins after both windows — JPMorganChase has confirmed Tuesday, Oct 13, 2026 (results ~6:45 a.m. ET, call 8:30 a.m. ET) per its own 2026 earnings-call announcement, which is trading day ~20. What reports inside these windows is the off-cycle cohort of May/June- and August-fiscal-year-end companies. The two largest Nasdaq-listed reporters with company-confirmed dates in either window are Costco (Sept 24) and Micron (Sept 30), both in window 2. No Mag-7 / mega-cap Nasdaq company is scheduled in either window per my searches (see the could-not-verify list for the limits of that negative).

FETCH FAILURES ENCOUNTERED (all reflected in the could-not-verify list): nasdaq.com/trading-calendar, ir.nasdaq.com press-release pages and the Nasdaq index rebalance-schedule PDF all timed out at 60s; ismworld.org's release-date calendar 302-redirects to a member login; census.gov's economic-indicators calendar page returned no dated content; federalreserve.gov/monetarypolicy/fomcpresconf2026.htm returned 404; an earlier guessed Costco IR press-release URL returned 404 (the date was then confirmed from Costco's IR events page).

MCP NOTE: several MCP servers in this session are unauthenticated or failed to connect; none were needed — all facts above come from agency/company/exchange web sources. No directional view, magnitude estimate, or market interpretation is offered anywhere in this output, per the task rules.

### Window 1 — trading days 1–7

| Date | Event | Status | Source |
|---|---|---|---|
| 2026-09-15 / 2026-09-16 | FOMC two-day meeting (asterisked on the Fed calendar = associated with a Summary of Economic Projections). Today is day 1. | confirmed | Federal Reserve, FOMC Meeting calendars (federalreserve.gov/monetarypolicy/fomccalendars.htm) — lists "September 15-16*" |
| 2026-09-16 | FOMC decision day: policy statement + Summary of Economic Projections; Chair press conference listed on the Fed's own September 2026 calendar at 2:00 p.m. ET entry | confirmed | Federal Reserve Board calendar, September 2026 (federalreserve.gov/newsevents/2026-september.htm) |
| 2026-09-16 | Advance Monthly Sales for Retail and Food Services, August 2026 (8:30 a.m. ET) | confirmed | OMB/OIRA Schedule of Release Dates for Principal Federal Economic Indicators CY2026 (whitehouse.gov PFEI schedule PDF), Census row — September value 16 |
| 2026-09-16 | Manufacturing and Trade: Inventories and Sales (business inventories), 8:30 a.m. ET | confirmed | OMB/OIRA PFEI CY2026 schedule, Census row — September value 16 |
| 2026-09-16 | U.S. Import and Export Price Indexes, August 2026 (8:30 a.m. ET) | confirmed | BLS release schedule, September 2026 (bls.gov/schedule/2026/09_sched.htm) |
| 2026-09-17 | New Residential Construction / housing starts and permits, August 2026 (8:30 a.m. ET) | confirmed | OMB/OIRA PFEI CY2026 schedule, Census row — September value 17 |
| 2026-09-17 | Unemployment Insurance Weekly Claims (8:30 a.m. ET). Weekly Thursday cadence; the most recent release was embargoed to 8:30 a.m. ET Thursday, September 10, 2026 | projected | DOL/ETA UI Weekly Claims news release dated Sept 10, 2026 (dol.gov/ui/data.pdf) — cadence, not a published forward-dated calendar entry |
| 2026-09-17 | FOMC communications blackout ends (blackout ran Sept 5–17, 2026) | confirmed | Federal Reserve Bank of Atlanta, Blackout Periods page (atlantafed.org/news-and-events/press-room/blackout-periods) |
| 2026-09-18 | Governor Christopher J. Waller, "Economic Outlook," Reuters NEXT Newsmaker Interview (virtual), 9:05 a.m. ET | confirmed | Federal Reserve Board calendar, September 2026 |
| 2026-09-18 | Vice Chair for Supervision Michelle W. Bowman, discussion on stress testing, London, 9:30 a.m. ET | confirmed | Federal Reserve Board calendar, September 2026 |
| 2026-09-18 | Industrial Production and Capacity Utilization (G.17), August 2026 — 9:15 a.m. ET | confirmed | Federal Reserve Board calendar, September 2026; cross-checked against OMB/OIRA PFEI CY2026 schedule (Fed row, September value 18) |
| 2026-09-18 | Quarterly quadruple witching / September monthly options expiration (third Friday): stock index futures, index options, single-stock options expire | confirmed | TradeStation 2026 quad-witching calendar; Option Alpha quadruple witching dates 2026 (third-Friday convention; date also confirmed by calendar arithmetic) |
| 2026-09-18 | FTSE Russell Global Equity Index Series September 2026 semi-annual review — constituent changes applied after the close | confirmed | FTSE Russell / LSEG index notices for the GEIS September 2026 semi-annual review (research.ftserussell.com index notice; lseg.com FTSE UK Index Series September 2026 review) |
| 2026-09-18 | BLS State Employment and Unemployment, August 2026 (10:00 a.m. ET) | confirmed | BLS release schedule, September 2026 |
| 2026-09-21 | S&P Dow Jones Indices quarterly rebalance effective prior to the open for S&P 500, S&P 100, S&P MidCap 400, S&P SmallCap 600 (announced Sept 4, 2026; S&P 500 adds Bloom Energy, Everpure, Illumina) | confirmed | S&P Dow Jones Indices press release of Sept 4, 2026, as carried by StockTitan and Nasdaq: "...effective prior to the open of trading on Monday, September 21, 2026, to coincide with the quarterly rebalance." |
| 2026-09-21 | FTSE GEIS September 2026 semi-annual review effective at the open (includes Greece Advanced Emerging → Developed and Vietnam Frontier → Secondary Emerging reclassifications) | confirmed | FTSE Russell / LSEG FAQ documents for the September 2026 GEIS review |
| 2026-09-22 / 2026-09-23 | No U.S. macro release, Fed event, index event, holiday or early close verified as scheduled on these two days | confirmed | Absence check across BLS Sept 2026 schedule, OMB/OIRA PFEI CY2026 schedule, BEA release schedule, Federal Reserve Board September 2026 calendar, NYSE hours-and-calendars page |

### Window 2 — trading days 8–14

| Date | Event | Status | Source |
|---|---|---|---|
| 2026-09-24 | New Residential Sales (new home sales), August 2026 (10:00 a.m. ET) | confirmed | OMB/OIRA PFEI CY2026 schedule, Census row — September value 24 |
| 2026-09-24 | BEA: U.S. International Transactions and Investment Position, Q2 2026 (8:30 a.m. ET) | confirmed | BEA news release schedule (bea.gov/news/schedule) |
| 2026-09-24 | Federal Reserve: Senior Credit Officer Opinion Survey on Dealer Financing Terms (2:00 p.m. ET) | confirmed | Federal Reserve Board calendar, September 2026 |
| 2026-09-24 | EARNINGS — Costco Wholesale (COST, Nasdaq) fiscal Q4 and FY2026 results; conference call 2:00 p.m. PT (release after the close) | confirmed | Costco investor relations events page, "Q4 2026 Earnings Call — September 24, 2026 02:00 PM PT" (investor.costco.com) |
| 2026-09-24 | Unemployment Insurance Weekly Claims (8:30 a.m. ET), weekly Thursday cadence | projected | DOL/ETA UI Weekly Claims release cadence (Sept 10, 2026 release embargoed 8:30 a.m. ET Thursday) |
| 2026-09-25 | Advance Report on Durable Goods — Manufacturers' Shipments, Inventories and Orders, August 2026 (8:30 a.m. ET) | confirmed | OMB/OIRA PFEI CY2026 schedule, Census row — September value 25 |
| 2026-09-29 | Job Openings and Labor Turnover Survey (JOLTS), August 2026 (10:00 a.m. ET) | confirmed | BLS release schedule, September 2026 |
| 2026-09-30 | BEA Personal Income and Outlays, August 2026 — includes the PCE and core PCE price indexes (8:30 a.m. ET) | confirmed | BEA news release schedule; cross-checked against OMB/OIRA PFEI CY2026 schedule (BEA row, September value 30) |
| 2026-09-30 | BEA GDP third estimate, Q2 2026, plus corporate profits, industry, state GDP and state personal income (8:30 a.m. ET) | confirmed | BEA news release schedule; cross-checked against OMB/OIRA PFEI CY2026 schedule |
| 2026-09-30 | EARNINGS — Micron Technology (MU, Nasdaq) fiscal Q4 2026 results; conference call 2:30 p.m. Mountain time (4:30 p.m. ET) | confirmed | Micron press release dated Aug 26, 2026, "Micron Technology to Report Fiscal Fourth Quarter Results on September 30, 2026" (investors.micron.com / GlobeNewswire) |
| 2026-09-30 | Calendar Q3 2026 quarter end (final trading day of the quarter; Wednesday) | confirmed | Calendar arithmetic against the NYSE 2026 holiday calendar — no holiday or early close between Sept 15 and Oct 10, 2026 |
| 2026-10-01 | Unemployment Insurance Weekly Claims (8:30 a.m. ET), weekly Thursday cadence | projected | DOL/ETA UI Weekly Claims release cadence |
| 2026-10-01 | ISM Manufacturing PMI, September 2026 data (10:00 a.m. ET). ISM publishes the Manufacturing report on the first business day of the month; Oct 1 is the first business day | projected | ISM stated release rule (ismworld.org PMI reports pages). ISM's own Report On Business release-date calendar redirects to a member login and could not be fetched |
| 2026-10-02 | BLS Employment Situation, September 2026 — nonfarm payrolls and unemployment rate (8:30 a.m. ET) | confirmed | BLS release schedule, October 2026 (bls.gov/schedule/2026/10_sched.htm); cross-checked against OMB/OIRA PFEI CY2026 schedule (BLS row, October value 2) |
| 2026-10-02 | Manufacturers' Shipments, Inventories and Orders (full factory orders report), August 2026 (10:00 a.m. ET) | confirmed | OMB/OIRA PFEI CY2026 schedule, Census row — October value 2 |
| 2026-10-02 | No U.S. market holiday or early close falls in this window; the next NYSE closure is Thanksgiving, Thursday Nov 26, 2026, and the next early close (1:00 p.m.) is Friday Nov 27, 2026 | confirmed | NYSE Holidays and Trading Hours page (nyse.com/markets/hours-calendars) |

### Could NOT be verified

Listed because an honest gap is the required output. Do not treat any of these as scheduled.

- Nasdaq-100 (NDX) September 2026 quarterly rebalance — UNCONFIRMED. Nasdaq's methodology provides for rank-based quarterly reviews in March, June and September, and the June 2026 rebalance was announced ~June 11-12 and effective prior to the open on Monday, June 22, 2026 (the Monday after quad witching), which implies an effective date of Monday, Sept 21, 2026. I found NO September 2026 Nasdaq-100 quarterly-changes press release. ir.nasdaq.com, the Nasdaq index rebalance-schedule PDF and nasdaq.com/trading-calendar all timed out on fetch; searches returned only the June 2026 release. Do not treat Sept 21 as a scheduled NDX rebalance on my authority.
- ISM Manufacturing (assumed Oct 1) and ISM Services (assumed Oct 5, 10:00 a.m. ET, September data) — exact published dates NOT verified. ismworld.org's 'Release Dates for the ISM Manufacturing and Non-Manufacturing Report On Business' page 302-redirects to an ecommerce/SSO login. Dates are derived from ISM's stated rule (Manufacturing = first business day, Services = third business day) plus the calendar. ISM Services on Oct 5 would in any case fall on trading day 15, just outside the second window.
- Weekly initial jobless claims dates (Sept 17, Sept 24, Oct 1) — derived from the DOL/ETA weekly-Thursday 8:30 a.m. ET cadence documented in the Sept 10, 2026 release, not from a fetched forward-dated DOL release calendar. Marked projected above.
- FOMC minutes for the Sept 15-16, 2026 meeting — release date NOT posted. The Fed's FOMC calendar page shows no minutes date for the September, October or December 2026 meetings yet. The Fed's standing 3-weeks-after convention would put it around Wednesday, Oct 7, 2026 (trading day ~16, outside both windows), but that is an inference, not a schedule.
- Scheduled Fed speakers after Sept 24, 2026 — the Federal Reserve Board's October 2026 calendar currently lists only statistical releases (G.5, H.4.1, H.8, H.15, CP) for Oct 1-6 with no speeches posted. Regional Reserve Bank speaker calendars (NY, Chicago, Atlanta, etc.) were NOT checked. Expect additional speeches to be added; the Oct 17-29 blackout for the Oct 27-28 FOMC is confirmed by the Atlanta Fed and starts after both windows.
- Exact FOMC press conference clock time on Sept 16 — the Fed's September 2026 calendar entry I retrieved shows a 2:00 p.m. ET timestamp for the FOMC press conference item. The customary split (statement/SEP 2:00 p.m., Chair press conference 2:30 p.m.) was NOT independently confirmed for this meeting.
- Whether any mega-cap Nasdaq name (Apple, Microsoft, Alphabet, Amazon, Meta, Nvidia, Tesla, Broadcom, Netflix) has a confirmed report date in either window — I found NONE scheduled in Sept 15-Oct 2, and I did NOT verify their actual Q3/fiscal-quarter dates (all are expected later in October/November). Treat 'no mega-cap Nasdaq reporter in these windows' as a search result, not as a verified negative for every name.
- Other late-September fiscal-quarter reporters frequently in this stretch — Accenture (NYSE), Nike (NYSE), Paychex (Nasdaq), Cintas (Nasdaq), Carnival, ConAgra, Jabil, Darden — I did NOT confirm any 2026 dates for these. Searches returned only their prior (June/July 2026) releases.
- Conference Board Consumer Confidence (customarily the last Tuesday, ~Sept 29) and University of Michigan sentiment final (~Sept 25) — NOT verified; no source fetched. Excluded from both windows.
- Census Bureau's own economic-indicator calendar page returned no dated content; all Census dates above come from the OMB/OIRA Principal Federal Economic Indicators CY2026 schedule PDF (text-extracted locally) rather than from census.gov release-date pages. The retail-sales date (Sept 16) was independently corroborated by search; the others were not double-sourced.
- Treasury auction/refunding calendar, S&P 500 float-share and index-share change details beyond the named adds/drops, and CBOE/CME product-specific expiration mechanics for Sept 18 — out of scope of what I verified.

