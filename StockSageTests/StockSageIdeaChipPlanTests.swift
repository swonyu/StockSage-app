import Testing
@testable import StockSage

// MARK: - Idea-card chip density plan — pure static visibleChips(), hand-derived
//
// Fixtures hand-derived from the priority order documented in IdeaChipPlan itself
// (stale > earnings > floor > heldOrTraded > delta > extreme > confluence), never
// from calling the implementation (F40 discipline — this file predicts the
// dropped element BEFORE running the assertion). Boundary straddle: 4 conditionals
// (under cap), 5 (exactly cap), 6 and 7 (over cap, one/two dropped).

struct StockSageIdeaChipPlanTests {

    @Test func fourConditionalsAllVisibleUnderCap() {
        // stale, earnings, floor, heldOrTraded true; delta, extreme, confluence false.
        let result = IdeaChipPlan.visibleChips(stale: true, earnings: true, floor: true,
                                                heldOrTraded: true, delta: false, extreme: false,
                                                confluence: false)
        #expect(result == [.stale, .earnings, .floor, .heldOrTraded])
        #expect(result.count == 4)
    }

    @Test func fiveConditionalsAllVisibleExactlyAtCap() {
        // stale, earnings, floor, heldOrTraded, delta true — exactly IdeaChipPlan.cap (5).
        let result = IdeaChipPlan.visibleChips(stale: true, earnings: true, floor: true,
                                                heldOrTraded: true, delta: true, extreme: false,
                                                confluence: false)
        #expect(result == [.stale, .earnings, .floor, .heldOrTraded, .delta])
        #expect(result.count == 5)
    }

    @Test func sixConditionalsDropsLowestPriorityPresent_extreme() {
        // All six of the original six true (confluence false) — the 6th-ranked present
        // chip (extreme, priority 6) is the one over the cap of 5 and must be dropped.
        let result = IdeaChipPlan.visibleChips(stale: true, earnings: true, floor: true,
                                                heldOrTraded: true, delta: true, extreme: true,
                                                confluence: false)
        #expect(result == [.stale, .earnings, .floor, .heldOrTraded, .delta])
        #expect(!result.contains(.extreme))
        #expect(result.count == 5)
    }

    @Test func sixConditionalsWithConfluenceInsteadOfExtremeDropsConfluence() {
        // stale, earnings, floor, heldOrTraded, delta, confluence true (extreme false):
        // confluence (priority 7, lowest of all) is dropped even though it's the only
        // one of the "last two" present — confirms drop order is by PRIORITY RANK of
        // the true set, not by "whichever is 6th in the boolean parameter list".
        let result = IdeaChipPlan.visibleChips(stale: true, earnings: true, floor: true,
                                                heldOrTraded: true, delta: true, extreme: false,
                                                confluence: true)
        #expect(result == [.stale, .earnings, .floor, .heldOrTraded, .delta])
        #expect(!result.contains(.confluence))
        #expect(result.count == 5)
    }

    @Test func allSevenConditionalsDropsTwoLowestPriority_extremeAndConfluence() {
        let result = IdeaChipPlan.visibleChips(stale: true, earnings: true, floor: true,
                                                heldOrTraded: true, delta: true, extreme: true,
                                                confluence: true)
        #expect(result == [.stale, .earnings, .floor, .heldOrTraded, .delta])
        #expect(!result.contains(.extreme))
        #expect(!result.contains(.confluence))
        #expect(result.count == 5)
    }

    @Test func zeroConditionalsIsEmpty() {
        let result = IdeaChipPlan.visibleChips(stale: false, earnings: false, floor: false,
                                                heldOrTraded: false, delta: false, extreme: false,
                                                confluence: false)
        #expect(result.isEmpty)
    }

    @Test func onlyLowPriorityChipsPresentStillRenderUnderCap() {
        // Only extreme + confluence true — well under cap, both must render (dropping
        // is purely a function of exceeding the cap, never of "low priority" alone).
        let result = IdeaChipPlan.visibleChips(stale: false, earnings: false, floor: false,
                                                heldOrTraded: false, delta: false, extreme: true,
                                                confluence: true)
        #expect(result == [.extreme, .confluence])
    }
}
