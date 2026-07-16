import Foundation

/// A deterministic 64-bit PRNG (SplitMix64) so the ruin simulation is reproducible — the same seed
/// yields a byte-identical result. The app had no seedable RNG; this keeps the Monte-Carlo honest
/// and unit-testable (a simulation you cannot reproduce is a number you cannot trust).
nonisolated struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Forward-looking tail risk: bootstrap the journal's realized-R outcomes into many simulated
/// futures at the configured risk-per-trade, and report the DISTRIBUTION of drawdown and ruin —
/// the thing one historical path (the streak / underwater curve) cannot show. Estimates drawn
/// from YOUR own sample, never fabricated, and only when the sample is large enough to mean anything.
struct MonteCarloRuin: Sendable, Equatable {
    let pRuin: Double            // P(equity ever falls to/below ruinLevel) over the horizon
    let p20DrawdownProb: Double  // P(a path's max drawdown exceeds 20%)
    let medianMaxDD: Double      // median of per-path max drawdown (0…1)
    let p95MaxDD: Double         // 95th-percentile max drawdown (the bad-but-plausible path)
    let sims: Int
    let sampleSize: Int          // R-defined closed trades the resample drew from
}

enum StockSageMonteCarloRuin {
    /// Bootstrap-resample closed-trade R at `riskFraction` per trade (equity compounds by 1+f·R).
    /// Returns nil when the log is too thin to resample honestly (< `minTrades` R-defined trades)
    /// so a 3-trade history can't manufacture a scary — or a falsely comforting — ruin number.
    nonisolated static func simulate(_ trades: [TradeRecord], riskFraction: Double,
                                     horizon: Int = 100, sims: Int = 10_000,
                                     seed: UInt64 = 0x5A1E_B0A7, ruinLevel: Double = 0.5,
                                     minTrades: Int = 20) -> MonteCarloRuin? {
        let rs = trades.filter { !$0.isOpen }.compactMap { $0.realizedR }
        // [D-3 2026-07-03] Floor at max(1, minTrades): a caller-supplied minTrades <= 0 must not
        // let an empty sample reach the bootstrap draw below (`% UInt64(n)` traps on n == 0).
        guard rs.count >= Swift.max(1, minTrades), riskFraction > 0, horizon > 0, sims > 0 else { return nil }
        let f = riskFraction
        let n = rs.count
        var rng = SplitMix64(seed: seed)
        var ruinCount = 0, dd20Count = 0
        var maxDDs: [Double] = []; maxDDs.reserveCapacity(sims)
        for _ in 0..<sims {
            var equity = 1.0, peak = 1.0, maxDD = 0.0, ruined = false
            for _ in 0..<horizon {
                let r = rs[Int(rng.next() % UInt64(n))]
                equity *= (1 + f * r)
                if equity < 0 || !equity.isFinite { equity = 0 }   // clamp negative/impossible to ruin
                if equity > peak { peak = equity }
                let dd = peak > 0 ? (peak - equity) / peak : 0
                if dd > maxDD { maxDD = dd }
                if equity <= ruinLevel { ruined = true }
            }
            if ruined { ruinCount += 1 }
            if maxDD > 0.20 { dd20Count += 1 }
            maxDDs.append(maxDD)
        }
        maxDDs.sort()
        func pct(_ p: Double) -> Double {
            let idx = Int((Double(maxDDs.count - 1) * p).rounded())
            return maxDDs[Swift.max(0, Swift.min(maxDDs.count - 1, idx))]
        }
        return MonteCarloRuin(pRuin: Double(ruinCount) / Double(sims),
                              p20DrawdownProb: Double(dd20Count) / Double(sims),
                              medianMaxDD: pct(0.5), p95MaxDD: pct(0.95),
                              sims: sims, sampleSize: n)
    }

    nonisolated static let caveat =
        "Bootstraps YOUR closed-trade R outcomes assuming future trades resemble past ones and are independent — it ignores losing streaks that cluster and regime shifts, so it UNDER-states clustered-loss tails. A distribution of maybes, not a forecast."
}
