import Testing
import Foundation
@testable import StockSage

// MARK: - Journal CSV export (pure)

struct StockSageJournalCSVTests {

    @Test func csvHasHeaderAndAnEscapedRow() {
        let t = TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90, target: 124, shares: 10,
                            openedAt: Date(timeIntervalSince1970: 0), exitPrice: 120,
                            closedAt: Date(timeIntervalSince1970: 86_400), note: "Bought dip, added size")
        let csv = StockSageJournalCSV.csv([t])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0] == StockSageJournalCSV.header)
        let row = lines[1]
        #expect(row.contains("AAPL,Long,100.0,90.0,124.0,10.0,"))
        #expect(row.contains("1970-01-01T00:00:00Z"))          // openedAt ISO8601 (UTC)
        #expect(row.contains(",2.0,"))                          // realizedR: (120−100)/(100−90)
        #expect(row.contains("\"Bought dip, added size\""))    // note with a comma is quoted
    }

    @Test func emptyOptionalsRenderAsEmptyFields() {
        let open = TradeRecord(symbol: "X", side: .short, entry: 50, stop: 55, target: nil, shares: 3,
                               openedAt: Date(timeIntervalSince1970: 0))   // open, no exit/close/note
        let row = StockSageJournalCSV.csv([open]).split(separator: "\n").map(String.init)[1]
        // target, exitPrice, closedAt, realizedR, note all empty → trailing commas.
        #expect(row.hasPrefix("X,Short,50.0,55.0,,3.0,1970-01-01T00:00:00Z,,,,"))
    }

    @Test func escapeFollowsRFC4180() {
        #expect(StockSageJournalCSV.escape("plain") == "plain")
        #expect(StockSageJournalCSV.escape("a,b") == "\"a,b\"")
        #expect(StockSageJournalCSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(StockSageJournalCSV.escape("line1\nline2") == "\"line1\nline2\"")
    }
}
