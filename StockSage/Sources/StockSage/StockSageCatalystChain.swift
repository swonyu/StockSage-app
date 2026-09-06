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
    /// Whether a provider closure actually OBSERVED something, distinct from never having asked
    /// at all (blocker fix 2026-09-06). Before this, every provider closure returned a plain
    /// optional, so ".unavailable" (external access off, non-equity, timeout, non-200, 3-attempt
    /// 429 exhaustion, plan-tier rejection) and ".answered(nil)" (a real 200 with nothing usable)
    /// collapsed into the same `nil` — the chain could not tell "we asked and got nothing" from
    /// "we never actually asked," so it stamped a dated "none known" record even when NO source
    /// ever answered. `.answered(value)` — the provider was actually asked and responded;
    /// `.unavailable` — no observation was made and the caller must NOT count it as asked.
    enum Answer<T> { case answered(T), unavailable }

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
        /// True the moment ANY provider actually answered (blocker fix 2026-09-06) — the store
        /// must refuse to stamp a dated "none known" record when this is false, since that would
        /// claim a question nobody ever actually answered.
        let anySourceAnswered: Bool
    }

    /// Runs the 3-step chain for ONE equity symbol (the caller has already excluded
    /// non-equities, which go straight to `.notApplicable` without calling this at all).
    /// `now` gates a stale date the SAME way `StockSageStore.earningsRefreshOutcome` always has:
    /// more than a day in the past is not a usable "next" catalyst, so the chain falls through to
    /// its next step rather than reporting a report that already happened. `historyUnitLabel`
    /// names what `history`'s dates actually ARE (EODHD fundamentals = past REPORT dates; Yahoo
    /// `earningsHistory` = past fiscal QUARTER-END dates, a materially different thing) so the
    /// projection's basis string never claims more than the source actually supports.
    static func resolve(
        now: Date,
        eodhdCalendar: () async -> Answer<StockSageEODHDCalendar.Row?>,
        yahooCalendar: () async -> Answer<StockSageEarnings.EarningsCalendarInfo?>,
        historyUnitLabel: String = "reports",
        history: () async -> Answer<[Date]>
    ) async -> Outcome {
        var sourcesAsked: [String] = []
        var anySourceAnswered = false

        // Each step appends to `sourcesAsked` ONLY after `.answered` — a provider that was never
        // actually reachable (not covered, key empty, 24h-unavailable window open, external
        // access off, non-equity, timeout, non-200, 429-exhaustion) must never be recorded as
        // asked (blocker fix 2026-09-06 — see StockSageCatalystRecordCache.Record.sourcesAsked's
        // own doc: it's the ONLY field distinguishing "never asked" from "asked, nothing usable").
        if case .answered(let row) = await eodhdCalendar() {
            anySourceAnswered = true
            sourcesAsked.append("eodhd calendar")
            if let row, row.date.timeIntervalSince(now) > -86_400 {
                return Outcome(earningsDate: row.date, dateRangeEnd: nil,
                              confirmed: StockSageEODHDCalendar.confirmed(for: row),
                              status: .dateKnown, source: "eodhd calendar",
                              sourcesAsked: sourcesAsked, projectionBasis: nil,
                              anySourceAnswered: anySourceAnswered)
            }
        }

        if case .answered(let info) = await yahooCalendar() {
            anySourceAnswered = true
            sourcesAsked.append("yahoo calendarEvents")
            if let info, info.date.timeIntervalSince(now) > -86_400 {
                return Outcome(earningsDate: info.date, dateRangeEnd: info.dateRangeEnd,
                              confirmed: !info.isEstimate, status: .dateKnown,
                              source: "yahoo calendarEvents", sourcesAsked: sourcesAsked,
                              projectionBasis: nil, anySourceAnswered: anySourceAnswered)
            }
        }

        if case .answered(let pastDates) = await history() {
            anySourceAnswered = true
            sourcesAsked.append("earnings history")
            // A projection is pure history math with no future constraint of its own — without
            // this `now` guard, a company whose history source has gone stale (exactly the case
            // when both calendars come up empty) projects a date that's already in the past and
            // gets filed as an upcoming catalyst (major fix 2026-09-06). Same `> -86_400`
            // boundary as the two steps above, for the same reason.
            if let projection = StockSageCatalystProjection.project(history: pastDates, unitLabel: historyUnitLabel),
               projection.date.timeIntervalSince(now) > -86_400 {
                return Outcome(earningsDate: projection.date, dateRangeEnd: projection.dateRangeEnd,
                              confirmed: nil, status: .projected, source: "projection",
                              sourcesAsked: sourcesAsked, projectionBasis: projection.basis,
                              anySourceAnswered: anySourceAnswered)
            }
        }

        return Outcome(earningsDate: nil, dateRangeEnd: nil, confirmed: nil, status: .unchecked,
                       source: "—", sourcesAsked: sourcesAsked, projectionBasis: nil,
                       anySourceAnswered: anySourceAnswered)
    }
}
