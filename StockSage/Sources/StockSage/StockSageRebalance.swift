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
    /// returned. nil for an empty target/book, invalid domain or unrepresentable
    /// value/aggregate. Missing-FX scope must be explicitly chosen by the caller.
    nonisolated static func plan(holdings: [(symbol: String, value: Double)],
                                 targets: [String: Double], band: Double = 0.02) -> RebalancePlan? {
        // Every supplied value participates in the stated scope. Dropping an
        // unknown holding or converting an unknown target to zero fabricates trades.
        guard band.isFinite, (0...1).contains(band),
              holdings.allSatisfy({ $0.value.isFinite && $0.value >= 0 }),
              targets.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let total = holdings.reduce(0) { $0 + $1.value }
        guard total > 0, total.isFinite else { return nil }
        let tSum = targets.values.reduce(0, +)
        guard tSum > 0, tSum.isFinite else { return nil }
        let norm = targets.mapValues { $0 / tSum }
        guard norm.allSatisfy({ key, value in
            value.isFinite && (0...1).contains(value) && (targets[key] == 0 || value > 0)
        }) else { return nil }

        var current: [String: Double] = [:]
        for holding in holdings {
            let value = current[holding.symbol, default: 0] + holding.value
            guard value.isFinite else { return nil }
            current[holding.symbol] = value
        }

        var trades: [RebalanceTrade] = []
        for symbol in Set(current.keys).union(norm.keys).sorted() {
            let value = current[symbol] ?? 0
            let cw = value / total
            let tw = norm[symbol] ?? 0
            guard cw.isFinite, (0...1).contains(cw), value == 0 || cw > 0 else { return nil }
            let drift = tw - cw
            if abs(drift) > band {
                let delta = drift * total
                guard delta.isFinite, drift == 0 || delta != 0 else { return nil }
                trades.append(RebalanceTrade(symbol: symbol, currentWeight: cw,
                                             targetWeight: tw, deltaValue: delta))
            }
        }

        // Biggest moves first; symbol breaks ties so the plan is a total order (review C2 —
        // sort is not stable, an equal-magnitude pair could swap between runs).
        trades.sort {
            abs($0.deltaValue) != abs($1.deltaValue) ? abs($0.deltaValue) > abs($1.deltaValue) : $0.symbol < $1.symbol
        }
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
