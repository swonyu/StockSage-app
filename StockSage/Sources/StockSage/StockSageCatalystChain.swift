import Foundation

// MARK: - The catalyst chain: one honest next-earnings answer per tracked equity
//
// Pure orchestration — no direct network access, no singleton. Every provider is an injected
// async closure so a test can stub "EODHD nil, Yahoo hit" / "both nil, project from history" /
// "fewer than 3 history dates" without ever touching the network (STANDING RULES: tests must
// never hit the network). `StockSageStore` is the only real caller; it wires `eodhdCalendar` /
// `yahooCalendar` / `history` to the live StockSageEODHDCalendar / StockSageEarnings functions,
// picking EODHD fundamentals (US) vs Yahoo `earningsHistory` (Tadawul) for `history` by region —
// this function itself doesn't need to know which region it's running for.
nonisolated enum StockSageCatalystChain {
    /// The chain's answer for one symbol, shaped to drop straight into a
    /// `StockSageCatalystRecordCache.Record`.
    struct Outcome: Sendable, Equatable {
        let earningsDate: Date?
        let dateRangeEnd: Date?
        let confirmed: Bool?
        let status: StockSageCatalystRecordCache.Record.Status
        let source: String
        let sourcesAsked: [String]
        let projectionBasis: String?
    }

    /// Runs the 3-step chain for ONE equity symbol (the caller has already excluded
    /// non-equities, which go straight to `.notApplicable` without calling this at all).
    /// `now` gates a stale date the SAME way `StockSageStore.earningsRefreshOutcome` always has:
    /// more than a day in the past is not a usable "next" catalyst, so the chain falls through to
    /// its next step rather than reporting a report that already happened.
    static func resolve(
        now: Date,
        eodhdCalendar: () async -> StockSageEODHDCalendar.Row?,
        yahooCalendar: () async -> StockSageEarnings.EarningsCalendarInfo?,
        history: () async -> [Date]
    ) async -> Outcome {
        var sourcesAsked: [String] = []

        sourcesAsked.append("eodhd calendar")
        if let row = await eodhdCalendar(), row.date.timeIntervalSince(now) > -86_400 {
            return Outcome(earningsDate: row.date, dateRangeEnd: nil,
                          confirmed: StockSageEODHDCalendar.confirmed(for: row),
                          status: .dateKnown, source: "eodhd calendar",
                          sourcesAsked: sourcesAsked, projectionBasis: nil)
        }

        sourcesAsked.append("yahoo calendarEvents")
        if let info = await yahooCalendar(), info.date.timeIntervalSince(now) > -86_400 {
            return Outcome(earningsDate: info.date, dateRangeEnd: info.dateRangeEnd,
                          confirmed: !info.isEstimate, status: .dateKnown,
                          source: "yahoo calendarEvents", sourcesAsked: sourcesAsked, projectionBasis: nil)
        }

        sourcesAsked.append("earnings history")
        let pastDates = await history()
        if let projection = StockSageCatalystProjection.project(history: pastDates) {
            return Outcome(earningsDate: projection.date, dateRangeEnd: projection.dateRangeEnd,
                          confirmed: nil, status: .projected, source: "projection",
                          sourcesAsked: sourcesAsked, projectionBasis: projection.basis)
        }

        return Outcome(earningsDate: nil, dateRangeEnd: nil, confirmed: nil, status: .unchecked,
                       source: "—", sourcesAsked: sourcesAsked, projectionBasis: nil)
    }
}
