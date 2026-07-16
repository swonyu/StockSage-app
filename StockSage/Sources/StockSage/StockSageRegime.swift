import Foundation

// MARK: - Market regime ("risk-on / risk-off" meta-gauge)
//
// The research's meta-rule (MARKETS_INTELLIGENCE_RESEARCH.md §4): detect the
// MARKET-WIDE regime first, then size accordingly. This fuses four classic,
// evidence-backed reads into one risk-on(+)/risk-off(−) score:
//   • Trend    — the benchmark (S&P 500) vs its 200-day average.
//   • Breadth  — % of tracked names above their OWN 200-day average (>70% strong,
//                <30% weak — the most common breadth gauge).
//   • Volatility — the VIX zone (<20 calm, 20–40 elevated, >40 crisis).
//   • Momentum — the index RSI.
// Output is a regime label + a position-size BIAS (scale exposure up in a calm
// uptrend, down in a downtrend, hard-cut in a crisis). It biases sizing; it does
// NOT predict. Pure + deterministic → unit-tested.

struct MarketRegime: Sendable, Equatable {
    enum State: String, Sendable {
        case trendingBull = "Risk-On · Bull trend"
        case trendingBear = "Risk-Off · Bear trend"
        case ranging      = "Neutral · Range-bound"
        case crisis       = "Risk-Off · High volatility"
    }
    let state: State
    /// −1 (max risk-off) … +1 (max risk-on).
    let riskScore: Double
    /// Plain-language votes that produced the score.
    let signals: [String]
    /// Suggested multiplier on the advisor's position size for THIS regime
    /// (0.25 in a crisis … ~1.25 in a strong bull). Guidance, not automatic.
    let sizingBias: Double
    let caveat: String
}

enum StockSageRegime {
    /// A liquid global large-cap sample for the breadth read (fraction above 200DMA).
    /// ⚠️ Bias: 8 of 14 names are US (6 mega-cap tech) — breadth signal skews with Nasdaq sentiment.
    nonisolated static let breadthSample: [String] = [
        "AAPL", "MSFT", "NVDA", "AMZN", "GOOGL", "META", "JPM", "TSLA",
        "SHEL.L", "SAP.DE", "7203.T", "0700.HK", "RELIANCE.NS", "BHP.AX",
    ]

    nonisolated static let caveat = "A market-wide risk gauge, not a forecast — it biases how much to size, it doesn't predict direction."

    /// Breadth: fraction of the given histories whose latest close is above their
    /// OWN 200-day average. Names without enough history to HAVE a 200DMA are
    /// excluded from BOTH numerator and denominator (counting them as "below"
    /// would understate breadth). nil when none are eligible. Pure + testable.
    nonisolated static func breadth(_ histories: [StockSagePriceHistory]) -> Double? {
        var eligible = 0, above = 0
        for h in histories {
            guard let sma = StockSageIndicators.sma(h.closes, period: 200), let price = h.latestClose else { continue }
            eligible += 1
            if price > sma { above += 1 }
        }
        return eligible > 0 ? Double(above) / Double(eligible) : nil
    }

    /// Apply this regime's sizing bias to a base position weight, re-capped — the
    /// research's "size smaller risk-off, bigger risk-on" rule made concrete.
    /// Guidance only. Pure.
    nonisolated static func adjustedWeight(base: Double, bias: Double, cap: Double) -> Double {
        guard base > 0 else { return 0 }
        return Swift.max(0, Swift.min(cap, base * bias))
    }

    /// Assess the regime. All inputs are optional/defensive so a partial feed
    /// still yields a sane verdict (missing inputs simply don't vote).
    nonisolated static func assess(indexCloses: [Double], vix: Double?, breadthAbove200: Double?) -> MarketRegime {
        var signals: [String] = []
        var score = 0.0

        // Trend — benchmark vs its 200DMA (heaviest weight).
        if let sma200 = StockSageIndicators.sma(indexCloses, period: 200), let price = indexCloses.last {
            if price > sma200 { score += 0.40; signals.append("S&P 500 above its 200-day average (uptrend)") }
            else { score -= 0.40; signals.append("S&P 500 below its 200-day average (downtrend)") }
        }
        // Momentum — index RSI.
        if let rsi = StockSageIndicators.rsi(indexCloses) {
            if rsi > 55 { score += 0.10; signals.append(String(format: "Index RSI %.0f — firm momentum", rsi)) }
            else if rsi < 45 { score -= 0.10; signals.append(String(format: "Index RSI %.0f — soft momentum", rsi)) }
        }
        // Breadth — participation.
        if let b = breadthAbove200 {
            if b >= 0.70 { score += 0.25; signals.append(String(format: "Broad strength — %.0f%% of names above their 200DMA", b * 100)) }
            else if b <= 0.30 { score -= 0.25; signals.append(String(format: "Narrow/weak — only %.0f%% above their 200DMA", b * 100)) }
            else { signals.append(String(format: "Mixed breadth — %.0f%% above their 200DMA", b * 100)) }
        }
        // Volatility — VIX zones.
        var crisis = false
        if let vix {
            if vix >= 40 { score -= 0.40; crisis = true; signals.append(String(format: "VIX %.0f — crisis-level volatility", vix)) }
            else if vix >= 20 { score -= 0.15; signals.append(String(format: "VIX %.0f — elevated volatility", vix)) }
            else { score += 0.10; signals.append(String(format: "VIX %.0f — calm", vix)) }
        }

        let risk = Swift.max(-1.0, Swift.min(1.0, score))
        let state: MarketRegime.State
        if crisis { state = .crisis }
        else if risk >= 0.40 { state = .trendingBull }
        else if risk <= -0.40 { state = .trendingBear }
        else { state = .ranging }

        // Size bigger when risk-on, smaller risk-off, hard-cut in a crisis.
        let sizingBias = crisis ? 0.25 : Swift.max(0.40, Swift.min(1.25, 0.75 + risk * 0.5))

        return MarketRegime(state: state, riskScore: risk, signals: signals,
                            sizingBias: sizingBias, caveat: caveat)
    }
}
