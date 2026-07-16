import Testing
import Foundation
@testable import StockSage

// MARK: - Allocation breakdown (pure)

struct StockSageAllocationTests {

    typealias AL = StockSageAllocation

    @Test func assetClassFromSymbolConvention() {
        #expect(AL.assetClass("AAPL") == "Equity")
        #expect(AL.assetClass("2222.SR") == "Equity")
        #expect(AL.assetClass("EURUSD=X") == "Forex")
        #expect(AL.assetClass("BTC-USD") == "Crypto")
        #expect(AL.assetClass("^GSPC") == "Index")
    }

    @Test func regionFromSuffix() {
        #expect(AL.region("AAPL") == "United States")
        #expect(AL.region("2222.SR") == "Saudi")
        #expect(AL.region("7203.T") == "Japan")
        #expect(AL.region("BTC-USD") == "Global")
        #expect(AL.region("^GSPC") == "Index")
    }

    @Test func breakdownSumsAndSorts() {
        let b = AL.breakdown([("AAPL", 100), ("MSFT", 100), ("2222.SR", 50), ("BTC-USD", 50)])
        #expect(b.totalValue == 300)
        // By class: Equity 250 (.833) > Crypto 50 (.167)
        #expect(b.byClass.first?.label == "Equity")
        #expect(abs((b.byClass.first?.fraction ?? 0) - 250.0 / 300.0) < 1e-9)
        #expect(b.byClass.count == 2)
        #expect(abs(b.topClassConcentration - 250.0 / 300.0) < 1e-9)
        // By region: US 200, Saudi 50, Global 50
        #expect(b.byRegion.first?.label == "United States")
        // Fractions sum to ~1
        #expect(abs(b.byClass.reduce(0) { $0 + $1.fraction } - 1.0) < 1e-9)
    }

    @Test func emptyAndZeroValueHoldings() {
        #expect(AL.breakdown([]).byClass.isEmpty)
        #expect(AL.breakdown([("AAPL", 0)]).totalValue == 0)
        #expect(AL.breakdown([("AAPL", 0)]).byClass.isEmpty)   // zero-value dropped
    }

    @Test func mixedSignHoldingsShortsDroppedFromConcentration() {
        let b = StockSageAllocation.breakdown([("AAPL", 100), ("SHY", -50), ("MSFT", 75)])
        #expect(b.totalValue == 175)
        #expect(b.byClass.count == 1)
        #expect(abs(b.topClassConcentration - 1.0) < 1e-9)
    }

    // Exact-fraction tie (50/50 Equity vs Crypto): pre-fix, the winner depended on
    // Dictionary.map's randomized iteration order, so `.first` (topClassConcentration's
    // label) could differ across runs for byte-identical input. The sort must break ties
    // deterministically (alphabetically by label) so the order is stable every run.
    @Test func exactFractionTieBreaksDeterministicallyByLabel() {
        let holdings: [(symbol: String, value: Double)] = [("AAPL", 100), ("BTC-USD", 100)]
        for _ in 0..<20 {
            let b = AL.breakdown(holdings)
            #expect(b.byClass.count == 2)
            #expect(abs((b.byClass[0].fraction) - 0.5) < 1e-9)
            #expect(abs((b.byClass[1].fraction) - 0.5) < 1e-9)
            // "Crypto" < "Equity" alphabetically — must always win the tie.
            #expect(b.byClass[0].label == "Crypto")
            #expect(b.byClass[1].label == "Equity")
            #expect(b.topClassConcentration == b.byClass[0].fraction)
        }
    }
}
