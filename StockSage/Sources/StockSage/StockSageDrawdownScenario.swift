import Foundation

// MARK: - Drawdown survival (the "stay in the game" check)
//
// Velocity rewards taking more setups — but more setups means more losing streaks.
// This models the account going DOWN: k consecutive 1R stop-outs at a fixed risk
// fraction f shrink the account by (1 − f)^k. It is the deliberate counterweight to
// the money-velocity surfaces — "fastest" must never quietly mean "over-bet." Pure +
// deterministic. (Assumes 1R stop-outs; a loss bigger than the stop costs more.)

struct DrawdownScenario: Sendable, Equatable {
    let losses: Int                // consecutive 1R stop-outs modeled
    let fraction: Double           // risk per trade (e.g. 0.01 = 1%)
    let survivalMultiple: Double   // (1 − fraction)^losses

    /// Fraction of the account lost after the streak, scaled 0–1 (e.g. 0.049 = 4.9%
    /// down) — NOT already ×100, unlike the sibling `UnderwaterCurve.maxDrawdown`
    /// (StockSageDrawdown.swift), which IS a 0–100 percentage. Callers must multiply
    /// by 100 before displaying this as a percent (see MarketsView's two call sites).
    nonisolated var drawdownPct: Double { 1 - survivalMultiple }
    /// A streak that costs ≥20% of the account is "steep" — worth a survival warning.
    nonisolated var isSteep: Bool { drawdownPct >= 0.20 }
}

enum StockSageRiskOfRuin {
    /// Account multiple after `losses` consecutive 1R stop-outs at risk `fraction`.
    /// nil for a non-positive streak or a fraction outside (0, 1).
    nonisolated static func scenario(losses: Int, fraction: Double) -> DrawdownScenario? {
        guard losses >= 1, fraction > 0, fraction < 1 else { return nil }
        return DrawdownScenario(losses: losses, fraction: fraction,
                                survivalMultiple: pow(1 - fraction, Double(losses)))
    }
}
