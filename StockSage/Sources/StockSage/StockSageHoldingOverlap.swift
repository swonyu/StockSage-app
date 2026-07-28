import Foundation

/// "You already own this bet" — overlap between a PROPOSED idea and the positions already held.
///
/// THE GAP THIS FILLS: StockSageCorrelationCluster de-weights correlated names *within one
/// proposed batch*, so a plan that funds three oil names at once is caught. Nothing checked a
/// proposed trade against the book already open. Adding a Tadawul petrochemical while already
/// holding a NASDAQ oil major is one bet wearing two tickers across two markets, and the 8% heat
/// cap counts it as two — exactly the concentration the cap exists to prevent.
///
/// WHY RETURN CORRELATION RATHER THAN SECTOR TAGS: an external review proposed matching on sector
/// labels. Correlation measures the thing sector tags are a proxy FOR, needs no per-symbol
/// taxonomy the app does not have, and catches pairs a taxonomy would miss (an airline and a
/// refiner are different sectors and opposite ends of the same oil trade). It also cannot invent
/// a relationship: too little shared history returns nil, and nil renders nothing.
enum StockSageHoldingOverlap {

    /// Correlation at or above which two names are treated as substantially the same exposure.
    /// Matches StockSageCorrelationCluster's own threshold so the two cannot disagree about what
    /// "correlated" means.
    nonisolated static let threshold = StockSageCorrelationCluster.threshold
    /// Minimum overlapping observations before a correlation is trustworthy at all.
    nonisolated static let minObservations = 20

    struct Overlap: Sendable, Equatable {
        let heldSymbol: String
        let correlation: Double
        /// True when the two sit in different markets — the case most likely to feel like
        /// diversification while being none.
        let crossMarket: Bool
    }

    /// Held names whose returns move with `candidate`, strongest first.
    ///
    /// `candidateReturns` and each entry of `heldReturns` are daily return series. Series shorter
    /// than `minObservations` after alignment are skipped rather than guessed at.
    nonisolated static func overlaps(candidate: String,
                                     candidateReturns: [Double],
                                     heldReturns: [String: [Double]],
                                     threshold: Double = threshold) -> [Overlap] {
        guard candidateReturns.count >= minObservations else { return [] }
        var out: [Overlap] = []
        for (held, series) in heldReturns {
            guard held.uppercased() != candidate.uppercased() else { continue }
            // Align on the most recent overlapping window — the series can differ in length
            // because histories start on different dates.
            let n = Swift.min(candidateReturns.count, series.count)
            guard n >= minObservations else { continue }
            let a = Array(candidateReturns.suffix(n))
            let b = Array(series.suffix(n))
            guard let r = StockSagePortfolioAnalytics.correlation(a, b), r >= threshold else { continue }
            out.append(Overlap(heldSymbol: held.uppercased(), correlation: r,
                               crossMarket: isCrossMarket(candidate, held)))
        }
        return out.sorted { $0.correlation > $1.correlation }
    }

    /// Tadawul names carry a .SR suffix; anything else in this universe is US-listed.
    nonisolated static func isCrossMarket(_ a: String, _ b: String) -> Bool {
        let aSaudi = a.uppercased().hasSuffix(".SR")
        let bSaudi = b.uppercased().hasSuffix(".SR")
        return aSaudi != bSaudi
    }

    /// One honest sentence for the UI, or nil when there is nothing to say.
    nonisolated static func warning(for overlaps: [Overlap]) -> String? {
        guard let top = overlaps.first else { return nil }
        let pct = Int((top.correlation * 100).rounded())
        let others = overlaps.count - 1
        let alsoText = others > 0 ? " (and \(others) other held name\(others == 1 ? "" : "s"))" : ""
        let crossText = top.crossMarket
            ? " Different markets, but the same bet — splitting it across exchanges does not diversify it."
            : ""
        return "You already hold \(top.heldSymbol), which has moved \(pct)% with this name\(alsoText)."
            + crossText
            + " Sizing both as independent positions understates your real concentration."
    }
}
