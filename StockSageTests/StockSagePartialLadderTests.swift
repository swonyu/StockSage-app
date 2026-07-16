import Testing
import Foundation
@testable import StockSage

// MARK: - Partial-profit ladder (pure)

struct StockSagePartialLadderTests {
    typealias L = StockSagePartialLadder

    @Test func longLadderEvenlySpacedToTarget() {
        // entry 100, stop 90 (risk 10), target 130 (3R). 3 rungs → 1R@110, 2R@120, 3R@130.
        let l = L.levels(entry: 100, stop: 90, target: 130, rungs: 3)!
        #expect(l.rungs.map(\.price) == [110, 120, 130])
        #expect(l.rungs.map(\.rMultiple) == [1, 2, 3])
        #expect(l.rungs.allSatisfy { abs($0.fraction - 1.0 / 3) < 1e-9 })
        #expect(abs(l.blendedExitR - 2.0) < 1e-9)        // (1+2+3)/3 — scaling out averages to 2R
        #expect(l.rungs.last?.price == 130)              // last rung is the target
    }

    @Test func shortLadderMirrors() {
        // short: entry 100, stop 110 (risk 10), target 80 (2R). 2 rungs → 1R@90, 2R@80.
        let s = L.levels(entry: 100, stop: 110, target: 80, rungs: 2)!
        #expect(s.rungs.map(\.price) == [90, 80])
        #expect(s.rungs.map(\.rMultiple) == [1, 2])
        #expect(abs(s.blendedExitR - 1.5) < 1e-9)        // (1+2)/2
    }

    @Test func guardsDegenerate() {
        #expect(L.levels(entry: 100, stop: 100, target: 130, rungs: 3) == nil)  // zero risk
        #expect(L.levels(entry: 100, stop: 90, target: 100, rungs: 3) == nil)   // target == entry
        #expect(L.levels(entry: 100, stop: 90, target: 130, rungs: 0) == nil)   // no rungs
    }

    @Test func singleRungLadderExitsAtTarget() {
        let l = StockSagePartialLadder.levels(entry: 100, stop: 90, target: 130, rungs: 1)!
        #expect(l.rungs.count == 1)
        #expect(abs(l.rungs[0].price - 130) < 1e-9)
        #expect(abs(l.rungs[0].rMultiple - 3.0) < 1e-9)
        #expect(abs(l.rungs[0].fraction - 1.0) < 1e-9)
        #expect(abs(l.blendedExitR - 3.0) < 1e-9)
    }

    @Test func largeRungsCountBlendingIsCorrect() {
        let l = StockSagePartialLadder.levels(entry: 100, stop: 90, target: 150, rungs: 10)!
        #expect(l.rungs.count == 10)
        #expect(l.rungs.allSatisfy { abs($0.fraction - 0.1) < 1e-9 })
        #expect(abs(l.blendedExitR - 2.75) < 1e-9)
    }

    @Test func guardsNonFiniteInputsRatherThanProducingNaN() {
        // Before the fix: Double.infinity > 0 is true, so these passed the old positivity-only
        // guard and targetR = reward / risk became Infinity/Infinity = NaN, poisoning every
        // rung's price/rMultiple.
        #expect(L.levels(entry: .infinity, stop: 90, target: 130, rungs: 3) == nil)
        #expect(L.levels(entry: 100, stop: .infinity, target: 130, rungs: 3) == nil)
        #expect(L.levels(entry: 100, stop: 90, target: .infinity, rungs: 3) == nil)
        #expect(L.levels(entry: .nan, stop: 90, target: 130, rungs: 3) == nil)
        #expect(L.levels(entry: 100, stop: .nan, target: 130, rungs: 3) == nil)
        #expect(L.levels(entry: 100, stop: 90, target: .nan, rungs: 3) == nil)
    }
}
