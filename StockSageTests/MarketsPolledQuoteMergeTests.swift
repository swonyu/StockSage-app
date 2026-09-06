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
// gets a priced quote whose feed omitted the timestamp (marketTime: nil) — the fail-closed
// straddle; GOOG gets no quote at all (must come through byte-identical); a 4th symbol TSLA is
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

        let result = StockSageStore.mergedPolledQuotes(symbols: symbols, ideas: ideas, symbolIndex: index, quotes: quotes)

        // Shape: same count, same order (symbol at each index unchanged), same identity (idea.id == symbol).
        #expect(result.symbols.count == symbols.count)
        #expect(result.ideas.count == ideas.count)
        #expect(result.symbols.map(\.symbol) == symbols.map(\.symbol))
        #expect(result.ideas.map(\.id) == ideas.map(\.id))

        // AAPL: priced quote WITH a market time -> price and asOf both move.
        #expect(result.symbols[0].latest?.price == 155.25)
        #expect(result.ideas[0].price == 155.25)
        #expect(result.ideas[0].priceAsOf == freshStamp)

        // MSFT: priced quote whose feed omitted marketTime -> price moves, asOf is overwritten
        // to nil (fail-closed) even though the fixture started with a real, non-nil priceAsOf —
        // proving this is an active nil-out, not merely "left alone because already nil".
        #expect(result.symbols[1].latest?.price == 305)
        #expect(result.ideas[1].price == 305)
        #expect(result.ideas[1].priceAsOf == nil)

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
}
