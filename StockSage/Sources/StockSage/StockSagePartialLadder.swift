import Foundation

// MARK: - Partial-profit ladder (scale-out plan)
//
// Taking the whole position off at the target maximizes R but also variance — one failed
// breakout and the runner gives it all back. A scale-out ladder banks pieces along the
// way: it LOWERS the average exit R but locks gains and cuts the chance of a winner
// round-tripping to break-even. This lays out evenly-spaced rungs from the first R step up
// to the target, with the blended exit R you'd realize if each fills. Pure + deterministic.
// Honest: it ASSUMES each level fills — gaps and thin liquidity can skip a rung.

struct LadderRung: Sendable, Equatable, Identifiable {
    let price: Double
    let rMultiple: Double   // R banked at this level
    let fraction: Double    // portion of the position exited here (rungs sum to 1)
    var id: Double { price }
}

struct PartialLadder: Sendable, Equatable {
    let rungs: [LadderRung]
    let blendedExitR: Double   // Σ fraction · rMultiple — the average R if every rung fills
}

enum StockSagePartialLadder {
    /// Evenly-spaced scale-out rungs (equal fractions) from the first R step up to the target
    /// (the last rung IS the target). Works long and short. nil for a degenerate setup.
    nonisolated static func levels(entry: Double, stop: Double, target: Double, rungs: Int = 3) -> PartialLadder? {
        // 2026-07-02 adversarial-review fix: the original guard checked only positivity, never
        // finiteness — Double.infinity > 0 is true, so a non-finite entry/stop/target passed
        // straight through and targetR = reward / risk became Infinity/Infinity = NaN, poisoning
        // every rung's price/rMultiple. Mirrors the identical hardening applied to
        // StockSagePyramid.levels on 2026-07-01.
        guard entry.isFinite, stop.isFinite, target.isFinite else { return nil }
        let risk = abs(entry - stop)
        let reward = abs(target - entry)
        guard risk > 0, reward > 0, rungs >= 1, entry > 0 else { return nil }
        let targetR = reward / risk
        let sign: Double = target > entry ? 1 : -1
        let frac = 1.0 / Double(rungs)
        let out = (1...rungs).map { i -> LadderRung in
            let r = targetR * Double(i) / Double(rungs)
            return LadderRung(price: entry + sign * r * risk, rMultiple: r, fraction: frac)
        }
        return PartialLadder(rungs: out, blendedExitR: out.reduce(0.0) { $0 + $1.fraction * $1.rMultiple })
    }
}
