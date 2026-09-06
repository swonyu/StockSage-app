import Testing
import SwiftUI
@testable import StockSage

// MARK: - Significance-gated backtest verdict color (AUDIT_FINDINGS_2 #1)
//
// Truth table from the finding's own spec (python sketch in AUDIT_FINDINGS_2.md #1):
// color(pos, sig) = neutral if !sig else (green if pos else red-family). Token equality, not RGB.
// ux-wave-2 D4: the negative-significant branch swapped danger -> dangerSoft (every caller
// renders this at ~12.5pt TEXT, so the wave's small-danger-TEXT-is-AA invariant applies) —
// this pin was updated to match that deliberate, directive-sanctioned change.

struct BacktestVerdictColorTests {
    @Test func insignificantSamplesRenderNeutralRegardlessOfSign() {
        #expect(BacktestVerdict.metricColor(positive: true, significant: false) == DS.Palette.textSecondary)
        #expect(BacktestVerdict.metricColor(positive: false, significant: false) == DS.Palette.textSecondary)
        #expect(BacktestVerdict.metricColor(positive: true, significant: true) == DS.Palette.successSoft)
        #expect(BacktestVerdict.metricColor(positive: false, significant: true) == DS.Palette.dangerSoft)
        // The gate must actually distinguish: neutral ≠ either verdict token.
        #expect(DS.Palette.textSecondary != DS.Palette.successSoft)
        #expect(DS.Palette.textSecondary != DS.Palette.dangerSoft)
    }
}

// MARK: - Action badge fill/ink (review 2026-07-28 #6)
//
// Sell/Reduce was white-on-`danger` (#FF453A) — 3.41:1 at the badge's 11pt bold TEXT, below
// the AA 4.5:1 bar. Every action badge must now be a light pastel fill + dark ink (the pattern
// buy/hold already used), matching how this file's own metricColor pins the same
// small-danger-TEXT-is-AA invariant. Reaches MarketsView's private actionColor/actionTextColor
// via the same static `ForTest`-suffixed seam metricColor uses (a top-level/static pure
// function, testable without a live View instance).
struct ActionBadgeColorTests {
    @Test func actionBadgesUseLightFillDarkInk() {
        // Every action badge must be a pastel fill with dark ink — the AA pattern the
        // buy/hold badges already used and the sell badge did not (3.41:1 white-on-red).
        for a in [TradeAdvice.Action.strongBuy, .buy, .hold, .reduce, .sell] {
            #expect(MarketsView.actionTextColorForTest(a) == Color(white: 0.06))
        }
        #expect(MarketsView.actionColorForTest(.sell) == DS.Palette.dangerSoft)
        #expect(MarketsView.actionColorForTest(.reduce) == DS.Palette.dangerSoft)
        // .avoid is the one deliberate exception: white text stays on its 22%-white fill.
        #expect(MarketsView.actionTextColorForTest(.avoid) == .white)
    }
}
