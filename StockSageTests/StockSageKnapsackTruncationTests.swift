import Testing
import Foundation
@testable import StockSage

// BATCH 5.2 (2026-09-12) — the knapsack strategy truncated but reported a full plan.
//
// `.greedyKnapsack` (the shipped default on the Markets card) fits the heat cap by DROPPING the
// slowest-velocity names entirely, then the allocation reported `fundableCandidateCount =
// fundable.count` — read AFTER the truncation. So a 12-idea board that funded 5 said five names
// qualified, and the seven that were cut were never mentioned anywhere: not in the header, not in
// the caveat, not in the clipboard export. The owner had no way to learn the plan was a slice.
//
// Contract change, deliberate: `fundableCandidateCount` is now the PRE-truncation qualified
// population in BOTH strategies, so `fundableCandidateCount - truncatedForHeat.count` is what
// actually reached the sizer. Every existing pin is uniform-mode, where truncatedForHeat is empty
// and the two definitions coincide — verified by the suite staying green.
struct StockSageKnapsackTruncationTests {

    private typealias Alloc = StockSageCapitalAllocator

    /// Twelve equally attractive names; each wants a large half-Kelly slice, so a small cap can
    /// only fit a few and the rest are cut.
    private func board(_ n: Int) -> [StockSageIdea] {
        (0..<n).map { i in
            StockSageIdea(symbol: "SYM\(i)", market: "TEST", price: 100,
                          advice: TradeAdvice(action: .buy, conviction: 0.5, regime: .bullTrend,
                                              rationale: [], stopPrice: 90, targetPrice: 130,
                                              suggestedWeight: 0, caveat: "x"),
                          spark: [])
        }
    }

    @Test func theKnapsackNamesWhatItDidNotFund() {
        let ideas = board(12)
        let a = Alloc.allocate(ideas: ideas, account: 100_000, maxHeat: 0.30,
                               strategy: .greedyKnapsack)
        #expect(a.fundableCandidateCount == 12, "the PRE-truncation qualified population")
        #expect(!a.truncatedForHeat.isEmpty, "premise: this cap really does truncate this board")
        #expect(a.fundableCandidateCount - a.truncatedForHeat.count == a.positions.count,
                "qualified minus cut must equal what was actually sized")

        // Disjoint by construction — a funded name must never also be reported as dropped.
        let funded = Set(a.positions.map(\.symbol))
        #expect(funded.intersection(Set(a.truncatedForHeat)).isEmpty)

        // And the owner is told, in the caveat that also feeds the clipboard export.
        #expect(a.caveat.contains("Heat cap reached"))
        #expect(a.caveat.contains("were NOT funded"))
        #expect(a.caveat.contains("not the whole board"))
        for symbol in a.truncatedForHeat { #expect(a.caveat.contains(symbol)) }
    }

    // The other half of the defect: `scaleApplied` stays 1 in knapsack mode because it drops
    // rather than scales, so the header chip was indistinguishable from an unconstrained plan.
    @Test func truncationIsVisibleEvenThoughNothingWasScaled() {
        let a = Alloc.allocate(ideas: board(12), account: 100_000, maxHeat: 0.30,
                               strategy: .greedyKnapsack)
        #expect(abs(a.scaleApplied - 1.0) < 1e-9, "knapsack truncates instead of scaling")
        #expect(!a.truncatedForHeat.isEmpty, "…so THIS is the only signal the plan was cut")
    }

    // Uniform mode shrinks everyone instead of dropping anyone — it must report nothing cut, or
    // the new chip would fire on a plan that funded the whole board.
    @Test func uniformScaleDropsNobodyAndReportsNobody() {
        let a = Alloc.allocate(ideas: board(12), account: 100_000, maxHeat: 0.30,
                               strategy: .uniformScale)
        #expect(a.truncatedForHeat.isEmpty)
        #expect(a.scaleApplied < 1, "premise: this cap really does bind in uniform mode too")
        #expect(!a.caveat.contains("Heat cap reached"))
        #expect(a.fundableCandidateCount == 12)
    }

    // A plan that fits under the cap must report nothing cut in either mode.
    @Test func anUnconstrainedPlanReportsNothingCut() {
        for strategy in [Alloc.AllocationStrategy.uniformScale, .greedyKnapsack] {
            let a = Alloc.allocate(ideas: board(2), account: 100_000, maxHeat: 0.90, strategy: strategy)
            #expect(a.truncatedForHeat.isEmpty, "\(strategy)")
            #expect(!a.caveat.contains("Heat cap reached"), "\(strategy)")
        }
    }

    // MARK: The empty-plan sentence, which the same count made false in the OPPOSITE direction

    @Test func theEmptyPlanSentenceCountsOnlyWhatWasActuallySized() {
        // 12 qualified, 7 cut by the cap ⇒ only 5 were ever sized. Saying "all 12 are below the
        // 1-share minimum" would be a claim about seven names the sizer never saw.
        let s = MarketsView.emptyPlanSentence(fundableCandidateCount: 12, truncatedForHeat: 7,
                                              maxHeat: 0.08, account: 500)
        #expect(s.contains("all 5 sized positions are below the 1-share minimum"))
        #expect(s.contains("A further 7 qualified ideas were cut by the 8% heat cap before sizing"))
        #expect(!s.contains("all 12"))

        // Nothing cut ⇒ no extra clause, and the sentence reads as it always did.
        let plain = MarketsView.emptyPlanSentence(fundableCandidateCount: 3, truncatedForHeat: 0,
                                                  maxHeat: 0.08, account: 500)
        #expect(plain.contains("all 3 sized positions are below the 1-share minimum"))
        #expect(!plain.contains("A further"))

        // Singular agreement on both halves.
        let one = MarketsView.emptyPlanSentence(fundableCandidateCount: 2, truncatedForHeat: 1,
                                                maxHeat: 0.08, account: 500)
        #expect(one.contains("all 1 sized position is below"))
        #expect(one.contains("A further 1 qualified idea was cut"))

        // Degenerate input cannot produce a negative count.
        let odd = MarketsView.emptyPlanSentence(fundableCandidateCount: 1, truncatedForHeat: 5,
                                                maxHeat: 0.08, account: 500)
        #expect(odd.contains("all 0 sized positions"))
    }
}
