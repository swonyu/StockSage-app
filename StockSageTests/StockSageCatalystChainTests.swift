import Testing
import Foundation
@testable import StockSage

// MARK: - Catalyst chain order (W1, 2026-09-06)
//
// Every provider is a stub closure — no network, per STANDING RULES. Fixture triple per the
// step's own spec: EODHD-nil→Yahoo-hit; both-nil→projection; <3 history dates→unchecked.

@Suite("StockSageCatalystChain (EODHD → Yahoo → projection → unchecked)")
struct StockSageCatalystChainTests {
    private let now = Date(timeIntervalSince1970: 1_701_000_000)

    private func row(daysFromNow: Double) -> StockSageEODHDCalendar.Row {
        StockSageEODHDCalendar.Row(code: "AAPL.US", reportPeriod: nil,
                                   date: now.addingTimeInterval(daysFromNow * 86_400),
                                   beforeAfterMarket: "AfterMarket", estimate: nil, actual: nil)
    }

    private func calInfo(daysFromNow: Double, rangeEndDays: Double? = nil,
                         isEstimate: Bool) -> StockSageEarnings.EarningsCalendarInfo {
        StockSageEarnings.EarningsCalendarInfo(
            date: now.addingTimeInterval(daysFromNow * 86_400),
            dateRangeEnd: rangeEndDays.map { now.addingTimeInterval($0 * 86_400) }, isEstimate: isEstimate)
    }

    @Test func eodhdHitWinsAndShortCircuitsYahooAndHistory() async {
        var yahooCalled = false, historyCalled = false
        let outcome = await StockSageCatalystChain.resolve(
            now: now,
            eodhdCalendar: { self.row(daysFromNow: 10) },
            yahooCalendar: { yahooCalled = true; return self.calInfo(daysFromNow: 20, isEstimate: true) },
            history: { historyCalled = true; return [] })
        #expect(outcome.status == .dateKnown)
        #expect(outcome.source == "eodhd calendar")
        #expect(outcome.confirmed == false)   // documented rule: EODHD calendar rows are always confirmed:false
        #expect(outcome.earningsDate == now.addingTimeInterval(10 * 86_400))
        #expect(outcome.dateRangeEnd == nil)
        #expect(outcome.sourcesAsked == ["eodhd calendar"])
        #expect(outcome.projectionBasis == nil)
        #expect(!yahooCalled, "an EODHD hit must short-circuit Yahoo")
        #expect(!historyCalled, "an EODHD hit must short-circuit the history/projection step")
    }

    @Test func eodhdNilFallsThroughToYahooHitAndShortCircuitsHistory() async {
        var historyCalled = false
        let outcome = await StockSageCatalystChain.resolve(
            now: now,
            eodhdCalendar: { nil },
            yahooCalendar: { self.calInfo(daysFromNow: 15, rangeEndDays: 17, isEstimate: false) },
            history: { historyCalled = true; return [] })
        #expect(outcome.status == .dateKnown)
        #expect(outcome.source == "yahoo calendarEvents")
        #expect(outcome.confirmed == true)   // isEstimate:false ⇒ confirmed:true
        #expect(outcome.earningsDate == now.addingTimeInterval(15 * 86_400))
        #expect(outcome.dateRangeEnd == now.addingTimeInterval(17 * 86_400))
        #expect(outcome.sourcesAsked == ["eodhd calendar", "yahoo calendarEvents"])
        #expect(!historyCalled, "a Yahoo hit must short-circuit the history/projection step")
    }

    @Test func bothNilFallsThroughToProjectionWithThreeHistoryDates() async {
        // Hand-derived (mirrors StockSageCatalystProjectionTests): 3 dates → 2 gaps of 90 and
        // 92 days → median 91.
        let d1 = now.addingTimeInterval(-360 * 86_400)
        let d2 = d1.addingTimeInterval(90 * 86_400)
        let d3 = d2.addingTimeInterval(92 * 86_400)
        let outcome = await StockSageCatalystChain.resolve(
            now: now, eodhdCalendar: { nil }, yahooCalendar: { nil }, history: { [d1, d2, d3] })
        #expect(outcome.status == .projected)
        #expect(outcome.source == "projection")
        #expect(outcome.confirmed == nil)
        #expect(outcome.earningsDate == d3.addingTimeInterval(91 * 86_400))
        #expect(outcome.dateRangeEnd == outcome.earningsDate?.addingTimeInterval(7 * 86_400))
        #expect(outcome.projectionBasis?.contains("median gap of last 3 reports = 91 d from") == true)
        #expect(outcome.sourcesAsked == ["eodhd calendar", "yahoo calendarEvents", "earnings history"])
    }

    @Test func fewerThanThreeHistoryDatesFallsThroughToUnchecked() async {
        let d1 = now.addingTimeInterval(-360 * 86_400)
        let d2 = d1.addingTimeInterval(90 * 86_400)
        let outcome = await StockSageCatalystChain.resolve(
            now: now, eodhdCalendar: { nil }, yahooCalendar: { nil }, history: { [d1, d2] })
        #expect(outcome.status == .unchecked)
        #expect(outcome.earningsDate == nil)
        #expect(outcome.dateRangeEnd == nil)
        #expect(outcome.confirmed == nil)
        #expect(outcome.source == "—")
        #expect(outcome.projectionBasis == nil)
        #expect(outcome.sourcesAsked == ["eodhd calendar", "yahoo calendarEvents", "earnings history"])
    }

    @Test func emptyHistoryAlsoFallsThroughToUnchecked() async {
        let outcome = await StockSageCatalystChain.resolve(
            now: now, eodhdCalendar: { nil }, yahooCalendar: { nil }, history: { [] })
        #expect(outcome.status == .unchecked)
    }

    // MARK: Stale-date guard — mirrors StockSageStore.earningsRefreshOutcome's own `> -86_400` rule

    @Test func aStaleEodhdRowFallsThroughToYahoo() async {
        // Exactly 2 days in the past is well outside the usability guard.
        let outcome = await StockSageCatalystChain.resolve(
            now: now, eodhdCalendar: { self.row(daysFromNow: -2) },
            yahooCalendar: { self.calInfo(daysFromNow: 5, isEstimate: true) }, history: { [] })
        #expect(outcome.status == .dateKnown)
        #expect(outcome.source == "yahoo calendarEvents")
    }

    @Test func aStaleYahooDateFallsThroughToProjection() async {
        let d1 = now.addingTimeInterval(-360 * 86_400)
        let d2 = d1.addingTimeInterval(90 * 86_400)
        let d3 = d2.addingTimeInterval(92 * 86_400)
        let outcome = await StockSageCatalystChain.resolve(
            now: now, eodhdCalendar: { nil },
            yahooCalendar: { self.calInfo(daysFromNow: -2, isEstimate: true) },
            history: { [d1, d2, d3] })
        #expect(outcome.status == .projected)
    }
}
