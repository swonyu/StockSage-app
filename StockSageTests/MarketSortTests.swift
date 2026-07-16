import Testing
import Foundation
@testable import StockSage

/// Pins `MarketSort.apply` — the watchlist ordering behind the Markets sort menu.
/// Pure over `[StockSageSymbol]`, so the comparator can't silently drift.
struct MarketSortTests {

    /// A symbol whose latest quote yields the given percent change (prev = 100).
    private func sym(_ s: String, _ changePct: Double) -> StockSageSymbol {
        StockSageSymbol(symbol: s, market: "M",
                        quotes: [StockSageQuote(price: 100 * (1 + changePct / 100), previousPrice: 100)])
    }
    private func tickers(_ xs: [StockSageSymbol]) -> [String] { xs.map(\.symbol) }

    @Test func feedPreservesOrder() {
        let xs = [sym("C", 1), sym("A", 2), sym("B", 3)]
        #expect(tickers(MarketSort.feed.apply(xs)) == ["C", "A", "B"])
    }

    @Test func symbolSortsAlphabetically() {
        let xs = [sym("ZZZ", 0), sym("aaa", 0), sym("MMM", 0)]
        #expect(tickers(MarketSort.symbol.apply(xs)) == ["aaa", "MMM", "ZZZ"])   // case-insensitive
    }

    @Test func changeSortsTopGainersFirst() {
        let xs = [sym("DOWN", -2), sym("UP", 7), sym("MID", 3)]
        #expect(tickers(MarketSort.change.apply(xs)) == ["UP", "MID", "DOWN"])
    }

    @Test func signalSortsStrongestRecommendationFirst() {
        let xs = [sym("HOLD", 1), sym("STRONG", 8), sym("BUY", 4)]   // hold / strongBuy / buy
        #expect(tickers(MarketSort.signal.apply(xs)) == ["STRONG", "BUY", "HOLD"])
    }

    @Test func signalTieBreaksByMoveMagnitude() {
        let xs = [sym("SMALLER", 7), sym("BIGGER", 9)]              // both strongBuy
        #expect(tickers(MarketSort.signal.apply(xs)) == ["BIGGER", "SMALLER"])
    }

    @Test func rankOrdersStrongAboveBuyAboveHold() {
        #expect(MarketSort.rank(.strongBuy) > MarketSort.rank(.buy))
        #expect(MarketSort.rank(.buy) > MarketSort.rank(.hold))
        #expect(MarketSort.rank(.strongSell) == MarketSort.rank(.strongBuy))
    }

    @Test func emptyAndSingleAreStable() {
        #expect(MarketSort.signal.apply([]).isEmpty)
        #expect(tickers(MarketSort.change.apply([sym("ONLY", 5)])) == ["ONLY"])
    }

    @Test func allCasesHaveTitles() {
        for c in MarketSort.allCases { #expect(!c.title.isEmpty) }
    }
}
