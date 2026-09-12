import Foundation
import Testing
@testable import StockSage

/// In-memory fixtures only: no Store singleton, credentials, disk or provider requests.
@MainActor struct StockSagePriceSourceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ symbol: String = "AAPL", source: StockSagePriceSource?, at: Date) -> StockSageSymbol {
        StockSageSymbol(symbol: symbol, market: "TEST", quotes: [
            .init(price: 100, previousPrice: 99, time: at, marketTime: at, priceSource: source)
        ])
    }

    private func idea(source: StockSagePriceSource?, at: Date) -> StockSageIdea {
        .init(symbol: "AAPL", market: "TEST", price: 100,
              advice: .init(action: .buy, conviction: 0.6, regime: .bullTrend, rationale: [],
                            stopPrice: 90, targetPrice: 130, suggestedWeight: 0.05, caveat: "fixture"),
              spark: [99, 100], generatedAt: at, priceAsOf: at, priceSource: source)
    }

    @Test func providerParsersAttachOriginNotFreshness() throws {
        let massive = try #require(StockSageMassive.parseSnapshot(StockSageMassiveTests.docsSample,
                                                                 requestedSymbols: ["BCAT"])["BCAT"])
        #expect(massive.priceSource == .massiveSIP)
        let yahoo = try #require(StockSageQuoteService.parseChart(Data(#"{"chart":{"result":[{"meta":{"symbol":"AAPL","regularMarketPrice":100,"previousClose":99,"regularMarketTime":1700000000}}]}}"#.utf8)))
        #expect(yahoo.priceSource == .yahoo)
        #expect(yahoo.marketTime == Date(timeIntervalSince1970: 1_700_000_000))
        let bars = try #require(StockSageMassive.parseHistory(Data(#"{"status":"OK","results":[{"t":1700000000000,"o":100,"h":102,"l":99,"c":101,"v":10},{"t":1700086400000,"o":101,"h":103,"l":100,"c":102,"v":20}]}"#.utf8), symbol: "AAPL"))
        #expect(bars.priceSource == .massiveDaily)
        #expect(bars.closes == [101, 102])
        let yahooBars = try #require(StockSageQuoteService.parseHistory(Data(#"{"chart":{"result":[{"timestamp":[1700000000,1700086400],"indicators":{"quote":[{"open":[100,101],"high":[102,103],"low":[99,100],"close":[101,102],"volume":[10,20]}]}}]}}"#.utf8), symbol: "AAPL"))
        #expect(yahooBars.priceSource == .yahooBars)
        #expect(yahooBars.closes == bars.closes)
    }

    @Test func legacyEODHDSourceStillDecodesAndLabels() throws {
        let source = try JSONDecoder().decode(StockSagePriceSource.self, from: Data(#""eodhd""#.utf8))
        #expect(source == .eodhd)
        #expect(source.label == "EODHD")
    }

    @Test func acceptedPriceAndOriginMoveTogetherRejectedPriceCannotRelabel() {
        let at = now.addingTimeInterval(-10)
        let symbols = [row(source: .massiveSIP, at: at)]
        let ideas = [idea(source: .massiveSIP, at: at)]
        for incomingAt in [at.addingTimeInterval(-1), at] {
            let rejected = StockSageStore.mergedPolledQuotes(symbols: symbols, ideas: ideas, symbolIndex: ["AAPL": 0],
                quotes: ["AAPL": .init(symbol: "AAPL", price: 101, previousClose: 99, marketTime: incomingAt, priceSource: .yahoo)], now: now)
            #expect(rejected.symbols == symbols)
            #expect(rejected.ideas == ideas)
            #expect(rejected.acceptedKeys.isEmpty)
        }
        for source: StockSagePriceSource? in [.yahoo, nil] {
            let accepted = StockSageStore.mergedPolledQuotes(symbols: symbols, ideas: ideas, symbolIndex: ["AAPL": 0],
                quotes: ["AAPL": .init(symbol: "AAPL", price: 101, previousClose: 99, marketTime: now, priceSource: source)], now: now)
            #expect(accepted.symbols[0].latest?.price == 101)
            #expect(accepted.symbols[0].latest?.priceSource == source)
            #expect(accepted.ideas[0].priceSource == source)
            #expect(accepted.ideas[0].priceAsOf == now)
            #expect(accepted.ideas[0].advice == ideas[0].advice)
            #expect(accepted.ideas[0].generatedAt == ideas[0].generatedAt)
        }
    }

    @Test func scanKeepsOriginOfWinningPriceNotOriginOfNewAnalysis() {
        let fresh = idea(source: .massiveDaily, at: now.addingTimeInterval(-86_400))
        let board = row(source: .yahoo, at: now.addingTimeInterval(-1))
        let merged = StockSageStore.ideasWithLatestPrices([fresh], symbols: [board], previous: [], now: now)[0]
        #expect(merged.priceSource == .yahoo)
        #expect(merged.priceAsOf == board.latest?.marketTime)
        #expect(merged.generatedAt == fresh.generatedAt)
        let offBoard = fresh.withLivePrice(103, asOf: now, massiveTradeSequence: 7, priceSource: .massiveSIP)
        let latest = StockSageStore.ideasWithLatestPrices([fresh], symbols: [board], previous: [offBoard], now: now)[0]
        #expect(latest.price == 103)
        #expect(latest.priceSource == .massiveSIP)
        #expect(latest.massiveTradeSequence == 7)
    }

    @Test func quoteCacheRetainsOriginAndOldCacheDecodesUnknown() throws {
        let cache = StockSageQuoteCache.from(symbols: [row(source: .massiveSIP, at: now)], savedAt: now)
        let data = try JSONEncoder().encode(cache)
        let restored = try JSONDecoder().decode(StockSageQuoteCache.self, from: data)
        #expect(restored == cache)
        #expect(restored.symbols(marketFor: { _ in "TEST" })[0].latest?.priceSource == .massiveSIP)
        let old = try JSONDecoder().decode(StockSageQuoteCache.self, from: removingSource(data))
        #expect(old.symbols(marketFor: { _ in "TEST" })[0].latest?.priceSource == nil)
        #expect(old.entries[0].price == 100)
        #expect(old.entries[0].marketTime == now)
    }

    @Test func historyCacheAndIdeaBuildRetainOriginIncludingOldUnknown() async throws {
        let closes = (0..<30).map { 100 + Double($0) }
        let dates = (0..<30).map { now.addingTimeInterval(Double($0 - 29) * 86_400) }
        let history = StockSagePriceHistory(symbol: "AAPL", dates: dates, opens: closes, highs: closes,
            lows: closes, closes: closes, volumes: Array(repeating: 100, count: 30), priceSource: .massiveDaily)
        let cache = StockSageHistoryCache.from(histories: ["AAPL": history], universe: ["AAPL"], savedAt: now, maxBars: 30)
        let data = try JSONEncoder().encode(cache)
        let restored = try #require(StockSageHistoryCache.decode(data))
        #expect(restored == cache)
        #expect(restored.priceHistories()["AAPL"] == history)
        let old = try #require(StockSageHistoryCache.decode(removingSource(data)))
        #expect(old.priceHistories()["AAPL"]?.priceSource == nil)
        #expect(old.priceHistories()["AAPL"]?.closes == closes)
        for input in [restored, old] {
            let built = await StockSageStore.buildIdeas(defs: [.init(symbol: "AAPL", market: "TEST")], histories: input.priceHistories())
            let first = try #require(built.first)
            #expect(first.price == 129)
            #expect(first.priceSource == input.entries[0].priceSource)
            #expect(first.priceAsOf == now)
        }
    }

    private func removingSource(_ data: Data) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(object["entries"] as? [[String: Any]])
        object["entries"] = entries.map { entry in entry.filter { $0.key != "priceSource" } }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func labelsDistinguishCachedUnknownAndInvalidTime() {
        func label(_ source: StockSagePriceSource?, _ at: Date?, cached: Bool = false) -> String? {
            MarketsView.sourceTagLabel(isSampleData: false, loadedFromCache: cached, priceAsOf: at, now: now, priceSource: source)
        }
        #expect(label(.massiveSIP, now) == "Massive SIP · just now")
        #expect(label(.massiveDaily, now.addingTimeInterval(-86_400)) == "Massive daily bars · 1d")
        #expect(label(.yahoo, now, cached: true) == "cached · Yahoo · just now")
        #expect(label(nil, now, cached: true) == "cached · source unknown · just now")
        #expect(label(.sample, nil) == "sample")
        #expect(label(.yahoo, nil) == "Yahoo · time unknown")
        #expect(label(.massiveSIP, Date(timeIntervalSince1970: .nan)) == "Massive SIP · time unverified")
    }

    @Test func bannerDatesOneObservationNotTheWholeUniverse() {
        let equity = row(source: .massiveSIP, at: now.addingTimeInterval(-100))
        let crypto = row("BTC-USD", source: .yahoo, at: now)
        let at = StockSageStore.closeableQuoteAsOf([equity, crypto])
        #expect(StockSageStore.quoteSourceLabel([equity, crypto], asOf: at) == "Massive SIP")
        #expect(StockSageStore.quoteSourceLabel([equity, row("MSFT", source: .yahoo, at: equity.latest!.marketTime!)], asOf: at) == "mixed sources")
        #expect(StockSageStore.quoteSourceLabel([row(source: nil, at: now)], asOf: now) == "source unknown")
        let text = MarketsView.quoteBannerText(asOf: at, source: "Massive SIP", now: now)
        #expect(text.contains("Massive SIP"))
        #expect(text.contains("Other symbols may be older or unavailable"))
        #expect(!text.contains("Live Tadawul"))
        #expect(MarketsView.quoteBannerText(asOf: now.addingTimeInterval(-7200), source: "Yahoo", now: now).contains("Last observed quote (not live)"))
        #expect(MarketsView.quoteBannerText(asOf: nil, source: "Yahoo", now: now).contains("Price age unknown"))
        #expect(MarketsView.quoteBannerText(asOf: now.addingTimeInterval(1), source: "Yahoo", now: now).contains("timestamp unverified"))
    }
}
