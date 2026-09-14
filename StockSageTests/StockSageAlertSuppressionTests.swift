import Testing
import Foundation
@testable import StockSage

// BATCH 4a + 4b (2026-09-12) — suppression becomes visible, and a cap-refused crossing survives.
//
// These two had to land together. The budget's own header has claimed since 2026-07-28 that it is
// "deliberately NOT silent … so the app can tell the owner '12 other alerts were suppressed'" —
// but `suppressedAlertCount` had ZERO references outside tests, and was a computed property over a
// non-@Published stored struct, so even if rendered it would have painted once and never updated.
//
// 4b (owner-approved 2026-09-11, reversing the 2026-07-28 latching) stops the GLOBAL hourly cap
// destroying a crossing. Shipping 4b alone would have made the surfaced number nonsense: with
// nothing latching, one capped event re-consults the budget every 180s cycle, so a single held
// stop breach would report as ~20 suppressed alerts per hour. Hence the distinct-key counter.
@Suite("Alert suppression — visible, and not destructive")
struct StockSageAlertSuppressionTests {

    private typealias B = StockSageNotificationBudget
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func emptyBudget() throws -> B {
        let name = "suppression.empty.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        return B(loadingFrom: defaults, now: t0)
    }

    private func cappedBudget() throws -> B {
        var b = try emptyBudget()
        // Fill the rolling hour on DISTINCT symbols so no per-symbol brake is involved.
        for i in 0..<B.hourlyCap {
            b.record(symbol: "FILL\(i)", price: 100, now: t0)
        }
        return b
    }

    // MARK: D1 — the rule 4b turns on

    // The whole point: capacity is not a verdict about the symbol.
    @Test func onlyTheGlobalCapHoldsTheBaseline() {
        #expect(!B.shouldAdvanceBaseline(after: .hourlyCapReached))
        #expect(B.shouldAdvanceBaseline(after: .symbolCoolingDown))
        #expect(B.shouldAdvanceBaseline(after: .priceHasNotMovedEnough))
        // nil means delivered; the caller advances on its own success path.
        #expect(B.shouldAdvanceBaseline(after: nil))
    }

    // `refuse` must name the reason, not just say no — that distinction IS the fix.
    // NOTE: `#expect` captures its subexpressions immutably, so every `mutating` call below is
    // hoisted to a `let` first. Inlining one is a compile error, not a style choice.
    @Test func refuseNamesTheReasonTheCapAndTheBrakesAreDistinguishable() throws {
        var capped = try cappedBudget()
        let capRefusal = capped.refuse(symbol: "NEW", price: 100, now: t0)
        #expect(capRefusal == .hourlyCapReached,
                "a symbol never alerted before can only be refused by the GLOBAL cap")

        var cooling = try emptyBudget()
        cooling.record(symbol: "AAPL", price: 100, now: t0)
        let cool = cooling.refuse(symbol: "AAPL", price: 200, now: t0.addingTimeInterval(60))
        #expect(cool == .symbolCoolingDown)
        let flat = cooling.refuse(symbol: "AAPL", price: 100.1, now: t0.addingTimeInterval(3600))
        #expect(flat == .priceHasNotMovedEnough)

        // `allow` keeps its exact Bool contract for every existing caller.
        var b = try cappedBudget()
        let deniedByCap = b.allow(symbol: "NEW", price: 100, now: t0)
        #expect(!deniedByCap)
        var fresh = try emptyBudget()
        let allowed = fresh.allow(symbol: "FRESH", price: 100, now: t0)
        #expect(allowed)
    }

    // MARK: The counter the panel renders

    // Without distinct counting this is the number that would reach the owner's screen: the
    // monitor re-consults the budget every 180s, and under D1 a capped signal no longer latches,
    // so one held event would report as ~20 suppressed alerts an hour.
    @Test func repeatedPollsOfOneHeldEventCountAsOne() throws {
        var b = try cappedBudget()
        for cycle in 0..<20 {
            _ = b.refuse(symbol: "RKLB", price: 50, now: t0.addingTimeInterval(Double(cycle) * 180))
        }
        #expect(b.distinctSuppressedCount == 1, "one symbol, one reason, one held alert")
        // The raw attempt counter is unchanged and still pinned elsewhere — both are kept on
        // purpose, and only the distinct one is shown.
        #expect(b.suppressedSinceLastAllowed == 20)
    }

    @Test func distinctSymbolsAndDistinctReasonsCountSeparately() throws {
        var b = try cappedBudget()
        _ = b.refuse(symbol: "AAPL", price: 100, now: t0)
        _ = b.refuse(symbol: "NVDA", price: 100, now: t0)
        _ = b.refuse(symbol: "aapl", price: 100, now: t0)      // same symbol, different casing
        #expect(b.distinctSuppressedCount == 2)

        // A delivered push clears the shown number — the sentence says "since the last one
        // delivered", so a stale count would make that sentence false.
        b.record(symbol: "TSLA", price: 10, now: t0.addingTimeInterval(7200))
        #expect(b.distinctSuppressedCount == 0)
        #expect(b.suppressedSinceLastAllowed == 0)
    }

    // MARK: The sentence

    @Test func theSentenceNamesEveryBrakeAndReadsItsConstants() throws {
        #expect(MarketsView.suppressedPushSentence(held: 0) == nil, "nothing withheld ⇒ no line at all")

        let one = try #require(MarketsView.suppressedPushSentence(held: 1))
        #expect(one.contains("1 push alert was held back"))

        let many = try #require(MarketsView.suppressedPushSentence(held: 7))
        #expect(many.contains("7 push alerts were held back since the last one delivered"))
        // All three brakes are named: the count covers cooldown and hysteresis refusals too, so
        // blaming the hourly cap alone would be a false statement about why they were dropped.
        #expect(many.contains("\(B.hourlyCap)/hour"))
        #expect(many.contains("30-minute per-symbol cooldown"))
        #expect(many.contains("0.5%"))
        // Interpolated, not hardcoded — moving a constant must move the copy with it.
        #expect(many.contains("\(Int((B.symbolCooldown / 60).rounded()))-minute"))
    }
}
