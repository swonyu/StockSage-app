import Foundation

// MARK: - Pre-trade gate ("should I take this trade?")
//
// A single disciplined go/no-go verdict that composes the rules the owner already
// has into one answer BEFORE entering: is risk defined (a stop)? is it within the
// cap? is the reward skew acceptable? is there an earnings gap or a correlated-book
// concentration? It BLOCKS undefined-risk / over-sized trades, CAUTIONS on poor
// skew / event risk, and otherwise clears. Pure + deterministic.
//
// Honesty: a discipline checklist, NOT a profit signal — passing the gate does not
// mean the trade wins; it means it isn't obviously reckless. Risk control > signal.

struct TradeGateCheck: Sendable, Equatable {
    enum Level: String, Sendable { case pass, warn, fail }
    let level: Level
    let label: String
}

struct TradeGateVerdict: Sendable, Equatable {
    enum Decision: String, Sendable {
        case clear   = "Clear to trade"
        case caution = "Proceed with caution"
        case blocked = "Don't take this trade"
    }
    let decision: Decision
    let checks: [TradeGateCheck]
    nonisolated var caveat: String {
        "A discipline checklist, not a profit signal — clearing it means the trade isn't obviously reckless, not that it wins. Risk control > signal."
    }
    nonisolated var passes: Int { checks.filter { $0.level == .pass }.count }
    nonisolated var warns: Int { checks.filter { $0.level == .warn }.count }
    nonisolated var fails: Int { checks.filter { $0.level == .fail }.count }
}

enum StockSageTradeGate {
    /// Evaluate a proposed trade. Inputs are already-computed primitives so the gate is
    /// a pure decision over them (the caller supplies risk %, R:R, correlation, earnings).
    /// `rewardToRisk`/`maxCorrelation`/`daysToEarnings` are nil when unknown/not applicable.
    /// `rrIsNet` is display-only: when true the R:R check label reads "Net reward:risk
    /// (after est. costs)" instead of "Reward:risk". Default false → byte-identical verdict
    /// and decision for all existing callers. Pass true ONLY when rewardToRisk is already
    /// a net-of-costs figure (i.e. StockSageNetEdge.netRR resolved non-nil — NOT the `?? gross`
    /// fallback, which must stay labeled gross to avoid mislabeling).
    nonisolated static func evaluate(hasStop: Bool,
                                     rewardToRisk: Double?,
                                     riskFraction: Double,
                                     maxRiskFraction: Double = 0.02,
                                     maxCorrelation: Double? = nil,
                                     daysToEarnings: Int? = nil,
                                     rrIsNet: Bool = false) -> TradeGateVerdict {
        var checks: [TradeGateCheck] = []
        let rrPrefix = rrIsNet ? "Net reward:risk (after est. costs)" : "Reward:risk"

        // 1. A defined stop — without it, risk is undefined and sizing is meaningless.
        checks.append(hasStop
            ? TradeGateCheck(level: .pass, label: "Stop defined — risk is bounded")
            : TradeGateCheck(level: .fail, label: "No stop — risk is UNDEFINED; set one before entering"))

        // 2. Risk within the per-trade cap.
        if riskFraction <= 0 {
            checks.append(TradeGateCheck(level: .fail, label: "Risk fraction must be positive"))
        } else if riskFraction <= maxRiskFraction {
            checks.append(TradeGateCheck(level: .pass, label: String(format: "Risk %.1f%% within the %.1f%% cap", riskFraction * 100, maxRiskFraction * 100)))
        } else {
            checks.append(TradeGateCheck(level: .fail, label: String(format: "Risk %.1f%% EXCEEDS the %.1f%% cap — size down", riskFraction * 100, maxRiskFraction * 100)))
        }

        // 3. Reward:risk skew.
        if let rr = rewardToRisk {
            if rr >= 2 { checks.append(TradeGateCheck(level: .pass, label: String(format: "%@ %.1f:1 — positive skew", rrPrefix, rr))) }
            else if rr >= 1 { checks.append(TradeGateCheck(level: .warn, label: String(format: "%@ %.1f:1 — thin; below 2:1", rrPrefix, rr))) }
            // rr can arrive NET of costs, so a negative value means costs exceed the reward — say
            // that, rather than blaming the target (which may sit well above 1R on the gross plan).
            else if rr >= 0 { checks.append(TradeGateCheck(level: .fail, label: String(format: "%@ %.1f:1 — sub-1R; reward below the risk", rrPrefix, rr))) }
            else { checks.append(TradeGateCheck(level: .fail, label: String(format: "%@ %.1f:1 — costs exceed the reward (net-negative)", rrPrefix, rr))) }
        } else {
            checks.append(TradeGateCheck(level: .warn, label: "No target set — define one to judge skew"))
        }

        // 4. Correlation with the existing book (concentration).
        // F36: add a moderate band (0.5–<0.8) so a 0.79 correlation is not mislabeled "Low".
        // Gate LEVEL is unchanged — only the check's label text is split into three honest bands.
        if let c = maxCorrelation, c >= 0.8 {
            checks.append(TradeGateCheck(level: .warn, label: String(format: "Highly correlated (%.2f) with a holding — sizes as one bet, not two", c)))
        } else if let c = maxCorrelation, c >= 0.5 {
            checks.append(TradeGateCheck(level: .pass, label: String(format: "Moderate correlation %.2f — partial overlap with your book", c)))
        } else if let c = maxCorrelation {
            checks.append(TradeGateCheck(level: .pass, label: String(format: "Low correlation (%.2f) with the book — adds diversification", c)))
        }

        // 5. Earnings-gap proximity.
        if let d = daysToEarnings, d >= 0, d <= 3 {
            checks.append(TradeGateCheck(level: .warn, label: "Earnings in \(d) day\(d == 1 ? "" : "s") — overnight gap risk through the stop"))
        }

        let decision: TradeGateVerdict.Decision =
            checks.contains { $0.level == .fail } ? .blocked
            : (checks.contains { $0.level == .warn } ? .caution : .clear)
        return TradeGateVerdict(decision: decision, checks: checks)
    }
}
