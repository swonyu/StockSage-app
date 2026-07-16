import Foundation

// MARK: - StockSage signal engine
//
// Ported verbatim (logic unchanged) from the StockSage v32 package's
// `MarketSignalEngine` — the one genuinely real, pure, dependency-free piece of
// the package. Deterministic price→recommendation mapping; trivially testable.
// Namespaced + internal access (the package's `public` was meaningless in a
// single-module app).

enum StockSageRecommendation: String, Sendable {
    case strongBuy  = "Strong Buy"
    case buy        = "Buy"
    case hold       = "Hold"
    case sell       = "Sell"
    case strongSell = "Strong Sell"
}

struct StockSageSignal: Sendable, Equatable {
    let symbol: String
    let recommendation: StockSageRecommendation
    let confidence: Double
    let reason: String
}

enum StockSageSignalEngine {

    /// Map a price move to a recommendation. Thresholds (from the package):
    ///   * |Δ| > 6%   → strong buy / strong sell
    ///   * |Δ| > 2.5% → buy / sell
    ///   * otherwise  → hold
    /// Confidence scales with the move magnitude, capped at 0.92; a hold is a
    /// flat 0.65. Pure function — no I/O, no state.
    static func generateSignal(symbol: String,
                               currentPrice: Double,
                               previousPrice: Double) -> StockSageSignal {
        // Defensive: a corrupt or missing price (≤0) must not masquerade as a confident
        // "consolidating" hold — say so honestly and keep the function total.
        guard currentPrice > 0, previousPrice > 0 else {
            return StockSageSignal(symbol: symbol, recommendation: .hold,
                                   confidence: 0.5, reason: "No valid price to assess")
        }
        let changePercent = ((currentPrice - previousPrice) / previousPrice) * 100
        let absChange = abs(changePercent)

        let recommendation: StockSageRecommendation
        let reason: String
        var confidence = min(absChange / 8, 0.92)

        if absChange > 6 {
            recommendation = changePercent > 0 ? .strongBuy : .strongSell
            reason = changePercent > 0 ? "Very strong upward momentum" : "Sharp selling pressure"
        } else if absChange > 2.5 {
            recommendation = changePercent > 0 ? .buy : .sell
            reason = changePercent > 0 ? "Positive momentum building" : "Downward pressure detected"
        } else {
            recommendation = .hold
            reason = "Price consolidating"
            confidence = 0.65
        }

        return StockSageSignal(symbol: symbol, recommendation: recommendation,
                               confidence: confidence, reason: reason)
    }

    /// Convenience: derive a signal straight from a symbol's latest quote.
    /// Returns nil when the symbol has no quote to evaluate.
    static func generateSignal(for symbol: StockSageSymbol) -> StockSageSignal? {
        guard let latest = symbol.latest else { return nil }
        return generateSignal(symbol: symbol.symbol,
                              currentPrice: latest.price,
                              previousPrice: latest.previousPrice)
    }
}
