import Testing
import Foundation
@testable import StockSage

// BATCH 8.2 + 8.3 (2026-09-12) — the paper book must not fabricate a basis, and must date its mark.
//
// 8.2: `markToMarket` compared the stored entry against `closes[max(0, startIdx - 1)]`. When
// `startIdx == 0` the window holds NO bar at or before the open, so `closes[0]` is a LATER bar and
// the stored entry has nothing to be checked against. A genuine >=50% move since the open then
// reads as a split and rebases a real position onto a price it never traded at — stamping a
// corporate action that never happened. Falling through without rebasing is worse: `simulateExit`
// walks from j = entryIdx = 0 on stale-basis levels (the CLBK -13.5R fabrication).
//
// The companion matters as much as the fix: `scoreboard` marked those same positions at the
// un-rebased entry, so suppressing the rebase alone would have relocated the fabrication into the
// optimistic bound instead of removing it.
//
// 8.3: every mark is a DAILY CLOSE as of its own bar's date. The UI called it "current price".
@Suite("Paper book — mark basis and provenance")
struct StockSagePaperMarkProvenanceTests {

    private typealias P = StockSagePaperTrader
    private let day = 86_400.0
    private func d(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + n * 86_400) }

    private let costs = StockSageNetEdge.CostAssumption(spreadBps: 0, slippageBps: 0, assetClass: "test")

    private func history(dates: [Date], closes: [Double]) -> StockSagePriceHistory {
        StockSagePriceHistory(symbol: "CLBK", dates: dates, opens: closes, highs: closes,
                              lows: closes, closes: closes,
                              volumes: Array(repeating: 1_000, count: closes.count))
    }

    private func trade(_ symbol: String, entry: Double, stop: Double, openedAt: Date,
                       shares: Double = 10) -> TradeRecord {
        TradeRecord(symbol: symbol, side: .long, entry: entry, stop: stop, target: entry * 1.5,
                    shares: shares, openedAt: openedAt)
    }

    // MARK: 8.2 — a window that cannot verify the basis must change nothing

    // The CLBK shape: entry 23.42 on a pre-split basis, a history window that starts AFTER the
    // open and carries retro-adjusted ~10.7 closes. There is no entry bar to compare against.
    @Test func anOpenBeforeTheWindowIsReturnedUntouched() {
        let opened = d(0)
        let bars = history(dates: [d(1), d(2), d(3)], closes: [10.7, 10.8, 10.6])
        let t = trade("CLBK", entry: 23.42, stop: 21.0, openedAt: opened)
        let out = P.markToMarket([t], history: bars, costs: costs).first!
        #expect(out == t, "nothing about this trade is knowable from this window; it must be returned exactly as-is")
        #expect(out.note == t.note, "no '[rebased' stamp for a corporate action that was never observed")
        #expect(out.entry == 23.42 && out.shares == 10)
    }

    // The regression guard: a window that DOES contain the entry bar must still rebase, or 8.2
    // would have silently disabled the CLBK protection it exists to preserve.
    @Test func anEntryDayAnchoredWindowStillRebases() {
        let opened = d(2)
        // Bar at d(1) is the entry bar — it sits before the first post-open bar.
        let bars = history(dates: [d(1), d(2), d(3)], closes: [10.65, 10.7, 10.8])
        let t = trade("CLBK", entry: 23.42, stop: 21.0, openedAt: opened)
        let out = P.markToMarket([t], history: bars, costs: costs).first!
        #expect(out.entry < 23.42, "a >=50% basis mismatch against the real entry bar must still rebase")
        #expect(out.shares > 10, "shares scale inversely so position value is preserved")
    }

    // MARK: 8.2's companion — the fabrication must not relocate into the optimistic bound

    @Test func anUnverifiableOpenIsLeftUnmarkedNotMarkedOnADeadBasis() throws {
        let closed = (0..<4).map { i -> TradeRecord in
            var t = trade("OLD\(i)", entry: 100, stop: 90, openedAt: d(0))
            t.exitPrice = 110
            t.closedAt = d(1)
            return t
        }
        let preWindow = trade("CLBK", entry: 23.42, stop: 21.0, openedAt: d(0))
        let marks = ["CLBK": 10.7]

        // Hand-derived, not read off the run. Each closed trade: (110-100)/(100-90) = +1.00R,
        // four of them. The unverifiable open marked on its DEAD basis:
        // (10.7 - 23.42) / (23.42 - 21) = -12.72 / 2.42 = -5.2562R.
        // naive  full = [1, 1, 1, 1, -5.2562] -> avg = (4 - 5.2562) / 5 = -0.2512R
        // honest full = [1, 1, 1, 1]          -> avg = +1.0000R
        // So one fabricated mark swings the whole bound from +1.00R to -0.25R.
        let naive = try #require(P.scoreboard(closed + [preWindow], latestClose: marks))
        #expect(naive.openMarked == 1)
        #expect(naive.fullN == 5)
        #expect(abs(naive.fullAvgR - (-0.2512396694214876)) < 1e-9,
                "premise: the dead-basis mark really does enter the bound, at -5.2562R")

        // With the basis check, the position is dropped from the bound entirely.
        let honest = try #require(P.scoreboard(closed + [preWindow], latestClose: marks,
                                               firstBarAt: ["CLBK": d(1)]))
        #expect(honest.openMarked == 0, "an unverifiable basis is unknown, not a -5R")
        #expect(honest.fullN == 4)
        #expect(abs(honest.fullAvgR - 1.0) < 1e-9)
    }

    // MARK: 8.3 — the mark's own as-of

    @Test func theOldestMarkAndUndatedMarksAreBothCarried() throws {
        let closed = (0..<4).map { i -> TradeRecord in
            var t = trade("OLD\(i)", entry: 100, stop: 90, openedAt: d(0))
            t.exitPrice = 110; t.closedAt = d(1); return t
        }
        let opens = [trade("AAA", entry: 100, stop: 90, openedAt: d(1)),
                     trade("BBB", entry: 100, stop: 90, openedAt: d(1)),
                     trade("CCC", entry: 100, stop: 90, openedAt: d(1))]
        let marks = ["AAA": 110.0, "BBB": 110.0, "CCC": 110.0]
        // AAA dated 6 days ago, BBB dated today, CCC undated.
        let sb = try #require(P.scoreboard(closed + opens, latestClose: marks,
                                           markAsOf: ["AAA": d(-6), "BBB": d(0)]))
        #expect(sb.openMarked == 3)
        #expect(sb.oldestMarkAsOf == d(-6), "the OLDEST dated mark, not the newest")
        #expect(sb.marksWithUnknownAsOf == 1)

        // The bound itself is byte-identical to the same call without provenance — this is a
        // disclosure, not a change to the arithmetic.
        let plain = try #require(P.scoreboard(closed + opens, latestClose: marks))
        #expect(sb.fullAvgR == plain.fullAvgR && sb.fullN == plain.fullN && sb.openMarked == plain.openMarked)
    }

    @Test func theLineDatesTheBoundAndFailsClosedOnAnUnknownAsOf() throws {
        let now = d(0)
        #expect(MarketsView.markAsOfLine(oldest: nil, unknownCount: 0, marked: 0, now: now) == nil,
                "nothing marked ⇒ nothing to date")

        let today = try #require(MarketsView.markAsOfLine(oldest: d(0), unknownCount: 0, marked: 2, now: now))
        #expect(today.contains("today's close"))

        let week = try #require(MarketsView.markAsOfLine(oldest: d(-7), unknownCount: 0, marked: 2, now: now))
        #expect(week.contains("7 days old"), "a week-old close must say so, not read as a current price")

        let one = try #require(MarketsView.markAsOfLine(oldest: d(-1), unknownCount: 0, marked: 2, now: now))
        #expect(one.contains("1 day old") && !one.contains("1 days"))

        // Partial dating discloses the gap rather than rounding it off.
        let partial = try #require(MarketsView.markAsOfLine(oldest: d(-2), unknownCount: 1, marked: 3, now: now))
        #expect(partial.contains("2 days old") && partial.contains("1 of 3 mark(s) carried no bar date"))

        // ALL marks undated fails closed: it states the age is unverified, never implies today.
        let blind = try #require(MarketsView.markAsOfLine(oldest: nil, unknownCount: 2, marked: 2, now: now))
        #expect(blind.contains("unverified"))
        #expect(!blind.contains("today"))
    }
}
