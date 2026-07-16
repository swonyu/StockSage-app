import Foundation

// MARK: - Alert decision (what's worth a notification)
//
// Pure, stateless decision: given a symbol's current state + a little prior context
// (its previous price, and the recommendation it was LAST alerted on), decide whether
// THIS update warrants a fresh notification — and never re-fire the same one. Keeping
// this pure means the (@MainActor, side-effecting) monitor stays a thin shell over a
// tested rule. Honest: an alert flags an EVENT, not a profit — act with your own plan.

struct StockSageAlert: Sendable, Equatable {
    enum Kind: String, Sendable {
        case newStrongBuy  = "Strong Buy"
        case newStrongSell = "Strong Sell"
        case flip          = "Signal flip"
        case stopBreach    = "Stop breached"
        case targetHit     = "Target hit"
    }
    let symbol: String
    let kind: Kind
    let reason: String
}

enum StockSageAlertDecision {
    /// Decide the single most-actionable alert for this update, or nil to stay silent.
    /// Priority: a price level CROSSED this bar (stop, then target) beats a signal change;
    /// signal alerts dedupe against `lastAlertedRecommendation` so the same one never repeats.
    nonisolated static func evaluate(symbol: String,
                                     recommendation: StockSageRecommendation,
                                     price: Double,
                                     priorPrice: Double,
                                     stop: Double?,
                                     target: Double?,
                                     lastAlertedRecommendation: StockSageRecommendation?) -> StockSageAlert? {
        // Side-aware crossings (mirrors StockSageAlerts.detect). A LONG stops BELOW / targets ABOVE;
        // a SHORT (sell/strongSell) stops ABOVE / targets BELOW. (Was long-only: a short's stop-out
        // was missed and a winning short fired a false stop.)
        let isShort = recommendation == .sell || recommendation == .strongSell
        // 1. Stop crossed this update.
        if let s = stop, s > 0 {
            let breached: Bool
            if isShort { breached = priorPrice < s && price >= s }
            else { breached = priorPrice > s && price <= s }
            if breached {
                let rel = isShort ? "≥" : "≤"
                return StockSageAlert(symbol: symbol, kind: .stopBreach,
                                      reason: "\(symbol) hit its stop (\(fmt(price)) \(rel) \(fmt(s))) — the setup is invalidated; risk is realized.")
            }
        }
        // 2. Target crossed this update.
        if let t = target, t > 0 {
            let hit: Bool
            if isShort { hit = priorPrice > t && price <= t }
            else { hit = priorPrice < t && price >= t }
            if hit {
                let rel = isShort ? "≤" : "≥"
                return StockSageAlert(symbol: symbol, kind: .targetHit,
                                      reason: "\(symbol) reached its target (\(fmt(price)) \(rel) \(fmt(t))) — consider taking profit or trailing the stop.")
            }
        }
        // 3. Strong-signal events only (buy/sell/hold don't notify), deduped vs last alert.
        let isStrong = recommendation == .strongBuy || recommendation == .strongSell
        guard isStrong, recommendation != lastAlertedRecommendation else { return nil }

        let flipped = (recommendation == .strongBuy && lastAlertedRecommendation == .strongSell)
            || (recommendation == .strongSell && lastAlertedRecommendation == .strongBuy)
        if flipped {
            return StockSageAlert(symbol: symbol, kind: .flip,
                                  reason: "\(symbol) FLIPPED to \(recommendation.rawValue) — re-evaluate any open position.")
        }
        return StockSageAlert(symbol: symbol,
                              kind: recommendation == .strongBuy ? .newStrongBuy : .newStrongSell,
                              reason: "\(symbol): new \(recommendation.rawValue) signal — check the plan before acting.")
    }

    /// ALERT-FMT-1: was bare %.2f — every board/card surface uses the 3-tier adaptive formatter,
    /// so a sub-dollar stop/target pair (DOGE-USD: stop 0.099, target 0.104) collapsed to
    /// identical "0.10" push text. Routed through the shared formatter (StockSageCurrency,
    /// pure, tested there) so alert text matches what the board/sheet already show.
    private nonisolated static func fmt(_ v: Double) -> String { StockSageCurrency.adaptivePrice(v) }
}
