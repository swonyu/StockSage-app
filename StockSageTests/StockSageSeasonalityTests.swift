import Testing
import Foundation
@testable import StockSage

// MARK: - Monthly seasonality (pure)

struct StockSageSeasonalityTests {

    @Test func currentMonthUsesUTCNotLocal() {
        // 1970-01-01 00:00:00 UTC → month 1 in UTC. A negative-offset LOCAL calendar would read
        // Dec 31 1969 → month 12; forcing UTC keeps the "this month" lookup aligned with compute().
        #expect(StockSageSeasonality.currentMonth(asOf: Date(timeIntervalSince1970: 0)) == 1)
        // 1970-02-01 00:00:00 UTC = 31 days later → month 2.
        #expect(StockSageSeasonality.currentMonth(asOf: Date(timeIntervalSince1970: 31 * 86_400)) == 2)
    }

    private func utcDate(_ y: Int, _ m: Int, _ d: Int = 28) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// Month-end series Dec 2019 … Dec 2022. Each June return = +10%, all else flat.
    private func juneSpikeSeries() -> (dates: [Date], closes: [Double]) {
        var dates: [Date] = []
        var closes: [Double] = []
        var price = 100.0
        dates.append(utcDate(2019, 12)); closes.append(price)
        for y in 2020...2022 {
            for m in 1...12 {
                price *= (m == 6) ? 1.10 : 1.00     // June pops, others flat
                dates.append(utcDate(y, m)); closes.append(price)
            }
        }
        return (dates, closes)
    }

    @Test func juneIsTheStandoutMonth() {
        let s = juneSpikeSeries()
        let result = StockSageSeasonality.compute(dates: s.dates, closes: s.closes)
        let june = StockSageSeasonality.stat(result, month: 6)!
        #expect(abs(june.avgReturn - 0.10) < 1e-9)
        #expect(june.samples == 3)            // 2020, 2021, 2022
        #expect(june.isReliable)
        let jan = StockSageSeasonality.stat(result, month: 1)!
        #expect(abs(jan.avgReturn) < 1e-9)    // flat
        #expect(result.years > 2.9 && result.years < 3.1)
    }

    @Test func twelveMonthsAlwaysPresent() {
        let s = juneSpikeSeries()
        let result = StockSageSeasonality.compute(dates: s.dates, closes: s.closes)
        #expect(result.months.count == 12)
        #expect(result.months.map(\.month) == Array(1...12))
    }

    @Test func tooShortHistoryIsEmpty() {
        #expect(StockSageSeasonality.compute(dates: [utcDate(2020, 1)], closes: [100]) == .empty)
        #expect(StockSageSeasonality.compute(dates: [], closes: []) == .empty)
    }

    @Test func gapMonthIsNotCreditedAsSingleMonthReturn() {
        // Feb is MISSING. The Jan→Mar pair spans 2 months and must NOT be credited
        // to March; Mar→Apr is consecutive and counts.
        let dates = [utcDate(2020, 1), utcDate(2020, 3), utcDate(2020, 4)]
        let closes: [Double] = [100, 130, 130]
        let r = StockSageSeasonality.compute(dates: dates, closes: closes)
        #expect(StockSageSeasonality.stat(r, month: 3)!.samples == 0)   // gap → skipped
        #expect(StockSageSeasonality.stat(r, month: 4)!.samples == 1)   // consecutive → counted
    }

    @Test func thinSampleIsFlaggedUnreliable() {
        // Two calendar months only → each month has ≤1 sample → not reliable.
        let dates = [utcDate(2020, 1), utcDate(2020, 2)]
        let result = StockSageSeasonality.compute(dates: dates, closes: [100, 105])
        let feb = StockSageSeasonality.stat(result, month: 2)!
        #expect(feb.samples == 1)
        #expect(!feb.isReliable)
        #expect(feb.note(monthName: "February").contains("thin sample"))
    }

    @Test func inProgressMonthIsExcludedFromItsOwnBucket() {
        // Month-end points Jan…Jun 2020 + a PARTIAL July point (July 9). MEASURED premise
        // (2026-07-09, Yahoo v8 AAPL 1mo): the feed's last monthly bar is the in-progress
        // month — its "return" is a partial MTD move, not a seasonality observation.
        let dates = (1...6).map { utcDate(2020, $0) } + [utcDate(2020, 7, 9)]
        let closes: [Double] = [100, 102, 104, 106, 108, 110, 119]
        // As of MID-JULY (the month is in progress) → the July bucket must be EMPTY…
        let during = StockSageSeasonality.compute(dates: dates, closes: closes,
                                                  now: utcDate(2020, 7, 15))
        #expect(StockSageSeasonality.stat(during, month: 7)!.samples == 0)
        #expect(StockSageSeasonality.stat(during, month: 6)!.samples == 1)   // completed months keep theirs
        // …but from AUGUST on, the same trailing point is a COMPLETED July → it counts.
        let after = StockSageSeasonality.compute(dates: dates, closes: closes,
                                                 now: utcDate(2020, 8, 15))
        #expect(StockSageSeasonality.stat(after, month: 7)!.samples == 1)
    }

    @Test func stdDevAndTStatMatchHandDerivation() {
        // June returns across 3 years: +10%, +4%, +7%. Hand-derived (Bessel n−1,
        // /tmp/derive_seasonality_robustness.swift): mean 0.07, std 0.03, t 4.04145188432738.
        var dates: [Date] = [utcDate(2019, 12)]
        var closes: [Double] = [100]
        var price = 100.0
        let juneFactor = [2020: 1.10, 2021: 1.04, 2022: 1.07]
        for y in 2020...2022 {
            for m in 1...12 {
                price *= (m == 6) ? juneFactor[y]! : 1.0
                dates.append(utcDate(y, m)); closes.append(price)
            }
        }
        let r = StockSageSeasonality.compute(dates: dates, closes: closes, now: utcDate(2026, 7, 9))
        let june = StockSageSeasonality.stat(r, month: 6)!
        #expect(abs(june.avgReturn - 0.07) < 1e-9)
        #expect(abs(june.stdDev - 0.03) < 1e-9)
        #expect(june.samples == 3)
        #expect(june.tStat.map { abs($0 - 4.04145188432738) < 1e-6 } == true)
        // Flat months: zero dispersion with n≥2 → tStat nil (undefined, treated as consistent).
        let jan = StockSageSeasonality.stat(r, month: 1)!
        #expect(jan.stdDev == 0 && jan.tStat == nil)
    }
}
