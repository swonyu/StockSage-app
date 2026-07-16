import Testing
import Foundation
@testable import StockSage

// MARK: - Compounding horizon (FASTMONEY_BACKLOG #8) — pure, hand/python-verified.

struct StockSageCompoundingHorizonTests {
    typealias Horizon = StockSageCompoundingHorizon

    @Test func weeksToTargetMatchesTheClosedFormCompoundingFormula() {
        // t = ln(target) / ln(1 + weeklyReturn) — python-verified.
        #expect(abs(Horizon.weeksToTarget(weeklyReturn: 0.01, target: 2.0)! - 69.66071689357483) < 1e-6)
        #expect(abs(Horizon.weeksToTarget(weeklyReturn: 0.02, target: 2.0)! - 35.0027887811465) < 1e-6)
        #expect(abs(Horizon.weeksToTarget(weeklyReturn: 0.005, target: 3.0)! - 220.27130726361713) < 1e-6)
    }

    @Test func nonPositiveWeeklyReturnHasNoDoublingTime() {
        #expect(Horizon.weeksToTarget(weeklyReturn: 0) == nil)
        #expect(Horizon.weeksToTarget(weeklyReturn: -0.01) == nil)
    }

    @Test func targetAtOrBelowOneIsAlreadyThere() {
        #expect(Horizon.weeksToTarget(weeklyReturn: 0.01, target: 1.0) == 0)
        #expect(Horizon.weeksToTarget(weeklyReturn: 0.01, target: 0.5) == 0)
    }

    @Test func nonFiniteInputsNeverCrashOrProduceNonsense() {
        #expect(Horizon.weeksToTarget(weeklyReturn: .infinity) == nil)
        #expect(Horizon.weeksToTarget(weeklyReturn: .nan) == nil)
        #expect(Horizon.weeksToTarget(weeklyReturn: 0.01, target: .infinity) == nil)
    }

    @Test func caveatIsExplicitlyLabeledHypotheticalNotAForecast() {
        // The honesty floor IS the spec here — enforce it as a test, not just a comment.
        #expect(Horizon.caveat.contains("HYPOTHETICAL"))
        #expect(Horizon.caveat.localizedCaseInsensitiveContains("not a forecast"))
        #expect(Horizon.caveat.localizedCaseInsensitiveContains("slower"))
    }
}
