import Foundation

// MARK: - Time stop (age-based / dead-money discipline)
//
// A trade that hasn't worked in the time you gave it is tying up capital that could be
// compounding elsewhere — the slow leak that doesn't show up as a loss. This flags a
// position past its planned holding window so you decide consciously rather than drift.
// Pure + deterministic (takes `now` explicitly). Honest: it's a CAPITAL-EFFICIENCY rule,
// not a signal — it says nothing about whether the trade will still work, only that the
// clock you set has run out.

struct TimeStopSuggestion: Sendable, Equatable {
    let daysHeld: Int
    let daysToHold: Int
    let daysRemaining: Int   // negative once overdue
    let shouldExit: Bool     // daysHeld >= daysToHold
    let rationale: String
}

enum StockSageTimeStop {
    nonisolated enum Basis: Sendable { case elapsedDays, nasdaqSessions }
    nonisolated static func basis(for symbol: String) -> Basis? {
        if StockSageAllocation.assetClass(symbol) == "Crypto" { return .elapsedDays }
        return StockSageUniverse.nasdaqListed.contains(symbol.uppercased()) ? .nasdaqSessions : nil
    }
    nonisolated static func suggest(openedAt: Date, now: Date, daysToHold: Int, basis: Basis) -> TimeStopSuggestion? {
        if basis == .elapsedDays { return suggest(openedAt: openedAt, now: now, daysToHold: daysToHold) }
        guard daysToHold > 0, openedAt.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite,
              now >= openedAt, StockSageMarketHours.nasdaqDay(at: openedAt) != nil,
              StockSageMarketHours.nasdaqDay(at: now) != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let first = calendar.startOfDay(for: openedAt)
        let last = calendar.startOfDay(for: now)
        var held = 0
        // Both endpoints must be in the published 2026 calendar; at most366 dates to inspect.
        for offset in 1...366 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            if day > last { break }
            guard let schedule = StockSageMarketHours.nasdaqDay(at: day) else { return nil }
            if schedule.trading, let close = calendar.date(bySettingHour: schedule.regularClose, minute: 0, second: 0, of: day), close <= now { held += 1 }
        }
        let remaining = daysToHold - held
        let exit = held >= daysToHold
        let rationale = "\(held) completed Nasdaq sessions of the ~\(daysToHold)-session assumption; opening date excluded. "
            + (exit ? "Time-stop reached. " : "\(remaining) sessions remain. ")
            + "Uses the app's dated Nasdaq membership and published 2026 calendar. This is the general hold assumption, not a position-specific plan or sell signal."
        return .init(daysHeld: held, daysToHold: daysToHold, daysRemaining: remaining, shouldExit: exit, rationale: rationale)
    }
    /// nil when `daysToHold` isn't positive. Same-day open → 0 days held.
    nonisolated static func suggest(openedAt: Date, now: Date, daysToHold: Int) -> TimeStopSuggestion? {
        guard daysToHold > 0, openedAt.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite,
              now.timeIntervalSince(openedAt).isFinite,
              abs(now.timeIntervalSince(openedAt) / 86_400) < Double(Int.max) else { return nil }
        let held = Swift.max(0, Int((now.timeIntervalSince(openedAt) / 86_400).rounded(.down)))
        let remaining = daysToHold - held
        let exit = held >= daysToHold
        let why = exit
            ? "Held \(held) of ~\(daysToHold) planned days — time-stop reached. If the thesis hasn't played out, the capital may compound better elsewhere (this is a clock, not a sell signal)."
            : "Day \(held) of ~\(daysToHold) — \(remaining) day\(remaining == 1 ? "" : "s") left on the plan."
        return TimeStopSuggestion(daysHeld: held, daysToHold: daysToHold,
                                  daysRemaining: remaining, shouldExit: exit, rationale: why)
    }
}
