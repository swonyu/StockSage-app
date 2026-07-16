import Foundation

// MARK: - Portfolio heat (total open risk vs equity)
//
// Each trade sized at "1% risk" feels safe in isolation, but ten of them open at once is
// 10% of the account on the line — exposure a single bad day (or a correlated gap) hits
// all at once, and nothing else in the app surfaces it. Heat = Σ (shares · |entry−stop|)
// ÷ account: the fraction of equity you'd lose if every open stop filled. Pure +
// deterministic. Honest: assumes each stop fills AT its level — a gap can lose more.

struct PortfolioHeat: Sendable, Equatable {
    let dollarsAtRisk: Double   // Σ open risk in account currency
    let accountSize: Double
    let openCount: Int
    nonisolated var heatPct: Double { accountSize > 0 ? dollarsAtRisk / accountSize : 0 }

    enum Level: String, Sendable { case cool, warm, hot }
    /// <5% cool, <10% warm, ≥10% hot.
    nonisolated var level: Level { heatPct < 0.05 ? .cool : (heatPct < 0.10 ? .warm : .hot) }

    nonisolated var verdict: String {
        let p = Int((heatPct * 100).rounded())
        switch level {
        case .cool: return "\(p)% of account at open risk — room to add."
        case .warm: return "\(p)% of account at open risk — getting full; add carefully."
        case .hot:  return "\(p)% of account at open risk — heavy; one bad day hits hard, consider trimming."
        }
    }
    nonisolated var caveat: String {
        "Assumes each stop fills AT its level; a correlated gap can hit several at once for more than this."
    }
}

enum StockSagePortfolioHeat {
    /// Total open risk ÷ account. Each tuple is one OPEN trade (shares, entry, stop).
    /// nil only when there's no account to measure against; zero open trades → 0% heat.
    nonisolated static func compute(openTrades: [(shares: Double, entry: Double, stop: Double)],
                                    accountSize: Double) -> PortfolioHeat? {
        guard accountSize > 0 else { return nil }
        // Non-finite legs (e.g. a fat-fingered "inf" typed into the journal form) are excluded
        // from the risk sum rather than trusted — otherwise `verdict`'s Int(heatPct * 100) traps
        // on a non-finite heatPct, crashing every future render of this screen.
        let atRisk = openTrades.reduce(0.0) { sum, t in
            guard t.shares.isFinite, t.entry.isFinite, t.stop.isFinite else { return sum }
            return sum + Swift.max(0, t.shares) * abs(t.entry - t.stop)
        }
        return PortfolioHeat(dollarsAtRisk: atRisk, accountSize: accountSize, openCount: openTrades.count)
    }
}
