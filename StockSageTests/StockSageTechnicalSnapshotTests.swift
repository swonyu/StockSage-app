import Foundation
import Testing
@testable import StockSage

// Fixtures are hand-derived in the comments and never read back from the code under test.
// The indicator primitives (RSI, Wilder ATR, MACD, SMA, volume ratio) are proven separately in
// StockSageIndicatorsTests; what is derived here is the SNAPSHOT'S OWN composition: horizon
// windows, ATR as a percentage, range position, overnight gap statistics, and sufficiency.
@Suite("Technical snapshot")
struct StockSageTechnicalSnapshotTests {
    private typealias T = StockSageTechnical
    private let calculatedAt = Date(timeIntervalSince1970: 1_788_739_200) // 2026-09-07 UTC

    /// A flat series with controlled overrides, so every composed value is hand-checkable.
    private func history(count: Int = 220, symbol: String = "ACME",
                         close: Double = 100,
                         highs: ((Int) -> Double)? = nil,
                         lows: ((Int) -> Double)? = nil,
                         opens: ((Int) -> Double)? = nil,
                         closes: ((Int) -> Double)? = nil,
                         volumes: ((Int) -> Double)? = nil) -> StockSagePriceHistory {
        let dates = (0..<count).map { Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 86_400) }
        let closeSeries = (0..<count).map { closes?($0) ?? close }
        return .init(symbol: symbol, dates: dates,
            opens: (0..<count).map { opens?($0) ?? closeSeries[$0] },
            highs: (0..<count).map { highs?($0) ?? (closeSeries[$0] + 1) },
            lows: (0..<count).map { lows?($0) ?? (closeSeries[$0] - 1) },
            closes: closeSeries,
            volumes: (0..<count).map { volumes?($0) ?? 100 },
            priceSource: .massiveDaily)
    }

    @Test(arguments: [StockSageHorizonResearch.Horizon.week, .fortnight])
    func eachHorizonUsesItsOwnShortWindowsAndLookback(horizon: StockSageHorizonResearch.Horizon) throws {
        let snapshot = try #require(T.snapshot(history: history(), horizon: horizon, calculatedAt: calculatedAt))
        let expectedWindows = horizon == .week ? [3, 5, 7] : [7, 10, 14]
        #expect(snapshot.shortWindows.map(\.bars) == expectedWindows)
        #expect(snapshot.lookbackBars == (horizon == .week ? 20 : 60))
        #expect(snapshot.horizon == horizon.rawValue)
        #expect(snapshot.version == 1 && snapshot.timezone == "America/New_York")
        #expect(snapshot.calculatedAt == calculatedAt)
        #expect(snapshot.barDate == Date(timeIntervalSince1970: 1_700_000_000 + 219 * 86_400),
                "Values are as of the last completed bar")
        #expect(snapshot.symbol == "ACME")
    }

    @Test func atrPercentAndRangePositionAreComposedFromTheCompletedClose() throws {
        // Close 100 everywhere, high = close + 1, low = close - 1.
        // True range each bar = 2 (high-low), and prior close sits inside it, so ATR14 = 2.
        // atrPercent = 2 / 100 * 100 = 2.
        // Over the last 20 bars: rangeHigh = 101, rangeLow = 99, width 2.
        // rangePosition = (100 - 99) / (101 - 99) = 0.5, hand-derived.
        let snapshot = try #require(T.snapshot(history: history(), horizon: .week, calculatedAt: calculatedAt))
        #expect(abs(try #require(snapshot.atr14) - 2) < 1e-9)
        #expect(abs(try #require(snapshot.atrPercent) - 2) < 1e-9)
        #expect(try #require(snapshot.rangeHigh) == 101 && #require(snapshot.rangeLow) == 99)
        #expect(abs(try #require(snapshot.rangePosition) - 0.5) < 1e-9)
        #expect(snapshot.close == 100)
    }

    @Test func rangePositionReportsAnExtendedCloseRatherThanCallingItStrength() throws {
        // Last bar closes at the top of its own 20-bar range: high 110 on the final bar only.
        let extended = history(highs: { $0 == 219 ? 110 : 101 },
                               lows: { $0 == 219 ? 109 : 99 },
                               closes: { $0 == 219 ? 110 : 100 })
        let snapshot = try #require(T.snapshot(history: extended, horizon: .week, calculatedAt: calculatedAt))
        // rangeHigh = 110 (final bar), rangeLow = 99 (the other 19 bars), close = 110.
        // rangePosition = (110 - 99) / (110 - 99) = 1.0 exactly, hand-derived.
        #expect(abs(try #require(snapshot.rangePosition) - 1.0) < 1e-9)
        #expect(try #require(snapshot.rangeHigh) == 110 && #require(snapshot.rangeLow) == 99)
    }

    @Test func zeroWidthRangeIsUnavailableRatherThanAMidpointGuess() throws {
        // Every high and low equal the close: the range has no width, so the close cannot be located.
        let flat = history(highs: { _ in 100 }, lows: { _ in 100 })
        let snapshot = try #require(T.snapshot(history: flat, horizon: .week, calculatedAt: calculatedAt))
        #expect(snapshot.rangePosition == nil)
        #expect(snapshot.sufficiency.unavailable.contains("rangePosition"))
        #expect(!snapshot.sufficiency.isComplete, "An uncomputable value is a gap, never a passed check")
    }

    @Test func overnightGapStatisticsUseTheOpenAgainstThePriorCompletedClose() throws {
        // Closes flat at 100. One bar opens at 105 → gap = |105 - 100| / 100 * 100 = 5%.
        // Another opens at 98 → gap = 2%. Every other bar opens at its own close → 0%.
        // Week lookback = 20 bars, so gaps are sampled over indices 200...219 → 20 samples.
        // mean = (5 + 2) / 20 = 0.35, max = 5. Hand-derived.
        let gapped = history(opens: { index in
            if index == 210 { return 105 }
            if index == 215 { return 98 }
            return 100
        })
        let snapshot = try #require(T.snapshot(history: gapped, horizon: .week, calculatedAt: calculatedAt))
        #expect(snapshot.gapSampleCount == 20)
        #expect(abs(try #require(snapshot.gapMaxPercent) - 5) < 1e-9)
        #expect(abs(try #require(snapshot.gapMeanPercent) - 0.35) < 1e-9)
    }

    @Test func volumeRatioComparesTheLastThreeBarsWithThePrecedingTwenty() throws {
        // Last three bars at volume 300, the twenty before them at 100 → ratio = 3.0, hand-derived.
        let surge = history(volumes: { $0 >= 217 ? 300 : 100 })
        let snapshot = try #require(T.snapshot(history: surge, horizon: .week, calculatedAt: calculatedAt))
        #expect(abs(try #require(snapshot.volumeRatio) - 3.0) < 1e-9)
        // Zero volume cannot confirm anything and must not read as a passed check.
        let silent = history(volumes: { _ in 0 })
        let quiet = try #require(T.snapshot(history: silent, horizon: .week, calculatedAt: calculatedAt))
        #expect(quiet.volumeRatio == nil && quiet.sufficiency.unavailable.contains("volumeRatio"))
    }

    @Test func relativeStrengthIsAbsentWithoutABenchmarkAndNeverInvented() throws {
        let rising = history(closes: { 100 + Double($0) })   // +1 per bar
        let none = try #require(T.snapshot(history: rising, horizon: .week, calculatedAt: calculatedAt))
        #expect(none.relativeStrengthPercent == nil && none.benchmarkSymbol == nil)
        #expect(!none.sufficiency.unavailable.contains("relativeStrengthPercent"),
                "No benchmark supplied is not a failed measurement")

        // Symbol closes 212...219 rise 1/bar: 7-bar return = (219 - 212) / 212 * 100.
        // A flat benchmark returns 0, so relative strength equals the symbol's own return.
        let flatBenchmark = Array(repeating: 50.0, count: 220)
        let measured = try #require(T.snapshot(history: rising, horizon: .week, calculatedAt: calculatedAt,
            benchmarkCloses: flatBenchmark, benchmarkSymbol: "BENCH"))
        let expected = (319.0 - 312.0) / 312.0 * 100
        #expect(abs(try #require(measured.relativeStrengthPercent) - expected) < 1e-9)
        #expect(measured.benchmarkSymbol == "BENCH")
    }

    @Test func shortHistoryMarksLongIndicatorsUnavailableWithoutFailingTheSnapshot() throws {
        // 40 completed bars: SMA20 available, SMA50 and SMA200 are not, MACD needs 35.
        let short = history(count: 40)
        let snapshot = try #require(T.snapshot(history: short, horizon: .week, calculatedAt: calculatedAt))
        #expect(snapshot.sma20 != nil)
        #expect(snapshot.sma50 == nil && snapshot.sma200 == nil)
        #expect(snapshot.sufficiency.unavailable.contains("sma50"))
        #expect(snapshot.sufficiency.unavailable.contains("sma200"))
        #expect(snapshot.sufficiency.completedBars == 40)
        #expect(snapshot.sufficiency.unavailable == snapshot.sufficiency.unavailable.sorted(),
                "A receipt lists gaps in a stable order")
        // A fortnight lookback of 60 exceeds 40 bars, so the range cannot be measured.
        let fortnight = try #require(T.snapshot(history: short, horizon: .fortnight, calculatedAt: calculatedAt))
        #expect(fortnight.rangeHigh == nil && fortnight.rangeLow == nil)
        #expect(fortnight.sufficiency.unavailable.contains("rangeHigh"))
    }

    @Test func malformedSeriesProducesNoSnapshotAtAll() {
        #expect(T.snapshot(history: history(count: 0), horizon: .week, calculatedAt: calculatedAt) == nil)
        let ragged = StockSagePriceHistory(symbol: "ACME",
            dates: [Date(timeIntervalSince1970: 1_700_000_000)], opens: [100], highs: [101], lows: [99],
            closes: [100], volumes: [], priceSource: .massiveDaily)
        #expect(T.snapshot(history: ragged, horizon: .week, calculatedAt: calculatedAt) == nil)
        let nonFinite = history(closes: { $0 == 219 ? Double.nan : 100 })
        #expect(T.snapshot(history: nonFinite, horizon: .week, calculatedAt: calculatedAt) == nil)
    }

    @Test func snapshotRoundTripsByteIdenticallyForTheReceipt() throws {
        let snapshot = try #require(T.snapshot(history: history(), horizon: .fortnight, calculatedAt: calculatedAt,
            benchmarkCloses: Array(repeating: 50.0, count: 220), benchmarkSymbol: "BENCH"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(snapshot)
        let decoded = try JSONDecoder().decode(T.Snapshot.self, from: bytes)
        let reencoded = try encoder.encode(decoded)
        #expect(decoded == snapshot && reencoded == bytes)
    }
}
