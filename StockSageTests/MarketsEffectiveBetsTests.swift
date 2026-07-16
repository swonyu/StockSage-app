import Testing
import Foundation
@testable import StockSage

// MARK: - Deploy-capital effective-bets diagnostic (L1, 2026-07-09, DISPLAY-ONLY)
//
// Pins MarketsView.deployEffectiveBets(positions:ideas:) (the pure symbol/spark → EffectiveBets
// mapping) and MarketsView.effectiveBetsCaption(_:) (the on-screen/copy-plan formatter — both the
// visible Text and the "Copy allocation plan" button call this SAME function on the SAME computed
// EffectiveBets, so on-screen and copied text can't drift; see StockSageCorrelationClusterTests
// for the underlying effectiveBets() math, hand-derived in derive_effective_bets.swift).

struct MarketsEffectiveBetsTests {
    typealias M = MarketsView

    private func pos(_ symbol: String) -> AllocatedPosition {
        AllocatedPosition(symbol: symbol, riskFraction: 0.02, shares: 1,
                          dollarsAtRisk: 100, notional: 1000, halfKelly: 0.1, evR: 1.0)
    }

    private func idea(_ symbol: String, spark: [Double]) -> StockSageIdea {
        StockSageIdea(symbol: symbol, market: symbol, price: 100,
                      advice: TradeAdvice(action: .buy, conviction: 0.7, regime: .bullTrend,
                                         rationale: [], stopPrice: 90, targetPrice: 130,
                                         suggestedWeight: 0.05, caveat: "x"),
                      spark: spark)
    }

    @Test func caption_pinnedForOneHandBuiltEffectiveBets() {
        let eb = EffectiveBets(nEff: 1.8, meanPairwise: 1.0 / 3.0, n: 3, windowBars: 20)
        #expect(M.effectiveBetsCaption(eb) == "Effective bets ≈ 1.8 of 3 — correlated positions count less")
    }

    @Test func deployEffectiveBets_nonNilForTwoPositionsWithSharedSpark() {
        // 21-bar identical spark → 20 daily returns each, at the effectiveBets minBars=20 floor.
        // Identical series → correlation 1.0 exactly (same reasoning as
        // threeIdenticalSeriesGiveFullyConcentratedNEffOfOne) → n_eff = 2/(1+1*1) = 1.0.
        let spark = (0..<21).map { 100.0 + ($0 % 2 == 0 ? 1.0 : -1.0) }
        let positions = [pos("AAA"), pos("BBB")]
        let ideas = [idea("AAA", spark: spark), idea("BBB", spark: spark)]
        let eb = M.deployEffectiveBets(positions: positions, ideas: ideas)
        #expect(eb != nil)
        guard let eb else { Issue.record("deployEffectiveBets returned nil"); return }
        #expect(abs(eb.nEff - 1.0) < 1e-9)
        #expect(eb.n == 2)
    }

    @Test func deployEffectiveBets_nilBelowTwoPositions() {
        let spark = (0..<21).map { Double($0) }
        #expect(M.deployEffectiveBets(positions: [pos("AAA")], ideas: [idea("AAA", spark: spark)]) == nil)
        #expect(M.deployEffectiveBets(positions: [], ideas: []) == nil)
    }

    @Test func deployEffectiveBets_nilWhenSparkTooShortForMinBars() {
        // Only 5 spark points -> 4 daily returns, below the default minBars=20 floor.
        let shortSpark = [100.0, 101.0, 99.0, 102.0, 98.0]
        let positions = [pos("AAA"), pos("BBB")]
        let ideas = [idea("AAA", spark: shortSpark), idea("BBB", spark: shortSpark)]
        #expect(M.deployEffectiveBets(positions: positions, ideas: ideas) == nil)
    }

    @Test func deployEffectiveBets_nilWhenIdeaMissingLeavesEmptySpark() {
        // A position whose symbol has no matching idea reads spark [] (sparkBy[$0] ?? []) ->
        // dailyReturns([]) = [] -> minLen 0 < minBars -> nil. Never a fabricated correlation.
        let spark = (0..<21).map { Double($0) }
        let positions = [pos("AAA"), pos("BBB")]
        let ideas = [idea("AAA", spark: spark)]   // BBB missing
        #expect(M.deployEffectiveBets(positions: positions, ideas: ideas) == nil)
    }
}
