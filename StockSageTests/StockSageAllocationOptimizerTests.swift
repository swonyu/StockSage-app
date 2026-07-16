import Testing
import Foundation
@testable import StockSage

// MARK: - Sharpe-max, de-correlated capital allocator (ALLOC_BACKLOG #6, "stretch")
//
// The FIRST iterative/numerical engine in this codebase — see StockSageAllocationOptimizer.swift's
// own header for the full derivation (units, why Frank-Wolfe, the lambda=1.0=half-Kelly anchor).
// These tests hand-verify (python-first) both the pure-math primitives AND the end-to-end pipeline
// for cases precise enough to compute exactly, plus structural/directional invariants (box cap,
// heat cap, de-correlation direction) for cases too complex to hand-derive to the last digit.

struct StockSageAllocationOptimizerTests {
    typealias Opt = StockSageAllocationOptimizer

    private func idea(_ symbol: String, conviction: Double, entry: Double, stop: Double, target: Double,
                      closes: [Double]) -> StockSageIdea {
        StockSageIdea(symbol: symbol, market: "M", price: entry,
                      advice: TradeAdvice(action: .buy, conviction: conviction, regime: .bullTrend, rationale: [],
                                          stopPrice: stop, targetPrice: target, suggestedWeight: 0.05, caveat: "x"),
                      spark: closes)
    }

    /// A near-deterministic linear ramp — annualizedVolatility on this is TINY (python-verified
    /// ≈0.00076), so the unconstrained single-asset optimum (mu/(2·sigma²)) is astronomically
    /// larger than any realistic box/heat cap, making the solver's answer trivially predictable:
    /// it always lands EXACTLY at whichever cap binds. This isolates the box-cap/heat-cap logic
    /// from the correlation logic for hand-verification.
    private var lowVolCloses: [Double] { (0..<20).map { 100.0 + 0.3 * Double($0) } }

    /// A genuinely noisy uptrend (real day-to-day variance) — reused, scaled, for the
    /// correlation-sensitive tests below.
    private var noisyCloses: [Double] {
        var out: [Double] = [100.0]
        var seed = 0.37
        for _ in 0..<29 {
            seed = (seed * 9301 + 49297).truncatingRemainder(dividingBy: 233280) / 233280
            let noise = (seed - 0.5) * 3.0
            out.append(out.last! + 0.4 + noise)
        }
        return out
    }

    // MARK: - Single-idea, exact hand-derivation (isolates box/heat-cap logic)

    @Test func singleIdeaLandsExactlyAtItsBoxCapWhenHeatCapIsGenerous() {
        // python-verified: conviction 0.5 → winProb 0.465, entry/stop/target 100/90/130 →
        // rewardR 3.0, evR 0.86; Kelly fullKelly≈0.28667, halfKelly≈0.14333, boxCap=min(halfKelly,
        // 0.20)=0.14333 (NOT maxFraction-capped). The near-zero-vol fixture makes the unconstrained
        // optimum astronomically larger than any real cap, so with a generous heatCap (0.5, not
        // binding), the solver must land EXACTLY at boxCap.
        let only = idea("SOLO", conviction: 0.5, entry: 100, stop: 90, target: 130, closes: lowVolCloses)
        let result = Opt.optimizeSharpeDeCorrelated(ideas: [only], account: 10_000, heatCap: 0.5)!
        #expect(result.positions.count == 1)
        #expect(abs(result.positions[0].riskFraction - 0.14333333333333) < 1e-6)
        #expect(result.bindingConstraints.contains("SOLO"))
        #expect(!result.bindingConstraints.contains("heat"))
        #expect(result.converged)
    }

    @Test func singleIdeaLandsExactlyAtHeatCapWhenItsTighterThanTheBoxCap() {
        // Same idea, heatCap=0.05 (python-verified: tighter than boxCap≈0.14333) → the solver
        // must land EXACTLY at heatCap, not boxCap.
        let only = idea("SOLO", conviction: 0.5, entry: 100, stop: 90, target: 130, closes: lowVolCloses)
        let result = Opt.optimizeSharpeDeCorrelated(ideas: [only], account: 10_000, heatCap: 0.05)!
        #expect(result.positions.count == 1)
        #expect(abs(result.positions[0].riskFraction - 0.05) < 1e-6)
        #expect(result.bindingConstraints.contains("heat"))
        #expect(!result.bindingConstraints.contains("SOLO"))   // heat bound first, box cap never reached
    }

    // MARK: - De-correlation: the actual point of this engine

    @Test func aCorrelatedPairEachGetsLessWeightThanAnIndependentEqualIdea() {
        // Three ideas, IDENTICAL conviction/entry/stop/target (same mu, same boxCap) — isolates
        // the effect to volatility/correlation alone. A and B share the SAME price series
        // (correlation exactly 1.0, IDENTICAL vol) — genuinely redundant, the SAME bet twice. C is
        // a small-amplitude oscillation, python-verified to have near-zero correlation with A/B
        // (≈-0.034) AND closely-matched volatility (0.00300 vs A/B's 0.00320) — a real
        // diversifier, not just a differently-seeded copy of the same trending shape (an EARLIER,
        // rejected fixture attempt used a second noisy-uptrend series for "C" and accidentally
        // measured 0.94 correlation with A from the shared drift term — python-verified before
        // relying on any fixture here, not assumed).
        let a = idea("A", conviction: 0.5, entry: 100, stop: 90, target: 130, closes: noisyCloses)
        let b = idea("B", conviction: 0.5, entry: 100, stop: 90, target: 130, closes: noisyCloses)
        let indepCloses = (0..<30).map { 100.0 + 0.03 * sin(Double($0) * 2 * Double.pi / 7) }
        let c = idea("C", conviction: 0.5, entry: 100, stop: 90, target: 130, closes: indepCloses)
        // Small heatCap so the cap genuinely binds and forces a real allocation TRADE-OFF between
        // the three (otherwise, with a generous cap, everyone just gets their own box cap and
        // correlation has nothing to trade off against).
        let result = Opt.optimizeSharpeDeCorrelated(ideas: [a, b, c], account: 10_000, heatCap: 0.10)!
        let bySymbol = Dictionary(uniqueKeysWithValues: result.positions.map { ($0.symbol, $0.riskFraction) })
        // A and B are LITERALLY the same bet (perfectly correlated, identical vol) — funding BOTH
        // offers zero additional diversification over funding either alone, so the solver
        // correctly picks ONE of the redundant pair rather than splitting evenly between clones;
        // do not assert wa≈wb (python-verified: the true optimum here is degenerate/non-unique
        // between A and B, any split summing to the same total is equally optimal — Frank-Wolfe's
        // greedy tie-break deterministically picks one). The real, robust invariant is: C
        // (genuinely uncorrelated) must be funded, and must get AT LEAST as much as whichever of
        // A/B the solver funded — a de-correlation benefit, not an even 3-way split.
        let wc = bySymbol["C"] ?? 0
        let wRedundantPair = (bySymbol["A"] ?? 0) + (bySymbol["B"] ?? 0)
        #expect(wc > 0, "the independent idea must receive SOME weight")
        #expect(wc >= wRedundantPair - 1e-6, "the independent idea should get at least as much as the redundant pair combined got individually funded")
    }

    // MARK: - Structural invariants (across every case, not just the hand-derived ones)

    @Test func noPositionEverExceedsItsOwnBoxCap() {
        let ideas = [
            idea("A", conviction: 0.9, entry: 100, stop: 95, target: 200, closes: noisyCloses),
            idea("B", conviction: 0.3, entry: 50, stop: 48, target: 54, closes: lowVolCloses),
            idea("C", conviction: 0.6, entry: 200, stop: 180, target: 260, closes: noisyCloses),
        ]
        let result = Opt.optimizeSharpeDeCorrelated(ideas: ideas, account: 50_000, heatCap: 0.30)!
        for p in result.positions {
            #expect(p.riskFraction <= p.halfKelly + 1e-6, "\(p.symbol) exceeded its own box cap")
            #expect(p.riskFraction <= StockSageKelly.maxFraction + 1e-6)
        }
    }

    @Test func theSumOfRiskFractionsNeverExceedsHeatCap() {
        let ideas = (0..<6).map { i in
            idea("SYM\(i)", conviction: 0.5 + Double(i) * 0.05, entry: 100, stop: 92, target: 120 + Double(i) * 5,
                closes: noisyCloses)
        }
        let result = Opt.optimizeSharpeDeCorrelated(ideas: ideas, account: 20_000, heatCap: 0.08)!
        let total = result.positions.reduce(0.0) { $0 + $1.riskFraction }
        #expect(total <= 0.08 + 1e-6)
    }

    @Test func resultReportsAConsistentPortfolioEVRAndVariance() {
        let ideas = [
            idea("A", conviction: 0.6, entry: 100, stop: 90, target: 140, closes: noisyCloses),
            idea("B", conviction: 0.5, entry: 50, stop: 45, target: 65, closes: lowVolCloses),
        ]
        let result = Opt.optimizeSharpeDeCorrelated(ideas: ideas, account: 10_000, heatCap: 0.10)!
        #expect(result.estPortfolioEVR > 0)          // both ideas are positive-EV; a positive-weighted mix must be too
        #expect(result.estPortfolioVariance >= 0)     // a variance can never be negative
        if let sharpe = result.estPortfolioSharpe {
            #expect(abs(sharpe - result.estPortfolioEVR / result.estPortfolioVariance.squareRoot()) < 1e-9)
        }
    }

    // MARK: - Degenerate-input guards

    @Test func guardsDegenerateTopLevelInputs() {
        let ok = idea("A", conviction: 0.6, entry: 100, stop: 90, target: 140, closes: noisyCloses)
        #expect(Opt.optimizeSharpeDeCorrelated(ideas: [ok], account: 0, heatCap: 0.08) == nil)
        #expect(Opt.optimizeSharpeDeCorrelated(ideas: [ok], account: -100, heatCap: 0.08) == nil)
        #expect(Opt.optimizeSharpeDeCorrelated(ideas: [ok], account: 10_000, heatCap: 0) == nil)
        #expect(Opt.optimizeSharpeDeCorrelated(ideas: [ok], account: 10_000, heatCap: -0.1) == nil)
        #expect(Opt.optimizeSharpeDeCorrelated(ideas: [ok], account: 10_000, lambda: 0, heatCap: 0.08) == nil)
        #expect(Opt.optimizeSharpeDeCorrelated(ideas: [ok], account: 10_000, heatCap: 0.08, maxIterations: 0) == nil)
        #expect(Opt.optimizeSharpeDeCorrelated(ideas: [ok], account: .infinity, heatCap: 0.08) == nil)
        #expect(Opt.optimizeSharpeDeCorrelated(ideas: [], account: 10_000, heatCap: 0.08) == nil)
    }

    @Test func excludesNonBuyFamilyAndNonPositiveEVIdeas() {
        let sell = StockSageIdea(symbol: "SHORT", market: "M", price: 100,
                                  advice: TradeAdvice(action: .sell, conviction: 0.9, regime: .bearTrend, rationale: [],
                                                       stopPrice: 110, targetPrice: 80, suggestedWeight: 0.05, caveat: "x"),
                                  spark: noisyCloses)
        let negativeEV = idea("NEG", conviction: 0.0, entry: 100, stop: 90, target: 101, closes: noisyCloses)
        #expect(Opt.optimizeSharpeDeCorrelated(ideas: [sell, negativeEV], account: 10_000, heatCap: 0.08) == nil)
    }

    @Test func excludesIdeasWithTooLittleSparkHistoryRatherThanGuessingVolatility() {
        // <3 spark points -> annualizedVolatility itself is nil -> honestly excluded, not defaulted.
        let thin = idea("THIN", conviction: 0.6, entry: 100, stop: 90, target: 140, closes: [100, 101])
        #expect(Opt.optimizeSharpeDeCorrelated(ideas: [thin], account: 10_000, heatCap: 0.08) == nil)
    }

    @Test func noStopOrTargetIsExcludedNotCrashed() {
        let noStop = StockSageIdea(symbol: "NS", market: "M", price: 100,
                                    advice: TradeAdvice(action: .buy, conviction: 0.8, regime: .bullTrend, rationale: [],
                                                         stopPrice: nil, targetPrice: 140, suggestedWeight: 0.05, caveat: "x"),
                                    spark: noisyCloses)
        #expect(Opt.optimizeSharpeDeCorrelated(ideas: [noStop], account: 10_000, heatCap: 0.08) == nil)
    }

    // MARK: - Convergence reporting

    @Test func convergedFlagAndIterationsAreConsistent() {
        let only = idea("SOLO", conviction: 0.5, entry: 100, stop: 90, target: 130, closes: lowVolCloses)
        let result = Opt.optimizeSharpeDeCorrelated(ideas: [only], account: 10_000, heatCap: 0.5, maxIterations: 100)!
        #expect(result.iterations >= 1 && result.iterations <= 100)
        #expect(result.converged)   // a single-idea problem's linear oracle finds the optimum on iteration 1
        #expect(result.note.contains("Converged"))
    }

    @Test func caveatIsAlwaysPresentAndDisclosesLocalOptimum() {
        #expect(!Opt.caveat.isEmpty)
        #expect(Opt.caveat.localizedCaseInsensitiveContains("local optimum"))
        #expect(Opt.caveat.localizedCaseInsensitiveContains("estimate"))
    }
}
