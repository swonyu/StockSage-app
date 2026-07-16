import Testing
import Foundation
@testable import StockSage

// MARK: - Vol-of-vol sizing-reliability read (pure, deterministic)

struct StockSageVolStabilityTests {

    typealias VS = StockSageVolStability

    // MARK: - Helpers

    /// Build a close series from a per-bar return series (starting at 100.0).
    private func closes(fromReturns rets: [Double]) -> [Double] {
        var px = 100.0
        var out = [px]
        for r in rets { px *= (1 + r); out.append(px) }
        return out
    }

    /// Build a flat-vol close series: alternating ±magnitude returns for `bars` bars.
    /// Every 21-bar rolling window will see approximately the same vol → flat vol series → CoV ≈ 0.
    private func flatVolCloses(magnitude: Double = 0.01, bars: Int = 200) -> [Double] {
        let rets = (0..<bars).map { $0 % 2 == 0 ? magnitude : -magnitude }
        return closes(fromReturns: rets)
    }

    /// Build a calm/violent alternating-block close series with `blocksPerCycle` repetitions.
    /// Calm blocks: ±calmMag for blockLen bars. Violent blocks: ±violentMag for blockLen bars.
    /// This drives the rolling-vol series to alternate between two distinct vol levels → high CoV.
    private func alternatingVolCloses(
        calmMag: Double = 0.002,
        violentMag: Double = 0.05,
        blockLen: Int = 30,
        cycles: Int = 3,
        totalBars: Int = 200
    ) -> [Double] {
        var rets: [Double] = []
        var bar = 0
        var calm = true
        while bar < totalBars {
            let mag = calm ? calmMag : violentMag
            for j in 0..<blockLen where bar + j < totalBars {
                rets.append((bar + j) % 2 == 0 ? mag : -mag)
            }
            bar += blockLen
            calm.toggle()
        }
        return closes(fromReturns: rets)
    }

    // MARK: - Test 1: Constant-vol series → CoV ≈ 0, band == .steady, sizingReliability ≈ 1

    @Test func constantVolSeriesIsSteadyAndFullyReliable() {
        // 200 closes from fixed ±0.01 returns — every 21-bar rolling window sees identical vol.
        let c = flatVolCloses(magnitude: 0.01, bars: 200)
        // Ensure we meet the bar requirement.
        #expect(c.count >= 21 + 126)

        let vs = VS.volStability(closes: c)
        let result = try! #require(vs)

        #expect(result.coeffOfVariation < 0.02)   // constant-vol series should have CoV ≈ 0
        #expect(result.band == .steady)
        #expect(result.sizingReliability > 0.98)   // sizingReliability should be ≈ 1 for constant-vol
        #expect(!result.caveat.isEmpty)
    }

    // MARK: - Test 2: Alternating calm/violent series → high CoV, band == .erratic, reliability < steady

    @Test func alternatingCalmViolentSeriesIsErraticAndLessReliable() {
        let calmCloses = flatVolCloses(magnitude: 0.01, bars: 200)
        let violentCloses = alternatingVolCloses(calmMag: 0.002, violentMag: 0.05, blockLen: 25, cycles: 4, totalBars: 200)

        let steadyResult = try! #require(VS.volStability(closes: calmCloses))
        let erraticResult = try! #require(VS.volStability(closes: violentCloses))

        #expect(erraticResult.coeffOfVariation > 0.35)   // calm/violent alternating series should have CoV > 0.35
        #expect(erraticResult.band == .erratic)
        #expect(erraticResult.sizingReliability < steadyResult.sizingReliability)   // erratic < steady reliability
    }

    // MARK: - Test 3: Insufficient bars → nil

    @Test func insufficientBarsReturnsNil() {
        let volWindow = 21
        let historyWindow = 126
        let exactlyOneLess = volWindow + historyWindow - 1  // = 146 closes → nil

        // Build 146 closes (145 returns).
        let rets = [Double](repeating: 0.01, count: exactlyOneLess - 1)
        let c146 = closes(fromReturns: rets)
        #expect(c146.count == exactlyOneLess)
        #expect(VS.volStability(closes: c146) == nil)   // 146 closes should return nil

        // Empty series.
        #expect(VS.volStability(closes: []) == nil)

        // 100-close series.
        let c100 = closes(fromReturns: [Double](repeating: 0.005, count: 99))
        #expect(VS.volStability(closes: c100) == nil)   // 100 closes should return nil
    }

    // §1.A #8: an invalid (flat, vol==0) rolling window is SKIPPED (`continue`) instead of
    // aborting the whole read (the old `return nil`), and the read still requires ≥ max(5, 60%
    // of historyWindow=126) = 75 valid windows. Neither behavior was pinned — the other tests use
    // all-valid series. This pins BOTH the skip and the 75-valid-window floor.
    @Test func invalidWindowsAreSkippedAndTheMinValidWindowFloorApplies() throws {
        // 201 constant-vol closes ⇒ 126 rolling windows, all valid. Overwrite EXACTLY 21 closes
        // [90...110] with a constant ⇒ precisely ONE window (anchor i=110, slice closes[90...110])
        // is fully flat ⇒ vol 0 ⇒ INVALID. The old return-nil code would abort on it; the new
        // skip keeps the other 125 valid windows ⇒ non-nil. #require IS the discriminator.
        var c = flatVolCloses(magnitude: 0.01, bars: 200)      // 201 closes
        let fill = c[90]
        for i in 90...110 { c[i] = fill }
        let skipped = try #require(VS.volStability(closes: c)) // nil under the OLD abort-on-invalid behavior
        #expect(skipped.sizingReliability > 0 && skipped.sizingReliability <= 1)

        // Now flatten [80...200] (121 closes) ⇒ >51 windows invalid ⇒ fewer than 75 valid ⇒ the
        // min-valid-window floor returns nil (a spotty sample, honestly refused — not fabricated).
        var c2 = flatVolCloses(magnitude: 0.01, bars: 200)
        let fill2 = c2[80]
        for i in 80...200 { c2[i] = fill2 }
        #expect(VS.volStability(closes: c2) == nil)            // <75 valid windows → nil (line-106 guard)
    }

    // MARK: - Test 4: sizingReliability ∈ [0,1] and monotone non-increasing across a CoV sweep

    @Test func sizingReliabilityInRangeAndMonotoneNonIncreasingAcrossCoVSweep() {
        // Build series with progressively larger calm/violent contrast → increasing CoV.
        // violentMags sorted ascending → CoV ascending → sizingReliability should be non-increasing.
        let violentMags: [Double] = [0.005, 0.012, 0.025, 0.04, 0.06]
        let calmMag = 0.002

        var results: [(cov: Double, reliability: Double)] = []
        for vmag in violentMags {
            let c = alternatingVolCloses(calmMag: calmMag, violentMag: vmag, blockLen: 25, cycles: 3, totalBars: 210)
            guard let vs = VS.volStability(closes: c) else { continue }
            results.append((vs.coeffOfVariation, vs.sizingReliability))
        }

        // We should have enough results to test the invariant.
        #expect(results.count >= 3)   // expected at least 3 valid results for the CoV sweep

        for r in results {
            // sizingReliability ∈ [0, 1].
            #expect(r.reliability >= 0.0 - 1e-12)
            #expect(r.reliability <= 1.0 + 1e-12)

            // Verify closed-form identity: sizingReliability = 1/(1+CoV).
            let expected = 1.0 / (1.0 + r.cov)
            #expect(abs(r.reliability - expected) < 1e-9)   // sizingReliability == 1/(1+CoV) to 1e-9
        }

        // Sort by CoV and verify non-increasing reliability.
        let sorted = results.sorted { $0.cov < $1.cov }
        for i in 1..<sorted.count {
            // sizingReliability must be non-increasing in CoV (sorted by CoV ascending).
            #expect(sorted[i - 1].reliability >= sorted[i].reliability - 1e-12)
        }
    }

    // MARK: - Test 5: caveat and note are non-empty

    @Test func caveatAndNoteNonEmpty() {
        let c = flatVolCloses(magnitude: 0.01, bars: 165)
        let result = try! #require(VS.volStability(closes: c))

        #expect(!result.caveat.isEmpty)
        #expect(!result.note.isEmpty)
        // Band is one of the three valid cases.
        let validBands: [VolStability.Band] = [.steady, .choppy, .erratic]
        #expect(validBands.contains(result.band))
    }

    // MARK: - Test 6 (invariant): band thresholds are consistent with CoV

    @Test func bandThresholdsAreConsistentWithCoV() {
        // Constant-vol → CoV ≈ 0 → must be steady (< 0.15).
        let steadyCloses = flatVolCloses(magnitude: 0.01, bars: 200)
        let s = try! #require(VS.volStability(closes: steadyCloses))
        #expect(s.coeffOfVariation < 0.15)   // steady-case CoV must be < 0.15
        #expect(s.band == .steady)

        // Alternating calm/violent → CoV > 0.35 → must be erratic.
        let erraticCloses = alternatingVolCloses(calmMag: 0.002, violentMag: 0.05, blockLen: 25, cycles: 3, totalBars: 200)
        let e = try! #require(VS.volStability(closes: erraticCloses))
        #expect(e.coeffOfVariation >= 0.35)   // erratic-case CoV must be ≥ 0.35
        #expect(e.band == .erratic)
    }
}
