import Testing
import Foundation
@testable import StockSage

// MARK: - What-if portfolio impact (pure)

struct StockSageWhatIfTests {

    typealias WI = StockSageWhatIf

    @Test func addingMoreOfTheTopClassCanCrossConcentrated() {
        // Before: Crypto 60%, Equity 40% (top 0.60, not over). Add 40 more crypto →
        // Crypto 100/140 ≈ 71% → crosses.
        let holdings = [(symbol: "AAPL", value: 40.0), (symbol: "BTC-USD", value: 60.0)]
        let i = WI.addingHolding(symbol: "ETH-USD", addedValue: 40, to: holdings)
        #expect(i.candidateClass == "Crypto")
        #expect(i.afterTopClass == "Crypto")
        #expect(i.afterTopFraction > 0.70 && i.afterTopFraction < 0.72)
        #expect(i.crossesConcentration)
        #expect(i.isWarning)
        #expect(i.note.contains("CONCENTRATED"))
    }

    @Test func addingADifferentClassReducesConcentration() {
        // Before: Crypto 80%. Add equity 80 → Equity 100/180 ≈ 56% top → no cross.
        let holdings = [(symbol: "BTC-USD", value: 80.0), (symbol: "AAPL", value: 20.0)]
        let i = WI.addingHolding(symbol: "MSFT", addedValue: 80, to: holdings)
        #expect(i.beforeTopClass == "Crypto")
        #expect(i.afterTopClass == "Equity")
        #expect(!i.crossesConcentration)
        #expect(i.afterTopFraction < 0.60)
    }

    @Test func proposedAddValueCapsLeveragedNotionalToCash() {
        // A tight-stop sizer notional ($200k) on a $20k account is leverage, not
        // cash to add — cap it at the account so it can't fabricate concentration.
        #expect(WI.proposedAddValue(sizedNotional: 200_000, account: 20_000, bookTotal: 20_000) == 20_000)
        // No sized notional → 10% of the book.
        #expect(WI.proposedAddValue(sizedNotional: nil, account: 20_000, bookTotal: 20_000) == 2_000)

        // End-to-end: the capped add must NOT spuriously cross 60% on a normal book.
        let book = [(symbol: "BTC-USD", value: 18_000.0), (symbol: "AAPL", value: 2_000.0)]
        let add = WI.proposedAddValue(sizedNotional: 200_000, account: 20_000, bookTotal: 20_000)
        let i = WI.addingHolding(symbol: "MSFT", addedValue: add, to: book)
        #expect(!i.crossesConcentration)   // equity → 22k/40k = 55%, below 60%
    }

    @Test func noteReportsBothLeadersWhenTopClassFlips() {
        // Before: Forex 40%, Equity 35%, Crypto 25% (top = Forex ~40%, not Crypto).
        // Add 50 more crypto → Crypto 75/150 = 50% (new top), below the 60% concentration
        // line. The note must NOT claim Crypto "rises from ~40%" — that 40% belonged to
        // Forex, not Crypto (candidate's own before-share was 25%). It should instead name
        // both distinct leaders with their own correct percentages.
        let holdings = [(symbol: "EURUSD=X", value: 40.0), (symbol: "AAPL", value: 35.0), (symbol: "BTC-USD", value: 25.0)]
        let i = WI.addingHolding(symbol: "ETH-USD", addedValue: 50, to: holdings)
        #expect(i.candidateClass == "Crypto")
        #expect(i.beforeTopClass == "Forex")
        #expect(i.afterTopClass == "Crypto")
        #expect(i.afterTopFraction == 0.5)
        #expect(!i.crossesConcentration)
        #expect(!i.note.contains("raises Crypto"))
        #expect(!i.note.contains("from ~40%"))
        #expect(i.note == "Top class shifts from Forex (~40%) to Crypto (~50%).")
    }

    @Test func alreadyConcentratedDoesNotReCross() {
        // Before already 100% Equity → adding more equity stays concentrated but
        // does NOT newly "cross" (the flag is for entering, not staying).
        let holdings = [(symbol: "AAPL", value: 100.0)]
        let i = WI.addingHolding(symbol: "MSFT", addedValue: 50, to: holdings)
        #expect(!i.crossesConcentration)
        #expect(i.afterTopFraction == 1.0)
    }
}
