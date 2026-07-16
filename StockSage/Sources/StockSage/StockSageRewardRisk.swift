import Foundation

// MARK: - Reward:risk quality
//
// A trade isn't good because the target is far away — it's good because the target
// is far RELATIVE to the stop. Reward:risk = (target−entry) ÷ (entry−stop). The
// number that follows from it is the one that matters: the break-even win-rate,
// 1/(1+RR) — the hit-rate below which the setup loses money no matter how often it
// "works". Pure + tested. A property of the plan, not a probability of winning.

struct RewardRisk: Sendable, Equatable {
    enum Quality: String, Sendable {
        case poor   = "Poor"
        case fair   = "Fair"
        case strong = "Strong"
    }
    let ratio: Double             // reward ÷ risk
    let quality: Quality
    let breakevenWinRate: Double  // 1/(1+ratio): win-rate needed just to break even

    nonisolated var note: String {
        // %.1f (not %.0f): a 2:1 setup breaks even at 33.3%, so ">33%" would wrongly
        // imply 33% suffices. Keep the decimal so the threshold isn't understated.
        // "gross" suffix (wave-11): this ratio is before round-trip costs; the net figure
        // is computed separately by StockSageNetEdge and shown on the scissors line and
        // the gate — the two must never appear to say the same thing with different values.
        String(format: "R:R %.1f gross — %@; needs a >%.1f%% win-rate just to break even.",
               ratio, quality.rawValue, breakevenWinRate * 100)
    }
}

enum StockSageRewardRisk {
    nonisolated static func assess(entry: Double, stop: Double, target: Double) -> RewardRisk? {
        let risk = abs(entry - stop)
        let reward = abs(target - entry)
        guard risk > 0, reward > 0 else { return nil }
        let ratio = reward / risk
        let quality: RewardRisk.Quality = ratio >= 2.5 ? .strong : (ratio >= 1.5 ? .fair : .poor)
        return RewardRisk(ratio: ratio, quality: quality, breakevenWinRate: 1 / (1 + ratio))
    }
}
