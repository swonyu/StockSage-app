import Testing
import Foundation
@testable import StockSage

// MARK: - Sector tags (pure)

struct StockSageSectorTests {

    @Test func mapsKnownNamesAndFallsBack() {
        #expect(StockSageSector.sector("AAPL") == "Technology")
        #expect(StockSageSector.sector("nvda") == "Technology")     // case-insensitive
        #expect(StockSageSector.sector("JPM") == "Financials")
        #expect(StockSageSector.sector("XOM") == "Energy")
        #expect(StockSageSector.sector("JNJ") == "Healthcare")
        #expect(StockSageSector.sector("BTC-USD") == "Crypto")      // non-equity → asset class
        #expect(StockSageSector.sector("EURUSD=X") == "Forex")
        #expect(StockSageSector.sector("^GSPC") == "Index")
        #expect(StockSageSector.sector("2222.SR") == "Other")       // unmapped equity
        #expect(StockSageSector.sector("ZZZZ") == "Other")
    }

    @Test func sectorSlicesGroupByIndustry() {
        let holdings = [(symbol: "AAPL", value: 100.0), (symbol: "MSFT", value: 100.0), (symbol: "JPM", value: 100.0)]
        let s = StockSageAllocation.slices(holdings, by: StockSageSector.sector)
        #expect(s.first?.label == "Technology")
        #expect(abs((s.first?.fraction ?? 0) - 200.0 / 300.0) < 1e-9)
        #expect(s.count == 2)   // Technology + Financials
    }

    @Test func whatIfBySectorCrossesOnPiledTech() {
        // Tech 50% / Fin 50%; add 50 more Tech → Tech 100/150 ≈ 67% → crosses.
        let holdings = [(symbol: "AAPL", value: 50.0), (symbol: "JPM", value: 50.0)]
        let i = StockSageWhatIf.addingHolding(symbol: "MSFT", addedValue: 50, to: holdings,
                                              classify: StockSageSector.sector)
        #expect(i.candidateClass == "Technology")
        #expect(i.afterTopClass == "Technology")
        #expect(i.crossesConcentration)
    }
}
