import Foundation

// MARK: - Earnings-date projection from a company's own report-date history
//
// When neither EODHD's calendar nor Yahoo's `calendarEvents` has a next earnings date, the last
// honest thing this app can say is "here's when the pattern says it should be, and here's the
// pattern" — never a guess dressed up as a fetched date. This is pure math, no I/O: callers
// (StockSageCatalystChain) hand it whatever past report dates a provider returned.
//
// PROJECTION: next = most recent report date + median gap of the last ≤8 gaps between
// consecutive reports (a gap needs 2 dates, so ≤8 gaps ⇒ at most the last 9 dates feed the
// median — capped so one very old, irregular gap can't skew a company that has since settled
// into a steady quarterly cadence). Needs ≥3 history dates (≥2 gaps) to project at all; fewer is
// `.unchecked`, not a projection off a single number.
nonisolated enum StockSageCatalystProjection {
    struct Projection: Sendable, Equatable {
        /// The projected next-report date.
        let date: Date
        /// ±7-day uncertainty window's upper bound (projection is a pattern, not a fetched date).
        let dateRangeEnd: Date
        /// Human-readable derivation, e.g. "median gap of last 6 reports = 91 d from 2026-07-30".
        let basis: String
    }

    private nonisolated static let sevenDays: TimeInterval = 7 * 86_400

    /// Median of a non-empty array — even count averages the two middle values (matches every
    /// other stats helper in this codebase, e.g. StockSageDeflatedSharpe). `nil` for an empty input.
    nonisolated static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) { return (sorted[mid - 1] + sorted[mid]) / 2 }
        return sorted[mid]
    }

    /// `history`: past report dates in ANY order (sorted internally). `nil` when fewer than 3
    /// dates are supplied (the <3-history-dates ⇒ unchecked boundary the chain relies on).
    /// `unitLabel` names what these dates actually ARE in the basis string (default "reports" —
    /// EODHD fundamentals' `Earnings.History` genuinely is past announcement dates; the caller
    /// must pass "quarter ends" for Yahoo's `earningsHistory` module, whose dates are fiscal
    /// PERIOD ends, not announcements — major fix 2026-09-06: the basis string must never claim
    /// more than the source data actually supports).
    nonisolated static func project(history: [Date], unitLabel: String = "reports") -> Projection? {
        let sorted = history.sorted()
        guard sorted.count >= 3 else { return nil }
        // Gaps between CONSECUTIVE reports, in whole days. At most the last 9 dates (8 gaps) feed
        // the median — `suffix` on an array already capped by `sorted.count` is a no-op below 9.
        let recent = Array(sorted.suffix(9))
        var gaps: [Double] = []
        for i in 1..<recent.count {
            gaps.append(recent[i].timeIntervalSince(recent[i - 1]) / 86_400)
        }
        guard let medianGap = median(gaps) else { return nil }
        let last = sorted[sorted.count - 1]
        let next = last.addingTimeInterval(medianGap.rounded() * 86_400)
        let lastStr = last.formatted(.iso8601.year().month().day())
        let basis = "median gap of last \(recent.count) \(unitLabel) = \(Int(medianGap.rounded())) d from \(lastStr)"
        return Projection(date: next, dateRangeEnd: next.addingTimeInterval(sevenDays), basis: basis)
    }
}
