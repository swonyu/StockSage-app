import Foundation

/// The exact technical picture a research answer is allowed to talk about, computed ONLY from
/// completed adjusted daily bars and recorded so a later reviewer can reproduce every number.
///
/// This type calculates nothing itself beyond composition: every indicator comes from
/// `StockSageIndicators`, whose primitives are separately proven. What is new here is the
/// composition — which windows a horizon uses, ATR as a percentage, where the close sits in its
/// recent range, overnight gap statistics, and an explicit record of what could NOT be computed.
///
/// A missing indicator is recorded as unavailable. It is never defaulted, back-filled, or allowed
/// to read as a passed check; downstream qualification treats it as an uncertainty, not a
/// confirmation. Nothing here is a validated predictive probability.
enum StockSageTechnical {
    nonisolated static let version = 1
    /// Every value in a snapshot is stamped in this zone, matching the Nasdaq session calendar.
    nonisolated static let timezone = "America/New_York"

    /// One short lookback the horizon emphasises, with the measured return over it.
    nonisolated struct Window: Codable, Equatable, Sendable {
        let bars: Int
        /// Percent, matching StockSageIndicators.returnOverPeriod. nil when history is too short.
        let returnPercent: Double?
    }

    /// Indicator names that could not be computed from the supplied completed bars.
    /// Sorted for a stable receipt; presence here means "unknown", never "failed".
    nonisolated struct Sufficiency: Codable, Equatable, Sendable {
        let completedBars: Int
        let unavailable: [String]
        var isComplete: Bool { unavailable.isEmpty }
    }

    nonisolated struct Snapshot: Codable, Equatable, Sendable {
        let version: Int
        let symbol: String
        let horizon: String
        /// The last COMPLETED daily session. Every value below is as of this bar's close.
        let barDate: Date
        let timezone: String
        /// When this snapshot was computed. Never used as an evidence clock.
        let calculatedAt: Date
        /// The range/gap lookback in completed bars (20 for 1-7 days, 60 for 7-14 days).
        let lookbackBars: Int
        let shortWindows: [Window]

        let close: Double
        let sma20: Double?
        let sma50: Double?
        let sma200: Double?
        let rsi14: Double?
        let macd: Double?
        let macdSignal: Double?
        let macdHistogram: Double?
        let atr14: Double?
        /// ATR14 as a percentage of the completed close.
        let atrPercent: Double?
        /// Mean of the last three completed volumes over the preceding twenty. A plain multiple.
        let volumeRatio: Double?

        let rangeHigh: Double?
        let rangeLow: Double?
        /// Where the close sits inside the lookback range, 0 at the low and 1 at the high.
        /// nil when the range has no width. High values mean already-extended, not "strong".
        let rangePosition: Double?

        /// Absolute overnight gap, open against the prior completed close, in percent.
        let gapMeanPercent: Double?
        let gapMaxPercent: Double?
        let gapSampleCount: Int

        /// Symbol percent return minus benchmark percent return over the horizon window.
        /// nil when no benchmark series was supplied; a nil here is not weakness.
        let relativeStrengthPercent: Double?
        let benchmarkSymbol: String?

        let sufficiency: Sufficiency
    }

    /// The short lookbacks each horizon emphasises. Longer windows remain regime context and
    /// cannot manufacture a short-horizon catalyst.
    nonisolated static func shortWindowLengths(_ horizon: StockSageHorizonResearch.Horizon) -> [Int] {
        horizon == .week ? [3, 5, 7] : [7, 10, 14]
    }
    /// The range and gap lookback, matching the resistance window the strict screen already uses.
    nonisolated static func lookbackBars(_ horizon: StockSageHorizonResearch.Horizon) -> Int {
        horizon == .week ? 20 : 60
    }

    /// `history` MUST already be completed-bar history (see `completedHistory(_:at:)`), which
    /// enforces the adjusted daily source, bar integrity, and that the last bar is the latest
    /// completed session. Passing a still-forming bar here is a programming error upstream.
    nonisolated static func snapshot(history: StockSagePriceHistory,
                                     horizon: StockSageHorizonResearch.Horizon,
                                     calculatedAt: Date,
                                     benchmarkCloses: [Double]? = nil,
                                     benchmarkSymbol: String? = nil) -> Snapshot? {
        guard history.count > 0, history.count == history.dates.count,
              history.count == history.opens.count, history.count == history.highs.count,
              history.count == history.lows.count, history.count == history.volumes.count,
              let close = history.closes.last, close.isFinite, close > 0,
              let barDate = history.dates.last, barDate.timeIntervalSince1970.isFinite else { return nil }

        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        var unavailable: [String] = []
        func record(_ name: String, _ value: Double?) -> Double? {
            guard let value = finite(value) else { unavailable.append(name); return nil }
            return value
        }

        let lookback = lookbackBars(horizon)
        let sma20 = record("sma20", StockSageIndicators.sma(history.closes, period: 20))
        let sma50 = record("sma50", StockSageIndicators.sma(history.closes, period: 50))
        let sma200 = record("sma200", StockSageIndicators.sma(history.closes, period: 200))
        let rsi14 = record("rsi14", StockSageIndicators.rsi(history.closes, period: 14))

        let macdValue = StockSageIndicators.macd(history.closes)
        let macd = record("macd", macdValue?.macd)
        let macdSignal = record("macdSignal", macdValue?.signal)
        let macdHistogram = record("macdHistogram", macdValue?.histogram)

        let atr14 = record("atr14", StockSageIndicators.atr(highs: history.highs, lows: history.lows,
                                                            closes: history.closes, period: 14))
        let atrPercent = record("atrPercent", atr14.map { $0 / close * 100 })
        let volumeRatio = record("volumeRatio", StockSageIndicators.volumeConfirmation(
            closes: history.closes, volumes: history.volumes, lookback: 20, recentBars: 3)?.ratio)

        // Range over the horizon's own lookback, using the completed bars only.
        let windowHighs = Array(history.highs.suffix(lookback))
        let windowLows = Array(history.lows.suffix(lookback))
        let rangeHigh = record("rangeHigh", windowHighs.count >= lookback ? windowHighs.max() : nil)
        let rangeLow = record("rangeLow", windowLows.count >= lookback ? windowLows.min() : nil)
        var rangePosition: Double? = nil
        if let rangeHigh, let rangeLow, rangeHigh > rangeLow {
            rangePosition = (close - rangeLow) / (rangeHigh - rangeLow)
        } else if rangeHigh != nil, rangeLow != nil {
            unavailable.append("rangePosition")   // a zero-width range cannot locate the close
        }

        // Absolute overnight gap against the prior completed close, across the same lookback.
        var gaps: [Double] = []
        let firstGapIndex = max(1, history.count - lookback)
        if history.count > 1 {
            for index in firstGapIndex..<history.count {
                let prior = history.closes[index - 1]
                guard prior > 0 else { continue }
                let gap = abs(history.opens[index] - prior) / prior * 100
                if gap.isFinite { gaps.append(gap) }
            }
        }
        let gapMean = record("gapMeanPercent", gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count))
        let gapMax = record("gapMaxPercent", gaps.max())

        // Relative strength over the horizon's own holding length, not a long momentum window.
        var relativeStrength: Double? = nil
        if let benchmarkCloses {
            relativeStrength = finite(StockSageIndicators.relativeStrength(
                symbolCloses: history.closes, benchmarkCloses: benchmarkCloses,
                period: horizon == .week ? 7 : 14))
            if relativeStrength == nil { unavailable.append("relativeStrengthPercent") }
        }

        let windows = shortWindowLengths(horizon).map { bars in
            Window(bars: bars, returnPercent: finite(StockSageIndicators.returnOverPeriod(history.closes, period: bars)))
        }
        for window in windows where window.returnPercent == nil {
            unavailable.append("shortReturn\(window.bars)")
        }

        return Snapshot(version: version, symbol: history.symbol, horizon: horizon.rawValue,
            barDate: barDate, timezone: timezone, calculatedAt: calculatedAt,
            lookbackBars: lookback, shortWindows: windows, close: close,
            sma20: sma20, sma50: sma50, sma200: sma200, rsi14: rsi14,
            macd: macd, macdSignal: macdSignal, macdHistogram: macdHistogram,
            atr14: atr14, atrPercent: atrPercent, volumeRatio: volumeRatio,
            rangeHigh: rangeHigh, rangeLow: rangeLow, rangePosition: rangePosition,
            gapMeanPercent: gapMean, gapMaxPercent: gapMax, gapSampleCount: gaps.count,
            relativeStrengthPercent: relativeStrength, benchmarkSymbol: benchmarkCloses == nil ? nil : benchmarkSymbol,
            sufficiency: .init(completedBars: history.count, unavailable: unavailable.sorted()))
    }
}
