import Foundation

// MARK: - Correlation-cluster add pre-check
//
// "Diversification" that adds a name moving in lockstep with one you already hold isn't
// diversification — it's doubling the same bet. Before adding a candidate, this measures
// its return correlation to each current holding and flags any that are ≥ a threshold
// (default 0.8): you'd be concentrating, not spreading. Pure + deterministic. Honest:
// correlation is BACKWARD-looking and rises toward 1 in crashes — exactly when it hurts.

struct ClusterMatch: Sendable, Equatable, Identifiable {
    let symbol: String
    let correlation: Double   // −1…1
    var id: String { symbol }
}

struct ClusterCheck: Sendable, Equatable {
    let candidate: String
    let nearest: ClusterMatch?              // most positively-correlated holding
    let highlyCorrelated: [ClusterMatch]    // holdings ≥ threshold, highest first
    let threshold: Double

    nonisolated var isConcentrating: Bool { !highlyCorrelated.isEmpty }

    nonisolated var note: String {
        guard let top = highlyCorrelated.first ?? nearest else { return "" }
        let c = String(format: "%.2f", top.correlation)
        if isConcentrating {
            return "Adding \(candidate) ≈ doubling down on \(top.symbol) (corr \(c)) — concentration in disguise; correlated names fall together. Correlation is backward-looking and rises in crashes."
        }
        return "\(candidate)'s closest holding is \(top.symbol) (corr \(c)) — adds diversification. Correlation is backward-looking and regime-dependent."
    }
}

enum StockSageClusterCheck {
    /// Correlate `candidateReturns` against each holding's return series; flag any ≥ `threshold`.
    /// nil when there's nothing to compare (no candidate data, or no holdings). The same symbol
    /// already held is skipped (you can't cluster with yourself).
    nonisolated static func check(candidate: String, candidateReturns: [Double],
                                  holdings: [(symbol: String, returns: [Double])],
                                  threshold: Double = 0.8) -> ClusterCheck? {
        guard candidateReturns.count >= 2 else { return nil }
        let others = holdings.filter { $0.symbol.uppercased() != candidate.uppercased() && $0.returns.count >= 2 }
        guard !others.isEmpty else { return nil }

        // A zero-variance holding (flat/halted/newly-listed/illiquid) has an UNDEFINED
        // correlation with the candidate (0/0), not an "uncorrelated" 0 — excluded here via
        // compactMap rather than let through as a fake diversifying match.
        let matches = others.compactMap { h -> ClusterMatch? in
            StockSagePortfolioAnalytics.correlation(candidateReturns, h.returns).map {
                ClusterMatch(symbol: h.symbol, correlation: $0)
            }
        }
        let nearest = matches.max { $0.correlation < $1.correlation }
        let hot = matches.filter { $0.correlation >= threshold }.sorted { $0.correlation > $1.correlation }
        return ClusterCheck(candidate: candidate, nearest: nearest, highlyCorrelated: hot, threshold: threshold)
    }

    /// Date-aligned variant (F14 2026-07-02): correlates the candidate against each holding on
    /// their COMMON calendar days (UTC-day intersection via `StockSagePortfolioAnalytics
    /// .alignByDate`) instead of positionally. Positional pairing of series from different
    /// calendars (Tadawul/US, 24/7 crypto vs 5-day equity) compares returns from DIFFERENT days,
    /// biasing the coefficient toward 0 — a false-green "adds diversification".
    ///
    /// Honesty contract: a pair with fewer than `minOverlap` common days is UNKNOWN — it is
    /// skipped (tallied in `skipped`), never scored on a fabricated coefficient; a zero-variance
    /// aligned pair (undefined correlation) is likewise skipped. If NO pair is scorable the whole
    /// check is nil (unknown — callers show nothing, not a verdict). Same-symbol skip and
    /// threshold semantics match `check` exactly. The positional `check` remains for callers
    /// whose series are already index-aligned (allocator gates).
    nonisolated static func checkDated(candidate: String,
                                       candidateReturns: [(date: Date, ret: Double)],
                                       holdings: [(symbol: String, returns: [(date: Date, ret: Double)])],
                                       threshold: Double = 0.8,
                                       minOverlap: Int = 5) -> (check: ClusterCheck, skipped: Int)? {
        guard candidateReturns.count >= Swift.max(2, minOverlap) else { return nil }
        let others = holdings.filter { $0.symbol.uppercased() != candidate.uppercased() }
        guard !others.isEmpty else { return nil }

        var skipped = 0
        var matches: [ClusterMatch] = []
        for h in others {
            let aligned = StockSagePortfolioAnalytics.alignByDate([candidateReturns, h.returns])
            guard aligned.count == 2, aligned[0].count >= minOverlap,
                  let corr = StockSagePortfolioAnalytics.correlation(aligned[0], aligned[1]) else {
                skipped += 1   // <minOverlap common days or undefined (zero-variance) → unknown, never 0
                continue
            }
            matches.append(ClusterMatch(symbol: h.symbol, correlation: corr))
        }
        guard !matches.isEmpty else { return nil }   // nothing scorable → unknown, no verdict
        let nearest = matches.max { $0.correlation < $1.correlation }
        let hot = matches.filter { $0.correlation >= threshold }.sorted { $0.correlation > $1.correlation }
        return (check: ClusterCheck(candidate: candidate, nearest: nearest,
                                    highlyCorrelated: hot, threshold: threshold),
                skipped: skipped)
    }
}
