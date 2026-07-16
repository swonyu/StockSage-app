import Testing
import Foundation
@testable import StockSage

// MARK: - ExecutionQualityMath.worstLegBps (pure) — hand-derived fixtures
//
// legSlippageBps formula (StockSageJournal.swift): a BUY leg's cost-positive slippage is
// (fill - planned) / planned * 10_000; a SELL leg's is (planned - fill) / planned * 10_000.
// Long entry = BUY, long exit = SELL. worstLegBps is the MAX (most cost-positive = worst)
// signed leg across all closed trades' entry+exit legs.

struct ExecutionQualityMathTests {

    private func closedLong(entry: Double, plannedEntry: Double?, entryFill: Double?,
                            exitPrice: Double = 110, plannedExit: Double? = nil, exitFill: Double? = nil) -> TradeRecord {
        TradeRecord(symbol: "X", side: .long, entry: entry, stop: entry - 10, target: nil,
                    shares: 10, openedAt: Date(timeIntervalSince1970: 0),
                    exitPrice: exitPrice, closedAt: Date(timeIntervalSince1970: 100),
                    plannedEntry: plannedEntry, entryFill: entryFill,
                    plannedExit: plannedExit, exitFill: exitFill)
    }

    @Test func nilWithNoMeasuredLegs() {
        let trades = [closedLong(entry: 100, plannedEntry: nil, entryFill: nil)]
        #expect(ExecutionQualityMath.worstLegBps(trades) == nil)
    }

    @Test func singleEntryLegMatchesHandDerivedFormula() {
        // Long entry (BUY): planned 100, fill 100.5 -> (100.5-100)/100*10000 = 50 bps (paid worse).
        let trades = [closedLong(entry: 100, plannedEntry: 100, entryFill: 100.5)]
        #expect(abs((ExecutionQualityMath.worstLegBps(trades) ?? -999) - 50) < 1e-9)
    }

    @Test func picksTheMostCostPositiveLegAcrossMultipleTrades() {
        // Trade A entry: BUY planned 100 fill 100.5 -> +50 bps.
        // Trade B entry: BUY planned 50 fill 50.05 -> (50.05-50)/50*10000 = +10 bps.
        // Trade B exit: SELL planned 60 fill 59.94 -> (60-59.94)/60*10000 = +10 bps.
        // Worst (max) of {+50, +10, +10} = +50.
        let a = closedLong(entry: 100, plannedEntry: 100, entryFill: 100.5)
        let b = closedLong(entry: 50, plannedEntry: 50, entryFill: 50.05,
                            exitPrice: 60, plannedExit: 60, exitFill: 59.94)
        #expect(abs((ExecutionQualityMath.worstLegBps([a, b]) ?? -999) - 50) < 1e-9)
    }

    @Test func priceImprovementLegsAreNegativeAndNotMistakenForWorst() {
        // Long entry price improvement: planned 100, fill 99.5 -> (99.5-100)/100*10000 = -50 bps.
        // Long exit price improvement: SELL planned 110 fill 110.5 -> (110-110.5)/110*10000 ≈ -45.45 bps.
        // Worst (max, i.e. least negative = least good) of {-50, -45.4545...} = -45.4545...
        let trade = closedLong(entry: 100, plannedEntry: 100, entryFill: 99.5,
                                exitPrice: 110, plannedExit: 110, exitFill: 110.5)
        let expected = (110.0 - 110.5) / 110.0 * 10_000  // -45.4545...
        #expect(abs((ExecutionQualityMath.worstLegBps([trade]) ?? 999) - expected) < 1e-9)
    }

    @Test func openTradesAreExcludedEvenWithFillFieldsSet() {
        // isOpen legs never count (mirrors measuredSlippage's own `!t.isOpen` filter).
        let openTrade = TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: nil,
                                    shares: 10, openedAt: Date(timeIntervalSince1970: 0),
                                    plannedEntry: 100, entryFill: 105)
        #expect(ExecutionQualityMath.worstLegBps([openTrade]) == nil)
    }
}
