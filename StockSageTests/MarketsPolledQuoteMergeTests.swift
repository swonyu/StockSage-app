import Testing
import Foundation
@testable import StockSage

// MARK: - StockSageStore.mergedPolledQuotes — W3 (owner: "live prices … seamless … update
// automatically every 30 seconds")
//
// Pins the pure merge behind `applyPolledQuotes`, the in-place update the `.streamGap` 30s timer
// now applies instead of `mergeLiveQuotes`/`replaceAll`. No `@MainActor` singleton, no live
// stream, no network — `symbols`/`ideas`/`symbolIndex` are hand-built fixtures, so this is
// parallel-test safe (mirrors the "never touches StockSageStore.shared" discipline documented in
// StockSageQAFixtureIdeasTests).
//
// Fixture: a 3-row board (AAPL, MSFT, GOOG) with matching ideas, indices 0/1/2 — the SAME order
// `rebuildSymbolIndex()` would produce. AAPL gets a priced quote WITH a market timestamp; MSFT
// gets an undated quote (marketTime: nil) which cannot erase its dated observation — the
// fail-closed straddle; GOOG gets no quote at all (must come through byte-identical); TSLA is
// on the board but its quote is price == 0 (the exact `price > 0` boundary) and must be skipped
// exactly like GOOG.
struct MarketsPolledQuoteMergeTests {
    private static let oldPrice: [String: Double] = ["AAPL": 150, "MSFT": 300, "GOOG": 140, "TSLA": 250]
    // Hand-picked, unambiguous instant distinct from any "now"-derived value a bug could smuggle in.
    private static let oldAsOf = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z

    private func advice() -> TradeAdvice {
        TradeAdvice(action: .buy, conviction: 0.6, regime: .bullTrend, rationale: [],
                    stopPrice: 90, targetPrice: 130, suggestedWeight: 0.05, caveat: "x")
    }

    private func fixtureSymbols() -> [StockSageSymbol] {
        ["AAPL", "MSFT", "GOOG", "TSLA"].map { sym in
            StockSageSymbol(symbol: sym, market: "NASDAQ", quotes: [
                StockSageQuote(price: Self.oldPrice[sym]!, previousPrice: Self.oldPrice[sym]!,
                               time: Date(timeIntervalSinceNow: -86_400)),
                StockSageQuote(price: Self.oldPrice[sym]!, previousPrice: Self.oldPrice[sym]!,
                               marketTime: Self.oldAsOf),
            ])
        }
    }

    private func fixtureIdeas() -> [StockSageIdea] {
        ["AAPL", "MSFT", "GOOG", "TSLA"].map { sym in
            StockSageIdea(symbol: sym, market: "NASDAQ", price: Self.oldPrice[sym]!, advice: advice(),
                          spark: [Self.oldPrice[sym]!], priceAsOf: Self.oldAsOf)
        }
    }

    private func fixtureIndex(_ symbols: [StockSageSymbol]) -> [String: Int] {
        Dictionary(symbols.enumerated().map { ($0.element.symbol.uppercased(), $0.offset) },
                  uniquingKeysWith: { a, _ in a })
    }

    private func quote(price: Double, previousClose: Double, marketTime: Date?) -> StockSageQuoteService.LiveQuote {
        .init(symbol: "x", price: price, previousClose: previousClose, marketTime: marketTime)
    }

    @Test func pollMergeUpdatesOnlyThePolledRowsAndLeavesArrayShapeUntouched() {
        let symbols = fixtureSymbols()
        let ideas = fixtureIdeas()
        let index = fixtureIndex(symbols)
        let freshStamp = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T06:40:00Z — distinct from oldAsOf

        let quotes: [String: StockSageQuoteService.LiveQuote] = [
            "AAPL": quote(price: 155.25, previousClose: 150, marketTime: freshStamp),
            "MSFT": quote(price: 305, previousClose: 300, marketTime: nil),   // feed omitted the timestamp
            "TSLA": quote(price: 0, previousClose: 250, marketTime: freshStamp),   // price == 0: excluded
            // GOOG: no quote at all.
        ]

        let result = StockSageStore.mergedPolledQuotes(symbols: symbols, ideas: ideas, symbolIndex: index,
                                                       quotes: quotes, now: freshStamp)

        // Shape: same count, same order (symbol at each index unchanged), same identity (idea.id == symbol).
        #expect(result.symbols.count == symbols.count)
        #expect(result.ideas.count == ideas.count)
        #expect(result.symbols.map(\.symbol) == symbols.map(\.symbol))
        #expect(result.symbols.map(\.id) == symbols.map(\.id))
        #expect(result.ideas.map(\.id) == ideas.map(\.id))

        // AAPL: priced quote WITH a market time -> price and asOf both move.
        #expect(result.symbols[0].latest?.price == 155.25)
        #expect(result.ideas[0].price == 155.25)
        #expect(result.ideas[0].priceAsOf == freshStamp)

        // M2 ordering contract: missing time does NOT prove a newer price. Preserve the dated
        // observation; its original timestamp still ages normally through the freshness gate.
        #expect(result.symbols[1] == symbols[1])
        #expect(result.ideas[1] == ideas[1])

        // GOOG: no quote in the batch -> byte-identical row and idea.
        #expect(result.symbols[2] == symbols[2])
        #expect(result.ideas[2] == ideas[2])

        // TSLA: quote present but price == 0 (the exact `price > 0` boundary) -> excluded,
        // byte-identical to GOOG's untouched case.
        #expect(result.symbols[3] == symbols[3])
        #expect(result.ideas[3] == ideas[3])

        // The reported newest market time reflects only the quote that actually carried one
        // (AAPL's) — MSFT's nil and TSLA's skip must not contribute.
        #expect(result.newestMarketTime == freshStamp)
        #expect(result.acceptedKeys == ["AAPL"])
    }

    @Test func emptyQuoteBatchLeavesEverythingByteIdenticalAndReportsNoNewestTime() {
        let symbols = fixtureSymbols()
        let ideas = fixtureIdeas()
        let index = fixtureIndex(symbols)

        let result = StockSageStore.mergedPolledQuotes(symbols: symbols, ideas: ideas, symbolIndex: index, quotes: [:])

        #expect(result.symbols == symbols)
        #expect(result.ideas == ideas)
        #expect(result.newestMarketTime == nil)
    }

    @Test func staleRESTResponseCannotRewindStreamedRowOrIdea() {
        let symbols = fixtureSymbols(), ideas = fixtureIdeas()
        for stamp: Date? in [nil, Self.oldAsOf, Self.oldAsOf.addingTimeInterval(-1)] {
            let result = StockSageStore.mergedPolledQuotes(
                symbols: symbols, ideas: ideas, symbolIndex: fixtureIndex(symbols),
                quotes: ["AAPL": quote(price: 90, previousClose: 100, marketTime: stamp)], now: Self.oldAsOf)
            #expect(result.symbols == symbols)
            #expect(result.ideas == ideas)
            #expect(result.acceptedKeys.isEmpty)
            #expect(result.newestMarketTime == nil)
        }
    }

    @Test func undatedQuoteSeedsUnknownRowWithoutInventingFreshness() {
        let symbol = StockSageSymbol(symbol: "AAPL", market: "NASDAQ")
        let idea = StockSageIdea(symbol: "AAPL", market: "NASDAQ", price: 150, advice: advice(), spark: [150])
        let result = StockSageStore.mergedPolledQuotes(
            symbols: [symbol], ideas: [idea], symbolIndex: ["AAPL": 0],
            quotes: ["AAPL": quote(price: 155, previousClose: 150, marketTime: nil)], now: Self.oldAsOf)
        #expect(result.symbols[0].latest?.price == 155)
        #expect(result.symbols[0].latest?.marketTime == nil)
        #expect(result.ideas[0].price == 155)
        #expect(result.ideas[0].priceAsOf == nil)
        #expect(StockSageQuoteFreshness.isStale(symbol: "AAPL", marketTime: result.ideas[0].priceAsOf, asOf: Self.oldAsOf))
    }

    @Test func offBoardIdeaReceivesQuoteWithoutInventingBoardRow() {
        let ideas = fixtureIdeas()
        let at = Self.oldAsOf.addingTimeInterval(1)
        let result = StockSageStore.mergedPolledQuotes(
            symbols: [], ideas: ideas, symbolIndex: [:],
            quotes: ["AAPL": quote(price: 155, previousClose: 150, marketTime: at)], now: at)
        #expect(result.symbols.isEmpty)
        #expect(result.ideas[0].price == 155)
        #expect(result.ideas[0].priceAsOf == at)
        #expect(result.ideas[1] == ideas[1])
        #expect(result.acceptedKeys == ["AAPL"])
    }

    @Test func scanKeepsNewAdviceButDoesNotRewindLatestPrice() {
        let fresh = fixtureIdeas()
        let at = Self.oldAsOf.addingTimeInterval(10)
        let live = StockSageSymbol(symbol: "AAPL", market: "NASDAQ", quotes: [
            StockSageQuote(price: 155, previousPrice: 150, marketTime: at),
        ])
        let offBoard = fresh[1].withLivePrice(310, asOf: at)
        let result = StockSageStore.ideasWithLatestPrices(fresh, symbols: [live], previous: [offBoard], now: at)
        #expect(result[0].price == 155)
        #expect(result[1].price == 310)
        #expect(result[0].priceAsOf == at)
        #expect(result[0].advice == fresh[0].advice)
        #expect(result[0].generatedAt == fresh[0].generatedAt)
        #expect(result[2] == fresh[2])
    }

    @Test func invalidValuesAndBogusIndexAreRejectedAndFutureCacheCanRecover() {
        let symbols = fixtureSymbols(), ideas = fixtureIdeas()
        let at = Self.oldAsOf.addingTimeInterval(1)
        for q in [quote(price: .infinity, previousClose: 150, marketTime: at),
                  quote(price: 155, previousClose: .nan, marketTime: at),
                  quote(price: 155, previousClose: 150, marketTime: at.addingTimeInterval(61))] {
            let result = StockSageStore.mergedPolledQuotes(symbols: symbols, ideas: ideas, symbolIndex: fixtureIndex(symbols),
                                                           quotes: ["AAPL": q], now: at)
            #expect(result.symbols == symbols)
            #expect(result.ideas == ideas)
            #expect(result.acceptedKeys.isEmpty)
        }
        let result = StockSageStore.mergedPolledQuotes(symbols: symbols, ideas: [], symbolIndex: ["AAPL": 999],
                                                       quotes: ["AAPL": quote(price: 155, previousClose: 150, marketTime: at)], now: at)
        #expect(result.symbols == symbols)
        #expect(result.acceptedKeys.isEmpty)
        #expect(StockSageStore.acceptsQuote(at, after: at.addingTimeInterval(100_000), now: at))
    }
}
