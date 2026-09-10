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

    @Test func parsedErrorsCannotBecomeAnsweredSourcesOrRefreshStamps() async {
        let malformed = Data(#"{"error":"upstream unavailable"}"#.utf8)
        let outcome = await StockSageCatalystChain.resolve(now: now, eodhdCalendar: {
            guard let rows = StockSageEODHDCalendar.parseCalendar(malformed) else { return .unavailable }
            return .answered(StockSageEODHDCalendar.nextRow(rows, now: now))
        }, yahooCalendar: {
            switch StockSageEarnings.parseCalendarOutcome(malformed) {
            case .answered(let info): return .answered(info)
            case .unavailable: return .unavailable
            }
        }, history: {
            guard let dates = StockSageEarnings.parseEarningsHistory(malformed) else { return .unavailable }
            return .answered(dates)
        })
        #expect(outcome.status == .unchecked)
        #expect(!outcome.anySourceAnswered)
        #expect(outcome.sourcesAsked.isEmpty)
        #expect(outcome.earningsDate == nil)

        let empty = Data(#"{"quoteSummary":{"result":[{"calendarEvents":{"earnings":{"earningsDate":[]}}}]}}"#.utf8)
        for data in [malformed, empty] {
            let refresh = await StockSageStore.earningsRefreshOutcome(checkedAt: nil, now: now) {
                switch StockSageEarnings.parseCalendarOutcome(data) {
                case .answered(let info): return .answered(info?.date)
                case .unavailable: return .unavailable
                }
            }
            #expect((refresh?.checkedAt == now) == (data == empty))
            #expect(refresh?.earningsDate == nil)
        }
    }

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

    /// 3 history dates → 2 gaps of 90 and 92 days → median 91, with the LAST date recent enough
    /// (1 day before `now`) that the projected next date (last + 91d) lands ~90 days in the
    /// FUTURE — a genuinely live scenario, distinct from `aLapsedProjectionFallsThroughTo...`
    /// below, which deliberately ages the same gap pattern into the past.
    private func threeHistoryDatesProjectingToTheFuture() -> (Date, Date, Date) {
        let d3 = now.addingTimeInterval(-1 * 86_400)
        let d2 = d3.addingTimeInterval(-92 * 86_400)
        let d1 = d2.addingTimeInterval(-90 * 86_400)
        return (d1, d2, d3)
    }

    @Test func eodhdHitWinsAndShortCircuitsYahooAndHistory() async {
        var yahooCalled = false, historyCalled = false
        let outcome = await StockSageCatalystChain.resolve(
            now: now,
            eodhdCalendar: { .answered(self.row(daysFromNow: 10)) },
            yahooCalendar: { yahooCalled = true; return .answered(self.calInfo(daysFromNow: 20, isEstimate: true)) },
            history: { historyCalled = true; return .answered([]) })
        #expect(outcome.status == .dateKnown)
        #expect(outcome.source == "eodhd calendar")
        #expect(outcome.confirmed == false)   // documented rule: EODHD calendar rows are always confirmed:false
        #expect(outcome.earningsDate == now.addingTimeInterval(10 * 86_400))
        #expect(outcome.dateRangeEnd == nil)
        #expect(outcome.sourcesAsked == ["eodhd calendar"])
        #expect(outcome.projectionBasis == nil)
        #expect(outcome.anySourceAnswered)
        #expect(!yahooCalled, "an EODHD hit must short-circuit Yahoo")
        #expect(!historyCalled, "an EODHD hit must short-circuit the history/projection step")
    }

    @Test func eodhdNilFallsThroughToYahooHitAndShortCircuitsHistory() async {
        var historyCalled = false
        let outcome = await StockSageCatalystChain.resolve(
            now: now,
            eodhdCalendar: { .answered(nil) },
            yahooCalendar: { .answered(self.calInfo(daysFromNow: 15, rangeEndDays: 17, isEstimate: false)) },
            history: { historyCalled = true; return .answered([]) })
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
        let (d1, d2, d3) = threeHistoryDatesProjectingToTheFuture()
        let outcome = await StockSageCatalystChain.resolve(
            now: now, eodhdCalendar: { .answered(nil) }, yahooCalendar: { .answered(nil) },
            history: { .answered([d1, d2, d3]) })
        #expect(outcome.status == .projected)
        #expect(outcome.source == "projection")
        #expect(outcome.confirmed == nil)
        #expect(outcome.earningsDate == d3.addingTimeInterval(91 * 86_400))
        #expect(outcome.dateRangeEnd == outcome.earningsDate?.addingTimeInterval(7 * 86_400))
        #expect(outcome.projectionBasis?.contains("median gap of last 3 reports = 91 d from") == true)
        #expect(outcome.sourcesAsked == ["eodhd calendar", "yahoo calendarEvents", "earnings history"])
    }

    @Test func historyUnitLabelFeedsTheProjectionBasisString() async {
        // Same fixture as above but a caller (the store, for a Tadawul symbol) names the history
        // dates "quarter ends" instead of the default "reports" — the basis string must say so,
        // never claim more than the source actually supports (major fix 2026-09-06).
        let (d1, d2, d3) = threeHistoryDatesProjectingToTheFuture()
        let outcome = await StockSageCatalystChain.resolve(
            now: now, eodhdCalendar: { .answered(nil) }, yahooCalendar: { .answered(nil) },
            historyUnitLabel: "quarter ends", history: { .answered([d1, d2, d3]) })
        #expect(outcome.projectionBasis?.contains("median gap of last 3 quarter ends = 91 d from") == true)
        let brief = StockSageCatalystWatch.brief(for: SageFix.idea("2222.SR", conviction: 0.5),
            inputs: .init(now: now, catalystProjectedDate: outcome.earningsDate,
                          catalystProjectionBasis: outcome.projectionBasis))
        #expect(brief.primary.kind == .projectedEarnings)
        #expect(brief.primary.date == outcome.earningsDate)
        #expect(brief.primary.why == [outcome.projectionBasis!])
        #expect(brief.primary.headline.contains("projected from recorded history, not announced"))
        #expect(!brief.primary.headline.contains("prior reports"))
        let facts = StockSageCatalystNarrator.facts(for: brief)
        #expect(facts.contains("Catalyst: " + brief.primary.headline))
        #expect(facts.contains { $0.contains("quarter ends") })
        #expect(!facts.contains { $0.contains("prior reports") })
    }

    @Test func fewerThanThreeHistoryDatesFallsThroughToUnchecked() async {
        let d1 = now.addingTimeInterval(-360 * 86_400)
        let d2 = d1.addingTimeInterval(90 * 86_400)
        let outcome = await StockSageCatalystChain.resolve(
            now: now, eodhdCalendar: { .answered(nil) }, yahooCalendar: { .answered(nil) },
            history: { .answered([d1, d2]) })
        #expect(outcome.status == .unchecked)
        #expect(outcome.earningsDate == nil)
        #expect(outcome.dateRangeEnd == nil)
        #expect(outcome.confirmed == nil)
        #expect(outcome.source == "—")
        #expect(outcome.projectionBasis == nil)
        #expect(outcome.sourcesAsked == ["eodhd calendar", "yahoo calendarEvents", "earnings history"])
        #expect(outcome.anySourceAnswered, "every provider DID answer here — just with nothing usable")
    }

    @Test func emptyHistoryAlsoFallsThroughToUnchecked() async {
        let outcome = await StockSageCatalystChain.resolve(
            now: now, eodhdCalendar: { .answered(nil) }, yahooCalendar: { .answered(nil) },
            history: { .answered([]) })
        #expect(outcome.status == .unchecked)
    }

    // MARK: Blocker fix 2026-09-06 — a question NO source ever answered must never be recorded
    // as asked, and must leave `anySourceAnswered` false so the store refuses to stamp anything.

    @Test func everyProviderUnavailableLeavesAnySourceAnsweredFalseAndSourcesAskedEmpty() async {
        let outcome = await StockSageCatalystChain.resolve(
            now: now, eodhdCalendar: { .unavailable }, yahooCalendar: { .unavailable },
            history: { .unavailable })
        #expect(outcome.status == .unchecked)
        #expect(!outcome.anySourceAnswered, "nobody ever answered — this must not read as a checked negative")
        #expect(outcome.sourcesAsked.isEmpty, "an unreachable provider must never be recorded as asked")
    }

    @Test func aMixOfUnavailableAndAnsweredRecordsOnlyTheAnsweredSourceAndSetsAnySourceAnswered() async {
        // EODHD unreachable (never asked), Yahoo reachable but empty, history never reached
        // (short-circuited by nothing — Yahoo's `.answered(nil)` falls through to history, which
        // is also unavailable here) — only "yahoo calendarEvents" should ever be recorded.
        let outcome = await StockSageCatalystChain.resolve(
            now: now, eodhdCalendar: { .unavailable }, yahooCalendar: { .answered(nil) },
            history: { .unavailable })
        #expect(outcome.status == .unchecked)
        #expect(outcome.anySourceAnswered, "Yahoo DID answer, even though EODHD and history did not")
        #expect(outcome.sourcesAsked == ["yahoo calendarEvents"])
    }

    // MARK: Stale-date guard — mirrors StockSageStore.earningsRefreshOutcome's own `> -86_400` rule

    @Test func aStaleEodhdRowFallsThroughToYahoo() async {
        // Exactly 2 days in the past is well outside the usability guard.
        let outcome = await StockSageCatalystChain.resolve(
            now: now, eodhdCalendar: { .answered(self.row(daysFromNow: -2)) },
            yahooCalendar: { .answered(self.calInfo(daysFromNow: 5, isEstimate: true)) },
            history: { .answered([]) })
        #expect(outcome.status == .dateKnown)
        #expect(outcome.source == "yahoo calendarEvents")
    }

    @Test func aStaleYahooDateFallsThroughToProjection() async {
        let (d1, d2, d3) = threeHistoryDatesProjectingToTheFuture()
        let outcome = await StockSageCatalystChain.resolve(
            now: now, eodhdCalendar: { .answered(nil) },
            yahooCalendar: { .answered(self.calInfo(daysFromNow: -2, isEstimate: true)) },
            history: { .answered([d1, d2, d3]) })
        #expect(outcome.status == .projected)
    }

    // MARK: Major fix 2026-09-06 — a projection that has already lapsed must not be reported as
    // an upcoming catalyst; the symbol must fall through to the honest `.unchecked` instead.

    @Test func aLapsedProjectionFallsThroughToUncheckedRatherThanAPastCatalyst() async {
        // 3 history dates 91 days apart, ending 100 days before `now` — the projected next date
        // (last + 91d) lands 9 days IN THE PAST relative to `now`, well outside the `> -86_400`
        // guard, so this must NOT surface as `.projected`.
        let d3 = now.addingTimeInterval(-100 * 86_400)
        let d2 = d3.addingTimeInterval(-91 * 86_400)
        let d1 = d2.addingTimeInterval(-91 * 86_400)
        let outcome = await StockSageCatalystChain.resolve(
            now: now, eodhdCalendar: { .answered(nil) }, yahooCalendar: { .answered(nil) },
            history: { .answered([d1, d2, d3]) })
        #expect(outcome.status == .unchecked, "a projection 9 days in the past must not be reported as a catalyst")
        #expect(outcome.earningsDate == nil)
        #expect(outcome.anySourceAnswered)
    }
}
