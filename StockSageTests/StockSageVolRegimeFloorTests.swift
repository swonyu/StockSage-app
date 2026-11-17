import Testing
import Foundation
@testable import StockSage

// MARK: - F17 — vol-regime 0.25 hard-floor tests
//
// The existing StockSageVolRegimeTests pins ≤1.0 and monotonicity but never exercises
// the 0.25 hard floor. These tests add fixtures that push the raw multiplier BELOW 0.25
// and assert the floor holds exactly.
//
// Formula (from StockSageVolRegime.sizingMultiplier):
//   absoluteBrake = min(1, medianVol / max(absFloor, currentVol))   where absFloor = medianVol*0.01
//   percentileBrake = max(0.5, 1 − max(0, pct − 0.5))
//   result = max(0.25, min(absoluteBrake, percentileBrake))
//
// Hand-derivation (derive_hardening.swift):
//   medianVol=0.20, currentVol=1.00, pct=1.0:
//     absoluteBrake = 0.20/1.00 = 0.20
//     percentileBrake = max(0.5, 1−0.5) = 0.50
//     raw min = 0.20  →  floored to 0.25 exactly ✓
//
//   medianVol=0.20, currentVol=4.00, pct=1.0:
//     absoluteBrake = 0.20/4.00 = 0.05
//     percentileBrake = 0.50
//     raw min = 0.05  →  floored to 0.25 exactly ✓

struct StockSageVolRegimeFloorTests {

    typealias VR = StockSageVolRegime

    // MARK: - sizingMultiplier direct floor tests (no close series needed)

    /// currentVol = 5× medianVol → absoluteBrake = 0.20 < 0.25 → floor fires.
    /// Derivation: medianVol=0.20, currentVol=1.00, pct=1.0 → result=0.25.
    @Test func sizingMultiplierFloorAt0_25WhenAbsoluteBrakeBelow() {
        let medianVol = 0.20
        let currentVol = 1.00   // 5× median → absoluteBrake = 0.20/1.00 = 0.20
        let pct = 1.0

        let m = VR.sizingMultiplier(percentile: pct, currentVol: currentVol, medianVol: medianVol)
        // Hand-derived: max(0.25, min(0.20, 0.50)) = max(0.25, 0.20) = 0.25
        #expect(m == 0.25,
                "Floor must be exactly 0.25 when raw min(absoluteBrake, percentileBrake) = 0.20")
    }

    /// currentVol = 20× medianVol → absoluteBrake = 0.05 ≪ 0.25 → floor fires.
    /// Derivation: medianVol=0.20, currentVol=4.00, pct=1.0 → result=0.25.
    @Test func sizingMultiplierFloorAt0_25WithExtremeCurrentVol() {
        let medianVol = 0.20
        let currentVol = 4.00   // 20× median → absoluteBrake = 0.20/4.00 = 0.05
        let pct = 1.0

        let m = VR.sizingMultiplier(percentile: pct, currentVol: currentVol, medianVol: medianVol)
        // Hand-derived: max(0.25, min(0.05, 0.50)) = 0.25
        #expect(m == 0.25,
                "Floor must be 0.25 even when absoluteBrake is only 0.05")
    }

    /// Sweeping many extreme ratios: floor must always be ≥ 0.25.
    @Test func sizingMultiplierAlwaysAtOrAbove0_25AcrossAllRatios() {
        let medianVol = 0.20
        // currentVol from 0.5× to 100× median; percentile at worst-case 1.0
        for ratio in [0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0] {
            let m = VR.sizingMultiplier(percentile: 1.0, currentVol: medianVol * ratio, medianVol: medianVol)
            #expect(m >= 0.25,
                    "sizingMultiplier must be ≥ 0.25 for all currentVol ratios (ratio=\(ratio), got \(m))")
        }
    }

    /// The floor is tight: with a ratio just ABOVE the critical 4× point the floor fires;
    /// just BELOW (currentVol = medianVol exactly) the multiplier is 1.0 (no brake at median).
    @Test func sizingMultiplierTransitionAroundFloor() {
        // At or below median (ratio ≤ 1, pct ≤ 0.5): no brake, multiplier = 1.0.
        let atMedian = VR.sizingMultiplier(percentile: 0.5, currentVol: 0.20, medianVol: 0.20)
        #expect(abs(atMedian - 1.0) < 1e-9,
                "At median, no brake should apply — multiplier should be 1.0")

        // Extreme ratio: floor fires.
        let extreme = VR.sizingMultiplier(percentile: 1.0, currentVol: 1.00, medianVol: 0.20)
        #expect(extreme == 0.25, "Floor must be 0.25 at extreme vol ratio")

        // Floor is strictly less than 1.0.
        #expect(extreme < atMedian,
                "Floor value must be strictly below no-brake value")
    }

    // MARK: - regime() end-to-end floor test (using a constructed close series)

    /// Build a series whose CURRENT 21-bar vol is far above the median of the historical
    /// distribution, so the raw sizingMultiplier would fall below 0.25.
    /// regime().sizingMultiplier must be exactly 0.25.
    @Test func regimeReturnsExactly0_25FloorForExtremeCurrentVol() {
        // 272 bars of sinusoidal low-vol (~8% ann.), then 21 bars of extreme high-vol
        // alternating 3% daily moves (~47% ann.). The final 21-bar vol window is far above
        // the median → absoluteBrake ≈ 0.12–0.20 → floor fires.
        let lowVol = 0.005   // ~8% ann.
        let highVol = 0.030  // ~47% ann.
        var closes = [100.0]
        for i in 0..<272 {
            closes.append(closes.last! * (1 + sin(Double(i)) * lowVol))
        }
        for i in 0..<21 {
            let sign: Double = i % 2 == 0 ? 1 : -1
            closes.append(closes.last! * (1 + sign * highVol))
        }
        // Must be ≥ volWindow + historyWindow = 21 + 252 = 273 bars.
        assert(closes.count >= 273, "Series too short for VolRegime")

        let result = VR.regime(closes: closes)
        // regime() returns nil when series is too short; assert non-nil first.
        guard let vr = result else {
            Issue.record("regime() returned nil for a \(closes.count)-bar series (expected ≥273 bars)")
            return
        }

        // The floor must hold exactly.
        #expect(vr.sizingMultiplier == 0.25,
                "sizingMultiplier must be exactly 0.25 when absoluteBrake falls below the floor; got \(vr.sizingMultiplier)")

        // General invariant: the multiplier from regime() must always be ≥ 0.25.
        #expect(vr.sizingMultiplier >= 0.25,
                "regime().sizingMultiplier must always be ≥ 0.25")
    }

}
