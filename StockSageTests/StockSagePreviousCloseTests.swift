import Foundation
import Testing
@testable import StockSage

@MainActor struct StockSagePreviousCloseTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func staleRestPriceRepairsBaselineWithoutRewindingTradeOrReceiptClocks() throws {
        let now = date("2026-09-10T15:00:00Z")
        let old = date("2026-09-09T15:00:00Z")
        let row = StockSageQuote(price: 111, previousPrice: 100, time: now, marketTime: now,
            massiveTradeSequence: 55, priceSource: .massiveSIP,
            previousCloseSource: .yahoo, previousCloseQuoteTime: old)
        let symbol = StockSageSymbol(symbol: "AAPL", market: "US", quotes: [row])
        #expect(symbol.sessionChangePercent == nil)
        let repair = StockSageQuoteService.LiveQuote(symbol: "AAPL", price: 110.5, previousClose: 110,
            marketTime: now.addingTimeInterval(-60), priceSource: .massiveSIP,
            previousCloseSource: .massiveSIP, previousCloseQuoteTime: now.addingTimeInterval(-60))
        let merged = StockSageStore.mergedPolledQuotes(symbols: [symbol], ideas: [], symbolIndex: ["AAPL": 0],
            quotes: ["AAPL": repair], now: now)
        let result = try #require(merged.symbols.first?.latest)
        #expect(result.previousPrice == 110)
        #expect(result.price == row.price && result.marketTime == row.marketTime && result.time == row.time)
        #expect(result.massiveTradeSequence == 55 && merged.acceptedKeys.isEmpty && merged.newestMarketTime == nil)
        #expect(abs((merged.symbols[0].sessionChangePercent ?? .nan) - (100.0 / 110.0)) < 1e-9)
    }

    @Test func baselineCarryUsesTradingDateNotWallClockOrTradingPhase() {
        let pre = date("2026-11-27T09:00:00Z") // early-close trading date
        let q = StockSageQuote(price: 101, previousPrice: 100, marketTime: pre, priceSource: .yahoo,
                              previousCloseSource: .yahoo, previousCloseQuoteTime: pre)
        #expect(q.hasSessionBaseline(symbol: "AAPL", at: date("2026-11-27T21:00:00Z")))
        #expect(!q.hasSessionBaseline(symbol: "AAPL", at: date("2026-11-30T09:00:00Z")))
        #expect(!q.hasSessionBaseline(symbol: "AAPL", at: date("2026-11-26T15:00:00Z")))
        let unknown = StockSageQuote(price: 101, previousPrice: 100, marketTime: pre, priceSource: .massiveSIP)
        #expect(!unknown.hasSessionBaseline(symbol: "AAPL", at: pre))
        #expect(StockSageSignalEngine.generateSignal(for: .init(symbol: "AAPL", market: "US", quotes: [unknown])) == nil)
    }

    @Test func equalTimeRepairPublishesThroughStoreWithoutStampingAPriceUpdate() throws {
        let suite = "baseline.store.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let time = date("2026-09-10T15:00:00Z")
        let row = StockSageQuote(price: 111, previousPrice: 111, time: time, marketTime: time,
                                massiveTradeSequence: 55, priceSource: .massiveSIP)
        store.replaceAll([.init(symbol: "AAPL", market: "US", quotes: [row])])
        let stamp = store.lastUpdated, asOf = store.quoteAsOf
        store.applyPolledQuotes(["AAPL": .init(symbol: "AAPL", price: 110.5, previousClose: 110,
            marketTime: time, priceSource: .yahoo, previousCloseSource: .yahoo, previousCloseQuoteTime: time)])
        #expect(store.symbols[0].latest?.previousPrice == 110)
        #expect(store.symbols[0].latest?.massiveTradeSequence == 55 && store.symbols[0].latest?.price == 111)
        #expect(store.quoteAsOf == asOf && store.lastUpdated == stamp)
        #expect(StockSageStore.streamGapCandidates(tracked: ["AAPL", "MSFT"], subscribed: ["AAPL", "MSFT"],
            needsBaseline: ["MSFT"], isTrading: { _ in true }) == ["MSFT"])
    }

    @Test func parserAndCachePreserveBaselineOriginAndLegacyCacheDoesNotInventIt() throws {
        let time = date("2026-09-10T15:00:00Z")
        let body = Data("{\"chart\":{\"result\":[{\"meta\":{\"symbol\":\"AAPL\",\"regularMarketPrice\":111,\"previousClose\":110,\"regularMarketTime\":\(time.timeIntervalSince1970)}}]}}".utf8)
        let parsed = try #require(StockSageQuoteService.parseChart(body))
        #expect(parsed.previousCloseQuoteTime == time && parsed.previousCloseSource == .yahoo)
        let q = StockSageQuote(price: 111, previousPrice: 110, marketTime: time, priceSource: .yahoo,
                              previousCloseSource: parsed.previousCloseSource, previousCloseQuoteTime: parsed.previousCloseQuoteTime)
        let cache = StockSageQuoteCache.from(symbols: [.init(symbol: "AAPL", market: "US", quotes: [q])], savedAt: time)
        let decoded = try JSONDecoder().decode(StockSageQuoteCache.self, from: JSONEncoder().encode(cache))
        #expect(decoded.symbols(marketFor: { _ in "US" })[0].sessionChangePercent != nil)
        let legacy = StockSageQuoteCache(entries: [.init(symbol: "AAPL", price: 111, previousClose: 100,
            time: time, marketTime: time, priceSource: .yahoo)], savedAt: time)
        #expect(legacy.symbols(marketFor: { _ in "US" })[0].sessionChangePercent == nil)
    }
}
