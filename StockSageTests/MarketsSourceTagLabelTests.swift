import Testing
import Foundation
@testable import StockSage

// MARK: - sourceTagLabel per-idea provenance tag (F-round-j FIX 2, 2026-07-09)
//
// Pins MarketsView.sourceTagLabel(isSampleData:loadedFromCache:priceAsOf:now:) — the honest
// per-row "Yahoo · Nm" / "cached" / "sample" tag. Precedence: isSampleData (global) wins over
// loadedFromCache (global) wins over the per-idea priceAsOf age — mirroring the top banner's own
// `sampleBanner`/`cachedBanner` precedence so a row can never contradict it. Every threshold below
// is hand-derived arithmetic (60s/3600s/86400s), not a call into the function under test.

struct MarketsSourceTagLabelTests {
    typealias M = MarketsView
    private static let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func sampleWinsOverEverything() {
        // isSampleData true must render "sample" regardless of loadedFromCache or priceAsOf —
        // matches sampleBanner's own precedence (checked first in bannerSection).
        #expect(M.sourceTagLabel(isSampleData: true, loadedFromCache: true, priceAsOf: Self.now, now: Self.now) == "sample")
        #expect(M.sourceTagLabel(isSampleData: true, loadedFromCache: false, priceAsOf: nil, now: Self.now) == "sample")
    }

    @Test func cachedWinsOverLivePriceAsOf() {
        // isSampleData false, loadedFromCache true -> "cached", ignoring priceAsOf entirely.
        #expect(M.sourceTagLabel(isSampleData: false, loadedFromCache: true, priceAsOf: Self.now, now: Self.now) == "cached")
        #expect(M.sourceTagLabel(isSampleData: false, loadedFromCache: true, priceAsOf: nil, now: Self.now) == "cached")
    }

    @Test func nilPriceAsOfOnALiveBoardRendersNothing() {
        // Honesty floor: neither global flag fires and this idea's own priceAsOf is unknown ->
        // nil, never a fabricated "0m"/"just now".
        #expect(M.sourceTagLabel(isSampleData: false, loadedFromCache: false, priceAsOf: nil, now: Self.now) == nil)
    }

    @Test func liveAgeStraddlesTheMinuteBoundary() {
        // 59s elapsed -> "just now" (< 60s threshold).
        let fiftyNineS = Self.now.addingTimeInterval(-59)
        #expect(M.sourceTagLabel(isSampleData: false, loadedFromCache: false, priceAsOf: fiftyNineS, now: Self.now) == "Yahoo · just now")
        // exactly 60s -> the 'm' bucket begins: 60/60 = 1 -> "Yahoo · 1m"
        let sixtyS = Self.now.addingTimeInterval(-60)
        #expect(M.sourceTagLabel(isSampleData: false, loadedFromCache: false, priceAsOf: sixtyS, now: Self.now) == "Yahoo · 1m")
        // 12 minutes -> "Yahoo · 12m" (the task's own worked example).
        let twelveMin = Self.now.addingTimeInterval(-12 * 60)
        #expect(M.sourceTagLabel(isSampleData: false, loadedFromCache: false, priceAsOf: twelveMin, now: Self.now) == "Yahoo · 12m")
    }

    @Test func liveAgeStraddlesTheHourBoundary() {
        // 59m59s elapsed: 3599s < 3600s -> still minutes bucket -> 3599/60 = 59 -> "Yahoo · 59m"
        let justUnderHour = Self.now.addingTimeInterval(-3599)
        #expect(M.sourceTagLabel(isSampleData: false, loadedFromCache: false, priceAsOf: justUnderHour, now: Self.now) == "Yahoo · 59m")
        // exactly 3600s -> hours bucket begins: 3600/3600 = 1 -> "Yahoo · 1h"
        let exactlyHour = Self.now.addingTimeInterval(-3600)
        #expect(M.sourceTagLabel(isSampleData: false, loadedFromCache: false, priceAsOf: exactlyHour, now: Self.now) == "Yahoo · 1h")
    }

    @Test func liveAgeStraddlesTheDayBoundary() {
        // 23h59m59s: 86399s < 86400s -> hours bucket -> 86399/3600 = 23 -> "Yahoo · 23h"
        let justUnderDay = Self.now.addingTimeInterval(-86_399)
        #expect(M.sourceTagLabel(isSampleData: false, loadedFromCache: false, priceAsOf: justUnderDay, now: Self.now) == "Yahoo · 23h")
        // exactly 86400s -> days bucket begins: 86400/86400 = 1 -> "Yahoo · 1d"
        let exactlyDay = Self.now.addingTimeInterval(-86_400)
        #expect(M.sourceTagLabel(isSampleData: false, loadedFromCache: false, priceAsOf: exactlyDay, now: Self.now) == "Yahoo · 1d")
    }
}
