import Foundation

// MARK: - The catalyst chain: one honest next-earnings answer per tracked equity
//
// Pure orchestration — no direct network access, no singleton. Every provider is an injected
// async closure so a test can stub "Yahoo nil, project from history" / "no history stage" /
// "fewer than 3 history dates" without ever touching the network (STANDING RULES: tests must
// never hit the network). `StockSageStore` is the only real caller; it wires `yahooCalendar` to
// Yahoo calendarEvents and admits Yahoo quarter-end history only for non-US equities.
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

    /// Runs the Massive/Benzinga → Yahoo → optional history chain for ONE equity symbol (the
    /// caller has already excluded non-equities, which go straight to `.notApplicable` without
    /// calling this at all).
    /// `now` gates a stale date the SAME way `StockSageStore.earningsRefreshOutcome` always has:
    /// more than a day in the past is not a usable "next" catalyst, so the chain falls through to
    /// its next step rather than reporting a report that already happened.
    /// `history` returns nil when that stage does not exist (US after provider retirement),
    /// `.unavailable` when an admitted source did not answer, and `.answered` only for an actual
    /// Yahoo fiscal-quarter-end observation.
    static func resolve(
        now: Date,
        stillValid: () -> Bool = { true },
        massiveCalendar: () async -> Answer<StockSageMassiveEarnings.Row?> = { .unavailable },
        yahooCalendar: () async -> Answer<StockSageEarnings.EarningsCalendarInfo?>,
        history: (() async -> Answer<[Date]>)?
    ) async -> Outcome {
        var sourcesAsked: [String] = []
        var anySourceAnswered = false

        func active() -> Bool { !Task.isCancelled && stillValid() }
        func unchecked() -> Outcome {
            Outcome(earningsDate: nil, dateRangeEnd: nil, confirmed: nil, status: .unchecked,
                    source: "—", sourcesAsked: sourcesAsked, projectionBasis: nil,
                    anySourceAnswered: anySourceAnswered)
        }

        guard active() else { return unchecked() }
        let massiveAnswer = await massiveCalendar()
        guard active() else { return unchecked() }
        if case .answered(let row) = massiveAnswer {
            anySourceAnswered = true
            sourcesAsked.append(StockSageMassiveEarnings.source)
            if let row, row.date.timeIntervalSince(now) > -86_400 {
                // Provider-estimated dates remain explicitly unconfirmed calendar observations,
                // not the app's separate median-gap history projection (.projected).
                return Outcome(earningsDate: row.date, dateRangeEnd: nil, confirmed: row.confirmed,
                               status: .dateKnown, source: StockSageMassiveEarnings.source,
                               sourcesAsked: sourcesAsked, projectionBasis: nil, anySourceAnswered: true)
            }
        }

        // Each step appends to `sourcesAsked` ONLY after `.answered` — a provider that was never
        // actually reachable (external access off, non-equity, timeout, non-200, 429-exhaustion)
        // must never be recorded as asked (blocker fix 2026-09-06).
        guard active() else { return unchecked() }
        let yahooAnswer = await yahooCalendar()
        guard active() else { return unchecked() }
        if case .answered(let info) = yahooAnswer {
            anySourceAnswered = true
            sourcesAsked.append("yahoo calendarEvents")
            if let info, info.date.timeIntervalSince(now) > -86_400 {
                return Outcome(earningsDate: info.date, dateRangeEnd: info.dateRangeEnd,
                              confirmed: !info.isEstimate, status: .dateKnown,
                              source: "yahoo calendarEvents", sourcesAsked: sourcesAsked,
                              projectionBasis: nil, anySourceAnswered: anySourceAnswered)
            }
        }

        guard active() else { return unchecked() }
        guard let history else { return unchecked() }
        let historyAnswer = await history()
        guard active() else { return unchecked() }
        if case .answered(let pastDates) = historyAnswer {
            anySourceAnswered = true
            sourcesAsked.append("earnings history")
            // A projection is pure history math with no future constraint of its own — without
            // this `now` guard, a company whose history source has gone stale (exactly the case
            // when both calendars come up empty) projects a date that's already in the past and
            // gets filed as an upcoming catalyst (major fix 2026-09-06). Same `> -86_400`
            // boundary as the two steps above, for the same reason.
            if let projection = StockSageCatalystProjection.project(history: pastDates, unitLabel: "quarter ends"),
               projection.date.timeIntervalSince(now) > -86_400 {
                return Outcome(earningsDate: projection.date, dateRangeEnd: projection.dateRangeEnd,
                              confirmed: nil, status: .projected, source: "projection",
                              sourcesAsked: sourcesAsked, projectionBasis: projection.basis,
                              anySourceAnswered: anySourceAnswered)
            }
        }

        return unchecked()
    }
}
