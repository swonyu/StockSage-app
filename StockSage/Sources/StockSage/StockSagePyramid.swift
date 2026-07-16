import Foundation

// MARK: - Pyramiding (scale-in) ladder — mirror image of the scale-out PartialLadder
//
// Scaling OUT (StockSagePartialLadder) banks a winner in even pieces on the way up. Scaling IN
// is its mirror: front-load the full initial size at entry, then add SHRINKING pieces only as
// the trade proves itself — tier1 is the full `initialFraction` at entry, tier2 adds 50% of
// tier1 if price reaches +0.5R, tier3 adds 50% of tier2 (25% of tier1) at +1.5R. Shrinking
// add-ons keep the newest, least-proven size smallest (classic Livermore-style pyramiding).
// Pure + deterministic, same shape as StockSagePartialLadder but scaling in instead of out.
//
// Honest: this ASSUMES the trend keeps running. In chop, an add-on buys size right before the
// reversal — pyramiding is the most speculative sizing tool in the engine, which is why it is a
// standalone opt-in calculator, not wired into buildIdeas/advise() or conviction. It never
// bypasses the existing risk invariants: `riskCap` bounds the TOTAL account fraction across all
// three tiers combined, the same ceiling `StockSageKelly.maxFraction` and
// `StockSagePortfolioHeat` already enforce elsewhere. Per-tier dollar/share sizing composes with
// `StockSagePositionSizer.size(account:riskFraction:entry:stop:)` — this module only decides the
// FRACTIONS and trigger prices, not shares, so it never duplicates that logic.

struct PyramidTier: Sendable, Equatable, Identifiable {
    let price: Double              // trigger price for this tier's add-on (== entry for tier1)
    let rMultiple: Double          // R-multiple trigger (0, 0.5, 1.5 for tier1/2/3)
    let addOnFraction: Double      // account fraction ADDED at this tier (after any cap scaling)
    let cumulativeFraction: Double // running total account fraction once this tier has filled
    var id: Double { rMultiple }
}

struct PyramidPlan: Sendable, Equatable {
    let tiers: [PyramidTier]        // ordered tier1..tier3, strictly increasing rMultiple
    let requestedFraction: Double   // uncapped Σ add-ons (initialFraction × 1.75)
    let totalFraction: Double       // Σ add-ons actually scheduled == tiers.last.cumulativeFraction
    let riskCap: Double             // the ceiling totalFraction is pinned to
    let scaleApplied: Double        // 1.0 under the cap; else riskCap ÷ requestedFraction
    let caveat: String
}

enum StockSagePyramid {
    nonisolated static let caveat = "Pyramiding locks in early risk but needs more capital and assumes the trend keeps running — in chop, an add-on buys size right before the reversal. Only add to a trade that is already working; never force an add-on to average into a loser, and never let the total position bypass your risk cap."

    /// Fixed three-tier shrinking add-on schedule mirroring `StockSagePartialLadder`'s shape:
    /// tier1 is the full `initialFraction` at `entry` (0R); tier2 adds 50% of tier1 if price
    /// reaches +0.5R; tier3 adds 50% of tier2 (25% of tier1) at +1.5R, where R = |entry − stop|.
    /// Works long (stop below entry) and short (stop above entry) — direction is inferred from
    /// stop-vs-entry exactly like `StockSagePartialLadder` infers it from target-vs-entry.
    ///
    /// `riskCap` bounds the TOTAL account fraction across all three tiers combined (default
    /// `StockSageKelly.maxFraction`, the same 20% ceiling Kelly sizing already enforces — this
    /// tool must never let a pyramid exceed it). When the uncapped schedule (1.75× the initial
    /// fraction) would exceed the cap, EVERY tier — including tier1 — is scaled down uniformly so
    /// the total lands exactly at the cap while the shrinking 100/50/25 shape is preserved; ratios
    /// between tiers never change, only the overall scale does.
    ///
    /// nil for a degenerate setup: zero risk distance (entry == stop), non-positive entry,
    /// non-positive `initialFraction`, `initialFraction` above 1 (100% of the account — never
    /// legitimate), non-positive `riskCap`, or any non-finite input.
    nonisolated static func levels(entry: Double, stop: Double, initialFraction: Double,
                                   riskCap: Double = StockSageKelly.maxFraction) -> PyramidPlan? {
        // 2026-07-01 adversarial-review fix: the original guard checked only positivity, never
        // finiteness — Double.infinity > 0 is true, so an infinite entry/stop/initialFraction/
        // riskCap passed straight through and poisoned every downstream field with NaN (e.g. a
        // 0 × .infinity term in the tier-price math). `initialFraction <= 1` is also required:
        // it's an ACCOUNT FRACTION (never legitimately >100%), and without a ceiling a huge-but-
        // finite value can overflow the tier-sum to .infinity, silently zeroing every
        // addOnFraction via 0.2/.infinity while still reporting requestedFraction as .infinity.
        guard entry.isFinite, stop.isFinite, initialFraction.isFinite, riskCap.isFinite,
              entry > 0, initialFraction > 0, initialFraction <= 1, riskCap > 0 else { return nil }
        let risk = abs(entry - stop)
        guard risk > 0, risk.isFinite else { return nil }
        let cap = Swift.min(1, riskCap)
        let sign: Double = entry > stop ? 1 : -1   // long: stop below entry; short: stop above

        let rMultiples: [Double] = [0.0, 0.5, 1.5]
        let rawAddOns: [Double] = [initialFraction, initialFraction * 0.5, initialFraction * 0.25]
        let requested = rawAddOns.reduce(0, +)
        let scale = requested > cap ? cap / requested : 1

        var running = 0.0
        let tiers = (0..<3).map { i -> PyramidTier in
            let addOn = rawAddOns[i] * scale
            running += addOn
            return PyramidTier(price: entry + sign * rMultiples[i] * risk, rMultiple: rMultiples[i],
                               addOnFraction: addOn, cumulativeFraction: running)
        }
        return PyramidPlan(tiers: tiers, requestedFraction: requested, totalFraction: running,
                           riskCap: cap, scaleApplied: scale, caveat: caveat)
    }
}
