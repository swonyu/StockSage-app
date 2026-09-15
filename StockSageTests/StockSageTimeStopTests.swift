import Testing
import Foundation
@testable import StockSage

// MARK: - Time stop (pure)

struct StockSageTimeStopTests {
    typealias TS = StockSageTimeStop
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func plus(_ days: Double) -> Date { t0.addingTimeInterval(days * 86_400) }

    @Test func sessionBasisIsExplicitAndInvalidDatesDoNotBecomeCounts() {
        #expect(StockSageTimeStop.basis(for: "AAPL") == .nasdaqSessions)
        #expect(StockSageTimeStop.basis(for: "BTC-USD") == .elapsedDays)
        #expect(StockSageTimeStop.basis(for: "000001.SZ") == nil)
        #expect(StockSageTimeStop.basis(for: "EURUSD=X") == nil)
        #expect(StockSageTimeStop.suggest(openedAt: Date(timeIntervalSince1970: .infinity), now: Date(), daysToHold: 7, basis: .nasdaqSessions) == nil)
    }

    @Test func sessionClockSkipsClosedDatesAndCountsOnlyCompletedCloses() throws {
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        let opened = date("2026-09-04T15:00:00Z")
        let before = try #require(TS.suggest(openedAt: opened, now: date("2026-09-08T19:59:59Z"), daysToHold: 1, basis: .nasdaqSessions))
        #expect(before.daysHeld == 0 && !before.shouldExit)
        let after = try #require(TS.suggest(openedAt: opened, now: date("2026-09-08T20:00:00Z"), daysToHold: 1, basis: .nasdaqSessions))
        #expect(after.daysHeld == 1 && after.shouldExit)
        #expect(after.rationale.contains("sessions"))
        let half = try #require(TS.suggest(openedAt: date("2026-11-25T15:00:00Z"), now: date("2026-11-27T18:00:00Z"), daysToHold: 1, basis: .nasdaqSessions))
        #expect(half.daysHeld == 1)
        #expect(TS.suggest(openedAt: date("2026-12-31T15:00:00Z"), now: date("2027-01-04T21:00:00Z"), daysToHold: 1, basis: .nasdaqSessions) == nil)
        let crypto = try #require(TS.suggest(openedAt: opened, now: date("2026-09-08T15:00:00Z"), daysToHold: 7, basis: .elapsedDays))
        #expect(crypto.daysHeld == 4)
    }

    @Test func countsDaysAndFlagsAtTheLimit() {
        // Day 5 of a 10-day plan → still running.
        let mid = TS.suggest(openedAt: t0, now: plus(5), daysToHold: 10)!
        #expect(mid.daysHeld == 5 && mid.daysRemaining == 5 && !mid.shouldExit)
        #expect(mid.rationale.contains("5 days left"))
        // Exactly at the limit (>=) → exit.
        let at = TS.suggest(openedAt: t0, now: plus(10), daysToHold: 10)!
        #expect(at.daysHeld == 10 && at.daysRemaining == 0 && at.shouldExit)
        #expect(at.rationale.lowercased().contains("time-stop reached"))
        // Overdue.
        let over = TS.suggest(openedAt: t0, now: plus(12), daysToHold: 10)!
        #expect(over.daysHeld == 12 && over.daysRemaining == -2 && over.shouldExit)
    }

    @Test func sameDayAndGuards() {
        let sameDay = TS.suggest(openedAt: t0, now: t0, daysToHold: 10)!
        #expect(sameDay.daysHeld == 0 && !sameDay.shouldExit)
        #expect(TS.suggest(openedAt: t0, now: plus(5), daysToHold: 0) == nil)   // no plan → nil
        // now before open clamps to 0, not negative.
        #expect(TS.suggest(openedAt: t0, now: plus(-3), daysToHold: 10)!.daysHeld == 0)
    }

    @Test func tradeRecordDaysHeld() {
        // Open trade: held to `now`. Closed: held to closedAt.
        let open = TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                               openedAt: t0, exitPrice: nil, closedAt: nil)
        #expect(open.daysHeld(asOf: plus(7)) == 7)
        let closed = TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                                 openedAt: t0, exitPrice: 110, closedAt: plus(4))
        #expect(closed.daysHeld(asOf: plus(99)) == 4)   // ignores `now`, uses closedAt
    }
}
