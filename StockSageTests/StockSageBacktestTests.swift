import Testing
import Foundation
@testable import StockSage

// MARK: - Walk-forward backtester
//
// Pins the no-look-ahead simulation against hand-reasoned series. A clean uptrend
// must produce winning long trades that hit their 2:1 target; a clean downtrend
// must produce no long entries at all.

struct StockSageBacktestTests {

    private func history(_ closes: [Double]) -> StockSagePriceHistory {
        StockSagePriceHistory(
            symbol: "T",
            dates: closes.enumerated().map { Date(timeIntervalSince1970: Double($0.offset) * 86_400) },
            opens: closes,                       // fill at next bar's open == its close
            highs: closes.map { $0 + 1 },
            lows: closes.map { $0 - 1 },
            closes: closes,
            volumes: closes.map { _ in 1000 })
    }

    @Test func cleanUptrendProducesWinningTargetTrades() {
        // ITER3 note: the old (1...600) fixture starts at price=1, where early log returns
        // (e.g. ln(2/1) ≈ 69%) inflate annualized vol to ~75%, causing the variance scalar
        // to heavily attenuate the trend family and suppress buy signals (score → ~0.03).
        // Replace with a realistic-price series starting at 100+: daily moves are ~0.17%,
        // annualized vol ≈ 2.7% << 20% → scalar = 1.0 (no-op), buy signals fire normally.
        // Series: 100 → 700 over 600 bars (600 * 1.0/bar, same monotone shape).
        let up = (0..<600).map { 100.0 + Double($0) * 1.0 }   // 100 → 699, gentle uptrend
        let r = StockSageBacktester.run(history(up))
        #expect(r.trades > 0)
        #expect(r.winRate == 1.0)             // a pure uptrend never hits the stop
        #expect(r.avgR > 1.9)                 // nearly every exit is the 2:1 target
        #expect(r.maxDrawdownR == 0)          // monotonic equity, no drawdown
    }

    @Test func cleanDowntrendTakesNoLongTrades() {
        let down = (1...600).reversed().map(Double.init)
        let r = StockSageBacktester.run(history(down))
        #expect(r.trades == 0)
        #expect(r == .empty)
    }

    @Test func tooLittleHistoryIsEmpty() {
        let r = StockSageBacktester.run(history((1...50).map(Double.init)))   // < warmup
        #expect(r == .empty)
    }

    @Test func significanceFlagNeedsTwentyTrades() {
        #expect(BacktestResult.empty.isSignificant == false)
    }

    /// Regression for the review fix: a bar that GAPS open below the stop must fill
    /// at the gap-open (worse), not magically at the stop — so the loss is < −1R.
    @Test func adverseGapFillIsWorseThanACleanStop() {
        // ITER3 note: the old (1...202) fixture starts at price=1, causing annualized vol
        // ≈ 75% (same root cause as cleanUptrendProducesWinningTargetTrades above), which
        // suppresses buy signals via the variance scalar. Start at 100 so daily log returns
        // are ~1% → vol ≈ 15% << 20% → scalar = 1.0 (no-op), buy signals fire at the SMA cross.
        var closes = (0...201).map { 100.0 + Double($0) }   // bars 0…201: 100 → 301 rising
        let crashLevel = 145.0
        closes += Array(repeating: crashLevel, count: 48)     // 250 bars total: then crash-flat
        var opens = closes
        opens[202] = 150                                     // gap-down open, below the prior stop
        var highs = closes.map { $0 + 1 }
        var lows  = closes.map { $0 - 1 }
        highs[202] = 151
        lows[202]  = 144                                     // pierces the stop on the gap bar
        let h = StockSagePriceHistory(
            symbol: "GAP",
            dates: closes.enumerated().map { Date(timeIntervalSince1970: Double($0.offset) * 86_400) },
            opens: opens, highs: highs, lows: lows, closes: closes, volumes: closes.map { _ in 1000 })
        let r = StockSageBacktester.run(h)
        #expect(r.trades >= 1)
        #expect(r.avgR < -1.0, "gap-open fill must produce a loss worse than -1R (filled below stop)")
    }
}
