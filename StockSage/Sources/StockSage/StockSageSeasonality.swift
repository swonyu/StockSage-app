import Foundation

// MARK: - Monthly seasonality
//
// Some names have a mild calendar tendency (the "sell in May" folklore, tax-loss
// bounces, etc.). This measures it honestly: month-over-month returns grouped by
// calendar month, averaged, WITH the sample count — because a "+3% average June"
// over 2 years is noise, not a pattern. Pure + tested. Always framed as a weak,
// backward-looking tendency, never a forecast.

struct MonthlySeasonality: Sendable, Equatable {
    struct MonthStat: Sendable, Equatable, Identifiable {
        let month: Int          // 1…12
        let avgReturn: Double   // average month-over-month return (fraction)
        let samples: Int        // how many years contributed this month
        /// Sample standard deviation of this month's yearly returns (Bessel n−1; 0 when <2
        /// samples). Defaulted so existing construction sites stay source-compatible.
        var stdDev: Double = 0
        var id: Int { month }
        /// A month needs ≥3 yearly samples before it's worth reading at all.
        nonisolated var isReliable: Bool { samples >= 3 }
        /// t-statistic of the mean vs zero (mean ÷ SE). nil when undefined (<2 samples or
        /// zero dispersion — zero dispersion with n≥2 is a perfectly consistent signal,
        /// which callers should treat as PASSING any noise gate, not failing it).
        nonisolated var tStat: Double? {
            guard samples >= 2, stdDev > 0 else { return nil }
            return avgReturn / (stdDev / Double(samples).squareRoot())
        }

        nonisolated func note(monthName: String) -> String {
            let pct = String(format: "%+.1f%%", avgReturn * 100)
            let tail = isReliable ? "" : " — thin sample, treat as noise"
            return "\(monthName): historically \(pct) average over \(samples) year\(samples == 1 ? "" : "s")\(tail). A weak, backward-looking tendency — not a forecast."
        }
    }
    let months: [MonthStat]     // exactly 12 entries (month 1…12)
    let years: Double

    nonisolated static let empty = MonthlySeasonality(
        months: (1...12).map { MonthStat(month: $0, avgReturn: 0, samples: 0) }, years: 0)
}

enum StockSageSeasonality {
    private nonisolated static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// The current month (1–12) in the SAME UTC frame `compute()` buckets by, so the "this month"
    /// stat the UI highlights matches the bucket the data was filed under. A local calendar can
    /// disagree near a month boundary (e.g. it's already next month locally but still month-end UTC).
    nonisolated static func currentMonth(asOf now: Date = Date()) -> Int {
        utcCalendar.component(.month, from: now)
    }

    /// Group month-over-month returns by calendar month. Accepts daily OR monthly
    /// bars — within each calendar month the LAST close is taken as the month-end,
    /// then returns are computed between consecutive month-ends.
    ///
    /// `now` (injectable, UTC-bucketed like everything else here) excludes the IN-PROGRESS
    /// month: Yahoo's `1mo` bars include the current partial month (MEASURED 2026-07-09:
    /// AAPL response carried a 2026-07-01 bar 6 trading days into July, close 313.39 — a
    /// +8.3% partial MTD move that would otherwise be credited as a full "July" seasonality
    /// sample). The current month is exactly the bucket the TOM rank tilt reads, so without
    /// this exclusion the "seasonal" tilt double-counts the symbol's own recent momentum.
    nonisolated static func compute(dates: [Date], closes: [Double], now: Date = Date()) -> MonthlySeasonality {
        guard dates.count == closes.count, dates.count >= 2 else { return .empty }
        let cal = utcCalendar

        // Collapse to one (key, month, month-end-close) point per calendar month.
        // `key` = year*12+month lets us require ADJACENT months below — and lets the
        // in-progress-month exclusion compare against `now`'s (year, month) exactly.
        var order: [(key: Int, month: Int, close: Double)] = []
        var lastKey = Int.min
        for (d, c) in zip(dates, closes) where c > 0 {
            let comps = cal.dateComponents([.year, .month], from: d)
            guard let y = comps.year, let m = comps.month else { continue }
            let key = y * 12 + m
            if key == lastKey {
                order[order.count - 1].close = c   // keep the last close seen this month
            } else {
                order.append((key: key, month: m, close: c))
                lastKey = key
            }
        }
        guard order.count >= 2 else { return .empty }

        // Drop the trailing point when it belongs to the CURRENT (incomplete) calendar month —
        // its "month return" is a partial MTD move, not a seasonality observation.
        let nowComps = cal.dateComponents([.year, .month], from: now)
        if let ny = nowComps.year, let nm = nowComps.month,
           let last = order.last, last.key == ny * 12 + nm {
            order.removeLast()
            guard order.count >= 2 else { return .empty }
        }

        var byMonth: [Int: [Double]] = [:]
        for i in 1..<order.count {
            // Only credit a return when the two points are CONSECUTIVE calendar
            // months — a gap (e.g. a dropped null bar) would otherwise mislabel a
            // multi-month return as the later month's single-month seasonality.
            guard order[i - 1].close > 0, order[i].key == order[i - 1].key + 1 else { continue }
            byMonth[order[i].month, default: []].append(order[i].close / order[i - 1].close - 1)
        }
        let months = (1...12).map { m -> MonthlySeasonality.MonthStat in
            let rs = byMonth[m] ?? []
            let avg = rs.isEmpty ? 0 : rs.reduce(0, +) / Double(rs.count)
            // Sample std (Bessel n−1) — feeds the tilt's noise gate; 0 when <2 samples.
            let std: Double = rs.count >= 2
                ? (rs.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(rs.count - 1)).squareRoot()
                : 0
            return MonthlySeasonality.MonthStat(month: m, avgReturn: avg, samples: rs.count, stdDev: std)
        }
        let years = dates.last!.timeIntervalSince(dates.first!) / (365.25 * 86_400)
        return MonthlySeasonality(months: months, years: years)
    }

    nonisolated static func stat(_ s: MonthlySeasonality, month: Int) -> MonthlySeasonality.MonthStat? {
        s.months.first { $0.month == month }
    }
}
