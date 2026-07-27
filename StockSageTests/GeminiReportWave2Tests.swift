import Testing
import Foundation
@testable import StockSage

// Wave 2 locks for the owner-signed external-report items (2026-07-28):
//   item 1 — greedy-knapsack allocation, hard heat-cap truncation
//   item 5 — Jensen second-order hold inflation in the velocity rank
//   item 6 — MEASURED AND REJECTED: the two vol brakes are orthogonal; composition retained
// Fixtures hand-derived in the comments; never read back from the code under test.

@Suite("Gemini-report Wave 2 (allocator, Jensen, vol brake)")
struct GeminiReportWave2Tests {

    typealias Alloc = StockSageCapitalAllocator
    typealias EV = StockSageExpectedValue

    private func idea(_ symbol: String, price: Double, stop: Double, target: Double,
                      conviction: Double, spark: [Double] = []) -> StockSageIdea {
        StockSageIdea(symbol: symbol, market: "TEST", price: price,
                      advice: TradeAdvice(action: .buy, conviction: conviction, regime: .bullTrend,
                                          rationale: [], stopPrice: stop, targetPrice: target,
                                          suggestedWeight: 0, caveat: "x"),
                      spark: spark)
    }

    // MARK: item 1 — the invariant the report cared about: Σ risk can never breach the cap

    @Test("knapsack never breaches the heat cap, however many strong ideas compete")
    func knapsackHoldsTheHeatInvariant() {
        // The report's failure scenario: N simultaneous max-size signals each locally compliant
        // but summing past the global cap. Build 12 high-conviction ideas and assert BOTH modes
        // keep total heat ≤ cap — the whole-share floor only ever rounds DOWN, never up.
        let ideas = (0..<12).map { i in
            idea("SYM\(i)", price: 100, stop: 90, target: 140, conviction: 0.9,
                 spark: [100, 102, 104, 106, 108])
        }
        for strategy in [Alloc.AllocationStrategy.greedyKnapsack, .uniformScale] {
            let a = Alloc.allocate(ideas: ideas, account: 100_000, maxHeat: 0.08, strategy: strategy)
            #expect(a.totalHeat <= 0.08 + 1e-9,
                    "\(strategy) breached the cap: \(a.totalHeat)")
            let summed = a.positions.reduce(0) { $0 + $1.riskFraction }
            #expect(summed <= 0.08 + 1e-9, "\(strategy) position risk sums past cap: \(summed)")
        }
    }

    @Test("knapsack concentrates: it truncates rather than shrinking everyone")
    func knapsackTruncatesInsteadOfScaling() {
        // Same oversubscribed book both ways. Knapsack funds FEWER names at FULL size
        // (scaleApplied stays 1); uniform funds more names, all scaled down (<1).
        let ideas = (0..<12).map { i in
            idea("SYM\(i)", price: 100, stop: 90, target: 140, conviction: 0.9,
                 spark: [100, 102, 104, 106, 108])
        }
        let knap = Alloc.allocate(ideas: ideas, account: 100_000, maxHeat: 0.08, strategy: .greedyKnapsack)
        let unif = Alloc.allocate(ideas: ideas, account: 100_000, maxHeat: 0.08, strategy: .uniformScale)
        guard knap.requestedHeat > 0.08 else { return }   // only meaningful when oversubscribed
        #expect(knap.scaleApplied == 1, "knapsack must truncate, not uniformly scale")
        #expect(unif.scaleApplied < 1, "uniform mode must scale when oversubscribed")
        #expect(knap.positions.count <= unif.positions.count,
                "knapsack should fund no more names than uniform")
    }

    // MARK: item 5 — Jensen second-order hold inflation

    @Test("jensenHoldInflation is 1 + CV² of the per-bar move, clamped to 4×")
    func jensenInflationHandDerived() {
        // Constant moves ⇒ zero variance ⇒ no Jensen penalty.
        // spark [100,102,100,102] → moves [2,2,2]; μ=2, σ²=0 → 1 + 0/4 = 1.
        #expect(abs(EV.jensenHoldInflation([100, 102, 100, 102]) - 1.0) < 1e-12)

        // Uneven moves ⇒ penalty. spark [100,101,105,106] → moves [1,4,1];
        // μ = 6/3 = 2; σ² = ((1−2)² + (4−2)² + (1−2)²)/3 = 6/3 = 2; CV² = 2/4 = 0.5
        // → inflation = 1.5 exactly.
        #expect(abs(EV.jensenHoldInflation([100, 101, 105, 106]) - 1.5) < 1e-12)

        // Clamp: spark [100,100,100,100,110] → moves [0,0,0,10]; μ = 2.5;
        // σ² = (3·2.5² + 7.5²)/4 = (18.75 + 56.25)/4 = 18.75; CV² = 18.75/6.25 = 3 (at the clamp)
        // → 1 + 3 = 4, the maximum.
        #expect(abs(EV.jensenHoldInflation([100, 100, 100, 100, 110]) - 4.0) < 1e-12)

        // Too little history to judge ⇒ neutral, never a fabricated penalty.
        #expect(EV.jensenHoldInflation([100, 101, 102]) == 1)
        #expect(EV.jensenHoldInflation([]) == 1)
    }

    @Test("uneven-step movers rank below even-step movers at identical mean speed")
    func jensenPenalisesVariableStepPaths() {
        // Jensen's term is the VARIANCE of |move|, not directionality — my first fixture got this
        // wrong (an oscillator with constant 10-pt swings has ZERO move-variance, so no penalty,
        // and its large steps correctly earn a FAST hold). The honest test holds the MEAN move
        // equal and varies only its dispersion:
        //   even  [100,102,104,106,108,110] → moves [2,2,2,2,2]  μ=2  σ²=0    → inflation 1.0
        //   uneven[100,104,104,108,108,110] → moves [4,0,4,0,2]  μ=2  σ²=3.2  → CV²=0.8 → 1.8
        // Same EV, same mean speed ⇒ the uneven path's inflated expected hold must rank it lower.
        #expect(abs(EV.jensenHoldInflation([100, 102, 104, 106, 108, 110]) - 1.0) < 1e-12)
        #expect(abs(EV.jensenHoldInflation([100, 104, 104, 108, 108, 110]) - 1.8) < 1e-12)

        let even = idea("EVEN", price: 100, stop: 90, target: 140, conviction: 0.7,
                        spark: [100, 102, 104, 106, 108, 110])
        let uneven = idea("UNEVEN", price: 100, stop: 90, target: 140, conviction: 0.7,
                          spark: [100, 104, 104, 108, 108, 110])
        guard let vE = EV.velocity(for: even), let vU = EV.velocity(for: uneven) else {
            Issue.record("velocity should be computable for both fixtures"); return
        }
        #expect(vE > vU, "even-step \(vE) should out-rank uneven-step \(vU) at equal EV and mean speed")
    }

    // MARK: item 6 — SHIPPED single-tier brake (owner-forced after seeing the measurement)

    @Test("volatility is priced once: the most-binding brake wins, the other is inert")
    func volBrakeIsSingleTier() {
        // Absolute brake at vol 0.80 = 1/4 = 0.25. A regime brake of 0.25 therefore adds
        // NOTHING under min() — that inertness is the accepted cost of item 6. A regime brake
        // of 0.10 is more binding and does win. Hand-derived: halfKelly 0.174, no market regime.
        #expect(StockSageExpectedValue.cryptoRiskScaler(annualizedVol: 0.80) == 4)

        func alloc(_ mult: Double) -> Double? {
            let adv = TradeAdvice(action: .buy, conviction: 0.7, regime: .bullTrend, rationale: [],
                                  stopPrice: 90, targetPrice: 130, suggestedWeight: 0.10, caveat: "x")
            let vr = VolRegime(current: 0.80, median: 0.20, percentile: 1.0,
                               sizingMultiplier: mult, note: "t", caveat: "t")
            let i = StockSageIdea(symbol: "V\(Int(mult * 100))", market: "TEST", price: 100,
                                  advice: adv, spark: [], dailyMove: nil,
                                  realizedVol: 0.80, volRegime: vr)
            return Alloc.allocate(ideas: [i], account: 100_000, maxHeat: 0.5).positions.first?.riskFraction
        }
        // equal-strength brake ⇒ inert: same size as no regime brake at all
        #expect(alloc(0.25).map { abs($0 - 0.0435) < 1e-6 } == true)
        #expect(alloc(1.00).map { abs($0 - 0.0435) < 1e-6 } == true)
        // stronger regime brake ⇒ it binds
        #expect(alloc(0.10).map { abs($0 - 0.0174) < 1e-6 } == true)
    }
}
