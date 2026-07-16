import Foundation

// MARK: - Liquidity profile (average daily dollar volume)
//
// A signal is worthless if you can't get filled near the price. For a thinly-
// traded name, your own order moves the market — the backtest's clean fills are a
// fantasy. This estimates average daily DOLLAR volume (close × shares) and tiers
// it, so small/illiquid names carry a slippage warning. Pure + tested. FX and
// indices report no real share volume, so they return nil (handled gracefully).

struct LiquidityProfile: Sendable, Equatable {
    enum Tier: String, Sendable {
        case thin     = "Thin"
        case moderate = "Moderate"
        case deep     = "Deep"
    }
    let avgDollarVolume: Double   // average daily close × volume over the window
    let tier: Tier

    nonisolated var note: String {
        let v = StockSageLiquidity.humanDollars(avgDollarVolume)
        switch tier {
        case .thin:
            return "Thin liquidity (~\(v)/day traded) — your order size can move the price; expect slippage and use LIMIT orders, not market. Backtest fills assume you didn't move the market."
        case .moderate:
            return "Moderate liquidity (~\(v)/day)."
        case .deep:
            return "Deep liquidity (~\(v)/day) — normal size is unlikely to move it."
        }
    }
}

enum StockSageLiquidity {
    // Rough $/day bands (US-equity scale).
    nonisolated static let thinBelow = 2_000_000.0
    nonisolated static let deepAbove = 50_000_000.0

    /// Whether a symbol's price×volume is genuinely in USD — so the $ label and the
    /// USD tier bands are valid. US-listed equities (no foreign exchange suffix) and
    /// USD crypto only; a foreign listing (.SR/.L/.T…) trades in its LOCAL currency,
    /// and London (.L) even quotes in pence, so a "$" figure there is meaningless.
    nonisolated static func isUSDPriced(_ symbol: String) -> Bool {
        switch StockSageAllocation.assetClass(symbol) {
        case "Crypto": return true
        case "Equity": return StockSageAllocation.region(symbol) == "United States"
        default: return false
        }
    }

    nonisolated static func tier(_ advDollar: Double) -> LiquidityProfile.Tier {
        if advDollar < thinBelow { return .thin }
        if advDollar < deepAbove { return .moderate }
        return .deep
    }

    /// Average daily dollar volume over the last `window` bars with usable volume.
    /// nil when there's no real volume (FX / indices report 0).
    nonisolated static func profile(closes: [Double], volumes: [Double], window: Int = 30) -> LiquidityProfile? {
        let n = Swift.min(closes.count, volumes.count)
        guard n >= 1 else { return nil }
        let cs = Array(closes.suffix(n)), vs = Array(volumes.suffix(n))
        let take = Swift.min(window, n)
        var sum = 0.0, count = 0
        for i in (n - take)..<n where vs[i] > 0 && cs[i] > 0 {
            sum += cs[i] * vs[i]
            count += 1
        }
        guard count > 0 else { return nil }
        let adv = sum / Double(count)
        return LiquidityProfile(avgDollarVolume: adv, tier: tier(adv))
    }

    nonisolated static func humanDollars(_ v: Double) -> String {
        switch v {
        case 1_000_000_000...: return String(format: "$%.1fB", v / 1_000_000_000)
        case 1_000_000...:
            // %.0f can round a band-top (e.g. 999.5M–999.99M) UP to "1000M"; promote to B instead.
            let m = v / 1_000_000
            return m >= 999.5 ? String(format: "$%.1fB", v / 1_000_000_000) : String(format: "$%.0fM", m)
        case 1_000...:
            // …and 999_950–999_999 would round to "1000K"; promote to M instead.
            let k = v / 1_000
            return k >= 999.5 ? String(format: "$%.1fM", v / 1_000_000) : String(format: "$%.0fK", k)
        default:               return String(format: "$%.0f", v)
        }
    }
}
