import Testing
import Foundation
@testable import StockSage

// MARK: - F40 — FastLane 1.5x threshold direct fixtures (de-circularization)
//
// The existing StockSageFastLaneBoardsTests.cryptoRotationDominantFlagsWhen1_5xCleared
// asserts the flag using EV.velocity() on the SAME ideas — circular (it uses the
// implementation to assert the implementation). These tests add two fixtures whose
// velocity sums are HAND-DERIVED to sit just ABOVE and just BELOW the 1.5× threshold,
// then assert the flag flips.
//
// EV.cryptoRotationDominant: cryptoVelocitySum > equityVelocitySum * 1.5
//
// velocity(for idea) = evR / expectedHoldDays
//   expectedHoldDays: crypto → 3d, equity → 12d (with empty spark, falls back to class default)
//   evR = winProb * rewardR − (1 − winProb)
//   winProb = 0.35 + conviction * 0.23
//
// GENUINE STRADDLE (hand-verified, derived in scratchpad/derive_hardening2.swift):
//
// Equity spine (shared by both TRUE/FALSE cases):
//   AAPL: conviction=0.7, entry=100, stop=90, target=130
//     winProb = 0.35 + 0.7*0.23 = 0.511
//     rewardR = min(30/10, 50) = 3.0
//     evR     = 0.511*3 − 0.489 = 1.044
//     vel     = 1.044/12 = 0.087
//     1.5 × equityVel = 1.5 × 0.087 = 0.1305
//
// TRUE case — BTC-USD conviction=0.7, entry=100, stop=95, target=108.7:
//   winProb = 0.511
//   rewardR = min(8.7/5, 50) = 1.74
//   evR     = 0.511*1.74 − 0.489 = 0.40014
//   vel     = 0.40014/3 = 0.13338
//   ratio   = 0.13338 / 0.087 = 1.533  →  dominant = TRUE
//
// FALSE case — BTC-USD conviction=0.7, entry=100, stop=95, target=108.5:
//   winProb = 0.511
//   rewardR = min(8.5/5, 50) = 1.70
//   evR     = 0.511*1.70 − 0.489 = 0.37970
//   vel     = 0.37970/3 = 0.12657
//   ratio   = 0.12657 / 0.087 = 1.455  →  dominant = FALSE
//
// This pins the 1.5 constant to the interval (1.455, 1.533).

struct StockSageFastLaneThresholdTests {

    typealias EV = StockSageExpectedValue

    // MARK: - Helpers

    private func idea(_ symbol: String, conviction: Double,
                      stop: Double, target: Double) -> StockSageIdea {
        StockSageIdea(
            symbol: symbol, market: "M", price: 100,
            advice: TradeAdvice(
                action: .buy, conviction: conviction, regime: .bullTrend,
                rationale: [], stopPrice: stop, targetPrice: target,
                suggestedWeight: 0.05, caveat: "x"),
            spark: [])   // empty spark → velocity falls back to expectedHoldDays default
    }

    // MARK: - Fixture A: just ABOVE 1.5× → dominant=true

    /// Genuine straddle TRUE case: cryptoVel=0.13338 vs 1.5×equityVel=0.1305 → ratio=1.533.
    /// Both fixtures share the AAPL spine (conviction=0.7, stop=90, target=130, vel=0.087).
    /// BTC target=108.7 pushes the ratio to 1.533 — just above the threshold.
    @Test func cryptoRotationDominantTrueWhenAboveThreshold() {
        // BTC-USD: conviction=0.7, stop=95, target=108.7
        //   winProb=0.511, rewardR=1.74, evR=0.40014, vel=0.40014/3=0.13338
        let btc = idea("BTC-USD", conviction: 0.7, stop: 95, target: 108.7)

        // AAPL: conviction=0.7, stop=90, target=130
        //   winProb=0.511, rewardR=3.0, evR=1.044, vel=1.044/12=0.087
        let aapl = idea("AAPL", conviction: 0.7, stop: 90, target: 130)

        // Assert derived velocities within 0.001 (non-circular check).
        let cryptoVel = EV.velocity(for: btc)
        let equityVel = EV.velocity(for: aapl)

        guard let cv = cryptoVel, let ev = equityVel else {
            Issue.record("velocity() returned nil — check EV > 0 and class defaults")
            return
        }

        // Hand-derived: BTC vel ≈ 0.13338, AAPL vel = 0.087
        #expect(abs(cv - (0.40014 / 3.0)) < 0.001,
                "BTC velocity must ≈ 0.40014/3 = 0.13338; got \(cv)")
        #expect(abs(ev - (1.044 / 12.0)) < 0.001,
                "AAPL velocity must ≈ 1.044/12 = 0.087; got \(ev)")

        // Ratio = 1.533 > 1.5 — the flag must fire.
        #expect(cv > ev * 1.5, "cryptoVel \(cv) must exceed 1.5 × equityVel \(ev) [ratio ≈ 1.533]")
        #expect(EV.cryptoRotationDominant(crypto: [btc], equity: [aapl]),
                "cryptoRotationDominant must be true when ratio ≈ 1.533 > 1.5")
    }

    // MARK: - Fixture B: just BELOW 1.5× → dominant=false

    /// Genuine straddle FALSE case: cryptoVel=0.12657 vs 1.5×equityVel=0.1305 → ratio=1.455.
    /// BTC target=108.5 (vs 108.7 in TRUE case) drops evR to 0.37970 → ratio falls to 1.455.
    @Test func cryptoRotationDominantFalseWhenBelowThreshold() {
        // BTC-USD: conviction=0.7, stop=95, target=108.5
        //   winProb=0.511, rewardR=1.70, evR=0.37970, vel=0.37970/3=0.12657
        let btc = idea("BTC-USD", conviction: 0.7, stop: 95, target: 108.5)

        // AAPL: conviction=0.7, stop=90, target=130 (same spine as TRUE case)
        //   winProb=0.511, rewardR=3.0, evR=1.044, vel=1.044/12=0.087
        let aapl = idea("AAPL", conviction: 0.7, stop: 90, target: 130)

        let cryptoVel = EV.velocity(for: btc)
        let equityVel = EV.velocity(for: aapl)

        guard let cv = cryptoVel, let ev = equityVel else {
            Issue.record("velocity() returned nil — check EV > 0 and class defaults")
            return
        }

        // Hand-derived: BTC vel ≈ 0.12657, AAPL vel = 0.087
        #expect(abs(cv - (0.37970 / 3.0)) < 0.001,
                "BTC velocity must ≈ 0.37970/3 = 0.12657; got \(cv)")
        #expect(abs(ev - (1.044 / 12.0)) < 0.001,
                "AAPL velocity must ≈ 1.044/12 = 0.087; got \(ev)")

        // Ratio = 1.455 < 1.5 — the flag must NOT fire.
        #expect(cv <= ev * 1.5, "cryptoVel \(cv) must NOT exceed 1.5 × equityVel \(ev) [ratio ≈ 1.455]")
        #expect(!EV.cryptoRotationDominant(crypto: [btc], equity: [aapl]),
                "cryptoRotationDominant must be false when ratio ≈ 1.455 < 1.5")
    }

    // MARK: - Threshold boundary: negative crypto EV → velocity nil → dominant false

    /// When crypto EV is negative, velocity() returns nil; cryptoSum = 0 → dominant = false.
    /// The strict > condition means even a non-negative cryptoSum that equals equitySum*1.5
    /// is false, but the most reliable boundary test is the nil-velocity (EV < 0) path.
    @Test func cryptoRotationDominantFalseWhenCryptoEVNegative() {
        // BTC-USD: conviction=0.7, stop=97, target=100.3
        //   p=0.511; rewardR=min(0.3/3,50)=0.1; evR=0.511*0.1−0.489=−0.438 → negative EV
        //   velocity() returns nil for negative EV → cryptoSum = 0 → function returns false
        let btcNegEV = idea("BTC-USD", conviction: 0.7, stop: 97, target: 100.3)
        let aapl = idea("AAPL", conviction: 0.7, stop: 90, target: 130)
        #expect(!EV.cryptoRotationDominant(crypto: [btcNegEV], equity: [aapl]),
                "Must be false when crypto EV is negative (velocity nil → sum 0)")
    }

    // MARK: - Flag flips between above-threshold and below-threshold fixtures

    /// Directly assert the flag is true for the TRUE fixture and false for the FALSE fixture —
    /// confirms the 1.5× threshold is what drives the flip, not a sign error.
    @Test func flagFlipsCorrectlyBetweenAboveAndBelowThreshold() {
        let btcAbove = idea("BTC-USD", conviction: 0.7, stop: 95, target: 108.7)
        let aaplAbove = idea("AAPL", conviction: 0.7, stop: 90, target: 130)

        let btcBelow = idea("BTC-USD", conviction: 0.7, stop: 95, target: 108.5)
        let aaplBelow = idea("AAPL", conviction: 0.7, stop: 90, target: 130)

        let aboveSplit = EV.fastLaneByClass([btcAbove, aaplAbove])
        let belowSplit = EV.fastLaneByClass([btcBelow, aaplBelow])

        #expect(EV.cryptoRotationDominant(crypto: aboveSplit.crypto, equity: aboveSplit.equity),
                "Above-threshold fixture (ratio≈1.533) must produce dominant=true")
        #expect(!EV.cryptoRotationDominant(crypto: belowSplit.crypto, equity: belowSplit.equity),
                "Below-threshold fixture (ratio≈1.455) must produce dominant=false")
    }
}
