import Testing
import Foundation
@testable import StockSage

// MARK: - Honesty guard for the NEW money engines (hardening #11 extension)
//
// The existing caveat sweep (StockSageGlossaryTests) pins MoneyVelocityCopy + the glossary.
// This extends the same structural guard to the money/risk engines added in the 2026-06-22
// hardening pass, so a future edit that drops a caveat from PortfolioHeat / TimeStop becomes
// a failing test rather than a silent over-promise.

struct StockSageHonestyGuardTests {
    private let hedges = ["estimate", "not ", "assum", "surviv", "variance", "ceiling",
                          "volume", "clock", "may ", "hypothetical", "past", "gap"]
    private func hedged(_ s: String) -> Bool { let l = s.lowercased(); return hedges.contains { l.contains($0) } }

    @Test func portfolioHeatCarriesACaveat() {
        let h = StockSagePortfolioHeat.compute(openTrades: [(10, 100, 90)], accountSize: 10_000)!
        #expect(hedged(h.caveat))   // "Assumes … a correlated gap can hit several at once…"
    }

    @Test func timeStopRationaleIsHedgedBothStates() {
        let t0 = Date(timeIntervalSince1970: 0)
        let exit = StockSageTimeStop.suggest(openedAt: t0, now: Date(timeIntervalSince1970: 20 * 86_400), daysToHold: 10)!
        #expect(exit.shouldExit && hedged(exit.rationale))   // "…a clock, not a sell signal"
        let running = StockSageTimeStop.suggest(openedAt: t0, now: Date(timeIntervalSince1970: 5 * 86_400), daysToHold: 10)!
        #expect(!running.shouldExit)   // running state is a plain count, not a money claim
    }

    @Test func netEdgeCostsAreLabeledByAssetClass() {
        // The cost assumption must name its asset class so the UI can label it an estimate.
        #expect(StockSageNetEdge.defaultCosts(forSymbol: "BTC-USD").assetClass == "crypto")
        #expect(StockSageNetEdge.defaultCosts(forSymbol: "AAPL").assetClass == "US large-cap")
    }
}
