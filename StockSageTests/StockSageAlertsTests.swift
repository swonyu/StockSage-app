import Testing
import Foundation
@testable import StockSage

// MARK: - Signal alerts (pure crossing detector)

struct StockSageAlertsTests {

    private func idea(_ symbol: String, _ price: Double, _ action: TradeAdvice.Action,
                      stop: Double? = nil, target: Double? = nil) -> StockSageIdea {
        StockSageIdea(
            symbol: symbol, market: symbol, price: price,
            advice: TradeAdvice(action: action, conviction: 0.5, regime: .range, rationale: [],
                                stopPrice: stop, targetPrice: target, suggestedWeight: 0.05, caveat: "x"),
            spark: [])
    }

    @Test func bullishFlipFiresOnceOnEntry() {
        let prev = [idea("AAPL", 100, .hold)]
        let cur  = [idea("AAPL", 101, .strongBuy)]
        let a = StockSageAlerts.detect(previous: prev, current: cur)
        #expect(a.count == 1)
        #expect(a.first?.kind == .flipBullish)
        // Staying strongBuy → no repeat.
        #expect(StockSageAlerts.detect(previous: cur, current: [idea("AAPL", 102, .strongBuy)]).isEmpty)
    }

    @Test func bearishFlipFires() {
        let a = StockSageAlerts.detect(previous: [idea("X", 50, .buy)], current: [idea("X", 49, .sell)])
        #expect(a.first?.kind == .flipBearish)
        #expect(a.first?.isWarning == true)
        // buy → strongBuy is within the bullish set → NOT a flip.
        #expect(StockSageAlerts.detect(previous: [idea("X", 50, .buy)], current: [idea("X", 51, .strongBuy)]).isEmpty)
    }

    @Test func shortStopBreachFiresOnCrossUp() {
        // A SHORT stops ABOVE entry — a stop-out is price crossing UP through the stop (a real loss).
        let a = StockSageAlerts.detect(previous: [idea("X", 107, .sell, stop: 108, target: 84)],
                                       current:  [idea("X", 109, .sell, stop: 108, target: 84)])
        #expect(a.contains { $0.kind == .stopBreach })
        // A WINNING short (price falling toward the 84 target) must NOT fire a stop breach.
        #expect(!StockSageAlerts.detect(previous: [idea("X", 109, .sell, stop: 108, target: 84)],
                                        current:  [idea("X", 107, .sell, stop: 108, target: 84)])
            .contains { $0.kind == .stopBreach })
    }

    @Test func shortTargetHitFiresOnCrossDown() {
        // A SHORT targets BELOW entry — target hit is price crossing DOWN through the target.
        let a = StockSageAlerts.detect(previous: [idea("X", 86, .sell, stop: 108, target: 84)],
                                       current:  [idea("X", 83, .sell, stop: 108, target: 84)])
        #expect(a.contains { $0.kind == .targetHit })
        // Still above the target → no target hit yet.
        #expect(!StockSageAlerts.detect(previous: [idea("X", 90, .sell, stop: 108, target: 84)],
                                        current:  [idea("X", 86, .sell, stop: 108, target: 84)])
            .contains { $0.kind == .targetHit })
    }

    @Test func stopBreachFiresOnlyOnCrossDown() {
        let prev = [idea("X", 105, .buy, stop: 100)]
        let cur  = [idea("X", 99, .buy, stop: 100)]
        let a = StockSageAlerts.detect(previous: prev, current: cur)
        #expect(a.contains { $0.kind == .stopBreach })
        // Already below → no re-fire.
        #expect(!StockSageAlerts.detect(previous: cur, current: [idea("X", 98, .buy, stop: 100)])
            .contains { $0.kind == .stopBreach })
    }

    @Test func targetHitFiresOnCrossUp() {
        let a = StockSageAlerts.detect(previous: [idea("X", 110, .buy, target: 120)],
                                       current:  [idea("X", 121, .buy, target: 120)])
        #expect(a.contains { $0.kind == .targetHit })
    }

    @Test func newSymbolDoesNotAlert() {
        // No previous entry → can't detect a crossing.
        #expect(StockSageAlerts.detect(previous: [], current: [idea("NEW", 10, .strongBuy, stop: 5)]).isEmpty)
    }
}
