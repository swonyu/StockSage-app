import Testing
import Foundation
@testable import StockSage

// MARK: - User-set price alerts (pure)

struct StockSagePriceAlertTests {
    @Test func isMetAboveAndBelow() {
        let above = PriceAlert(symbol: "AAPL", target: 150, direction: .above)
        #expect(above.isMet(by: 150))
        #expect(above.isMet(by: 151))
        #expect(!above.isMet(by: 149))
        let below = PriceAlert(symbol: "AAPL", target: 100, direction: .below)
        #expect(below.isMet(by: 100))
        #expect(below.isMet(by: 99))
        #expect(!below.isMet(by: 101))
    }

    @Test func newlyTriggeredFiltersArmedMetWithPrice() {
        let a = PriceAlert(symbol: "AAPL", target: 150, direction: .above)                       // armed, met @151
        let b = PriceAlert(symbol: "NVDA", target: 200, direction: .above)                       // armed, not met @150
        let c = PriceAlert(symbol: "MSFT", target: 300, direction: .above, triggeredAt: Date())  // already triggered
        let d = PriceAlert(symbol: "TSLA", target: 100, direction: .below)                       // no price supplied
        let fired = StockSagePriceAlertEngine.newlyTriggered(
            [a, b, c, d], prices: ["AAPL": 151, "NVDA": 150, "MSFT": 350])
        #expect(fired.map(\.symbol) == ["AAPL"])
    }

    @Test func validateTargetParsesAndRejects() {
        #expect(StockSagePriceAlertEngine.validateTarget("").price == nil)
        #expect(StockSagePriceAlertEngine.validateTarget("abc").price == nil)
        #expect(StockSagePriceAlertEngine.validateTarget("0").price == nil)
        #expect(StockSagePriceAlertEngine.validateTarget("-5").price == nil)
        #expect(StockSagePriceAlertEngine.validateTarget("150").price == 150)
        #expect(StockSagePriceAlertEngine.validateTarget("1,500.5").price == 1500.5)
    }

    @Test func codableRoundTripAndUppercasing() throws {
        let a = PriceAlert(symbol: "aapl", target: 150, direction: .below)   // init uppercases
        let data = try JSONEncoder().encode([a])
        let back = try JSONDecoder().decode([PriceAlert].self, from: data)
        #expect(back.first?.symbol == "AAPL")
        #expect(back.first?.direction == .below)
        #expect(back.first?.isArmed == true)
    }
}
