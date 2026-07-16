import Testing
import Foundation
@testable import StockSage

// MARK: - Risk-parity vs equal-weight (pure)

struct StockSageRiskParityVsEqualTests {

    typealias RP = StockSageRiskParity

    private func target(_ symbol: String, _ targetWeight: Double, vol: Double) -> RiskParityTarget {
        RiskParityTarget(symbol: symbol, currentWeight: 0.5, targetWeight: targetWeight, volatility: vol)
    }

    @Test func trimsTheVolHogAndAddsToTheCalm() {
        // Equal weight = 0.5. HOG target 0.20 → −0.30 ; CALM target 0.80 → +0.30.
        let v = RP.vsEqualWeight([target("HOG", 0.20, vol: 0.40), target("CALM", 0.80, vol: 0.10)])!
        #expect(v.count == 2)
        #expect(abs(v.equalWeight - 0.5) < 1e-9)
        #expect(v.trimSymbol == "HOG")
        #expect(abs(v.trimDelta - (-0.30)) < 1e-9)
        #expect(v.addSymbol == "CALM")
        #expect(abs(v.addDelta - 0.30) < 1e-9)
        #expect(v.note.contains("HOG"))
    }

    @Test func threeWayPicksTheExtremes() {
        // Equal weight = 1/3 ≈ 0.3333. targets 0.2 / 0.3 / 0.5.
        let v = RP.vsEqualWeight([
            target("A", 0.2, vol: 0.5), target("B", 0.3, vol: 0.3), target("C", 0.5, vol: 0.1),
        ])!
        #expect(v.trimSymbol == "A")                       // 0.2 − 0.333 ≈ −0.133 (most negative)
        #expect(v.addSymbol == "C")                        // 0.5 − 0.333 ≈ +0.167 (most positive)
        #expect(abs(v.trimDelta - (0.2 - 1.0 / 3)) < 1e-9)
        #expect(abs(v.addDelta - (0.5 - 1.0 / 3)) < 1e-9)
    }

    @Test func fewerThanTwoIsNil() {
        #expect(RP.vsEqualWeight([target("A", 1.0, vol: 0.2)]) == nil)
        #expect(RP.vsEqualWeight([]) == nil)
    }
}
