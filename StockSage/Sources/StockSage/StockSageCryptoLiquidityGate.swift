import Foundation

// MARK: - Crypto liquidity gate (CRYPTO_RISK #3)
//
// Two crypto-specific overstatements the backtester cannot see: (1) on a thin alt, a modeled
// stop/target "fill" exceeds the visible book — the fill is fiction (partial fills walking the
// book, or no fill); (2) 24/7 books thin on weekends/off-hours and stops blow through far past
// the level. This gate classifies tradability from the symbol's OWN history (ADV$ + worst
// adverse open-vs-prior-close drift) and composes IN FRONT of StockSageCryptoHonesty: a thin
// gate forces "unproven" (an unfillable edge is not an edge). nil for non-crypto — equities are
// byte-identical. Yahoo crypto volume is venue-AGGREGATED, so it OVERSTATES any single book you
// would actually trade — the floors are deliberately conservative, LABELED ESTIMATES, not
// fillability promises. Pure + deterministic; no network.

struct CryptoLiquidityGate: Sendable, Equatable {
    let advDollar: Double?            // ~average daily $ volume over the window; nil = unknown
    let isThinForCrypto: Bool
    let cryptoThinFloor: Double       // the floor used, surfaced for labeling
    let maxAdverseGapPct: Double      // worst (priorClose − nextOpen)/priorClose in sample, ≥ 0
    let recommendation: String        // "skip" | "limit-only, size down" | "tradeable"
    let note: String
}

enum StockSageCryptoLiquidityGate {
    /// LABELED ESTIMATE, owner-tunable: below ~this venue-aggregated ADV$, treat a crypto name
    /// as unfillable at advisor size (recommendation "skip"). NOT a measured microstructure fact.
    nonisolated static let cryptoThinFloorUSD = 5_000_000.0
    /// Between the thin floor and this ceiling: fills are plausible but the book is shallow —
    /// resting limits only, sized down. 4× the floor; same labeled-estimate status.
    nonisolated static let cautionCeilingUSD = 20_000_000.0

    /// Mean of close·volume over the trailing `window` bars. nil on mismatched/empty inputs or
    /// a non-positive result (no usable volume — unknown, never assumed liquid).
    nonisolated static func averageDollarVolume(closes: [Double], volumes: [Double], window: Int = 20) -> Double? {
        guard closes.count == volumes.count, !closes.isEmpty else { return nil }
        let n = Swift.min(Swift.max(1, window), closes.count)
        let sum = zip(closes.suffix(n), volumes.suffix(n)).reduce(0.0) { $0 + $1.0 * $1.1 }
        let adv = sum / Double(n)
        return adv > 0 ? adv : nil
    }

    /// Worst adverse "overnight" drift: max over i of (closes[i−1] − opens[i]) / closes[i−1],
    /// clamped ≥ 0. 0 when nothing gapped down, lengths mismatch, or < 2 bars (no crash, no
    /// fabricated read). On 24/7 UTC-bucketed candles there is no literal session close — this
    /// measures real prior-close-vs-next-open drift, descriptive of the past, not predictive.
    nonisolated static func maxAdverseOvernightGapPct(opens: [Double], closes: [Double]) -> Double {
        guard opens.count == closes.count, closes.count >= 2 else { return 0 }
        var worst = 0.0
        for i in 1..<closes.count {
            let prior = closes[i - 1]
            guard prior > 0 else { continue }
            worst = Swift.max(worst, (prior - opens[i]) / prior)
        }
        return Swift.max(0, worst)
    }

    /// nil for non-crypto symbols (no "-USD" suffix) — the equity path is untouched.
    nonisolated static func assess(symbol: String, closes: [Double], opens: [Double],
                                   volumes: [Double], window: Int = 20) -> CryptoLiquidityGate? {
        guard symbol.uppercased().hasSuffix("-USD") else { return nil }
        let adv = averageDollarVolume(closes: closes, volumes: volumes, window: window)
        let gap = maxAdverseOvernightGapPct(opens: opens, closes: closes)
        let isThin: Bool
        let recommendation: String
        let note: String
        if let adv {
            isThin = adv < cryptoThinFloorUSD
            if isThin {
                recommendation = "skip"
                note = String(format: "THIN crypto liquidity (~$%.1fM/day est., venue-aggregated — any single book is thinner) — modeled fills are optimistic; real slippage is worse. Worst adverse open gap in sample ≈ %.0f%%.", adv / 1_000_000, gap * 100)
            } else if adv < cautionCeilingUSD {
                recommendation = "limit-only, size down"
                note = String(format: "Shallow crypto book (~$%.1fM/day est.) — resting limits only, size down; modeled fills may be optimistic. Worst adverse open gap in sample ≈ %.0f%%.", adv / 1_000_000, gap * 100)
            } else {
                recommendation = "tradeable"
                note = String(format: "~$%.0fM/day est. (venue-aggregated; overstates any single book). Worst adverse open gap in sample ≈ %.0f%%. Depth is an estimate — it can vanish in a stress event.", adv / 1_000_000, gap * 100)
            }
        } else {
            // Honesty floor: unknown depth is never assumed liquid — but claiming "thin" would
            // fabricate a read we don't have. Middle recommendation, labeled unknown.
            isThin = false
            recommendation = "limit-only, size down"
            note = "Unknown crypto depth (no usable volume data) — est. only; treat fills as limit-only and size down."
        }
        return CryptoLiquidityGate(advDollar: adv, isThinForCrypto: isThin,
                                   cryptoThinFloor: cryptoThinFloorUSD, maxAdverseGapPct: gap,
                                   recommendation: recommendation, note: note)
    }
}
