import Foundation

// MARK: - Loss-limit circuit breaker (the guardrail that halts a bad run)
//
// The app meticulously sizes every trade to ~1% but has nothing that says STOP after a red
// run — and a revenge/over-sizing spiral after a losing streak is the single most common way
// retail accounts blow up. This is a pure, deterministic brake: it aggregates today's and
// this-week's realized P&L (and R) AND the consecutive-loss run from CLOSED journal trades,
// and returns ok / warn / halted vs the owner's policy. `now` is injected for determinism.
// HONEST: a behavioral brake, NOT a probability edge — a losing streak doesn't make the next
// trade likelier to lose; it only sees trades the owner LOGGED, and only CLOSED ones count.

struct LossLimitPolicy: Sendable, Equatable {
    var maxDailyLoss: Double?      // positive $ magnitude; nil = no daily-$ limit
    var maxWeeklyLoss: Double?
    var maxDailyLossR: Double?     // positive R magnitude
    var maxWeeklyLossR: Double?
    var standDownLossRun: Int      // halt after this many consecutive losses (0 = off)
    var warnFraction: Double       // warn band as a fraction of each limit

    nonisolated init(maxDailyLoss: Double? = nil, maxWeeklyLoss: Double? = nil,
                     maxDailyLossR: Double? = nil, maxWeeklyLossR: Double? = nil,
                     standDownLossRun: Int = 3, warnFraction: Double = 0.70) {
        self.maxDailyLoss = maxDailyLoss; self.maxWeeklyLoss = maxWeeklyLoss
        self.maxDailyLossR = maxDailyLossR; self.maxWeeklyLossR = maxWeeklyLossR
        self.standDownLossRun = standDownLossRun; self.warnFraction = warnFraction
    }
}

struct LossLimitState: Sendable, Equatable {
    enum Status: String, Sendable { case ok, warn, halted }
    let status: Status
    let dailyRealized: Double      // today's realized P&L, NATIVE currency units summed (losses negative)
    let weeklyRealized: Double
    let dailyRealizedR: Double
    /// This week's realized R — exposed so the warn banner can report the weekly reading
    /// in the same unit as the weekly gate (review fix 2026-07-16: the banner previously
    /// showed `weeklyRealized` labeled "$", but realizedProfit is the symbol's NATIVE
    /// currency — a mixed SAR/USD sum for this owner — and the live weekly gate is R-based).
    let weeklyRealizedR: Double
    let lossRun: Int               // current consecutive-loss streak (breakeven/win breaks it)
    let haltReason: String?
    let caveat: String
}

enum StockSageLossLimit {
    nonisolated static let caveat = "A behavioral brake, not a probability edge — a losing streak does NOT make the next trade likelier to lose; markets have no memory. It only sees trades you LOGGED, and only CLOSED trades count toward today's tally. Period boundaries are UTC, matching the journal's own aggregation."

    /// Fixed UTC Gregorian calendar so the day/week halt windows agree with the journal's
    /// UTC-pinned reporting and never drift with device timezone, locale firstWeekday, or DST.
    nonisolated static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()

    /// #9's fail-closed fallback: the start of a trailing 7-day window (dayStart − 6 days).
    /// Any calendar week containing `now` starts at most 6 days before today's start, so
    /// [dayStart − 6d, now] ⊇ [weekStart, now] — the fallback can only count MORE losses than
    /// the real week (halt earlier), never fewer. Exposed (not private) so the test pins it.
    nonisolated static func sevenDayFallbackStart(dayStart: Date, calendar: Calendar = utcCalendar) -> Date {
        calendar.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart.addingTimeInterval(-6 * 86_400)
    }

    /// Aggregate realized losses + the consecutive-loss run vs `policy`. Open trades (no
    /// closedAt) contribute 0; a breakeven or a win breaks the loss run.
    nonisolated static func evaluate(closedTrades: [TradeRecord], policy: LossLimitPolicy,
                                     now: Date, calendar: Calendar = utcCalendar) -> LossLimitState {
        let closed = closedTrades.filter { $0.closedAt != nil }
        let dayStart = calendar.startOfDay(for: now)
        // #9 fail-CLOSED: if the calendar ever fails to produce a week interval (never, for
        // valid Gregorian dates — but this is a safety breaker), the weekly window must NOT
        // silently collapse to [startOfToday, now] (a guardrail failing OPEN: weekly losses
        // under-counted, no halt on a bad week). Fall back to a trailing 7-day window, which
        // always covers ⊇ any calendar week containing `now` — strictly more conservative.
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? sevenDayFallbackStart(dayStart: dayStart, calendar: calendar)

        func realized(since from: Date) -> (dollars: Double, r: Double) {
            var d = 0.0, r = 0.0
            for t in closed {
                guard let c = t.closedAt, c >= from, c <= now else { continue }
                if let p = t.realizedProfit { d += p }
                if let rr = t.realizedR { r += rr }
            }
            return (d, r)
        }
        let day = realized(since: dayStart), week = realized(since: weekStart)

        // Consecutive most-recent losses; a breakeven or a win breaks the run. Judge by realized
        // P&L (a closed loser with stop==entry has a real negative profit but a NIL R — using R
        // alone would make it invisible and mis-link the streak); fall back to R when P&L is absent.
        let recent = closed.compactMap { t -> (Date, Double)? in
            guard let c = t.closedAt, c <= now else { return nil }
            if let p = t.realizedProfit { return (c, p) }
            if let rr = t.realizedR { return (c, rr) }
            return nil
        }.sorted { $0.0 > $1.0 }
        var lossRun = 0
        for (_, v) in recent { if v < 0 { lossRun += 1 } else { break } }

        // Each limit is a positive magnitude; a loss makes the realized figure negative.
        var halts: [String] = [], warn = false
        func gate(_ realizedValue: Double, _ limit: Double?, _ label: String) {
            guard let lim = limit, lim > 0 else { return }
            let loss = -realizedValue
            if loss >= lim { halts.append(label) }
            else if loss >= lim * policy.warnFraction { warn = true }
        }
        gate(day.dollars, policy.maxDailyLoss, "daily loss limit hit")
        gate(week.dollars, policy.maxWeeklyLoss, "weekly loss limit hit")
        gate(day.r, policy.maxDailyLossR, "daily R limit hit")
        gate(week.r, policy.maxWeeklyLossR, "weekly R limit hit")
        if policy.standDownLossRun > 0 {
            if lossRun >= policy.standDownLossRun { halts.append("\(lossRun)-loss streak — stand down") }
            else if lossRun > 0, Double(lossRun) >= Double(policy.standDownLossRun) * policy.warnFraction { warn = true }
        }

        let status: LossLimitState.Status = !halts.isEmpty ? .halted : (warn ? .warn : .ok)
        return LossLimitState(status: status, dailyRealized: day.dollars, weeklyRealized: week.dollars,
                              dailyRealizedR: day.r, weeklyRealizedR: week.r, lossRun: lossRun,
                              haltReason: halts.isEmpty ? nil : halts.joined(separator: "; "), caveat: caveat)
    }
}
