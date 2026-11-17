import Testing
import Foundation
@testable import StockSage

// MARK: - regimeWarningNeeded honesty-disclosure predicate (round-I, 2026-07-09)
//
// Pins MarketsView.regimeWarningNeeded(regime:isStale:) — the pure predicate behind the
// Deploy-capital plan's regime-not-gauged warning banner. THE BUG: the allocator's regime
// step (`regime.map { adjustedWeight } ?? suggestedFraction`) silently no-ops when regime is
// nil, and the plan.caveat regime note is only appended when a regime IS present — so an
// ungauged/stale plan previously shipped with zero on-screen disclosure that it carries no
// risk-off/on brake. Truth table is definitional (an OR of two Bools), no external spec to
// hand-derive against — each case pinned directly per gated-scope's "trivial one-liner" carve-out.

struct MarketsRegimeWarningNeededTests {
    typealias M = MarketsView

    @Test func nilRegimeAlwaysWarns() {
        // Never gauged (store.regime == nil) -> warn, regardless of the isStale flag's value.
        #expect(M.regimeWarningNeeded(regime: nil, isStale: true) == true)
        #expect(M.regimeWarningNeeded(regime: nil, isStale: false) == true)
    }

    @Test func staleRegimeWarnsEvenWhenPresent() {
        // Gauged once but stale (>6h old per store.regimeIsStale) -> still warn, the brake it
        // applied is untrustworthy for the CURRENT tape.
        let stale = MarketRegime(state: .ranging, riskScore: 0, signals: [], sizingBias: 1.0, caveat: "test")
        #expect(M.regimeWarningNeeded(regime: stale, isStale: true) == true)
    }

    @Test func freshPresentRegimeDoesNotWarn() {
        // Gauged AND fresh -> no NEW warning; the allocator's own plan.caveat regime note
        // already discloses this case (allocate() lines ~134-136), so rendering nothing here
        // avoids a redundant banner.
        let fresh = MarketRegime(state: .trendingBull, riskScore: 0.8, signals: [], sizingBias: 1.15, caveat: "test")
        #expect(M.regimeWarningNeeded(regime: fresh, isStale: false) == false)
    }
}
