import Testing
import Foundation
@testable import StockSage

// F19/F20 extraction (2026-07-15): the board's sort/filter/search contract, previously untestable
// inside MarketsView.displayedIdeas (audit F16). All fixtures HAND-DERIVED — never read off the
// code under test. A silent filter bug here invisibly hides ideas from the board, so these pins
// guard user-facing truth, not style.
@MainActor
struct StockSageIdeaProjectionTests {
    typealias P = StockSageIdeaProjection

    private func idea(_ symbol: String, market: String = "M", action: TradeAdvice.Action = .buy,
                      conviction: Double = 0.6, price: Double = 100,
                      stop: Double? = 90, target: Double? = 120) -> StockSageIdea {
        StockSageIdea(symbol: symbol, market: market, price: price,
                      advice: TradeAdvice(action: action, conviction: conviction, regime: .bullTrend,
                                          rationale: [], stopPrice: stop, targetPrice: target,
                                          suggestedWeight: 0.05, caveat: "x"),
                      spark: [])
    }

    private func displayed(_ ideas: [StockSageIdea], sort: P.Sort = .signal, filter: P.Filter = .all,
                           minConv: Double = 0, search: String = "") -> [StockSageIdea] {
        P.displayed(ideas, sort: sort, filter: filter, minConviction: minConv, search: search,
                    regime: nil, earnings: [:], liquidity: [:], seasonality: [:],
                    holds: .defaults, calibration: nil)
    }

    // Filter semantics: buys = strongBuy + buy ONLY; sells = sell + reduce; strongBuy exact.
    // A hold idea appears only under .all.
    @Test func filterSemanticsPartitionActionsCorrectly() {
        let ideas = [idea("SB", action: .strongBuy), idea("B", action: .buy),
                     idea("H", action: .hold), idea("S", action: .sell), idea("R", action: .reduce)]
        #expect(displayed(ideas, filter: .all).map(\.symbol) == ["SB", "B", "H", "S", "R"])
        #expect(displayed(ideas, filter: .strongBuy).map(\.symbol) == ["SB"])
        #expect(displayed(ideas, filter: .buys).map(\.symbol) == ["SB", "B"])
        #expect(displayed(ideas, filter: .sells).map(\.symbol) == ["S", "R"])
    }

    // Min-conviction boundary STRADDLE at 0.5: 0.49 excluded, 0.50 included (the code's `>=`),
    // and 0 = show-all (a 0.01-conviction idea survives).
    @Test func minConvictionThresholdStraddlesTheBoundary() {
        let ideas = [idea("LO", conviction: 0.49), idea("AT", conviction: 0.50), idea("HI", conviction: 0.51)]
        #expect(displayed(ideas, minConv: 0.5).map(\.symbol) == ["AT", "HI"])
        #expect(displayed([idea("TINY", conviction: 0.01)], minConv: 0).map(\.symbol) == ["TINY"])
    }

    // Search matches symbol OR market, case-insensitive, whitespace-trimmed; no match → empty.
    @Test func searchMatchesSymbolOrMarketCaseInsensitively() {
        let ideas = [idea("AAPL", market: "US Equity"), idea("2222.SR", market: "Tadawul")]
        #expect(displayed(ideas, search: "aapl").map(\.symbol) == ["AAPL"])
        #expect(displayed(ideas, search: "tadawul").map(\.symbol) == ["2222.SR"])   // via market
        #expect(displayed(ideas, search: "  AAPL  ").map(\.symbol) == ["AAPL"])     // trimmed
        #expect(displayed(ideas, search: "ZZZ").isEmpty)
        #expect(displayed(ideas, search: "   ").count == 2)                          // all-space = no filter
    }

    // .rr sort, hand-derived: A entry 100/stop 90/target 130 → 30/10 = 3.0;
    // B entry 100/stop 95/target 110 → 10/5 = 2.0 → A before B. And the 50 cap:
    // C entry 100/stop 99.9/target 200 → 100/0.1 = 1000 → capped at 50, still first.
    @Test func rewardRiskSortOrdersByHandDerivedRatios() {
        let a = idea("A", stop: 90, target: 130), b = idea("B", stop: 95, target: 110)
        #expect(displayed([b, a], sort: .rr).map(\.symbol) == ["A", "B"])
        #expect(abs(P.rewardRisk(a) - 3.0) < 1e-12)
        #expect(abs(P.rewardRisk(b) - 2.0) < 1e-12)
        let c = idea("C", stop: 99.9, target: 200)
        #expect(abs(P.rewardRisk(c) - 50) < 1e-12)                                  // capped
        // degenerate legs → 0 (missing stop; stop == price)
        #expect(P.rewardRisk(idea("X", stop: nil, target: 120)) == 0)
        #expect(P.rewardRisk(idea("Y", price: 100, stop: 100, target: 120)) == 0)
    }

    // .signal preserves the scan's input order (no re-rank).
    @Test func signalSortPreservesInputOrder() {
        let ideas = [idea("C3", conviction: 0.2), idea("A1", conviction: 0.9), idea("B2", conviction: 0.5)]
        #expect(displayed(ideas, sort: .signal).map(\.symbol) == ["C3", "A1", "B2"])
        // contrast: .conviction re-sorts descending
        #expect(displayed(ideas, sort: .conviction).map(\.symbol) == ["A1", "B2", "C3"])
    }

    // Enum stability pins (the @AppStorage identity contract + F08 label + picker exclusion).
    // A rawValue rename would silently reset every user's persisted sort/filter choice.
    @Test func enumRawValuesAndPickerContractAreStable() {
        #expect(P.Sort.conviction.rawValue == "Conviction")            // stable storage key (F08)
        #expect(P.Sort.conviction.label == "Signal strength")          // display-only rename
        #expect(P.Sort.momentumWeighted.rawValue == "Momentum-weighted")
        #expect(!P.Sort.pickerCases.contains(.momentumWeighted))       // audit 2026-07-12 exclusion
        #expect(P.Sort.pickerCases.count == P.Sort.allCases.count - 1)
        #expect(P.Filter.all.rawValue == "All" && P.Filter.buys.rawValue == "Buys")
    }
}
