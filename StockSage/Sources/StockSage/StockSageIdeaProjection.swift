import Foundation

// MARK: - Ideas-board list projection (F19/F20 extraction, 2026-07-15)
//
// The board's sort + filter + search pipeline, extracted VERBATIM from MarketsView's private
// `displayedIdeas` so the contract is testable (audit F16: filter semantics, the min-conviction
// threshold, and search matching could previously not be pinned — a silent filter bug would
// invisibly hide ideas). Behavior-preserving: the view now delegates here; the enums moved with
// their raw values UNCHANGED so the @AppStorage("marketsIdeaSort"/"marketsIdeaFilter") persisted
// identities still decode (the F08 note: `conviction`'s rawValue stays "Conviction" as the stable
// storage key; only `label` shows "Signal strength").
//
// Deliberate scope (the deciding session's F19/F20 architecture call, post the 2026-07-09 owner
// gate-class lift): `fullPlanText` is NOT extracted — it is a ~150-line export-critical surface
// repeatedly audited IN SITU (F04/F15/F27/F2/pass-3 annotations), every component it composes
// (TradePlan.text, NetEdge, PositionSizer, PartialLadder) already has its own engine tests, and a
// big-bang extraction of a correct surface trades real regression risk for marginal convenience.

enum StockSageIdeaProjection {

    /// Board sort modes. Raw values are the STABLE @AppStorage identity keys — never rename them.
    enum Sort: String, CaseIterable {
        case ev = "Expected value", velocity = "EV / day", conviction = "Conviction",
             rr = "Reward:risk", signal = "Signal rank", momentumWeighted = "Momentum-weighted"
        /// Shown name. `conviction`'s rawValue stays "Conviction" as the stable
        /// @AppStorage("marketsIdeaSort") identity key; F08 renames only the label.
        var label: String { self == .conviction ? "Signal strength" : rawValue }
        /// Audit 2026-07-12 (ideas-card): the picker OFFERS only these. `momentumWeighted` is EXCLUDED
        /// because its momentum multiplier is inert with the default empty `closes` — it produced a
        /// list byte-identical to `.velocity` while the UI claimed a momentum factor was applied (a
        /// mislabel). The case stays in the enum so a previously-persisted @AppStorage value still
        /// decodes and works (falls through to the velocity order it always produced); it just can't be
        /// newly selected. Re-add it here only once per-symbol closes are actually threaded into the rank.
        static var pickerCases: [Sort] { allCases.filter { $0 != .momentumWeighted } }
    }

    /// Ideas board action filter — jump straight to the strongest setups.
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", strongBuy = "Strong Buy", buys = "Buys", sells = "Sells"
        var id: String { rawValue }
    }

    /// Reward:risk for an idea — symmetric so it works for SHORT (sell/reduce) setups too,
    /// matching the detail sheet's `ev.rewardR`. 0 only when a leg is missing or stop == price.
    nonisolated static func rewardRisk(_ idea: StockSageIdea) -> Double {
        guard let stop = idea.advice.stopPrice, let target = idea.advice.targetPrice,
              abs(idea.price - stop) > 0 else { return 0 }
        return min(abs(target - idea.price) / abs(idea.price - stop), 50)
    }

    /// The board's displayed list: sort by `sort`, then filter by action / min-conviction / search.
    /// Byte-for-byte the logic MarketsView.displayedIdeas ran in place before the extraction.
    nonisolated static func displayed(_ ideas: [StockSageIdea],
                                      sort: Sort,
                                      filter: Filter,
                                      minConviction: Double,
                                      search: String,
                                      regime: MarketRegime?,
                                      earnings: [String: EarningsProximity],
                                      liquidity: [String: LiquidityProfile],
                                      seasonality: [String: MonthlySeasonality],
                                      holds: VelocityHoldDays,
                                      calibration: StockSageConvictionCalibration?) -> [StockSageIdea] {
        let sorted: [StockSageIdea]
        switch sort {
        case .ev:         sorted = StockSageExpectedValue.rankByEV(ideas, regime: regime, earnings: earnings, liquidity: liquidity, seasonality: seasonality, calibration: calibration)
        case .velocity:   sorted = StockSageExpectedValue.rankByVelocity(ideas, holds: holds, earnings: earnings, liquidity: liquidity, calibration: calibration)
        case .conviction: sorted = ideas.sorted { $0.advice.conviction > $1.advice.conviction }
        case .rr:         sorted = ideas.sorted { rewardRisk($0) > rewardRisk($1) }
        case .signal:     sorted = ideas
        // Momentum-weighted velocity rank: with the default empty `closes` the quality
        // multiplier is inert and this IS fastLane's earnings/liquidity-aware order —
        // momentum weighting activates when per-symbol closes are threaded in a future pass.
        case .momentumWeighted: sorted = StockSageExpectedValue.rankByVelocityWeighted(ideas, holds: holds, calibration: calibration, earnings: earnings, liquidity: liquidity)
        }
        var result: [StockSageIdea]
        switch filter {
        case .all:       result = sorted
        case .strongBuy: result = sorted.filter { $0.advice.action == .strongBuy }
        case .buys:      result = sorted.filter { $0.advice.action == .strongBuy || $0.advice.action == .buy }
        case .sells:     result = sorted.filter { $0.advice.action == .sell || $0.advice.action == .reduce }
        }
        if minConviction > 0 { result = result.filter { $0.advice.conviction >= minConviction } }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { result = result.filter { $0.symbol.lowercased().contains(q) || $0.market.lowercased().contains(q) } }
        return result
    }
}
