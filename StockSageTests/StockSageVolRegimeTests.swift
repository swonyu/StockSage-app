import Testing
import Foundation
@testable import StockSage

// MARK: - Per-symbol vol regime brake tests (pure, deterministic)
// Spec: EDGE_RESEARCH.md #1
//   ✓ Flat vol → percentile≈0.5, multiplier==1.0 (no brake when calm)
//   ✓ Low→high vol regime change → percentile near 1.0, multiplier < 1 < calm case
//   ✓ closes.count just under volWindow+historyWindow → nil
//   ✓ sizingMultiplier non-increasing across p sweep 0→1, never exceeds 1
//   ✓ caveat is non-empty

struct StockSageVolRegimeTests {

    typealias VR = StockSageVolRegime

    // MARK: - Helpers

    /// Build a close series with a CONSTANT level of realized vol using deterministic
    /// sinusoidal returns — vol is approximately the same every 21-bar window so all
    /// historical windows produce similar vol readings. Used to verify the calm-regime
    /// "no brake" property.
    private func flatCloses(count: Int, amplitude: Double = 0.008) -> [Double] {
        var px = 100.0
        var out = [px]
        for i in 1..<count { px *= (1 + sin(Double(i)) * amplitude); out.append(px) }
        return out
    }

    /// Build a close series that starts with low-vol returns and ends with high-vol returns.
    private func lowThenHighVolCloses(total: Int = 300) -> [Double] {
        let lowVol = 0.005    // ~8% annualized
        let highVol = 0.040   // ~63% annualized
        var px = 100.0
        var out = [px]
        // First 272 bars: low vol (fills history window with calm readings)
        for i in 0..<272 {
            let r = sin(Double(i)) * lowVol
            px *= (1 + r); out.append(px)
        }
        // Last 21 bars: high vol (latest rolling window should rank near top)
        for i in 0..<21 {
            let sign: Double = i % 2 == 0 ? 1 : -1
            px *= (1 + sign * highVol); out.append(px)
        }
        return out
    }

    // MARK: - Tests

    @Test func flatVolGivesPercentileNearHalfAndMultiplierOne() {
        // Flat-vol series: every 21-bar window has the same vol → percentile ≈ 0.5,
        // currentVol ≈ medianVol → multiplier ≈ 1.0 (no brake when calm).
        let closes = flatCloses(count: 300)
        let result = try! #require(VR.regime(closes: closes))
        // Percentile should be near the middle of [0,1].
        #expect(result.percentile >= 0.3 && result.percentile <= 0.7)
        // Multiplier should be 1.0 (no brake when vol is at its own median).
        #expect(abs(result.sizingMultiplier - 1.0) < 0.01)
    }

    @Test func lowThenHighVolGivesElevatedPercentileAndReducedMultiplier() {
        let closes = lowThenHighVolCloses()
        let result = try! #require(VR.regime(closes: closes))
        // Latest window is high vol — should rank near top of history.
        #expect(result.percentile > 0.7)
        // Multiplier must be strictly below 1.
        #expect(result.sizingMultiplier < 1.0)
        // And never exceeds 1.
        #expect(result.sizingMultiplier <= 1.0)
    }

    @Test func tooShortHistoryReturnsNil() {
        // volWindow=21 + historyWindow=252 = 273 minimum; 272 bars should return nil.
        let closes = flatCloses(count: 272)
        #expect(VR.regime(closes: closes, volWindow: 21, historyWindow: 252) == nil)
    }

    @Test func minimumBarsReturnsSomething() {
        let closes = flatCloses(count: 273)
        #expect(VR.regime(closes: closes, volWindow: 21, historyWindow: 252) != nil)
    }

    @Test func perturbingOnlyTheMostRecentCloseChangesCurrentVol() {
        // Each rolling window must include its own anchor bar `i` — a half-open range that
        // stops one short would make `current` (the final window) permanently blind to the
        // single most recent close. Change ONLY the last close and confirm `current` moves.
        var base = flatCloses(count: 280)
        let baseline = VR.regime(closes: base, volWindow: 21, historyWindow: 252)!
        base[base.count - 1] *= 1.15   // a real, sizeable one-day move on the latest bar
        let perturbed = VR.regime(closes: base, volWindow: 21, historyWindow: 252)!
        #expect(abs(perturbed.current - baseline.current) > 1e-9)
    }

    @Test func sizingMultiplierNonIncreasingAcrossPercentileSweep() {
        // Hold currentVol=0.30, medianVol=0.20 constant; vary percentile 0→1.
        // multiplier must be non-increasing.
        let currentVol = 0.30
        let medianVol  = 0.20
        var prev = Double.infinity
        for step in 0...10 {
            let p = Double(step) / 10.0
            let m = VR.sizingMultiplier(percentile: p, currentVol: currentVol, medianVol: medianVol)
            #expect(m <= prev + 1e-9)
            prev = m
        }
    }

    @Test func sizingMultiplierNeverExceedsOne() {
        let medianVol = 0.20
        for step in 0...10 {
            let p = Double(step) / 10.0
            for ratio in [0.5, 1.0, 1.5, 2.0, 3.0] {
                let m = VR.sizingMultiplier(percentile: p, currentVol: medianVol * ratio, medianVol: medianVol)
                #expect(m <= 1.0 + 1e-9)
            }
        }
    }

    @Test func multiplierAtVolBelowMedianIsOne() {
        // When current vol is BELOW the median, absoluteBrake=1 and percentile is low → no brake.
        let m = VR.sizingMultiplier(percentile: 0.3, currentVol: 0.10, medianVol: 0.20)
        #expect(abs(m - 1.0) < 0.01)
    }

    @Test func caveatIsNonEmpty() {
        #expect(!VR.caveat.isEmpty)
        let closes = flatCloses(count: 300)
        if let result = VR.regime(closes: closes) {
            #expect(!result.caveat.isEmpty)
            #expect(!result.note.isEmpty)
        }
    }

    // MARK: - F17: the 0.25 hard sizing floor ("sizing never goes to 0")
    // The load-bearing lower bound of the entire brake chain was pinned by NO test — the
    // suite above only reaches ratio 3.0 (→ 0.333), which never touches the floor. Expected
    // values derived independently in /tmp/derive_volregime_floor.swift (NOT read off code):
    //   p=1, cur=1.0, med=0.2 → raw min(absoluteBrake 0.2, percentileBrake 0.5)=0.2 < 0.25 → floor BINDS → 0.25
    //   p=1, cur=100, med=0.2 → raw 0.02 → still exactly 0.25 (proves a floor, not a coincidence)
    //   p=1, cur=0.8 (=4×med) → raw exactly 0.25 (floor meets raw)
    //   p=1, cur=0.6 (=3×med) → 0.333 > 0.25 (the gap the old suite left — floor unreached)
    // 0.25 == 1/4 is exact in binary FP and max(0.25, x) returns the literal when x<0.25, so
    // `== 0.25` is a safe exact assertion here.

    @Test func sizingMultiplierFlooredAtQuarterUnderExtremeVol() {
        #expect(VR.sizingMultiplier(percentile: 1.0, currentVol: 1.0, medianVol: 0.2) == 0.25)   // floor binds
        #expect(VR.sizingMultiplier(percentile: 1.0, currentVol: 100.0, medianVol: 0.2) == 0.25) // stays floored — it IS a floor
        #expect(VR.sizingMultiplier(percentile: 1.0, currentVol: 0.8, medianVol: 0.2) == 0.25)   // boundary: raw==floor
        #expect(VR.sizingMultiplier(percentile: 1.0, currentVol: 0.6, medianVol: 0.2) > 0.25)    // ratio 3.0: above the floor
    }

    @Test func regimeSizingMultiplierNeverBelowFloorEndToEnd() {
        // The floor must hold through the full regime() pipeline, not just the pure helper.
        // The low→very-high vol tail (~8% → ~63% annualized, ratio ≫ 4×) drives the absolute
        // brake well below 0.25; the pipeline must clamp to the floor (never 0, never negative).
        let closes = lowThenHighVolCloses()
        let result = try! #require(VR.regime(closes: closes))
        #expect(result.sizingMultiplier >= 0.25 - 1e-12)   // floor respected end-to-end
        #expect(result.sizingMultiplier < 1.0)             // brake genuinely engaged (non-vacuous)
    }
}
