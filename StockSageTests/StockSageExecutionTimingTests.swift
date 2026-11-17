import Testing
import Foundation
@testable import StockSage

// MARK: - Execution-timing advisory tests (pure, deterministic)
// Spec: RESEARCH_2026-07-02_week_horizon_velocity.md roadmap item #2
//   ✓ Trending buy/sell actions get the overnight-session note
//   ✓ Range regime never gets it (different signal type, not covered by the finding)
//   ✓ Hold/avoid never get it (not actionable)
//   ✓ caveat is non-empty

struct StockSageExecutionTimingTests {
    typealias ET = StockSageExecutionTiming

    @Test func trendingBuyGetsTheOvernightNote() {
        #expect(ET.sessionNote(action: .strongBuy, regime: .bullTrend) != nil)
        #expect(ET.sessionNote(action: .buy, regime: .bullTrend)!.lowercased().contains("overnight"))
    }

    @Test func trendingSellGetsTheOvernightNoteToo() {
        // Sell/reduce ideas are also a trend-following (short) construction — the finding covers
        // past-return strategies generally, not just long-side momentum.
        #expect(ET.sessionNote(action: .sell, regime: .bearTrend) != nil)
        #expect(ET.sessionNote(action: .reduce, regime: .bearTrend) != nil)
    }

    @Test func rangeRegimeNeverGetsTheNote() {
        // .range is the RSI-oversold-bounce / mean-reversion read, a structurally different
        // signal type than the past-return momentum families the finding covers.
        #expect(ET.sessionNote(action: .strongBuy, regime: .range) == nil)
        #expect(ET.sessionNote(action: .sell, regime: .range) == nil)
    }

    @Test func nonActionableAdviceNeverGetsTheNote() {
        #expect(ET.sessionNote(action: .hold, regime: .bullTrend) == nil)
        #expect(ET.sessionNote(action: .avoid, regime: .bullTrend) == nil)
        #expect(ET.sessionNote(action: .hold, regime: .range) == nil)
    }

    @Test func caveatIsNonEmptyAndHonest() {
        #expect(!ET.caveat.isEmpty)
        #expect(ET.caveat.lowercased().contains("not a promise"))
    }

    @Test func noteCarriesTheMeasuredExecutionCurve() {
        // 2026-07-11 intraday-curve measurement (method pinned pre-result): the pinned decision
        // rule returned REVISE-ADVISORY — the note must carry the measured facts: the close's
        // liquidity depth, its slightly-above-midday ranges, and the avoid-the-open warning.
        // No symbol (default "") is treated as US → the measured curve shows (backward-compat).
        let note = ET.sessionNote(action: .buy, regime: .bullTrend)!.lowercased()
        #expect(note.contains("deepest liquidity"))
        #expect(note.contains("measured"))
        #expect(note.contains("open is the costliest"))
    }

    // Audit 2026-07-12 (wave-2 #6): the measured intraday curve was measured on 64 US names, so it
    // must NOT be presented as applicable to a Tadawul/.L/.T listing. The market-agnostic
    // overnight-premia rationale still shows for all trend ideas; the US-ET microstructure sentence
    // drops for non-US symbols.
    @Test func measuredCurveIsUSOnlyButOvernightRationaleIsUniversal() {
        // US symbol → keeps the measured microstructure sentence.
        let us = ET.sessionNote(action: .buy, regime: .bullTrend, symbol: "AAPL")!.lowercased()
        #expect(us.contains("measured") && us.contains("open is the costliest"))
        // Tadawul → overnight rationale stays, measured US curve DROPS.
        let sr = ET.sessionNote(action: .sell, regime: .bearTrend, symbol: "1120.SR")!.lowercased()
        #expect(sr.contains("overnight"))                    // market-agnostic rationale kept
        #expect(!sr.contains("measured on this us universe")) // US-only curve dropped
        #expect(!sr.contains("64"))                          // the "64 names" measurement gone
        // London pence + Tokyo → same (non-USD).
        #expect(!ET.sessionNote(action: .buy, regime: .bullTrend, symbol: "BP.L")!.lowercased().contains("64"))
        #expect(!ET.sessionNote(action: .buy, regime: .bullTrend, symbol: "7203.T")!.lowercased().contains("64"))
    }
}
