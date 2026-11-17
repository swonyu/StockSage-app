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

    /// Held names whose returns move with `candidate`, strongest first, plus a count of holdings
    /// that could not be scored at all. Returns nil when NOTHING was scorable — the caller must be
    /// able to tell "checked, nothing overlaps" from "could not check", because only the first of
    /// those is reassuring.
    ///
    /// DATE-ALIGNED (2026-09-11), and the predecessor's failure is the whole reason this exists.
    /// `overlaps(candidate:candidateReturns:heldReturns:)` took UNDATED `[Double]` and paired the
    /// two series by `suffix(n)` — index from the end. Tadawul trades Sun–Thu and US markets
    /// Mon–Fri, so index N from the end is a DIFFERENT CALENDAR DAY in each series. The doc comment
    /// at the top of this file advertises catching exactly that pair ("a Tadawul petrochemical
    /// while already holding a NASDAQ oil major"), and positional pairing is the one thing that
    /// cannot. Worse, its only caller fed it `idea.spark` — a down-sampled board sparkline with no
    /// dates at all — and rendered the result as a hard warning naming a specific percentage.
    ///
    /// Honesty contract, matching `StockSageClusterCheck.checkDated`: fewer than `minObservations`
    /// COMMON days, or an undefined (zero-variance) pair, is UNKNOWN — tallied in `skipped`, never
    /// scored. A holding that IS scored and simply sits below `threshold` is a real negative
    /// result and is not counted as skipped.
    nonisolated static func overlapsDated(candidate: String,
                                          candidateReturns: [(date: Date, ret: Double)],
                                          held: [(symbol: String, returns: [(date: Date, ret: Double)])],
                                          threshold: Double = threshold)
        -> (overlaps: [Overlap], skipped: Int)? {
        let others = held.filter { $0.symbol.uppercased() != candidate.uppercased() }
        guard !others.isEmpty, candidateReturns.count >= minObservations else { return nil }
        var out: [Overlap] = []
        var skipped = 0
        for h in others {
            let aligned = StockSagePortfolioAnalytics.alignByDate([candidateReturns, h.returns])
            guard aligned.count == 2, aligned[0].count >= minObservations,
                  let r = StockSagePortfolioAnalytics.correlation(aligned[0], aligned[1]) else {
                skipped += 1
                continue
            }
            guard r >= threshold else { continue }   // scored and cleared — a real answer, not a gap
            out.append(Overlap(heldSymbol: h.symbol.uppercased(), correlation: r,
                               crossMarket: isCrossMarket(candidate, h.symbol)))
        }
        guard skipped < others.count else { return nil }   // nothing scorable ⇒ no claim either way
        return (out.sorted { $0.correlation > $1.correlation }, skipped)
    }

    /// Tadawul names carry a .SR suffix; anything else in this universe is US-listed.
    nonisolated static func isCrossMarket(_ a: String, _ b: String) -> Bool {
        let aSaudi = a.uppercased().hasSuffix(".SR")
        let bSaudi = b.uppercased().hasSuffix(".SR")
        return aSaudi != bSaudi
    }

    /// One honest sentence for the UI, or nil when there is nothing to say.
    ///
    /// `skipped` is holdings that could not be scored. This warning is BAD news, so an unchecked
    /// holding can only mean there may be more of it — the sentence says so rather than letting
    /// "you already hold X" read as the complete list.
    nonisolated static func warning(for overlaps: [Overlap], skipped: Int = 0) -> String? {
        guard let top = overlaps.first else { return nil }
        let pct = Int((top.correlation * 100).rounded())
        let others = overlaps.count - 1
        let alsoText = others > 0 ? " (and \(others) other held name\(others == 1 ? "" : "s"))" : ""
        let crossText = top.crossMarket
            ? " Different markets, but the same bet — splitting it across exchanges does not diversify it."
            : ""
        let skippedText = skipped > 0
            ? " \(skipped) other holding\(skipped == 1 ? "" : "s") could not be checked (too few shared trading days)."
            : ""
        return "You already hold \(top.heldSymbol), which has moved \(pct)% with this name\(alsoText)."
            + crossText
            + " Sizing both as independent positions understates your real concentration."
            + skippedText
    }
}
