import Testing
@testable import StockSage

// MARK: - Weekly turnover disclosure (Item A, label-only)
//
// Fixtures + expected values HAND-DERIVED in /tmp/derive_weekly_turnover.swift (output pasted
// in plans/PLAN_2026-07-03_calc_wave2_cost_honesty.md Step 4a) — never from the code under test.
// Ideas carry spark [] and no dailyMove, so expectedHoldDays = the class base (equity 12, crypto 3).

struct StockSageWeeklyTurnoverTests {
    typealias EV = StockSageExpectedValue

    private func idea(_ symbol: String, conviction: Double = 0.9) -> StockSageIdea {
        StockSageIdea(symbol: symbol, market: "M", price: 100,
                      advice: TradeAdvice(action: .buy, conviction: conviction, regime: .bullTrend,
                                          rationale: [], stopPrice: 90, targetPrice: 130,
                                          suggestedWeight: 0.05, caveat: "x"),
                      spark: [])
    }

    @Test func twoEquitySlotsSumTheirWeeklyCycles() {
        // derive_weekly_turnover: 5/12 + 5/12 = 0.8333…
        let trips = EV.assumedWeeklyRoundTrips([idea("AAA"), idea("BBB")], tradingDays: 5)
        #expect(trips != nil && abs(trips! - (5.0 / 12 + 5.0 / 12)) < 1e-9)
    }

    @Test func topThreePrefixExcludesTheWeakestCrypto() {
        // derive_weekly_turnover: sum = 3·(5/3) = 5.0 exactly; a wrongly-included 4th would read
        // 6.667. MEASURED SCOPE (2026-07-03 review): all four fixtures are crypto with the same
        // 3d hold, so ANY 3-of-4 subset sums to 5.0 — this pins the prefix(3) COUNT cap only,
        // not WHICH three were taken (the name, kept for plan cross-refs, overstates); pinning
        // rank order would need a mixed-class 4th idea with a different hold.
        let ideas = [idea("AAA-USD"), idea("BBB-USD"), idea("CCC-USD"), idea("DDD-USD", conviction: 0.45)]
        let trips = EV.assumedWeeklyRoundTrips(ideas, maxConcurrent: 3, tradingDays: 5)
        #expect(trips != nil && abs(trips! - 5.0) < 1e-9)
    }

    @Test func noCadenceMeansNilNeverAFabricatedNumber() {
        // FX has no hold (expectedHoldDays nil) → out of the fast lane → nil, not 0.
        #expect(EV.assumedWeeklyRoundTrips([idea("EURUSD=X")], tradingDays: 5) == nil)
        #expect(EV.assumedWeeklyRoundTrips([], tradingDays: 5) == nil)
        #expect(EV.weeklyTurnoverNote([], tradingDays: 5) == nil)
    }

    @Test func noteDisclosesTripCountAndStaysLabelOnly() {
        let note = EV.weeklyTurnoverNote([idea("AAA"), idea("BBB")], tradingDays: 5)
        guard let note else { Issue.record("note should exist for two equity ideas"); return }
        #expect(note.contains("≈0.8 round trips"))            // derive: %.1f of 0.8333
        #expect(note.contains("gross figure excludes"))       // names the exclusion, nets nothing
        #expect(!note.lowercased().contains("guarantee"))
    }
}
