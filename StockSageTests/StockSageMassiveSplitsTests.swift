import Foundation
import Testing
@testable import StockSage

@Suite("Journal split comparison boundaries")
struct StockSageMassiveSplitsTests {
    private typealias S = StockSageMassiveSplits
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var now: Date { date("2026-09-07T15:00:00Z") }
    private var opened: Date { date("2026-09-01T15:00:00Z") }
    private func trade(side: TradeRecord.Side = .long, entry: Double = 100, stop: Double = 90,
                       target: Double = 130, shares: Double = 10, at: Date? = nil) -> TradeRecord {
        TradeRecord(symbol: "AAPL", side: side, entry: entry, stop: stop, target: target,
                    shares: shares, openedAt: at ?? opened, note: "Original broker record",
                    plannedEntry: entry, entryFill: entry + 0.1)
    }
    private func row(id: String = "s1", day: String = "2026-09-04", old: Double = 1,
                     new: Double = 4, kind: String = "forward_split") -> String {
        "{\"id\":\"\(id)\",\"ticker\":\"AAPL\",\"execution_date\":\"\(day)\",\"split_from\":\(old),\"split_to\":\(new),\"adjustment_type\":\"\(kind)\"}"
    }
    private func body(_ rows: String, tail: String = "") -> Data {
        Data("{\"status\":\"OK\",\"results\":[\(rows)]\(tail)}".utf8)
    }
    private func snapshot(_ rows: String) throws -> S.Snapshot {
        try S.parse(body(rows), symbol: "AAPL", since: opened, now: now)
    }
    private func basis(_ t: TradeRecord, _ rows: String) throws -> S.Basis {
        S.comparison(t, snapshot: try snapshot(rows), markAsOf: now, now: now)
    }

    @Test func forwardSplitPreservesValueAndCannotInventAStop() throws {
        let original = trade()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(original)
        let result = try basis(original, row())
        let copy = try #require(result.trade)
        #expect(copy.entry == 25 && copy.stop == 22.5 && copy.target == 32.5 && copy.shares == 40)
        #expect(copy.profit(at: 26) == 40 && copy.rMultiple(at: 26) == 0.4)
        #expect(StockSageJournal.openActions([copy], mark: { _ in 26 }).first?.kind == .inProfit)
        #expect(copy.entry * copy.shares == original.entry * original.shares)
        #expect(copy.riskPerShare * copy.shares == original.riskPerShare * original.shares)
        #expect(copy.plannedEntry == original.plannedEntry && copy.entryFill == original.entryFill)
        #expect(try encoder.encode(original) == before)
        #expect(result.multiplier == 4 && result.needsCloseReconciliation && !result.allowsMarkPrefill)
        #expect(result.note?.contains("journal unchanged") == true && result.note?.contains("×4") == true)
    }

    @Test func reverseSplitCannotInventATargetAndShortsKeepTheirSign() throws {
        let reverse = try #require(try basis(trade(entry: 10, stop: 9, target: 13, shares: 100),
                                            row(old: 10, new: 1, kind: "reverse_split")).trade)
        #expect(reverse.entry == 100 && reverse.stop == 90 && reverse.target == 130 && reverse.shares == 10)
        #expect(reverse.profit(at: 105) == 50 && reverse.rMultiple(at: 105) == 0.5)
        #expect(StockSageJournal.openActions([reverse], mark: { _ in 105 }).first?.kind == .inProfit)
        let short = try #require(try basis(trade(side: .short, stop: 110, target: 70), row()).trade)
        #expect(short.profit(at: 24) == 40 && short.rMultiple(at: 24) == 0.4)
        #expect(StockSageJournal.openActions([short], mark: { _ in 28 }).first?.kind == .stopHit)
    }

    @Test func completeNegativeAnswerLeavesOriginalMathAndClosePrefillAlone() throws {
        let original = trade()
        let result = try basis(original, "")
        #expect(result.trade == original && result.multiplier == 1 && result.note == nil)
        #expect(result.allowsMarkPrefill && !result.needsCloseReconciliation)
        #expect(StockSageJournal.openActions([original], mark: { _ in 110 }) ==
                StockSageJournal.openActions([try #require(result.trade)], mark: { _ in 110 }))
        let unavailable = S.comparison(original, snapshot: nil, markAsOf: now, now: now)
        #expect(unavailable.trade == nil && !unavailable.allowsMarkPrefill && unavailable.note != nil)
    }

    @Test func executionDayUsesNewYorkCalendarAndAlreadyAdjustedEntries() throws {
        let events = row(day: "2026-09-07")
        let sameDay = trade(at: date("2026-09-07T10:00:00Z")) // 06:00 NY, premarket
        #expect(try basis(sameDay, events).trade == sameDay)
        let previousNYDay = trade(at: date("2026-09-07T00:30:00Z")) // still Sep 6 in New York
        #expect(try basis(previousNYDay, events).multiplier == 4)
        let staleBasisMark = S.comparison(previousNYDay, snapshot: try snapshot(events),
            markAsOf: date("2026-09-07T01:00:00Z"), now: now)
        #expect(staleBasisMark.trade == nil && staleBasisMark.note?.contains("predates") == true)
        #expect(S.comparison(sameDay, snapshot: try snapshot(events),
                            markAsOf: date("2026-09-07T09:00:00Z"), now: now).trade == nil)
    }

    @Test func multipleEventsCompoundOnceNotTheCumulativeHistoricalFactor() throws {
        let a = row(day: "2026-09-02", new: 2)
        let b = row(id: "s2", new: 3).replacingOccurrences(of: "}", with: ",\"historical_adjustment_factor\":0.01}")
        let result = try basis(trade(), b + "," + a + "," + a)
        #expect(result.multiplier == 6 && result.trade?.shares == 60)
        let inverse = row(id: "s2", old: 2, new: 1, kind: "reverse_split")
        let netZero = try basis(trade(), a + "," + inverse)
        #expect(netZero.multiplier == 1 && netZero.allowsMarkPrefill && !netZero.needsCloseReconciliation)
        #expect(netZero.note != nil)
    }

    @Test func snapshotExpiresOnNewYorkRolloverOr24HoursAndNeverCoversEarlierEntry() throws {
        let s = try snapshot("")
        #expect(s.covers(since: opened, now: now))
        #expect(!s.covers(since: opened.addingTimeInterval(-86_400), now: now))
        #expect(!s.covers(since: opened, now: now.addingTimeInterval(-1)))
        #expect(!s.covers(since: opened, now: date("2026-09-08T04:00:00Z")))
        #expect(!s.covers(since: opened, now: now.addingTimeInterval(86_400)))
        #expect(!s.covers(since: opened, now: Date(timeIntervalSince1970: .nan)))
        for mark: Date? in [nil, now.addingTimeInterval(1), now.addingTimeInterval(-172_801)] {
            #expect(S.comparison(trade(), snapshot: s, markAsOf: mark, now: now).trade == nil)
        }
    }

    @Test func malformedPartialAndAmbiguousResponsesNeverMeanNoSplit() {
        let valid = row()
        let invalid = [Data("{}".utf8), body("null"), body("", tail: ",\"next_url\":\"https://api.massive.com/next\""),
            body("", tail: ",\"next_url\":3"), body(valid.replacingOccurrences(of: "AAPL", with: "MSFT")),
            body(row(day: "2026-09-08")), body(row(day: "2026-02-30")), body(row(day: "2026-08-31")),
            body(row(old: 0)), body(row(new: -4)), body(row(new: 0)), body(row(kind: "unknown")),
            body(row(kind: "reverse_split")), body(valid.replacingOccurrences(of: "\"split_from\":1.0", with: "\"split_from\":true")),
            body(valid + "," + row(new: 2)), body(valid + "," + row(id: "different")),
            body(Array(repeating: valid, count: 101).joined(separator: ","))]
        for data in invalid {
            #expect(throws: (any Error).self) { try S.parse(data, symbol: "AAPL", since: opened, now: now) }
        }
    }

    @Test func overflowingRatiosAndAdjustedValuesAreWithheld() throws {
        let huge = row(day: "2026-09-02", new: 1e200) + "," + row(id: "s2", new: 1e200)
        #expect(try basis(trade(), huge).trade == nil)
        #expect(try basis(trade(shares: 1e308), row()).trade == nil)
        #expect(try basis(trade(entry: .nan), row()).trade == nil)
    }

    @Test func requestsUseCurrentEndpointAndNeverPutCredentialsInURL() throws {
        let request = try #require(S.request(symbol: "aapl", since: opened, now: now, key: "fixture-only"))
        let url = try #require(request.url)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(url.host == "api.massive.com" && url.path == "/stocks/v1/splits")
        #expect(q["ticker"] == "AAPL" && q["execution_date.gte"] == "2026-09-01" && q["execution_date.lte"] == "2026-09-07")
        #expect(q["sort"] == "execution_date.asc" && q["limit"] == "100")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
        #expect(!url.absoluteString.contains("fixture-only"))
        #expect(S.request(symbol: "2222.SR", since: opened, now: now, key: "fixture-only") == nil)
        #expect(S.request(symbol: "AAPL", since: now.addingTimeInterval(1), now: now, key: "fixture-only") == nil)
        #expect(S.request(symbol: "AAPL", since: opened, now: now, key: "") == nil)
    }

    @Test func twoPositionsInOneSymbolHaveDistinctActions() {
        let trades = [trade(), trade()]
        let actions = StockSageJournal.openActions(trades, mark: { _ in 89 })
        #expect(actions.count == 2 && Set(actions.map(\.id)).count == 2)
        #expect(Set(actions.map(\.tradeID)) == Set(trades.map(\.id)))
    }
}
