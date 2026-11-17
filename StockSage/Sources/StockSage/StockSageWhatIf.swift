import Foundation

// MARK: - "What if I add this" portfolio impact
//
// Concentration creeps in one reasonable-looking trade at a time. This projects
// what the book's asset-class mix becomes if you add a candidate at a proposed
// size — BEFORE you click buy — and flags when that pushes you across the >60%
// "concentrated" line. Pure (reuses StockSageAllocation). A projection of the mix,
// not a prediction of returns.

struct WhatIfImpact: Sendable, Equatable {
    let candidateClass: String
    let beforeTopClass: String
    let beforeTopFraction: Double
    let afterTopClass: String
    let afterTopFraction: Double
    /// True only when adding the candidate NEWLY crosses 60% (wasn't already over).
    let crossesConcentration: Bool

    nonisolated var isWarning: Bool { crossesConcentration }

    nonisolated var note: String {
        guard let after = StockSageAllocation.percentage(afterTopFraction),
              let before = StockSageAllocation.percentage(beforeTopFraction) else {
            return "Concentration is unavailable because the portfolio values cannot be represented."
        }
        guard afterTopFraction > 0 else { return "No positive holding value is available for a concentration comparison." }
        if crossesConcentration {
            return "Adding this pushes \(afterTopClass) to ~\(after)% of the book — crossing into CONCENTRATED (>60%). Size smaller or pick a different class."
        }
        // beforeTopFraction belongs to beforeTopClass, NOT afterTopClass — these can be
        // different asset classes when the top flips. Only phrase it as "raises X (from Y%)"
        // when it's the SAME class before and after; otherwise report both distinct leaders
        // so the percentages line up with the class names they actually describe.
        if afterTopClass != beforeTopClass {
            return "Top class shifts from \(beforeTopClass) (~\(before)%) to \(afterTopClass) (~\(after)%)."
                + (afterTopFraction > StockSageWhatIf.concentratedAbove ? " The resulting book remains concentrated." : "")
        }
        if afterTopFraction > StockSageWhatIf.concentratedAbove {
            return "The book remains concentrated: \(afterTopClass) ~\(after)% (previously ~\(before)%)."
        }
        if afterTopFraction > beforeTopFraction + 0.005 {
            return "Adding this raises \(afterTopClass) to ~\(after)% of the book (from ~\(before)%)."
        }
        return "After adding this, the top class is \(afterTopClass) at ~\(after)%."
    }
}

enum StockSageWhatIf {
    nonisolated static let concentratedAbove = 0.60

    /// The CASH actually deployable as a new holding. The sizer's notional is a
    /// leveraged EXPOSURE figure (a tight stop can make it many× the account), not
    /// cash to add to the book — so cap it at the account. Falls back to 10% of the
    /// book when there's no sized notional. Keeps the what-if projection honest.
    nonisolated static func proposedAddValue(sizedNotional: Double?, account: Double?, bookTotal: Double) -> Double? {
        guard bookTotal.isFinite, bookTotal >= 0 else { return nil }
        if let sizedNotional, !sizedNotional.isFinite || sizedNotional < 0 { return nil }
        if let account, !account.isFinite || account <= 0 { return nil }
        if let n = sizedNotional, let acct = account {
            guard n.isFinite, n >= 0, acct.isFinite, acct > 0 else { return nil }
            return Swift.min(n, acct)
        }
        let value = bookTotal * 0.10
        guard value.isFinite, bookTotal == 0 || value > 0 else { return nil }
        return value
    }

    /// Project concentration after adding `symbol` at `addedValue` to the current
    /// `holdings`, grouped by `classify` (default = asset class; pass
    /// StockSageSector.sector for a by-sector projection). Pure.
    nonisolated static func addingHolding(symbol: String, addedValue: Double,
                                          to holdings: [(symbol: String, value: Double)],
                                          classify: (String) -> String = StockSageAllocation.assetClass) -> WhatIfImpact? {
        guard addedValue.isFinite, addedValue >= 0,
              let before = StockSageAllocation.slices(holdings, by: classify),
              let after = StockSageAllocation.slices(holdings + [(symbol: symbol, value: addedValue)], by: classify) else { return nil }
        let bTop = before.first
        let aTop = after.first
        let beforeFrac = bTop?.fraction ?? 0
        let afterFrac = aTop?.fraction ?? 0
        return WhatIfImpact(
            candidateClass: classify(symbol),
            beforeTopClass: bTop?.label ?? "—",
            beforeTopFraction: beforeFrac,
            afterTopClass: aTop?.label ?? "—",
            afterTopFraction: afterFrac,
            crossesConcentration: afterFrac > concentratedAbove && beforeFrac <= concentratedAbove)
    }
}
