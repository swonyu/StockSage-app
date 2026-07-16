import Testing
import Foundation
@testable import StockSage

// MARK: - Liquidity profile (pure)

struct StockSageLiquidityTests {

    typealias LQ = StockSageLiquidity

    @Test func tierBands() {
        #expect(LQ.tier(500_000) == .thin)
        #expect(LQ.tier(10_000_000) == .moderate)
        #expect(LQ.tier(200_000_000) == .deep)
    }

    @Test func thinNameIsFlagged() {
        // close 10 × 50,000 sh = $500k/day → thin
        let p = LQ.profile(closes: Array(repeating: 10, count: 30), volumes: Array(repeating: 50_000, count: 30))!
        #expect(p.tier == .thin)
        #expect(abs(p.avgDollarVolume - 500_000) < 1e-6)
        #expect(p.note.contains("Thin"))
    }

    @Test func deepNameIsCalm() {
        // close 100 × 10,000,000 = $1B/day → deep
        let p = LQ.profile(closes: Array(repeating: 100, count: 30), volumes: Array(repeating: 10_000_000, count: 30))!
        #expect(p.tier == .deep)
    }

    @Test func zeroVolumeReturnsNil() {
        // FX/index report 0 volume → no liquidity profile.
        #expect(LQ.profile(closes: Array(repeating: 1.1, count: 30), volumes: Array(repeating: 0, count: 30)) == nil)
        #expect(LQ.profile(closes: [], volumes: []) == nil)
    }

    @Test func averagesOnlyOverTheWindowAndUsableBars() {
        // 40 bars but window 30; mix in a zero-volume bar that must be excluded.
        var closes = Array(repeating: 20.0, count: 40)
        var vols = Array(repeating: 100_000.0, count: 40)
        closes[39] = 20; vols[39] = 0     // last bar has no volume → excluded
        let p = LQ.profile(closes: closes, volumes: vols, window: 30)!
        #expect(abs(p.avgDollarVolume - 2_000_000) < 1e-6)   // 20 × 100k
    }

    @Test func onlyUSDPricedSymbolsGetADollarProfile() {
        #expect(LQ.isUSDPriced("AAPL"))          // US equity
        #expect(LQ.isUSDPriced("BTC-USD"))       // USD crypto
        #expect(!LQ.isUSDPriced("2222.SR"))      // Saudi (SAR)
        #expect(!LQ.isUSDPriced("7203.T"))       // Japan (JPY)
        #expect(!LQ.isUSDPriced("VOD.L"))        // London (pence!)
        #expect(!LQ.isUSDPriced("EURUSD=X"))     // FX
        #expect(!LQ.isUSDPriced("^GSPC"))        // index
    }

    @Test func humanDollarsFormatsScale() {
        #expect(LQ.humanDollars(2_300_000_000) == "$2.3B")
        #expect(LQ.humanDollars(45_000_000) == "$45M")
        #expect(LQ.humanDollars(800_000) == "$800K")
        // Band-top rounding: %.0f would overflow the unit ("$1000K"/"$1000M") — promote instead.
        #expect(LQ.humanDollars(999_950) == "$1.0M")
        #expect(LQ.humanDollars(999_500_000) == "$1.0B")
        #expect(LQ.humanDollars(999_499_999) == "$999M")   // under the threshold → stays M
    }
}
