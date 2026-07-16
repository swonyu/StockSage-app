import Testing
@testable import StockSage

// MARK: - Detail-sheet prev/next navigation (pure index math)
//
// Fixtures + expected values HAND-DERIVED in /tmp/derive_sheetnav.swift (output pasted in
// plans/PLAN_2026-07-02_sheet_candidate_navigation.md §Step 2a) — NEVER from calling the
// code under test (spec-fidelity / F40 rule). Board fixture ["AAA","BBB","CCC"]:
// AAA=0, BBB=1, CCC=2 by hand; labels are 1-based.

struct SheetCandidateNavigationTests {

    /// Hand-typed board-order ids (stand-ins for displayedIdeas.map(\.id)).
    private let ids = ["AAA", "BBB", "CCC"]

    @Test func nextFromMiddleStepsDown() {
        // derive_sheetnav: next(BBB) = 2
        #expect(SheetCandidateNavigation.neighborIndex(ids: ids, currentID: "BBB", delta: +1) == 2)
    }

    @Test func prevFromMiddleStepsUp() {
        // derive_sheetnav: prev(BBB) = 0
        #expect(SheetCandidateNavigation.neighborIndex(ids: ids, currentID: "BBB", delta: -1) == 0)
    }

    @Test func prevClampsAtFirst() {
        #expect(SheetCandidateNavigation.neighborIndex(ids: ids, currentID: "AAA", delta: -1) == nil)
        // Same id CAN still step forward — proves the nil above is the CLAMP firing, not a
        // failed lookup (WHIPPYX rule: the test must prove the positive path fires too).
        #expect(SheetCandidateNavigation.neighborIndex(ids: ids, currentID: "AAA", delta: +1) == 1)
    }

    @Test func nextClampsAtLast() {
        #expect(SheetCandidateNavigation.neighborIndex(ids: ids, currentID: "CCC", delta: +1) == nil)
        #expect(SheetCandidateNavigation.neighborIndex(ids: ids, currentID: "CCC", delta: -1) == 1)
    }

    @Test func unknownIDResolvesNil() {
        // The board mutated under background refresh and the shown idea fell off it —
        // press-time re-resolution must refuse to step, and the label must vanish
        // (honesty floor: never fabricate a position).
        #expect(SheetCandidateNavigation.neighborIndex(ids: ids, currentID: "GONE", delta: +1) == nil)
        #expect(SheetCandidateNavigation.positionLabel(ids: ids, currentID: "GONE") == nil)
    }

    @Test func positionLabelIsOneBased() {
        // derive_sheetnav: label(AAA) = "1 of 3", label(CCC) = "3 of 3"
        #expect(SheetCandidateNavigation.positionLabel(ids: ids, currentID: "AAA") == "1 of 3")
        #expect(SheetCandidateNavigation.positionLabel(ids: ids, currentID: "CCC") == "3 of 3")
    }

    @Test func singleIdeaBoardDisablesBothDirections() {
        #expect(SheetCandidateNavigation.neighborIndex(ids: ["ONLY"], currentID: "ONLY", delta: +1) == nil)
        #expect(SheetCandidateNavigation.neighborIndex(ids: ["ONLY"], currentID: "ONLY", delta: -1) == nil)
        #expect(SheetCandidateNavigation.positionLabel(ids: ["ONLY"], currentID: "ONLY") == "1 of 1")
    }

    @Test func emptyBoardResolvesNil() {
        #expect(SheetCandidateNavigation.neighborIndex(ids: [], currentID: "ANY", delta: +1) == nil)
        #expect(SheetCandidateNavigation.positionLabel(ids: [], currentID: "ANY") == nil)
    }
}
