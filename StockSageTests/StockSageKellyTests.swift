import Testing
import Foundation
@testable import StockSage

// MARK: - Fractional Kelly (pure)

struct StockSageKellyTests {

    @Test func portfolioCapPinsBookHeatToTheCeiling() {
        // Ten half-Kelly bets at 0.20 each → requested 2.0 (2× the account, a ruin setup per-position
        // Kelly can't see). Cap 0.30 scales every position by 0.15 → book heat pinned to 0.30.
        let pc = StockSageKelly.portfolioCap(Array(repeating: 0.20, count: 10), maxPortfolioHeat: 0.30)
        #expect(abs(pc.bookRequestedHeat - 2.0) < 1e-9)
        #expect(abs(pc.scaleApplied - 0.15) < 1e-9)
        #expect(abs((pc.scaledFractions.first ?? 0) - 0.03) < 1e-9)
        #expect(abs(pc.bookHeat - 0.30) < 1e-9)              // pinned to the cap, NOT 2.0
        // Under the cap → untouched (no-op scale).
        let under = StockSageKelly.portfolioCap([0.05, 0.04], maxPortfolioHeat: 0.30)
        #expect(under.scaleApplied == 1 && abs(under.bookHeat - 0.09) < 1e-9)
        // Empty / cap-0 → zero heat, no NaN, no negative.
        #expect(StockSageKelly.portfolioCap([], maxPortfolioHeat: 0.30).bookHeat == 0)
        #expect(StockSageKelly.portfolioCap([0.5], maxPortfolioHeat: 0).bookHeat == 0)
    }

    @Test func inputsFromBacktestStats() {
        // payoff = avgWin ÷ avgLoss = 2.0 / 1.0 = 2.0
        let i = StockSageKelly.inputs(winRate: 0.55, avgWinR: 2.0, avgLossR: 1.0)!
        #expect(abs(i.winRate - 0.55) < 1e-9)
        #expect(abs(i.payoffRatio - 2.0) < 1e-9)
        // One-sided samples can't form a payoff ratio → nil.
        #expect(StockSageKelly.inputs(winRate: 1.0, avgWinR: 2.0, avgLossR: 0) == nil)   // no losers
        #expect(StockSageKelly.inputs(winRate: 0.0, avgWinR: 0, avgLossR: 1.0) == nil)   // no winners
    }

    @Test func backtestExposesAvgWinAndLossR() {
        // Sanity on the new BacktestResult fields via the memberwise init.
        let bt = BacktestResult(trades: 3, wins: 2, winRate: 2.0 / 3, avgR: 1.0, totalR: 3,
                                maxDrawdownR: 1, sharpe: 0.5, avgHoldBars: 5, avgWinR: 2.0, avgLossR: 1.0)
        let i = StockSageKelly.inputs(winRate: bt.winRate, avgWinR: bt.avgWinR, avgLossR: bt.avgLossR)!
        #expect(abs(i.payoffRatio - 2.0) < 1e-9)
    }

    @Test func positiveEdgeGivesFractionalKelly() {
        // W=0.6, R=2 → f* = 0.6 − 0.4/2 = 0.40; half 0.20, quarter 0.10.
        let k = StockSageKelly.compute(winRate: 0.60, payoffRatio: 2.0, accountSize: 10_000)
        #expect(abs(k.fullKelly - 0.40) < 1e-9)
        #expect(abs(k.halfKelly - 0.20) < 1e-9)
        #expect(abs(k.quarterKelly - 0.10) < 1e-9)
        #expect(abs(k.edge - 0.80) < 1e-9)                 // 0.6·2 − 0.4
        #expect(abs(k.suggestedFraction - 0.20) < 1e-9)    // half == cap
        #expect(abs(k.dollarsToAllocate - 2_000) < 1e-6)   // suggestedFraction 0.20 × $10k account
    }

    @Test func noEdgeMeansDoNotBet() {
        // Even-money coin flip: W=0.5, R=1 → f* = 0.5 − 0.5 = 0.
        let k = StockSageKelly.compute(winRate: 0.50, payoffRatio: 1.0, accountSize: 10_000)
        #expect(k.fullKelly == 0)
        #expect(k.suggestedFraction == 0)
        #expect(k.note.contains("don't bet"))
    }

    @Test func negativeEdgeClampsToZero() {
        // W=0.4, R=1 → f* = 0.4 − 0.6 = −0.2 → clamped 0.
        let k = StockSageKelly.compute(winRate: 0.40, payoffRatio: 1.0, accountSize: 10_000)
        #expect(k.fullKelly == 0)
        #expect(k.edge < 0)
    }

    @Test func suggestionIsHardCapped() {
        // W=0.7, R=3 → f* = 0.7 − 0.1 = 0.60; half 0.30 → capped to 0.20.
        let k = StockSageKelly.compute(winRate: 0.70, payoffRatio: 3.0, accountSize: 10_000)
        #expect(abs(k.fullKelly - 0.60) < 1e-9)
        #expect(k.suggestedFraction == StockSageKelly.maxFraction)
        #expect(k.note.contains("cap"))
    }

    @Test func guardsDegenerateInputs() {
        // R=0 must not divide-by-zero; W clamps to [0,1].
        let k = StockSageKelly.compute(winRate: 2.0, payoffRatio: 0.0, accountSize: -5)
        #expect(k.fullKelly >= 0 && k.fullKelly <= 1)
        #expect(k.dollarsToAllocate >= 0)
    }

    // MARK: - HARDENING_BACKLOG #19: cost/slippage haircut

    @Test func nilCostsReproduceTodaysResultByteForByte() {
        // Regression guard: the default (no CostProfile) must be untouched by the new param.
        let k = StockSageKelly.compute(winRate: 0.55, payoffRatio: 2.0, accountSize: 10_000)
        #expect(abs(k.halfKelly - 0.1625) < 1e-9)   // W=0.55,R=2 → f*=0.55−0.45/2=0.325 → half 0.1625
        #expect(k.costAdjustment == 0)
    }

    @Test func costsHaircutTheSuggestedFraction() {
        // Same W/R as above; a 30%-of-R round-trip cost (commission 15 + slippage 10 + spread 5)
        // shrinks netR to 1.7, lowering half-Kelly from 0.1625 to ≈0.14265.
        let costs = CostProfile(commissionPct: 15, slippagePct: 10, bidAskPct: 5)
        #expect(abs(costs.roundTripR - 0.30) < 1e-9)
        let k = StockSageKelly.compute(winRate: 0.55, payoffRatio: 2.0, accountSize: 10_000, costs: costs)
        #expect(k.costAdjustment == costs.roundTripR)
        #expect(k.halfKelly < 0.1625)                           // strictly reduced vs the no-cost case
        #expect(abs(k.halfKelly - 0.142647058823529) < 1e-9)    // python-verified: (0.55-0.45/1.7)/2
        #expect(k.note.localizedCaseInsensitiveContains("cost"))
    }

    @Test func costsExceedingTheRewardZeroTheSize() {
        // Round-trip cost (200% of R) exceeds the entire 2.0R reward → no edge left → 0 size,
        // never a negative/NaN fraction from a flipped-sign divisor.
        let costs = CostProfile(commissionPct: 100, slippagePct: 100, bidAskPct: 0)
        let k = StockSageKelly.compute(winRate: 0.55, payoffRatio: 2.0, accountSize: 10_000, costs: costs)
        #expect(k.fullKelly == 0)
        #expect(k.suggestedFraction == 0)
        #expect(k.dollarsToAllocate == 0)
        #expect(k.note.localizedCaseInsensitiveContains("cost"))
    }

    @Test func zeroAccountSizeYieldsZeroDollars() {
        let k = StockSageKelly.compute(winRate: 0.60, payoffRatio: 2.0, accountSize: 0)
        #expect(abs(k.suggestedFraction - 0.20) < 1e-9)
        #expect(k.dollarsToAllocate == 0.0)
    }
}
