import Testing
import Foundation
@testable import StockSage

// MARK: - Chunked progressive scan — pure infra (PLAN_2026-07-08_equity2000.md Stage 1)
//
// Four groups per the plan's test list: (1) pure chunking helper — boundaries, order
// preservation; (2) merge-equivalence — chunked merge over fixtures == single-shot
// buildIdeas result at n≤250; (3) staleness-partition — same-day cached vs stale;
// (4) fallback trigger math — <30% on chunk 2 stops, chunk 1 exempt.
//
// Chunk-boundary/coverage-threshold literals hand-derived in scratchpad/derive_chunking.swift
// and derive_throttle.swift; staleness fixtures in derive_staleness.swift (F40 discipline —
// see testing-discipline skill).

struct StockSageScanChunkingTests {

    // MARK: 1. Pure chunking — boundaries + order preservation

    @Test func chunksSingleChunkWhenUnderSize() {
        // n=210, size=250 -> ONE chunk [0,210) — today's universe size, byte-identical scan shape.
        let defs = Array(0..<210)
        let chunks = StockSageScanChunking.chunks(defs, size: 250)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 210)
        #expect(chunks[0] == defs)   // order preserved, head-first
    }

    @Test func chunksSplitsAtBoundariesPreservingOrder() {
        // n=210, size=100 -> [0,100),[100,200),[200,210) — derived in derive_chunking.swift.
        let defs = Array(0..<210)
        let chunks = StockSageScanChunking.chunks(defs, size: 100)
        #expect(chunks.count == 3)
        #expect(chunks[0] == Array(0..<100))
        #expect(chunks[1] == Array(100..<200))
        #expect(chunks[2] == Array(200..<210))
        // Concatenation reconstructs the original order exactly.
        #expect(chunks.flatMap { $0 } == defs)
    }

    @Test func chunksEmptyInputIsEmptyOutput() {
        #expect(StockSageScanChunking.chunks([Int](), size: 250).isEmpty)
    }

    @Test func chunksExactMultipleOfSizeHasNoTrailingEmptyChunk() {
        // n=501, size=250 -> [0,250),[250,500),[500,501) — a non-multiple to also confirm
        // the tail chunk lands correctly (derive_chunking.swift).
        let defs = Array(0..<501)
        let chunks = StockSageScanChunking.chunks(defs, size: 250)
        #expect(chunks.count == 3)
        #expect(chunks[0].count == 250)
        #expect(chunks[1].count == 250)
        #expect(chunks[2].count == 1)
    }

    @Test func chunksExactMultipleHasNoEmptyTrailingChunk() {
        // n=5, size=5 -> exactly one full chunk, no trailing empty chunk.
        let defs = Array(0..<5)
        let chunks = StockSageScanChunking.chunks(defs, size: 5)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 5)
    }

    @Test func chunksNonPositiveSizeTreatedAsOne() {
        // size<=0 must never infinite-loop or produce an empty chunk — treated as 1.
        let defs = [10, 20, 30]
        let chunks = StockSageScanChunking.chunks(defs, size: 0)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count == 1 })
        #expect(chunks.flatMap { $0 } == defs)
    }

    @Test func chunksHeadIsAlwaysFirstChunkSaudiFirstOrderingPreserved() {
        // The plan requires chunk 0 = the array's natural head (Saudi-first core). A
        // string-symbol fixture stands in for trackedDefs()'s ordering contract.
        let universe = ["2222.SR", "1120.SR", "AAPL", "MSFT", "GOOGL"]
        let chunks = StockSageScanChunking.chunks(universe, size: 2)
        #expect(chunks[0] == ["2222.SR", "1120.SR"])   // Saudi core leads chunk 0
        #expect(chunks[1] == ["AAPL", "MSFT"])
        #expect(chunks[2] == ["GOOGL"])
    }

    // MARK: 2. Merge-equivalence — chunked merge == single-shot buildIdeas

    /// Minimal non-index StockSageSymbol.
    private func equitySym(_ s: String) -> StockSageSymbol { StockSageSymbol(symbol: s, market: "TEST") }

    /// Deterministic price history with a genuine trend (uptrend when `slope > 0`, downtrend
    /// when `slope < 0`) — enough bars (260) to clear the momentum/trend-triad lookbacks so
    /// buildIdeas' advisor produces DIFFERENT (non-degenerate) actions across symbols, giving
    /// the merge+re-sort something real to order. OHLC mirror closes (matches the
    /// StockSageBuildIdeasDirectTests precedent).
    private func trendingHistory(_ sym: String, slope: Double, bars: Int = 260) -> StockSagePriceHistory {
        let closes = (0..<bars).map { 100.0 + Double($0) * slope }
        let dates = (0..<bars).map { Date(timeIntervalSince1970: Double($0) * 86_400) }
        return StockSagePriceHistory(symbol: sym, dates: dates, opens: closes,
                                     highs: closes.map { $0 * 1.005 }, lows: closes.map { $0 * 0.995 },
                                     closes: closes, volumes: closes.map { _ in 100_000 })
    }

    @Test func chunkedMergeEqualsSingleShotBuildIdeasAtNUnder250() async {
        // 6 symbols, 3 strong uptrends + 3 strong downtrends (WHIPPYX discipline: assert a hard
        // count, never a soft guard) — split into 2 chunks of 3 and merge, vs one buildIdeas call
        // over all 6 at once. Both paths call the SAME buildIdeas/rankScore; this test pins the
        // ARCHITECTURE invariant (chunk+merge recomposes to the single-shot result), not a magic
        // number computed by the code under test.
        let symbols = ["UP1", "UP2", "UP3", "DOWN1", "DOWN2", "DOWN3"]
        var histories: [String: StockSagePriceHistory] = [:]
        for s in ["UP1", "UP2", "UP3"] { histories[s] = trendingHistory(s, slope: 0.6) }
        for s in ["DOWN1", "DOWN2", "DOWN3"] { histories[s] = trendingHistory(s, slope: -0.6) }
        let defs = symbols.map { equitySym($0) }

        // Single-shot: one buildIdeas call over the whole universe, sorted once.
        let singleShotBuilt = await StockSageStore.buildIdeas(defs: defs, histories: histories)
        let singleShot = singleShotBuilt.sorted { StockSageStore.rankScore($0.advice) > StockSageStore.rankScore($1.advice) }
        #expect(singleShot.count == 6)   // hard count first (WHIPPYX)

        // Chunked: split into 2 chunks of 3, buildIdeas per chunk, merge via the SAME
        // StockSageScanChunking.mergeChunk the store's chunked scan calls.
        let chunks = StockSageScanChunking.chunks(defs, size: 3)
        #expect(chunks.count == 2)
        var merged: [StockSageIdea] = []
        for chunk in chunks {
            let built = await StockSageStore.buildIdeas(defs: chunk, histories: histories)
            merged = StockSageScanChunking.mergeChunk(current: merged, newlyBuilt: built, rankScore: StockSageStore.rankScore)
        }
        #expect(merged.count == 6)

        // Equivalence: same symbols, same order, same advice per symbol.
        #expect(merged.map(\.symbol) == singleShot.map(\.symbol))
        for (a, b) in zip(merged, singleShot) {
            #expect(a.symbol == b.symbol)
            #expect(a.advice.action == b.advice.action)
            #expect(abs(a.advice.conviction - b.advice.conviction) < 1e-9)
        }
    }

    // MARK: 2a. Retry-chunking equivalence (review round-2 finding 3): retryFailedIdeas now
    // shares `runChunkedScan` with performRefreshIdeas instead of an un-chunked single-shot
    // hammer over the whole missing-symbol subset. `runChunkedScan` (private, MainActor-bound)
    // has no test seam, same as `performRefreshIdeas` (see the preScanBoard test's comment
    // above) — so this pins the ARCHITECTURE invariant the shared loop relies on: chunking the
    // retry subset and merging chunk-by-chunk into the EXISTING board (retry's `startingRanked:
    // ideas`, not an empty board — the key difference vs the full-scan shape already covered
    // above) produces the SAME result as the OLD single-shot retry (one buildIdeas call over the
    // whole missing subset, merged once via mergeChunk) at n≤250 missing symbols.
    @Test func chunkedRetryEqualsOldSingleShotRetryMergeAtNUnder250() async {
        // Board already has 2 unrelated priced ideas on it (what retryFailedIdeas starts from).
        func existingIdea(_ symbol: String) -> StockSageIdea {
            StockSageIdea(symbol: symbol, market: symbol, price: 100,
                         advice: TradeAdvice(action: .hold, conviction: 0.1, regime: .range,
                                            rationale: [], stopPrice: nil, targetPrice: nil,
                                            suggestedWeight: 0, caveat: "x"),
                         spark: [])
        }
        let existingBoard = [existingIdea("SPY"), existingIdea("QQQ")]

        // 6 previously-missing symbols being retried, 3 up + 3 down (same fixture shape as the
        // full-scan equivalence test above).
        let missingSymbols = ["UP1", "UP2", "UP3", "DOWN1", "DOWN2", "DOWN3"]
        var histories: [String: StockSagePriceHistory] = [:]
        for s in ["UP1", "UP2", "UP3"] { histories[s] = trendingHistory(s, slope: 0.6) }
        for s in ["DOWN1", "DOWN2", "DOWN3"] { histories[s] = trendingHistory(s, slope: -0.6) }
        let defs = missingSymbols.map { equitySym($0) }

        // OLD single-shot retry: one buildIdeas call over the WHOLE missing subset, merged once.
        let oldBuilt = await StockSageStore.buildIdeas(defs: defs, histories: histories)
        let oldReplaced = StockSageScanChunking.mergeChunk(current: existingBoard, newlyBuilt: oldBuilt,
                                                            rankScore: StockSageStore.rankScore)
        let oldMerged = oldReplaced.sorted { StockSageStore.rankScore($0.advice) > StockSageStore.rankScore($1.advice) }
        #expect(oldMerged.count == 8)   // 2 existing + 6 retried (WHIPPYX: hard count first)

        // NEW chunked retry: split the missing subset into 2 chunks of 3, buildIdeas per chunk,
        // merge each into the STARTING board (existingBoard) — exactly runChunkedScan's shape
        // when called with startingRanked: ideas.
        let chunks = StockSageScanChunking.chunks(defs, size: 3)
        #expect(chunks.count == 2)
        var chunkedMerged = existingBoard
        for chunk in chunks {
            let built = await StockSageStore.buildIdeas(defs: chunk, histories: histories)
            chunkedMerged = StockSageScanChunking.mergeChunk(current: chunkedMerged, newlyBuilt: built,
                                                             rankScore: StockSageStore.rankScore)
        }
        chunkedMerged = chunkedMerged.sorted { StockSageStore.rankScore($0.advice) > StockSageStore.rankScore($1.advice) }
        #expect(chunkedMerged.count == 8)

        // Equivalence: same symbols (existing + retried), same order, same advice per symbol —
        // the shared chunk loop produces the identical result the old un-chunked retry did.
        #expect(chunkedMerged.map(\.symbol) == oldMerged.map(\.symbol))
        for (a, b) in zip(chunkedMerged, oldMerged) {
            #expect(a.symbol == b.symbol)
            #expect(a.advice.action == b.advice.action)
            #expect(abs(a.advice.conviction - b.advice.conviction) < 1e-9)
        }
        // The 2 pre-existing board rows survived untouched (retry only replaces the retried symbols).
        #expect(chunkedMerged.contains { $0.symbol == "SPY" })
        #expect(chunkedMerged.contains { $0.symbol == "QQQ" })
    }

    @Test func mergeChunkReplacesBySymbolCaseInsensitive() {
        func idea(_ symbol: String, _ action: TradeAdvice.Action, conviction: Double = 0.5) -> StockSageIdea {
            StockSageIdea(symbol: symbol, market: symbol, price: 100,
                         advice: TradeAdvice(action: action, conviction: conviction, regime: .range,
                                            rationale: [], stopPrice: nil, targetPrice: nil,
                                            suggestedWeight: 0.05, caveat: "x"),
                         spark: [])
        }
        // Current board has AAPL=.hold; a new chunk re-prices AAPL (different casing) as .buy —
        // the merge must REPLACE, not duplicate, and re-sort so .buy (rankScore 1.5) outranks
        // a stale .hold (rankScore 0) — .buy > .hold by rankScore's own formula.
        let current = [idea("AAPL", .hold), idea("MSFT", .sell, conviction: 0.2)]
        let newlyBuilt = [idea("aapl", .buy, conviction: 0.5)]
        let merged = StockSageScanChunking.mergeChunk(current: current, newlyBuilt: newlyBuilt, rankScore: StockSageStore.rankScore)
        #expect(merged.count == 2)   // AAPL replaced in place, not duplicated
        #expect(merged[0].symbol == "aapl")   // .buy (rankScore 1.5) ranks above .sell (rankScore -2.2)
        #expect(merged[0].advice.action == .buy)
        #expect(merged.filter { $0.symbol.uppercased() == "AAPL" }.count == 1)
    }

    @Test func mergeChunkNoOpWhenNewlyBuiltEmpty() {
        func idea(_ symbol: String) -> StockSageIdea {
            StockSageIdea(symbol: symbol, market: symbol, price: 100,
                         advice: TradeAdvice(action: .hold, conviction: 0.1, regime: .range,
                                            rationale: [], stopPrice: nil, targetPrice: nil,
                                            suggestedWeight: 0, caveat: "x"),
                         spark: [])
        }
        let current = [idea("AAPL"), idea("MSFT")]
        let merged = StockSageScanChunking.mergeChunk(current: current, newlyBuilt: [], rankScore: StockSageStore.rankScore)
        #expect(merged == current)   // an empty (e.g. totally-failed) chunk leaves the board untouched
    }

    // MARK: 2b. preScanBoard semantic — alerts must key off the state BEFORE the chunk loop's
    // mid-scan publishes, not the state AFTER (review round 1, finding 1: mid-loop `ideas =
    // ranked` publishes overwrote the pre-scan board before StockSageAlerts.detect ran, so
    // detect(new, new) never fired and alerts went dead). `performRefreshIdeas` is private and
    // network/disk-bound (StockSageQuoteService, StockSageHistoryCache, StockSageJournalStore.shared)
    // — no store seam exists to drive it directly in a unit test — so this test pins the
    // composition it relies on instead: build the SAME two snapshots `performRefreshIdeas` would
    // (`preScanBoard` = board before any chunk merges; the chunk-loop's own mid-scan publish
    // state = board after chunk 1 merges but before chunk 2 runs) and shows the alert only fires
    // when `detect` is given the TRUE pre-scan snapshot as `previous`, not the mid-loop one.
    @Test func alertsFireAcrossAChunkedScanOnlyWhenComparedToThePreScanSnapshot() {
        func idea(_ symbol: String, _ action: TradeAdvice.Action, price: Double = 100) -> StockSageIdea {
            StockSageIdea(symbol: symbol, market: symbol, price: price,
                         advice: TradeAdvice(action: action, conviction: 0.6, regime: .range,
                                            rationale: [], stopPrice: nil, targetPrice: nil,
                                            suggestedWeight: 0.05, caveat: "x"),
                         spark: [])
        }
        // Board BEFORE this scan starts: AAPL was .hold last scan.
        let preScanBoard = [idea("AAPL", .hold)]

        // Chunk 1 merges in a flip to .strongBuy — this is the mid-loop publish
        // (`ideas = ranked` inside the loop) that the bug compared `previous` against.
        var midLoopBoard = preScanBoard
        midLoopBoard = StockSageScanChunking.mergeChunk(current: midLoopBoard, newlyBuilt: [idea("AAPL", .strongBuy)],
                                                        rankScore: StockSageStore.rankScore)
        // Chunk 2 (a different symbol) doesn't touch AAPL again — mirrors a multi-chunk scan
        // where AAPL priced in an early chunk and stays untouched for the rest of the scan.
        let finalRanked = StockSageScanChunking.mergeChunk(current: midLoopBoard, newlyBuilt: [idea("MSFT", .hold)],
                                                           rankScore: StockSageStore.rankScore)

        // THE BUG (pre-fix shape): comparing finalRanked to the ALREADY-PUBLISHED midLoopBoard/
        // finalRanked itself — both snapshots already show AAPL as .strongBuy, so no crossing.
        let buggyAlerts = StockSageAlerts.detect(previous: midLoopBoard, current: finalRanked)
        #expect(buggyAlerts.isEmpty)   // demonstrates why the bug went silent: detect(new, new)

        // THE FIX: comparing finalRanked to preScanBoard (captured BEFORE any chunk merge)
        // correctly sees the .hold → .strongBuy crossing and fires.
        let fixedAlerts = StockSageAlerts.detect(previous: preScanBoard, current: finalRanked)
        #expect(fixedAlerts.count == 1)
        #expect(fixedAlerts.first?.kind == .flipBullish)
        #expect(fixedAlerts.first?.symbol == "AAPL")
    }

    @Test func alertsSkippedOnFirstEverScanWhenPreScanBoardIsEmpty() {
        // First-ever-scan guard: `alertsEnabled && !preScanBoard.isEmpty` in performRefreshIdeas.
        // An empty pre-scan board (never scanned before) must produce no alerts — there's nothing
        // to have "crossed" from. Modeled here as detect(previous: [], current:) returning empty,
        // the same guard the store's `!preScanBoard.isEmpty` short-circuits before ever calling.
        func idea(_ symbol: String, _ action: TradeAdvice.Action) -> StockSageIdea {
            StockSageIdea(symbol: symbol, market: symbol, price: 100,
                         advice: TradeAdvice(action: action, conviction: 0.6, regime: .range,
                                            rationale: [], stopPrice: nil, targetPrice: nil,
                                            suggestedWeight: 0.05, caveat: "x"),
                         spark: [])
        }
        let finalRanked = StockSageScanChunking.mergeChunk(current: [], newlyBuilt: [idea("AAPL", .strongBuy)],
                                                           rankScore: StockSageStore.rankScore)
        #expect(StockSageAlerts.detect(previous: [], current: finalRanked).isEmpty)
    }

    // MARK: 3. Staleness-partition — same-day cached vs stale

    /// Build a minimal HistoryCache with one entry whose newest bar date is `newestBar`.
    private func cache(savedAt: Date, symbol: String = "AAPL", newestBar: Date) -> StockSageHistoryCache {
        let entry = StockSageHistoryCache.Entry(symbol: symbol, dates: [newestBar],
                                                 opens: [100], highs: [101], lows: [99], closes: [100], volumes: [1000])
        return StockSageHistoryCache(schemaVersion: StockSageHistoryCache.currentSchemaVersion, entries: [entry], savedAt: savedAt)
    }

    private let iso = ISO8601DateFormatter()

    @Test func partitionServesFromCacheWhenSameUTCDayAndFresh() {
        // derive_staleness.swift case A: cache savedAt 2026-07-08 09:00Z, symbol's own newest
        // bar is ALSO that instant (age 0 days) -> now 2026-07-08 12:00Z is the same UTC day
        // and not stale (0 <= 7) -> serves from cache, no fetch.
        let now = iso.date(from: "2026-07-08T12:00:00Z")!
        let savedAt = iso.date(from: "2026-07-08T09:00:00Z")!
        let c = cache(savedAt: savedAt, newestBar: savedAt)
        let (fromCache, toFetch) = StockSageScanChunking.partitionByCacheFreshness(symbols: ["AAPL"], cache: c, now: now)
        #expect(fromCache == ["AAPL"])
        #expect(toFetch.isEmpty)
    }

    @Test func partitionFetchesWhenCacheSavedPreviousUTCDay() {
        // derive_staleness.swift case B: cache savedAt 2026-07-07 23:00Z is a DIFFERENT UTC day
        // than now (2026-07-08 12:00Z), even though only 13h apart and the entry itself isn't
        // stale by the 7-day bar — same-UTC-day is the stricter, deliberate bar.
        let now = iso.date(from: "2026-07-08T12:00:00Z")!
        let savedAt = iso.date(from: "2026-07-07T23:00:00Z")!
        let c = cache(savedAt: savedAt, newestBar: savedAt)
        let (fromCache, toFetch) = StockSageScanChunking.partitionByCacheFreshness(symbols: ["AAPL"], cache: c, now: now)
        #expect(fromCache.isEmpty)
        #expect(toFetch == ["AAPL"])
    }

    @Test func partitionFetchesWhenSameDayCacheButSymbolEntryStale() {
        // derive_staleness.swift case C: cache saved TODAY, but AAPL's own newest bar is 10
        // calendar days old (> maxAgeDays 7) -> same-day cache existing does not override a
        // genuinely stale per-symbol entry (e.g. a carried-forward miss from a prior scan).
        let now = iso.date(from: "2026-07-08T12:00:00Z")!
        let savedAt = iso.date(from: "2026-07-08T09:00:00Z")!
        let staleNewestBar = iso.date(from: "2026-06-28T09:00:00Z")!
        let c = cache(savedAt: savedAt, newestBar: staleNewestBar)
        let (fromCache, toFetch) = StockSageScanChunking.partitionByCacheFreshness(symbols: ["AAPL"], cache: c, now: now)
        #expect(fromCache.isEmpty)
        #expect(toFetch == ["AAPL"])
    }

    @Test func partitionFetchesEverythingWhenCacheIsNil() {
        // First scan of the day / no cache on disk — never invents freshness.
        let (fromCache, toFetch) = StockSageScanChunking.partitionByCacheFreshness(
            symbols: ["AAPL", "MSFT"], cache: nil, now: Date())
        #expect(fromCache.isEmpty)
        #expect(toFetch == ["AAPL", "MSFT"])
    }

    @Test func partitionPreservesInputOrderAcrossBothBuckets() {
        let now = iso.date(from: "2026-07-08T12:00:00Z")!
        let savedAt = iso.date(from: "2026-07-08T09:00:00Z")!
        // AAPL fresh (same instant as savedAt), MSFT has no cache entry at all (absent -> stale
        // per HistoryCache.isStale's own "absence is not freshness" contract) -> must fetch.
        let c = cache(savedAt: savedAt, symbol: "AAPL", newestBar: savedAt)
        let (fromCache, toFetch) = StockSageScanChunking.partitionByCacheFreshness(
            symbols: ["AAPL", "MSFT"], cache: c, now: now)
        #expect(fromCache == ["AAPL"])
        #expect(toFetch == ["MSFT"])
    }

    // MARK: 4. Fallback trigger math — <30% on chunk-beyond-first stops, chunk 0 exempt

    @Test func shouldThrottleTrueJustBelow30PercentOnLaterChunk() {
        // derive_throttle.swift: chunk index 1 (a chunk beyond the first), 74/250 = 0.296 < 0.30.
        #expect(StockSageScanChunking.shouldThrottle(chunkIndex: 1, priced: 74, attempted: 250))
    }

    @Test func shouldThrottleFalseAtExactly30PercentOnLaterChunk() {
        // derive_throttle.swift: chunk index 1, 75/250 = 0.30 exactly — the threshold is a
        // strict "<", so exactly-30% does NOT trip (straddle pin: 74/250 true, 75/250 false).
        #expect(!StockSageScanChunking.shouldThrottle(chunkIndex: 1, priced: 75, attempted: 250))
    }

    @Test func shouldThrottleFalseOnFirstChunkRegardlessOfCoverage() {
        // Chunk 0 (index 0) is EXEMPT — a totally-failed first chunk is the legacy
        // total-failure path (histories.isEmpty bail), not this scaffold.
        #expect(!StockSageScanChunking.shouldThrottle(chunkIndex: 0, priced: 0, attempted: 250))
    }

    @Test func shouldThrottleFalseWhenNothingAttemptedThisChunk() {
        // All-cache-hit chunk (nothing fetched) must never look like a throttle event —
        // chunkCoverage is vacuously 1.0 when attempted == 0.
        #expect(StockSageScanChunking.chunkCoverage(priced: 0, attempted: 0) == 1.0)
        #expect(!StockSageScanChunking.shouldThrottle(chunkIndex: 2, priced: 0, attempted: 0))
    }

    @Test func shouldThrottleTrueOnThirdChunkTooLowCoverage() {
        // A second later chunk (index 2) with a worse cratered coverage also trips it —
        // confirms the predicate is not special-cased to index==1 only.
        #expect(StockSageScanChunking.shouldThrottle(chunkIndex: 2, priced: 10, attempted: 250))
    }
}
