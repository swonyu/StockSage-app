import Foundation

// MARK: - Multi-timeframe trend confirmation
//
// A daily signal is more trustworthy when the HIGHER timeframe agrees — a classic
// way to cut false signals (MARKETS_INTELLIGENCE_RESEARCH.md §4: don't fight the
// higher-timeframe tape). This reads the daily trend (price vs its 50DMA) and the
// WEEKLY trend (weekly price vs its 30-week MA, off actual weekly bars — far less
// noisy than a long daily MA) and reports whether they ALIGN. Pure + tested.

struct MultiTimeframeTrend: Sendable, Equatable {
    enum Trend: String, Sendable {
        case up = "Up"
        case down = "Down"
        case flat = "Flat"
    }
    let daily: Trend
    let weekly: Trend
    /// Both trending the same direction (and neither flat) = the high-conviction case.
    var aligned: Bool { daily == weekly && daily != .flat }
    let note: String
}

enum StockSageMultiTimeframe {
    nonisolated static func assess(dailyCloses: [Double], weeklyCloses: [Double]) -> MultiTimeframeTrend {
        let d = trend(dailyCloses, period: 50)
        let w = trend(weeklyCloses, period: 30)
        let note: String
        if d == w && d != .flat {
            note = "Daily + weekly trends aligned (\(d.rawValue.lowercased())) — higher conviction."
        } else if d == .flat || w == .flat {
            note = "Trend unclear on one timeframe — treat with caution."
        } else {
            note = "Daily and weekly disagree — conflicting signals, lower conviction."
        }
        return MultiTimeframeTrend(daily: d, weekly: w, note: note)
    }

    /// Trend = latest close vs its moving average, with a 1% neutral band so a price
    /// hugging the average reads Flat rather than flickering Up/Down. Requires the
    /// FULL `period` of bars — too short → Flat (unknown), never a degraded MA that
    /// would let a sparse/IPO ticker fake a "higher-timeframe aligned" confirmation.
    nonisolated static func trend(_ closes: [Double], period: Int) -> MultiTimeframeTrend.Trend {
        guard closes.count >= period, let last = closes.last,
              let sma = StockSageIndicators.sma(closes, period: period) else { return .flat }
        let band = abs(sma) * 0.01
        if last > sma + band { return .up }
        if last < sma - band { return .down }
        return .flat
    }
}
