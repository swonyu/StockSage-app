import Testing
import Foundation
@testable import StockSage

// MARK: - Loss-limit circuit breaker (pure) — the halt-after-a-bad-run guardrail.
// Deterministic via injected `now`; entry 100 / stop 90 so exit = 100 + r·10 gives R == r.

struct StockSageLossLimitTests {
    typealias LL = StockSageLossLimit

    private let cal = StockSageLossLimit.utcCalendar   // align with the engine's UTC boundaries
    private var dayStart: Date { cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000)) }
    private var now: Date { cal.date(byAdding: .hour, value: 12, to: dayStart)! }   // midday
    private func todayAt(_ hoursBeforeNow: Int) -> Date { cal.date(byAdding: .hour, value: -hoursBeforeNow, to: now)! }
    private var yesterday: Date { cal.date(byAdding: .hour, value: -2, to: dayStart)! }  // before midnight

    /// A CLOSED long with realized R == r (profit = r·10·shares), or OPEN when closedAt is nil.
    private func t(_ r: Double, shares: Double = 10, closedAt: Date?) -> TradeRecord {
        TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: 130, shares: shares,
                    openedAt: Date(timeIntervalSince1970: 0),
                    exitPrice: closedAt == nil ? nil : 100 + r * 10, closedAt: closedAt)
    }

    @Test func profitableDayIsOk() {
        let s = LL.evaluate(closedTrades: [t(2, closedAt: now)],
                            policy: LossLimitPolicy(maxDailyLoss: 150), now: now)
        #expect(s.status == .ok && abs(s.dailyRealized - 200) < 1e-9)
    }

    @Test func dailyDollarLossHalts() {
        let s = LL.evaluate(closedTrades: [t(-1, closedAt: now), t(-1, closedAt: todayAt(1))],
                            policy: LossLimitPolicy(maxDailyLoss: 150, standDownLossRun: 0), now: now)
        #expect(s.status == .halted && abs(s.dailyRealized + 200) < 1e-9)
        #expect(s.haltReason?.lowercased().contains("daily") == true)
    }

    @Test func warnBandAtSeventyPercent() {
        // −$100 vs a $130 limit → 77% of the limit → warn (not yet halted).
        let s = LL.evaluate(closedTrades: [t(-1, closedAt: now)],
                            policy: LossLimitPolicy(maxDailyLoss: 130, standDownLossRun: 0), now: now)
        #expect(s.status == .warn)
    }

    @Test func threeLossStreakStandsDown() {
        let s = LL.evaluate(closedTrades: [t(-1, closedAt: now), t(-1, closedAt: todayAt(1)), t(-1, closedAt: todayAt(2))],
                            policy: LossLimitPolicy(standDownLossRun: 3), now: now)
        #expect(s.lossRun == 3 && s.status == .halted)
        #expect(s.haltReason?.lowercased().contains("streak") == true)
    }

    @Test func breakevenScratchBreaksTheRun() {
        // recency: loss, then breakeven (R==0) → run stops at 1.
        let s = LL.evaluate(closedTrades: [t(-1, closedAt: now), t(0, closedAt: todayAt(1)), t(-1, closedAt: todayAt(2))],
                            policy: LossLimitPolicy(standDownLossRun: 3), now: now)
        #expect(s.lossRun == 1 && s.status == .ok)
    }

    @Test func yesterdaysLossExcludedFromTodayTally() {
        let s = LL.evaluate(closedTrades: [t(-5, closedAt: yesterday)],
                            policy: LossLimitPolicy(maxDailyLoss: 100, standDownLossRun: 0), now: now)
        #expect(abs(s.dailyRealized) < 1e-9 && s.status == .ok)   // not counted today
    }

    @Test func openTradesContributeNothing() {
        let s = LL.evaluate(closedTrades: [t(-1, closedAt: nil)],
                            policy: LossLimitPolicy(maxDailyLoss: 100), now: now)
        #expect(abs(s.dailyRealized) < 1e-9 && s.lossRun == 0 && s.status == .ok)
    }

    @Test func futureDatedWinnerDoesNotHideActiveStreak() {
        // A real 3-loss streak plus a mis-dated/typo'd WINNER with closedAt AFTER `now` must not
        // hide it: the future trade has to be excluded entirely, mirroring the `c <= now` guard
        // realized(since:) already applies. Unguarded, it sorts to the front (descending date) and
        // breaks the streak loop immediately, masking a real active loss streak.
        let futureWinner = t(2, closedAt: todayAt(-1))   // now + 1 hour
        let s = LL.evaluate(closedTrades: [t(-1, closedAt: now), t(-1, closedAt: todayAt(1)), t(-1, closedAt: todayAt(2)), futureWinner],
                            policy: LossLimitPolicy(standDownLossRun: 3), now: now)
        #expect(s.lossRun == 3 && s.status == .halted)
    }

    @Test func futureDatedLoserDoesNotInflateStreak() {
        // Symmetric case: a mis-dated/typo'd LOSER with closedAt AFTER `now` must not inflate a
        // real 1-loss streak into a 2-loss streak.
        let futureLoser = t(-3, closedAt: todayAt(-1))   // now + 1 hour
        let s = LL.evaluate(closedTrades: [t(-1, closedAt: now), futureLoser],
                            policy: LossLimitPolicy(standDownLossRun: 3), now: now)
        #expect(s.lossRun == 1 && s.status == .ok)
    }

    @Test func stopEqualsEntryLoserStillCountsInTheRun() {
        // A closed loser whose stop == entry has a real negative P&L but a NIL R — it must still
        // count toward (and not break) the loss streak (judged by realized P&L, not R).
        let zeroRiskLoser = TradeRecord(symbol: "Z", side: .long, entry: 100, stop: 100, target: nil,
                                        shares: 10, openedAt: Date(timeIntervalSince1970: 0),
                                        exitPrice: 95, closedAt: now)
        let s = LL.evaluate(closedTrades: [t(-1, closedAt: todayAt(1)), zeroRiskLoser],
                            policy: LossLimitPolicy(standDownLossRun: 2), now: now)
        #expect(s.lossRun == 2 && s.status == .halted)
    }

    @Test func weeklyFallbackWindowIsSevenDaysNotOneDay() {
        // #9 — fail-closed: the fallback start is dayStart − 6·86 400 s = −518 400 s exactly
        // (UTC Gregorian, no DST). The OLD code fell back to dayStart itself: a weekly gate
        // scoped to a single day, silently failing open.
        let dayStart = Date(timeIntervalSince1970: 1_751_500_800)
        let fallback = StockSageLossLimit.sevenDayFallbackStart(dayStart: dayStart)
        #expect(fallback.timeIntervalSince1970 == 1_751_500_800 - 518_400)
        #expect(fallback < dayStart)   // the property the old `?? dayStart` violated
    }
}
