import Foundation

// MARK: - Rebalance-to-target
//
// Given the current holdings (symbol, market value) and a set of target weights
// (e.g. inverse-vol risk parity, or equal weight), compute the per-symbol drift and
// the buy/sell trades that bring the book back to target. A no-trade BAND suppresses
// tiny drifts so you don't churn (and pay spread/tax) chasing a 0.5% miss. Pure +
// deterministic. Honest: ignores trading costs, taxes, and min-lot sizing — it's the
// direction and rough size, not an order ticket.

struct RebalanceTrade: Sendable, Equatable, Identifiable {
    let symbol: String
    let currentWeight: Double   // 0–1
    let targetWeight: Double    // 0–1
    let deltaValue: Double      // + = buy, − = sell (account currency)
    var id: String { symbol }
    nonisolated var action: String { deltaValue > 0 ? "Buy" : (deltaValue < 0 ? "Sell" : "Hold") }
}

struct RebalancePlan: Sendable, Equatable {
    let trades: [RebalanceTrade]   // only symbols whose drift exceeds the band
    let totalValue: Double
    nonisolated var isBalanced: Bool { trades.isEmpty }
}

enum StockSageRebalance {
    /// Trades to move `holdings` toward `targets` (weights need not be normalized — they
    /// are normalized here). Only drifts whose magnitude exceeds `band` (default 2%) are
    /// returned. nil if there's nothing invested or no positive target weight.
    nonisolated static func plan(holdings: [(symbol: String, value: Double)],
                                 targets: [String: Double], band: Double = 0.02) -> RebalancePlan? {
        // Non-finite values (a bad quote/FX multiply upstream) are excluded rather than
        // clamped — Swift.max(0, .nan) silently reads as "worthless" and .infinity passes
        // max(0, ·) unchanged, either of which would poison `total` and, through it, every
        // OTHER holding's weight and recommended trade size.
        let total = holdings.reduce(0) { $1.value.isFinite ? $0 + Swift.max(0, $1.value) : $0 }
        guard total > 0, total.isFinite else { return nil }

        let posTargets = targets.mapValues { $0.isFinite ? Swift.max(0, $0) : 0 }
        let tSum = posTargets.values.reduce(0, +)
        guard tSum > 0 else { return nil }
        let norm = posTargets.mapValues { $0 / tSum }

        var current: [String: Double] = [:]
        for h in holdings where h.value.isFinite { current[h.symbol, default: 0] += Swift.max(0, h.value) }

        var trades: [RebalanceTrade] = []
        for s in Set(current.keys).union(norm.keys).sorted() {
            let cw = (current[s] ?? 0) / total
            let tw = norm[s] ?? 0
            let drift = tw - cw
            if abs(drift) > band {
                trades.append(RebalanceTrade(symbol: s, currentWeight: cw, targetWeight: tw, deltaValue: drift * total))
            }
        }
        trades.sort { abs($0.deltaValue) > abs($1.deltaValue) }   // biggest moves first
        return RebalancePlan(trades: trades, totalValue: total)
    }

    /// Equal-weight targets over the held symbols — a simple default when no other target
    /// model is chosen.
    nonisolated static func equalWeightTargets(_ symbols: [String]) -> [String: Double] {
        let unique = Array(Set(symbols))
        guard !unique.isEmpty else { return [:] }
        let w = 1.0 / Double(unique.count)
        return Dictionary(uniqueKeysWithValues: unique.map { ($0, w) })
    }
}
