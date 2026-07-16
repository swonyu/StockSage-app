import Testing
import Foundation
@testable import StockSage

// MARK: - Underwater / drawdown curve (pure)

struct StockSageDrawdownTests {

    @Test func monotonicRiseHasNoDrawdown() {
        let u = StockSageDrawdown.underwater([100, 110, 120, 130])
        #expect(u.series.allSatisfy { $0 == 0 })
        #expect(u.maxDrawdown == 0)
        #expect(u.longestUnderwaterBars == 0)
    }

    @Test func dipAndRecoveryMeasuresDepthAndDuration() {
        // peak stays 100: 0, −20, −10, then new high → 0
        let u = StockSageDrawdown.underwater([100, 80, 90, 120])
        #expect(abs(u.series[1] - (-20)) < 1e-9)
        #expect(abs(u.series[2] - (-10)) < 1e-9)
        #expect(u.series[3] == 0)
        #expect(abs(u.maxDrawdown - 20) < 1e-9)
        #expect(u.longestUnderwaterBars == 2)
    }

    @Test func longestUnderwaterIsTheLongestConsecutiveRun() {
        // peak 100 throughout: 0,−10,0,−10,−20,−30 → runs of 1 then 3
        let u = StockSageDrawdown.underwater([100, 90, 100, 90, 80, 70])
        #expect(u.longestUnderwaterBars == 3)
        #expect(abs(u.maxDrawdown - 30) < 1e-9)
    }

    @Test func singleHalvingIsFiftyPercent() {
        let u = StockSageDrawdown.underwater([100, 50])
        #expect(abs(u.maxDrawdown - 50) < 1e-9)
        #expect(u.longestUnderwaterBars == 1)
    }

    @Test func emptyIsZero() {
        let u = StockSageDrawdown.underwater([])
        #expect(u.isEmpty)
        #expect(u.maxDrawdown == 0)
        #expect(u.longestUnderwaterBars == 0)
    }
}
