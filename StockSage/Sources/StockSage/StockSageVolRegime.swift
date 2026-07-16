import Foundation

// MARK: - Per-symbol realized-vol regime brake (Edge Research #1)
//
// Evidence: vol clustering + the equity leverage effect are among the most robust
// facts in finance (Engle 1982 ARCH; Black 1976 leverage effect). High realized vol
// predicts more high vol; the worst left-tail returns cluster at elevated vol regimes.
// A per-name realized-vol read turns this into a data-only de-risk gate that works on
// TADAWUL / FX / CRYPTO names the VIX cannot cover (^VIX is US-equity-only). This is
// the documented complement to StockSageRegime (market-wide, VIX-driven) — "detect
// regime first, then size", but per-symbol and VIX-free.
//
// Design:
//   • Build a rolling 21-bar realized-vol series over the close history (volWindow=21).
//   • Rank the LATEST vol via its empirical CDF over 252 historical windows (historyWindow=252).
//   • sizingMultiplier is CONTINUOUS, monotone-non-increasing, ≤1. It blends:
//       - absoluteBrake = min(1, medianVol/currentVol) — rises to 1× at/below median,
//         shrinks as current vol exceeds median (absolute regime-blind signal).
//       - percentileBrake = max(0.5, 1 − max(0, p−0.5)) — 1× for p≤0.5, linear to 0.5×
//         at p=1.0 (relative, own-history-aware signal).
//       The minimum of the two is taken (more conservative) floored at 0.25.
//   • Composes with StockSageRegime.adjustedWeight (market-wide bias) and
//     StockSageExpectedValue.cryptoRiskScaler under one cap.
//   • Caveat: the leverage effect is STRONGEST for equities/credit; weaker for FX/commodities.
//     Percentile-of-own-history is also regime-blind: a structurally high-vol name (crypto)
//     reads "calm" at absolutely dangerous vols — the absoluteBrake term corrects for this.

struct VolRegime: Sendable, Equatable {
    /// Latest 21-bar annualized realized vol (0..1 as a fraction).
    let current: Double
    /// Median 21-bar vol over the historyWindow rolling series.
    let median: Double
    /// Empirical CDF rank of current vol in its own history (0 = calmest, 1 = most elevated).
    let percentile: Double
    /// Position-size multiplier ≤1 that encodes both absolute and relative vol stress. 1.0 = no brake.
    let sizingMultiplier: Double
    let note: String
    let caveat: String
}

enum StockSageVolRegime {
    nonisolated static let caveat = "A risk gate, not a forecast — brakes position SIZE when a name's own realized vol is historically elevated. Does NOT predict direction. The leverage effect is documented strongest for equities/credit; for FX/commodities the brake is a heuristic, not a peer-reviewed result. Percentile-of-own-history is regime-blind: a structurally high-vol era can read 'calm' at absolutely dangerous levels — the absolute-vol anchor corrects for this."

    /// Compute the per-symbol vol regime. Returns nil when `closes` is too short
    /// (needs at least `volWindow + historyWindow` bars ≈ 273 for default parameters).
    ///
    /// Algorithm:
    ///   1. Build a rolling series of `historyWindow` annualized-vol readings, each
    ///      computed over a trailing `volWindow` window of closes.
    ///   2. Rank the latest reading via its empirical CDF position in that series.
    ///   3. Compute a continuous, monotone-non-increasing sizing multiplier ≤1.
    nonisolated static func regime(closes: [Double],
                                   volWindow: Int = 21,
                                   historyWindow: Int = 252,
                                   periodsPerYear: Double = 252) -> VolRegime? {
        let minBars = volWindow + historyWindow
        guard closes.count >= minBars else { return nil }

        // Build rolling 21-bar vol series over the last historyWindow windows. Each window is
        // a CLOSED range ending AT i (inclusive) — a half-open `..<i` would silently exclude
        // the anchor bar itself, permanently lagging every reading (including `current`, the
        // final one) by one trading day behind the latest available close.
        var series: [Double] = []
        series.reserveCapacity(historyWindow)
        let start = closes.count - historyWindow   // first window ending-index
        for i in start ..< closes.count {
            let window = Array(closes[(i - volWindow + 1)...i])
            guard let v = StockSageIndicators.annualizedVolatility(window, periodsPerYear: periodsPerYear),
                  v.isFinite, v > 0 else { continue }
            series.append(v)
        }
        guard series.count >= 5 else { return nil }   // degenerate — too few valid windows

        let current = series.last!
        let sorted = series.sorted()
        let median = StockSagePortfolioAnalytics.percentile(sorted, 0.5)

        // Empirical CDF: fraction of historical windows with vol ≤ current.
        let pct = Double(series.filter { $0 <= current }.count) / Double(series.count)

        let mult = sizingMultiplier(percentile: pct, currentVol: current, medianVol: median)

        let pctLabel = Int((pct * 100).rounded())
        let note: String
        if pct < 0.5 {
            note = String(format: "Vol in the %dth percentile of its own 12-month history (%.0f%% realized vs. %.0f%% median) — calm; no brake applied.",
                          pctLabel, current * 100, median * 100)
        } else if mult >= 0.95 {
            note = String(format: "Vol in the %dth percentile (%.0f%% realized vs. %.0f%% median) — slightly elevated; minimal brake (×%.2f).",
                          pctLabel, current * 100, median * 100, mult)
        } else {
            note = String(format: "Vol in the %dth percentile of its own 12-month history (%.0f%% realized vs. %.0f%% median) — elevated; position braked to ×%.2f.",
                          pctLabel, current * 100, median * 100, mult)
        }

        return VolRegime(current: current, median: median, percentile: pct,
                         sizingMultiplier: mult, note: note, caveat: caveat)
    }

    /// Continuous sizing multiplier ≤1. Monotone-non-increasing in both `percentile` and
    /// `currentVol/medianVol`. Two components blend via `min` (take the more conservative):
    ///   absoluteBrake — reciprocal of vol/median, floored so it can't go below 0.25.
    ///   percentileBrake — linear from 1.0 (p≤0.5) to 0.5 (p=1.0).
    nonisolated static func sizingMultiplier(percentile: Double,
                                             currentVol: Double,
                                             medianVol: Double) -> Double {
        // Absolute anchor: ≤1 when current exceeds median, decreasing as vol rises.
        let absFloor = medianVol * 0.01   // prevent divide-by-zero when medianVol≈0
        let absoluteBrake = Swift.min(1.0, medianVol / Swift.max(absFloor, currentVol))

        // Percentile-relative: 1× at or below median, linear to 0.5× at the 100th pct.
        let percentileBrake = Swift.max(0.5, 1.0 - Swift.max(0.0, percentile - 0.5))

        // Take the more conservative of the two; hard floor so sizing never goes to 0.
        return Swift.max(0.25, Swift.min(absoluteBrake, percentileBrake))
    }
}
