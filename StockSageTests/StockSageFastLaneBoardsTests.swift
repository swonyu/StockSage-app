import Testing
import Foundation
@testable import StockSage

// MARK: - FASTMONEY_BACKLOG #7: crypto/equity fast-lane board split + cross-correlation (pure)

struct StockSageFastLaneBoardsTests {

    typealias EV = StockSageExpectedValue

    private func idea(_ symbol: String, action: TradeAdvice.Action = .buy, conviction: Double,
                      stop: Double?, target: Double?) -> StockSageIdea {
        StockSageIdea(symbol: symbol, market: "M", price: 100,
                      advice: TradeAdvice(action: action, conviction: conviction, regime: .bullTrend, rationale: [],
                                          stopPrice: stop, targetPrice: target, suggestedWeight: 0.05, caveat: "x"),
                      spark: [])
    }

    @Test func fastLaneByClassPartitionsCryptoAndEquityWithoutReordering() {
        let btc = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
        let eth = idea("ETH-USD", conviction: 0.8, stop: 90, target: 130)
        let aapl = idea("AAPL", conviction: 0.85, stop: 90, target: 120)
        let msft = idea("MSFT", conviction: 0.7, stop: 90, target: 115)
        let all = [btc, eth, aapl, msft]
        let split = EV.fastLaneByClass(all)
        #expect(Set(split.crypto.map(\.symbol)) == ["BTC-USD", "ETH-USD"])
        #expect(Set(split.equity.map(\.symbol)) == ["AAPL", "MSFT"])
        // Every fastLane() member lands in exactly one bucket (Index/FX never enter fastLane()).
        let whole = EV.fastLane(all)
        #expect(split.crypto.count + split.equity.count == whole.count)
        // Each bucket preserves fastLane()'s OWN relative order (a pure filter, not a re-rank):
        // filtering the whole ranked list by class must equal each bucket's order.
        #expect(split.crypto.map(\.symbol) == whole.filter { $0.symbol.hasSuffix("-USD") }.map(\.symbol))
        #expect(split.equity.map(\.symbol) == whole.filter { !$0.symbol.hasSuffix("-USD") }.map(\.symbol))
    }

    @Test func fastLaneByClassEmptySideWhenOneClassAbsent() {
        let btc = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
        let eth = idea("ETH-USD", conviction: 0.8, stop: 90, target: 130)
        let split = EV.fastLaneByClass([btc, eth])
        #expect(split.equity.isEmpty)
        #expect(split.crypto.count == 2)
        #expect(EV.fastLaneByClass([]).crypto.isEmpty && EV.fastLaneByClass([]).equity.isEmpty)
    }

    @Test func cryptoRotationDominantFlagsWhen1_5xCleared() {
        // Strong, tight crypto setups vs a weak, wide equity setup — crypto's velocity sum should
        // clear 1.5x the equity sum (crypto compounds faster at similar EV, per the default holds).
        let btc = idea("BTC-USD", conviction: 0.95, stop: 95, target: 140)
        let eth = idea("ETH-USD", conviction: 0.9, stop: 95, target: 135)
        let aapl = idea("AAPL", conviction: 0.45, stop: 98, target: 104)
        let split = EV.fastLaneByClass([btc, eth, aapl])
        let cryptoSum = split.crypto.compactMap { EV.velocity(for: $0) }.reduce(0, +)
        let equitySum = split.equity.compactMap { EV.velocity(for: $0) }.reduce(0, +)
        #expect(cryptoSum > equitySum * 1.5)
        #expect(EV.cryptoRotationDominant(crypto: split.crypto, equity: split.equity))
    }

    @Test func cryptoRotationDominantFalseWhenNoCryptoVelocity() {
        let aapl = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        #expect(!EV.cryptoRotationDominant(crypto: [], equity: [aapl]))
    }

    @Test func cryptoRotationDominantFalseWhenBelowThreshold() {
        // Comparable velocity sums on both sides — crypto's sum does not clear 1.5x equity's.
        let btc = idea("BTC-USD", conviction: 0.5, stop: 95, target: 105)
        let aapl = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        let split = EV.fastLaneByClass([btc, aapl])
        #expect(!EV.cryptoRotationDominant(crypto: split.crypto, equity: split.equity))
    }

    @Test func laneCorrelationNilWhenEitherSideHasNoUsableHistory() {
        let btc = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
        let aapl = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        #expect(EV.laneCorrelation(crypto: [btc], equity: [aapl], histories: [:]) == nil)
        #expect(EV.laneCorrelation(crypto: [], equity: [aapl], histories: ["AAPL": [1, 2, 3]]) == nil)
    }

    @Test func laneCorrelationAveragesPearsonAcrossEveryCrossGroupPair() {
        let btc = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
        let aapl = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        // Perfectly-correlated series (identical) → Pearson correlation of 1.0.
        let series = [100.0, 101, 102, 103, 104, 105, 106]
        let histories = ["BTC-USD": series, "AAPL": series]
        let corr = EV.laneCorrelation(crypto: [btc], equity: [aapl], histories: histories)
        #expect(corr != nil)
        #expect(abs(corr! - 1.0) < 1e-6)
    }

    @Test func laneCorrelationSkipsTooShortHistoriesRatherThanCrashing() {
        let btc = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
        let aapl = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        // Single-point history → dailyReturns has 0 elements → excluded, not a crash.
        #expect(EV.laneCorrelation(crypto: [btc], equity: [aapl], histories: ["BTC-USD": [100], "AAPL": [100]]) == nil)
    }
}
