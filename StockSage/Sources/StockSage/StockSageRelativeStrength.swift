import Foundation

// MARK: - Cross-sectional relative-strength ranking (HARDENING_BACKLOG #32)
//
// Distinct from the ablated `StockSageAdvisor.relativeStrengthEnabled` (which compared ONE
// symbol against a BENCHMARK INDEX inside `advise()`'s score, gated off 2026-06-27 — DSR=0,
// redundant with the absolute trend term). This module compares ideas AGAINST EACH OTHER — a
// pure cross-sectional rank, structurally like `StockSageExpectedValue.rankByEV`/`rankByVelocity`
// — and never touches `advise()`, conviction, EV, or sizing anywhere.
//
// STANDING NOTE (2026-07-02, ablation complete): the dedicated ablation this file called for has
// now run — see RESEARCH_2026-07-02_confluence_rs_ablation.md (20-symbol/5yr walk-forward, no
// look-ahead, block-level significance, 5 forward horizons). Result: NO statistically significant
// forward-return edge at any horizon tested; the point estimate is mildly NEGATIVE, consistent
// with the known ≤1-month reversal anomaly. Conclusion: do NOT wire this into rankByEV/
// rankByVelocity/bestOpportunity/advise()/conviction — the ablation does not support it. This
// remains a STANDALONE, UNWIRED utility by design, not merely by omission.

struct RelativeStrengthRank: Sendable, Equatable, Identifiable {
    let symbol: String
    /// The input return this rank was computed from (whatever period the caller supplied —
    /// typically a ~1-month/21-bar return via `StockSageIndicators.returnOverPeriod`).
    let inputReturnPct: Double
    /// 0 (weakest of the group) … 1 (strongest of the group). A group of exactly one holding
    /// has no peer to compare against, so it is NEUTRAL (0.5), not trivially "strongest."
    let percentile: Double
    var id: String { symbol }
}

enum StockSageRelativeStrength {
    nonisolated static let caveat =
        "Ranks symbols only against EACH OTHER in this book, by a single trailing return window — " +
        "not a forecast, and not validated by any backtest yet. Momentum and mean-reversion both " +
        "exist in real markets, so a high or low rank here is a tiebreaker at most, never a signal " +
        "to act on alone."

    /// Cross-sectional percentile rank of each symbol's already-computed return (the caller
    /// supplies it — e.g. `StockSageIndicators.returnOverPeriod(closes, period: 21)` per symbol —
    /// so this function makes no new fetch/indicator call and stays pure). Ties (equal returns)
    /// receive EQUAL percentiles (averaged rank), so no arbitrary ordering is implied among them.
    /// A single-symbol input returns percentile 0.5 (neutral — nothing to compare against, not
    /// trivially "strongest"). Empty input returns an empty array, never a crash.
    nonisolated static func rank(_ returns: [String: Double]) -> [RelativeStrengthRank] {
        // Non-finite inputs (NaN/±infinity) are a caller bug, not a real return — drop them rather
        // than let a single garbage value corrupt the sort/tie-detection for every OTHER symbol
        // (NaN comparisons are neither < nor == under IEEE-754, which would silently break both).
        let returns = returns.filter { $0.value.isFinite }
        guard !returns.isEmpty else { return [] }
        guard returns.count > 1 else {
            let only = returns.first!
            return [RelativeStrengthRank(symbol: only.key, inputReturnPct: only.value, percentile: 0.5)]
        }
        let sorted = returns.sorted { $0.value < $1.value }   // ascending: weakest first
        let n = sorted.count
        // Average-rank percentile: every symbol tied at the same return value gets the MEAN of
        // the positions their tie would span, so equal inputs never receive different percentiles
        // (and never imply a false ordering among them) purely from dictionary/sort iteration order.
        var percentileBySymbol: [String: Double] = [:]
        var i = 0
        while i < n {
            var j = i
            while j + 1 < n, sorted[j + 1].value == sorted[i].value { j += 1 }
            let avgIdx = Double(i + j) / 2.0
            let pct = avgIdx / Double(n - 1)
            for k in i...j { percentileBySymbol[sorted[k].key] = pct }
            i = j + 1
        }
        return sorted.map { entry in
            RelativeStrengthRank(symbol: entry.key, inputReturnPct: entry.value,
                                 percentile: percentileBySymbol[entry.key] ?? 0.5)
        }
    }
}
