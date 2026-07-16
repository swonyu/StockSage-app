import Foundation

// MARK: - Gap risk: a stop is a TRIGGER, not a guaranteed fill
//
// Every sizing/risk engine here assumes a stop fills AT its level. Reality: overnight,
// weekend, earnings and 24/7-crypto gaps can open far THROUGH the stop, so you exit at the
// gap price and the realized loss EXCEEDS the planned 1R — with leverage/options it can
// exceed the entire account. This is the only forward-looking quantifier of that truth
// (the backtester only models adverse gaps backward, in simulateExit). Pure + deterministic.
// `gapPct` is a what-if the caller supplies, never a forecast.

enum TradeSide: Sendable, Equatable { case long, short }

struct GapRiskScenario: Sendable, Equatable {
    let side: TradeSide
    let gapPct: Double
    let entry, stop, gapFillPrice, riskPerShare, lossPerShare, shares: Double
    let plannedRiskDollars, dollarsLost, beyondPlanDollars, rMultiple: Double
    let accountEquity, accountLossPct: Double
    nonisolated var blowsThroughStop: Bool { gapPct > 0 }
    /// True when this single gap fill loses MORE than the whole account. NEVER clamped to 100%.
    nonisolated var exceedsAccount: Bool { accountLossPct > 1.0 }
    nonisolated var caveat: String { StockSageGapRisk.caveat }
    nonisolated var verdict: String {
        let pct = Int((accountLossPct * 100).rounded())
        if exceedsAccount {
            return String(format: "A %.0f%% gap through your stop ≈ %.1fR (~%d%% of the account — MORE than you have; you could owe the broker).", gapPct * 100, rMultiple, pct)
        }
        return String(format: "A %.0f%% gap through your stop ≈ %.1fR (~%d%% of the account) — worse than the planned −1R.", gapPct * 100, rMultiple, pct)
    }
}

enum StockSageGapRisk {
    nonisolated static let caveat = "A stop is a trigger, not a guaranteed fill. Overnight, weekend, earnings and 24/7-crypto gaps can open far THROUGH your stop — you exit at the gap price, not the stop, so the loss exceeds the planned 1R. With leverage or options the loss can be MORE than your entire account (you can owe the broker). This models ONE clean gap fill; a thin or halted book or a cascading liquidation can be worse still. Never a maximum, never a probability, never advice."

    /// The realized loss if price gaps `gapPct` THROUGH the stop (a long gaps below, a short
    /// above). rMultiple is always > 1 when gapPct > 0 — that's the point. `shares` is the ACTUAL
    /// position (a leveraged book already holds more shares, so leverage needs no separate knob —
    /// the loss vs equity falls out of dollarsLost / accountEquity, and a big gap alone can exceed
    /// the account). nil on degenerate inputs (entry==stop, non-positive shares/equity/prices, negative gap).
    nonisolated static func scenario(side: TradeSide, entry: Double, stop: Double, shares: Double,
                                     gapPct: Double, accountEquity: Double) -> GapRiskScenario? {
        let riskPerShare = abs(entry - stop)
        guard riskPerShare > 0, shares > 0, accountEquity > 0, gapPct >= 0, entry > 0, stop > 0 else { return nil }
        switch side {
        case .long:  guard stop < entry else { return nil }   // a long's stop sits BELOW entry
        case .short: guard stop > entry else { return nil }   // a short's stop sits ABOVE entry
        }
        let gapFill: Double, lossPerShare: Double
        switch side {
        // #10: a gap of ≥100% cannot fill below $0 — clamp the long fill at zero (a total
        // wipeout of the position, the honest physical maximum), never a negative price.
        // Shorts have no analogous ceiling (loss above entry is unbounded — deliberately unclamped).
        case .long:  gapFill = Swift.max(0, stop * (1 - gapPct)); lossPerShare = entry - gapFill   // gaps below the stop
        case .short: gapFill = stop * (1 + gapPct); lossPerShare = gapFill - entry    // gaps above the stop
        }
        let dollarsLost = shares * lossPerShare
        let planned = shares * riskPerShare
        return GapRiskScenario(side: side, gapPct: gapPct, entry: entry, stop: stop,
                               gapFillPrice: gapFill, riskPerShare: riskPerShare, lossPerShare: lossPerShare,
                               shares: shares, plannedRiskDollars: planned, dollarsLost: dollarsLost,
                               beyondPlanDollars: dollarsLost - planned, rMultiple: lossPerShare / riskPerShare,
                               accountEquity: accountEquity, accountLossPct: dollarsLost / accountEquity)
    }

    /// A ladder of canonical adverse gaps (weekend 5%, earnings 8%, crypto-flash 20%,
    /// halt-reopen 35% by default), each a separate scenario — the "a stop is not a fill" table.
    /// Magnitudes are illustrative, NOT predicted probabilities. #7: `gaps` is SORTED ascending
    /// before mapping, so the documented ascending-in-loss ladder holds for ANY caller order
    /// (loss is monotonic in gapPct; non-strictly once a long gap ≥ 100% plateaus at the $0 fill).
    nonisolated static func worstCase(side: TradeSide, entry: Double, stop: Double, shares: Double,
                                      accountEquity: Double,
                                      gaps: [Double] = [0.05, 0.08, 0.20, 0.35]) -> [GapRiskScenario] {
        gaps.sorted().compactMap { scenario(side: side, entry: entry, stop: stop, shares: shares, gapPct: $0,
                                            accountEquity: accountEquity) }
    }

    /// Bridge from a sized position. `PositionSize` carries no side — pass it explicitly.
    nonisolated static func fromPosition(_ ps: PositionSize, side: TradeSide, stop: Double, entry: Double,
                                         accountEquity: Double, gapPct: Double) -> GapRiskScenario? {
        scenario(side: side, entry: entry, stop: stop, shares: Double(ps.shares), gapPct: gapPct,
                 accountEquity: accountEquity)
    }
}
