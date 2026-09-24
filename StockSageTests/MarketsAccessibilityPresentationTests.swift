import Testing
import SwiftUI
@testable import StockSage

@Suite("Markets chart descriptions") @MainActor
struct MarketsAccessibilityPresentationTests {
    @Test(arguments: [
        ([100.0, 100], MarketsView.SparkTrend.flat),
        ([100.0, 150, 100], .flat),
        ([100.0, 100.05], .flat),
        ([100.0, 99.95], .flat),
        ([100.0, 100.2], .up),
        ([100.0, 99.8], .down),
        ([], .unavailable),
        ([100.0], .unavailable),
        ([0.0, 100], .unavailable)
    ])
    func chartDescriptionAndColorShareTheSameNetTrend(values: [Double], expected: MarketsView.SparkTrend) {
        #expect(MarketsView.sparkTrend(values) == expected)
        switch expected {
        case .up: #expect(MarketsView.sparkColor(values) == DS.Palette.successSoft)
        case .down: #expect(MarketsView.sparkColor(values) == DS.Palette.danger)
        case .flat, .unavailable: #expect(MarketsView.sparkColor(values) == DS.Palette.textSecondary)
        }
    }

    @Test func invalidChartEndpointsDoNotClaimADirection() {
        #expect(MarketsView.sparkTrend([100, .infinity]) == .unavailable)
        #expect(MarketsView.sparkTrend([.nan, 100]) == .unavailable)
    }
}
