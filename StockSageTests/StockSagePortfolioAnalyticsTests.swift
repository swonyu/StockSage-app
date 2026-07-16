import Testing
import Foundation
@testable import StockSage

// MARK: - Portfolio risk analytics (pure)

struct StockSagePortfolioAnalyticsTests {

    typealias PA = StockSagePortfolioAnalytics

    @Test func dailyReturnsComputeCorrectly() {
        let r = PA.dailyReturns([100, 110, 99])
        #expect(r.count == 2)
        #expect(abs(r[0] - 0.10) < 1e-9)     // +10%
        #expect(abs(r[1] + 0.10) < 1e-9)     // −10%
    }

    @Test func maxDrawdownIsPeakToTrough() {
        // equity: 1.1 → 1.21 → 0.605 → DD = (1.21−0.605)/1.21 = 0.5
        #expect(abs(PA.maxDrawdown([0.1, 0.1, -0.5]) - 0.5) < 1e-9)
        #expect(PA.maxDrawdown([0.01, 0.01, 0.01]) == 0)   // monotonic up → no drawdown
    }

    @Test func correlationExtremes() {
        #expect(abs((PA.correlation([0.1, 0.2, 0.3], [0.1, 0.2, 0.3]) ?? 0) - 1) < 1e-9)
        #expect(abs((PA.correlation([0.1, -0.1, 0.1, -0.1], [-0.1, 0.1, -0.1, 0.1]) ?? 0) + 1) < 1e-9)
    }

    @Test func correlationIsNilNotZeroForInsufficientOverlap() {
        // n<2 is the SAME "undefined" semantic as zero variance: correlation requires
        // at least two paired observations to be mathematically defined. Must return nil,
        // consistent with the zero-variance convention, so callers exclude it rather than
        // treating a thin/overlapping pair as "uncorrelated". All production callers pre-guard
        // to n≥2 (ClusterCheck ≥2, Precheck minOverlap=5, laneCorrelation filter{≥2}), so
        // this convention is byte-identical to the prior return-0 in practice (F33 2026-07-02).
        #expect(PA.correlation([], []) == nil)                     // n=0
        #expect(PA.correlation([0.1], [0.1]) == nil)               // n=1
        #expect(PA.correlation([0.1, 0.2], [0.1]) == nil)          // min(2,1)=1
        #expect(PA.correlation([0.1], [0.1, 0.2]) == nil)          // min(1,2)=1
        // n=2 is the boundary: with 2 points Pearson IS defined (unless zero variance).
        #expect(PA.correlation([0.1, 0.2], [0.1, 0.2]) != nil)    // n=2 → defined
    }

    @Test func correlationIsNilNotZeroForAZeroVarianceSeries() {
        // A flat/halted/illiquid series has ZERO variance — its correlation with anything is
        // mathematically 0/0 (UNDEFINED), not a real "uncorrelated" 0. Must be nil so callers
        // EXCLUDE it, not silently treat a flat holding as maximally diversifying.
        let flat = [100.0, 100.0, 100.0, 100.0]
        let moving: [Double] = [0.01, -0.02, 0.03, -0.01]
        #expect(PA.correlation(flat, moving) == nil)
        #expect(PA.correlation(moving, flat) == nil)
        #expect(PA.correlation(flat, flat) == nil)   // both flat → still undefined, not "perfectly correlated"
    }

    @Test func averageCorrelationOfSingleHoldingIsOne() {
        #expect(PA.averageCorrelation([[0.1, 0.2, 0.3]]) == 1)          // concentrated
        #expect(abs(PA.averageCorrelation([[0.1, 0.2], [0.1, 0.2]]) - 1) < 1e-9)
    }

    @Test func averageCorrelationExcludesAZeroVarianceHoldingRatherThanTreatingItAsUncorrelated() {
        // Three holdings: two genuinely +1-correlated, one FLAT (zero variance, undefined vs
        // both). If the flat holding were treated as a fake 0, the average would be dragged down
        // (falsely reading as more diversified). Excluded, the average must equal exactly the
        // one real, defined pair (+1) — not a blend that includes a phantom "uncorrelated" 0.
        let a: [Double] = [0.1, 0.2, 0.3, 0.1]
        let identicalToA = a
        let flat: [Double] = [100, 100, 100, 100]
        let avg = PA.averageCorrelation([a, identicalToA, flat])
        #expect(abs(avg - 1) < 1e-9)   // only the (a, identicalToA) pair is defined, and it's +1

        // All-flat (every pair undefined) → no defined pairs → falls back to the existing
        // "no data → assume fully concentrated" convention (1), not a fake 0.
        #expect(PA.averageCorrelation([flat, flat]) == 1)
    }

    @Test func percentileNearestRank() {
        #expect(PA.percentile([1, 2, 3, 4, 5], 0.0) == 1)
        #expect(PA.percentile([1, 2, 3, 4, 5], 1.0) == 5)
    }

    @Test func computeRejectsTooLittleHistory() {
        #expect(PA.compute(holdings: [(1.0, [100, 101, 102])]) == nil)   // 2 returns < 5
        #expect(PA.compute(holdings: []) == nil)
    }

    @Test func computeReturnsSuiteWithCorrectMetadata() {
        let rising = (0..<12).map { 100.0 + Double($0) }
        let a = PA.compute(holdings: [(1000, rising), (1000, rising)])
        #expect(a != nil)
        #expect(a?.holdingsAnalyzed == 2)
        #expect(a?.observations == 11)                  // 12 closes → 11 returns
        #expect(abs((a?.avgCorrelation ?? 0) - 1) < 1e-6)   // identical → fully correlated
        #expect((a?.diversificationScore ?? 100) < 20)      // two identical names = poorly diversified
        #expect(a?.maxDrawdown == 0)                    // monotonic up
        #expect(a?.calmar == nil)   // maxDrawdown == 0 → calmar is UNDEFINED, not a fake 0.00
    }

    @Test func aNonFiniteHoldingWeightIsExcludedRatherThanPoisoningEveryOtherHoldingsWeight() {
        let closes = (0..<12).map { 100.0 + Double($0) }
        let poisoned = PA.compute(holdings: [(.infinity, closes), (1000, closes)])
        let clean = PA.compute(holdings: [(1000, closes)])
        // A non-finite weight must not turn every OTHER holding's normalized weight into 0
        // (finite / .infinity) or the poisoned holding's own weight into NaN — the poisoned
        // input should be excluded, so the result matches the single valid holding alone.
        #expect(poisoned != nil)
        #expect(poisoned?.annualizedReturn.isFinite == true)
        #expect(abs((poisoned?.annualizedReturn ?? .nan) - (clean?.annualizedReturn ?? .nan)) < 1e-6)
        #expect(poisoned?.sharpe?.isFinite ?? true)
    }

    @Test func allNonFiniteWeightsReturnNilRatherThanACrashOrNaNSuite() {
        let closes = (0..<12).map { 100.0 + Double($0) }
        #expect(PA.compute(holdings: [(.infinity, closes), (.nan, closes)]) == nil)
    }

    @Test func ratioMetricsAreConsistentWithTheirComponents() {
        // Single holding → portfolio returns == its daily returns, so the ratio
        // metrics can be pinned against the public helpers (no magic annualized
        // numbers). Guards the Sharpe/Sortino/Calmar/VaR formulas from regression.
        let closes: [Double] = [100, 110, 105, 115, 108, 120, 112, 118]   // up & down days
        let a = PA.compute(holdings: [(1000, closes)])!
        let rets = PA.dailyReturns(closes)

        #expect(abs(a.maxDrawdown - PA.maxDrawdown(rets) * 100) < 1e-6)
        #expect(abs(a.valueAtRisk95 - max(0, -PA.percentile(rets, 0.05) * 100)) < 1e-6)
        #expect(a.annualizedVolatility > 0)
        #expect(a.sharpe != nil)   // defined here (vol > 0)
        #expect(abs(a.sharpe! - a.annualizedReturn / a.annualizedVolatility) < 1e-6)
        #expect(a.maxDrawdown > 0)
        #expect(a.calmar != nil)   // defined here (maxDrawdown > 0)
        #expect(abs(a.calmar! - a.annualizedReturn / a.maxDrawdown) < 1e-6)
        // Sortino's downside deviation is normalized over ALL observations (the fix);
        // reverting to ÷down-day-count would break this.
        let n = Double(rets.count)
        let downSq = rets.reduce(0.0) { $0 + min($1, 0) * min($1, 0) }
        let downDev = (downSq / n).squareRoot() * (252.0).squareRoot() * 100
        #expect(downDev > 0)
        #expect(a.sortino != nil)   // defined here (downside > 0)
        #expect(abs(a.sortino! - a.annualizedReturn / downDev) < 1e-6)
    }

    @Test func zeroVolatilityYieldsUndefinedSharpeSortino() {
        // No movement → zero realized vol & zero downside → the ratios are UNDEFINED.
        // They must be nil (rendered "n/a"), never a sentinel that reads as a real 100.
        let flat = Array(repeating: 100.0, count: 8)
        let a = PA.compute(holdings: [(1000, flat)])!
        #expect(a.annualizedVolatility == 0)
        #expect(a.sharpe == nil)
        #expect(a.sortino == nil)
    }

    @Test func correlationMatrixIsSymmetricWithUnitDiagonal() {
        let a: [Double] = [0.1, 0.2, 0.3]
        let b: [Double] = [-0.1, -0.2, -0.3]            // perfectly anti-correlated with a
        let m = PA.correlationMatrix([a, b])
        #expect(m.count == 2 && m[0].count == 2)
        #expect(m[0][0] == 1 && m[1][1] == 1)           // unit diagonal
        #expect(abs(m[0][1] - m[1][0]) < 1e-12)         // symmetric
        #expect(abs(m[0][1] + 1) < 1e-9)                // a vs b = −1
        #expect(PA.correlationMatrix([[0.1, 0.2]]) == [[1.0]])   // single series → identity
    }

    @Test func correlationMatrixShowsAZeroFallbackForAnUndefinedZeroVariancePairForDisplayOnly() {
        // The matrix cell for an undefined (zero-variance) pair falls back to 0 for the heatmap's
        // display purposes — the matrix type can't hold nil — but this must NOT leak into
        // averageCorrelation, which recomputes and correctly excludes it (see the test above).
        let a: [Double] = [0.1, 0.2, 0.3]
        let flat: [Double] = [100, 100, 100]
        let m = PA.correlationMatrix([a, flat])
        #expect(m[0][1] == 0)
        #expect(m[1][0] == 0)
    }

    // Audit 2026-07-12 (ideas-card F3): the parallel defined-ness mask lets the heatmap render an
    // undefined (zero-variance) pair as "—" instead of a fabricated green "0.0 independent" cell.
    // The mask must flag exactly the pairs where correlationMatrix stored the display-only 0, and
    // leave a genuinely-measured pair (and the diagonal) defined.
    @Test func correlationDefinedMaskFlagsTheUndefinedZeroVariancePair() {
        let a: [Double] = [0.1, 0.2, 0.3, 0.15]     // real variation
        let b: [Double] = [0.3, 0.1, 0.25, 0.2]     // real variation
        let flat: [Double] = [100, 100, 100, 100]   // zero variance → undefined vs anything
        let mask = PA.correlationDefinedMask([a, b, flat])
        // Diagonal always defined (self-correlation is 1).
        #expect(mask[0][0] && mask[1][1] && mask[2][2])
        // a vs b: both vary → defined.
        #expect(mask[0][1] && mask[1][0])
        // flat vs anything: undefined → false (the cell the heatmap must render as "—").
        #expect(!mask[0][2] && !mask[2][0])
        #expect(!mask[1][2] && !mask[2][1])
        // And the mask lines up with where the matrix stored its display-only 0.
        let m = PA.correlationMatrix([a, b, flat])
        #expect(m[0][2] == 0 && !mask[0][2])   // undefined pair: matrix 0, mask false — the exact contract.
    }

    @Test func computeDoesNotTreatAFlatHoldingAsMaximallyDiversifying() {
        // A flat (zero-variance) holding paired with a real one used to make avgCorrelation()
        // silently read as 0 ("perfectly diversifying") — the worst possible mis-read, since a
        // flat/halted/illiquid name tells you NOTHING about diversification. With the fix, the
        // undefined pair is excluded, so avgCorrelation falls back to the "no defined pairs → 1"
        // (fully concentrated) convention instead of a falsely-reassuring 0.
        let flat = Array(repeating: 100.0, count: 12)
        let moving = (0..<12).map { 100.0 + Double($0 % 3) - 1 }   // some real up/down movement
        let a = PA.compute(holdings: [(1000, flat), (1000, moving)])
        #expect(a != nil)
        #expect(a?.avgCorrelation == 1)   // NOT 0 — the pair is undefined, not "uncorrelated"
    }

    @Test func antiCorrelatedHoldingsScoreWellDiversified() {
        let a: [Double] = [100, 110, 100, 110, 100, 110, 100]   // alternating
        let b: [Double] = [110, 100, 110, 100, 110, 100, 110]   // opposite phase
        let r = PA.compute(holdings: [(1000, a), (1000, b)])
        #expect(r != nil)
        #expect((r?.avgCorrelation ?? 1) < -0.9)        // strongly anti-correlated
        #expect((r?.diversificationScore ?? 0) > 70)    // genuine diversification
    }

    // cVaR95 (conditional VaR / expected shortfall — "if you lose, HOW bad?") was untested.
    // Single holding ⇒ port == dailyReturns(closes). cutoff = percentile(port,0.05);
    // cVaR95 = tail.isEmpty ? var95 : max(0, −mean(tail)·100). Hand-derived in derive_cvar.swift.
    @Test func conditionalVaRAveragesTheTailAndFallsBackToVaRWhenTailIsEmpty() {
        // NORMAL branch: 21 closes → returns [−0.10, +0.01…+0.19]. 5th-pctile cutoff = +0.01,
        // so the ONLY sub-cutoff return is the −0.10 crash ⇒ tail = [−0.10] ⇒ cVaR95 = 10.0,
        // while var95 = max(0, −0.01·100) = 0.0. cVaR95 ≠ var95 PROVES the tail-mean branch fired
        // (a fallback would make them equal).
        var normal = [100.0]
        for r in [-0.10] + (1...19).map({ Double($0) / 100 }) { normal.append(normal.last! * (1 + r)) }
        let a = PA.compute(holdings: [(1000, normal)])!
        #expect(abs(a.cVaR95 - 10.0) < 1e-6)
        #expect(abs(a.valueAtRisk95 - 0.0) < 1e-6)
        #expect(a.cVaR95 > a.valueAtRisk95)   // expected shortfall ≥ VaR when the tail bites

        // FALLBACK branch: 6 closes → 5 returns (compute needs minLen ≥ 5). The 5th-pctile idx =
        // round(4·0.05) = 0 = the minimum (−0.10 crash), so NOTHING is strictly below it ⇒ empty
        // tail ⇒ cVaR95 falls back to var95 (both = 10.0).
        let f = PA.compute(holdings: [(1000, [100, 90, 91, 92, 93, 94])])!
        #expect(abs(f.cVaR95 - 10.0) < 1e-6)
        #expect(f.cVaR95 == f.valueAtRisk95)   // empty tail ⇒ exact fallback to VaR
    }
}
