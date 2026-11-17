import Testing
import Foundation
@testable import StockSage

// MARK: - StockSage value types (pure) — the shapes the signal engine/monitor read.

struct StockSageModelsTests {

    @Test func quoteChangePercentAndZeroGuard() {
        #expect(abs(StockSageQuote(price: 110, previousPrice: 100).changePercent - 10) < 1e-9)
        #expect(abs(StockSageQuote(price: 90, previousPrice: 100).changePercent - (-10)) < 1e-9)
        // No prior price → 0%, NOT NaN/inf (the divide-by-zero guard that protects alerts/UI).
        #expect(StockSageQuote(price: 50, previousPrice: 0).changePercent == 0)
    }

    @Test func symbolLatestIsMostRecentQuote() {
        let q1 = StockSageQuote(price: 100, previousPrice: 99)
        let q2 = StockSageQuote(price: 105, previousPrice: 100)
        #expect(StockSageSymbol(symbol: "X", market: "M", quotes: [q1, q2]).latest == q2)
        #expect(StockSageSymbol(symbol: "Y", market: "M").latest == nil)   // no quotes → nil, no crash
    }
}
