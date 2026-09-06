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

    // MARK: rotatedSweepSlice — blocker fix 2026-09-06: refreshStreamGap must cap+rotate rather
    // than fan out to every candidate every sweep (unbounded ⇒ ~70k calls/h when `subscribed` is
    // empty — liveStream toggled off, or the Markets tab never yet shown).

    @Test("the stream-gap sweep cap is 20 per 30s-cadence sweep (major fix 2026-09-06)")
    func streamGapCapIsTwenty() {
        #expect(StockSageStore.streamGapMaxPerSweep == 20)
    }

    // MARK: shouldSweepStreamGap — the monotonic floor that stops two callers (MarketsView's 30s
    // timer, StockSageMonitor's per-cycle call) from stacking into a higher effective rate than
    // either alone (major fix 2026-09-06).

    @Test("never swept before (nil lastAt) always sweeps")
    func neverSweptAlwaysSweeps() {
        #expect(StockSageStore.shouldSweepStreamGap(lastAt: nil, now: Date(timeIntervalSince1970: 0)))
    }

    // Genuine boundary straddle, hand-derived: 1s under the floor still blocks; exactly at the
    // floor reopens it (the `>=` in `shouldSweepStreamGap`'s implementation).
    @Test("boundary straddle: 1s under the floor blocks, exactly at the floor sweeps")
    func floorBoundaryStraddle() {
        let last = Date(timeIntervalSince1970: 1_700_000_000)
        let justUnder = last.addingTimeInterval(StockSageStore.streamGapMinInterval - 1)
        let exactlyAt = last.addingTimeInterval(StockSageStore.streamGapMinInterval)
        #expect(!StockSageStore.shouldSweepStreamGap(lastAt: last, now: justUnder),
                "1s under the floor must still block a second caller from stacking")
        #expect(StockSageStore.shouldSweepStreamGap(lastAt: last, now: exactlyAt),
                "exactly at the floor, a legitimate next sweep must be allowed through")
    }

    @Test("a custom minInterval overrides the default floor")
    func customMinIntervalOverridesDefault() {
        let last = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(StockSageStore.shouldSweepStreamGap(lastAt: last, now: last.addingTimeInterval(5), minInterval: 3))
        #expect(!StockSageStore.shouldSweepStreamGap(lastAt: last, now: last.addingTimeInterval(2), minInterval: 3))
    }

    @Test("a candidate set under the cap is returned whole, cursor wraps to 0")
    func rotatedSliceUnderCapReturnsAllAndWrapsCursor() {
        let all = (1...10).map { "S\($0)" }
        let (picked, next) = StockSageStore.rotatedSweepSlice(all: all, cursor: 0, limit: 60)
        #expect(picked == all)
        #expect(next == 0)   // n == count exactly: (0 + 10) % 10 == 0
    }

    @Test("a candidate set over the cap is capped at the limit starting from the cursor")
    func rotatedSliceOverCapRespectsCursorAndLimit() {
        let all = (1...100).map { "S\($0)" }   // S1...S100
        let (picked, next) = StockSageStore.rotatedSweepSlice(all: all, cursor: 40, limit: 60)
        #expect(picked.count == 60)
        #expect(picked.first == "S41")          // 0-indexed cursor 40 -> element 41
        #expect(picked.last == "S100")          // 40+60=100 -> wraps: last 60 of 100 starting at 40 is S41...S100
        #expect(next == 0)                      // (40 + 60) % 100 == 0
    }

    @Test("rotation wraps around the end of the list, covering the tail before the head repeats")
    func rotatedSliceWrapsAroundTheEnd() {
        let all = (1...100).map { "S\($0)" }
        let (picked, next) = StockSageStore.rotatedSweepSlice(all: all, cursor: 80, limit: 60)
        #expect(picked.count == 60)
        #expect(picked.first == "S81")
        #expect(picked.last == "S40")            // wraps: S81...S100 (20) then S1...S40 (40)
        #expect(Set(picked).isSubset(of: Set(all)))
        #expect(next == 40)                      // (80 + 60) % 100 == 40
    }

    @Test("successive sweeps over a set larger than the cap eventually cover every symbol")
    func rotationCoversEveryTrackedSymbolAcrossSweeps() {
        let all = (1...130).map { "S\($0)" }     // > 2× the cap
        var cursor = 0
        var covered = Set<String>()
        for _ in 0..<3 {   // ceil(130/60) == 3 sweeps needed
            let (picked, next) = StockSageStore.rotatedSweepSlice(all: all, cursor: cursor, limit: 60)
            covered.formUnion(picked)
            cursor = next
        }
        #expect(covered == Set(all))
    }

    @Test("empty candidate list yields an empty slice and cursor 0")
    func rotatedSliceEmptyInputIsEmpty() {
        let (picked, next) = StockSageStore.rotatedSweepSlice(all: [], cursor: 5, limit: 60)
        #expect(picked.isEmpty)
        #expect(next == 0)
    }
}
