import Testing
import Foundation
@testable import StockSage

// MARK: - MarketsView.updatedAgoLabel(since:now:) — W3 (owner: "update automatically every 30
// seconds"): the header's ticking "updated …" line, TimelineView-driven. Pure/threaded-clock so
// this is testable without a running TimelineView or a real wall clock.
struct MarketsUpdatedAgoLabelTests {
    typealias M = MarketsView

    @Test func justLandedReadsZeroSeconds() {
        let t = Date(timeIntervalSince1970: 1_000)
        #expect(M.updatedAgoLabel(since: t, now: t) == "updated 0s ago")
    }

    @Test func straddleAtFiftyNineVsSixtySecondsCrossesIntoMinutes() {
        let when = Date(timeIntervalSince1970: 1_000)
        #expect(M.updatedAgoLabel(since: when, now: when.addingTimeInterval(59)) == "updated 59s ago")
        #expect(M.updatedAgoLabel(since: when, now: when.addingTimeInterval(60)) == "updated 1m ago")
    }

    @Test func severalMinutesFormatsAsWholeMinutes() {
        let when = Date(timeIntervalSince1970: 1_000)
        #expect(M.updatedAgoLabel(since: when, now: when.addingTimeInterval(150)) == "updated 2m ago")
    }

    @Test func aClockThatSomehowRunsBackwardsNeverGoesNegative() {
        // Defensive floor: `now` before `when` (clock skew) must read as "just now", not a
        // nonsensical negative count.
        let when = Date(timeIntervalSince1970: 1_000)
        #expect(M.updatedAgoLabel(since: when, now: when.addingTimeInterval(-5)) == "updated 0s ago")
    }
}
