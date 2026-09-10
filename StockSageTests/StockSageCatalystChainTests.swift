import Testing
import Foundation
@testable import StockSage

// MARK: - Catalyst chain order (W1, 2026-09-06)
//
// Every provider is a stub closure — no network, per STANDING RULES. Fixture triple per the
// step's own spec: Yahoo-hit; Yahoo-nil→projection; absent/short history→unchecked.

@Suite("StockSageCatalystChain (Massive → Yahoo → projection → unchecked)")
struct StockSageCatalystChainTests {
    private let now = Date(timeIntervalSince1970: 1_701_000_000)

    @Test func parsedErrorsCannotBecomeAnsweredSourcesOrRefreshStamps() async {
        let malformed = Data(#"{"error":"upstream unavailable"}"#.utf8)
        let outcome = await StockSageCatalystChain.resolve(now: now, yahooCalendar: {
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

    @Test func yahooHitShortCircuitsHistory() async {
        var historyCalled = false
        let outcome = await StockSageCatalystChain.resolve(
            now: now,
            yahooCalendar: { .answered(self.calInfo(daysFromNow: 15, rangeEndDays: 17, isEstimate: false)) },
            history: { historyCalled = true; return .answered([]) })
        #expect(outcome.status == .dateKnown)
        #expect(outcome.source == "yahoo calendarEvents")
        #expect(outcome.confirmed == true)   // isEstimate:false ⇒ confirmed:true
        #expect(outcome.earningsDate == now.addingTimeInterval(15 * 86_400))
        #expect(outcome.dateRangeEnd == now.addingTimeInterval(17 * 86_400))
        #expect(outcome.sourcesAsked == ["yahoo calendarEvents"])
        #expect(!historyCalled, "a Yahoo hit must short-circuit the history/projection step")
    }

    @Test func emptyYahooFallsThroughToProjectionWithThreeHistoryDates() async {
        // Hand-derived (mirrors StockSageCatalystProjectionTests): 3 dates → 2 gaps of 90 and
        // 92 days → median 91.
        let (d1, d2, d3) = threeHistoryDatesProjectingToTheFuture()
        let outcome = await StockSageCatalystChain.resolve(
            now: now, yahooCalendar: { .answered(nil) },
            history: { .answered([d1, d2, d3]) })
        #expect(outcome.status == .projected)
        #expect(outcome.source == "projection")
        #expect(outcome.confirmed == nil)
        #expect(outcome.earningsDate == d3.addingTimeInterval(91 * 86_400))
        #expect(outcome.dateRangeEnd == outcome.earningsDate?.addingTimeInterval(7 * 86_400))
        #expect(outcome.projectionBasis?.contains("median gap of last 3 quarter ends = 91 d from") == true)
        #expect(outcome.sourcesAsked == ["yahoo calendarEvents", "earnings history"])
    }

    @Test func yahooHistoryUsesQuarterEndUnitsInTheProjectionBasisString() async {
        // Yahoo history dates are fiscal quarter ends, so the basis must never call them reports.
        let (d1, d2, d3) = threeHistoryDatesProjectingToTheFuture()
        let outcome = await StockSageCatalystChain.resolve(
            now: now, yahooCalendar: { .answered(nil) }, history: { .answered([d1, d2, d3]) })
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
            now: now, yahooCalendar: { .answered(nil) },
            history: { .answered([d1, d2]) })
        #expect(outcome.status == .unchecked)
        #expect(outcome.earningsDate == nil)
        #expect(outcome.dateRangeEnd == nil)
        #expect(outcome.confirmed == nil)
        #expect(outcome.source == "—")
        #expect(outcome.projectionBasis == nil)
        #expect(outcome.sourcesAsked == ["yahoo calendarEvents", "earnings history"])
        #expect(outcome.anySourceAnswered, "every provider DID answer here — just with nothing usable")
    }

    @Test func emptyHistoryAlsoFallsThroughToUnchecked() async {
        let outcome = await StockSageCatalystChain.resolve(
            now: now, yahooCalendar: { .answered(nil) },
            history: { .answered([]) })
        #expect(outcome.status == .unchecked)
    }

    @Test func absentUSHistoryStagePreservesTheYahooAnswerWithoutAddingASource() async {
        let outcome = await StockSageCatalystChain.resolve(
            now: now, yahooCalendar: { .answered(nil) }, history: nil)
        #expect(outcome.status == .unchecked)
        #expect(outcome.anySourceAnswered)
        #expect(outcome.sourcesAsked == ["yahoo calendarEvents"])
    }

    // MARK: Blocker fix 2026-09-06 — a question NO source ever answered must never be recorded
    // as asked, and must leave `anySourceAnswered` false so the store refuses to stamp anything.

    @Test func everyProviderUnavailableLeavesAnySourceAnsweredFalseAndSourcesAskedEmpty() async {
        let outcome = await StockSageCatalystChain.resolve(
            now: now, yahooCalendar: { .unavailable }, history: { .unavailable })
        #expect(outcome.status == .unchecked)
        #expect(!outcome.anySourceAnswered, "nobody ever answered — this must not read as a checked negative")
        #expect(outcome.sourcesAsked.isEmpty, "an unreachable provider must never be recorded as asked")
    }

    @Test func aMixOfUnavailableAndAnsweredRecordsOnlyTheAnsweredSourceAndSetsAnySourceAnswered() async {
        // Yahoo reachable but empty and history unavailable — only the answered Yahoo source is recorded.
        let outcome = await StockSageCatalystChain.resolve(
            now: now, yahooCalendar: { .answered(nil) },
            history: { .unavailable })
        #expect(outcome.status == .unchecked)
        #expect(outcome.anySourceAnswered, "Yahoo DID answer even though history did not")
        #expect(outcome.sourcesAsked == ["yahoo calendarEvents"])
    }

    // MARK: Stale-date guard — mirrors StockSageStore.earningsRefreshOutcome's own `> -86_400` rule

    @Test func aStaleYahooDateFallsThroughToProjection() async {
        let (d1, d2, d3) = threeHistoryDatesProjectingToTheFuture()
        let outcome = await StockSageCatalystChain.resolve(
            now: now, yahooCalendar: { .answered(self.calInfo(daysFromNow: -2, isEstimate: true)) },
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
            now: now, yahooCalendar: { .answered(nil) },
            history: { .answered([d1, d2, d3]) })
        #expect(outcome.status == .unchecked, "a projection 9 days in the past must not be reported as a catalyst")
        #expect(outcome.earningsDate == nil)
        #expect(outcome.anySourceAnswered)
    }
}
