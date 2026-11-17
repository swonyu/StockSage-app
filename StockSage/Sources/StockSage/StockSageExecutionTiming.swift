import Foundation

// MARK: - Execution-timing advisory (week-horizon velocity research, item #2)
//
// Evidence: Lou, Polk & Skouras, "A Tug of War: Overnight vs Intraday Expected Returns"
// (JFE; verified 3-0 ×3 in RESEARCH_2026-07-02_week_horizon_velocity.md). Across 14 US
// strategies (1993-2013, non-microcap), all five PAST-RETURN strategies — 12-1 price
// momentum, industry momentum, earnings momentum, time-series momentum, and short-term
// reversal — earn their premia ENTIRELY OVERNIGHT (12-1 momentum: overnight CAPM alpha
// 0.98%/month t=3.84 vs intraday −0.02% t=−0.06; overnight Sharpe 0.77 vs 0.31 close-to-
// close), while nine OTHER anomaly types earn entirely intraday. This is a ZERO-added-
// turnover lever: it changes WHEN an already-planned entry executes, not whether to trade.
//
// StockSage's OWN trend-family signal (12-1 TSMOM + SMA/MACD trend, capped together —
// StockSageAdvisor.trendFamilyCap) is exactly a past-return / momentum-family construction,
// so this applies directly to any idea whose regime reads `.bullTrend`/`.bearTrend` (a
// score-positive/negative TRENDING read, not the `.range` mean-reversion/RSI-bounce case,
// which is a structurally different signal type this specific finding doesn't cover).
//
// Advisory ONLY: appended to `rationale`, exactly like ReturnShape/VolStability/VolRegime/
// SectorRotation before it. Never touches score/conviction/stopPrice/targetPrice/
// suggestedWeight — the ranking/sizing math is completely untouched.

enum StockSageExecutionTiming {
    nonisolated static let caveat =
        "A documented pattern (Lou-Polk-Skouras), not a promise for any single trade — timing an " +
        "entry doesn't change WHICH setups to take, only when to place an already-decided order."

    /// Advisory note for a trend-driven buy/sell idea: momentum/trend premia are documented to
    /// accrue almost entirely in the OVERNIGHT session, so entering near the close (to hold the
    /// position overnight) captures more of the historical edge than a mid-session entry. nil for
    /// non-trending (`.range`) or non-actionable (`.hold`/`.avoid`) advice — this is specifically
    /// the momentum-family finding, not a generic timing tip.
    ///
    /// The execution-cost sentence carries MEASURED numbers (2026-07-11 intraday curve, 64 US
    /// names × ~80 days of 1-minute bars, method pinned pre-result — see
    /// tools/eodhd_panel/METHOD_2026-07-11_intraday_curve.md + intraday_curve.json): close bucket
    /// = 20.0% of session volume (3.7× midday) at minute-ranges ~20% above midday (9.7 vs 8.1bp
    /// median); opening bucket ≈ 3× midday ranges. Display-only; proxies, not realized spreads.
    /// Audit 2026-07-12 (ideas-card wave-2 #6): `symbol` gates the MEASURED intraday-microstructure
    /// sentence — that curve was measured on 64 US names, so it must NOT be presented as applicable
    /// to a Tadawul/`.L`/`.T` listing (whose session/auction structure differs entirely). The
    /// overnight-premia rationale (first sentence, market-agnostic — Lou-Polk-Skouras) always shows;
    /// the US-ET execution-cost sentence shows ONLY for USD-quoted symbols. `symbol` defaults to ""
    /// (treated as USD → prior behavior byte-identical) so an un-updated caller is unchanged.
    nonisolated static func sessionNote(action: TradeAdvice.Action, regime: TradeAdvice.Regime,
                                        symbol: String = "") -> String? {
        guard action == .strongBuy || action == .buy || action == .sell || action == .reduce else { return nil }
        switch regime {
        case .bullTrend, .bearTrend:
            let base = "Trend/momentum premia are documented to accrue almost entirely OVERNIGHT — " +
                       "entering near the close (to hold the position overnight) has historically captured " +
                       "more of this edge than a mid-session entry."
            // The measured microstructure numbers are US-only; show them only for US-listed symbols.
            let isUS = symbol.isEmpty || StockSageCurrency.currencyForSymbol(symbol) == "USD"
            guard isUS else {
                // First-real-trade review (2026-07-16): give Tadawul names their OWN session facts
                // so "near the close" is actionable in Riyadh time (static exchange schedule,
                // sourced 2026-07-16: Sun–Thu, continuous 10:00–15:00 AST, closing auction to
                // ~15:10 — saudiexchange.sa Trading Cycle and Times). Display-only, no US numbers.
                if symbol.uppercased().hasSuffix(".SR") {
                    return base + " Tadawul session: Sun–Thu, continuous 10:00–15:00 Riyadh with the " +
                           "closing auction to ~15:10 — \"near the close\" here means ~14:40–15:00 " +
                           "or the auction."
                }
                return base
            }
            return base + " Measured on this US universe (2026-07, 64 names): the close has the " +
                   "session's deepest liquidity (~20% of volume) at minute-ranges slightly above midday; " +
                   "the open is the costliest window (~3× midday ranges) — avoid it for these entries."
        case .range:
            return nil
        }
    }
}
