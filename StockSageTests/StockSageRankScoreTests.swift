import Testing
import Foundation
@testable import StockSage

// MARK: - Board default-ordering (rankScore) total-order pins — AUDIT F41
// `StockSageStore.rankScore` is the board's default `.signal` ordering; it was `private`
// with ZERO tests — "a single sign slip silently reorders the board." Made `internal`
// (visibility only, behavior byte-identical) so the total order can be pinned here.
// Expected values derived independently in /tmp/derive_rankscore.swift (NOT read off code):
//   @conviction 0.5: strongBuy 2.5 > buy 1.5 > hold 0 > avoid -0.1 > reduce -1.5 > sell -2.5
//   tie-break: higher conviction ranks buys UP, sells DOWN (more negative = stronger sell)
//   action-class boundaries touch but never cross: buy(1.0)=2.0=strongBuy(0.0); reduce(1.0)=-2.0=sell(0.0)

struct StockSageRankScoreTests {

    /// Minimal TradeAdvice for ranking — only `action`/`conviction` feed rankScore; the rest
    /// are inert placeholders (the memberwise init requires them, defaults cover the rest).
    private func adv(_ action: TradeAdvice.Action, _ conviction: Double) -> TradeAdvice {
        TradeAdvice(action: action, conviction: conviction, regime: .bullTrend,
                    rationale: [], stopPrice: nil, targetPrice: nil,
                    suggestedWeight: 0, caveat: "")
    }
    private func score(_ action: TradeAdvice.Action, _ c: Double) -> Double {
        StockSageStore.rankScore(adv(action, c))
    }

    @Test func totalOrderAcrossAllSixActionsAtEqualConviction() {
        let c = 0.5
        let ordered: [TradeAdvice.Action] = [.strongBuy, .buy, .hold, .avoid, .reduce, .sell]
        let scores = ordered.map { score($0, c) }
        // Strictly descending — the exact board order the ForEach renders top-to-bottom.
        for (hi, lo) in zip(scores, scores.dropFirst()) { #expect(hi > lo) }
        // Exact values (all binary-representable; -0.1 literal == -0.1 literal in IEEE754).
        #expect(scores == [2.5, 1.5, 0.0, -0.1, -1.5, -2.5])
    }

    @Test func convictionTieBreakDirection() {
        // Higher conviction ranks a BUY higher…
        #expect(score(.strongBuy, 0.8) > score(.strongBuy, 0.2))
        #expect(score(.buy, 0.8) > score(.buy, 0.2))
        // …and a SELL lower (more negative = stronger sell, sorts to the bottom).
        #expect(score(.sell, 0.8) < score(.sell, 0.2))
        #expect(score(.reduce, 0.8) < score(.reduce, 0.2))
        // Hold/avoid ignore conviction entirely (flat constants).
        #expect(score(.hold, 0.9) == score(.hold, 0.1))
        #expect(score(.avoid, 0.9) == score(.avoid, 0.1))
    }

    @Test func actionClassBoundariesTouchButNeverCross() {
        // Deliberate: a max-conviction buy can TIE the weakest strong-buy but never beat it,
        // so a StrongBuy call is never out-ranked by a Buy call regardless of conviction.
        #expect(score(.buy, 1.0) <= score(.strongBuy, 0.0))
        #expect(score(.reduce, 1.0) >= score(.sell, 0.0))
        // Within the strong-buy band, conviction still separates strictly.
        #expect(score(.strongBuy, 0.0) < score(.strongBuy, 1.0))
    }
}
