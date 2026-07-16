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
    /// nil when `daysToHold` isn't positive. Same-day open → 0 days held.
    nonisolated static func suggest(openedAt: Date, now: Date, daysToHold: Int) -> TimeStopSuggestion? {
        guard daysToHold > 0 else { return nil }
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
