import Testing
import Foundation
@testable import StockSage

// MARK: - Reward:risk quality (pure)

struct StockSageRewardRiskTests {

    typealias RR = StockSageRewardRisk

    // entry 100, stop 90 → risk 10. target varies.
    @Test func strongSetupHasHighRatioAndLowBreakeven() {
        // target 130 → reward 30, ratio 3.0 → strong; breakeven 1/(1+3)=0.25
        let r = RR.assess(entry: 100, stop: 90, target: 130)!
        #expect(abs(r.ratio - 3.0) < 1e-9)
        #expect(r.quality == .strong)
        #expect(abs(r.breakevenWinRate - 0.25) < 1e-9)
    }

    @Test func fairSetupAtRatioTwo() {
        // target 120 → reward 20, ratio 2.0 → fair; breakeven 1/3
        let r = RR.assess(entry: 100, stop: 90, target: 120)!
        #expect(abs(r.ratio - 2.0) < 1e-9)
        #expect(r.quality == .fair)
        #expect(abs(r.breakevenWinRate - (1.0 / 3.0)) < 1e-9)
    }

    @Test func poorSetupNeedsAMajorityWinRate() {
        // target 110 → reward 10, ratio 1.0 → poor; breakeven 0.5
        let r = RR.assess(entry: 100, stop: 90, target: 110)!
        #expect(abs(r.ratio - 1.0) < 1e-9)
        #expect(r.quality == .poor)
        #expect(abs(r.breakevenWinRate - 0.5) < 1e-9)
    }

    @Test func bandBoundaries() {
        // exactly 1.5 → fair, exactly 2.5 → strong (inclusive lower bounds)
        #expect(RR.assess(entry: 100, stop: 90, target: 115)!.quality == .fair)    // ratio 1.5
        #expect(RR.assess(entry: 100, stop: 90, target: 125)!.quality == .strong)  // ratio 2.5
    }

    @Test func zeroRiskOrRewardIsNil() {
        #expect(RR.assess(entry: 100, stop: 100, target: 120) == nil)   // risk 0
        #expect(RR.assess(entry: 100, stop: 90, target: 100) == nil)    // reward 0
    }

    // MARK: - wave-11 "gross" note tests (F18) — hand-derived via derive_wave11f.swift

    // note for ratio=3.0 (Strong): "R:R 3.0 gross — Strong; needs a >25.0% win-rate just to break even."
    // note for ratio=2.0 (Fair):  "R:R 2.0 gross — Fair; needs a >33.3% win-rate just to break even."
    @Test func noteContainsGrossLabelForStrongSetup() {
        // entry=100, stop=90, target=130 → ratio=3.0, breakevenWinRate=0.25 → "25.0%"
        let r = RR.assess(entry: 100, stop: 90, target: 130)!
        #expect(r.note.contains("gross"))
        // breakeven decimal: %.1f of 0.25*100 = "25.0"
        #expect(r.note.contains("25.0"))
    }

    @Test func noteContainsGrossLabelAndDecimalForFairSetup() {
        // entry=100, stop=90, target=120 → ratio=2.0, breakevenWinRate=1/3 → "33.3%"
        let r = RR.assess(entry: 100, stop: 90, target: 120)!
        #expect(r.note.contains("gross"))
        // breakeven decimal: %.1f of (1/3)*100 = "33.3"
        #expect(r.note.contains("33.3"))
    }
}
