import Testing
import Foundation
@testable import StockSage

// Notification rate control (owner report 2026-07-28: "it sends so much").
// Every threshold below is hand-checked arithmetic against the documented constants.

@Suite("Notification budget")
struct StockSageNotificationBudgetTests {

    typealias B = StockSageNotificationBudget
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: hysteresis — the wobble case that caused the spam

    @Test("a price wobbling across a threshold cannot re-alert")
    func hysteresisBlocksWobble() {
        // Alerted at 20.00. A 0.1% wobble (19.98 / 20.02) must stay silent even AFTER the
        // cooldown expires — this is precisely the 45-second-poll spam the owner reported.
        let last = B.AlertRecord(at: t0, price: 20.00)
        let afterCooldown = t0.addingTimeInterval(B.symbolCooldown + 60)
        #expect(B.refusal(last: last, alertsInLastHour: 0, price: 20.02, now: afterCooldown)
                == .priceHasNotMovedEnough)
        #expect(B.refusal(last: last, alertsInLastHour: 0, price: 19.98, now: afterCooldown)
                == .priceHasNotMovedEnough)
    }

    @Test("a real move clears hysteresis — the boundary is exactly 0.5%")
    func hysteresisBoundary() {
        let last = B.AlertRecord(at: t0, price: 100.0)
        let after = t0.addingTimeInterval(B.symbolCooldown + 1)
        // 0.5% of 100 is 0.50 exactly. 100.49 is inside (refused), 100.50 is at the edge (allowed).
        #expect(B.refusal(last: last, alertsInLastHour: 0, price: 100.49, now: after)
                == .priceHasNotMovedEnough)
        #expect(B.refusal(last: last, alertsInLastHour: 0, price: 100.50, now: after) == nil)
        #expect(B.refusal(last: last, alertsInLastHour: 0, price: 99.50, now: after) == nil)  // symmetric
    }

    // MARK: cooldown

    @Test("cooldown silences a symbol for 30 minutes even on a big move")
    func cooldownBlocksEvenLargeMoves() {
        let last = B.AlertRecord(at: t0, price: 100.0)
        // +20% one minute later is genuinely dramatic — still held, because two pushes a minute
        // apart is the behaviour being fixed.
        #expect(B.refusal(last: last, alertsInLastHour: 0, price: 120.0,
                          now: t0.addingTimeInterval(60)) == .symbolCoolingDown)
        // Just before / after the boundary.
        #expect(B.refusal(last: last, alertsInLastHour: 0, price: 120.0,
                          now: t0.addingTimeInterval(B.symbolCooldown - 1)) == .symbolCoolingDown)
        #expect(B.refusal(last: last, alertsInLastHour: 0, price: 120.0,
                          now: t0.addingTimeInterval(B.symbolCooldown)) == nil)
    }

    @Test("a symbol's first ever alert is never refused for cooldown or hysteresis")
    func firstAlertAlwaysPasses() {
        #expect(B.refusal(last: nil, alertsInLastHour: 0, price: 42, now: t0) == nil)
    }

    // MARK: global cap — the crash-day flood

    @Test("the rolling hourly cap outranks everything else")
    func globalCapWins() {
        // At the cap, even a brand-new symbol with a huge move is refused: on a day when every
        // name crosses at once, 60 pushes are worse than 8 plus a count of what was held.
        #expect(B.refusal(last: nil, alertsInLastHour: B.hourlyCap, price: 999, now: t0)
                == .hourlyCapReached)
        #expect(B.refusal(last: nil, alertsInLastHour: B.hourlyCap - 1, price: 999, now: t0) == nil)
    }

    @Test("the hour window rolls — old alerts stop counting")
    func hourWindowRolls() {
        let stamps = [t0.addingTimeInterval(-7200),   // 2h ago — outside
                      t0.addingTimeInterval(-3601),   // just outside
                      t0.addingTimeInterval(-3599),   // just inside
                      t0.addingTimeInterval(-60)]     // inside
        #expect(B.countWithinHour(stamps, now: t0) == 2)
        #expect(B.countWithinHour([], now: t0) == 0)
    }

    // MARK: stateful behaviour + visibility

    @Test("suppression is COUNTED, never silent")
    func suppressionIsVisible() {
        var b = B()
        let first = b.allow(symbol: "AAPL", price: 100, now: t0)
        #expect(first)
        b.record(symbol: "AAPL", price: 100, now: t0)
        #expect(b.suppressedSinceLastAllowed == 0)

        // three wobble attempts inside the cooldown
        var wobbleResults: [Bool] = []
        for p in [100.1, 99.9, 100.05] {
            wobbleResults.append(b.allow(symbol: "AAPL", price: p, now: t0.addingTimeInterval(120)))
        }
        #expect(wobbleResults == [false, false, false])
        #expect(b.suppressedSinceLastAllowed == 3)   // the UI can say "3 held back"

        // a real move after the cooldown gets through and resets the counter
        let later = t0.addingTimeInterval(B.symbolCooldown + 10)
        let afterMove = b.allow(symbol: "AAPL", price: 110, now: later)
        #expect(afterMove)
        b.record(symbol: "AAPL", price: 110, now: later)
        #expect(b.suppressedSinceLastAllowed == 0)
    }

    @Test("symbols are independent and case-insensitive")
    func symbolsAreIndependentAndNormalised() {
        var b = B()
        let first = b.allow(symbol: "AAPL", price: 100, now: t0)
        #expect(first)
        b.record(symbol: "AAPL", price: 100, now: t0)
        // a DIFFERENT symbol is unaffected by AAPL's cooldown
        let other = b.allow(symbol: "2222.SR", price: 30, now: t0.addingTimeInterval(60))
        #expect(other)
        // the same symbol in lower case must hit the same cooldown, not slip through
        let sameLowercased = b.allow(symbol: "aapl", price: 100.05, now: t0.addingTimeInterval(60))
        #expect(!sameLowercased)
    }

    @Test("clearing a symbol re-arms it — an explicit owner action is never silenced")
    func clearReArms() {
        var b = B()
        b.record(symbol: "AAPL", price: 100, now: t0)
        let blocked = b.allow(symbol: "AAPL", price: 100.1, now: t0.addingTimeInterval(60))
        #expect(!blocked)
        b.clear(symbol: "AAPL")
        let reArmed = b.allow(symbol: "AAPL", price: 100.1, now: t0.addingTimeInterval(60))
        #expect(reArmed)
    }
}
