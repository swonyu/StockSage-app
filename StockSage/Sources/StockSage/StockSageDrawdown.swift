import Foundation

// MARK: - Underwater / drawdown curve
//
// Max drawdown is one number; the UNDERWATER curve is the whole story — how deep
// you went below the prior high AND how LONG you stayed there. Time underwater is
// the part that actually breaks people: a 30% drop that recovers in a month is
// survivable; the same drop that takes three years is the one you sell at the
// bottom. Pure + tested. A backward-looking record of one path, not a prediction.

struct UnderwaterCurve: Sendable, Equatable {
    /// % below the running peak at each point (0 at a new high, negative in a drawdown).
    let series: [Double]
    /// Worst depth as a positive magnitude (%).
    let maxDrawdown: Double
    /// Longest run of consecutive underwater points (bars below the prior peak).
    let longestUnderwaterBars: Int

    var isEmpty: Bool { series.isEmpty }
}

enum StockSageDrawdown {
    /// Underwater curve from a price/equity series. At each point: % below the
    /// running peak — 0 at a new high, negative while below it.
    nonisolated static func underwater(_ values: [Double]) -> UnderwaterCurve {
        guard let first = values.first else {
            return UnderwaterCurve(series: [], maxDrawdown: 0, longestUnderwaterBars: 0)
        }
        var peak = first
        var series: [Double] = []
        series.reserveCapacity(values.count)
        var maxDD = 0.0
        var longest = 0, current = 0
        for v in values {
            if v > peak { peak = v }
            let dd = peak > 0 ? (v / peak - 1) * 100 : 0   // ≤ 0
            series.append(dd)
            maxDD = Swift.max(maxDD, -dd)
            if dd < 0 {
                current += 1
                longest = Swift.max(longest, current)
            } else {
                current = 0
            }
        }
        return UnderwaterCurve(series: series, maxDrawdown: maxDD, longestUnderwaterBars: longest)
    }
}
