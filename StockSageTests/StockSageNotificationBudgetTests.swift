import Testing
import Foundation
@testable import StockSage

// Notification rate control (owner report 2026-07-28: "it sends so much").
// Every threshold below is hand-checked arithmetic against the documented constants.

@Suite("Notification budget")
struct StockSageNotificationBudgetTests {

    typealias B = StockSageNotificationBudget
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func emptyBudget() throws -> B {
        let name = "budget.empty.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        return B(loadingFrom: defaults, now: t0)
    }

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
    func suppressionIsVisible() throws {
        var b = try emptyBudget()
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
    func symbolsAreIndependentAndNormalised() throws {
        var b = try emptyBudget()
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
    func clearReArms() throws {
        var b = try emptyBudget()
        b.record(symbol: "AAPL", price: 100, now: t0)
        let blocked = b.allow(symbol: "AAPL", price: 100.1, now: t0.addingTimeInterval(60))
        #expect(!blocked)
        b.clear(symbol: "AAPL")
        let reArmed = b.allow(symbol: "AAPL", price: 100.1, now: t0.addingTimeInterval(60))
        #expect(reArmed)
    }

    // MARK: persistence — the cold-start burst (second review, 2026-07-28)

    @Test("budget state survives a process kill — the cold-start burst cannot recur")
    func statePersistsAcrossRelaunch() throws {
        let suite = try #require(UserDefaults(suiteName: "budget.persist.test"))
        suite.removePersistentDomain(forName: "budget.persist.test")

        var first = B(loadingFrom: suite, now: t0)
        first.record(symbol: "AAPL", price: 100, now: t0)
        first.save(to: suite)

        // Simulate the OS killing the app and the owner relaunching a minute later: a FRESH
        // instance must still know AAPL is cooling down. In-memory-only state forgot this, and
        // that is what pushed an alert for every threshold-crossing name ~20s after launch.
        var relaunched = B(loadingFrom: suite, now: t0.addingTimeInterval(60))
        let blocked = relaunched.allow(symbol: "AAPL", price: 100.1, now: t0.addingTimeInterval(60))
        #expect(!blocked, "a relaunched process must honour the cooldown it recorded before dying")

        suite.removePersistentDomain(forName: "budget.persist.test")
    }

    @Test("relaunch preserves price hysteresis after cooldown and hourly timestamps expire")
    func relaunchMatchesContinuingBudget() throws {
        let name = "budget.restart.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        var original = B(loadingFrom: suite, now: t0)
        original.record(symbol: "AAPL", price: 100, now: t0)
        original.save(to: suite)

        // N19: cooldown expiry must not erase the independent last-alerted-price anchor.
        // Exercise the real save/load/allow chain on both sides of each time boundary.
        for seconds in [60.0, 1799, 1800, 1860, 3600, 3601, 86_400] {
            let now = t0.addingTimeInterval(seconds)
            for price in [100.0, 100.1, 99.9, 100.49, 100.5, 99.5, 101] {
                var continuing = original
                var restored = B(loadingFrom: suite, now: now)
                let before = continuing.allow(symbol: "aapl", price: price, now: now)
                let after = restored.allow(symbol: "aapl", price: price, now: now)
                #expect(after == before, "restart changed decision at \(seconds)s / \(price)")
                #expect(restored.perSymbol["AAPL"] == original.perSymbol["AAPL"])
                #expect(restored.recentAlerts == continuing.recentAlerts)
                #expect(restored.suppressedSinceLastAllowed == continuing.suppressedSinceLastAllowed)
            }
        }
    }

    @Test("explicitly cleared hysteresis stays cleared after save and relaunch")
    func clearedAnchorDoesNotReturn() throws {
        let name = "budget.clear.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        var first = B(loadingFrom: suite, now: t0)
        first.record(symbol: "AAPL", price: 100, now: t0)
        first.record(symbol: "MSFT", price: 200, now: t0)
        first.save(to: suite)
        let later = t0.addingTimeInterval(1860)
        var restored = B(loadingFrom: suite, now: later)
        restored.clear(symbol: "aapl")
        restored.save(to: suite)
        var final = B(loadingFrom: suite, now: later)
        let clearedAllowed = final.allow(symbol: "AAPL", price: 100, now: later)
        let otherAllowed = final.allow(symbol: "MSFT", price: 200, now: later)
        #expect(clearedAllowed)
        #expect(!otherAllowed)
        #expect(final.recentAlerts.count == 2) // clearing one anchor never erases the global cap
    }

    @Test("a corrupt or absent blob loads as empty rather than crashing")
    func corruptBlobIsSafe() throws {
        let suite = try #require(UserDefaults(suiteName: "budget.corrupt.test"))
        suite.set(Data("not json".utf8), forKey: "stocksage.notify.budgetState.v1")
        var b = B(loadingFrom: suite, now: t0)
        let allowed = b.allow(symbol: "ANY", price: 1, now: t0)
        #expect(allowed)
        suite.removePersistentDomain(forName: "budget.corrupt.test")
    }
}
