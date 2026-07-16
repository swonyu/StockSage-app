import Foundation

// MARK: - Leverage / margin honesty (none of what leverage changes is upside)
//
// Leverage multiplies your loss and your risk of ruin by the SAME factor it multiplies gains.
// This derives the three numbers it actually changes — the adverse move that wipes you, the
// liquidation price, and the drawdown multiplier — plus the non-negotiable "can lose more than
// the account" flag. Pure + deterministic. Pairs with StockSageGapRisk: a gap THROUGH the
// liquidation level loses even more. Never presents leverage as free upside.

struct LeverageRisk: Sendable, Equatable {
    let leverage: Double            // notional ÷ account (L×)
    let entry: Double
    let liquidationMovePct: Double  // % adverse move that wipes the posted equity = 100/L
    let liquidationPrice: Double    // long: entry·(1 − 1/L), 0 for cash; SHORT: entry·(1 + 1/L) — adverse is UP
    let drawdownMultiplier: Double  // every unleveraged loss scaled by L
    let canLoseMoreThanAccount: Bool
    let caveat: String
    nonisolated var verdict: String {
        if leverage <= 1 {
            return canLoseMoreThanAccount
                ? String(format: "%.1f×, but this instrument can lose MORE than the account (options/short/futures).", leverage)
                : String(format: "No leverage (%.1f×) — losses are 1×, and a long position can't be margin-liquidated.", leverage)
        }
        return String(format: "%.1f× — a %.1f%% adverse move wipes you (≈ %.2f); losses hit %.1f× as hard. Can lose MORE than the account.",
                      leverage, liquidationMovePct, liquidationPrice, drawdownMultiplier)
    }
}

enum StockSageLeverage {
    nonisolated static let caveat = "Leverage and options are NOT free upside: they multiply your loss and your risk of ruin by the same factor they multiply gains. At L× a 100/L% adverse move wipes the position, and a gap, funding or slippage THROUGH that level — or any options/futures position — can lose MORE than the entire account, leaving you owing money. Fees, funding and maintenance margin only move liquidation CLOSER."

    /// Leverage risk from an explicit multiple. nil on non-positive leverage/entry.
    /// `isShort` (default false, byte-identical for existing callers): a short's ADVERSE move is
    /// UP, so its liquidation price is entry·(1 + 1/L) — ABOVE entry. Displaying the long-side
    /// entry·(1 − 1/L) for a short would print a "wipe-out" price on the side where the short is
    /// in PROFIT. A short's loss is also unbounded, so canLoseMoreThanAccount is always true.
    nonisolated static func assess(leverage L: Double, entry: Double,
                                   instrumentCanLoseMoreThanAccount: Bool = false,
                                   isShort: Bool = false) -> LeverageRisk? {
        guard L > 0, entry > 0 else { return nil }
        return LeverageRisk(leverage: L, entry: entry,
                            liquidationMovePct: 100 / L,
                            liquidationPrice: isShort
                                ? entry * (1 + 1 / L)                       // short: wiped by an UP move
                                : Swift.max(0, entry * (1 - 1 / L)),        // long: ≤0 (cash) ⇒ no liquidation
                            drawdownMultiplier: L,
                            canLoseMoreThanAccount: L > 1 || isShort || instrumentCanLoseMoreThanAccount,
                            caveat: caveat)
    }

    /// Leverage from a real book: L = notional ÷ account (the same ratio PositionSizer.pctOfAccount
    /// produces). nil on non-positive account/notional/entry.
    nonisolated static func assess(account: Double, notional: Double, entry: Double,
                                   instrumentCanLoseMoreThanAccount: Bool = false,
                                   isShort: Bool = false) -> LeverageRisk? {
        guard account > 0, notional > 0 else { return nil }
        return assess(leverage: notional / account, entry: entry,
                      instrumentCanLoseMoreThanAccount: instrumentCanLoseMoreThanAccount,
                      isShort: isShort)
    }
}
