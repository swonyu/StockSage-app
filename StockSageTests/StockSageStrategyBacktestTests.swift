import Testing
import Foundation
@testable import StockSage

// MARK: - Aggregate (strategy-wide) backtest (pure)

struct StockSageStrategyBacktestTests {

    private func result(trades: Int, wins: Int, totalR: Double, maxDD: Double) -> BacktestResult {
        BacktestResult(trades: trades, wins: wins,
                       winRate: trades > 0 ? Double(wins) / Double(trades) : 0,
                       avgR: trades > 0 ? totalR / Double(trades) : 0,
                       totalR: totalR, maxDrawdownR: maxDD, sharpe: 0, avgHoldBars: 5)
    }

    @Test func momentCorrectedTStatIsHonestVsRaw() {
        func agg(_ rs: [Double]) -> StrategyBacktest {
            let t = rs.map { BacktestTrade(entryIndex: 0, exitIndex: 1, entry: 100, exit: 100, r: $0,
                                           outcome: .target, conviction: 0.5) }
            return StockSageStrategyBacktest.aggregate([], trades: t)
        }
        // Positive-edge sample: the skew/fat-tail-adjusted t is positive but BELOW the raw t
        // (the Sharpe-estimator SE widens with SR, and uses n−1 not n).
        let edge = Array(repeating: 1.0, count: 60) + Array(repeating: -1.0, count: 40)
        let a = agg(edge)
        #expect(a.tStat > 0)
        #expect(a.momentCorrectedTStat > 0)
        #expect(a.momentCorrectedTStat < a.tStat)
        // Inject a rare fat negative tail → heavier left tail lowers the adjusted t below the raw further.
        let b = agg(edge + [-8.0, -8.0])
        #expect(b.momentCorrectedTStat < b.tStat)
        // Too few trades → undefined moments → 0 (no false precision).
        #expect(agg([0.5, -0.5, 0.5]).momentCorrectedTStat == 0)
    }

    @Test func honestSignificanceGatesOnSampleAndFatTails() {
        func bt(trades: Int, t: Double, adj: Double) -> StrategyBacktest {
            StrategyBacktest(symbolsTested: 1, symbolsWithTrades: 1, symbolsProfitable: 1,
                             totalTrades: trades, wins: trades / 2, blendedWinRate: 0.5, avgR: 0.1,
                             totalR: 1, worstDrawdownR: 1, tStat: t, momentCorrectedTStat: adj, caveat: "x")
        }
        // <100 trades but raw t>3 → NOT an honest pass; verdict says not meaningful (no green check, #8).
        let thin = bt(trades: 40, t: 4.0, adj: 4.0)
        #expect(!thin.passesHonestSignificance)
        #expect(thin.significanceVerdict.contains("isn't statistically meaningful"))
        // Enough trades, raw t>3, but the fat-tail-corrected t FAILS → not a pass; verdict flags it (#10).
        let fat = bt(trades: 200, t: 4.0, adj: 2.5)
        #expect(!fat.passesHonestSignificance)
        #expect(fat.significanceVerdict.contains("does NOT"))
        // Enough trades, both raw and adjusted clear → honest pass.
        let solid = bt(trades: 200, t: 4.0, adj: 3.5)
        #expect(solid.passesHonestSignificance)
        #expect(solid.significanceVerdict.contains("clears the t>3"))
        // Adjusted unknown (0) doesn't block a pass (can't penalize what we couldn't compute).
        #expect(bt(trades: 200, t: 4.0, adj: 0).passesHonestSignificance)
    }

    @Test func deflatedSharpeSealRequiresMeaningfulSample() {
        // #8: the green DSR "PASS" seal (deflatedSharpeShowsPass) may light ONLY when the sample is
        // statistically meaningful (≥100 trades). DSR.passes is dsr>0.95 and DSR populates at n≥4, so
        // a high small-sample Sharpe can clear 0.95 — that must NOT light a green seal beside the
        // "<100 trades, not meaningful yet" verdict. Mirrors the per-symbol PSR gate (round-g FIX-4).
        func bt(trades: Int, dsr: Double) -> StrategyBacktest {
            StrategyBacktest(symbolsTested: 1, symbolsWithTrades: 1, symbolsProfitable: 1,
                             totalTrades: trades, wins: trades / 2, blendedWinRate: 0.5, avgR: 0.1,
                             totalR: 1, worstDrawdownR: 1,
                             deflatedSharpe: .init(psr: dsr, dsr: dsr, trials: 5), caveat: "x")
        }
        // DSR clears its 0.95 bar, but only 50 trades → seal WITHHELD (the load-bearing straddle:
        // passes is true while deflatedSharpeShowsPass is false — a regression dropping `&& isSignificant`
        // fails right here).
        let thin = bt(trades: 50, dsr: 0.99)
        #expect(thin.deflatedSharpe?.passes == true)   // the raw DSR bar IS cleared…
        #expect(!thin.isSignificant)                    // …but the sample isn't meaningful…
        #expect(!thin.deflatedSharpeShowsPass)          // …so the seal stays dark (#8).
        // DSR clears the bar AND ≥100 trades → seal shows.
        #expect(bt(trades: 150, dsr: 0.99).deflatedSharpeShowsPass)
        // ≥100 trades but DSR below the bar → no seal (unchanged behaviour).
        #expect(!bt(trades: 150, dsr: 0.50).deflatedSharpeShowsPass)
        // No DSR computed at all → no seal.
        #expect(!StrategyBacktest(symbolsTested: 1, symbolsWithTrades: 1, symbolsProfitable: 1,
                                  totalTrades: 150, wins: 75, blendedWinRate: 0.5, avgR: 0.1,
                                  totalR: 1, worstDrawdownR: 1, caveat: "x").deflatedSharpeShowsPass)
    }

    @Test func pooledTStatFromTrades() {
        // No trades supplied → tStat 0 (default, behaviour unchanged).
        #expect(StockSageStrategyBacktest.aggregate([result(trades: 10, wins: 6, totalR: 5, maxDD: 3)]).tStat == 0)
        // Pooled trades with a positive mean and real dispersion → positive, finite t.
        let trades = (0..<120).map { i in
            BacktestTrade(entryIndex: 0, exitIndex: 1, entry: 100, exit: 100,
                          r: i.isMultiple(of: 3) ? -1.0 : 2.0, outcome: .target)   // ~2/3 win, mean>0
        }
        let agg = result(trades: 120, wins: 80, totalR: 80, maxDD: 5)
        let s = StockSageStrategyBacktest.aggregate([agg], trades: trades)
        #expect(s.tStat > 0)
        #expect(s.isSignificant)                       // 120 ≥ 100
        #expect(s.significanceVerdict.contains("t ="))
        // Zero dispersion (all identical R) → tStat 0, not a divide-by-zero.
        let flat = (0..<120).map { _ in BacktestTrade(entryIndex: 0, exitIndex: 1, entry: 100, exit: 100, r: 1.0, outcome: .target) }
        #expect(StockSageStrategyBacktest.aggregate([agg], trades: flat).tStat == 0)
    }

    @Test func aggregatesSumsAndRates() {
        let a = result(trades: 10, wins: 6, totalR: 5, maxDD: 3)     // profitable
        let b = result(trades: 5, wins: 2, totalR: -1, maxDD: 4)     // losing
        let c = result(trades: 0, wins: 0, totalR: 0, maxDD: 0)      // never traded
        let s = StockSageStrategyBacktest.aggregate([a, b, c])
        #expect(s.symbolsTested == 3)
        #expect(s.symbolsWithTrades == 2)
        #expect(s.symbolsProfitable == 1)                            // only `a`
        #expect(s.totalTrades == 15)
        #expect(s.wins == 8)
        #expect(abs(s.blendedWinRate - 8.0 / 15.0) < 1e-9)
        #expect(abs(s.totalR - 4) < 1e-9)
        #expect(abs(s.avgR - 4.0 / 15.0) < 1e-9)
        #expect(s.worstDrawdownR == 4)                               // max(3,4)
        #expect(s.isSignificant == false)                           // 15 < 100
    }

    @Test func emptyAggregatesToZero() {
        let s = StockSageStrategyBacktest.aggregate([])
        #expect(s.symbolsTested == 0)
        #expect(s.totalTrades == 0)
        #expect(s.blendedWinRate == 0)
        #expect(s.avgR == 0)
        #expect(s.isSignificant == false)
    }

    @Test func significanceNeedsHundredTrades() {
        let big = result(trades: 120, wins: 60, totalR: 10, maxDD: 8)
        #expect(StockSageStrategyBacktest.aggregate([big]).isSignificant)
    }

    @Test func sampleIsNonTrivialAndUnique() {
        let s = StockSageStrategyBacktest.sampleSymbols
        #expect(s.count >= 15)
        #expect(Set(s).count == s.count)
    }

    // MARK: - Pooled portfolio-proxy drawdown golden vector
    //
    // Hand-derivation:
    //   SymA: (d1,+3) (d3,−2) (d5,−2)   per-sym cum: 3 → 1 → −1   DD = 3−(−1) = 4
    //   SymB: (d2,+1) (d4,−4) (d6,+2)   per-sym cum: 1 → −3 → −1  DD = 1−(−3) = 4
    //   → worstDrawdownR = max(4, 4) = 4  (per-symbol max, unchanged by this addition)
    //
    //   Chronological merge: d1,d2,d3,d4,d5,d6 → R: +3,+1,−2,−4,−2,+2
    //   Cumulative R:        3, 4, 2, −2, −4, −2
    //   Peak so far:         3, 4, 4,  4,  4,  4
    //   Draw:                0, 0, 2,  6,  8,  6
    //   → pooledDrawdownR = 8.0   (peak +4 at d2 → trough −4 at d5)
    //
    // The pooled proxy (8.0) > worst-name (4.0) because cross-symbol losses stack
    // chronologically — the same phenomenon as the 27.67-vs-17.28 production measurement.
    @Test func pooledDrawdownIsChronologicalAndHonestVsPerName() throws {
        let dayA = [1.0, 3.0, 5.0].map { Date(timeIntervalSince1970: $0 * 86_400) }
        let dayB = [2.0, 4.0, 6.0].map { Date(timeIntervalSince1970: $0 * 86_400) }
        func tr(_ r: Double) -> BacktestTrade {
            BacktestTrade(entryIndex: 0, exitIndex: 1, entry: 100, exit: 100, r: r, outcome: .target)
        }
        // Trades supplied in received order: A's three then B's three (un-sorted across symbols).
        let trades = [tr(3), tr(-2), tr(-2),  tr(1), tr(-4), tr(2)]
        // 1:1 aligned entry dates — the sort will interleave them chronologically.
        let dates  = [dayA[0], dayA[1], dayA[2], dayB[0], dayB[1], dayB[2]]
        // Per-symbol results whose maxDrawdownR = 4 each → worstDrawdownR stays 4.
        let rA = BacktestResult(trades: 3, wins: 1,
                                winRate: 1.0/3, avgR: -1.0/3, totalR: -1,
                                maxDrawdownR: 4, sharpe: 0, avgHoldBars: 1)
        let rB = BacktestResult(trades: 3, wins: 2,
                                winRate: 2.0/3, avgR: -1.0/3, totalR: -1,
                                maxDrawdownR: 4, sharpe: 0, avgHoldBars: 1)
        let s = StockSageStrategyBacktest.aggregate([rA, rB], trades: trades, tradeEntryDates: dates)
        // Golden vector: chronological pooled curve has peak +4 (d2) → trough −4 (d5) ⇒ DD = 8.
        #expect(abs(s.pooledDrawdownR - 8.0) < 1e-9,
                "pooledDrawdownR expected 8.0, got \(s.pooledDrawdownR)")
        // Per-symbol max drawdown is UNCHANGED by this addition.
        #expect(abs(s.worstDrawdownR - 4.0) < 1e-9,
                "worstDrawdownR expected 4.0, got \(s.worstDrawdownR)")
        // The pooled proxy is strictly larger here because cross-symbol losses stack in time.
        #expect(s.pooledDrawdownR > s.worstDrawdownR,
                "pooled DD (\(s.pooledDrawdownR)) should exceed worst-name DD (\(s.worstDrawdownR))")
    }

    // Verify the fallback path: when tradeEntryDates is omitted, pooledDrawdownR uses
    // received order (which for a single symbol is already entry-ordered — still valid).
    @Test func pooledDrawdownFallbackNoDatesSingleSymbol() {
        // Single symbol: 3 trades in entry order +2, −3, +1 → cum: 2, −1, 0 → DD = 2−(−1) = 3
        func tr(_ r: Double) -> BacktestTrade {
            BacktestTrade(entryIndex: 0, exitIndex: 1, entry: 100, exit: 100, r: r, outcome: .target)
        }
        let trades = [tr(2), tr(-3), tr(1)]
        let r = BacktestResult(trades: 3, wins: 2,
                               winRate: 2.0/3, avgR: 0, totalR: 0,
                               maxDrawdownR: 3, sharpe: 0, avgHoldBars: 1)
        let s = StockSageStrategyBacktest.aggregate([r], trades: trades)  // no tradeEntryDates
        #expect(abs(s.pooledDrawdownR - 3.0) < 1e-9,
                "fallback pooledDrawdownR expected 3.0, got \(s.pooledDrawdownR)")
        #expect(s.pooledDrawdownR >= 0)
    }

    @Test func aggregateSymbolWithZeroReturnIsNotProfitable() {
        let symbols = [
            BacktestResult(trades: 10, wins: 5, winRate: 0.5, avgR: 0, totalR: 0, maxDrawdownR: 2, sharpe: 0, avgHoldBars: 5),
            BacktestResult(trades: 5, wins: 2, winRate: 0.4, avgR: -0.2, totalR: -1, maxDrawdownR: 3, sharpe: -0.5, avgHoldBars: 4)
        ]
        let s = StockSageStrategyBacktest.aggregate(symbols)
        #expect(s.symbolsTested == 2)
        #expect(s.symbolsWithTrades == 2)
        #expect(s.symbolsProfitable == 0)
        #expect(abs(s.totalR - (-1)) < 1e-9)
    }
}
