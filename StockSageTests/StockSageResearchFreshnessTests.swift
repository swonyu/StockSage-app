import Foundation
import Testing
@testable import StockSage

@Suite("Research market and freshness presentation")
struct StockSageResearchFreshnessTests {
    typealias F = StockSageResearchFreshness
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func marketClockUsesNewYorkAndDistinguishesAllSessionStates() {
        let regular = F.market(at: date("2026-09-14T13:30:00Z"))
        #expect(regular.tone == .green && regular.clock.contains("09:30 EDT"))
        #expect(regular.next.contains("16:00 EDT"))
        #expect(F.market(at: date("2026-09-14T12:00:00Z")).tone == .amber)
        #expect(F.market(at: date("2026-09-14T21:00:00Z")).tone == .amber)
        #expect(F.market(at: date("2026-09-13T15:00:00Z")).tone == .red)
        #expect(F.market(at: date("2026-09-07T15:00:00Z")).tone == .red) // Labor Day
        #expect(F.market(at: date("2027-01-04T15:00:00Z")).tone == .gray)
        #expect(F.market(at: date("2027-01-04T15:00:00Z")).phaseLabel.contains("unavailable"))
        #expect(F.market(at: date("2026-11-27T18:00:00Z")).tone == .amber) // Early close 13:00 EST
        #expect(F.market(at: date("2026-11-02T14:30:00Z")).clock.contains("09:30 EST"))
    }

    @Test func agesAndChangesDoNotPretendClosedPricesAreFreshQuotes() {
        let now = date("2026-09-13T15:00:00Z")
        #expect(F.age(now.addingTimeInterval(1), at: now) == "clock mismatch")
        #expect(F.age(now.addingTimeInterval(-61), at: now) == "1m ago")
        let old = StockSageHorizonResearch.Result(note: "fixture", at: now.addingTimeInterval(-3600),
            referenceClose: (100, now.addingTimeInterval(-86400)), newestNewsAt: now.addingTimeInterval(-7200))
        let new = StockSageHorizonResearch.Result(note: "fixture", at: now,
            referenceClose: old.referenceClose, newestNewsAt: now.addingTimeInterval(-1800))
        #expect(F.change(from: old, to: new).contains("Same completed daily bar"))
        #expect(F.change(from: old, to: new).contains("Newer article retained"))
        #expect(F.change(from: old, to: new).contains("1h 0m ago"))
        #expect(F.change(from: nil, to: new).contains("no prior result"))
    }
}
