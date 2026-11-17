import Foundation

// MARK: - Conviction-scaled, regime-gated per-trade risk cap (FASTMONEY_BACKLOG #6)
//
// Re-audit (2026-07-01) found the backlog's premise about the CURRENT mechanism was stale/wrong
// on two counts: (1) the "(0.4 + 0.6*conviction)" scaler it cites lives in
// StockSageExpectedValue.qualityWeight and only re-weights the VELOCITY/EV RANKING key — it does
// not touch StockSageAdvisor.suggestedWeight's sizing math at all; (2) suggestedWeight's per-trade
// RISK really is a flat, non-conviction-scaled 1% (StockSageAdvisor.riskPerTrade) that conviction
// can only ever SHRINK (via the Kelly half-fraction feeding it), never grow, and regime is never
// applied to it at the engine level (StockSageRegime.sizingBias is applied only to the WEIGHT, as
// a display-only "Regime size" hint in MarketsView). Separately, StockSageCapitalAllocator.allocate/
// suggestAdd DO already compose conviction (via Kelly's win-prob) and regime (StockSageRegime.
// sizingBias) into sizing — but the resulting fraction is fed DIRECTLY into
// StockSagePositionSizer.size(riskFraction:), i.e. it IS a stop-risk fraction, capped only by
// StockSageKelly.maxFraction (20%) per-position and by portfolio maxHeat (8%/10% default) in
// aggregate — so a single concentrated idea can realistically be sized to 8-20% dollar-risk-at-stop
// today, nowhere close to a hard 2%/trade ceiling. NEITHER existing path enforces the backlog's
// actual ask. This adds ONLY the missing piece: a pure, explicit, hard-capped-at-2% risk-fraction
// function. It is deliberately NOT wired into advise()/suggestedWeight() or
// StockSageCapitalAllocator in this pass — conviction feeds ranking+EV+sizing everywhere, so a new
// conviction-nudging signal needs its own careful wiring/backtest pass, exactly like
// FASTMONEY_BACKLOG #8 (StockSageCompoundingHorizon) shipped engine-only before any UI wiring. Pure
// + deterministic → unit-tested.
//
// HONESTY is load-bearing: conviction scales SIZE, not odds — conviction is rule strength, not a
// win probability; a bigger position amplifies both wins and losses. Never skip the stop.

enum StockSageConvictionScaler {
    nonisolated static let caveat =
        "Conviction scales SIZE, not odds — conviction is rule strength, not win probability; " +
        "bigger positions amplify both wins and losses. Never skip the stop."

    /// Hard ceiling: whatever conviction/regime say, never risk more than this share of the
    /// account on a single trade.
    nonisolated static let maxRiskFraction = 0.02
    /// Floor: even rock-bottom conviction in a crisis regime still risks at least this much — the
    /// scaler shrinks size, it does not fully zero out a genuine buy signal.
    nonisolated static let minRiskFraction = 0.005

    /// `base` (the flat per-trade risk budget — pass `StockSageAdvisor.riskPerTrade`, 1%, to match
    /// today's default) scaled by conviction (0.5× at conviction 0 → 1.5× at conviction ≥ 1.0) and
    /// by `regimeBias` (`MarketRegime.sizingBias` — 0.25 crisis … 1.25 strong bull), then re-capped
    /// at `maxRiskFraction` (2%) and floored at `min(minRiskFraction, base × 0.5)`. Non-finite/
    /// non-positive `base` → 0 (nothing to scale). Non-finite/non-positive `regimeBias` falls back
    /// to a neutral 1.0× (no regime adjustment) rather than propagating a garbage multiplier. Pure
    /// + deterministic; NOT called from advise()/suggestedWeight() — callers opt in explicitly.
    nonisolated static func scaledRiskFraction(base: Double = 0.01, conviction: Double,
                                               regimeBias: Double) -> Double {
        guard base.isFinite, base > 0 else { return 0 }
        let c = conviction.isFinite ? Swift.max(0, Swift.min(1, conviction)) : 0
        let bias = (regimeBias.isFinite && regimeBias > 0) ? regimeBias : 1.0
        let convictionMultiplier = Swift.min(1.5, 0.5 + c)
        let raw = base * convictionMultiplier * bias
        // The floor never RAISES risk above the conviction multiplier's own 0.5× lower bound for
        // the caller's base (2026-07-09 review fix): the absolute 0.5% floor was designed for the
        // documented 1% base — fed a smaller user-configured base (e.g. 0.1% risk/trade) it
        // silently scaled the DISPLAYED risk up to 5× the configured budget, the dangerous
        // direction for a risk-discipline surface. `min(0.5%, base·0.5)` is byte-identical for
        // every base ≥ 1% (there base·0.5 ≥ 0.5%, so the effective floor is still 0.5%).
        let floor = Swift.min(minRiskFraction, base * 0.5)
        return Swift.max(floor, Swift.min(maxRiskFraction, raw))
    }
}
