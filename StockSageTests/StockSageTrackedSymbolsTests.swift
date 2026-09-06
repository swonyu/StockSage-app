import Testing
@testable import StockSage

// MARK: - trackedSymbols union (coverage: watchlist ∪ board ∪ portfolio ∪ journal-open)
//
// Pure function, no store/network access — inputs below are hand-typed arrays, not derived
// from any live store. Order contract per the function's own doc: board order first, then
// watchlist/portfolio/journalOpen in first-seen order; dedup is case-folded (uppercase).

struct StockSageTrackedSymbolsTests {
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
