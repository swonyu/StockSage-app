import Testing
import Foundation
@testable import StockSage

// MARK: - Pyramiding (scale-in) ladder (pure)

struct StockSagePyramidTests {
    typealias P = StockSagePyramid

    @Test func longPyramidTriggersAndFractionsUncapped() {
        // entry 100, stop 90 (risk 10), initialFraction 0.10, default cap 0.20.
        // Uncapped total = 0.10 + 0.05 + 0.025 = 0.175 <= 0.20 → no scaling.
        let p = P.levels(entry: 100, stop: 90, initialFraction: 0.10)!
        #expect(p.tiers.map(\.price) == [100, 105, 115])
        #expect(p.tiers.map(\.rMultiple) == [0, 0.5, 1.5])
        #expect(abs(p.tiers[0].addOnFraction - 0.10) < 1e-9)
        #expect(abs(p.tiers[1].addOnFraction - 0.05) < 1e-9)
        #expect(abs(p.tiers[2].addOnFraction - 0.025) < 1e-9)
        #expect(abs(p.tiers[0].cumulativeFraction - 0.10) < 1e-9)
        #expect(abs(p.tiers[1].cumulativeFraction - 0.15) < 1e-9)
        #expect(abs(p.tiers[2].cumulativeFraction - 0.175) < 1e-9)
        #expect(abs(p.requestedFraction - 0.175) < 1e-9)
        #expect(abs(p.totalFraction - 0.175) < 1e-9)
        #expect(p.scaleApplied == 1)
        #expect(p.riskCap == StockSageKelly.maxFraction)
    }

    @Test func shortPyramidMirrorsLong() {
        // short: entry 100, stop 110 (risk 10) — favorable direction is DOWN.
        let s = P.levels(entry: 100, stop: 110, initialFraction: 0.10)!
        #expect(s.tiers.map(\.price) == [100, 95, 85])
        #expect(s.tiers.map(\.rMultiple) == [0, 0.5, 1.5])
        #expect(abs(s.tiers[0].addOnFraction - 0.10) < 1e-9)
        #expect(abs(s.tiers[1].addOnFraction - 0.05) < 1e-9)
        #expect(abs(s.tiers[2].addOnFraction - 0.025) < 1e-9)
    }

    @Test func shrinkingSizesAlwaysHold() {
        // Uncapped: tier1 > tier2 > tier3 strictly.
        let p = P.levels(entry: 100, stop: 90, initialFraction: 0.10)!
        #expect(p.tiers[0].addOnFraction > p.tiers[1].addOnFraction)
        #expect(p.tiers[1].addOnFraction > p.tiers[2].addOnFraction)
        // Capped: the ratios survive uniform scaling, so the shrinking shape still holds.
        let capped = P.levels(entry: 100, stop: 90, initialFraction: 0.15, riskCap: 0.20)!
        #expect(capped.tiers[0].addOnFraction > capped.tiers[1].addOnFraction)
        #expect(capped.tiers[1].addOnFraction > capped.tiers[2].addOnFraction)
    }

    @Test func orderedTriggersAreFixedAndIncreasing() {
        let p = P.levels(entry: 50, stop: 45, initialFraction: 0.05)!
        let rs = p.tiers.map(\.rMultiple)
        #expect(rs == [0, 0.5, 1.5])
        #expect(rs[0] < rs[1] && rs[1] < rs[2])
    }

    @Test func riskCapScalesAllTiersUniformlyAndIsRespected() {
        // initialFraction 0.15 → uncapped total 0.2625 > cap 0.20 → scale = 0.20/0.2625.
        let p = P.levels(entry: 100, stop: 90, initialFraction: 0.15, riskCap: 0.20)!
        let expectedScale = 0.20 / 0.2625
        #expect(abs(p.scaleApplied - expectedScale) < 1e-9)
        #expect(abs(p.requestedFraction - 0.2625) < 1e-9)
        #expect(abs(p.tiers[0].addOnFraction - 0.15 * expectedScale) < 1e-9)
        #expect(abs(p.tiers[1].addOnFraction - 0.075 * expectedScale) < 1e-9)
        #expect(abs(p.tiers[2].addOnFraction - 0.0375 * expectedScale) < 1e-9)
        // Total NEVER exceeds the cap, even though the uncapped request did.
        #expect(p.totalFraction <= p.riskCap + 1e-9)
        #expect(abs(p.totalFraction - 0.20) < 1e-9)
        #expect(abs(p.tiers.last!.cumulativeFraction - p.totalFraction) < 1e-9)
    }

    @Test func underCapIsANoOp() {
        let p = P.levels(entry: 100, stop: 90, initialFraction: 0.02, riskCap: 0.20)!
        #expect(p.scaleApplied == 1)
        #expect(abs(p.totalFraction - 0.035) < 1e-9)   // 0.02 + 0.01 + 0.005, well under 0.20
    }

    @Test func defaultRiskCapIsKellyMaxFraction() {
        let p = P.levels(entry: 100, stop: 90, initialFraction: 0.10)!
        #expect(p.riskCap == StockSageKelly.maxFraction)
    }

    @Test func riskCapAboveOneIsClampedToOne() {
        // A caller passing a nonsensical >100% cap must never get a >100% total suggested.
        let p = P.levels(entry: 100, stop: 90, initialFraction: 1.0, riskCap: 2.0)!
        #expect(p.riskCap == 1)
        #expect(p.totalFraction <= 1 + 1e-9)
    }

    @Test func guardsDegenerate() {
        #expect(P.levels(entry: 100, stop: 100, initialFraction: 0.10) == nil)     // zero risk
        #expect(P.levels(entry: 0, stop: 90, initialFraction: 0.10) == nil)        // non-positive entry
        #expect(P.levels(entry: 100, stop: 90, initialFraction: 0) == nil)         // no size to pyramid
        #expect(P.levels(entry: 100, stop: 90, initialFraction: -0.1) == nil)      // negative size
        #expect(P.levels(entry: 100, stop: 90, initialFraction: 0.10, riskCap: 0) == nil)  // no cap budget
    }

    // MARK: - 2026-07-01 adversarial-review fix: finiteness + fraction-ceiling guards

    @Test func guardsNonFiniteInputsRatherThanProducingNaN() {
        // Before the fix: Double.infinity > 0 is true, so these passed the old positivity-only
        // guard and poisoned every tier field with NaN (e.g. 0 x .infinity in the price math).
        #expect(P.levels(entry: .infinity, stop: 90, initialFraction: 0.10) == nil)
        #expect(P.levels(entry: 100, stop: .infinity, initialFraction: 0.10) == nil)
        #expect(P.levels(entry: 100, stop: 90, initialFraction: .infinity) == nil)
        #expect(P.levels(entry: 100, stop: 90, initialFraction: 0.10, riskCap: .infinity) == nil)
        #expect(P.levels(entry: .nan, stop: 90, initialFraction: 0.10) == nil)
        #expect(P.levels(entry: 100, stop: 90, initialFraction: .nan) == nil)
    }

    @Test func initialFractionAboveOneHundredPercentIsRejected() {
        // initialFraction is an ACCOUNT FRACTION — >1.0 (>100% of the account) is never
        // legitimate, and a huge-but-finite value would otherwise overflow the tier sum to
        // .infinity, silently zeroing every addOnFraction while still reporting an infinite
        // requestedFraction.
        #expect(P.levels(entry: 100, stop: 90, initialFraction: 1.01) == nil)
        #expect(P.levels(entry: 100, stop: 90, initialFraction: 1.2e308) == nil)
        // Exactly 1.0 remains valid (matches the existing pinned test at initialFraction: 1.0).
        #expect(P.levels(entry: 100, stop: 90, initialFraction: 1.0, riskCap: 2.0) != nil)
    }

    @Test func caveatIsPresentAndNonEmpty() {
        let p = P.levels(entry: 100, stop: 90, initialFraction: 0.10)!
        #expect(!p.caveat.isEmpty)
        #expect(p.caveat == StockSagePyramid.caveat)
        // Load-bearing caveat per the backlog spec: "only if it runs, never force it".
        #expect(p.caveat.lowercased().contains("never"))
        #expect(p.caveat.lowercased().contains("risk cap"))
    }
}
