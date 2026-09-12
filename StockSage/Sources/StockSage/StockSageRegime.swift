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
    /// Evidence for current daily-history research, not a new trading-session policy.
    /// Preserve the cache's seven-full-calendar-day allowance (weekends included).
    nonisolated static func historyAsOf(_ h: StockSagePriceHistory, now: Date, coveringDailyDate: Date? = nil) -> Date? {
        guard h.priceSource == .massiveDaily || h.priceSource == .yahooBars,
              !h.closes.isEmpty, h.dates.count == h.closes.count,
              h.closes.allSatisfy({ $0.isFinite && $0 > 0 }),
              h.dates.allSatisfy({ $0.timeIntervalSince1970.isFinite && $0 <= now }),
              zip(h.dates, h.dates.dropFirst()).allSatisfy({ $0 < $1 }),
              let at = h.dates.last else { return nil }
        if let dailyDate = coveringDailyDate {
            // Yahoo weekly stamps denote period starts, not a new daily observation.
            // Compare covered weeks to the validated latest daily bar (holidays included).
            // Anchor at the provider's period start, not the device/US weekday: foreign
            // exchange weekly bars may begin on Sunday in New York.
            guard dailyDate <= now, dailyDate >= at,
                  dailyDate.timeIntervalSince(at) < 7 * 86_400 else { return nil }
        } else if StockSageHistoryCache.isStale(newest: at, asOf: now) { return nil }
        return at
    }
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
    /// BATCH 7.2 (owner-approved 2026-09-11). Minimum share of the REQUESTED sample that must
    /// produce a usable 200DMA reading before breadth is reported at all.
    ///
    /// `breadth` below excludes un-priced names from its own denominator — right, because counting
    /// a name with no history as "below its 200DMA" would understate breadth. But it means a
    /// fetch that returned 1 of 14 names publishes "100% of names above their 200DMA": a
    /// market-wide claim the owner reads verbatim, built on one stock. That breadth then
    /// multiplies every Deploy-capital weight through `sizingBias`, so the thin sample does not
    /// just mislead, it sizes. Below this floor breadth is nil, and a nil breadth already abstains
    /// cleanly in `assess` — sizing falls back to neutral rather than to a wrong bias.
    nonisolated static let minBreadthCoverage = 0.60

    /// Histories that can actually produce a 200DMA reading — `breadth`'s own denominator,
    /// exposed so the caller can judge COVERAGE before trusting the fraction.
    nonisolated static func breadthEligibleCount(_ histories: [StockSagePriceHistory]) -> Int {
        histories.reduce(into: 0) { n, h in
            if StockSageIndicators.sma(h.closes, period: 200) != nil, h.latestClose != nil { n += 1 }
        }
    }

    /// Whether `eligible` of `requested` names clears `minBreadthCoverage`. Zero requested is
    /// false: no sample is not full coverage.
    nonisolated static func breadthHasCoverage(eligible: Int, requested: Int) -> Bool {
        guard requested > 0 else { return false }
        return Double(eligible) / Double(requested) >= minBreadthCoverage
    }

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
