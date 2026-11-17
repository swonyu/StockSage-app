import Foundation

// MARK: - Risk-parity (inverse-volatility) portfolio sizing
//
// "Naive risk parity": weight each holding ∝ 1/volatility so every holding
// contributes the SAME amount of risk (weightᵢ × volᵢ is equal across holdings).
// A dollar-weighted 60/40 book hides ~85–90% of its risk in equities; this
// rebalances by RISK instead. Pure + deterministic → unit-tested. See
// MARKETS_INTELLIGENCE_RESEARCH.md §6 (and its caveat: vulnerable to
// correlation-regime shocks — keep a cash sleeve).

/// One holding's inputs: current dollar value + its annualized volatility.
struct RiskParityHolding: Sendable, Equatable, Identifiable {
    let symbol: String
    let currentValue: Double
    let volatility: Double      // annualized, e.g. 0.25 = 25%
    var id: String { symbol }
}

/// A holding's current vs risk-parity target weight (both over the valid set).
struct RiskParityTarget: Sendable, Equatable, Identifiable {
    let symbol: String
    let currentWeight: Double   // 0–1
    let targetWeight: Double    // 0–1 (inverse-vol)
    let volatility: Double
    /// Move needed: +ve = add to this holding, −ve = trim. Deltas sum to ~0.
    nonisolated var deltaWeight: Double { targetWeight - currentWeight }
    nonisolated var id: String { symbol }
}

/// How inverse-vol (risk-parity) target weights differ from naive equal-weight (1/N).
struct RiskParityVsEqual: Sendable, Equatable {
    let count: Int
    let equalWeight: Double      // 1/N
    let trimSymbol: String?      // most UNDER-weighted vs 1/N (the vol hog risk-parity cuts)
    let trimDelta: Double        // ≤0: targetWeight − 1/N
    let addSymbol: String?       // most OVER-weighted vs 1/N (the calmest name risk-parity adds to)
    let addDelta: Double         // ≥0

    nonisolated var note: String {
        guard let t = trimSymbol, let a = addSymbol else { return "" }
        return String(format: "Risk-parity trims %@ %+.0fpp vs equal-weight (it's the vol hog) and adds %+.0fpp to %@ (the calmest). Equal RISK ≠ equal dollars.",
                      t, trimDelta * 100, addDelta * 100, a)
    }
}

enum StockSageRiskParity {

    /// Compare risk-parity target weights to naive equal-weight (1/N): which name
    /// the vol-sizing trims most and which it adds to most. nil for <2 holdings.
    nonisolated static func vsEqualWeight(_ targets: [RiskParityTarget]) -> RiskParityVsEqual? {
        let n = targets.count
        guard n >= 2 else { return nil }
        let eq = 1.0 / Double(n)
        let deltas = targets.map { (symbol: $0.symbol, delta: $0.targetWeight - eq) }
        let trim = deltas.min(by: { $0.delta < $1.delta })!   // most negative
        let add = deltas.max(by: { $0.delta < $1.delta })!    // most positive
        return RiskParityVsEqual(count: n, equalWeight: eq,
                                 trimSymbol: trim.symbol, trimDelta: trim.delta,
                                 addSymbol: add.symbol, addDelta: add.delta)
    }

    /// Inverse-vol target weights, normalized to 1 over the holdings that have a
    /// usable (positive) volatility. Holdings with non-positive vol are dropped
    /// (can't be risk-sized). Current weights are computed over the same valid
    /// set so the deltas are directly comparable and sum to ~0.
    nonisolated static func targets(_ holdings: [RiskParityHolding]) -> [RiskParityTarget] {
        let valid = holdings.filter { $0.volatility > 0 && $0.currentValue >= 0 }
        guard !valid.isEmpty else { return [] }
        let validTotal = valid.reduce(0.0) { $0 + $1.currentValue }
        let sumInv = valid.reduce(0.0) { $0 + 1.0 / $1.volatility }
        guard sumInv > 0 else { return [] }
        return valid.map { h in
            let target = (1.0 / h.volatility) / sumInv
            // No dollar info (all zero) → show target as current so the delta is 0.
            let current = validTotal > 0 ? h.currentValue / validTotal : target
            return RiskParityTarget(symbol: h.symbol, currentWeight: current,
                                    targetWeight: target, volatility: h.volatility)
        }
    }

    /// Dollar rebalance per symbol to move from current → target given the book's
    /// total value (+ve = buy, −ve = sell). Excludes any cash sleeve (caller's call).
    nonisolated static func rebalanceAmounts(_ targets: [RiskParityTarget], totalValue: Double) -> [String: Double] {
        var out: [String: Double] = [:]
        for t in targets { out[t.symbol] = t.deltaWeight * totalValue }
        return out
    }
}
