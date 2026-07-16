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
    }
    let verdict: Verdict
    let avgCorrelation: Double        // candidate vs each holding, averaged
    let comparedCount: Int            // holdings it could actually be compared to
    let mostCorrelatedSymbol: String?
    let mostCorrelation: Double

    nonisolated var isWarning: Bool { verdict == .concentrating }

    nonisolated var note: String {
        switch verdict {
        case .noHoldings:
            return "No current holdings to compare against — this check needs an existing book."
        case .diversifying:
            return String(format: "Diversifying — ~%.0f%% average correlation to your %d holding(s). Adds a genuinely different return stream.",
                          avgCorrelation * 100, comparedCount)
        case .neutral:
            return String(format: "Some overlap — ~%.0f%% average correlation to your %d holding(s)%@.",
                          avgCorrelation * 100, comparedCount, mostLike)
        case .concentrating:
            return String(format: "Concentrating — ~%.0f%% average correlation to your %d holding(s)%@. Adding it doubles down on risk you already carry.",
                          avgCorrelation * 100, comparedCount, mostLike)
        }
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
    nonisolated static func assess(candidate: [Double],
                                   holdings: [(symbol: String, returns: [Double])]) -> CorrelationPrecheck {
        var corrs: [(symbol: String, c: Double)] = []
        for h in holdings {
            let n = Swift.min(candidate.count, h.returns.count)
            guard n >= minOverlap else { continue }
            // A zero-variance holding's correlation is UNDEFINED (0/0), not an "uncorrelated" 0 —
            // excluded from the average rather than silently counted as diversifying.
            guard let c = StockSagePortfolioAnalytics.correlation(Array(candidate.suffix(n)), Array(h.returns.suffix(n))) else { continue }
            corrs.append((h.symbol, c))
        }
        guard !corrs.isEmpty else {
            return CorrelationPrecheck(verdict: .noHoldings, avgCorrelation: 0, comparedCount: 0,
                                       mostCorrelatedSymbol: nil, mostCorrelation: 0)
        }
        let avg = corrs.map(\.c).reduce(0, +) / Double(corrs.count)
        let most = corrs.max { $0.c < $1.c }!   // most POSITIVELY correlated = the concentration culprit
        let verdict: CorrelationPrecheck.Verdict =
            avg >= concentratingAt ? .concentrating :
            (avg <= diversifyingBelow ? .diversifying : .neutral)
        return CorrelationPrecheck(verdict: verdict, avgCorrelation: avg, comparedCount: corrs.count,
                                   mostCorrelatedSymbol: most.symbol, mostCorrelation: most.c)
    }
}
