import Foundation

// MARK: - StockSageIndicators
//
// Pure, dependency-free technical indicators over a price / OHLC series. Every
// function is TOTAL (insufficient data → nil, never a crash or NaN) and
// deterministic, so they're unit-tested directly and can drive both the live
// advisor and the (future) backtester. Evidence + rationale for each:
// MARKETS_INTELLIGENCE_RESEARCH.md. All series are newest-LAST.
enum StockSageIndicators {

    /// Simple moving average of the last `period` values.
    nonisolated static func sma(_ values: [Double], period: Int) -> Double? {
        guard period > 0, values.count >= period else { return nil }
        return values.suffix(period).reduce(0, +) / Double(period)
    }

    /// Final exponential moving average (seeded with the SMA of the first window).
    nonisolated static func ema(_ values: [Double], period: Int) -> Double? {
        emaSeries(values, period: period).last
    }

    /// Full EMA series — newest last, length `values.count - period + 1`.
    /// Empty when there isn't enough data. Used by MACD.
    nonisolated static func emaSeries(_ values: [Double], period: Int) -> [Double] {
        guard period > 0, values.count >= period else { return [] }
        let k = 2.0 / (Double(period) + 1.0)
        var e = values.prefix(period).reduce(0, +) / Double(period)
        var out = [e]
        for v in values.dropFirst(period) {
            e = v * k + e * (1 - k)
            out.append(e)
        }
        return out
    }

    /// Wilder's RSI over `period` (default 14). 0–100. A series with no down-moves
    /// returns 100; no up-moves returns 0.
    nonisolated static func rsi(_ closes: [Double], period: Int = 14) -> Double? {
        guard period > 0, closes.count > period else { return nil }
        var gains = 0.0, losses = 0.0
        for i in 1...period {
            let change = closes[i] - closes[i - 1]
            if change >= 0 { gains += change } else { losses -= change }
        }
        var avgGain = gains / Double(period)
        var avgLoss = losses / Double(period)
        if closes.count > period + 1 {
            for i in (period + 1)..<closes.count {
                let change = closes[i] - closes[i - 1]
                let g = change > 0 ? change : 0
                let l = change < 0 ? -change : 0
                avgGain = (avgGain * Double(period - 1) + g) / Double(period)
                avgLoss = (avgLoss * Double(period - 1) + l) / Double(period)
            }
        }
        guard avgLoss != 0 else { return avgGain == 0 ? 50 : 100 }
        let rs = avgGain / avgLoss
        return 100 - 100 / (1 + rs)
    }

    struct MACDValue: Sendable, Equatable {
        let macd: Double
        let signal: Double
        let histogram: Double
    }

    /// MACD(12,26,9): macd = EMA(fast) − EMA(slow); signal = EMA(signalPeriod) of
    /// the macd line; histogram = macd − signal.
    nonisolated static func macd(_ closes: [Double], fast: Int = 12, slow: Int = 26, signalPeriod: Int = 9) -> MACDValue? {
        guard fast < slow, closes.count >= slow + signalPeriod else { return nil }
        let fastSeries = emaSeries(closes, period: fast)
        let slowSeries = emaSeries(closes, period: slow)
        guard !fastSeries.isEmpty, !slowSeries.isEmpty else { return nil }
        // The slow EMA series is shorter; align on its tail length.
        let count = min(fastSeries.count, slowSeries.count)
        let macdLine = zip(fastSeries.suffix(count), slowSeries.suffix(count)).map { $0 - $1 }
        guard let signal = ema(macdLine, period: signalPeriod), let last = macdLine.last else { return nil }
        return MACDValue(macd: last, signal: signal, histogram: last - signal)
    }

    /// Wilder's Average True Range over `period` (default 14). Highs/lows/closes
    /// must be equal length and newest-last.
    nonisolated static func atr(highs: [Double], lows: [Double], closes: [Double], period: Int = 14) -> Double? {
        let n = closes.count
        guard period > 0, n > period, highs.count == n, lows.count == n else { return nil }
        var trs: [Double] = []
        trs.reserveCapacity(n - 1)
        for i in 1..<n {
            let tr = Swift.max(highs[i] - lows[i],
                               abs(highs[i] - closes[i - 1]),
                               abs(lows[i] - closes[i - 1]))
            trs.append(tr)
        }
        guard trs.count >= period else { return nil }
        var atr = trs.prefix(period).reduce(0, +) / Double(period)
        for tr in trs.dropFirst(period) {
            atr = (atr * Double(period - 1) + tr) / Double(period)
        }
        return atr
    }

    /// Kaufman Efficiency Ratio over `period`: |net change| ÷ Σ|step changes|.
    /// 0 = pure chop (mean-reverting), 1 = clean trend. A simple, robust regime
    /// discriminator (substitutes for ADX without its complexity).
    nonisolated static func efficiencyRatio(_ closes: [Double], period: Int = 20) -> Double? {
        guard period > 0, closes.count > period else { return nil }
        let window = Array(closes.suffix(period + 1))
        guard let first = window.first, let last = window.last else { return nil }
        let net = abs(last - first)
        var noise = 0.0
        for i in 1..<window.count { noise += abs(window[i] - window[i - 1]) }
        guard noise != 0 else { return 0 }
        return net / noise
    }

    /// Annualized realized volatility from closes: stdev of log returns × √periodsPerYear.
    nonisolated static func annualizedVolatility(_ closes: [Double], periodsPerYear: Double = 252) -> Double? {
        guard closes.count >= 3 else { return nil }
        var rets: [Double] = []
        for i in 1..<closes.count where closes[i - 1] > 0 && closes[i] > 0 {
            rets.append(log(closes[i] / closes[i - 1]))
        }
        guard rets.count >= 2 else { return nil }
        let mean = rets.reduce(0, +) / Double(rets.count)
        let variance = rets.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rets.count - 1)
        return variance.squareRoot() * periodsPerYear.squareRoot()
    }

    /// Percent return over the last `period` steps (e.g. 126 ≈ 6 trading months).
    nonisolated static func returnOverPeriod(_ closes: [Double], period: Int) -> Double? {
        guard period > 0, closes.count > period else { return nil }
        let past = closes[closes.count - 1 - period]
        guard past != 0, let last = closes.last else { return nil }
        return (last - past) / past * 100
    }

    /// Is the latest move backed by REAL volume? Compares the last `recentBars` of the
    /// (real, fetched) volume series against the `lookback` bars before them. ratio = recent
    /// avg ÷ prior avg; confirmed when ratio ≥ 1 (above-average participation). Returns nil
    /// when volumes are absent/all-zero (FX & indices have none) — never invents a number.
    nonisolated static func volumeConfirmation(closes: [Double], volumes: [Double],
                                               lookback: Int = 20, recentBars: Int = 3)
        -> (confirmed: Bool, ratio: Double)? {
        guard volumes.count == closes.count, lookback > 0, recentBars > 0,
              volumes.count >= lookback + recentBars else { return nil }
        let recent = volumes.suffix(recentBars)
        let prior  = volumes.dropLast(recentBars).suffix(lookback)
        let recentAvg = recent.reduce(0, +) / Double(recent.count)
        let priorAvg  = prior.reduce(0, +) / Double(prior.count)
        guard priorAvg > 0 else { return nil }   // no real volume to compare against
        let ratio = recentAvg / priorAvg
        return (confirmed: ratio >= 1.0, ratio: ratio)
    }

    /// Benchmark-relative strength: the symbol's % return MINUS the benchmark's (e.g. ^GSPC)
    /// % return over `period` bars. Positive ⇒ outperforming the index — the part of
    /// momentum with the most documented forward edge; a name rising only because the whole
    /// market is rising has RS ≈ 0. nil when either real series is too short to measure
    /// (so the consumer simply skips the term rather than inventing one). Lengths needn't
    /// match — each leg's return is measured over its own last `period` bars.
    nonisolated static func relativeStrength(symbolCloses: [Double], benchmarkCloses: [Double],
                                             period: Int = 126) -> Double? {
        guard let symRet = returnOverPeriod(symbolCloses, period: period),
              let benchRet = returnOverPeriod(benchmarkCloses, period: period) else { return nil }
        return symRet - benchRet
    }

    /// Volatility-adjusted momentum: % return over `period` ÷ ATR-as-a-%-of-price. Raw %
    /// return flatters whichever asset simply swings harder (a 40%-vol crypto vs an 8%-vol
    /// equity), so dividing by the asset's own ATR makes momentum apples-to-apples across
    /// assets — a steady low-vol climber beats a jumpy same-return name. Same sign as raw
    /// momentum. nil when bars are insufficient or ATR is unavailable/zero.
    nonisolated static func volAdjustedMomentum(closes: [Double], period: Int = 126, atrPeriod: Int = 14,
                                                highs: [Double], lows: [Double]) -> Double? {
        guard let mom = returnOverPeriod(closes, period: period),
              let a = atr(highs: highs, lows: lows, closes: closes, period: atrPeriod),
              let price = closes.last, price > 0 else { return nil }
        let atrPct = a / price * 100
        guard atrPct > 0 else { return nil }
        return mom / atrPct
    }

    /// Time-series (absolute) momentum — the name's OWN trailing return over `lookback` bars
    /// EXCLUDING the most-recent `skipRecent` (the standard 12-1 construction that avoids the
    /// 1-month reversal). One of the most replicated cross-asset anomalies, and it doubles as a
    /// crash filter: a long against a name's own downtrend is the trade to veto. Same sign as the
    /// trend. nil when there aren't enough bars. Pair with `trendOK` for a binary risk-on/off gate.
    nonisolated static func timeSeriesMomentum(_ closes: [Double], lookback: Int = 252, skipRecent: Int = 21) -> Double? {
        guard lookback > skipRecent, skipRecent >= 0, closes.count > lookback else { return nil }
        let startIdx = closes.count - 1 - lookback     // `lookback` bars back
        let endIdx   = closes.count - 1 - skipRecent   // up to `skipRecent` bars ago (the 12-1 skip)
        guard startIdx >= 0, endIdx > startIdx else { return nil }
        let past = closes[startIdx]
        guard past != 0 else { return nil }
        return (closes[endIdx] - past) / past * 100
    }

    /// Binary own-trend gate: is time-series momentum positive (risk-on for a long)? nil when
    /// momentum can't be computed. A FILTER/veto, never a return forecast.
    nonisolated static func trendOK(_ closes: [Double], lookback: Int = 252, skipRecent: Int = 21) -> Bool? {
        timeSeriesMomentum(closes, lookback: lookback, skipRecent: skipRecent).map { $0 > 0 }
    }

    /// Donchian channel: the highest high and lowest low over the last `period` bars. nil if
    /// fewer than `period` bars. Computed over EXACTLY the slice you pass — so to stay
    /// look-ahead-free in a backtest, pass bars up to but EXCLUDING the current one
    /// (e.g. `highs[0..<i]`), never the bar you're deciding on.
    nonisolated static func donchian(highs: [Double], lows: [Double], period: Int = 20)
        -> (upper: Double, lower: Double)? {
        guard period > 0, highs.count >= period, lows.count >= period,
              let upper = highs.suffix(period).max(), let lower = lows.suffix(period).min() else { return nil }
        return (upper, lower)
    }

    /// A long breakout fires when `price` closes STRICTLY above the channel's upper band
    /// (equalling the band is not a breakout). Build `channel` on bars excluding the current
    /// one, then pass the current close, to keep the trigger free of look-ahead.
    nonisolated static func isBreakout(price: Double, channel: (upper: Double, lower: Double)) -> Bool {
        price > channel.upper
    }

    /// 52-week-high proximity ratio: `price ÷ (highest high over the trailing min(252,count) bars)`.
    /// The CONTINUOUS anchoring signal (Byun & Jeon 2023) — value rises toward 1 as price nears its
    /// 1-year high; ≈ 0.5 deep in a drawdown. Replaces the binary breakout trigger, which adds ~0
    /// incremental edge once a continuous distance is present (Avramov 2018).
    ///
    /// HONESTY (Guardrail 4): with < 252 bars this is the proximity to the AVAILABLE-history high,
    /// NOT a true 52-week high — `effectiveWindow` returns the bars actually used so the caller can
    /// label the rationale honestly. Uses `highs` (intraday extremes), so an intraday/realtime print
    /// can make pth slightly > 1; callers must tolerate (and the long-side term naturally caps benefit).
    /// nil when there are no bars or the rolling-max high is non-positive (degenerate). Pure + total.
    nonisolated static func highProximity(price: Double, highs: [Double], window: Int = 252)   // [AUDIT] default 252 = ~1yr
        -> (pth: Double, effectiveWindow: Int)? {
        guard price > 0, !highs.isEmpty, window > 0 else { return nil }
        let w = Swift.min(window, highs.count)                 // [AUDIT] min(252,count) — short-history honesty
        guard let maxHigh = highs.suffix(w).max(), maxHigh > 0 else { return nil }
        return (pth: price / maxHigh, effectiveWindow: w)      // [AUDIT] pth = price / rollingMaxHigh
    }

    /// Three-timeframe confluence — RANKING_BACKLOG #12's actual intent ("confluent setups outrank
    /// single-signal ones"), shipped SAFELY as a pure post-hoc OBSERVER instead of a conviction-score
    /// input: it reads three horizons already implicit in one daily `closes` array and reports
    /// whether they agree, but it NEVER feeds back into `score`/conviction/sizing anywhere (see
    /// `StockSageAdvisor.advise()`'s own `trendFamilyCap` invariant — folding a 4th trend-correlated
    /// term directly into the score, as originally proposed, was independently re-audited 2026-07-01
    /// and rejected: it would sit OUTSIDE the 0.65 cap and double-count the SAME underlying trend
    /// factor the daily/short legs here already partially share).
    ///
    ///   • LONG   — `trendOK(closes)` (the SAME 12-1 / 252-bar TSMOM already gating buy-the-dip
    ///     eligibility elsewhere in `advise()`) AND price-vs-its-own-200DMA must AGREE. TSMOM's
    ///     12-1 construction structurally SKIPS the most recent ~21 trading days, so it alone can't
    ///     see a breakout/breakdown that happened THIS month; requiring the 200DMA read to agree
    ///     catches that gap (a name that broke below its 200DMA this week but whose 12-1 window
    ///     hasn't rolled forward yet must not still read "long-term bullish"). When the two
    ///     disagree, the long-term read is itself ambiguous — nil ("unknown"), never a guessed side.
    ///     nil when < 253 bars (trendOK's own minimum) — genuinely unknown, not bearish.
    ///   • DAILY  — the sign of `dailyDirection` (the caller passes the advisor's own RESOLVED,
    ///     already-fully-computed `score`'s sign — after every existing term, cap, and the iter3
    ///     variance-scalar attenuation have already applied; this function does not re-derive it).
    ///   • SHORT  — the sign of `returnOverPeriod(closes, period: shortPeriod)` (~1 month), with a
    ///     `neutralBandPct` dead-zone so a flat/chop tape can't fake agreement by pure noise.
    ///
    /// `aligned` is true only when all three legs are DEFINED and share the same sign. A `long` leg
    /// of `nil` (short history, or the TSMOM/200DMA disagreement above) makes alignment structurally
    /// unavailable — read as "unknown," never as "not aligned" / bearish. Pure, deterministic, zero
    /// new fetch (reuses `trendOK`/`sma`/`returnOverPeriod`, already-tested primitives).
    nonisolated static func timeframeConfluence(closes: [Double], dailyDirection: Int,
                                                shortPeriod: Int = 21, neutralBandPct: Double = 1.0)
    -> (aligned: Bool, direction: Int, long: Int, short: Int?)? {
        guard let longUp = trendOK(closes) else { return nil }
        guard let sma200 = sma(closes, period: 200), let price = closes.last, price > 0 else { return nil }
        guard longUp == (price > sma200) else { return nil }   // TSMOM vs 200DMA disagree → unknown, not a guess
        let longDir = longUp ? 1 : -1
        guard let shortReturn = returnOverPeriod(closes, period: shortPeriod) else { return nil }
        let shortDir = abs(shortReturn) < neutralBandPct ? 0 : (shortReturn > 0 ? 1 : -1)
        guard shortDir != 0, dailyDirection != 0 else {
            return (aligned: false, direction: 0, long: longDir, short: shortDir == 0 ? nil : shortDir)
        }
        let aligned = longDir == dailyDirection && dailyDirection == shortDir
        return (aligned: aligned, direction: aligned ? dailyDirection : 0, long: longDir, short: shortDir)
    }
}
