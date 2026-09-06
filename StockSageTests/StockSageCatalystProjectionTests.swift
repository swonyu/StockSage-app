import Testing
import Foundation
@testable import StockSage

// MARK: - Earnings-date projection math (W1, 2026-09-06)
//
// Every date below is hand-built from a fixed epoch via whole-day offsets so the gap/median
// arithmetic is checkable by eye (testing-discipline: hand-derived fixtures, derivation in a
// comment, hard assertions).

@Suite("StockSageCatalystProjection")
struct StockSageCatalystProjectionTests {
    private let day0 = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z

    // MARK: median (pure)

    @Test func medianOfEmptyIsNil() {
        #expect(StockSageCatalystProjection.median([]) == nil)
    }

    @Test func medianOfOneIsItself() {
        #expect(StockSageCatalystProjection.median([5]) == 5)
    }

    @Test func medianOfEvenCountAveragesTheTwoMiddleValues() {
        #expect(StockSageCatalystProjection.median([1, 2]) == 1.5)
        #expect(StockSageCatalystProjection.median([4, 2, 1, 3]) == 2.5)   // sorted [1,2,3,4] → (2+3)/2
    }

    @Test func medianOfOddCountIsTheMiddleValue() {
        #expect(StockSageCatalystProjection.median([1, 2, 3]) == 2)
        #expect(StockSageCatalystProjection.median([5, 1, 3]) == 3)
    }

    // MARK: project(history:) — the <3-history-dates boundary

    @Test func exactlyTwoHistoryDatesDoesNotProject() {
        let d1 = day0, d2 = day0.addingTimeInterval(90 * 86_400)
        #expect(StockSageCatalystProjection.project(history: [d1, d2]) == nil,
                "2 dates ⇒ only 1 gap — not enough to trust a median from")
    }

    @Test func exactlyThreeHistoryDatesProjectsWithAnEvenGapCount() {
        // Hand-derived: 3 dates, 2 gaps of 90 and 92 days → median = (90+92)/2 = 91.
        let d1 = day0
        let d2 = d1.addingTimeInterval(90 * 86_400)
        let d3 = d2.addingTimeInterval(92 * 86_400)
        guard let p = StockSageCatalystProjection.project(history: [d3, d1, d2]) else {   // unordered input
            Issue.record("3 dates must project"); return
        }
        #expect(p.date == d3.addingTimeInterval(91 * 86_400))
        #expect(p.dateRangeEnd == p.date.addingTimeInterval(7 * 86_400))
        #expect(p.basis.contains("median gap of last 3 reports = 91 d from"))
    }

    @Test func fourHistoryDatesProjectsWithAnOddGapCount() {
        // Hand-derived: 4 dates, 3 gaps of 90, 92, 94 days → median = the middle value, 92
        // (NOT the mean of all three, which would be 92.0 too by coincidence here — pick values
        // where mean ≠ median to make the assertion meaningful: 90, 92, 200 → mean=127.33,
        // median=92).
        let d1 = day0
        let d2 = d1.addingTimeInterval(90 * 86_400)
        let d3 = d2.addingTimeInterval(92 * 86_400)
        let d4 = d3.addingTimeInterval(200 * 86_400)
        guard let p = StockSageCatalystProjection.project(history: [d1, d2, d3, d4]) else {
            Issue.record("4 dates must project"); return
        }
        #expect(p.date == d4.addingTimeInterval(92 * 86_400), "median of [90,92,200] is the middle value 92, not the mean")
        #expect(p.basis.contains("median gap of last 4 reports = 92 d from"))
    }

    @Test func atMostTheLastEightGapsFeedTheMedian() {
        // 10 dates: an ENORMOUS first gap (1000d) that must be EXCLUDED once more than 9 dates
        // exist (⇒ at most the last 9 dates / 8 gaps), followed by 9 evenly-spaced dates 90 days
        // apart (8 gaps of exactly 90). If the huge gap leaked in, the median would be skewed way
        // above 90; it must come out to exactly 90.
        var dates: [Date] = [day0]
        var cursor = day0.addingTimeInterval(1_000 * 86_400)   // the huge, excluded gap
        dates.append(cursor)
        for _ in 0..<8 {
            cursor = cursor.addingTimeInterval(90 * 86_400)
            dates.append(cursor)
        }
        #expect(dates.count == 10)
        guard let p = StockSageCatalystProjection.project(history: dates) else {
            Issue.record("10 dates must project"); return
        }
        #expect(p.date == dates.last!.addingTimeInterval(90 * 86_400))
        #expect(p.basis.contains("median gap of last 9 reports = 90 d from"))
    }
}
