import Testing
import Foundation
@testable import StockSage

// MARK: - F06 — multi-brake sizing composition
//
// StockSageCapitalAllocator.allocate() composes five sequential brakes:
//   1. Regime bias    (market-wide: crisis → sizingBias=0.25)
//   2. Vol-targeting  (realizedVol: cryptoRiskScaler = max(1, vol/0.20))
//   3. VolRegime brake (per-symbol: idea.volRegime?.sizingMultiplier)
//   4. Correlation de-weight (cluster /K when ≥3 correlated names)
//   5. Heat cap       (uniform proportional scale if Σweights > cap)
//
// This suite exercises all five together and verifies:
//   (a) every funded weight > 0 (no zero-share lines survive)
//   (b) edge ORDER is preserved across the braked+scaled output
//   (c) total heat ≤ cap
//   (d) final weight < what any single brake alone would give
//
// Hand-derivation (derive_hardening.swift) for the single-idea spine:
//   idea: AAPL, price=100, stop=90, target=130, conviction=0.7
//   winProb = 0.35 + 0.7*0.23 = 0.511
//   rewardR = min(30/10, 50) = 3.0
//   evR     = 0.511*3 − 0.489 = 1.044  > 0  →  fundable
//   fullKelly   = 0.511 − 0.489/3 = 0.348
//   halfKelly   = 0.348/2 = 0.174
//   suggestedFraction = min(0.174, 0.20) = 0.174   (Kelly cap 0.20 doesn't bind)
//
// Brake 1 (regime, crisis, sizingBias=0.25):
//   weight = max(0, min(0.20, 0.174 * 0.25)) = 0.0435
//
// Brake 2 (vol-targeting, realizedVol=0.80):
//   cryptoRiskScaler = max(1, 0.80/0.20) = 4.0
//   weight /= 4.0  →  0.0435/4 = 0.010875
//
// Brake 3 (volRegime, sizingMultiplier=0.25 — at floor):
//   weight *= 0.25  →  0.010875*0.25 = 0.0027188
//
// Brake 4 (correlation): with ONE idea no cluster forms — no de-weight.
//
// Brake 5 (heat cap, maxHeat=0.002 — cap BINDS):
//   requestedHeat = 0.0027188 > 0.002
//   scaleApplied = 0.002 / 0.0027188 ≈ 0.7356
//   scaledWeight = 0.0027188 * 0.7356 ≈ 0.002
//
// Single-brake comparisons (all brakes in isolation on the same 0.174 base):
//   regimeOnly   = min(0.20, 0.174*0.25)  = 0.0435
//   volOnly      = 0.174/4               = 0.0435
//   volRegimeOnly= 0.174*0.25            = 0.0435
//   composed     = 0.0027188             ≪ any single brake

struct StockSageMultiBrakeTests {

    typealias Alloc = StockSageCapitalAllocator

    // MARK: - Helpers

    private func crisisRegime() -> MarketRegime {
        // StockSageRegime.assess with VIX=50 → crisis, sizingBias=0.25.
        // Construct directly (the assess() path requires an index history we don't have here).
        MarketRegime(state: .crisis, riskScore: -0.80, signals: ["VIX 50 — crisis"],
                     sizingBias: 0.25, caveat: "test")
    }

    /// Build an idea with ALL brakes loaded.
    /// - price=100, stop=90, target=130, conviction=0.7
    /// - realizedVol=0.80 (triggers vol-targeting: scaler=4)
    /// - volRegime.sizingMultiplier=0.25 (the floor, triggers the brake note)
    private func brakedIdea(symbol: String) -> StockSageIdea {
        let advice = TradeAdvice(
            action: .buy, conviction: 0.7, regime: .bullTrend, rationale: [],
            stopPrice: 90, targetPrice: 130, suggestedWeight: 0.10, caveat: "x")
        // Build a VolRegime at the 0.25 floor (hand-set, not recomputed from closes here
        // because the allocator reads idea.volRegime directly).
        let volRegime = VolRegime(
            current: 0.80, median: 0.20, percentile: 1.0,
            sizingMultiplier: 0.25,
            note: "Vol at 100th pct — braked to ×0.25",
            caveat: "test")
        return StockSageIdea(
            symbol: symbol, market: "TEST", price: 100,
            advice: advice, spark: [],
            dailyMove: nil, realizedVol: 0.80,
            volRegime: volRegime)
    }

    // MARK: - F06 core: all brakes compose — result < any single brake alone

    @Test func composedBrakesProduceWeightStrictlyBelowAnySingleBrake() {
        let idea = brakedIdea(symbol: "AAPL")
        let account = 100_000.0
        let maxHeat = 0.002   // tight cap — must bind

        let result = Alloc.allocate(
            ideas: [idea], account: account, maxHeat: maxHeat,
            regime: crisisRegime())

        guard let pos = result.positions.first else {
            // The idea might be excluded by the cost gate (equity AAPL costs ≈13bps which
            // should clear, but check explicitly).
            Issue.record("Expected at least one funded position; got empty plan")
            return
        }

        // (a) Every funded weight > 0.
        #expect(pos.riskFraction > 0,
                "riskFraction must be positive — no zero-share lines survive")
        #expect(pos.shares > 0, "shares must be positive")

        // (c) Total heat ≤ cap.
        #expect(result.totalHeat <= maxHeat + 1e-9,
                "totalHeat \(result.totalHeat) exceeds cap \(maxHeat)")

        // (d) Composed weight < each single-brake result.
        // Single-brake results on the same 0.174 suggestedFraction base:
        //   regimeOnly   = min(0.174*0.25, 0.20) = 0.0435
        //   volOnly      = 0.174/4               = 0.0435
        //   volRegimeOnly= 0.174*0.25            = 0.0435
        // Composed (before heat cap): 0.174 * 0.25 / 4.0 * 0.25 = 0.00271875
        // After heat cap (0.002): ≤ 0.002
        let regimeOnly    = min(0.174 * 0.25, 0.20)  // 0.0435
        let volOnly       = 0.174 / 4.0               // 0.0435
        let volRegimeOnly = 0.174 * 0.25              // 0.0435
        #expect(pos.riskFraction < regimeOnly,
                "Composed weight \(pos.riskFraction) must be below regime-only \(regimeOnly)")
        #expect(pos.riskFraction < volOnly,
                "Composed weight \(pos.riskFraction) must be below vol-only \(volOnly)")
        #expect(pos.riskFraction < volRegimeOnly,
                "Composed weight \(pos.riskFraction) must be below volRegime-only \(volRegimeOnly)")

        // (e) Pre-cap composition pin: the three sequential brakes multiply down to exactly
        //     0.00271875 before the heat cap is applied, then the cap (0.002) scales them down.
        //     requestedHeat = composed weight AFTER correlation de-weight, BEFORE heat cap.
        //     For a single idea (no correlation cluster), requestedHeat IS the composed weight:
        //       halfKelly(0.174) × regimeBias(0.25) = 0.0435
        //       ÷ cryptoRiskScaler(4)               = 0.010875
        //       × volRegimeMult(0.25)               = 0.00271875
        //     This pin ensures deleting any one brake would change requestedHeat — the assertion
        //     is not vacuous even though the heat cap (0.002) binds on riskFraction.
        #expect(abs(result.requestedHeat - 0.00271875) < 1e-6,
                "requestedHeat (pre-cap) must equal the fully-composed weight 0.00271875; got \(result.requestedHeat)")
    }

    // MARK: - F06: total heat ≤ cap even with three braked ideas

    @Test func heatCapHoldsWithThreeBrakedIdeas() {
        // Three fundable ideas (different symbols so no cluster — correlation needs ≥3
        // SAME-spark names, and these have no spark). All carry all three brakes.
        // Total pre-scale heat ≈ 3 × 0.0027 ≈ 0.0082. Cap = 0.005 → binds.
        let ideas = ["AAPL", "MSFT", "NVDA"].map { brakedIdea(symbol: $0) }
        let result = Alloc.allocate(
            ideas: ideas, account: 100_000, maxHeat: 0.005,
            regime: crisisRegime())

        // (c) total heat ≤ cap.
        #expect(result.totalHeat <= 0.005 + 1e-9,
                "totalHeat \(result.totalHeat) must not exceed cap 0.005")

        // (a) All funded positions have positive weight.
        for pos in result.positions {
            #expect(pos.riskFraction > 0, "Every position must have positive risk fraction")
            #expect(pos.shares > 0, "Every position must have at least 1 share")
        }
    }

    // MARK: - F06: edge order preserved

    @Test func edgeOrderPreservedAfterComposition() {
        // Two ideas with DIFFERENT convictions — higher conviction should rank first
        // after all brakes are applied (all brakes are proportional, so the rank is preserved).
        let highConv = TradeAdvice(action: .buy, conviction: 0.9, regime: .bullTrend,
                                   rationale: [], stopPrice: 90, targetPrice: 160,
                                   suggestedWeight: 0.10, caveat: "x")
        let lowConv = TradeAdvice(action: .buy, conviction: 0.5, regime: .bullTrend,
                                  rationale: [], stopPrice: 90, targetPrice: 130,
                                  suggestedWeight: 0.05, caveat: "x")
        let volReg = VolRegime(current: 0.80, median: 0.20, percentile: 1.0,
                               sizingMultiplier: 0.25, note: "test", caveat: "test")

        let ideaHigh = StockSageIdea(symbol: "HIGH", market: "T", price: 100,
                                     advice: highConv, spark: [],
                                     dailyMove: nil, realizedVol: 0.80, volRegime: volReg)
        let ideaLow = StockSageIdea(symbol: "LOW", market: "T", price: 100,
                                    advice: lowConv, spark: [],
                                    dailyMove: nil, realizedVol: 0.80, volRegime: volReg)

        let result = Alloc.allocate(
            ideas: [ideaHigh, ideaLow], account: 100_000, maxHeat: 0.10,
            regime: crisisRegime())

        guard result.positions.count == 2 else { return }  // both must survive for order check
        // Desc by riskFraction: HIGH should come first (its edge is larger after identical brakes).
        #expect(result.positions[0].symbol == "HIGH",
                "Higher-conviction idea must rank first after composition; got \(result.positions.map(\.symbol))")
        #expect(result.positions[0].riskFraction >= result.positions[1].riskFraction,
                "Positions must be sorted desc by riskFraction")
    }

    // MARK: - F06: vol-regime brake composes with vol-targeting (not one or the other)

    @Test func volRegimeBrakeComposesWithVolTargeting() {
        // Same idea but volRegime.sizingMultiplier varies: 0.25 vs 1.0.
        // With mult=0.25: weight *= 0.25 on top of the vol-targeting ÷4.
        // With mult=1.0 : weight *= 1.00 (no brake).
        // The 0.25-mult version must produce a strictly smaller riskFraction.
        //
        // Derived (no regime passed → sizingBias not applied):
        //   halfKelly = 0.174, suggestedFraction = 0.174
        //   vol-targeting: realizedVol=0.80 → cryptoRiskScaler=4 → 0.174/4 = 0.0435
        //   UNBRAKED (mult=1.0): 0.0435 × 1.0  = 0.0435
        //   BRAKED  (mult=0.25): 0.0435 × 0.25 = 0.010875
        // maxHeat=0.5 → cap doesn't bind for either → riskFraction == weight.
        func ideaWithMult(_ mult: Double, symbol: String) -> StockSageIdea {
            let adv = TradeAdvice(action: .buy, conviction: 0.7, regime: .bullTrend,
                                  rationale: [], stopPrice: 90, targetPrice: 130,
                                  suggestedWeight: 0.10, caveat: "x")
            let vr = VolRegime(current: 0.80, median: mult == 1.0 ? 0.80 : 0.20,
                               percentile: mult == 1.0 ? 0.5 : 1.0,
                               sizingMultiplier: mult, note: "test", caveat: "test")
            return StockSageIdea(symbol: symbol, market: "T", price: 100,
                                 advice: adv, spark: [],
                                 dailyMove: nil, realizedVol: 0.80, volRegime: vr)
        }

        let braked   = Alloc.allocate(ideas: [ideaWithMult(0.25, symbol: "BRAKED")],
                                      account: 100_000, maxHeat: 0.5)
        let unbraked = Alloc.allocate(ideas: [ideaWithMult(1.00, symbol: "UNBRAKED")],
                                      account: 100_000, maxHeat: 0.5)

        guard let bPos = braked.positions.first, let uPos = unbraked.positions.first else {
            Issue.record("Both ideas should be funded"); return
        }
        #expect(bPos.riskFraction < uPos.riskFraction,
                "volRegime brake 0.25 must produce strictly smaller weight than mult=1.0; got braked=\(bPos.riskFraction) unbraked=\(uPos.riskFraction)")

        // Concrete pins (cap doesn't bind at maxHeat=0.5 for either position):
        //   unbraked riskFraction = suggestedFraction/cryptoScaler × 1.0 = 0.174/4 = 0.0435
        //   braked   riskFraction = suggestedFraction/cryptoScaler × 0.25 = 0.0435 × 0.25 = 0.010875
        #expect(abs(uPos.riskFraction - 0.0435) < 1e-6,
                "unbraked riskFraction must be 0.0435 (halfKelly 0.174 ÷ cryptoScaler 4); got \(uPos.riskFraction)")
        #expect(abs(bPos.riskFraction - 0.010875) < 1e-6,
                "braked riskFraction must be 0.010875 (0.0435 × volRegimeMult 0.25); got \(bPos.riskFraction)")
    }

    // MARK: - F06: no negative-share lines survive

    @Test func noZeroOrNegativeSharesAfterAllBrakes() {
        // A very tight heat cap can round Kelly to zero shares — such lines must be DROPPED,
        // never emitted with 0 shares (that would look like a funded position without capital).
        let idea = brakedIdea(symbol: "AAPL")
        let result = Alloc.allocate(
            ideas: [idea], account: 1_000, maxHeat: 0.0001,   // tiny account + tiny cap
            regime: crisisRegime())

        for pos in result.positions {
            #expect(pos.shares > 0, "No zero-share position should survive allocation")
            #expect(pos.riskFraction > 0, "No zero-risk-fraction position should survive")
        }
    }
}
