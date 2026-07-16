import Foundation

// MARK: - Downside-skew / left-tail read on a symbol's return distribution
//
// EV and Sharpe assume symmetric-ish payoffs; a name can show a fine mean and
// vol while hiding a FAT LEFT TAIL (crash-prone). This is a direct honesty check
// on "this setup's stop may gap": realized return SKEWNESS plus a historical
// 1-day 95% downside (the same percentile machinery PortfolioAnalytics.var95
// uses, but per-symbol). Pure transform of fetched closes — reuses
// StockSagePortfolioAnalytics.dailyReturns + .percentile. Deterministic, no ML.
//
// Honest by construction: sample skew over short daily history is NOISY and
// dominated by a handful of days — it describes the PAST distribution, never the
// next move, and one fresh crash can flip it. A "this name has had ugly down-days"
// flag, never a crash probability and never a sizing input here.

struct ReturnShape: Sendable, Equatable {
    /// 3rd standardized moment of daily returns (population formula: mean(((r−μ)/σ)^3)).
    let skewness: Double
    /// max(0, −5th-percentile daily return) — a positive loss fraction.
    let downside95: Double
    /// The single worst daily return (most negative), as a fraction (not ×100).
    let worstDay: Double
    /// True when skewness < −0.5 — historically asymmetric to the downside.
    let isLeftTailed: Bool
    /// One-line plain read of the distribution shape.
    let note: String
    /// The standing honesty caveat (always non-empty).
    let caveat: String
}

enum StockSageReturnShape {
    nonisolated static let caveat =
        "Sample skew over a short daily history is NOISY and dominated by a handful of days — " +
        "it describes the PAST distribution, not the next move, and a single fresh crash can flip it. " +
        "Read it as 'this name has historically had ugly down-days', never as a probability of a " +
        "future crash and never as a sizing input."

    /// Downside-skew / left-tail read over StockSagePortfolioAnalytics.dailyReturns(closes).
    ///
    /// - `skewness` = mean(((r−μ)/σ)^3) (population 3rd standardized moment)
    /// - `downside95` = max(0, −percentile(returns, 0.05)) — positive loss fraction
    /// - `worstDay` = returns.min()
    ///
    /// Returns nil when fewer than 30 daily returns (sample too short to be even weakly meaningful)
    /// or when the series has zero dispersion (skew undefined).
    nonisolated static func returnShape(closes: [Double]) -> ReturnShape? {
        let returns = StockSagePortfolioAnalytics.dailyReturns(closes)
        guard returns.count >= 30 else { return nil }

        let n = Double(returns.count)
        let mean = returns.reduce(0, +) / n

        // Population variance (÷N) so the 3rd-moment ratio is exactly mean(((r−μ)/σ)^3).
        let variance = returns.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let sd = variance.squareRoot()
        guard sd > 0 else { return nil }   // flat series → skew undefined

        let skewness = returns.reduce(0.0) { acc, r in
            let z = (r - mean) / sd
            return acc + z * z * z
        } / n

        let downside95 = Swift.max(0, -StockSagePortfolioAnalytics.percentile(returns, 0.05))
        let worstDay = returns.min() ?? 0
        // Require BOTH negative skew AND at least 2% downside tail — a noisy
        // skew-only threshold produces too many false positives at low N
        // (≤~120 daily returns). The 2% floor filters out trivial left-tail
        // noise that has no economic magnitude.
        let isLeftTailed = skewness < -0.5 && downside95 > 0.02

        let note = isLeftTailed
            ? String(
                format: "Left-tailed: skew %.2f, worst day %.1f%%, 1-day 95%% downside %.1f%% — historically ugly down-days.",
                skewness, worstDay * 100, downside95 * 100)
            : String(
                format: "Roughly symmetric: skew %.2f, 1-day 95%% downside %.1f%%.",
                skewness, downside95 * 100)

        return ReturnShape(
            skewness: skewness,
            downside95: downside95,
            worstDay: worstDay,
            isLeftTailed: isLeftTailed,
            note: note,
            caveat: caveat)
    }
}
