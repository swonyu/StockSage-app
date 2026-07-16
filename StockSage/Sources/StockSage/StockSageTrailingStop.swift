import Foundation

// MARK: - ATR trailing-stop suggestion
//
// A fixed stop is set once and forgotten; a TRAILING stop follows the trade up.
// This is a true Chandelier exit: the HIGHEST HIGH over the lookback minus a
// multiple of ATR (average true range). Anchoring to the highest high (not the
// latest close) is what makes it trail — the anchor can't fall while that high
// stands, so the level rises with new highs and doesn't drop on a down day. The
// ATR term scales the room to the name's real volatility, not a guessed percent.
// It's a STARTING level computed once — the owner moves it up as new highs print.
// Pure + tested. An exit rule, not a profit forecast.

struct TrailingStop: Sendable, Equatable {
    let level: Double         // suggested stop price (for a long): highestHigh − k·ATR
    let atr: Double           // current ATR
    let multiple: Double      // k (ATRs of room)
    let distancePct: Double   // how far below the last close, %
}

enum StockSageTrailingStop {
    /// Chandelier exit for a LONG: highestHigh(period) − k·ATR. nil if ATR can't be
    /// computed, the level is non-positive, or it isn't below the last close (a stop
    /// at/above price means it would already be hit — not a usable trailing level).
    nonisolated static func suggest(highs: [Double], lows: [Double], closes: [Double],
                                    multiple: Double = 3, period: Int = 14) -> TrailingStop? {
        guard multiple > 0, let last = closes.last, last > 0,
              let anchorHigh = highs.suffix(period).max(),
              let atr = StockSageIndicators.atr(highs: highs, lows: lows, closes: closes, period: period),
              atr > 0 else { return nil }
        let level = anchorHigh - multiple * atr
        guard level > 0, level < last else { return nil }
        return TrailingStop(level: level, atr: atr, multiple: multiple,
                            distancePct: (last - level) / last * 100)
    }

    /// "Where your stop SHOULD be today" for a LONG held since `entryIndex` — the ratcheting
    /// Chandelier the backtester scores (StockSageBacktester.trailLevels), lifted to an owner-facing
    /// call. Anchors the highest high SINCE ENTRY and lets the stop only RISE (a pullback never
    /// surrenders banked profit). Returns the FINAL ratcheted level. Bars too close to the start of
    /// the supplied window for ATR to be computable yet are simply skipped (not fatal) — only
    /// entryIndex being out of range, ATR NEVER becoming computable, or the final level not being
    /// usable (≤0, or ≥ last close → already hit: price has pulled back THROUGH the trail, so you
    /// should already be out, not "set a stop here") produce nil.
    /// Advisory only — the app places NO orders; you move the GTC stop at the broker.
    nonisolated static func recompute(highs: [Double], lows: [Double], closes: [Double],
                                      entryIndex: Int, multiple: Double = 3, period: Int = 14) -> TrailingStop? {
        let n = closes.count
        guard highs.count == n, lows.count == n, multiple > 0,
              entryIndex >= 0, entryIndex < n - 1,            // need ≥1 bar after entry
              let last = closes.last, last > 0 else { return nil }
        var anchorHigh = highs[entryIndex]                    // highest high since entry (monotonic ↑)
        var ratchet = -Double.greatestFiniteMagnitude
        var lastATR = 0.0
        for b in (entryIndex + 1)..<n {
            anchorHigh = Swift.max(anchorHigh, highs[b])
            // ATR needs > period bars of history; if entryIndex is early in the supplied window it may
            // not be computable yet at THIS bar — skip it (don't abort the whole computation) and pick
            // the ratchet up once enough bars have accumulated. Only the FINAL level needs to be usable.
            guard let atr = StockSageIndicators.atr(highs: Array(highs[0...b]), lows: Array(lows[0...b]),
                                                    closes: Array(closes[0...b]), period: period),
                  atr > 0 else { continue }
            ratchet = Swift.max(ratchet, anchorHigh - multiple * atr)   // up-only, same as the backtester
            lastATR = atr
        }
        guard lastATR > 0, ratchet > 0, ratchet < last else { return nil }
        return TrailingStop(level: ratchet, atr: lastATR, multiple: multiple,
                            distancePct: (last - ratchet) / last * 100)
    }
}
