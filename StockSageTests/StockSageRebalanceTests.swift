import Testing
import Foundation
@testable import StockSage

// MARK: - Rebalance-to-target (pure)

struct StockSageRebalanceTests {
    typealias RB = StockSageRebalance

    private func trade(_ p: RebalancePlan, _ sym: String) -> RebalanceTrade? {
        p.trades.first { $0.symbol == sym }
    }

    @Test func computesDriftTradesOutsideBand() {
        // A 60% / B 40% → target 50/50: sell 1000 of A, buy 1000 of B (total 10k).
        let p = RB.plan(holdings: [("A", 6000), ("B", 4000)], targets: ["A": 0.5, "B": 0.5])!
        #expect(abs(p.totalValue - 10_000) < 1e-9)
        #expect(abs(trade(p, "A")!.deltaValue - (-1000)) < 1e-9)
        #expect(abs(trade(p, "B")!.deltaValue - 1000) < 1e-9)
        #expect(trade(p, "A")!.action == "Sell" && trade(p, "B")!.action == "Buy")
    }

    @Test func noTradeBandSuppressesSmallDrift() {
        // Each side drifts only 0.01 < 0.02 band → nothing to do.
        let p = RB.plan(holdings: [("A", 6000), ("B", 4000)], targets: ["A": 0.59, "B": 0.41], band: 0.02)!
        #expect(p.trades.isEmpty)
        #expect(p.isBalanced)
    }

    @Test func normalizesTargetsAndSellsUntargetedToZero() {
        // targets sum 0.8 → normalize to A=1.0; B not targeted → sell fully.
        let p = RB.plan(holdings: [("A", 5000), ("B", 5000)], targets: ["A": 0.8])!
        #expect(abs(trade(p, "A")!.deltaValue - 5000) < 1e-9)    // cw .5 → tw 1.0 → buy 5000
        #expect(abs(trade(p, "B")!.deltaValue - (-5000)) < 1e-9) // cw .5 → tw 0 → sell 5000
    }

    @Test func equalWeightTargetsSumToOne() {
        let t = RB.equalWeightTargets(["A", "B", "C", "A"])   // dedups
        #expect(t.count == 3)
        #expect(abs((t["A"] ?? 0) - 1.0 / 3) < 1e-9)
        #expect(abs(t.values.reduce(0, +) - 1) < 1e-9)
    }

    @Test func guardsEmptyOrZero() {
        #expect(RB.plan(holdings: [], targets: ["A": 1]) == nil)          // nothing invested
        #expect(RB.plan(holdings: [("A", 1000)], targets: [:]) == nil)    // no targets
        #expect(RB.plan(holdings: [("A", 0)], targets: ["A": 1]) == nil)  // zero value
    }

    @Test func driftExactlyAtBandEdge() {
        // 0.02 is not exactly representable in binary64, so 5200/4800 vs a 2% band produces a
        // drift of 0.020000000000000018 (not bit-exact 0.02), spuriously tripping the strict `>`.
        // Use a band/weight pair that IS bit-exact: band 0.25 (a power of two), holdings weighted
        // 25%/75% vs a 50/50 target — 0.5 - 0.25 = 0.25 bit-for-bit in binary64.
        let atBand = StockSageRebalance.plan(holdings: [("A", 2500), ("B", 7500)],
                                             targets: ["A": 0.5, "B": 0.5], band: 0.25)!
        #expect(atBand.trades.isEmpty)   // |0.5-0.25| = 0.25, not > 0.25
        let aboveBand = StockSageRebalance.plan(holdings: [("A", 2400), ("B", 7600)],
                                                targets: ["A": 0.5, "B": 0.5], band: 0.25)!
        #expect(!aboveBand.trades.isEmpty)   // |0.5-0.24| = 0.26 > 0.25
    }

    @Test func nonFiniteHoldingIsExcludedRatherThanPoisoningEveryOtherPositionsRecommendation() {
        // A single .infinity holding value must not blow up `total`, which would otherwise
        // silently zero every OTHER holding's current weight and recommend an infinite-dollar
        // "Buy" for each of them.
        let p = RB.plan(holdings: [("A", .infinity), ("B", 6000), ("C", 4000)],
                        targets: ["B": 0.5, "C": 0.5])!
        #expect(p.totalValue.isFinite)
        #expect(abs(p.totalValue - 10_000) < 1e-9)   // A excluded entirely
        #expect(trade(p, "A") == nil)
        for t in p.trades { #expect(t.deltaValue.isFinite) }
    }

    @Test func nonFiniteTargetIsTreatedAsZeroRatherThanCorruptingNormalization() {
        // A NaN target for A is treated as target 0 (not "worth a share of the normalization"),
        // so the plan sells A fully and buys B up to its full 100% target — never NaN/Infinity.
        let p = RB.plan(holdings: [("A", 5000), ("B", 5000)], targets: ["A": .nan, "B": 1.0])!
        #expect(abs(trade(p, "A")!.deltaValue - (-5000)) < 1e-9)
        #expect(abs(trade(p, "B")!.deltaValue - 5000) < 1e-9)
    }

    @Test func allNonFiniteHoldingsReturnNilRatherThanACrashOrGarbageOutput() {
        #expect(RB.plan(holdings: [("A", .infinity), ("B", .nan)], targets: ["A": 1]) == nil)
    }
}
