import Testing
import Foundation
@testable import StockSage

// MARK: - Cross-sectional relative-strength ranking (pure, standalone, NOT wired anywhere —
// HARDENING_BACKLOG #32, deliberately unwired pending a dedicated backtest)

struct StockSageRelativeStrengthTests {
    typealias RS = StockSageRelativeStrength

    @Test func distinctReturnsGetEvenlySpacedPercentilesWeakestToStrongest() {
        // python-verified: sorted A(-5) C(0) B(10) D(20), n=4, denom=3.
        let ranked = RS.rank(["A": -5.0, "B": 10.0, "C": 0.0, "D": 20.0])
        let byPct = Dictionary(uniqueKeysWithValues: ranked.map { ($0.symbol, $0.percentile) })
        #expect(abs(byPct["A"]! - 0.0) < 1e-9)
        #expect(abs(byPct["C"]! - (1.0 / 3.0)) < 1e-9)
        #expect(abs(byPct["B"]! - (2.0 / 3.0)) < 1e-9)
        #expect(abs(byPct["D"]! - 1.0) < 1e-9)
    }

    @Test func rankingIsMonotonicInTheInputReturn() {
        let ranked = RS.rank(["A": -5.0, "B": 10.0, "C": 0.0, "D": 20.0])
        let sortedByReturn = ranked.sorted { $0.inputReturnPct < $1.inputReturnPct }
        let sortedByPercentile = ranked.sorted { $0.percentile < $1.percentile }
        #expect(sortedByReturn.map(\.symbol) == sortedByPercentile.map(\.symbol))
    }

    @Test func everyPercentileIsBoundedZeroToOne() {
        let ranked = RS.rank(["A": -100.0, "B": 0.001, "C": 50.0, "D": -3.0, "E": 200.0])
        for r in ranked { #expect(r.percentile >= 0 && r.percentile <= 1) }
    }

    @Test func tiedReturnsGetTheAveragedPercentileNotAnArbitraryOrder() {
        // python-verified: A=0.0, B&C tie at 5.0 (avg idx 1,2 of 0...3 → 0.5), D=1.0.
        let ranked = RS.rank(["A": 0.0, "B": 5.0, "C": 5.0, "D": 10.0])
        let byPct = Dictionary(uniqueKeysWithValues: ranked.map { ($0.symbol, $0.percentile) })
        #expect(abs(byPct["A"]! - 0.0) < 1e-9)
        #expect(abs(byPct["B"]! - 0.5) < 1e-9)
        #expect(abs(byPct["C"]! - 0.5) < 1e-9)
        #expect(byPct["B"] == byPct["C"])   // exact tie, not merely close
        #expect(abs(byPct["D"]! - 1.0) < 1e-9)
    }

    @Test func allTiedReturnsAllLandAtTheNeutralMidpoint() {
        // python-verified: 3-way tie → every symbol lands at exactly 0.5.
        let ranked = RS.rank(["A": 5.0, "B": 5.0, "C": 5.0])
        for r in ranked { #expect(abs(r.percentile - 0.5) < 1e-9) }
    }

    @Test func singleHoldingIsNeutralNotTriviallyStrongest() {
        let ranked = RS.rank(["A": 7.0])
        #expect(ranked.count == 1)
        #expect(ranked[0].symbol == "A")
        #expect(abs(ranked[0].percentile - 0.5) < 1e-9)
        #expect(abs(ranked[0].inputReturnPct - 7.0) < 1e-9)
    }

    @Test func emptyInputReturnsEmptyNeverCrashes() {
        #expect(RS.rank([:]).isEmpty)
    }

    @Test func twoHoldingsSplitZeroAndOne() {
        let ranked = RS.rank(["A": -1.0, "B": 1.0])
        let byPct = Dictionary(uniqueKeysWithValues: ranked.map { ($0.symbol, $0.percentile) })
        #expect(abs(byPct["A"]! - 0.0) < 1e-9)
        #expect(abs(byPct["B"]! - 1.0) < 1e-9)
    }

    @Test func inputReturnPctIsPreservedVerbatim() {
        let ranked = RS.rank(["A": 12.345])
        #expect(ranked[0].inputReturnPct == 12.345)
    }

    @Test func nonFiniteReturnsAreDroppedNotAllowedToCorruptTheOthers() {
        // 2026-07-01 adversarial-review hardening: a NaN/infinite value must not compare as < or
        // == anything (IEEE-754), which would otherwise silently break the sort and tie-detection
        // for every OTHER symbol sharing the call. Dropped entirely, not ranked.
        let ranked = RS.rank(["A": 0.0, "B": .nan, "C": 10.0, "D": .infinity, "E": -.infinity])
        let symbols = Set(ranked.map(\.symbol))
        #expect(symbols == ["A", "C"])
        let byPct = Dictionary(uniqueKeysWithValues: ranked.map { ($0.symbol, $0.percentile) })
        #expect(abs(byPct["A"]! - 0.0) < 1e-9)
        #expect(abs(byPct["C"]! - 1.0) < 1e-9)
    }

    @Test func allNonFiniteInputReturnsEmpty() {
        #expect(RS.rank(["A": .nan, "B": .infinity]).isEmpty)
    }

    @Test func singleFiniteSurvivorAfterDroppingNonFiniteIsNeutral() {
        let ranked = RS.rank(["A": 5.0, "B": .nan])
        #expect(ranked.count == 1)
        #expect(ranked[0].symbol == "A")
        #expect(abs(ranked[0].percentile - 0.5) < 1e-9)
    }

    @Test func caveatIsAlwaysPresentAndNamesTheTiebreakerLimit() {
        #expect(!RS.caveat.isEmpty)
        #expect(RS.caveat.localizedCaseInsensitiveContains("tiebreaker"))
    }
}
