import Testing
import Foundation
@testable import StockSage

// MARK: - freshnessStale (review item Q8, 2026-07-28)
//
// Pins MarketsView.freshnessStale(asOf:now:) — the FAIL-CLOSED predicate shared by `liveBanner`
// and `headerSubtitle`. Before this fix both sites used `?? false` (nil asOf reads as live); the
// fix flips the fallback to `?? true` so an unknown market timestamp can never render "Live".
// >1h (strict) tolerates the normal ~15-min feed delay, matching the row-level contract at
// StockSageModels.swift:85 (`guard let t = marketTime else { return true }`).

struct MarketsFreshnessStaleTests {
    typealias M = MarketsView
    private static let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func nilAsOfIsStaleNotLive() {
        // The Q8 fix itself: unknown freshness must fail closed (stale), never fail open (live).
        #expect(M.freshnessStale(asOf: nil, now: Self.now) == true)
    }

    @Test func straddlesTheOneHourBoundary() {
        // 59m59s elapsed: 3599s < 3600s (1h) -> NOT stale
        let underOneHour = Self.now.addingTimeInterval(-3599)
        #expect(M.freshnessStale(asOf: underOneHour, now: Self.now) == false)

        // exactly 1h elapsed: 3600.0s -> strict '>' means the boundary itself is NOT stale
        let exactlyOneHour = Self.now.addingTimeInterval(-3600)
        #expect(M.freshnessStale(asOf: exactlyOneHour, now: Self.now) == false)

        // 1h01s elapsed: 3601s > 3600s -> stale
        let overOneHour = Self.now.addingTimeInterval(-3601)
        #expect(M.freshnessStale(asOf: overOneHour, now: Self.now) == true)
    }
}
