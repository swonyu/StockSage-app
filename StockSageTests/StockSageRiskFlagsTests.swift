import Testing
import Foundation
@testable import StockSage

// MARK: - Consolidated risk flags (pure)

struct StockSageRiskFlagsTests {

    typealias RF = StockSageRiskFlags

    private func imminent() -> EarningsProximity {
        StockSageEarnings.proximity(now: Date(timeIntervalSince1970: 0),
                                    earnings: Date(timeIntervalSince1970: 2 * 86_400))
    }
    private func concentrating() -> CorrelationPrecheck {
        CorrelationPrecheck(verdict: .concentrating, avgCorrelation: 0.8, comparedCount: 3,
                            mostCorrelatedSymbol: "NVDA", mostCorrelation: 0.85)
    }

    @Test func cleanEquityBuyHasNoFlags() {
        let f = RF.flags(action: .buy, conviction: 0.8, symbol: "AAPL",
                         earnings: nil, precheck: nil, regimeIsStale: false, hasRegime: true)
        #expect(f.isEmpty)
    }

    @Test func earningsAndConcentrationAreHighAndSortedFirst() {
        let f = RF.flags(action: .buy, conviction: 0.8, symbol: "AAPL",
                         earnings: imminent(), precheck: concentrating(),
                         regimeIsStale: false, hasRegime: true)
        #expect(f.count == 2)
        #expect(f.allSatisfy { $0.level == .high })
        #expect(f.contains { $0.label == "Earnings ≤3d" })
        #expect(f.contains { $0.label == "Concentrating" })
    }

    @Test func lowConvictionAndStaleRegimeAreCautions() {
        let f = RF.flags(action: .buy, conviction: 0.3, symbol: "AAPL",
                         earnings: nil, precheck: nil, regimeIsStale: true, hasRegime: true)
        #expect(f.contains { $0.label == "Low conviction" && $0.level == .caution })
        #expect(f.contains { $0.label == "Stale regime" })
        // Stale regime only counts when a regime exists.
        let none = RF.flags(action: .buy, conviction: 0.8, symbol: "AAPL",
                            earnings: nil, precheck: nil, regimeIsStale: true, hasRegime: false)
        #expect(none.isEmpty)
    }

    @Test func thinLiquidityRaisesAFlag() {
        let f = RF.flags(action: .buy, conviction: 0.8, symbol: "AAPL",
                         earnings: nil, precheck: nil, regimeIsStale: false, hasRegime: true,
                         liquidityTier: .thin)
        #expect(f.contains { $0.label == "Thin liquidity" })
        // Deep liquidity raises nothing.
        let deep = RF.flags(action: .buy, conviction: 0.8, symbol: "AAPL",
                            earnings: nil, precheck: nil, regimeIsStale: false, hasRegime: true,
                            liquidityTier: .deep)
        #expect(!deep.contains { $0.label == "Thin liquidity" })
    }

    @Test func cryptoFlagsItsStructuralVol() {
        let f = RF.flags(action: .buy, conviction: 0.8, symbol: "BTC-USD",
                         earnings: nil, precheck: nil, regimeIsStale: false, hasRegime: true)
        #expect(f.contains { $0.label == "Crypto vol 24/7" })
    }

    @Test func avoidActionFlagsNoEdge() {
        let f = RF.flags(action: .avoid, conviction: 0.5, symbol: "AAPL",
                         earnings: nil, precheck: nil, regimeIsStale: false, hasRegime: true)
        #expect(f.contains { $0.label == "No edge (choppy)" })
    }

    @Test func avoidDoesNotDoubleFireLowConviction() {
        let f = RF.flags(action: .avoid, conviction: 0.2, symbol: "AAPL",
                         earnings: nil, precheck: nil, regimeIsStale: false, hasRegime: true)
        #expect(f.contains { $0.label == "No edge (choppy)" })
        #expect(!f.contains { $0.label == "Low conviction" })   // redundant on a stand-aside
    }

    @Test func mostSevereSortsFirst() {
        let f = RF.flags(action: .avoid, conviction: 0.3, symbol: "ETH-USD",
                         earnings: imminent(), precheck: nil, regimeIsStale: false, hasRegime: true)
        #expect(f.first?.level == .high)   // Earnings ≤3d ahead of the cautions
    }
}
