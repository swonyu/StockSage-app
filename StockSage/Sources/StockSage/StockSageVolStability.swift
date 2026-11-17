import Foundation

// MARK: - Vol-of-vol sizing-reliability read (EDGE_RESEARCH #5)
//
// ATR-stops and position-size both depend on realized vol being STABLE over the
// holding window. If the monthly vol series itself swings wildly (high vol-of-vol),
// a stop width or fraction set today on today's vol is mis-calibrated by next week.
// This computes the coefficient of variation (CoV = populaton-stdev / mean) of a
// rolling annualized-vol series over the trailing historyWindow bars, then maps it
// to a categorical band and a continuous sizing-reliability score in (0,1].
//
// Self-contained (EDGE_RESEARCH #5): builds its own rolling-vol series internally
// from closes via StockSageIndicators.annualizedVolatility — no StockSageVolRegime
// dependency (that rank-1 module was never built). Orthogonal to varianceScalar:
// varianceScalar is a LEVEL transform (current vol vs. target vol); volStability
// measures DISPERSION of the vol series over time — a name can have the same
// varianceScalar and very different sizingReliability.
//
// Honest by construction: this is a backward-looking read of vol stability, never
// a forecast of future vol. An erratic-vol name can still be a great trade setup;
// it just means the ATR stop and size are less trustworthy. Read-only — not wired
// into any sizing path here (wiring is a deferred owner decision).

struct VolStability: Sendable, Equatable {
    /// Population stdev / mean of the rolling annualized-vol series (scale-free, ≥ 0).
    let coeffOfVariation: Double
    /// Categorical stability band based on CoV thresholds.
    let band: Band
    /// 1 / (1 + CoV) ∈ (0, 1]; = 1 at CoV = 0, strictly decreasing in CoV.
    let sizingReliability: Double
    /// One-line plain read of the vol-stability regime.
    let note: String
    /// Standing honesty caveat (always non-empty).
    let caveat: String

    /// Categorical vol-of-vol regime.
    enum Band: Sendable, Equatable {
        /// CoV < 0.15 — rolling vol moves < 15% of its mean; stops and sizing are reliable.
        case steady
        /// CoV ∈ [0.15, 0.35) — rolling vol drifts meaningfully; size with some caution.
        case choppy
        /// CoV ≥ 0.35 — rolling vol swings > 35% of its mean; sizing inputs are unstable.
        case erratic
    }
}

enum StockSageVolStability {
    // Band thresholds (half-open intervals: [0,steadyMaxCoV) / [steadyMaxCoV,choppyMaxCoV) / [choppyMaxCoV,∞)).
    //
    // 0.15 (steady ceiling): a CoV of 15% means the monthly vol typically sits within
    // ±15% of its mean — stop widths and sizes set today stay roughly valid next bar.
    // Empirically, steady large-cap rolling-vol CoV sits ≈ 0.10–0.20.
    //
    // 0.35 (choppy→erratic): above ~⅓, monthly vol swings by > ⅓ of its mean —
    // stops set in one regime are materially miscalibrated in the next.
    // An alternating calm/violent series (vol ratio ≫ 1) drives CoV well above 0.35.
    //
    // These are conservative, justified defaults — no ML, no data fitting.
    private static let steadyMaxCoV: Double = 0.15
    private static let choppyMaxCoV: Double = 0.35

    nonisolated static let caveat =
        "This measures how STABLE the volatility inputs are (vol-of-vol), not whether the " +
        "trade is good — an erratic-vol name can still be a great setup; it just means your " +
        "ATR-stop width and position size are less trustworthy, so trade it smaller. It is a " +
        "backward-looking dispersion of the rolling realized-vol series, never a forecast of " +
        "future vol, and not an entry/exit signal."

    /// Rolling realized-vol stability read over a closes series.
    ///
    /// Builds a `historyWindow`-length series of rolling annualized vols, each from a
    /// trailing `volWindow`-bar close slice, then computes:
    ///   - CoV = populationStdev(series) / mean(series)  (population ÷N, describing THIS series)
    ///   - band ∈ {.steady, .choppy, .erratic} via CoV thresholds
    ///   - sizingReliability = 1/(1+CoV) ∈ (0,1]; = 1 at CoV=0, strictly decreasing
    ///
    /// Required bars: `closes.count ≥ volWindow + historyWindow` (defaults: ≥ 147).
    /// Returns nil when: insufficient bars, degenerate window (all-equal closes within
    /// any vol slice), or mean of the vol series ≤ 0.
    nonisolated static func volStability(
        closes: [Double],
        volWindow: Int = 21,
        historyWindow: Int = 126
    ) -> VolStability? {
        // Defensive: degenerate window parameters.
        guard volWindow >= 2, historyWindow >= 2 else { return nil }
        // Spec's nil guard: one bar more conservative than strict minimum for clean full-overlap.
        guard closes.count >= volWindow + historyWindow else { return nil }

        // Build the rolling-vol series: historyWindow points, each from a volWindow-bar close slice.
        // Anchors: i ∈ { closes.count - historyWindow, …, closes.count - 1 } (most-recent last).
        // Individual invalid windows are SKIPPED (matching VolRegime's approach) instead of
        // aborting the whole computation — a single flash-crash bar shouldn't hide the
        // stability read from the other ~125 clean bars.
        var series: [Double] = []
        series.reserveCapacity(historyWindow)
        let firstAnchor = closes.count - historyWindow
        for i in firstAnchor..<closes.count {
            let slice = Array(closes[(i - volWindow + 1)...i])
            guard let v = StockSageIndicators.annualizedVolatility(slice),
                  v.isFinite, v > 0 else { continue }
            series.append(v)
        }
        // Require at least 60% of the expected windows to have valid vol — otherwise the
        // remaining sample is too spotty for a meaningful CoV.
        guard series.count >= Swift.max(5, Int(Double(historyWindow) * 0.6)) else { return nil }

        let n = Double(series.count)
        let mean = series.reduce(0.0, +) / n
        // Population variance (÷N): we describe the dispersion of THIS observed vol series,
        // not estimating a parameter of a hypothetical superpopulation (same convention as
        // ReturnShape's skewness computation).
        let varP = series.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / n

        // Spec guard: mean ≤ 0 → CoV undefined (annualized vol is ≥ 0; mean > 0 if all v > 0
        // above, but guard explicitly for robustness).
        guard mean > 0 else { return nil }
        let cov = varP.squareRoot() / mean
        guard cov.isFinite else { return nil }

        // sizingReliability = 1/(1+CoV): = 1 at CoV=0, ∈ (0,1], f'(c) = -1/(1+c)² < 0 (strictly decreasing).
        let sizingReliability = 1.0 / (1.0 + cov)

        let band: VolStability.Band
        let note: String
        let covPct = cov * 100
        switch cov {
        case ..<steadyMaxCoV:
            band = .steady
            note = String(format: "Vol is steady (vol-of-vol CoV %.0f%%): ATR stops & sizing are reliable.", covPct)
        case ..<choppyMaxCoV:
            band = .choppy
            note = String(format: "Vol is choppy (vol-of-vol CoV %.0f%%): size with some caution — stop width drifts.", covPct)
        default:
            band = .erratic
            note = String(format: "Vol is erratic (vol-of-vol CoV %.0f%%): sizing inputs unstable — trade smaller.", covPct)
        }

        return VolStability(
            coeffOfVariation: cov,
            band: band,
            sizingReliability: sizingReliability,
            note: note,
            caveat: caveat
        )
    }
}
