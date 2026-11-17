import Testing
import Foundation
@testable import StockSage

// MARK: - Risk-parity (inverse-volatility) sizing
//
// Pins the core property: weight ∝ 1/vol, so each holding contributes equal risk.

struct StockSageRiskParityTests {

    @Test func inverseVolWeightsEqualizeRiskContribution() {
        let t = StockSageRiskParity.targets([
            RiskParityHolding(symbol: "LOW",  currentValue: 0, volatility: 0.10),
            RiskParityHolding(symbol: "HIGH", currentValue: 0, volatility: 0.20),
        ])
        #expect(t.count == 2)
        let low = t.first { $0.symbol == "LOW" }!
        let high = t.first { $0.symbol == "HIGH" }!
        #expect(abs(low.targetWeight - 2.0 / 3.0) < 1e-9)    // lower vol → bigger weight
        #expect(abs(high.targetWeight - 1.0 / 3.0) < 1e-9)
        // Equal risk contribution: weight × vol is the same for both.
        #expect(abs(low.targetWeight * 0.10 - high.targetWeight * 0.20) < 1e-9)
        // Weights sum to 1.
        #expect(abs(t.reduce(0) { $0 + $1.targetWeight } - 1.0) < 1e-9)
    }

    @Test func equalVolGivesEqualWeights() {
        let t = StockSageRiskParity.targets([
            RiskParityHolding(symbol: "A", currentValue: 0, volatility: 0.15),
            RiskParityHolding(symbol: "B", currentValue: 0, volatility: 0.15),
        ])
        #expect(abs(t[0].targetWeight - 0.5) < 1e-9)
        #expect(abs(t[1].targetWeight - 0.5) < 1e-9)
    }

    @Test func dropsNonPositiveVolAndEmptyStaysEmpty() {
        #expect(StockSageRiskParity.targets([]).isEmpty)
        let t = StockSageRiskParity.targets([
            RiskParityHolding(symbol: "OK",  currentValue: 0, volatility: 0.20),
            RiskParityHolding(symbol: "BAD", currentValue: 0, volatility: 0.0),
        ])
        #expect(t.count == 1)
        #expect(t[0].symbol == "OK")
        #expect(abs(t[0].targetWeight - 1.0) < 1e-9)         // only one valid → 100%
    }

    @Test func threeHoldingsAllContributeEqualRisk() {
        let t = StockSageRiskParity.targets([
            RiskParityHolding(symbol: "A", currentValue: 0, volatility: 0.10),
            RiskParityHolding(symbol: "B", currentValue: 0, volatility: 0.20),
            RiskParityHolding(symbol: "C", currentValue: 0, volatility: 0.40),
        ])
        #expect(t.count == 3)
        // The whole point of risk parity: weightᵢ × volᵢ is equal across holdings.
        let contributions = t.map { $0.targetWeight * $0.volatility }
        for c in contributions { #expect(abs(c - contributions[0]) < 1e-9) }
        #expect(abs(t.reduce(0) { $0 + $1.targetWeight } - 1.0) < 1e-9)
    }

    @Test func rebalanceDeltasFromCurrentDollars() {
        let t = StockSageRiskParity.targets([
            RiskParityHolding(symbol: "A", currentValue: 100, volatility: 0.10),
            RiskParityHolding(symbol: "B", currentValue: 100, volatility: 0.20),
        ])
        let a = t.first { $0.symbol == "A" }!
        #expect(abs(a.currentWeight - 0.5) < 1e-9)           // equal dollars now
        #expect(a.deltaWeight > 0)                           // add to the lower-vol holding
        let amounts = StockSageRiskParity.rebalanceAmounts(t, totalValue: 200)
        #expect(amounts["A"]! > 0)
        #expect(amounts["B"]! < 0)
        #expect(abs(amounts["A"]! + amounts["B"]!) < 1e-6)   // deltas net to ~0
    }

    @Test func negativeCurrentValueSilentlyDropped() {
        let t = StockSageRiskParity.targets([
            RiskParityHolding(symbol: "SHORT", currentValue: -100, volatility: 0.20),
            RiskParityHolding(symbol: "LONG", currentValue: 100, volatility: 0.20),
        ])
        #expect(t.count == 1)
        #expect(t[0].symbol == "LONG")
    }

    @Test func allZeroCurrentValueUsesTargetAsCurrentWeight() {
        let t = StockSageRiskParity.targets([
            RiskParityHolding(symbol: "A", currentValue: 0, volatility: 0.10),
            RiskParityHolding(symbol: "B", currentValue: 0, volatility: 0.20),
        ])
        let a = t.first { $0.symbol == "A" }!
        let b = t.first { $0.symbol == "B" }!
        #expect(abs(a.targetWeight - 2.0/3.0) < 1e-9)
        #expect(abs(b.targetWeight - 1.0/3.0) < 1e-9)
        #expect(abs(a.deltaWeight) < 1e-9)
        #expect(abs(b.deltaWeight) < 1e-9)
    }
}
