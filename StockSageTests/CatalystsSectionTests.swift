import Testing
import SwiftUI
@testable import StockSage

// Pure-helper pins for the catalysts tab view (owner request 2026-09-06, build step
// C3-view). Everything else in CatalystsSection needs a running app (it renders
// StockSageIdea/StockSageStore state); helpers and connection lifecycle transitions
// are plain values so they can be checked without owner settings or real network calls.

@Suite("CatalystsSection — pure view helpers")
struct CatalystsSectionTests {

    @Test(arguments: ["search", "action", "strength"], [false, true])
    @MainActor func filteredIdeasNeedFilterRecoveryNotAnotherScan(filter: String, loading: Bool) throws {
        let source = [SageFix.idea("AAPL", conviction: 0.6)]
        let visible = StockSageIdeaProjection.displayed(source, sort: .signal,
            filter: filter == "action" ? .sells : .all,
            minConviction: filter == "strength" ? 0.8 : 0,
            search: filter == "search" ? "ABSENT" : "", regime: nil, earnings: [:],
            liquidity: [:], seasonality: [:], holds: .defaults, calibration: nil)
        try #require(visible.isEmpty && source.count == 1)
        let detail = MarketsView.ideasEmptyMessage(search: filter == "search" ? "ABSENT" : "",
            minConviction: filter == "strength" ? 0.8 : 0,
            filter: filter == "action" ? .sells : .all, sourceIsEmpty: false)
        let recovery = try #require(CatalystsSection.ideasRecoveryState(visibleCount: visible.count,
            totalCount: source.count, loading: loading, filteredMessage: detail))
        #expect(recovery.message == detail && recovery.action == "Open Ideas")
    }

    @Test("a saved rules sort can exclude ideas without any active filter")
    @MainActor func sortExcludedIdeasAreNotAnEmptySource() throws {
        let source = [SageFix.idea("AAPL", conviction: 0.6, rr: nil)]
        func project(_ sort: StockSageIdeaProjection.Sort) -> [StockSageIdea] {
            StockSageIdeaProjection.displayed(source, sort: sort, filter: .all,
                minConviction: 0, search: "", regime: nil, earnings: [:], liquidity: [:],
                seasonality: [:], holds: .defaults, calibration: nil)
        }
        #expect(project(.signal).count == 1)
        try #require(project(.momentumWeighted).isEmpty)
        let message = MarketsView.ideasEmptyMessage(search: "", minConviction: 0,
            filter: .all, sourceIsEmpty: false)
        #expect(message == "No ideas qualify for this view — try a different rules sort.")
        #expect(MarketsView.ideasEmptyMessage(search: "", minConviction: 0,
            filter: .all, sourceIsEmpty: true) == "No ideas in this scan.")
        let recovery = try #require(CatalystsSection.ideasRecoveryState(visibleCount: 0,
            totalCount: source.count, loading: false, filteredMessage: message))
        #expect(recovery.message == message && recovery.action == "Open Ideas")
    }

    @Test(arguments: [false, true])
    func catalystRecoveryDistinguishesAnEmptyScanFromLoading(loading: Bool) throws {
        let recovery = try #require(CatalystsSection.ideasRecoveryState(visibleCount: 0,
            totalCount: 0, loading: loading, filteredMessage: "Do not display a filter explanation"))
        #expect(recovery.message == (loading ? "Ideas scan in progress. Results will appear here as ideas become available."
            : "No ideas yet. Open Ideas to choose and run a scan."))
        #expect(recovery.action == "Open Ideas")
        #expect(CatalystsSection.ideasRecoveryState(visibleCount: 1, totalCount: 2,
            loading: loading, filteredMessage: "Some names hidden") == nil)
    }

    @Test("late connection probes cannot publish for new settings or clear a newer spinner")
    @MainActor func connectionProbeCompletionBelongsToItsRequest() async {
        let a = ["localServerOnly", "http://127.0.0.1:8765", "model-A"]
        let b = ["localServerOnly", "http://127.0.0.1:8765", "model-B"]
        let reachable = StockSageLocalModelServer.Probe(reachable: true, isOllama: false,
            models: ["model-A"], hasModel: true, detail: "model-A present")
        var state = CatalystsSection.ConnectionProbeState()
        let old = state.begin(settings: a)
        let latest = state.begin(settings: b)
        state.finish(reachable, request: old, currentSettings: b, cancelled: false)
        #expect(state.current(for: b) == nil)
        #expect(state.probing)
        #expect(!StockSageCatalystNarrator.explainAvailable(backend: .localServerOnly,
            onDevice: .unavailable("fixture"), probe: state.current(for: b)))
        state.finish(nil, request: latest, currentSettings: b, cancelled: false)
        #expect(!state.probing && state.current(for: b) == nil)

        // A single matching request works; a settings edit hides it BEFORE another task starts.
        let matching = state.begin(settings: a)
        state.finish(reachable, request: matching, currentSettings: a, cancelled: false)
        #expect(state.current(for: a) == reachable)
        for settings in [b, ["localServerOnly", "http://127.0.0.1:11434", "model-A"],
                         ["off", a[1], a[2]], ["onDeviceOnly", a[1], a[2]]] {
            #expect(state.current(for: settings) == nil && !state.isProbing(for: settings))
        }

        // Same-settings overlap still needs request identity, not only settings equality.
        let sameOld = state.begin(settings: a)
        let sameNew = state.begin(settings: a)
        #expect(state.current(for: a) == nil)
        state.finish(reachable, request: sameOld, currentSettings: a, cancelled: false)
        #expect(state.current(for: a) == nil && state.isProbing(for: a))
        state.finish(nil, request: sameNew, currentSettings: a, cancelled: false)
        state.finish(reachable, request: sameOld, currentSettings: a, cancelled: false)
        #expect(state.current(for: a) == nil && !state.probing)

        // Cancellation, a settings edit during await, and disappearance all reject late replies.
        for cancelled in [false, true] {
            let id = state.begin(settings: a)
            state.finish(reachable, request: id, currentSettings: cancelled ? a : b, cancelled: cancelled)
            #expect(state.current(for: a) == nil && !state.probing)
        }
        let disappeared = state.begin(settings: a)
        state = .init()
        state.finish(reachable, request: disappeared, currentSettings: a, cancelled: false)
        #expect(state.current(for: a) == nil && !state.probing)
        #expect(await StockSageCatalystNarrator.probeServer(config: nil) == nil)

        // Equal values after A→B→A still carry a new in-app revision.
        let firstRevision = a + ["revision-1"]
        let nextRevision = a + ["revision-2"]
        let roundTrip = state.begin(settings: firstRevision)
        state.finish(reachable, request: roundTrip, currentSettings: nextRevision, cancelled: false)
        #expect(state.current(for: nextRevision) == nil && !state.probing)
    }

    @Test("an explanation is current only for the facts AND settings that requested it")
    func narrationSettingsAndFactsMustMatch() {
        let saved = ["localServerOnly", "http://127.0.0.1:8765", "model-A"]
        let facts = ["Price: 100"]
        #expect(CatalystsSection.narrationRefreshReason(savedFacts: facts, currentFacts: facts,
            savedSettings: saved, currentSettings: saved) == nil)
        for (index, value) in [(0, "off"), (0, "onDeviceOnly"), (0, "auto"),
                                (1, "http://127.0.0.1:11434"), (2, "model-B")] {
            var current = saved
            current[index] = value
            #expect(CatalystsSection.narrationRefreshReason(savedFacts: facts, currentFacts: facts,
                savedSettings: saved, currentSettings: current) != nil)
        }
        #expect(CatalystsSection.narrationRefreshReason(savedFacts: facts, currentFacts: facts,
            savedSettings: nil, currentSettings: saved) != nil)
        #expect(CatalystsSection.narrationRefreshReason(savedFacts: facts, currentFacts: ["Price: 101"],
            savedSettings: saved, currentSettings: saved) != nil)
        #expect(CatalystsSection.narrationRefreshReason(savedFacts: nil, currentFacts: facts,
            savedSettings: saved, currentSettings: saved) != nil)
    }

    @Test("one icon per catalyst Kind — all twelve cases")
    func iconPerKind() {
        #expect(CatalystsSection.iconName(for: .earnings) == "calendar.badge.exclamationmark")
        #expect(CatalystsSection.iconName(for: .volumeMove) == "bolt.horizontal.circle.fill")
        #expect(CatalystsSection.iconName(for: .extreme) == "arrow.up.right.circle")
        #expect(CatalystsSection.iconName(for: .regime) == "gauge.with.needle")
        #expect(CatalystsSection.iconName(for: .seasonality) == "calendar")
        #expect(CatalystsSection.iconName(for: .none) == "questionmark.circle")
        #expect(CatalystsSection.iconName(for: .projectedEarnings) == "calendar.badge.clock")   // W1, 2026-09-06
        #expect(CatalystsSection.iconName(for: .filing8K) == "doc.text.magnifyingglass")
        #expect(CatalystsSection.iconName(for: .ratingChange) == "person.text.rectangle")
        #expect(CatalystsSection.iconName(for: .guidanceChange) == "text.bubble")
        #expect(CatalystsSection.iconName(for: .exDividend) == "calendar.badge.plus")
        #expect(CatalystsSection.iconName(for: .insiderTrade) == "person.crop.circle.badge.clock")
    }

    @Test("action capsule fill matches the DS palette token per action")
    func actionFillMatchesPalette() {
        #expect(CatalystsSection.actionFill(for: .buy) == DS.Palette.successSoft)
        #expect(CatalystsSection.actionFill(for: .strongBuy) == DS.Palette.successSoft)
        #expect(CatalystsSection.actionFill(for: .hold) == DS.Palette.warningSoft)
        #expect(CatalystsSection.actionFill(for: .avoid) == Color.white.opacity(0.22))
        #expect(CatalystsSection.actionFill(for: .reduce) == DS.Palette.dangerSoft)
        #expect(CatalystsSection.actionFill(for: .sell) == DS.Palette.dangerSoft)
        // The gate must actually distinguish avoid from the two pastel tones it sits between.
        #expect(CatalystsSection.actionFill(for: .avoid) != DS.Palette.warningSoft)
    }

    @Test("Mode titles are Cards / Calendar, in that order")
    func modeTitles() {
        #expect(CatalystsSection.Mode.allCases.map(\.title) == ["Cards", "Calendar"])
    }

    #if os(macOS)
    // MARK: Catalyst period navigation — synthetic/offline contract

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: year, month: month, day: day, hour: hour))!
    }

    private func entry(_ symbol: String, _ kind: StockSageCatalystWatch.Kind, _ date: Date?,
                       negative: Bool = false, projected: Bool = false)
        -> StockSageCatalystWatch.CalendarEntry {
        let idea = SageFix.idea(symbol, conviction: 0.5)
        let item = StockSageCatalystWatch.Item(
            symbol: symbol, kind: kind, headline: "\(symbol) headline", date: date,
            why: ["Synthetic rationale."], watch: "Synthetic watch.", weight: .low,
            source: "synthetic source", caveat: nil)
        return .init(bucket: negative ? .checkedNoCatalyst : .today, item: item, idea: idea,
                     isNegativeRecord: negative, isProjected: projected)
    }

    @Test("period titles are Today / This Week / This Month")
    func periodTitles() {
        #expect(CatalystsSection.Period.allCases.map(\.title) == ["Today", "This Week", "This Month"])
    }

    @Test("UTC periods use start-inclusive/end-exclusive civil-day boundaries")
    func periodIntervalsAndMembership() {
        let now = utc(2026, 9, 9, 12)
        let today = CatalystsSection.periodInterval(.today, now: now)
        let week = CatalystsSection.periodInterval(.thisWeek, now: now)
        let month = CatalystsSection.periodInterval(.thisMonth, now: now)

        #expect(today == DateInterval(start: utc(2026, 9, 9), end: utc(2026, 9, 10)))
        #expect(week == DateInterval(start: utc(2026, 9, 7), end: utc(2026, 9, 14)))
        #expect(month == DateInterval(start: utc(2026, 9, 1), end: utc(2026, 10, 1)))
        for (period, interval) in [(CatalystsSection.Period.today, today),
                                   (.thisWeek, week), (.thisMonth, month)] {
            #expect(CatalystsSection.contains(interval.start, in: period, now: now))
            #expect(CatalystsSection.contains(interval.end.addingTimeInterval(-0.001), in: period, now: now))
            #expect(!CatalystsSection.contains(interval.end, in: period, now: now))
            #expect(!CatalystsSection.contains(interval.start.addingTimeInterval(-0.001), in: period, now: now))
        }
        #expect(CatalystsSection.periodRangeLabel(.today, now: now) == "Sep 9, 2026")
        #expect(CatalystsSection.periodRangeLabel(.thisWeek, now: now) == "Sep 7, 2026 – Sep 13, 2026")
        #expect(CatalystsSection.periodRangeLabel(.thisMonth, now: now) == "Sep 1, 2026 – Sep 30, 2026")
    }

    @Test("week crosses Dec/Jan and month uses leap and non-leap February")
    func crossYearAndMonthLengthBoundaries() {
        #expect(CatalystsSection.periodInterval(.thisWeek, now: utc(2027, 1, 1, 18))
            == DateInterval(start: utc(2026, 12, 28), end: utc(2027, 1, 4)))
        #expect(CatalystsSection.periodInterval(.thisMonth, now: utc(2028, 2, 14))
            == DateInterval(start: utc(2028, 2, 1), end: utc(2028, 3, 1)))
        #expect(CatalystsSection.periodInterval(.thisMonth, now: utc(2027, 2, 14))
            == DateInterval(start: utc(2027, 2, 1), end: utc(2027, 3, 1)))
        #expect(CatalystsSection.periodInterval(.thisMonth, now: utc(2027, 1, 14))
            == DateInterval(start: utc(2027, 1, 1), end: utc(2027, 2, 1)))
        #expect(CatalystsSection.periodInterval(.today, now: utc(2026, 3, 8, 12))
            == DateInterval(start: utc(2026, 3, 8), end: utc(2026, 3, 9)),
            "US DST changes must not move UTC catalyst boundaries")
    }

    @Test("period entries exclude undated and negative records and order upcoming before prior days")
    func periodEntriesAreTruthfulAndStable() {
        let now = utc(2026, 9, 9, 12)
        let entries = [
            entry("OLD", .ratingChange, utc(2026, 9, 1)),
            entry("PAST", .earnings, utc(2026, 9, 8)),
            entry("BETA", .filing8K, utc(2026, 9, 9)),
            entry("ALFA", .earnings, utc(2026, 9, 9)),
            entry("NEXT", .exDividend, utc(2026, 9, 10)),
            entry("END", .earnings, utc(2026, 10, 1)),
            entry("CHECK", .none, utc(2026, 9, 9), negative: true),
            entry("UNDATED", .volumeMove, nil),
        ]
        let shown = CatalystsSection.periodEntries(entries, period: .thisMonth, now: now)
        #expect(shown.map(\.idea.symbol) == ["ALFA", "BETA", "NEXT", "PAST", "OLD"])
        #expect(!shown.contains { $0.isNegativeRecord || $0.item.date == nil || $0.item.kind == .none })
        #expect(!shown.contains { $0.idea.symbol == "END" })
    }

    @Test("a secondary period event matches without changing the original primary")
    func secondaryMatchKeepsOriginalBrief() {
        let now = utc(2026, 9, 9, 12)
        let idea = SageFix.idea("MIX", conviction: 0.5)
        let outside = entry("MIX", .earnings, utc(2026, 10, 2)).item
        let inside = entry("MIX", .ratingChange, utc(2026, 9, 9)).item
        let undated = entry("MIX", .volumeMove, nil).item
        let brief = StockSageCatalystWatch.Brief(
            idea: idea, primary: outside, secondary: [inside, undated])

        let calendarRows = CatalystsSection.periodEntries(
            StockSageCatalystWatch.calendar([brief], now: now), period: .today, now: now)
        #expect(calendarRows.map(\.item.kind) == [.ratingChange])
        let cards = CatalystsSection.matchingBriefs([brief], entries: calendarRows)
        #expect(cards.count == calendarRows.count)
        #expect(cards.count == 1 && cards[0].primary.kind == .earnings)
    }

    @Test("scheduled/report status never turns a passed date into a reported result")
    func eventStatusCopy() {
        let now = utc(2026, 9, 9, 12)
        #expect(CatalystsSection.eventStatus(entry("FUT", .earnings, utc(2026, 9, 10)), now: now)
            == "Scheduled / estimated")
        #expect(CatalystsSection.eventStatus(entry("OLD", .earnings, utc(2026, 9, 8)), now: now)
            == "Date passed — outcome unverified")
        #expect(CatalystsSection.eventStatus(entry("FILE", .filing8K, utc(2026, 9, 8)), now: now)
            == "Reported")
        #expect(CatalystsSection.eventStatus(
            entry("PROJ", .projectedEarnings, utc(2026, 9, 10), projected: true), now: now)
            == "Projected from history — not announced")
        #expect(CatalystsSection.periodHeadline(
            entry("OLD", .earnings, utc(2026, 9, 8)).item, now: now) == "Earnings date")

        let groups = CatalystsSection.periodDayGroups([
            entry("EARN", .earnings, utc(2026, 9, 10)),
            entry("RATE", .ratingChange, utc(2026, 9, 10)),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].scheduled.map(\.idea.symbol) == ["EARN"])
        #expect(groups[0].reported.map(\.idea.symbol) == ["RATE"])
    }

    @Test("off-period dated briefs retain access to their full coverage and actions")
    func offPeriodCoverageRemainsReachable() {
        let outside = StockSageCatalystWatch.Brief(
            idea: SageFix.idea("OUTSIDE", conviction: 0.5),
            primary: entry("OUTSIDE", .earnings, utc(2026, 10, 2)).item, secondary: [])
        #expect(CatalystsSection.periodEntries(StockSageCatalystWatch.calendar([outside], now: utc(2026, 9, 9)),
            period: .thisWeek, now: utc(2026, 9, 9)).isEmpty)
        #expect(CatalystsSection.briefsNeedingCoverage([outside], excluding: []).map(\.id) == ["OUTSIDE"])
        #expect(CatalystsSection.briefsNeedingCoverage([outside], excluding: ["OUTSIDE"]).isEmpty)
    }

    @Test("period counts separate provider dates from history projections, including mixed rows")
    func periodCountsDoNotConfirmProjections() {
        let observed = entry("OBS", .earnings, utc(2026, 9, 9))
        let projected = entry("PROJ", .projectedEarnings, utc(2026, 9, 9), projected: true)
        for (rows, label) in [
            ([], "0 provider-dated · 0 projected (not announced)"),
            ([observed], "1 provider-dated · 0 projected (not announced)"),
            ([projected], "0 provider-dated · 1 projected (not announced)"),
            ([observed, projected], "1 provider-dated · 1 projected (not announced)")
        ] {
            #expect(CatalystsSection.periodCountLabel(rows) == label)
        }
    }

    @Test("unmatched undated and none briefs remain available as trailing disclosures")
    func trailingContextKeepsUnknownAndUndatedCoverage() {
        let now = utc(2026, 9, 9, 12)
        let match = StockSageCatalystWatch.Brief(
            idea: SageFix.idea("MATCH", conviction: 0.5),
            primary: entry("MATCH", .earnings, utc(2026, 9, 9)).item,
            secondary: [entry("MATCH", .volumeMove, nil).item])
        let undated = StockSageCatalystWatch.brief(
            for: SageFix.idea("UND", conviction: 0.5),
            inputs: .init(volumeMove: StockSageCatalyst.Signal(
                symbol: "UND", rvol: 3, priceChangePct: 5, tier: .notable,
                likelyMechanicalFlow: false, caveat: StockSageCatalyst.caveat), now: now))
        let unknown = StockSageCatalystWatch.brief(
            for: SageFix.idea("NONE", conviction: 0.5), inputs: .init(now: now))
        let checked = StockSageCatalystWatch.brief(
            for: SageFix.idea("CHECK", conviction: 0.5),
            inputs: .init(earningsCheckedAt: now, now: now,
                          catalystSourcesAsked: ["yahoo calendarEvents"]))
        let briefs = [match, undated, unknown, checked]
        let matchingEntries = CatalystsSection.periodEntries(
            StockSageCatalystWatch.calendar(briefs, now: now), period: .today, now: now)
        let matchingIDs = Set(CatalystsSection.matchingBriefs(
            briefs, entries: matchingEntries).map(\.id))

        #expect(matchingIDs == Set(["MATCH"]))
        #expect(CatalystsSection.briefsWithUndatedContext(briefs, excluding: matchingIDs).map(\.id) == ["UND"])
        #expect(CatalystsSection.briefsWithUndatedContext(briefs, excluding: []).map(\.id)
            == ["MATCH", "UND"], "Calendar keeps undated context even for a stock with a period match")
        let disclosedIDs = matchingIDs.union(CatalystsSection.briefsWithUndatedContext(
            briefs, excluding: matchingIDs).map(\.id))
        #expect(CatalystsSection.briefsNeedingCoverage(briefs, excluding: disclosedIDs).map(\.id)
            == ["NONE", "CHECK"])
    }
    #endif

    // MARK: A5 — negative-record calendar row styling (keyed ONLY on the engine's isNegativeRecord flag)

    @Test("negative-record badge reads 'No known catalyst'; a real catalyst gets no badge")
    func negativeRecordBadge() {
        #expect(CatalystsSection.negativeRecordBadge(isNegativeRecord: true) == "No known catalyst")
        #expect(CatalystsSection.negativeRecordBadge(isNegativeRecord: false) == nil)
    }

    @Test("negative-record row color is the dimmer DS.Palette.textSecondary; a real row is textPrimary")
    func negativeRecordRowColor() {
        #expect(CatalystsSection.calendarRowColor(isNegativeRecord: true) == DS.Palette.textSecondary)
        #expect(CatalystsSection.calendarRowColor(isNegativeRecord: false) == DS.Palette.textPrimary)
        // The gate must actually dim, not merely differ — pin against the raw danger tones too so
        // a future edit can't quietly swap in a warning/danger tint for "no catalyst" (neutral).
        #expect(CatalystsSection.calendarRowColor(isNegativeRecord: true) != DS.Palette.danger)
        #expect(CatalystsSection.calendarRowColor(isNegativeRecord: true) != DS.Palette.dangerSoft)
    }

    @Test("negative-record row opacity dims below full; a real row stays at full opacity")
    func negativeRecordRowOpacity() {
        #expect(CatalystsSection.calendarRowOpacity(isNegativeRecord: true) == 0.6)
        #expect(CatalystsSection.calendarRowOpacity(isNegativeRecord: false) == 1.0)
        #expect(CatalystsSection.calendarRowOpacity(isNegativeRecord: true) < CatalystsSection.calendarRowOpacity(isNegativeRecord: false))
    }

    // MARK: Major fix 2026-09-06 — the empty state must not be fooled by negative records alone

    private static let now = Date(timeIntervalSince1970: 1_757_000_000)

    @Test("a calendar of ONLY dated 'none known' negative records reports no dated catalysts")
    func hasDatedCatalystsIsFalseForOnlyNegativeRecords() {
        let checked = StockSageCatalystWatch.brief(for: SageFix.idea("CHKD", conviction: 0.5),
            inputs: StockSageCatalystWatch.Inputs(earningsCheckedAt: Self.now, now: Self.now,
                                                  catalystSourcesAsked: ["yahoo calendarEvents"]))
        let entries = StockSageCatalystWatch.calendar([checked], now: Self.now)
        #expect(!entries.isEmpty)                                     // the record IS on the calendar...
        #expect(!CatalystsSection.hasDatedCatalysts(entries))         // ...but it's not a REAL dated catalyst
    }

    @Test("a real earnings date makes hasDatedCatalysts true even alongside a negative record")
    func hasDatedCatalystsIsTrueWithARealCatalystPresent() {
        let checked = StockSageCatalystWatch.brief(for: SageFix.idea("CHKD", conviction: 0.5),
            inputs: StockSageCatalystWatch.Inputs(earningsCheckedAt: Self.now, now: Self.now,
                                                  catalystSourcesAsked: ["yahoo calendarEvents"]))
        let real = StockSageCatalystWatch.brief(for: SageFix.idea("EARN", conviction: 0.5),
            inputs: StockSageCatalystWatch.Inputs(earningsDate: Self.now.addingTimeInterval(2 * 86_400), now: Self.now))
        let entries = StockSageCatalystWatch.calendar([checked, real], now: Self.now)
        #expect(CatalystsSection.hasDatedCatalysts(entries))
    }

    @Test("an empty calendar reports no dated catalysts")
    func hasDatedCatalystsIsFalseWhenEmpty() {
        #expect(!CatalystsSection.hasDatedCatalysts([]))
    }
}
