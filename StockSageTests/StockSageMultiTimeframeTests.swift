import Testing
import Foundation
@testable import StockSage

// MARK: - Multi-timeframe trend confirmation (pure)

struct StockSageMultiTimeframeTests {

    typealias MTF = StockSageMultiTimeframe

    @Test func trendDirections() {
        #expect(MTF.trend((1...60).map(Double.init), period: 50) == .up)
        #expect(MTF.trend((1...60).reversed().map(Double.init), period: 50) == .down)
        #expect(MTF.trend(Array(repeating: 100.0, count: 60), period: 50) == .flat)
        #expect(MTF.trend([1], period: 50) == .flat)   // too short → flat, no crash
    }

    @Test func alignedWhenBothUp() {
        let r = MTF.assess(dailyCloses: (1...250).map(Double.init),
                           weeklyCloses: (1...60).map(Double.init))
        #expect(r.daily == .up)
        #expect(r.weekly == .up)
        #expect(r.aligned)
        #expect(r.note.contains("aligned"))
    }

    @Test func notAlignedWhenTheyDisagree() {
        let r = MTF.assess(dailyCloses: (1...250).map(Double.init),               // daily up
                           weeklyCloses: (1...60).reversed().map(Double.init))     // weekly down
        #expect(r.daily == .up)
        #expect(r.weekly == .down)
        #expect(!r.aligned)
        #expect(r.note.contains("disagree"))
    }

    @Test func tooShortHigherTimeframeIsFlatNotAligned() {
        // <30 weekly bars must NOT fake a 30-week trend (the degraded-MA bug).
        #expect(MTF.trend((1...10).map(Double.init), period: 30) == .flat)
        let r = MTF.assess(dailyCloses: (1...250).map(Double.init),
                           weeklyCloses: (1...10).map(Double.init))
        #expect(r.weekly == .flat)
        #expect(!r.aligned)
    }

    @Test func flatTimeframeIsNotAligned() {
        let r = MTF.assess(dailyCloses: (1...250).map(Double.init),
                           weeklyCloses: Array(repeating: 100.0, count: 60))
        #expect(!r.aligned)
        #expect(r.note.contains("unclear"))
    }
}
