import Testing
import Foundation
@testable import StockSage

// MARK: - Sector-rotation confirmation read (pure, flag-only — HARDENING_BACKLOG #31, reframed)

struct StockSageSectorRotationTests {

    typealias SR = StockSageSectorRotation

    /// One CLOSED long trade in `symbol`'s sector with realizedR == exitR (risk = entry−stop = 10).
    private func closedTrade(_ symbol: String, exitR: Double, day: Int = 0) -> TradeRecord {
        let entry = 100.0, stop = 90.0
        let exit = entry + exitR * (entry - stop)
        return TradeRecord(symbol: symbol, side: .long, entry: entry, stop: stop, target: nil,
                            shares: 1, openedAt: Date(timeIntervalSince1970: Double(day) * 86_400),
                            exitPrice: exit, closedAt: Date(timeIntervalSince1970: Double(day) * 86_400 + 3_600))
    }

    /// An OPEN trade (no exit) — must be excluded from every ranking.
    private func openTrade(_ symbol: String) -> TradeRecord {
        TradeRecord(symbol: symbol, side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                    openedAt: Date(timeIntervalSince1970: 0))
    }

    /// entry == stop → realizedR is nil (undefined risk); must be excluded from the average.
    private func undefinedRTrade(_ symbol: String) -> TradeRecord {
        TradeRecord(symbol: symbol, side: .long, entry: 100, stop: 100, target: nil, shares: 1,
                    openedAt: Date(timeIntervalSince1970: 0), exitPrice: 105,
                    closedAt: Date(timeIntervalSince1970: 3_600))
    }

    // MARK: - Ranking

    // 5 Technology trades avgR +1.0 vs 5 Financials trades avgR +0.2 → Technology ranks #1.
    @Test func ranksSectorsByAvgRDescendingAndFlagsTopN() {
        let techSymbols = ["AAPL", "MSFT", "NVDA", "GOOGL", "AVGO"]
        let finSymbols = ["JPM", "BAC", "WFC", "GS", "MS"]
        let trades = techSymbols.enumerated().map { i, s in closedTrade(s, exitR: 1.0, day: i) }
            + finSymbols.enumerated().map { i, s in closedTrade(s, exitR: 0.2, day: i) }

        let ranked = SR.analyze(allTrades: trades, minTrades: 5, topN: 1)
        #expect(ranked.count == 2)
        #expect(ranked[0].sector == "Technology")
        #expect(ranked[0].rank == 1)
        #expect(ranked[0].isRotatingIn == true)
        #expect(ranked[1].sector == "Financials")
        #expect(ranked[1].rank == 2)
        #expect(ranked[1].isRotatingIn == false)   // topN == 1, only rank 1 flagged
        #expect(abs(ranked[0].avgR - 1.0) < 1e-9)
        #expect(abs(ranked[1].avgR - 0.2) < 1e-9)
    }

    // Shuffling input trade order must not change the ranking (grouping is order-independent).
    @Test func rankingIsStableUnderInputReordering() {
        let techSymbols = ["AAPL", "MSFT", "NVDA", "GOOGL", "AVGO"]
        let finSymbols = ["JPM", "BAC", "WFC", "GS", "MS"]
        var trades = techSymbols.enumerated().map { i, s in closedTrade(s, exitR: 1.0, day: i) }
            + finSymbols.enumerated().map { i, s in closedTrade(s, exitR: 0.2, day: i) }
        trades.shuffle()
        let ranked = SR.analyze(allTrades: trades, minTrades: 5)
        #expect(ranked.map(\.sector) == ["Technology", "Financials"])
    }

    // MARK: - Small-sample honesty gate ("nil on too few")

    @Test func sectorBelowMinTradesIsOmittedAndSignalIsNil() {
        let trades = (0..<4).map { closedTrade("AAPL", exitR: 1.0, day: $0) }   // 4 < minTrades 5
        let ranked = SR.analyze(allTrades: trades, minTrades: 5)
        #expect(ranked.isEmpty)
        #expect(SR.signal(for: "AAPL", allTrades: trades, minTrades: 5) == nil)
    }

    // Empty journal (buildIdeas' default `journalTrades: []`) → no sectors, nil for every symbol —
    // this is what makes the buildIdeas wiring byte-identical when unused.
    @Test func emptyJournalProducesNoSignalForAnySymbol() {
        #expect(SR.analyze(allTrades: []).isEmpty)
        #expect(SR.signal(for: "AAPL", allTrades: []) == nil)
    }

    // MARK: - Exclusions

    @Test func openTradesAreExcludedFromTheAverage() {
        var trades = (0..<5).map { closedTrade("AAPL", exitR: 1.0, day: $0) }
        trades.append(contentsOf: (0..<10).map { _ in openTrade("AAPL") })   // opens must not dilute avgR
        let sig = try! #require(SR.signal(for: "AAPL", allTrades: trades, minTrades: 5))
        #expect(abs(sig.avgR - 1.0) < 1e-9)
        #expect(sig.trades == 5)
    }

    @Test func undefinedRTradesAreExcludedFromTheAverage() {
        var trades = (0..<5).map { closedTrade("AAPL", exitR: 1.0, day: $0) }
        trades.append(contentsOf: (0..<10).map { _ in undefinedRTrade("AAPL") })   // entry==stop → realizedR nil
        let sig = try! #require(SR.signal(for: "AAPL", allTrades: trades, minTrades: 5))
        #expect(abs(sig.avgR - 1.0) < 1e-9)
        #expect(sig.trades == 5)
    }

    // MARK: - Honesty caveat / lag disclosure

    @Test func caveatIsAlwaysPresentAndNamesTheLag() {
        #expect(!SR.caveat.isEmpty)
        #expect(SR.caveat.contains("LAGGING"))
        let trades = (0..<5).map { closedTrade("AAPL", exitR: 1.0, day: $0) }
        let sig = try! #require(SR.signal(for: "AAPL", allTrades: trades, minTrades: 5))
        #expect(sig.caveat == SR.caveat)
        #expect(!sig.note.isEmpty)
    }

    // MARK: - 2026-07-01 adversarial-review fix: rank alone isn't "paid off"

    @Test func aNetLosingSectorIsNeverFlaggedRotatingInEvenAtRankOne() {
        // Every eligible sector is a net LOSER — the least-bad one still ranks #1, but "rotating
        // in" implies capital has recently paid off, which a negative avgR directly contradicts.
        let techSymbols = ["AAPL", "MSFT", "NVDA", "GOOGL", "AVGO"]
        let finSymbols = ["JPM", "BAC", "WFC", "GS", "MS"]
        let trades = techSymbols.enumerated().map { i, s in closedTrade(s, exitR: -0.1, day: i) }
            + finSymbols.enumerated().map { i, s in closedTrade(s, exitR: -0.5, day: i) }
        let ranked = SR.analyze(allTrades: trades, minTrades: 5, topN: 3)
        #expect(ranked.count == 2)
        #expect(ranked[0].sector == "Technology")
        #expect(ranked[0].rank == 1)
        #expect(ranked[0].avgR < 0)
        #expect(!ranked[0].isRotatingIn)   // rank #1, but still a net loser — not "rotating in"
        #expect(!ranked[0].note.contains("rotating in"))
        for r in ranked { #expect(!r.isRotatingIn) }
    }

    @Test func aGenuinelyProfitableRankOneSectorIsStillFlaggedRotatingIn() {
        // Regression guard: the fix must not accidentally suppress the TRUE-positive case.
        let techSymbols = ["AAPL", "MSFT", "NVDA", "GOOGL", "AVGO"]
        let trades = techSymbols.enumerated().map { i, s in closedTrade(s, exitR: 1.0, day: i) }
        let ranked = SR.analyze(allTrades: trades, minTrades: 5, topN: 3)
        #expect(ranked.count == 1)
        #expect(ranked[0].avgR > 0)
        #expect(ranked[0].isRotatingIn)
        #expect(ranked[0].note.contains("rotating in"))
    }

    @Test func exactAvgRTiesBreakDeterministicallyByAlphabeticalSectorName() {
        // 2026-07-01 adversarial-review fix: `groups` is a Swift Dictionary internally, whose
        // iteration order carries NO stability guarantee — two sectors tied at the EXACT same
        // avgR could previously rank differently from run to run. Technology and Financials here
        // are both exactly 1.0R avg over 5 trades — "Financials" < "Technology" alphabetically,
        // so the tie-break must deterministically place Financials at rank #1 every time.
        let techSymbols = ["AAPL", "MSFT", "NVDA", "GOOGL", "AVGO"]
        let finSymbols = ["JPM", "BAC", "WFC", "GS", "MS"]
        let trades = techSymbols.enumerated().map { i, s in closedTrade(s, exitR: 1.0, day: i) }
            + finSymbols.enumerated().map { i, s in closedTrade(s, exitR: 1.0, day: i) }
        for _ in 0..<10 {   // repeat: a flaky Dictionary-order bug wouldn't necessarily fail on try #1
            let ranked = SR.analyze(allTrades: trades, minTrades: 5, topN: 3)
            #expect(ranked.count == 2)
            #expect(abs(ranked[0].avgR - ranked[1].avgR) < 1e-9)   // genuine exact tie
            #expect(ranked[0].sector == "Financials")
            #expect(ranked[0].rank == 1)
            #expect(ranked[1].sector == "Technology")
            #expect(ranked[1].rank == 2)
        }
    }
}
