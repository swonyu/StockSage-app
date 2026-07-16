import Testing
import Foundation
@testable import StockSage

// MARK: - StockSagePaperTrader (pure forward paper-trading engine)
//
// Every fixture is HAND-DERIVED in the test body. Exit selection is delegated to
// StockSageBacktester.simulateExit; these tests pin the paper-trader's own gating, cost-netting,
// and orchestration, plus BACKTEST PARITY (a closed paper trade's net R == the backtester's).
//
// Cost convention under test: costPerShare = max(0, roundTripBps)/10_000 · entry, subtracted from
// the gross exit → a stop-out nets WORSE than −1R, a winner banks LESS than gross R.

struct StockSagePaperTraderTests {

    // 10 bps round-trip, no taker → costFactor 0.001 → costPerShare = 0.001·entry (0.10 at entry 100).
    private let costs = StockSageNetEdge.CostAssumption(spreadBps: 10, slippageBps: 0, assetClass: "test")

    private func d(_ day: Int) -> Date { Date(timeIntervalSince1970: Double(day) * 86_400) }

    private func advice(_ action: TradeAdvice.Action, stop: Double?, target: Double?,
                        conviction: Double = 0.7) -> TradeAdvice {
        TradeAdvice(action: action, conviction: conviction, regime: .bullTrend, rationale: [],
                    stopPrice: stop, targetPrice: target, suggestedWeight: 0.1, caveat: "")
    }
    private func idea(_ symbol: String, price: Double, _ action: TradeAdvice.Action,
                      stop: Double?, target: Double?, conviction: Double = 0.7) -> StockSageIdea {
        StockSageIdea(symbol: symbol, market: "US", price: price,
                      advice: advice(action, stop: stop, target: target, conviction: conviction),
                      spark: [price])
    }
    private func history(_ symbol: String, dates: [Date],
                         opens: [Double], highs: [Double], lows: [Double], closes: [Double]) -> StockSagePriceHistory {
        StockSagePriceHistory(symbol: symbol, dates: dates, opens: opens, highs: highs,
                              lows: lows, closes: closes, volumes: Array(repeating: 0, count: closes.count))
    }

    // MARK: open() gating

    @Test func openOnlyForLongActionableWithDefinedRisk() {
        // Buy-side with stop+target+risk>0 → a long paper trade with the idea's numbers.
        let t = StockSagePaperTrader.open(from: idea("TST", price: 100, .buy, stop: 90, target: 120), at: d(0))
        #expect(t != nil)
        #expect(t?.side == .long)
        #expect(t?.entry == 100 && t?.stop == 90 && t?.target == 120)
        #expect(t?.conviction == 0.7)
        #expect(t?.isOpen == true)
        // strongBuy also opens.
        #expect(StockSagePaperTrader.open(from: idea("TST", price: 100, .strongBuy, stop: 90, target: 120), at: d(0)) != nil)
        // Non-buy actions never open a paper position.
        for a in [TradeAdvice.Action.hold, .avoid, .reduce, .sell] {
            #expect(StockSagePaperTrader.open(from: idea("TST", price: 100, a, stop: 90, target: 120), at: d(0)) == nil)
        }
        // Missing stop OR target → nil (no fabrication).
        #expect(StockSagePaperTrader.open(from: idea("TST", price: 100, .buy, stop: nil, target: 120), at: d(0)) == nil)
        #expect(StockSagePaperTrader.open(from: idea("TST", price: 100, .buy, stop: 90, target: nil), at: d(0)) == nil)
        // Entry at/below the stop → undefined risk → nil.
        #expect(StockSagePaperTrader.open(from: idea("TST", price: 90, .buy, stop: 90, target: 120), at: d(0)) == nil)
        #expect(StockSagePaperTrader.open(from: idea("TST", price: 85, .buy, stop: 90, target: 120), at: d(0)) == nil)
    }

    // MARK: markToMarket — target hit (net R)

    @Test func markToMarketClosesAtTargetNetOfCost() {
        // entry 100, stop 90 (risk 10), target 120. opened at d0 → scan starts at d1 (index 1).
        // d1: high 110 (<120), low 95 (>90) — no hit. d2: high 125 (≥120) → TARGET at 120.
        // costPerShare = 0.001·100 = 0.10 → exitPrice 119.90; R = (119.90−100)/10 = 1.99.
        let t = StockSagePaperTrader.open(from: idea("TST", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        let h = history("TST",
                        dates: [d(0), d(1), d(2), d(3)],
                        opens:  [100, 100, 118, 121],
                        highs:  [100, 110, 125, 122],
                        lows:   [100,  95, 100, 118],
                        closes: [100, 108, 121, 120])
        let out = StockSagePaperTrader.markToMarket([t], history: h, costs: costs).first!
        #expect(out.isOpen == false)
        #expect(out.closedAt == d(2))
        #expect(abs((out.exitPrice ?? 0) - 119.90) < 1e-9)
        #expect(abs((out.realizedR ?? 0) - 1.99) < 1e-9)
    }

    // MARK: markToMarket — stop hit, gap-honest + net (worse than −1R)

    @Test func markToMarketClosesAtGapHonestStopNetOfCost() {
        // d1 gaps DOWN: open 88 (below the 90 stop), low 85. Fills at min(stop 90, open 88) = 88 (gap-honest).
        // exitPrice 88 − 0.10 = 87.90; R = (87.90−100)/10 = −1.21 (friction + gap ⇒ worse than −1R).
        let t = StockSagePaperTrader.open(from: idea("TST", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        let h = history("TST",
                        dates: [d(0), d(1), d(2)],
                        opens:  [100, 88, 90],
                        highs:  [100, 92, 95],
                        lows:   [100, 85, 88],
                        closes: [100, 90, 92])
        let out = StockSagePaperTrader.markToMarket([t], history: h, costs: costs).first!
        #expect(out.isOpen == false)
        #expect(out.closedAt == d(1))
        #expect(abs((out.exitPrice ?? 0) - 87.90) < 1e-9)
        #expect(abs((out.realizedR ?? 0) - (-1.21)) < 1e-9)
    }

    // MARK: markToMarket — stop wins ties (pessimistic; never overstates)

    @Test func markToMarketStopWinsTiesWithinABar() {
        // d1 straddles BOTH: low 85 (≤90 stop) AND high 125 (≥120 target). Must resolve to STOP.
        // open 100 → stop fill min(90, 100) = 90; exitPrice 89.90; R = −1.01. NOT the +2 target.
        let t = StockSagePaperTrader.open(from: idea("TST", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        let h = history("TST",
                        dates: [d(0), d(1)],
                        opens:  [100, 100],
                        highs:  [100, 125],
                        lows:   [100, 85],
                        closes: [100, 110])
        let out = StockSagePaperTrader.markToMarket([t], history: h, costs: costs).first!
        #expect(out.isOpen == false)
        #expect(abs((out.exitPrice ?? 0) - 89.90) < 1e-9)   // stop fill, not the 120 target
        #expect(abs((out.realizedR ?? 0) - (-1.01)) < 1e-9)
    }

    // MARK: markToMarket — time-stop backstop

    @Test func markToMarketTimeStopsAtCloseNetOfCost() {
        // maxHoldingBars 2, neither level hit. entryIdx=1 (d1). Time-stop fires at j where j-1>=2 → j=3 (d3).
        // closes[3]=105 → exitPrice 104.90; R = (104.90−100)/10 = 0.49; closedAt d3.
        let t = StockSagePaperTrader.open(from: idea("TST", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        let h = history("TST",
                        dates: [d(0), d(1), d(2), d(3)],
                        opens:  [100, 101, 103, 104],
                        highs:  [100, 108, 110, 112],
                        lows:   [100,  96,  98,  99],
                        closes: [100, 105, 107, 105])
        let out = StockSagePaperTrader.markToMarket([t], history: h, costs: costs, maxHoldingBars: 2).first!
        #expect(out.isOpen == false)
        #expect(out.closedAt == d(3))
        #expect(abs((out.exitPrice ?? 0) - 104.90) < 1e-9)
        #expect(abs((out.realizedR ?? 0) - 0.49) < 1e-9)
    }

    // MARK: markToMarket — no new data / not-yet-resolved ⇒ stays open (nil = unknown)

    @Test func markToMarketStaysOpenWithoutNewBarsOrAResolution() {
        // (a) opened at the LAST date → no bar strictly after → unchanged, still open.
        let tLast = StockSagePaperTrader.open(from: idea("TST", price: 100, .buy, stop: 90, target: 120), at: d(3))!
        let h = history("TST",
                        dates: [d(0), d(1), d(2), d(3)],
                        opens:  [100, 101, 103, 104],
                        highs:  [100, 108, 110, 112],
                        lows:   [100,  96,  98,  99],
                        closes: [100, 105, 107, 105])
        let outLast = StockSagePaperTrader.markToMarket([tLast], history: h, costs: costs).first!
        #expect(outLast.isOpen == true)
        #expect(outLast.exitPrice == nil)
        // (b) opened at d0, no level hit, time-stop not reached (big maxBars) → openAtEnd → stays open.
        let tOpen = StockSagePaperTrader.open(from: idea("TST", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        let outOpen = StockSagePaperTrader.markToMarket([tOpen], history: h, costs: costs, maxHoldingBars: 63).first!
        #expect(outOpen.isOpen == true)
        // (c) a DIFFERENT symbol's history never touches this trade.
        let other = history("XXX", dates: [d(0), d(1)], opens: [100, 88], highs: [100, 92],
                            lows: [100, 85], closes: [100, 90])
        #expect(StockSagePaperTrader.markToMarket([tOpen], history: other, costs: costs).first?.isOpen == true)
    }

    // MARK: BACKTEST PARITY — the paper net R equals simulateExit + the backtester's net-R formula

    @Test func realizedRMatchesTheBacktesterNetRConvention() {
        let entry = 100.0, stop = 90.0, target = 120.0, risk = entry - stop
        let t = StockSagePaperTrader.open(from: idea("TST", price: entry, .buy, stop: stop, target: target), at: d(0))!
        let h = history("TST",
                        dates: [d(0), d(1), d(2), d(3)],
                        opens:  [100, 100, 118, 121],
                        highs:  [100, 110, 125, 122],
                        lows:   [100,  95, 100, 118],
                        closes: [100, 108, 121, 120])
        // Independently run the backtester's own exit walk + net-R formula.
        let (_, grossExit, _) = StockSageBacktester.simulateExit(
            entryIdx: 1, stop: stop, target: target,
            opens: h.opens, highs: h.highs, lows: h.lows, closes: h.closes, n: h.closes.count,
            mode: .timeStop(maxBars: 63))
        let costPerShare = max(0, costs.roundTripBps) / 10_000 * entry
        let backtesterR = (grossExit - entry - costPerShare) / risk
        let paperR = StockSagePaperTrader.markToMarket([t], history: h, costs: costs).first?.realizedR ?? .nan
        #expect(abs(paperR - backtesterR) < 1e-9)
    }

    // MARK: step() — dedup (one open per symbol) + open only long-actionable

    @Test func stepDoesNotDoubleOpenAndSkipsNonActionable() {
        let aaaOpen = StockSagePaperTrader.open(from: idea("AAA", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        let ideas = [
            idea("AAA", price: 100, .buy, stop: 90, target: 120),        // already open → skip
            idea("BBB", price: 50, .strongBuy, stop: 45, target: 60),    // new → open
            idea("CCC", price: 70, .hold, stop: 65, target: 80),         // not actionable → skip
        ]
        // Empty histories → no mark-to-market close; AAA stays open.
        let (closes, opens) = StockSagePaperTrader.step(
            current: [aaaOpen], ideas: ideas, histories: [:], openDate: d(1),
            costsFor: { _ in self.costs })
        #expect(closes.isEmpty)
        #expect(opens.count == 1)
        #expect(opens.first?.symbol == "BBB")
        #expect(opens.first?.openedAt == d(1))
    }

    // MARK: step() — a closed trade this step frees the symbol to re-open

    @Test func stepReopensAfterAMarkToMarketClose() {
        // AAA open; its history closes it at target this step; a fresh AAA idea then re-opens.
        let aaaOpen = StockSagePaperTrader.open(from: idea("AAA", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        let h = history("AAA",
                        dates: [d(0), d(1), d(2)],
                        opens:  [100, 100, 121],
                        highs:  [100, 125, 122],   // d1 hits the 120 target
                        lows:   [100,  95, 118],
                        closes: [100, 121, 120])
        let (closes, opens) = StockSagePaperTrader.step(
            current: [aaaOpen], ideas: [idea("AAA", price: 121, .buy, stop: 110, target: 140)],
            histories: ["AAA": h], openDate: d(2), costsFor: { _ in self.costs })
        #expect(closes.count == 1)
        #expect(closes.first?.isOpen == false)
        #expect(opens.count == 1)          // the symbol freed up → the new AAA idea opens
        #expect(opens.first?.symbol == "AAA")
        #expect(opens.first?.entry == 121)
    }

    // MARK: step() — a missing history for an open symbol must still block a reopen (dedup)

    @Test func stepMissingHistoryForAnOpenSymbolStillBlocksReopen() {
        let aaaOpen = StockSagePaperTrader.open(from: idea("AAA", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        // AAA is open but absent from histories → not marked-to-market, and must NOT be re-opened by a fresh AAA idea.
        let (closes, opens) = StockSagePaperTrader.step(
            current: [aaaOpen], ideas: [idea("AAA", price: 105, .buy, stop: 95, target: 125)],
            histories: [:], openDate: d(1), costsFor: { _ in self.costs })
        #expect(closes.isEmpty)   // no history → no close
        #expect(opens.isEmpty)    // still-open AAA blocks the reopen even with no history this step
    }

    // MARK: markToMarket — mixed array processed per-element (multi-trade + closed/short passthrough)

    @Test func markToMarketHandlesAMixedArrayPerElement() {
        let resolving = StockSagePaperTrader.open(from: idea("TST", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        let staying   = StockSagePaperTrader.open(from: idea("TST", price: 100, .buy, stop: 90, target: 120), at: d(3))! // opened at last bar → no bar after → stays open
        var preClosed = StockSagePaperTrader.open(from: idea("TST", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        preClosed.exitPrice = 115; preClosed.closedAt = d(1)   // already closed → passthrough, untouched
        let shortT = TradeRecord(symbol: "TST", side: .short, entry: 100, stop: 110, target: 90, shares: 1, openedAt: d(0)) // short → passthrough
        let h = history("TST",
                        dates: [d(0), d(1), d(2), d(3)],
                        opens:  [100, 100, 118, 121],
                        highs:  [100, 110, 125, 122],
                        lows:   [100,  95, 100, 118],
                        closes: [100, 108, 121, 120])
        let out = StockSagePaperTrader.markToMarket([resolving, staying, preClosed, shortT], history: h, costs: costs)
        #expect(out.count == 4)
        #expect(out[0].isOpen == false)                              // resolving long closed at target
        #expect(out[1].isOpen == true)                               // opened at the last bar → stays open
        #expect(out[2].isOpen == false && out[2].exitPrice == 115)   // pre-closed passthrough (unchanged)
        #expect(out[3].side == .short && out[3].isOpen == true)      // short passthrough (never marked)
    }

    // MARK: StockSagePaperTradeStore — the honesty-floor SEPARATION guarantee (isolated suite, no global collision)

    /// A paper store backed by a throwaway UserDefaults suite — isolates storage per testing-discipline
    /// (no two tests share a global key). Caller removes the suite in a defer.
    private func isolatedStore() -> (store: StockSagePaperTradeStore, defaults: UserDefaults, suite: String) {
        let suite = "papertrader.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (StockSagePaperTradeStore(defaults: defaults, key: "stocksage.papertrades.v1"), defaults, suite)
    }

    @Test func paperStoreUsesItsOwnKeyNotTheJournalKeyAndRoundTrips() {
        let (store, defaults, suite) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let t = StockSagePaperTrader.open(from: idea("AAA", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        store.add(t)
        // Persisted under the PAPER key; the journal's key is NEVER written by the paper store.
        #expect(defaults.data(forKey: "stocksage.papertrades.v1") != nil)
        #expect(defaults.data(forKey: "stocksage.journal.v1") == nil)
        // Round-trip: a fresh store on the same suite decodes the saved trade back.
        let reloaded = StockSagePaperTradeStore(defaults: defaults, key: "stocksage.papertrades.v1")
        #expect(reloaded.trades.count == 1)
        #expect(reloaded.trades.first?.symbol == "AAA")
        #expect(reloaded.trades.first?.isOpen == true)
    }

    @Test func applyCloseReplacesOnlyTheIdMatchingTrade() {
        let (store, defaults, suite) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = StockSagePaperTrader.open(from: idea("AAA", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        let b = StockSagePaperTrader.open(from: idea("BBB", price: 50, .buy, stop: 45, target: 60), at: d(0))!
        store.add(a); store.add(b)
        var closedA = a; closedA.exitPrice = 118; closedA.closedAt = d(2)
        store.applyClose(closedA)
        #expect(store.trades.first(where: { $0.id == a.id })?.isOpen == false)   // A now closed
        #expect(store.trades.first(where: { $0.id == b.id })?.isOpen == true)    // B untouched
        #expect(store.open.count == 1 && store.closed.count == 1)
    }

    // MARK: MEM-01a — batch apply(closes:opens:) end-state equivalence to the per-call loop
    //
    // `save()` is private with no call-count seam (adding one would be new production surface
    // for a test-only need — not worth it for a single production call site). Verified instead:
    // (1) END-STATE equivalence below — same `trades` array, same order, as the original loop
    //     (`for c in closes { applyClose(c) }; for o in opens { add(o) }`), on TWO independent
    //     stores built one each way; (2) BY CONSTRUCTION — `apply(closes:opens:)`'s body (read
    //     in the diff) contains exactly ONE `save()` call after the mutations, vs. the loop's
    //     one `save()` per `applyClose`/`add` invocation (N+M calls for N closes + M opens).

    @Test func batchApplyEndStateMatchesTheLoopItReplaces() {
        let (loopStore, loopDefaults, loopSuite) = isolatedStore()
        defer { loopDefaults.removePersistentDomain(forName: loopSuite) }
        let (batchStore, batchDefaults, batchSuite) = isolatedStore()
        defer { batchDefaults.removePersistentDomain(forName: batchSuite) }

        // Seed both stores identically: two open trades (AAA, BBB) before this "cycle".
        let a = StockSagePaperTrader.open(from: idea("AAA", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        let b = StockSagePaperTrader.open(from: idea("BBB", price: 50, .buy, stop: 45, target: 60), at: d(0))!
        loopStore.add(a); loopStore.add(b)
        batchStore.add(a); batchStore.add(b)

        // This cycle: AAA closes, two NEW paper trades open (CCC, DDD) — mirrors updatePaperTrades'
        // (closes, opens) from StockSagePaperTrader.step.
        var closedA = a; closedA.exitPrice = 118; closedA.closedAt = d(2)
        let c = StockSagePaperTrader.open(from: idea("CCC", price: 30, .buy, stop: 27, target: 36), at: d(2))!
        let e = StockSagePaperTrader.open(from: idea("DDD", price: 200, .buy, stop: 180, target: 240), at: d(2))!

        // Old path: the loop this fix replaces.
        for close in [closedA] { loopStore.applyClose(close) }
        for open in [c, e] { loopStore.add(open) }

        // New path: one batch call.
        batchStore.apply(closes: [closedA], opens: [c, e])

        // Same symbols, same order, same open/closed state.
        #expect(batchStore.trades.map(\.id) == loopStore.trades.map(\.id))
        #expect(batchStore.trades.map(\.symbol) == loopStore.trades.map(\.symbol))
        #expect(batchStore.trades.map(\.isOpen) == loopStore.trades.map(\.isOpen))
        #expect(batchStore.trades.count == 4)
        // The specific end-state both must reach — hand-derived in /tmp/derive_batch_order2.swift,
        // INCLUDING the seed step (add(a); add(b) already leaves [BBB, AAA], B before A, since
        // each add is insert(at: 0)): seed [BBB, AAA] -> AAA replaced in place by its closed
        // version -> [BBB, AAA(closed)] -> opens CCC then DDD each insert(at: 0) -> [DDD, CCC,
        // BBB, AAA(closed)].
        #expect(batchStore.trades.map(\.symbol) == ["DDD", "CCC", "BBB", "AAA"])
        #expect(batchStore.trades.first(where: { $0.symbol == "AAA" })?.isOpen == false)
        #expect(batchStore.trades.first(where: { $0.symbol == "BBB" })?.isOpen == true)
        #expect(batchStore.trades.first(where: { $0.symbol == "CCC" })?.isOpen == true)

        // Round-trips from UserDefaults too — the ONE save() actually persisted the full end state.
        let reloaded = StockSagePaperTradeStore(defaults: batchDefaults, key: "stocksage.papertrades.v1")
        #expect(reloaded.trades.count == 4)
        #expect(reloaded.trades.first(where: { $0.symbol == "AAA" })?.isOpen == false)
    }

    @Test func batchApplyIsANoOpWhenBothListsAreEmpty() {
        let (store, defaults, suite) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = StockSagePaperTrader.open(from: idea("AAA", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        store.add(a)
        store.apply(closes: [], opens: [])
        #expect(store.trades.count == 1)
        #expect(store.trades.first?.id == a.id)
    }

    // MARK: forwardStats — the FORWARD net-of-cost milestone read (DSR/PSR) on the paper record

    /// A CLOSED long paper trade with a chosen realized R: entry 100, stop 90 (risk 10),
    /// exit = 100 + 10·r ⇒ realizedR == r exactly.
    private func closedR(_ r: Double) -> TradeRecord {
        TradeRecord(symbol: "TST", side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                    openedAt: d(0), exitPrice: 100 + 10 * r, closedAt: d(1))
    }

    @Test func forwardStatsNilBelowFourClosedTrades() {
        // 3 closed-with-R → moments() nil → forwardStats nil (honest "too few to read").
        #expect(StockSagePaperTrader.forwardStats([closedR(2), closedR(-1), closedR(1)]) == nil)
        // An OPEN trade carries no realized R → does not count toward the 4.
        let open = StockSagePaperTrader.open(from: idea("Z", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        #expect(StockSagePaperTrader.forwardStats([closedR(2), closedR(-1), closedR(1), open]) == nil)
    }

    @Test func forwardStatsComputesWinRateAvgRAndSharpe() {
        // R = [2, 1, -1, 1.5]. Standalone-derived (/tmp/derive_paperfwd.swift): avgR 0.875, winRate 0.75,
        // sample-stdev 1.31497782, sharpe 0.66541046.
        let fs = StockSagePaperTrader.forwardStats([closedR(2), closedR(1), closedR(-1), closedR(1.5)])!
        #expect(fs.closed == 4)
        #expect(abs(fs.winRate - 0.75) < 1e-9)
        #expect(abs(fs.avgR - 0.875) < 1e-9)
        #expect(abs(fs.sharpe - 0.66541046) < 1e-6)   // mean ÷ SAMPLE stdev (matches the backtester)
    }

    @Test func forwardStatsWiresRSeriesIntoDeflatedSharpeWithTrialsOne() {
        let rs = [2.0, 1.0, -1.0, 1.5]
        let fs = StockSagePaperTrader.forwardStats(rs.map(closedR))!
        // Independently recompute the deflated Result with the inputs forwardStats should pass: its own
        // sharpe, n=4, the moments of the R-series, trials:1 (⇒ DSR == PSR, no selection-bias haircut).
        let m = StockSageDeflatedSharpe.moments(rs)!
        let expected = StockSageDeflatedSharpe.deflated(observedSharpe: fs.sharpe, nTrades: 4,
                                                        skew: m.skew, kurtosis: m.kurtosis,
                                                        trials: 1, varTrialSharpe: 0)
        #expect(fs.deflated == expected)
        #expect(fs.deflated.trials == 1)                    // forward OOS ⇒ no NEW selection bias
        #expect(fs.deflated.dsr == fs.deflated.psr)         // trials:1 ⇒ DSR == PSR
        #expect(fs.passesForwardBar == fs.deflated.passes)  // milestone bar reflects dsr > 0.95
    }

    // MARK: save() cross-process reconciliation (LOST-UPDATE FIX, 2026-07-09 — from live data:
    // GE/SAN.MC/O39.SI double-opened while the store held zero closes; a second app instance's
    // stale whole-array save had resurrected closed trades. Two stores on ONE suite simulate
    // the two processes.)

    @Test func staleProcessSaveCannotResurrectAClosedTrade() {
        let (a, defaults, suite) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let t = StockSagePaperTrader.open(from: idea("AAA", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        a.add(t)
        // Process B loads while AAA is open.
        let b = StockSagePaperTradeStore(defaults: defaults, key: "stocksage.papertrades.v1")
        #expect(b.trades.first?.isOpen == true)
        // Process A closes AAA and saves.
        var closed = t
        closed.exitPrice = 88.5
        closed.closedAt = d(5)
        a.applyClose(closed)
        // Process B (stale open copy in memory) saves — e.g. by adding an unrelated trade.
        let other = StockSagePaperTrader.open(from: idea("BBB", price: 50, .buy, stop: 45, target: 60), at: d(1))!
        b.add(other)
        // The disk truth must still hold AAA CLOSED (pre-fix: B's whole-array write resurrected it open).
        let final = StockSagePaperTradeStore(defaults: defaults, key: "stocksage.papertrades.v1")
        let aaa = final.trades.first { $0.symbol == "AAA" }
        #expect(aaa?.isOpen == false)
        #expect(aaa?.closedAt == d(5))
        #expect(final.trades.contains { $0.symbol == "BBB" })   // B's own open persisted too
    }

    @Test func foreignOpensSurviveAStaleSave() {
        let (a, defaults, suite) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        // Process B loads an EMPTY store, then A opens a trade, then B saves its (empty) state
        // via an unrelated add — A's trade must survive (pre-fix: B's write dropped it).
        let b = StockSagePaperTradeStore(defaults: defaults, key: "stocksage.papertrades.v1")
        let t = StockSagePaperTrader.open(from: idea("AAA", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        a.add(t)
        let other = StockSagePaperTrader.open(from: idea("BBB", price: 50, .buy, stop: 45, target: 60), at: d(1))!
        b.add(other)
        let final = StockSagePaperTradeStore(defaults: defaults, key: "stocksage.papertrades.v1")
        #expect(Set(final.trades.map(\.symbol)) == ["AAA", "BBB"])
    }

    @Test func resetAndRemoveStillDeleteDespiteTheReconcilingSave() {
        let (a, defaults, suite) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let t = StockSagePaperTrader.open(from: idea("AAA", price: 100, .buy, stop: 90, target: 120), at: d(0))!
        a.add(t)
        // remove() bypasses reconciliation — the record must NOT come back from disk.
        a.remove(t.id)
        #expect(StockSagePaperTradeStore(defaults: defaults, key: "stocksage.papertrades.v1").trades.isEmpty)
        a.add(t)
        a.reset()
        #expect(StockSagePaperTradeStore(defaults: defaults, key: "stocksage.papertrades.v1").trades.isEmpty)
    }

    // MARK: - scoreboard(_:latestClose:) — the bias-corrected forward bracket
    //
    // The closed-only read is selection-biased (fast stop-outs resolve before slow targets), so
    // scoreboard() marks still-open LONGS to the latest close for a second bound. Realized ≈ lower
    // (loser-enriched) and full ≈ upper (open marks lean optimistic); the truth sits between them.

    private func closed(_ sym: String, entry: Double, stop: Double, exit: Double) -> TradeRecord {
        TradeRecord(symbol: sym, side: .long, entry: entry, stop: stop, target: nil, shares: 1,
                    openedAt: d(0), exitPrice: exit, closedAt: d(5))
    }
    private func open(_ sym: String, entry: Double, stop: Double, side: TradeRecord.Side = .long) -> TradeRecord {
        TradeRecord(symbol: sym, side: side, entry: entry, stop: stop, target: nil, shares: 1, openedAt: d(0))
    }

    @Test func scoreboardBracketsRealizedAndFull() {
        // Realized: +3R (exit 130), +2R (exit 120), −1R (exit 90) → realized avg = 4/3, win 2/3.
        // Open long C marked at 105 → unrealized (105−100)/10 = +0.5R. Open D has no price → dropped.
        let trades = [closed("A", entry: 100, stop: 90, exit: 130),
                      closed("B", entry: 100, stop: 90, exit: 120),
                      closed("L", entry: 100, stop: 90, exit: 90),
                      open("C", entry: 100, stop: 90),
                      open("D", entry: 100, stop: 90)]
        let sb = StockSagePaperTrader.scoreboard(trades, latestClose: ["C": 105])!
        #expect(sb.realizedN == 3)
        #expect(abs(sb.realizedAvgR - 4.0 / 3.0) < 1e-9)
        #expect(abs(sb.realizedWinRate - 2.0 / 3.0) < 1e-9)
        // Full = [+3, +2, −1, +0.5] → avg 4.5/4 = 1.125, win 3/4 = 0.75, one open marked.
        #expect(sb.fullN == 4)
        #expect(abs(sb.fullAvgR - 1.125) < 1e-9)
        #expect(abs(sb.fullWinRate - 0.75) < 1e-9)
        #expect(sb.openMarked == 1)
        #expect(abs(sb.resolvedFrac - 0.75) < 1e-9)   // 3 realized / 4 evaluable
    }

    @Test func scoreboardNilUnderFourEvaluable() {
        // Two realized + one markable open = 3 < 4 → nil (too thin to read).
        let trades = [closed("A", entry: 100, stop: 90, exit: 130),
                      closed("B", entry: 100, stop: 90, exit: 110),
                      open("C", entry: 100, stop: 90)]
        #expect(StockSagePaperTrader.scoreboard(trades, latestClose: ["C": 105]) == nil)
    }

    @Test func scoreboardSkipsShortsAndDegenerateAndMissingPrice() {
        // Only LONG opens with a price and entry≠stop get marked. A short, an entry==stop, and a
        // priced-but-absent symbol are all dropped — leaving 4 realized so the result is defined.
        let trades = [closed("A", entry: 100, stop: 90, exit: 130),
                      closed("B", entry: 100, stop: 90, exit: 120),
                      closed("E", entry: 100, stop: 90, exit: 110),
                      closed("F", entry: 100, stop: 90, exit: 105),
                      open("S", entry: 100, stop: 90, side: .short),   // short → skipped
                      open("Z", entry: 100, stop: 100),                // entry==stop → skipped (div-by-0)
                      open("M", entry: 100, stop: 90)]                 // no latestClose entry → skipped
        let sb = StockSagePaperTrader.scoreboard(trades, latestClose: ["S": 80, "Z": 110])!
        #expect(sb.openMarked == 0)
        #expect(sb.fullN == 4)          // only the 4 realized
        #expect(sb.realizedN == 4)
        #expect(sb.resolvedFrac == 1.0) // nothing open counted → fully resolved
    }
}
