import Testing
import Foundation
@testable import StockSage

// MARK: - trackedSymbols union (coverage: watchlist ∪ board ∪ portfolio ∪ journal-open)
//
// Pure function, no store/network access — inputs below are hand-typed arrays, not derived
// from any live store. Order contract per the function's own doc: board order first, then
// watchlist/portfolio/journalOpen in first-seen order; dedup is case-folded (uppercase).

struct StockSageTrackedSymbolsTests {
    @Test(arguments: [false, true]) @MainActor
    func newlyHeldSymbolReceivesItsFirstPrice(streamed: Bool) throws {
        let name = "stocksage-held-price-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var held = ["vra"]
        let store = StockSageStore(defaults: defaults, heldSymbols: { held })
        let at = Date().addingTimeInterval(-5)
        #expect(store.latestPrice("VRA") == nil)
        #expect(store.trackedSymbolsUnion == ["VRA"])

        // Invalid responses and a response for a holding removed during the fetch
        // must not invent a price row.
        for quote in [
            StockSageQuoteService.LiveQuote(symbol: "VRA", price: 0, previousClose: 4, marketTime: at),
            .init(symbol: "OTHER", price: 4.13, previousClose: 4, marketTime: at),
            .init(symbol: "VRA", price: 4.13, previousClose: 4, marketTime: at.addingTimeInterval(3_600))
        ] { store.applyPolledQuotes(["VRA": quote]) }
        let valid = StockSageQuoteService.LiveQuote(symbol: "VRA", price: 4.13,
            previousClose: 4.09, marketTime: at, priceSource: .massiveSIP)
        held = []
        store.applyPolledQuotes(["VRA": valid])
        #expect(store.symbols.isEmpty && store.symbolIndex.isEmpty)
        held = ["vra"]

        if streamed {
            store.applyLiveTicks(["VRA": .init(symbol: "VRA", price: 4.13, timestamp: at)])
        } else {
            store.applyPolledQuotes(["VRA": valid])
        }
        let quote = try #require(store.latestQuote("VRA"))
        #expect(quote.price == 4.13 && quote.marketTime == at && quote.priceSource == .massiveSIP)
        #expect(store.symbolIndex["VRA"] == 0 && store.symbols.count == 1)
        let id = store.symbols[0].id
        store.applyPolledQuotes(["VRA": .init(symbol: "VRA", price: 9, previousClose: 4,
            marketTime: at.addingTimeInterval(-1), priceSource: .massiveSIP)])
        #expect(store.latestPrice("VRA") == 4.13 && store.symbols[0].id == id)
        store.applyPolledQuotes(["VRA": .init(symbol: "VRA", price: 4.15, previousClose: 4,
            marketTime: at.addingTimeInterval(1), priceSource: .massiveSIP)])
        #expect(store.latestPrice("VRA") == 4.15 && store.symbols.count == 1)
    }

    @Test @MainActor func mixedBatchKeepsExistingIndexesAndOnlyAddsAcceptedTrackedRows() throws {
        let name = "stocksage-held-price-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["ORCL"], forKey: "stocksage_user_symbols")
        let store = StockSageStore(defaults: defaults, heldSymbols: { ["BAD", "vra", "VRA"] })
        let at = Date().addingTimeInterval(-5)
        store.applyPolledQuotes(["ORCL": .init(symbol: "ORCL", price: 100, previousClose: 99,
            marketTime: at, priceSource: .massiveSIP)])
        let original = try #require(store.symbols.first)
        store.applyPolledQuotes([
            "vra": .init(symbol: "VRA", price: 4.13, previousClose: 4.09, marketTime: at, priceSource: .massiveSIP),
            "BAD": .init(symbol: "BAD", price: 5, previousClose: 4, marketTime: at.addingTimeInterval(3_600)),
            "OTHER": .init(symbol: "OTHER", price: 7, previousClose: 6, marketTime: at)
        ])
        #expect(store.symbols.map(\.symbol) == ["ORCL", "VRA"])
        #expect(store.symbols.first == original)
        #expect(store.symbolIndex == ["ORCL": 0, "VRA": 1])
        #expect(store.latestPrice("vra") == 4.13 && store.latestPrice("ORCL") == 100)
    }

    @Test func dedupsAcrossAllFourSets() {
        let result = StockSageStore.trackedSymbols(
            board: ["AAPL", "MSFT"],
            watchlist: ["MSFT", "TSLA"],
            portfolio: ["TSLA", "NVDA"],
            journalOpen: ["NVDA", "AAPL"]
        )
        // Each symbol appears once despite showing up in 2 of the 4 sets.
        #expect(result == ["AAPL", "MSFT", "TSLA", "NVDA"])
    }

    @Test func caseFoldsSoLowerAndUpperAreOneSymbol() {
        let result = StockSageStore.trackedSymbols(
            board: ["aapl"],
            watchlist: ["AAPL"],
            portfolio: [],
            journalOpen: []
        )
        #expect(result == ["AAPL"])
    }

    @Test func journalOpenSymbolAbsentFromBoardIsIncluded() {
        // GME never made the board or the watchlist or the portfolio — only an open journal
        // trade references it. It must still surface in the union (honesty floor: an open
        // position is tracked regardless of whether the board ranked it).
        let result = StockSageStore.trackedSymbols(
            board: ["AAPL"],
            watchlist: [],
            portfolio: [],
            journalOpen: ["GME"]
        )
        #expect(result == ["AAPL", "GME"])
    }

    @Test func orderIsBoardFirstThenFirstSeenAcrossTheRest() {
        let result = StockSageStore.trackedSymbols(
            board: ["C", "B"],
            watchlist: ["A", "B"],
            portfolio: ["D", "A"],
            journalOpen: ["E", "D"]
        )
        // Board order preserved verbatim (C before B, even though B < C alphabetically);
        // then A (first seen in watchlist), then D (first seen in portfolio), then E.
        #expect(result == ["C", "B", "A", "D", "E"])
    }

    @Test func emptyInputsYieldEmptyOutput() {
        let result = StockSageStore.trackedSymbols(board: [], watchlist: [], portfolio: [], journalOpen: [])
        #expect(result.isEmpty)
    }
}

// MARK: - composeTrackedDefs (B1: trackedDefs(scope:) gains off-board holdings)
//
// `trackedDefs(scope:)` itself is `private` and `@MainActor`-bound (reads `userSymbols` plus the
// live `StockSagePortfolio.shared`/`StockSageJournalStore.shared` singletons) — no test seam on
// the instance method itself, same as `coreIsTheGroupsDerivedCuratedSubsetOfWorldwide` in
// StockSageTests.swift documents for the pre-existing watchlist half of this composition. B1
// pulls the actual rule out into `composeTrackedDefs`, a `nonisolated static` pure function that
// takes every input as a parameter — `trackedDefs(scope: .full)` is exactly
// `composeTrackedDefs(base: StockSageUniverse.worldwide, userSymbols:, offBoardHoldings:)`, so
// pinning THIS is pinning that method's real behavior without touching the singleton.

@MainActor
struct StockSageComposeTrackedDefsTests {
    @Test func journalOpenSymbolOutsideTheBaseUniverseAndWatchlistIsIncluded() {
        // GME never made the curated universe or the watchlist — only an open journal trade
        // references it (mirrors trackedSymbols' own journalOpenSymbolAbsentFromBoardIsIncluded).
        let base = [StockSageSymbol(symbol: "AAPL", market: "NASDAQ")]
        let defs = StockSageStore.composeTrackedDefs(base: base, userSymbols: [], offBoardHoldings: ["GME"])
        #expect(defs.map(\.symbol) == ["AAPL", "GME"])
    }

    @Test func offBoardHoldingAlreadyInTheBaseUniverseIsNotDuplicated() {
        let base = [StockSageSymbol(symbol: "AAPL", market: "NASDAQ")]
        let defs = StockSageStore.composeTrackedDefs(base: base, userSymbols: [], offBoardHoldings: ["aapl"])
        #expect(defs.map(\.symbol) == ["AAPL"])
    }

    @Test func offBoardHoldingAlreadyOnTheWatchlistIsNotDuplicated() {
        let base = [StockSageSymbol(symbol: "AAPL", market: "NASDAQ")]
        let defs = StockSageStore.composeTrackedDefs(base: base, userSymbols: ["GME"], offBoardHoldings: ["gme"])
        #expect(defs.map(\.symbol) == ["AAPL", "GME"])
    }

    @Test func emptyOffBoardHoldingsChangesNothing() {
        let base = [StockSageSymbol(symbol: "AAPL", market: "NASDAQ")]
        let defs = StockSageStore.composeTrackedDefs(base: base, userSymbols: ["MSFT"], offBoardHoldings: [])
        #expect(defs.map(\.symbol) == ["AAPL", "MSFT"])
    }
}
