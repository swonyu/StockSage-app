import Testing
import Foundation
@testable import StockSage

// Ordinal rules-agreement display (external-report item 12, owner-signed 2026-07-28).
// The engine's `confidence` counts agreeing rules; rendering it as "65%" implied a
// probability it never was. These pin the 1...5 banding and its clamping.

@Suite("Ordinal strength display")
struct OrdinalStrengthTests {

    typealias M = MarketsView

    @Test("bands are even fifths, upper edge lands in level 5")
    func bandsAreEvenFifths() {
        // 0.0-0.2 -> 1, 0.2-0.4 -> 2, 0.4-0.6 -> 3, 0.6-0.8 -> 4, 0.8-1.0 -> 5
        #expect(M.ordinalStrengthLevel(0.00) == 1)
        #expect(M.ordinalStrengthLevel(0.19) == 1)
        #expect(M.ordinalStrengthLevel(0.20) == 2)
        #expect(M.ordinalStrengthLevel(0.39) == 2)
        #expect(M.ordinalStrengthLevel(0.40) == 3)
        #expect(M.ordinalStrengthLevel(0.59) == 3)
        #expect(M.ordinalStrengthLevel(0.60) == 4)
        #expect(M.ordinalStrengthLevel(0.79) == 4)
        #expect(M.ordinalStrengthLevel(0.80) == 5)
        #expect(M.ordinalStrengthLevel(1.00) == 5)     // upper edge must not spill to 6
    }

    @Test("out-of-range scores clamp instead of producing a nonsense level")
    func outOfRangeClamps() {
        #expect(M.ordinalStrengthLevel(-3) == 1)
        #expect(M.ordinalStrengthLevel(42) == 5)
        #expect(M.ordinalStrengthLevel(.nan) == 1)     // NaN comparisons are false → clamps low
    }

    @Test("the label reads as a level, never as a percentage")
    func labelIsNotAPercentage() {
        #expect(M.ordinalStrengthLabel(0.65) == "4/5")
        #expect(!M.ordinalStrengthLabel(0.65).contains("%"))
        #expect(M.ordinalStrengthLabel(0.95) == "5/5")
    }

    @Test("screen readers get the same five-level scale as signal cards")
    func screenReaderScaleMatchesCard() {
        for recommendation in [StockSageRecommendation.buy, .strongBuy, .sell, .strongSell] {
            let signal = StockSageSignal(symbol: "TEST", recommendation: recommendation,
                                         confidence: 0.45, reason: "")
            #expect(M.ordinalStrengthLabel(signal.confidence) == "3/5")
            #expect(M.signalAccessibilitySummary(signal) == "rules signal \(recommendation.rawValue), strength level 3 of 5, not a win probability")
        }
        #expect(M.signalAccessibilitySummary(nil) == "rules signal none")
        let hold = StockSageSignal(symbol: "TEST", recommendation: .hold, confidence: 0.65, reason: "")
        #expect(M.signalAccessibilitySummary(hold) == "rules signal Hold")
        for confidence in [Double.nan, Double.infinity] {
            let invalid = StockSageSignal(symbol: "TEST", recommendation: .buy, confidence: confidence, reason: "")
            #expect(M.signalAccessibilitySummary(invalid) == "rules signal Buy, strength level 1 of 5, not a win probability")
        }
    }
}
