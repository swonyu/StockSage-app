import Testing
import Foundation
@testable import StockSage

// MARK: - EODHD earnings calendar + fundamentals Earnings.History (W1, 2026-09-06)
//
// All fixtures are hand-written JSON, never a Swift-literal roundtrip of the parser's own
// output (spec-fidelity) — every date is a fixed `yyyy-MM-dd` string, never `Date()`.

@Suite("StockSageEODHDCalendar")
struct StockSageEODHDCalendarTests {

    private func utcDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    // MARK: parseCalendar

    @Test func parsesTheWrappedEarningsShape() {
        let json = """
        {"earnings":[
          {"code":"AAPL.US","report_date":"2026-06-30","date":"2026-07-30",
           "before_after_market":"AfterMarket","estimate":1.5,"actual":null}
        ]}
        """
        let rows = StockSageEODHDCalendar.parseCalendar(Data(json.utf8))
        #expect(rows.count == 1)
        #expect(rows[0].code == "AAPL.US")
        #expect(rows[0].date == utcDate(2026, 7, 30))
        #expect(rows[0].reportPeriod == utcDate(2026, 6, 30))
        #expect(rows[0].beforeAfterMarket == "AfterMarket")
        #expect(rows[0].estimate == 1.5)
        #expect(rows[0].actual == nil)
    }

    @Test func parsesTheBareArrayShape() {
        let json = """
        [{"code":"MSFT.US","date":"2026-08-15"}]
        """
        let rows = StockSageEODHDCalendar.parseCalendar(Data(json.utf8))
        #expect(rows.count == 1)
        #expect(rows[0].code == "MSFT.US")
        #expect(rows[0].date == utcDate(2026, 8, 15))
        #expect(rows[0].reportPeriod == nil)   // report_date absent — never fabricated
    }

    @Test func malformedRowsAreSkippedNotFailingTheWholeBatch() {
        // n=4 input rows: 1 valid, 1 missing code, 1 with an unparseable date, 1 not an object.
        let json = """
        {"earnings":[
          {"code":"AAPL.US","date":"2026-07-30"},
          {"date":"2026-07-30"},
          {"code":"NVDA.US","date":"not-a-date"},
          "garbage"
        ]}
        """
        let rows = StockSageEODHDCalendar.parseCalendar(Data(json.utf8))
        #expect(rows.count == 1)
        #expect(rows[0].code == "AAPL.US")
    }

    @Test func malformedOrEmptyBodyParsesToEmpty() {
        #expect(StockSageEODHDCalendar.parseCalendar(Data("{}".utf8)) == [])
        #expect(StockSageEODHDCalendar.parseCalendar(Data("not json".utf8)) == [])
        #expect(StockSageEODHDCalendar.parseCalendar(Data(#"{"earnings":[]}"#.utf8)) == [])
    }

    // MARK: nextRow — soonest at/after `now`

    @Test func nextRowPicksTheSoonestFutureRowNotThePastOne() {
        let now = utcDate(2026, 7, 1)
        let past = StockSageEODHDCalendar.Row(code: "A", reportPeriod: nil, date: utcDate(2026, 6, 1),
                                              beforeAfterMarket: nil, estimate: nil, actual: nil)
        let soon = StockSageEODHDCalendar.Row(code: "A", reportPeriod: nil, date: utcDate(2026, 7, 30),
                                              beforeAfterMarket: nil, estimate: nil, actual: nil)
        let later = StockSageEODHDCalendar.Row(code: "A", reportPeriod: nil, date: utcDate(2026, 10, 30),
                                               beforeAfterMarket: nil, estimate: nil, actual: nil)
        let next = StockSageEODHDCalendar.nextRow([later, past, soon], now: now)
        #expect(next?.date == utcDate(2026, 7, 30))
    }

    @Test func nextRowIncludesARowExactlyAtNow() {
        let now = utcDate(2026, 7, 1)
        let row = StockSageEODHDCalendar.Row(code: "A", reportPeriod: nil, date: now,
                                             beforeAfterMarket: nil, estimate: nil, actual: nil)
        #expect(StockSageEODHDCalendar.nextRow([row], now: now) != nil)
    }

    // MARK: confirmed(for:) — documented rule: always false for a next-earnings row

    @Test func confirmedIsAlwaysFalseRegardlessOfActual() {
        let withActual = StockSageEODHDCalendar.Row(code: "A", reportPeriod: nil, date: utcDate(2026, 7, 30),
                                                    beforeAfterMarket: nil, estimate: nil, actual: 1.2)
        let withoutActual = StockSageEODHDCalendar.Row(code: "A", reportPeriod: nil, date: utcDate(2026, 7, 30),
                                                       beforeAfterMarket: nil, estimate: nil, actual: nil)
        #expect(StockSageEODHDCalendar.confirmed(for: withActual) == false)
        #expect(StockSageEODHDCalendar.confirmed(for: withoutActual) == false)
    }

    // MARK: parseEarningsHistory (fundamentals Earnings.History)

    @Test func parsesFundamentalsEarningsHistorySortedOldestFirst() {
        let json = """
        {"Earnings":{"History":{
          "2026-07-30":{"date":"2026-07-30","epsActual":1.5},
          "2026-04-25":{"date":"2026-04-25","epsActual":1.4}
        }}}
        """
        let dates = StockSageEODHDCalendar.parseEarningsHistory(Data(json.utf8))
        #expect(dates == [utcDate(2026, 4, 25), utcDate(2026, 7, 30)])
    }

    @Test func fundamentalsHistorySkipsEntriesMissingADate() {
        let json = """
        {"Earnings":{"History":{
          "2026-07-30":{"date":"2026-07-30"},
          "bad":{"epsActual":1.5},
          "alsoBad":"not an object"
        }}}
        """
        let dates = StockSageEODHDCalendar.parseEarningsHistory(Data(json.utf8))
        #expect(dates == [utcDate(2026, 7, 30)])
    }

    @Test func fundamentalsMissingEarningsHistoryParsesToEmpty() {
        #expect(StockSageEODHDCalendar.parseEarningsHistory(Data("{}".utf8)) == [])
        #expect(StockSageEODHDCalendar.parseEarningsHistory(Data(#"{"Earnings":{}}"#.utf8)) == [])
    }

    // MARK: - Plan-tier availability gate

    @Test func rejectionStatusesCloseTheGateForExactly24Hours() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for code in [401, 402, 403] {
            #expect(StockSageEODHDCalendar.availabilityOutcome(statusCode: code, now: now)
                    == now.addingTimeInterval(24 * 3600), "status \(code) must close the gate for 24h")
        }
    }

    @Test func nonRejectionStatusesLeaveTheGateOpen() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for code: Int? in [200, 404, 429, 500, 503, nil] {
            #expect(StockSageEODHDCalendar.availabilityOutcome(statusCode: code, now: now) == nil,
                    "status \(String(describing: code)) must NOT close the gate")
        }
    }

    // Genuine boundary straddle, hand-derived: unavailableUntil = t; t − 1s is still inside the
    // 24h window (unavailable); t itself (and beyond) is the instant `isAvailable`'s own `>=`
    // reopens the gate.
    @Test func isAvailableBoundaryStraddle() {
        let until = Date(timeIntervalSince1970: 1_700_086_400)
        let justBefore = until.addingTimeInterval(-1)
        #expect(!StockSageEODHDCalendar.isAvailable(unavailableUntil: until, now: justBefore),
                "1s before the window closes, the gate must still be shut")
        #expect(StockSageEODHDCalendar.isAvailable(unavailableUntil: until, now: until),
                "exactly at the window's end, the gate must reopen")
    }

    @Test func neverProbedOrNilUnavailableUntilIsAlwaysAvailable() {
        #expect(StockSageEODHDCalendar.isAvailable(unavailableUntil: nil, now: Date(timeIntervalSince1970: 0)))
    }
}
