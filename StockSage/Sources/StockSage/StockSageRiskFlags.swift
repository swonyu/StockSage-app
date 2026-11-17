import Foundation

// MARK: - Consolidated risk flags
//
// Every risk signal in the app lives on its own row deep in the detail sheet —
// easy to scroll past the one that matters. This aggregates the already-computed
// signals into a single chip row shown FIRST, so the reasons NOT to take a trade
// are seen before the reasons to take it. Pure aggregation of existing state — no
// new judgement, no new fetch. Tested.

struct RiskFlag: Sendable, Equatable, Identifiable {
    enum Level: Int, Sendable { case info = 0, caution = 1, high = 2 }
    let label: String
    let level: Level
    var id: String { label }
}

enum StockSageRiskFlags {
    /// Active risk flags for an idea, from signals already computed elsewhere.
    /// Sorted most-severe first.
    nonisolated static func flags(action: TradeAdvice.Action,
                                  conviction: Double,
                                  symbol: String,
                                  earnings: EarningsProximity?,
                                  precheck: CorrelationPrecheck?,
                                  regimeIsStale: Bool,
                                  hasRegime: Bool,
                                  liquidityTier: LiquidityProfile.Tier? = nil) -> [RiskFlag] {
        var out: [RiskFlag] = []

        if liquidityTier == .thin {
            out.append(RiskFlag(label: "Thin liquidity", level: .caution))
        }

        if let e = earnings {
            if e.severity == .imminent { out.append(RiskFlag(label: "Earnings ≤3d", level: .high)) }
            else if e.severity == .soon { out.append(RiskFlag(label: "Earnings soon", level: .caution)) }
        }
        if precheck?.verdict == .concentrating {
            out.append(RiskFlag(label: "Concentrating", level: .high))
        }
        if hasRegime && regimeIsStale {
            out.append(RiskFlag(label: "Stale regime", level: .caution))
        }
        // Only meaningful for an actual entry — Avoid/Hold already say "stand aside",
        // so flagging low conviction there is redundant double-counting.
        if (action == .buy || action == .strongBuy), conviction < 0.40 {
            out.append(RiskFlag(label: "Low conviction", level: .caution))
        }
        if action == .avoid {
            out.append(RiskFlag(label: "No edge (choppy)", level: .caution))
        }
        switch StockSageAllocation.assetClass(symbol) {
        case "Crypto": out.append(RiskFlag(label: "Crypto vol 24/7", level: .caution))
        case "Forex":  out.append(RiskFlag(label: "FX leverage", level: .info))
        default: break
        }

        return out.sorted { $0.level.rawValue > $1.level.rawValue }
    }
}
