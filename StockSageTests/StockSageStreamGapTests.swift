import Testing
import Foundation
@testable import StockSage

// MARK: - Stream-gap candidate selection (B2, owner 2026-09-06: "every tracked stock should be live")
//
// Pins StockSageStore.streamGapCandidates(tracked:subscribed:isTrading:) — the pure diff between
// what's tracked and what StockSageLiveStream already streams, filtered by whether that symbol's
// market is actually trading right now. No network, no StockSageLiveStream singleton, no wall
// clock — `isTrading` is injected. The real `marketIsTrading` predicate (which B2 says to REUSE,
// not re-derive) is exercised separately below with hand-derived UTC instants.

@Suite("streamGap candidate selection")
struct StockSageStreamGapTests {
    typealias S = StockSageStore

    @Test("closed market yields no candidates")
    func closedMarketIsEmpty() {
        let result = S.streamGapCandidates(tracked: ["AAPL", "2222.SR"], subscribed: [],
                                            isTrading: { _ in false })
        #expect(result.isEmpty)
    }

    @Test("a symbol the stream already subscribed is excluded")
    func streamedSymbolIsExcluded() {
        let result = S.streamGapCandidates(tracked: ["AAPL", "MSFT"], subscribed: ["AAPL"],
                                            isTrading: { _ in true })
        #expect(result == ["MSFT"])
    }

    @Test("subscribed match is case-insensitive")
    func subscribedMatchIsCaseInsensitive() {
        // `subscribed` is documented uppercased already, but a tracked symbol's OWN casing
        // (e.g. the user's watchlist store) must not accidentally re-open a gap that's covered.
        let result = S.streamGapCandidates(tracked: ["aapl"], subscribed: ["AAPL"],
                                            isTrading: { _ in true })
        #expect(result.isEmpty)
    }

    @Test("an un-streamable Tadawul name trading now is included")
    func tadawulNameDuringHoursIsIncluded() {
        // EODHD carries no Tadawul feed (StockSageLiveStream's own doc) -> .SR names never land
        // in `subscribed`; they're exactly the gap this sweep exists to fill.
        let result = S.streamGapCandidates(tracked: ["2222.SR"], subscribed: [],
                                            isTrading: { $0.hasSuffix(".SR") })
        #expect(result == ["2222.SR"])
    }

    @Test("empty tracked set yields no candidates regardless of subscribed/isTrading")
    func emptyTrackedIsEmpty() {
        let result = S.streamGapCandidates(tracked: [], subscribed: [], isTrading: { _ in true })
        #expect(result.isEmpty)
    }

    // MARK: marketIsTrading straddle — B2 says reuse this existing schedule check rather than
    // write a second one. Fixtures are hand-derived UTC instants (Riyadh AST is +03:00
    // year-round, no DST), same technique/date as StockSageMarketHoursTests:
    //   Riyadh Sun 2026-07-19 09:59:59 AST -> 2026-07-19 06:59:59 UTC  (closed, 1s before open)
    //   Riyadh Sun 2026-07-19 10:00:00 AST -> 2026-07-19 07:00:00 UTC  (open, at the instant)
    //   Riyadh Sun 2026-07-19 14:59:59 AST -> 2026-07-19 11:59:59 UTC  (open, 1s before close)
    //   Riyadh Sun 2026-07-19 15:00:00 AST -> 2026-07-19 12:00:00 UTC  (closingAuction, at close)
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h; comps.minute = mi; comps.second = s
        return Self.utcCalendar.date(from: comps)!
    }

    @Test("straddle: one second before Tadawul open excludes; at the open instant includes")
    func tadawulOpenInstantStraddle() {
        let beforeOpen = utc(2026, 7, 19, 6, 59, 59)
        let atOpen = utc(2026, 7, 19, 7, 0, 0)
        #expect(S.marketIsTrading(symbol: "2222.SR", at: beforeOpen) == false)
        #expect(S.marketIsTrading(symbol: "2222.SR", at: atOpen) == true)

        let beforeResult = S.streamGapCandidates(tracked: ["2222.SR"], subscribed: [],
                                                  isTrading: { S.marketIsTrading(symbol: $0, at: beforeOpen) })
        #expect(beforeResult.isEmpty)
        let atOpenResult = S.streamGapCandidates(tracked: ["2222.SR"], subscribed: [],
                                                  isTrading: { S.marketIsTrading(symbol: $0, at: atOpen) })
        #expect(atOpenResult == ["2222.SR"])
    }

    @Test("straddle: one second before Tadawul close includes; at the close instant (closingAuction) excludes")
    func tadawulCloseInstantStraddle() {
        let beforeClose = utc(2026, 7, 19, 11, 59, 59)
        let atClose = utc(2026, 7, 19, 12, 0, 0)
        #expect(S.marketIsTrading(symbol: "2222.SR", at: beforeClose) == true)
        // closingAuction is NOT `.open` -> marketIsTrading is false (Tadawul's strict rule, unlike
        // NASDAQ's pre/after-hours which DO count as trading).
        #expect(S.marketIsTrading(symbol: "2222.SR", at: atClose) == false)

        let beforeResult = S.streamGapCandidates(tracked: ["2222.SR"], subscribed: [],
                                                  isTrading: { S.marketIsTrading(symbol: $0, at: beforeClose) })
        #expect(beforeResult == ["2222.SR"])
        let atCloseResult = S.streamGapCandidates(tracked: ["2222.SR"], subscribed: [],
                                                   isTrading: { S.marketIsTrading(symbol: $0, at: atClose) })
        #expect(atCloseResult.isEmpty)
    }
}
