import Foundation

// MARK: - Hypothetical compounding horizon (time-to-double)
//
// `expectedWeeklyR`/`expectedWeeklyDollars` give a weekly estimate, but neither answers the
// question an owner actually asks: "when am I 2x?" This converts a WEEKLY FRACTIONAL RETURN
// (e.g. weeklyDollars ÷ account, NOT the raw R-multiple `expectedWeeklyR` returns — an R
// figure has no % meaning without the risk-per-trade fraction) into a doubling time.
// HONESTY IS THE WHOLE POINT: every surface of this number must say HYPOTHETICAL, not a
// forecast — compounding an already-uncertain weekly estimate over months multiplies the
// uncertainty, and reality (slippage, partial fills, reversal losses, regime shifts) makes
// the real path slower and lumpier than a smooth compound curve. Pure + deterministic.

enum StockSageCompoundingHorizon {
    nonisolated static let caveat =
        "A HYPOTHETICAL scenario, not a forecast — actual is typically slower and riskier " +
        "(slippage, partial fills, reversal losses, regime shifts). Compounding an uncertain " +
        "weekly estimate over months multiplies its uncertainty; treat this as a rough " +
        "order-of-magnitude, not a plan."

    /// Weeks to compound at `weeklyReturn` (a FRACTIONAL weekly return — e.g. 0.01 = 1%/week,
    /// NOT a raw R-multiple) up to `target`× starting capital: solves
    /// `target = (1 + weeklyReturn)^weeks` for `weeks`, compounding once per week (the
    /// natural cadence of a weekly estimate). nil when there's nothing to project
    /// (weeklyReturn <= 0, or non-finite input); 0 when already at/past the target
    /// (target <= 1).
    nonisolated static func weeksToTarget(weeklyReturn: Double, target: Double = 2.0) -> Double? {
        guard weeklyReturn.isFinite, target.isFinite else { return nil }
        guard target > 1 else { return 0 }
        guard weeklyReturn > 0 else { return nil }
        let base = 1 + weeklyReturn
        guard base > 0 else { return nil }
        let weeks = log(target) / log(base)
        guard weeks.isFinite, weeks >= 0 else { return nil }
        return weeks
    }
}
