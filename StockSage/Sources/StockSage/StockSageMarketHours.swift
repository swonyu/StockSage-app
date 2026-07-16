import Foundation

// MARK: - Dual-market session clock (pure, testable)
//
// Purely a SCHEDULE readout — "what time is it there, and what does the published calendar
// say should be happening" — not a live open/closed feed and not a promise. Two honesty
// limits, stated up front because this app makes real-money decisions (HONESTY FLOOR):
//   1. NASDAQ carries NO US market-holiday table. A "scheduled open" on Thanksgiving reads
//      exactly like any other Thursday. `caveat` says so on every NASDAQ state so a caller
//      can surface it — this engine never claims certainty it doesn't have.
//   2. Tadawul's schedule (Sun–Thu, continuous 10:00–15:00 Riyadh, closing auction to ~15:10)
//      matches the existing sourced fact in StockSageExecutionTiming.swift (saudiexchange.sa
//      Trading Cycle and Times, sourced 2026-07-16) — same numbers, not re-derived.
//
// `nonisolated`, Date-injected (never `Date()` inside the engine) — every state is a pure
// function of (Date, Calendar) so it's deterministic and unit-testable without wall-clock races.
enum StockSageMarketHours {

    enum Market: String, Sendable { case tadawul = "Tadawul", nasdaq = "NASDAQ" }

    enum Phase: String, Sendable {
        case preMarket, open, closingAuction, afterHours, closed
    }

    struct SessionState: Sendable, Equatable {
        let market: Market
        let phase: Phase
        /// Short human label, e.g. "Open — closes 15:00" or "Scheduled open 9:30 ET".
        let phaseLabel: String
        /// When the current phase ends (nil only if genuinely unbounded, which never happens
        /// here — every phase in both calendars has a defined next boundary).
        let nextTransition: Date?
        /// Honest limits of this readout (holiday table, DST handling, etc.) — always non-empty.
        let caveat: String
    }

    // MARK: Tadawul (Sun–Thu, continuous 10:00–15:00 Asia/Riyadh, closing auction to ~15:10)

    private nonisolated static let tadawulCaveat =
        "Scheduled weekday/hours only — exchange holidays (Saudi National Day, Eid, etc.) not modeled."

    nonisolated static func tadawulState(at date: Date, calendar: Calendar) -> SessionState {
        var cal = calendar
        let tz = TimeZone(identifier: "Asia/Riyadh")!
        cal.timeZone = tz
        let weekday = cal.component(.weekday, from: date) // 1=Sun...7=Sat
        let openBoundaries = dayBoundaries(for: date, calendar: cal, hourMin: [(10, 0), (15, 0), (15, 10)])
        let open = openBoundaries[0], close = openBoundaries[1], auctionEnd = openBoundaries[2]

        // Fri(6)/Sat(7) closed all day; next transition is Sunday's 10:00 open.
        guard weekday != 6, weekday != 7 else {
            return SessionState(market: .tadawul, phase: .closed,
                                 phaseLabel: "Closed (weekend)",
                                 nextTransition: nextTadawulOpen(after: date, calendar: cal),
                                 caveat: tadawulCaveat)
        }
        if date < open {
            return SessionState(market: .tadawul, phase: .closed,
                                 phaseLabel: "Scheduled open 10:00 Riyadh",
                                 nextTransition: open, caveat: tadawulCaveat)
        }
        if date < close {
            return SessionState(market: .tadawul, phase: .open,
                                 phaseLabel: "Open — closes 15:00 Riyadh",
                                 nextTransition: close, caveat: tadawulCaveat)
        }
        if date < auctionEnd {
            return SessionState(market: .tadawul, phase: .closingAuction,
                                 phaseLabel: "Closing auction — ends ~15:10 Riyadh",
                                 nextTransition: auctionEnd, caveat: tadawulCaveat)
        }
        return SessionState(market: .tadawul, phase: .closed,
                             phaseLabel: "Closed",
                             nextTransition: nextTadawulOpen(after: date, calendar: cal),
                             caveat: tadawulCaveat)
    }

    private nonisolated static func nextTadawulOpen(after date: Date, calendar cal: Calendar) -> Date? {
        // Walk forward day by day (bounded) to the next Sun–Thu 10:00, skipping Fri/Sat.
        for offset in 0...8 {
            guard let day = cal.date(byAdding: .day, value: offset, to: date) else { continue }
            let weekday = cal.component(.weekday, from: day)
            guard weekday != 6, weekday != 7 else { continue }
            guard let open = combining(day: day, hour: 10, minute: 0, calendar: cal) else { continue }
            if open > date { return open }
        }
        return nil
    }

    // MARK: NASDAQ (Mon–Fri, pre 4:00–9:30, regular 9:30–16:00, after 16:00–20:00 America/New_York)

    private nonisolated static let nasdaqCaveat =
        "Scheduled weekday schedule; US exchange holidays (Thanksgiving, July 4th, etc.) not modeled."

    nonisolated static func nasdaqState(at date: Date, calendar: Calendar) -> SessionState {
        var cal = calendar
        let tz = TimeZone(identifier: "America/New_York")!
        cal.timeZone = tz
        let weekday = cal.component(.weekday, from: date) // 1=Sun...7=Sat

        guard weekday != 1, weekday != 7 else {
            return SessionState(market: .nasdaq, phase: .closed,
                                 phaseLabel: "Closed (weekend)",
                                 nextTransition: nextNasdaqPreMarket(after: date, calendar: cal),
                                 caveat: nasdaqCaveat)
        }
        let boundaries = dayBoundaries(for: date, calendar: cal, hourMin: [(4, 0), (9, 30), (16, 0), (20, 0)])
        let preOpen = boundaries[0], regOpen = boundaries[1], regClose = boundaries[2], afterClose = boundaries[3]

        if date < preOpen {
            return SessionState(market: .nasdaq, phase: .closed,
                                 phaseLabel: "Closed",
                                 nextTransition: preOpen, caveat: nasdaqCaveat)
        }
        if date < regOpen {
            return SessionState(market: .nasdaq, phase: .preMarket,
                                 phaseLabel: "Pre-market — scheduled open 9:30 ET",
                                 nextTransition: regOpen, caveat: nasdaqCaveat)
        }
        if date < regClose {
            return SessionState(market: .nasdaq, phase: .open,
                                 phaseLabel: "Open — closes 16:00 ET",
                                 nextTransition: regClose, caveat: nasdaqCaveat)
        }
        if date < afterClose {
            return SessionState(market: .nasdaq, phase: .afterHours,
                                 phaseLabel: "After-hours — ends 20:00 ET",
                                 nextTransition: afterClose, caveat: nasdaqCaveat)
        }
        return SessionState(market: .nasdaq, phase: .closed,
                             phaseLabel: "Closed",
                             nextTransition: nextNasdaqPreMarket(after: date, calendar: cal),
                             caveat: nasdaqCaveat)
    }

    private nonisolated static func nextNasdaqPreMarket(after date: Date, calendar cal: Calendar) -> Date? {
        for offset in 0...8 {
            guard let day = cal.date(byAdding: .day, value: offset, to: date) else { continue }
            let weekday = cal.component(.weekday, from: day)
            guard weekday != 1, weekday != 7 else { continue }
            guard let pre = combining(day: day, hour: 4, minute: 0, calendar: cal) else { continue }
            if pre > date { return pre }
        }
        return nil
    }

    // MARK: shared helpers

    /// Same calendar-day as `date`, at each (hour, minute) pair, in `calendar`'s timeZone.
    private nonisolated static func dayBoundaries(for date: Date, calendar cal: Calendar, hourMin: [(Int, Int)]) -> [Date] {
        hourMin.map { combining(day: date, hour: $0.0, minute: $0.1, calendar: cal) ?? date }
    }

    private nonisolated static func combining(day: Date, hour: Int, minute: Int, calendar cal: Calendar) -> Date? {
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour; comps.minute = minute; comps.second = 0
        return cal.date(from: comps)
    }
}
