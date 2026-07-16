import Testing
import Foundation
@testable import StockSage

// Correlation-aware portfolio heat: a cluster of mutually-correlated names is ~1 bet, so each
// member's weight is divided by the cluster size; uncorrelated names are untouched.
struct StockSageCorrelationHeatTests {
    typealias C = StockSageCorrelationCluster

    @Test func clusterMembersAreScaledByCountUncorrelatedUntouched() {
        let up: [Double]   = [0.01, 0.02, -0.01, 0.03, 0.01, -0.02, 0.02, 0.015]
        let down: [Double] = up.map { -$0 }   // perfectly ANTI-correlated → never in the cluster
        // A, B, C share identical returns (ρ = 1) → a 3-name cluster; D is anti-correlated → out.
        let symbols = ["A", "B", "C", "D"]
        let returns = [up, up, up, down]
        let weights = [0.06, 0.06, 0.06, 0.06]
        let adj = C.correlationAdjustedWeights(symbols: symbols, weights: weights, returns: returns)
        #expect(abs(adj[0] - 0.02) < 1e-9)   // 0.06 / 3
        #expect(abs(adj[1] - 0.02) < 1e-9)
        #expect(abs(adj[2] - 0.02) < 1e-9)
        #expect(abs(adj[3] - 0.06) < 1e-9)   // D unchanged
        // The cluster's COMBINED weight is now one position's worth, not three.
        #expect(abs((adj[0] + adj[1] + adj[2]) - 0.06) < 1e-9)
    }

    @Test func noClusterLeavesWeightsUnchanged() {
        // Three mutually low-correlation series → no ≥0.70 clique → identity.
        let a: [Double] = [0.01, -0.02, 0.03, -0.01, 0.02, -0.03, 0.01]
        let b: [Double] = [-0.02, 0.03, -0.01, 0.02, -0.03, 0.01, 0.0]
        let c: [Double] = [0.03, -0.01, -0.02, 0.0, 0.02, -0.01, 0.015]
        let w = [0.05, 0.05, 0.05]
        let adj = C.correlationAdjustedWeights(symbols: ["A", "B", "C"], weights: w, returns: [a, b, c])
        #expect(adj == w)
    }

    @Test func fewerThanThreeIsIdentity() {
        let w = [0.05, 0.05]
        #expect(C.correlationAdjustedWeights(symbols: ["A", "B"], weights: w, returns: [[0.01, 0.02], [0.01, 0.02]]) == w)
    }

    @Test func allocatorDeWeightsACorrelatedCluster() {
        let up: [Double]   = [100, 101, 100.5, 102, 101.5, 103, 102.5, 104]   // rising spark
        let down: [Double] = [104, 103, 103.5, 102, 102.5, 101, 101.5, 100]   // anti-correlated → out
        func idea(_ s: String, _ spark: [Double]) -> StockSageIdea {
            StockSageIdea(symbol: s, market: "M", price: 100,
                          advice: TradeAdvice(action: .buy, conviction: 0.5, regime: .bullTrend, rationale: [],
                                              stopPrice: 90, targetPrice: 130, suggestedWeight: 0, caveat: "x"),
                          spark: spark)
        }
        // A,B,C share a spark (ρ=1) → a 3-name cluster; D is anti-correlated → independent.
        let ideas = [idea("A", up), idea("B", up), idea("C", up), idea("D", down)]
        let plan = StockSageCapitalAllocator.allocate(ideas: ideas, account: 100_000, maxHeat: 0.99) // no heat scaling
        let rf = Dictionary(plan.positions.map { ($0.symbol, $0.riskFraction) }, uniquingKeysWith: { a, _ in a })
        // Each clustered member sized to ~1/3 of the uncorrelated D (same raw half-Kelly, divided by K=3).
        #expect((rf["A"] ?? 1) < (rf["D"] ?? 0) * 0.4)
        #expect(abs((rf["A"] ?? 0) - (rf["D"] ?? 0) / 3) < 1e-6)
        #expect(plan.caveat.contains("correlated cluster"))
    }
}
