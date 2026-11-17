import Foundation

// MARK: - Portfolio-correlation pre-check
//
// "More tickers" is not "more diversified." Before you add a name, the question
// that matters is: does it move WITH what you already own? This computes the
// candidate's average daily-return correlation to each current holding and
// classifies the effect — diversifying (a genuinely different stream), neutral,
// or concentrating (doubling down on risk you already carry). Pure + tested.

struct CorrelationPrecheck: Sendable, Equatable {
    enum Verdict: String, Sendable {
        case noHoldings    = "No holdings yet"
        case diversifying  = "Diversifying"
        case neutral       = "Some overlap"
        case concentrating = "Concentrating"
        /// Holdings exist, but none could be scored — too few COMMON trading days, or a
        /// zero-variance series. Added 2026-09-11: this was previously collapsed into
        /// `.noHoldings`, so "we could not compare your book" displayed as "you have no book".
        /// Those are different facts and the second one is a false statement about the owner.
        case notComparable = "Couldn't compare your holdings"
    }
    let verdict: Verdict
    let avgCorrelation: Double        // candidate vs each holding, averaged
    let comparedCount: Int            // holdings it could actually be compared to
    let mostCorrelatedSymbol: String?
    let mostCorrelation: Double
    /// Holdings present but unscorable. Non-zero alongside a real verdict means the average is
    /// over FEWER holdings than the owner has — the row says so rather than implying full cover.
    let skippedCount: Int

    /// Explicit rather than memberwise so `skippedCount` can default and existing construction
    /// sites keep compiling.
    nonisolated init(verdict: Verdict, avgCorrelation: Double, comparedCount: Int,
                     mostCorrelatedSymbol: String?, mostCorrelation: Double, skippedCount: Int = 0) {
        self.verdict = verdict
        self.avgCorrelation = avgCorrelation
        self.comparedCount = comparedCount
        self.mostCorrelatedSymbol = mostCorrelatedSymbol
        self.mostCorrelation = mostCorrelation
        self.skippedCount = skippedCount
    }

    nonisolated var isWarning: Bool { verdict == .concentrating }

    nonisolated var note: String {
        switch verdict {
        case .noHoldings:
            return "No current holdings to compare against — this check needs an existing book."
        case .notComparable:
            return skippedCount == 1
                ? "Couldn't compare — your 1 holding shares too few trading days with this name to measure overlap. No verdict rather than a guess."
                : "Couldn't compare — your \(skippedCount) holdings share too few trading days with this name to measure overlap. No verdict rather than a guess."
        case .diversifying:
            return String(format: "Diversifying — ~%.0f%% average correlation to your %d holding(s). Adds a genuinely different return stream.%@",
                          avgCorrelation * 100, comparedCount, coverageCaveat)
        case .neutral:
            return String(format: "Some overlap — ~%.0f%% average correlation to your %d holding(s)%@.%@",
                          avgCorrelation * 100, comparedCount, mostLike, coverageCaveat)
        case .concentrating:
            return String(format: "Concentrating — ~%.0f%% average correlation to your %d holding(s)%@. Adding it doubles down on risk you already carry.%@",
                          avgCorrelation * 100, comparedCount, mostLike, coverageCaveat)
        }
    }

    /// "your 3 holdings" reads as the WHOLE book. When some were unscorable it is not, and the
    /// missing ones are exactly the cross-calendar names most likely to be scored wrong — so the
    /// sentence says what it did not cover instead of quietly averaging over a subset.
    private nonisolated var coverageCaveat: String {
        guard skippedCount > 0 else { return "" }
        return " \(skippedCount) more couldn't be compared (too few shared trading days), so this doesn't cover your whole book."
    }

    private nonisolated var mostLike: String {
        guard let s = mostCorrelatedSymbol, mostCorrelation >= 0.5 else { return "" }
        return String(format: " (most like %@, %.0f%%)", s, mostCorrelation * 100)
    }
}

enum StockSageCorrelationPrecheck {
    // Daily-return correlation bands (typical for equities; FX/crypto run lower).
    nonisolated static let concentratingAt = 0.60
    nonisolated static let diversifyingBelow = 0.30
    private nonisolated static let minOverlap = 5

    /// Classify how adding `candidate` (its daily returns) would affect a book made
    /// of `holdings` (each a symbol + its daily returns). Aligns each pair to the
    /// shorter tail; holdings with too little overlap are skipped.
    /// Date-aligned assessment. USE THIS for anything the owner reads.
    ///
    /// `assess` below pairs two return series by POSITION from the end. Tadawul trades Sunday to
    /// Thursday and US markets Monday to Friday, so position N from the end is a different
    /// CALENDAR DAY in each series: the coefficient is computed across mismatched days and means
    /// nothing. A genuinely concentrated pair could therefore read "Diversifying" on the idea
    /// sheet — a false green on the exact question the row exists to answer.
    ///
    /// Honesty contract, matching `StockSageClusterCheck.checkDated`: a pair with fewer than
    /// `minOverlap` COMMON days is unknown — skipped and tallied, never scored on a fabricated
    /// coefficient. A zero-variance aligned pair is likewise skipped (0/0 is undefined, not
    /// "uncorrelated"). Holdings that exist but cannot be scored yield `.notComparable`, never
    /// `.noHoldings`.
    nonisolated static func assessDated(candidate: [(date: Date, ret: Double)],
                                        holdings: [(symbol: String, returns: [(date: Date, ret: Double)])],
                                        minOverlap: Int = 5) -> CorrelationPrecheck {
        func empty(_ verdict: CorrelationPrecheck.Verdict, skipped: Int) -> CorrelationPrecheck {
            CorrelationPrecheck(verdict: verdict, avgCorrelation: 0, comparedCount: 0,
                                mostCorrelatedSymbol: nil, mostCorrelation: 0, skippedCount: skipped)
        }
        guard !holdings.isEmpty else { return empty(.noHoldings, skipped: 0) }
        var corrs: [(symbol: String, c: Double)] = []
        var skipped = 0
        for h in holdings {
            let aligned = StockSagePortfolioAnalytics.alignByDate([candidate, h.returns])
            guard aligned.count == 2, aligned[0].count >= minOverlap,
                  let c = StockSagePortfolioAnalytics.correlation(aligned[0], aligned[1]) else {
                skipped += 1
                continue
            }
            corrs.append((h.symbol, c))
        }
        guard !corrs.isEmpty else { return empty(.notComparable, skipped: skipped) }
        let avg = corrs.map(\.c).reduce(0, +) / Double(corrs.count)
        let most = corrs.max { $0.c < $1.c }!
        let verdict: CorrelationPrecheck.Verdict =
            avg >= concentratingAt ? .concentrating :
            (avg <= diversifyingBelow ? .diversifying : .neutral)
        return CorrelationPrecheck(verdict: verdict, avgCorrelation: avg, comparedCount: corrs.count,
                                   mostCorrelatedSymbol: most.symbol, mostCorrelation: most.c,
                                   skippedCount: skipped)
    }

}
