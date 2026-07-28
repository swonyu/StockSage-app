import Testing
import Foundation
@testable import StockSage

// "You already own this bet" — proposed idea vs the book already held.
// Series below are hand-built so each correlation is obvious by inspection.

@Suite("Holding overlap")
struct StockSageHoldingOverlapTests {

    typealias H = StockSageHoldingOverlap

    /// 24 observations (past minObservations) of a simple repeating pattern.
    private func series(_ pattern: [Double]) -> [Double] {
        Array(Array(repeating: pattern, count: 24 / pattern.count + 1).joined().prefix(24))
    }

    @Test("a perfectly co-moving holding is flagged")
    func identicalMovementFlagged() {
        let a = series([0.01, -0.02, 0.03, -0.01])
        let overlaps = H.overlaps(candidate: "NEW", candidateReturns: a,
                                  heldReturns: ["HELD": a])          // r = 1.0 exactly
        #expect(overlaps.count == 1)
        #expect(overlaps.first?.heldSymbol == "HELD")
        #expect(abs((overlaps.first?.correlation ?? 0) - 1.0) < 1e-9)
    }

    @Test("an uncorrelated holding is NOT flagged")
    func uncorrelatedNotFlagged() {
        // Orthogonal by construction: sum of products is zero.
        let a = series([1, -1, 1, -1])
        let b = series([1, 1, -1, -1])
        #expect(H.overlaps(candidate: "NEW", candidateReturns: a, heldReturns: ["HELD": b]).isEmpty)
    }

    @Test("the candidate never flags itself")
    func selfIsSkipped() {
        let a = series([0.01, -0.02, 0.03, -0.01])
        #expect(H.overlaps(candidate: "AAPL", candidateReturns: a, heldReturns: ["aapl": a]).isEmpty)
    }

    @Test("thin history is skipped rather than correlated on noise")
    func thinHistorySkipped() {
        let short = [0.01, -0.01, 0.02]                       // 3 points, far below the floor
        let long = series([0.01, -0.02, 0.03, -0.01])
        #expect(H.overlaps(candidate: "NEW", candidateReturns: short, heldReturns: ["HELD": long]).isEmpty)
        #expect(H.overlaps(candidate: "NEW", candidateReturns: long, heldReturns: ["HELD": short]).isEmpty)
    }

    @Test("cross-market detection keys on the .SR suffix")
    func crossMarketDetection() {
        #expect(H.isCrossMarket("AAPL", "2222.SR"))          // US vs Tadawul
        #expect(H.isCrossMarket("2222.SR", "NVDA"))
        #expect(!H.isCrossMarket("AAPL", "NVDA"))            // both US
        #expect(!H.isCrossMarket("2222.SR", "1120.SR"))      // both Saudi
    }

    @Test("results are ordered strongest-overlap first")
    func orderedByCorrelation() {
        let a = series([0.02, -0.02, 0.02, -0.02])
        let exact = a                                          // r = 1
        let weaker = a.enumerated().map { $0.offset % 5 == 0 ? -$0.element : $0.element }
        let out = H.overlaps(candidate: "NEW", candidateReturns: a,
                             heldReturns: ["EXACT": exact, "WEAKER": weaker])
        #expect(out.first?.heldSymbol == "EXACT")
        if out.count > 1 { #expect(out[0].correlation >= out[1].correlation) }
    }

    @Test("the warning names the holding, the number, and why it matters")
    func warningIsSpecific() {
        let w = H.warning(for: [H.Overlap(heldSymbol: "2222.SR", correlation: 0.91, crossMarket: true)])
        let text = try! #require(w)
        #expect(text.contains("2222.SR"))
        #expect(text.contains("91%"))
        #expect(text.lowercased().contains("does not diversify"))
        // Same-market overlap omits the cross-market sentence.
        let same = H.warning(for: [H.Overlap(heldSymbol: "NVDA", correlation: 0.88, crossMarket: false)])
        #expect(!(same ?? "").lowercased().contains("does not diversify"))
        // Nothing to say when there is no overlap.
        #expect(H.warning(for: []) == nil)
    }
}
