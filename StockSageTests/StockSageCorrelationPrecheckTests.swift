import Testing
import Foundation
@testable import StockSage

// MARK: - Portfolio-correlation pre-check (pure)
//
// REWRITTEN 2026-09-11 onto `assessDated`. The positional `assess` these tests used to call has
// been DELETED, not merely deprecated: it paired the candidate and each holding by index from the
// end of each series, so a Tadawul (Sun–Thu) and a US (Mon–Fri) holding were correlated on
// mismatched calendar days. `theSamePairReadsConcentratingPositionallyAndDiversifyingByDate`
// below constructs that exact case and proves the two answers differ, so the defect is pinned by
// measurement rather than asserted in a comment.
//
// CONTRACT CHANGE, deliberate: "holdings exist but none could be scored" was previously reported
// as `.noHoldings` — a false statement about the owner's book. It is now `.notComparable`, and
// the two tests that used to pin `.noHoldings` for that case now pin the new verdict.

struct StockSageCorrelationPrecheckTests {

    typealias PC = StockSageCorrelationPrecheck

    /// Day `d` is `d` whole days after the epoch, which is exactly how `alignByDate` buckets
    /// (`floor(t / 86_400)`), so these fixtures line up on the same keys the shipped code uses.
    private func dated(_ rets: [Double], startDay: Int = 0) -> [(date: Date, ret: Double)] {
        rets.enumerated().map { (Date(timeIntervalSince1970: Double(startDay + $0.offset) * 86_400), $0.element) }
    }

    private let base: [Double] = [0.01, -0.02, 0.03, -0.01, 0.02, 0.00, 0.015]

    @Test func emptyHoldingsReadsNoHoldings() {
        let r = PC.assessDated(candidate: dated([0.1, 0.2, 0.3, 0.4, 0.5]), holdings: [])
        #expect(r.verdict == .noHoldings)
        #expect(r.comparedCount == 0)
        #expect(r.skippedCount == 0)
    }

    @Test func perfectlyCorrelatedHoldingsConcentrate() {
        let r = PC.assessDated(candidate: dated(base), holdings: [("TWIN", dated(base))])   // corr 1
        #expect(r.verdict == .concentrating)
        #expect(r.isWarning)
        #expect(abs(r.avgCorrelation - 1.0) < 1e-9)
        #expect(r.mostCorrelatedSymbol == "TWIN")
        #expect(r.skippedCount == 0)
    }

    @Test func antiCorrelatedHoldingDiversifies() {
        let r = PC.assessDated(candidate: dated(base), holdings: [("HEDGE", dated(base.map { -$0 }))])
        #expect(r.verdict == .diversifying)
        #expect(!r.isWarning)
    }

    // MARK: The defect this file exists to pin

    // Two series with IDENTICAL shapes on DIFFERENT calendar windows. Paired by position they are
    // a perfect match; paired by date, their five shared days are perfectly opposed. The positional
    // answer is computed here from the same public correlation function the deleted `assess` used,
    // so this test proves the divergence instead of describing it.
    @Test func theSamePairReadsConcentratingPositionallyAndDiversifyingByDate() throws {
        let alt = (0..<10).map { 0.01 * ($0 % 2 == 0 ? 1.0 : -1.0) }
        let candidate = dated(alt, startDay: 0)    // days 0…9
        let holding = dated(alt, startDay: 5)      // days 5…14, same shape, shifted window

        // What the positional pairing saw: suffix-aligned, the two arrays are element-identical.
        let positional = try #require(StockSagePortfolioAnalytics.correlation(
            candidate.map(\.ret), holding.map(\.ret)))
        #expect(positional >= PC.concentratingAt,
                "premise: paired by position this reads \(positional) — a concentration verdict")

        // What is actually true on the days both series trade (days 5–9): perfectly opposed.
        let r = PC.assessDated(candidate: candidate, holdings: [("SHIFTED", holding)])
        #expect(r.comparedCount == 1)
        #expect(abs(r.avgCorrelation + 1.0) < 1e-9)
        #expect(r.verdict == .diversifying,
                "date-aligned, the five shared days are anti-correlated; the positional answer was backwards")
    }

    // MARK: Unknown is a verdict of its own

    @Test func tooLittleOverlapIsNotComparableRatherThanNoHoldings() {
        // 3 shared days (< minOverlap 5). The owner HAS a holding — saying "no holdings yet"
        // would be a false statement about their book, so the verdict names the real problem.
        let r = PC.assessDated(candidate: dated([0.1, 0.2, 0.3]), holdings: [("X", dated([0.1, 0.2, 0.3]))])
        #expect(r.verdict == .notComparable)
        #expect(r.comparedCount == 0)
        #expect(r.skippedCount == 1)
        #expect(r.note.contains("Couldn't compare"))
        #expect(!r.note.lowercased().contains("no current holdings"))
    }

    // Series that never overlap at all are the cross-market case in its extreme form.
    @Test func disjointCalendarsAreNotComparable() {
        let r = PC.assessDated(candidate: dated(base, startDay: 0),
                               holdings: [("FAR", dated(base, startDay: 400))])
        #expect(r.verdict == .notComparable)
        #expect(r.skippedCount == 1)
    }

    @Test func excludesAZeroVarianceHoldingFromTheAverageRatherThanCountingItAsUncorrelated() {
        // A flat (zero-variance) holding's correlation with the candidate is UNDEFINED (0/0), not
        // a real "uncorrelated" 0 — it must be excluded from avgCorrelation/comparedCount, never
        // silently drag the average toward "diversifying".
        let flat = Array(repeating: 0.0, count: base.count)
        let r = PC.assessDated(candidate: dated(base),
                               holdings: [("TWIN", dated(base)), ("FLAT", dated(flat))])
        #expect(r.comparedCount == 1)               // FLAT excluded, not counted
        #expect(abs(r.avgCorrelation - 1.0) < 1e-9) // avg over the ONE defined pair only
        #expect(r.mostCorrelatedSymbol == "TWIN")
        #expect(r.skippedCount == 1)                // …but COUNTED as unchecked, not forgotten

        // When the flat holding is the ONLY one, there is nothing usable to compare against —
        // and the owner still has a holding, so this is `.notComparable`, not `.noHoldings`.
        let onlyFlat = PC.assessDated(candidate: dated(base), holdings: [("FLAT", dated(flat))])
        #expect(onlyFlat.verdict == .notComparable)
        #expect(onlyFlat.comparedCount == 0)
    }

    // A verdict computed over a SUBSET of the book must not phrase itself as covering all of it.
    @Test func thePartialCoverageCaveatNamesWhatWasNotChecked() {
        let flat = Array(repeating: 0.0, count: base.count)
        let r = PC.assessDated(candidate: dated(base),
                               holdings: [("TWIN", dated(base)), ("FLAT", dated(flat))])
        #expect(r.note.contains("1 more couldn't be compared"))
        #expect(r.note.contains("doesn't cover your whole book"))

        // Full coverage says nothing extra — the caveat must not become permanent decoration.
        let full = PC.assessDated(candidate: dated(base), holdings: [("TWIN", dated(base))])
        #expect(!full.note.contains("couldn't be compared"))
    }

    @Test func averagesAcrossHoldingsAndNamesTheMostCorrelated() {
        // One identical (corr ~1), one anti (corr ~−1) → avg ~0 → diversifying band.
        let r = PC.assessDated(candidate: dated(base),
                               holdings: [("SAME", dated(base)), ("OPP", dated(base.map { -$0 }))])
        #expect(r.comparedCount == 2)
        #expect(abs(r.avgCorrelation) < 1e-6)
        #expect(r.mostCorrelatedSymbol == "SAME")   // the positively-correlated one
        #expect(r.skippedCount == 0)
    }
}
