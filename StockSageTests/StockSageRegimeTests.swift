import Testing
import Foundation
@testable import StockSage

// MARK: - Market regime gauge (pure)

struct StockSageRegimeTests {

    @Test func calmUptrendWithBroadStrengthIsRiskOnBull() {
        let r = StockSageRegime.assess(
            indexCloses: (1...250).map(Double.init),   // clean uptrend → above 200DMA, RSI high
            vix: 15,                                    // calm
            breadthAbove200: 0.80)                      // broad strength
        #expect(r.state == .trendingBull)
        #expect(r.riskScore > 0.4)
        #expect(r.sizingBias > 1.0)                     // size UP in a calm bull
    }

    @Test func highVixForcesCrisisAndHardCutSizing() {
        let r = StockSageRegime.assess(
            indexCloses: (1...250).map(Double.init),
            vix: 50,                                    // crisis zone
            breadthAbove200: 0.80)
        #expect(r.state == .crisis)
        #expect(r.sizingBias == 0.25)                   // hard-cut exposure regardless of trend
    }

    @Test func downtrendWeakBreadthIsRiskOffBear() {
        let r = StockSageRegime.assess(
            indexCloses: (1...250).reversed().map(Double.init),   // downtrend, below 200DMA
            vix: 30,                                              // elevated, not crisis
            breadthAbove200: 0.20)                                // weak breadth
        #expect(r.state == .trendingBear)
        #expect(r.riskScore < 0)
        #expect(r.sizingBias < 0.75)                              // size DOWN
    }

    @Test func emptyInputsDegradeToNeutralWithoutCrashing() {
        let r = StockSageRegime.assess(indexCloses: [], vix: nil, breadthAbove200: nil)
        #expect(r.state == .ranging)
        #expect(r.riskScore == 0)
        #expect(r.signals.isEmpty)
    }

    @Test func regimeAdjustedWeightAppliesBiasAndCap() {
        #expect(abs(StockSageRegime.adjustedWeight(base: 0.10, bias: 1.20, cap: 0.20) - 0.12) < 1e-9)
        #expect(abs(StockSageRegime.adjustedWeight(base: 0.15, bias: 0.25, cap: 0.20) - 0.0375) < 1e-9)
        #expect(StockSageRegime.adjustedWeight(base: 0.30, bias: 1.20, cap: 0.20) == 0.20)   // capped
        #expect(StockSageRegime.adjustedWeight(base: 0, bias: 1.20, cap: 0.20) == 0)
    }

    private func history(_ closes: [Double]) -> StockSagePriceHistory {
        StockSagePriceHistory(
            symbol: "X",
            dates: closes.enumerated().map { Date(timeIntervalSince1970: Double($0.offset) * 86_400) },
            opens: closes, highs: closes, lows: closes, closes: closes, volumes: closes.map { _ in 0 })
    }

    @Test func breadthExcludesNamesWithoutA200DMA() {
        let up = history((1...250).map(Double.init))                  // above its 200DMA
        let down = history((1...250).reversed().map(Double.init))     // below its 200DMA
        let short = history((1...50).map(Double.init))                // <200 bars → EXCLUDED
        #expect(StockSageRegime.breadth([up, down, short]) == 0.5)    // 1 of 2 eligible above
        #expect(StockSageRegime.breadth([short]) == nil)             // none eligible
        #expect(StockSageRegime.breadth([]) == nil)
    }

    @Test func zeroBiasSilentlyZerosPosition() {
        #expect(StockSageRegime.adjustedWeight(base: 0.10, bias: 0.0, cap: 0.20) == 0.0)
    }

    // sizingBias band clamps [0.40, 1.25] — pins the EXACT boundaries the looser
    // `> 1.0` / `< 0.75` tests above leave open (money-math verification 2026-07-07,
    // invariant #8 was only PARTIAL: crisis 0.25 pinned, the band edges were not).
    // sizingBias = crisis ? 0.25 : max(0.40, min(1.25, 0.75 + risk*0.5)); risk = clamp(score,±1).
    // Hand-derived in scratchpad/derive_regime_band.swift.
    @Test func sizingBiasBandClampsAtExactBounds() {
        // Max-BEAR non-crisis: downtrend (−0.40) + RSI<45 (−0.10) + breadth≤0.30 (−0.25)
        // + VIX 20–40 elevated (−0.15) = score −0.90 → raw 0.75−0.45 = 0.30, CLAMPED UP to 0.40.
        // Genuine straddle: the raw 0.30 sits BELOW the 0.40 floor, so this proves the clamp binds.
        let bear = StockSageRegime.assess(
            indexCloses: (1...250).reversed().map(Double.init),
            vix: 30, breadthAbove200: 0.20)
        #expect(bear.state == .trendingBear)
        #expect(abs(bear.sizingBias - 0.40) < 1e-9)          // lower clamp binds (raw 0.30 → 0.40)

        // Max-BULL non-crisis: uptrend (+0.40) + RSI>55 (+0.10) + breadth≥0.70 (+0.25)
        // + VIX<20 calm (+0.10) = score +0.85 → 0.75 + 0.425 = 1.175 (< the 1.25 upper clamp,
        // i.e. the max REACHABLE bias is 1.175; the 1.25 cap is deliberately slack, never binds).
        let bull = StockSageRegime.assess(
            indexCloses: (1...250).map(Double.init),
            vix: 15, breadthAbove200: 0.80)
        #expect(bull.state == .trendingBull)
        #expect(abs(bull.sizingBias - 1.175) < 1e-9)         // exact linear value, below the 1.25 cap
        #expect(bull.sizingBias < 1.25)                      // upper clamp is slack at max reachable
    }
}
