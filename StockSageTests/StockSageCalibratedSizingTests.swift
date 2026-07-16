import Testing
import Foundation
@testable import StockSage

// MARK: - Calibrated half-Kelly sizing via StockSageAdvisor.suggestedWeight(…)

/// Tests that the calibrated win-prob path in `suggestedWeight` diverges correctly from
/// the conservative linear prior path, that nil-calibration is byte-identical to the prior
/// inline math, and that all sizing clamps hold under both paths.
struct StockSageCalibratedSizingTests {
    typealias Cal = StockSageConvictionCalibration

    // Build a calibration whose top conviction band win-prob is materially above the linear prior.
    // Feeds 60 synthetic trades so `fit` has enough samples (minSamples = 30) to calibrate.
    // The top-band (conviction 0.5–1.0) always wins → Wilson-LCB will be high but ≤ raw rate.
    //
    // [iter7] These sizing tests are written against the Platt small-N MAP this fixture produces
    // (e.g. "conviction 0.0 → low win-prob → zero weight"). With the candidate-selector ACTIVE by
    // default, this synthetic fixture's chronological test slice is all-wins, so the OOS-Brier
    // winner (Beta) collapses to a near-flat ~0.75 map — a legitimate selector result, but one that
    // breaks the OFF-path map-shape these clamp/edge tests assert. Pin the flag OFF for the duration
    // of the fit so the helper always returns the Platt map it documents; the selector's own
    // behavior is covered by StockSageCalibrationSelectorTests. (Restored after the fit.)
    private static func highWinCalibration() throws -> Cal {
        let saved = Cal.candidateSelectorEnabled; defer { Cal.candidateSelectorEnabled = saved }
        Cal.candidateSelectorEnabled = false
        // Deterministic outcomes: 30 trades in lower band (conviction ≈ 0.2, 50% win),
        // 30 in upper band (conviction ≈ 0.8, 100% win).
        let outcomes: [(conviction: Double, won: Bool)] =
            (0..<30).map { i in (conviction: 0.2, won: i < 15) }
          + (0..<30).map { _ in (conviction: 0.8, won: true) }
        // Use #require so a nil result surfaces as a legible per-test failure (not a process crash).
        return try #require(
            Cal.fit(outcomes, binCount: 5, minSamples: 30, minPerBin: 5, z: 1.0),
            "highWinCalibration: Cal.fit returned nil — adjust synthetic data or minSamples"
        )
    }

    // The linear prior at conviction 0.6: 0.35 + 0.23 * 0.6 = 0.488
    // Setup: buy, conviction 0.6, price 100, stop 92 (stopDist 8%), target 116 (R = 2.0), vol 0.20.
    private static let testAction: TradeAdvice.Action = .buy
    private static let testConviction: Double = 0.6
    private static let testPrice: Double = 100.0
    private static let testStop: Double = 92.0
    private static let testTarget: Double = 116.0
    private static let testVol: Double = 0.20

    // MARK: - Win-prob divergence (intermediate quantity, not cap-dominated weight)
    //
    // WHY we assert on winProbEstimate rather than suggestedWeight:
    //   At R = 2.0 and riskPerTrade = 1%, the riskPerTrade budget cap dominates for every
    //   realizable win-prob, so suggestedWeight(calibrated) == suggestedWeight(prior) == 0.125
    //   and the weight comparison proves nothing.  The correct unit to test is the intermediate
    //   win-probability that drives the Kelly numerator — the calibration changes that number
    //   and this test verifies the calibrated path returns a higher win-prob than the linear prior.
    @Test func testCalibratedWinProbExceedsPrior() throws {
        let cal = try Self.highWinCalibration()
        let pPrior = StockSageExpectedValue.winProbEstimate(conviction: Self.testConviction, calibration: nil)
        let pCal   = StockSageExpectedValue.winProbEstimate(conviction: Self.testConviction, calibration: cal)

        // The upper band (conviction ≈ 0.8, 100% wins) should produce a win-prob well above the
        // linear prior (0.488) for conviction = 0.6 (which maps into the upper calibration band).
        #expect(pCal > pPrior, "Calibrated win-prob should exceed prior for high-win upper band")
        #expect(pPrior > 0 && pPrior.isFinite, "Prior win-prob must be positive and finite")
        #expect(pCal > 0 && pCal <= 1.0, "Calibrated win-prob must be in (0, 1]")
    }

    @Test func testNilCalibrationLeavesWeightUnchanged() {
        // Hand-compute the expected weight for the test setup (nil calibration = linear prior).
        // W = 0.35 + 0.23 * 0.6 = 0.488; R = min(16/8, 50) = 2.0; fStar = max(0, 0.488 - 0.512/2) = max(0, 0.488 - 0.256) = 0.232
        // riskFraction = min(0.232/2, 0.01) = min(0.116, 0.01) = 0.01
        // cryptoRiskScaler(0.20, baseline 0.20): max(1, 0.20/0.20) = 1.0 (vol at baseline, floor applies → no shrink)
        // stopDistPct = |100 - 92| / 100 = 0.08
        // weight = min(0.01 / 0.08, 0.20) = min(0.125, 0.20) = 0.125
        let expected = 0.125

        let wNil = StockSageAdvisor.suggestedWeight(
            action: Self.testAction, conviction: Self.testConviction,
            price: Self.testPrice, stop: Self.testStop, target: Self.testTarget,
            realizedVol: Self.testVol, calibration: nil)

        #expect(abs(wNil - expected) < 1e-9, "nil-calibration weight must match hand-computed prior value (regression guard)")
    }

    @Test func testWeightClampsHoldUnderCalibration() throws {
        let cal = try Self.highWinCalibration()
        // Fat R (large target) to make raw Kelly huge, confirming caps still hold.
        let fatTarget = 1000.0   // R = (1000-100)/8 = 112.5 → capped at 50
        let wCal = StockSageAdvisor.suggestedWeight(
            action: .buy, conviction: 0.9,
            price: 100.0, stop: 92.0, target: fatTarget,
            realizedVol: 0.20, calibration: cal)

        #expect(wCal <= StockSageAdvisor.maxWeight + 1e-12, "weight must not exceed maxWeight (0.20)")

        // 1% risk-per-trade budget: weight * stopDistPct ≤ riskPerTrade (after vol shrink).
        let stopDistPct = abs(100.0 - 92.0) / 100.0
        // Vol scaler at 20% vol is 1.0 (vol at baseline) → implied risk = weight * stopDistPct
        #expect(wCal * stopDistPct <= StockSageAdvisor.riskPerTrade + 1e-12, "implied risk must not exceed riskPerTrade (1%)")

        // Non-positive-edge case: very low conviction → fStar = max(0, W − (1−W)/R); W small → 0.
        let wZero = StockSageAdvisor.suggestedWeight(
            action: .buy, conviction: 0.0,
            price: 100.0, stop: 99.0, target: 100.5,   // thin R ≈ 0.5
            realizedVol: nil, calibration: cal)
        #expect(wZero == 0, "low conviction + thin reward:risk → zero weight")
    }

    // MARK: - Neutral actions (hold / avoid) must return zero; sell-family actions must be nonzero

    /// .hold and .avoid should return 0 weight (no position taken) on both the calibrated and
    /// nil-calibration paths.  .sell and .reduce are intentionally sized (isSell = true in the
    /// Kelly block) and must return a positive weight when a valid stop/target are supplied.
    @Test func testNeutralActionsReturnZeroWeight() throws {
        let cal = try Self.highWinCalibration()
        // Neutral actions → zero weight (both calibrated and nil paths).
        for action: TradeAdvice.Action in [.hold, .avoid] {
            let w = StockSageAdvisor.suggestedWeight(
                action: action, conviction: 1.0,
                price: 100.0, stop: 90.0, target: 120.0,
                realizedVol: 0.20, calibration: cal)
            #expect(w == 0, "\(action.rawValue) (calibrated) must return zero weight")

            let wNil = StockSageAdvisor.suggestedWeight(
                action: action, conviction: 1.0,
                price: 100.0, stop: 90.0, target: 120.0,
                realizedVol: 0.20, calibration: nil)
            #expect(wNil == 0, "\(action.rawValue) (nil-cal) must also return zero weight")
        }

        // Sell-family actions (.sell, .reduce) pass through the Kelly math → nonzero weight when
        // stop is above price and target is below price (valid short setup).
        for action: TradeAdvice.Action in [.sell, .reduce] {
            let wSell = StockSageAdvisor.suggestedWeight(
                action: action, conviction: 0.8,
                price: 100.0, stop: 110.0, target: 80.0,   // short: stop above, target below
                realizedVol: 0.20, calibration: cal)
            #expect(wSell > 0, "\(action.rawValue) with valid short setup should return positive weight under calibration")
            #expect(wSell <= StockSageAdvisor.maxWeight + 1e-12,
                    "\(action.rawValue) calibrated weight must not exceed maxWeight")
        }
    }

    @Test func testVolTargetShrinksCalibratedWeight() throws {
        let cal = try Self.highWinCalibration()
        let wLowVol = StockSageAdvisor.suggestedWeight(
            action: Self.testAction, conviction: Self.testConviction,
            price: Self.testPrice, stop: Self.testStop, target: Self.testTarget,
            realizedVol: 0.20, calibration: cal)
        let wHighVol = StockSageAdvisor.suggestedWeight(
            action: Self.testAction, conviction: Self.testConviction,
            price: Self.testPrice, stop: Self.testStop, target: Self.testTarget,
            realizedVol: 0.70, calibration: cal)

        #expect(wHighVol < wLowVol, "70%-vol weight must be strictly smaller than 20%-vol weight (vol-targeting applies on calibrated path)")
    }
}
