import Testing
import Foundation
@testable import StockSage

// "You already own this bet" — proposed idea vs the book already held.
// Series below are hand-built so each correlation is obvious by inspection.
//
// REWRITTEN 2026-09-11 onto `overlapsDated`. The undated `overlaps` these tests used to call has
// been DELETED. It paired series by `suffix(n)` — index from the end — which compares different
// calendar days for the Tadawul/US pair this row exists to catch, and its only caller fed it
// `idea.spark`, a down-sampled sparkline with no dates at all. The result was rendered as a hard
// warning quoting a specific percentage. `aShiftedCalendarNoLongerFabricatesAnOverlap` builds that
// exact case and measures both answers.

@Suite("Holding overlap")
struct StockSageHoldingOverlapTests {

    typealias H = StockSageHoldingOverlap

    /// 24 observations (past minObservations of 20) of a simple repeating pattern.
    private func series(_ pattern: [Double]) -> [Double] {
        Array(Array(repeating: pattern, count: 24 / pattern.count + 1).joined().prefix(24))
    }

    /// Day `d` is `d` whole days after the epoch — the same bucket `alignByDate` keys on.
    private func dated(_ rets: [Double], startDay: Int = 0) -> [(date: Date, ret: Double)] {
        rets.enumerated().map { (Date(timeIntervalSince1970: Double(startDay + $0.offset) * 86_400), $0.element) }
    }

    @Test("a perfectly co-moving holding is flagged")
    func identicalMovementFlagged() throws {
        let a = series([0.01, -0.02, 0.03, -0.01])
        let r = try #require(H.overlapsDated(candidate: "NEW", candidateReturns: dated(a),
                                             held: [("HELD", dated(a))]))          // r = 1.0 exactly
        #expect(r.overlaps.count == 1)
        #expect(r.overlaps.first?.heldSymbol == "HELD")
        #expect(abs((r.overlaps.first?.correlation ?? 0) - 1.0) < 1e-9)
        #expect(r.skipped == 0)
    }

    @Test("an uncorrelated holding is NOT flagged")
    func uncorrelatedNotFlagged() throws {
        // Orthogonal by construction: sum of products is zero.
        let a = series([1, -1, 1, -1])
        let b = series([1, 1, -1, -1])
        let r = try #require(H.overlapsDated(candidate: "NEW", candidateReturns: dated(a),
                                             held: [("HELD", dated(b))]))
        #expect(r.overlaps.isEmpty)
        // Scored and cleared is a real answer, not a gap — it must NOT inflate `skipped`, or the
        // warning would claim coverage problems that do not exist.
        #expect(r.skipped == 0)
    }

    @Test("the candidate never flags itself")
    func selfIsSkipped() {
        let a = series([0.01, -0.02, 0.03, -0.01])
        // Nothing left to compare once the candidate is excluded ⇒ nil, not an empty verdict.
        #expect(H.overlapsDated(candidate: "AAPL", candidateReturns: dated(a), held: [("aapl", dated(a))]) == nil)
    }

    @Test("thin history is skipped rather than correlated on noise")
    func thinHistorySkipped() {
        let short = [0.01, -0.01, 0.02]                       // 3 points, far below the floor
        let long = series([0.01, -0.02, 0.03, -0.01])
        #expect(H.overlapsDated(candidate: "NEW", candidateReturns: dated(short),
                                held: [("HELD", dated(long))]) == nil)
        #expect(H.overlapsDated(candidate: "NEW", candidateReturns: dated(long),
                                held: [("HELD", dated(short))]) == nil)
    }

    // MARK: The defect this file exists to pin

    // Same shape, different calendar window — the shape of a Tadawul/US pair, or of any two
    // symbols whose histories start on different dates. Paired by position the two are identical
    // and would have produced a hard "you already hold HELD, which has moved 100% with this name".
    // On shared days they have only 5 in common, far under the 20-observation floor, so the honest
    // answer is that nothing is scorable — and the row renders nothing.
    @Test("a shifted calendar no longer fabricates an overlap")
    func aShiftedCalendarNoLongerFabricatesAnOverlap() throws {
        let a = series([0.01, -0.02, 0.03, -0.01])            // 24 observations
        let candidate = dated(a, startDay: 0)                 // days 0…23
        let holding = dated(a, startDay: 19)                  // days 19…42 — 5 shared days

        // Premise: what the deleted positional pairing measured on these very inputs.
        let positional = try #require(StockSagePortfolioAnalytics.correlation(a, a))
        #expect(positional >= H.threshold,
                "premise: paired by position this is \(positional) — above the \(H.threshold) warning threshold")

        #expect(H.overlapsDated(candidate: "NEW", candidateReturns: candidate,
                                held: [("HELD", holding)]) == nil,
                "5 shared trading days cannot support a correlation claim; the row must render nothing")
    }

    // An unscorable holding alongside a scorable one is a real finding PLUS a real gap. Both have
    // to survive to the sentence: the gap can only mean there is more concentration, not less.
    @Test("unscorable holdings are tallied, not dropped")
    func unscorableHoldingsAreTallied() throws {
        let a = series([0.01, -0.02, 0.03, -0.01])
        let r = try #require(H.overlapsDated(candidate: "NEW", candidateReturns: dated(a),
                                             held: [("TWIN", dated(a)),
                                                    ("UNFETCHED", [])]))   // empty ⇒ unknown
        #expect(r.overlaps.count == 1)
        #expect(r.skipped == 1)
        let text = try #require(H.warning(for: r.overlaps, skipped: r.skipped))
        #expect(text.contains("1 other holding could not be checked"))
    }

    // The mirror of the test above: date alignment must not become a blanket refusal. Histories
    // routinely start on different dates — a holding bought years ago against a recent listing —
    // and as long as they share enough days the pair is scorable and must still be scored.
    @Test("different history lengths still score when enough days are shared")
    func differentHistoryLengthsStillScore() throws {
        let a = series([0.01, -0.02, 0.03, -0.01])            // 24 observations, days 0…23
        let longer = Array(Array(repeating: [0.01, -0.02, 0.03, -0.01], count: 12).joined())
        let r = try #require(H.overlapsDated(candidate: "NEW", candidateReturns: dated(a, startDay: 0),
                                             held: [("HELD", dated(longer, startDay: 0))]))   // 48 days
        #expect(r.skipped == 0, "24 shared days is well past the 20-observation floor")
        #expect(r.overlaps.count == 1)
        #expect(abs((r.overlaps.first?.correlation ?? 0) - 1.0) < 1e-9)
    }

    @Test("cross-market detection keys on the .SR suffix")
    func crossMarketDetection() {
        #expect(H.isCrossMarket("AAPL", "2222.SR"))          // US vs Tadawul
        #expect(H.isCrossMarket("2222.SR", "NVDA"))
        #expect(!H.isCrossMarket("AAPL", "NVDA"))            // both US
        #expect(!H.isCrossMarket("2222.SR", "1120.SR"))      // both Saudi
    }

    @Test("results are ordered strongest-overlap first")
    func orderedByCorrelation() throws {
        let a = series([0.02, -0.02, 0.02, -0.02])
        let weaker = a.enumerated().map { $0.offset % 5 == 0 ? -$0.element : $0.element }
        let r = try #require(H.overlapsDated(candidate: "NEW", candidateReturns: dated(a),
                                             held: [("EXACT", dated(a)), ("WEAKER", dated(weaker))]))
        #expect(r.overlaps.first?.heldSymbol == "EXACT")
        if r.overlaps.count > 1 { #expect(r.overlaps[0].correlation >= r.overlaps[1].correlation) }
    }

    @Test("the warning names the holding, the number, and why it matters")
    func warningIsSpecific() {
        let w = H.warning(for: [H.Overlap(heldSymbol: "2222.SR", correlation: 0.91, crossMarket: true)])
        let text = try! #require(w)
        #expect(text.contains("2222.SR"))
        #expect(text.contains("91%"))
        #expect(text.lowercased().contains("does not diversify"))
        // Full coverage adds no caveat — it must not become permanent decoration.
        #expect(!text.contains("could not be checked"))
        // Same-market overlap omits the cross-market sentence.
        let same = H.warning(for: [H.Overlap(heldSymbol: "NVDA", correlation: 0.88, crossMarket: false)])
        #expect(!(same ?? "").lowercased().contains("does not diversify"))
        // Nothing to say when there is no overlap.
        #expect(H.warning(for: []) == nil)
    }
}
