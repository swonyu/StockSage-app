import Testing
import Foundation
@testable import StockSage

// MARK: - Correlation-cluster add pre-check (pure)

struct StockSageClusterCheckTests {
    typealias CK = StockSageClusterCheck

    // A clean, linearly-related set: A is identical to the candidate (corr +1),
    // B is its negation (corr −1).
    private let cand: [Double] = [0.01, -0.02, 0.03, -0.01]
    private var identical: [Double] { cand }
    private var negated: [Double] { cand.map { -$0 } }

    @Test func flagsAHighlyCorrelatedHolding() {
        let r = CK.check(candidate: "NEW",
                         candidateReturns: cand,
                         holdings: [("A", identical), ("B", negated)])!
        #expect(r.isConcentrating)
        #expect(r.highlyCorrelated.map(\.symbol) == ["A"])           // only the +1 holding
        #expect(abs(r.highlyCorrelated.first!.correlation - 1) < 1e-9)
        #expect(r.nearest?.symbol == "A")                            // highest positive corr
        #expect(r.note.contains("doubling down on A"))
    }

    @Test func anticorrelatedHoldingIsNotConcentration() {
        let r = CK.check(candidate: "NEW", candidateReturns: cand, holdings: [("B", negated)])!
        #expect(!r.isConcentrating)
        #expect(abs(r.nearest!.correlation - (-1)) < 1e-9)
        #expect(r.note.contains("adds diversification"))
    }

    @Test func skipsTheSameSymbolAndGuardsEmpties() {
        // Candidate already held under the same ticker → skipped → no other holdings → nil.
        #expect(CK.check(candidate: "A", candidateReturns: cand, holdings: [("a", identical)]) == nil)
        #expect(CK.check(candidate: "NEW", candidateReturns: cand, holdings: []) == nil)
        #expect(CK.check(candidate: "NEW", candidateReturns: [0.01], holdings: [("A", identical)]) == nil)  // too short
    }

    // MARK: - Date-aligned variant (F14) — checkDated

    /// UTC-day-tagged returns: day `startDay + i` at `hour` UTC. checkDated buckets by UTC day
    /// number (via alignByDate), so two exchanges' differing close TIMES on the same UTC day
    /// must still align — several tests below use different hours on purpose.
    private func dated(_ rets: [Double], startDay: Int, hour: Int = 12) -> [(date: Date, ret: Double)] {
        rets.enumerated().map { i, r in
            (date: Date(timeIntervalSince1970: Double(startDay + i) * 86_400 + Double(hour) * 3_600), ret: r)
        }
    }

    @Test func datedDisjointCalendarsAreUnknownNotFabricated() {
        let cand5 = dated([0.01, -0.02, 0.03, -0.01, 0.02], startDay: 0)

        // (a) ZERO overlapping days → unknown → nil (never a fabricated coefficient).
        let disjoint = dated([0.02, -0.01, 0.02, -0.03, 0.01], startDay: 10)
        #expect(CK.checkDated(candidate: "NEW", candidateReturns: cand5, holdings: [("H", disjoint)]) == nil)

        // (b) SOME overlap but < minOverlap(5) common days (only days 3–4) → still unknown → nil.
        let thinOverlap = dated([0.02, -0.01, 0.02, -0.03, 0.01], startDay: 3)
        #expect(CK.checkDated(candidate: "NEW", candidateReturns: cand5, holdings: [("H", thinOverlap)]) == nil)

        // (c) Candidate itself shorter than minOverlap → nil even vs a perfectly aligned holding.
        let shortCand = dated([0.01, -0.02, 0.03], startDay: 0)
        let aligned3 = dated([0.02, -0.01, 0.02], startDay: 0)
        #expect(CK.checkDated(candidate: "NEW", candidateReturns: shortCand, holdings: [("H", aligned3)]) == nil)

        // (d) Zero-variance aligned holding: correlation UNDEFINED (0/0) → skipped; as the only
        //     holding the whole check is nil — never rendered as fake "adds diversification".
        let flat = dated([0.0, 0.0, 0.0, 0.0, 0.0], startDay: 0)
        #expect(CK.checkDated(candidate: "NEW", candidateReturns: cand5, holdings: [("FLAT", flat)]) == nil)
    }

    @Test func datedAlignedSeriesMatchesHandDerivedPearson() {
        // Same 5 UTC days, different close hours (21:00 vs 03:00) — must still align by day.
        let cand = dated([0.01, -0.02, 0.03, -0.01, 0.02], startDay: 0, hour: 21)
        let hold = dated([0.02, -0.01, 0.02, -0.03, 0.01], startDay: 0, hour: 3)
        guard let (r, skipped) = CK.checkDated(candidate: "NEW", candidateReturns: cand,
                                               holdings: [("H", hold)]) else {
            Issue.record("a fully aligned 5-day pair must be scorable")
            return
        }
        // Hand-derived Pearson: means 0.006 / 0.002; deviations give cov = 0.00144,
        // var_a = 0.00172, var_b = 0.00188 → r = 0.00144 / √(0.00172 × 0.00188) = 0.8007912959402325.
        #expect(skipped == 0)
        #expect(r.nearest?.symbol == "H")
        #expect(abs((r.nearest?.correlation ?? 0) - 0.8007912959402325) < 1e-9)
        #expect(r.isConcentrating, "0.80079 ≥ 0.8 default threshold → flagged as concentration")
    }

    @Test func datedCrossCalendarOverlapUsesOnlyTheIntersection() {
        // Candidate trades UTC days 0..6; the holding trades days 2..8 (a different calendar).
        // On the 5 COMMON days (2..6) the holding is EXACTLY 2× the candidate
        // (cand [0.01,-0.02,0.03,-0.01,0.02] vs hold [0.02,-0.04,0.06,-0.02,0.04]) → a perfect
        // linear relation → Pearson = +1 by hand. Positional pairing of the raw 7-element arrays
        // (what the old spark-based path did) gives ≈ 0.4250429568 instead — this pins that the
        // coefficient comes from the date INTERSECTION, not from array positions.
        let cand = dated([0.05, -0.04, 0.01, -0.02, 0.03, -0.01, 0.02], startDay: 0)
        let hold = dated([0.02, -0.04, 0.06, -0.02, 0.04, 0.05, -0.03], startDay: 2)
        guard let (r, skipped) = CK.checkDated(candidate: "NEW", candidateReturns: cand,
                                               holdings: [("H", hold)]) else {
            Issue.record("a 5-common-day cross-calendar pair must be scorable")
            return
        }
        #expect(skipped == 0)
        #expect(abs((r.nearest?.correlation ?? 0) - 1.0) < 1e-9,
                "intersection days 2..6: hold = 2×cand exactly → r = +1")
        #expect(r.isConcentrating)
        #expect(r.note.contains("doubling down on H"))
        // Sanity: the positional coefficient the OLD path would have produced is far from +1.
        let positional = StockSagePortfolioAnalytics.correlation(cand.map(\.ret), hold.map(\.ret)) ?? 0
        #expect(abs(positional - 1.0) > 0.5,
                "positional pairing (≈0.425) must NOT be what checkDated reports")
    }

    @Test func datedMixedCoverageScoresTheAlignedHoldingAndTalliesTheSkipped() {
        let cand = dated([0.01, -0.02, 0.03, -0.01, 0.02], startDay: 0)
        let aligned = dated([0.02, -0.01, 0.02, -0.03, 0.01], startDay: 0)
        let disjoint = dated([0.02, -0.01, 0.02, -0.03, 0.01], startDay: 20)
        guard let (r, skipped) = CK.checkDated(candidate: "NEW", candidateReturns: cand,
                                               holdings: [("GOOD", aligned), ("GONE", disjoint)]) else {
            Issue.record("one scorable holding must still yield a check")
            return
        }
        #expect(skipped == 1, "the no-overlap holding is tallied as skipped (unknown), never scored as 0")
        #expect(r.nearest?.symbol == "GOOD")
        #expect(r.highlyCorrelated.map(\.symbol) == ["GOOD"])   // 0.80079 ≥ 0.8

        // Same-symbol skip parity with check(): candidate already held (case-insensitive) →
        // excluded → nothing scorable → nil.
        #expect(CK.checkDated(candidate: "GOOD", candidateReturns: cand, holdings: [("good", aligned)]) == nil)
    }

    @Test func excludesAZeroVarianceHoldingRatherThanTreatingItAsDiversifying() {
        // A flat (zero-variance) holding's correlation with the candidate is UNDEFINED (0/0), not
        // a genuine "uncorrelated" 0 — it must be excluded from nearest/highlyCorrelated, not let
        // through as a fake diversifying match.
        let flat: [Double] = [0.0, 0.0, 0.0, 0.0]
        let r = CK.check(candidate: "NEW", candidateReturns: cand,
                         holdings: [("A", identical), ("FLAT", flat)])!
        #expect(r.highlyCorrelated.map(\.symbol) == ["A"])   // FLAT never appears
        #expect(r.nearest?.symbol == "A")                    // FLAT never becomes "nearest"

        // When the ONLY holding is flat, there's nothing usable to compare against — nearest is
        // nil and nothing is flagged, rather than a flat holding masquerading as "diversifying".
        let onlyFlat = CK.check(candidate: "NEW", candidateReturns: cand, holdings: [("FLAT", flat)])!
        #expect(onlyFlat.nearest == nil)
        #expect(onlyFlat.highlyCorrelated.isEmpty)
        #expect(!onlyFlat.isConcentrating)
    }
}
