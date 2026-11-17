import Testing
import Foundation
@testable import StockSage

// MARK: - Indicator nil-boundary (F05 off-by-one companion)
//
// StockSageIndicatorsTests pins macd() nil at 34 bars but nothing pinned non-nil AT exactly
// 35 (= slow 26 + signal 9), so an off-by-one to `>= 36` would pass silently. macd feeds the
// advisor's ±0.10 MACD term (a money-relevant signal), so the exact minimum is worth pinning.

struct StockSageIndicatorBoundaryTests {

    typealias I = StockSageIndicators

    // macd minimum = slow(26) + signalPeriod(9) = 35 bars (StockSageIndicators.swift:70).
    // Rising (non-flat) series so flatness can't be what returns nil — isolating the COUNT guard.
    @Test func macdComputesAtExactly35Bars() {
        let rising35 = (0..<35).map { 100.0 + Double($0) }
        #expect(I.macd(rising35) != nil)     // exactly 35 → non-nil; an off-by-one to `>= 36` fails HERE
        let rising34 = (0..<34).map { 100.0 + Double($0) }
        #expect(I.macd(rising34) == nil)     // 34 (non-flat) → nil: the COUNT guard, not flatness
    }

    // trendOK / timeSeriesMomentum minimum: guard `closes.count > lookback(252)` ⇒ 253 bars
    // (StockSageIndicators.swift:190; at 253, startIdx = 253−1−252 = 0 works, past = closes[0] ≠ 0).
    // Existing tests pin <253 → nil (trendOK/confluence) but not non-nil AT 253. A boundary pin
    // needs only non-nil/nil (trendOK returns Bool?), no derived direction. Also covers
    // timeframeConfluence's shared count minimum (it delegates to trendOK).
    @Test func trendOKComputesAtExactly253Bars() {
        let rising253 = (0..<253).map { 100.0 + Double($0) }   // closes[0]=100≠0; 12-1 momentum > 0
        #expect(I.trendOK(rising253) != nil)     // exactly 253 → non-nil; off-by-one to `> 253` fails HERE
        let rising252 = (0..<252).map { 100.0 + Double($0) }
        #expect(I.trendOK(rising252) == nil)     // 252 → nil (`count > 252` is false)
    }
}
