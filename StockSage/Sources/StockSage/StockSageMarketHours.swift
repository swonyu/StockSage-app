import Foundation

// MARK: - Dual-market session clock (pure, testable)
//
// Purely a SCHEDULE readout — "what time is it there, and what does the published calendar
// say should be happening" — not a live open/closed feed and not a promise. Two honesty
// limits, stated up front because this app makes real-money decisions (HONESTY FLOOR):
//   1. NASDAQ uses the published 2026 calendar; unsupported years are unavailable.
//      Scheduled hours never establish a live market, eligible quote, or broker permission.
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
        "Published 2026 holiday/early-close schedule; unexpected closures and broker-specific hours are not modeled. Fresh eligible data is still required."

    nonisolated struct NasdaqDay: Sendable {
        let trading: Bool
        let regularClose: Int
        let extendedClose: Int
    }

    /// Nasdaq 2026 holiday calendar and UTP SIP transmission schedule, verified 2026-09-09.
    /// https://www.nasdaq.com/market-activity/stock-market-holiday-schedule
    /// https://www.utpplan.com/DOC/UTP_SIP_Transmission_Schedule.pdf
    /// ponytail: explicit published year; extend from verified notices before 2027, never guess.
    nonisolated static func nasdaqDay(at date: Date) -> NasdaqDay? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard parts.year == 2026, let month = parts.month, let day = parts.day else { return nil }
        let key = month * 100 + day
        let holidays: Set<Int> = [101, 119, 216, 403, 525, 619, 703, 907, 1126, 1225]
        let early = key == 1127 || key == 1224
        return .init(trading: parts.weekday != 1 && parts.weekday != 7 && !holidays.contains(key),
                     regularClose: early ? 13 : 16, extendedClose: early ? 17 : 20)
    }

    /// Full-day aggregates can include extended hours. The legacy prior-date rule remains
    /// available only for validating saved captures that predate this correction.
    nonisolated static func latestCompletedDailySession(at now: Date, includingCurrentSession: Bool = true) -> Date? {
        guard now.timeIntervalSince1970.isFinite, nasdaqDay(at: now) != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let today = calendar.startOfDay(for: now)
        for offset in (includingCurrentSession ? 0 : 1)...8 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let session = nasdaqDay(at: day) else { return nil }
            guard session.trading else { continue }
            if offset == 0 {
                guard let end = calendar.date(bySettingHour: session.extendedClose, minute: 0, second: 0, of: day) else { return nil }
                if now < end { continue }
            }
            return day
        }
        return nil
    }

    nonisolated static func isLatestCompletedDailyBar(_ bar: Date, at now: Date, includingCurrentSession: Bool = true) -> Bool {
        guard bar.timeIntervalSince1970.isFinite, bar <= now,
              let latest = latestCompletedDailySession(at: now, includingCurrentSession: includingCurrentSession) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar.isDate(bar, inSameDayAs: latest)
    }

    /// General research retains its existing age ceiling, including today's daily background.
    /// Only Massive daily bars get a verified completed-session holiday exception. This policy
    /// does not qualify an intraday observation or an executable paper-fill quote.
    nonisolated static func isRecentResearchPrice(_ priceTime: Date, source: StockSagePriceSource?, at now: Date) -> Bool {
        guard source != .manualEntry, source != .importedRecord,
              now.timeIntervalSince1970.isFinite, priceTime.timeIntervalSince1970.isFinite else { return false }
        return (0...4 * 86_400).contains(now.timeIntervalSince(priceTime))
            || (source == .massiveDaily && isLatestCompletedDailyBar(priceTime, at: now))
    }

    nonisolated static func nasdaqState(at date: Date, calendar: Calendar) -> SessionState {
        var cal = calendar
        let tz = TimeZone(identifier: "America/New_York")!
        cal.timeZone = tz
        let weekday = cal.component(.weekday, from: date) // 1=Sun...7=Sat
        guard let day = nasdaqDay(at: date) else {
            return SessionState(market: .nasdaq, phase: .closed,
                                phaseLabel: "Session calendar unavailable", nextTransition: nil, caveat: nasdaqCaveat)
        }
        guard day.trading else {
            return SessionState(market: .nasdaq, phase: .closed,
                                 phaseLabel: weekday == 1 || weekday == 7 ? "Closed (weekend)" : "Closed (exchange holiday)",
                                 nextTransition: nextNasdaqPreMarket(after: date, calendar: cal),
                                 caveat: nasdaqCaveat)
        }
        let boundaries = dayBoundaries(for: date, calendar: cal, hourMin: [(4, 0), (9, 30), (day.regularClose, 0), (day.extendedClose, 0)])
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
                                 phaseLabel: "Open — closes \(day.regularClose):00 ET",
                                 nextTransition: regClose, caveat: nasdaqCaveat)
        }
        if date < afterClose {
            return SessionState(market: .nasdaq, phase: .afterHours,
                                 phaseLabel: "After-hours — ends \(day.extendedClose):00 ET",
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
            guard nasdaqDay(at: day)?.trading == true else { continue }
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
