import Testing
import Foundation
@testable import StockSage

// MARK: - Sparkline series helpers (pure)

struct SparkSeriesTests {

    @Test func normalizeMapsToUnitRange() {
        #expect(SparkSeries.normalize([1, 2, 3]) == [0, 0.5, 1])
        #expect(SparkSeries.normalize([10, 0]) == [1, 0])
    }

    @Test func normalizeFlatSeriesIsMidline() {
        #expect(SparkSeries.normalize([5, 5, 5]) == [0.5, 0.5, 0.5])
        #expect(SparkSeries.normalize([]).isEmpty)
    }

    @Test func downsampleKeepsEndsAndCount() {
        let s = SparkSeries.downsample((1...100).map(Double.init), maxPoints: 10)
        #expect(s.count == 10)
        #expect(s.first == 1)
        #expect(s.last == 100)
    }

    @Test func downsampleLeavesShortSeriesUntouched() {
        let short = [1.0, 2.0, 3.0]
        #expect(SparkSeries.downsample(short, maxPoints: 32) == short)
    }

    // MARK: - domain/fraction (OSS-borrow B2: trade-plan overlay y-domain mapping)
    // Hand-derived in /tmp/derive_b2.py — never from calling domain()/fraction() themselves.

    @Test func domainExtendsToOutOfRangeExtras() {
        // series [10,12,11,13] extended with stop=8, target=15 -> domain widens to [8,15],
        // NOT clamped to the series' own [10,13].
        let d = SparkSeries.domain([10, 12, 11, 13], extending: [8, 15])
        #expect(d?.lo == 8)
        #expect(d?.hi == 15)
        #expect(SparkSeries.fraction(8, in: d!) == 0.0)
        #expect(SparkSeries.fraction(15, in: d!) == 1.0)
        #expect(SparkSeries.fraction(11.5, in: d!) == 0.5)
    }

    @Test func domainUnchangedWhenExtrasAlreadyInRange() {
        // extra=15 sits inside [10,20] -> domain stays the series' own range.
        let d = SparkSeries.domain([10, 20], extending: [15])
        #expect(d?.lo == 10)
        #expect(d?.hi == 20)
    }

    @Test func domainNilForDegenerateSeries() {
        // Flat series, no extras -> no meaningful range -> nil (never a fabricated 0.5 line).
        #expect(SparkSeries.domain([5, 5, 5]) == nil)
    }

    @Test func domainFromExtrasAloneWhenSeriesEmpty() {
        let d = SparkSeries.domain([], extending: [3, 9])
        #expect(d?.lo == 3)
        #expect(d?.hi == 9)
    }

    @Test func domainNilWhenSeriesEmptyAndSingleExtra() {
        // One point can't form a range.
        #expect(SparkSeries.domain([], extending: [7]) == nil)
    }

    // MARK: - Registration (fix-round: Shape and overlay must share ONE y-mapping)
    // Hand-derived in /tmp/derive_b2_registration.py — never from calling normalize()/fraction()
    // themselves. Fixture: series [95,100,105,110], stop=99, target=132 -> domain (95,132).
    // idea.price ≡ spark.last (110) by invariant (downsample preserves the final element), so
    // an honest last-bar marker must sit exactly on the Shape's own last drawn point.

    @Test func normalizeInDomainMatchesFractionAtEveryPoint() {
        let series = [95.0, 100.0, 105.0, 110.0]
        let stop = 99.0, target = 132.0
        let domain = SparkSeries.domain(series, extending: [stop, target])!
        #expect(domain.lo == 95)
        #expect(domain.hi == 132)

        let normalized = SparkSeries.normalize(series, in: domain)
        let derived = 0.40540540540540543   // (110 - 95) / (132 - 95), hand-derived
        #expect(abs(normalized.last! - derived) < 1e-9)
        #expect(abs(SparkSeries.fraction(110, in: domain) - derived) < 1e-9)

        // The registration invariant itself: the Shape's own normalized last-point fraction
        // and the overlay's fraction(price, in: domain) must be the SAME value, because
        // idea.price ≡ spark.last — this is what makes the last-bar marker land exactly on
        // the drawn last point instead of floating at a different y (review blocker 2).
        #expect(normalized.last! == SparkSeries.fraction(series.last!, in: domain))
    }

    // MARK: - extreme (OSS-borrow B3: "At recent high/low" chip)
    // Hand-derived in /tmp/derive_b3.py — never from calling extreme() itself.

    @Test func extremeStraddleEndsExactlyAtMaxIsAtHigh() {
        // Straddle case 1: series ends exactly at its running max -> atHigh.
        #expect(SparkSeries.extreme([1, 5, 3, 7, 7]) == .atHigh)
    }

    @Test func extremeStraddleOneTickBelowMaxIsNeither() {
        // Straddle case 2: last value one tick below the max -> neither (the boundary that
        // proves this isn't epsilon-fuzzed — exact == only).
        #expect(SparkSeries.extreme([1, 5, 3, 7, 6.999]) == .neither)
    }

    @Test func extremeFlatSeriesIsNeither() {
        // Degenerate-series guard (Ghostfolio's own rule): a flat series must NEVER flag,
        // and never both atHigh and atLow.
        #expect(SparkSeries.extreme([4, 4, 4, 4]) == .neither)
    }

    @Test func extremeEndsAtMinIsAtLow() {
        #expect(SparkSeries.extreme([9, 2, 5, 2]) == .atLow)
    }

    @Test func extremeTooShortIsNeither() {
        #expect(SparkSeries.extreme([5]) == .neither)
        #expect(SparkSeries.extreme([]) == .neither)
    }

    @Test func extremeMiddleValueIsNeither() {
        #expect(SparkSeries.extreme([1, 5, 3]) == .neither)
    }

    @Test func extremeTwoPointSeriesBothDirections() {
        #expect(SparkSeries.extreme([1, 2]) == .atHigh)
        #expect(SparkSeries.extreme([2, 1]) == .atLow)
    }

    // MARK: - clampedLabelY / deconflictedLabelYs (fix round: bottom-edge fold-back bug)
    // Hand-derived in /tmp/derive_b2_fix.py — never from calling these functions themselves.
    // Bug: the old one-directional (always-push-down-then-clamp) de-collision folded back onto
    // itself when both labels clamped to the SAME bottom edge — min(57.5+13, 57.5) == 57.5, i.e.
    // zero separation, full overlap. Direction-aware fix pushes UP instead when there's no room
    // below. h=64, labelHeight=13, half=6.5 throughout (matches the review's repro geometry).

    @Test func clampedLabelYBounds() {
        #expect(SparkSeries.clampedLabelY(0, height: 64, labelHeight: 13) == 6.5)
        #expect(SparkSeries.clampedLabelY(64, height: 64, labelHeight: 13) == 57.5)
        #expect(SparkSeries.clampedLabelY(32, height: 64, labelHeight: 13) == 32.0)
    }

    @Test func deconflictBottomEdgeBothClampToSamePoint() {
        // Both labels clamp to the exact same bottom-edge value (57.5, 57.5) — the fold-back bug.
        let a = SparkSeries.clampedLabelY(57.5, height: 64, labelHeight: 13)
        let b = SparkSeries.clampedLabelY(57.5, height: 64, labelHeight: 13)
        let (finalA, finalB) = SparkSeries.deconflictedLabelYs(a, b, labelHeight: 13, height: 64)
        #expect(finalA == 44.5)
        #expect(finalB == 57.5)
        #expect(abs(finalA - finalB) == 13)
        #expect(finalA >= 6.5 && finalA <= 57.5)
        #expect(finalB >= 6.5 && finalB <= 57.5)
    }

    @Test func deconflictBottomEdgeReviewRepro() {
        // The review's literal repro pair: raw y's 64.0/62.6 both clamp to the bottom edge.
        let a = SparkSeries.clampedLabelY(64.0, height: 64, labelHeight: 13)
        let b = SparkSeries.clampedLabelY(62.6, height: 64, labelHeight: 13)
        let (finalA, finalB) = SparkSeries.deconflictedLabelYs(a, b, labelHeight: 13, height: 64)
        #expect(finalA == 44.5)
        #expect(finalB == 57.5)
        #expect(abs(finalA - finalB) == 13)
        #expect(finalA >= 6.5 && finalA <= 57.5)
        #expect(finalB >= 6.5 && finalB <= 57.5)
    }

    @Test func deconflictTopEdgeMirror() {
        // Mirror case: both labels clamp to the top edge. Top edge always had room below, so
        // this path already worked pre-fix — kept as a regression guard.
        let a = SparkSeries.clampedLabelY(0.0, height: 64, labelHeight: 13)
        let b = SparkSeries.clampedLabelY(1.4, height: 64, labelHeight: 13)
        let (finalA, finalB) = SparkSeries.deconflictedLabelYs(a, b, labelHeight: 13, height: 64)
        #expect(finalA == 6.5)
        #expect(finalB == 19.5)
        #expect(abs(finalA - finalB) == 13)
        #expect(finalA >= 6.5 && finalA <= 57.5)
        #expect(finalB >= 6.5 && finalB <= 57.5)
    }

    @Test func deconflictMidChartNonCollidingPairUnchanged() {
        let a = SparkSeries.clampedLabelY(20.0, height: 64, labelHeight: 13)
        let b = SparkSeries.clampedLabelY(40.0, height: 64, labelHeight: 13)
        let (finalA, finalB) = SparkSeries.deconflictedLabelYs(a, b, labelHeight: 13, height: 64)
        #expect(finalA == 20.0)
        #expect(finalB == 40.0)
    }

    // Cross-checks against the shipped QA fixtures (StockSageStore.qaFixtureHistories):
    // NVDA's up250 = 50 + 0.0153·i² is strictly increasing -> ends at its max.
    // 1120.SR's down250 = 200 − 0.602·i is strictly decreasing -> ends at its min.
    @Test func extremeMatchesNVDAUp250Fixture() {
        let up250 = (0..<250).map { 50.0 + 0.0153 * pow(Double($0), 2) }
        #expect(SparkSeries.extreme(up250) == .atHigh)
    }

    @Test func extremeMatches1120SRDowntrendFixture() {
        let down250 = (0..<250).map { 200.0 - Double($0) * 0.602 }
        #expect(SparkSeries.extreme(down250) == .atLow)
    }
}
