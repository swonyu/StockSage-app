import Testing
import Foundation
@testable import StockSage

// MARK: - Engine boundary sweep (hardening #5)
//
// Pins the exact off-by-one / sign-flip boundaries on money math so a silent change to a
// `>=` vs `>` or a rounding direction becomes a conscious, failing-test decision. Every
// literal was read from the engine source and python-verified.

struct StockSageBoundaryTests {

    @Test func kellyEdgeAtPayoffOne() {
        // W=.70, R=1 → edge = .70·1 − .30 = .40; f* = .70 − .30/1 = .40; suggested = half = .20 (== cap).
        let k = StockSageKelly.compute(winRate: 0.70, payoffRatio: 1.0, accountSize: 10_000)
        #expect(abs(k.edge - 0.40) < 1e-9)
        #expect(abs(k.fullKelly - 0.40) < 1e-9)
        #expect(abs(k.suggestedFraction - 0.20) < 1e-9)
    }

    @Test func rewardRiskQualityBoundaries() {
        // risk fixed at 10; quality = ratio>=2.5 strong, >=1.5 fair, else poor.
        func q(_ target: Double) -> RewardRisk.Quality? {
            StockSageRewardRisk.assess(entry: 100, stop: 90, target: target)?.quality
        }
        #expect(q(125) == .strong)   // 2.5 — inclusive
        #expect(q(124) == .fair)     // 2.4
        #expect(q(115) == .fair)     // 1.5 — inclusive
        #expect(q(114) == .poor)     // 1.4
        #expect(StockSageRewardRisk.assess(entry: 100, stop: 100, target: 110) == nil)  // zero risk → nil
    }

    // The `.note` string is rendered directly on the manual add-trade form (24h-run cycle-4,
    // 2026-07-16) and the copy plan/detail sheet, so its exact format (incl. the "gross" label
    // and the break-even honesty companion) is load-bearing. HAND-DERIVED: entry 100/stop 90/
    // target 130 → risk 10, reward 30, ratio 3.0 → Strong (≥2.5); breakeven 1/(1+3)=0.25=25.0%.
    @Test func rewardRiskNoteFormatIsStableAndLabeledGross() {
        let rr = StockSageRewardRisk.assess(entry: 100, stop: 90, target: 130)!
        #expect(rr.note == "R:R 3.0 gross — Strong; needs a >25.0% win-rate just to break even.")
    }

    @Test func riskOfRuinBoundaries() {
        // (1−f)^losses; fraction must be in (0,1).
        let s = StockSageRiskOfRuin.scenario(losses: 1, fraction: 0.99)!
        #expect(abs(s.drawdownPct - 0.99) < 1e-9)        // 1 − 0.01
        #expect(s.isSteep)
        #expect(StockSageRiskOfRuin.scenario(losses: 5, fraction: 1.0) == nil)   // not < 1
        #expect(StockSageRiskOfRuin.scenario(losses: 0, fraction: 0.01) == nil)  // streak < 1
    }

    @Test func rMultipleExactAndUndefined() {
        let t = TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                            openedAt: Date(timeIntervalSince1970: 0), exitPrice: nil, closedAt: nil)
        #expect(abs((t.rMultiple(at: 110) ?? 0) - 1.0) < 1e-9)   // +10 profit / 10 risk = +1R
        let noRisk = TradeRecord(symbol: "X", side: .long, entry: 100, stop: 100, target: nil, shares: 1,
                                 openedAt: Date(timeIntervalSince1970: 0), exitPrice: nil, closedAt: nil)
        #expect(noRisk.rMultiple(at: 110) == nil)                // entry==stop → undefined, not infinite
    }

    @Test func netEdgeCostEqualsReward() {
        // 100bps on a 100 entry = $1 cost == the $1 gross reward → net reward 0 → netRR 0.
        let e = StockSageNetEdge.evaluate(entry: 100, stop: 90, target: 101, spreadBps: 100, slippageBps: 0)!
        #expect(abs(e.costPerShare - 1.0) < 1e-9)
        #expect(abs(e.netRR - 0.0) < 1e-9)
    }

    @Test func positionSizerTinyAccountZeroShares() {
        // $1 risk budget / $10 per share = 0.1 → floored to 0 shares (never over-risk), still valid.
        let ps = StockSagePositionSizer.size(account: 100, riskFraction: 0.01, entry: 100, stop: 90)!
        #expect(ps.shares == 0 && ps.dollarsAtRisk == 0)
        #expect(StockSagePositionSizer.size(account: 100, riskFraction: 0.01, entry: 100, stop: 100) == nil)  // zero risk/share
    }

    @Test func currencyAndRebalanceZeroGuards() {
        #expect(StockSageCurrency.breakdown(holdings: [(0, "USD")], ratesToBase: [:], base: "USD") == nil)
        #expect(StockSageRebalance.plan(holdings: [("A", 0)], targets: ["A": 1]) == nil)
    }
}
