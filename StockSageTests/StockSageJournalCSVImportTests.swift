import Testing
import Foundation
@testable import StockSage

// MARK: - Journal CSV import (pure) — round-trips StockSageJournalCSV's export format.

struct StockSageJournalCSVImportTests {

    @Test func roundTripsExportedTrades() {
        let trades = [
            TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90, target: 124, shares: 10,
                       openedAt: Date(timeIntervalSince1970: 0), exitPrice: 120,
                       closedAt: Date(timeIntervalSince1970: 86_400), note: "Bought dip, added size"),
            TradeRecord(symbol: "X", side: .short, entry: 50, stop: 55, target: nil, shares: 3,
                       openedAt: Date(timeIntervalSince1970: 1_000)),   // open, no exit/close/note
        ]
        let csv = StockSageJournalCSV.csv(trades)
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv)

        #expect(errors.isEmpty)
        #expect(parsed.count == 2)

        #expect(parsed[0].symbol == "AAPL")
        #expect(parsed[0].side == .long)
        #expect(parsed[0].entry == 100)
        #expect(parsed[0].stop == 90)
        #expect(parsed[0].target == 124)
        #expect(parsed[0].shares == 10)
        #expect(parsed[0].openedAt == Date(timeIntervalSince1970: 0))
        #expect(parsed[0].exitPrice == 120)
        #expect(parsed[0].closedAt == Date(timeIntervalSince1970: 86_400))
        #expect(parsed[0].note == "Bought dip, added size")
        #expect(parsed[0].realizedR == 2.0)          // derived, matches the export's realizedR column
        #expect(parsed[0].id != trades[0].id)         // new UUID on import

        #expect(parsed[1].symbol == "X")
        #expect(parsed[1].side == .short)
        #expect(parsed[1].target == nil)
        #expect(parsed[1].exitPrice == nil)
        #expect(parsed[1].closedAt == nil)
        #expect(parsed[1].note == nil)
    }

    @Test func quotedCommaNoteRoundTrips() {
        let t = TradeRecord(symbol: "MSFT", side: .long, entry: 200, stop: 190, target: nil, shares: 5,
                            openedAt: Date(timeIntervalSince1970: 0), note: "Earnings beat, raised guidance")
        let csv = StockSageJournalCSV.csv([t])
        #expect(csv.contains("\"Earnings beat, raised guidance\""))   // sanity: export really quotes it
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv)
        #expect(errors.isEmpty)
        #expect(parsed.count == 1)
        #expect(parsed[0].note == "Earnings beat, raised guidance")
    }

    @Test func quotedNewlineAndDoubledQuoteNoteRoundTrips() {
        let t = TradeRecord(symbol: "TSLA", side: .short, entry: 300, stop: 310, target: nil, shares: 2,
                            openedAt: Date(timeIntervalSince1970: 0), note: "Line one\nLine two, said \"sell\"")
        let csv = StockSageJournalCSV.csv([t])
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv)
        #expect(errors.isEmpty)
        #expect(parsed.count == 1)
        #expect(parsed[0].note == "Line one\nLine two, said \"sell\"")
    }

    @Test func mismatchedHeaderIsOneClearError() {
        let bad = "symbol,side,entry\nAAPL,Long,100"
        let (parsed, errors) = StockSageJournalCSVImport.parse(bad)
        #expect(parsed.isEmpty)
        #expect(errors.count == 1)
        #expect(errors[0].line == 1)
        #expect(errors[0].reason.contains("header"))
    }

    @Test func badNumericFieldProducesRowErrorNotSilentDrop() {
        let csv = StockSageJournalCSV.header + "\n" +
            "AAPL,Long,abc,90,,10,1970-01-01T00:00:00Z,,,,note"
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv)
        #expect(parsed.isEmpty)
        #expect(errors.count == 1)
        #expect(errors[0].line == 2)
        #expect(errors[0].reason.contains("entry"))
    }

    @Test func negativeEntryIsRejected() {
        let csv = StockSageJournalCSV.header + "\n" +
            "AAPL,Long,-100,90,,10,1970-01-01T00:00:00Z,,,,"
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv)
        #expect(parsed.isEmpty)
        #expect(errors.count == 1)
        #expect(errors[0].reason.contains("entry"))
    }

    @Test func infAndNanAreRejected() {
        let csvInf = StockSageJournalCSV.header + "\n" +
            "AAPL,Long,inf,90,,10,1970-01-01T00:00:00Z,,,,"
        let (parsedInf, errorsInf) = StockSageJournalCSVImport.parse(csvInf)
        #expect(parsedInf.isEmpty)
        #expect(errorsInf.count == 1)

        let csvNan = StockSageJournalCSV.header + "\n" +
            "AAPL,Long,nan,90,,10,1970-01-01T00:00:00Z,,,,"
        let (parsedNan, errorsNan) = StockSageJournalCSVImport.parse(csvNan)
        #expect(parsedNan.isEmpty)
        #expect(errorsNan.count == 1)
    }

    @Test func invalidSideIsRejected() {
        let csv = StockSageJournalCSV.header + "\n" +
            "AAPL,Sideways,100,90,,10,1970-01-01T00:00:00Z,,,,"
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv)
        #expect(parsed.isEmpty)
        #expect(errors.count == 1)
        #expect(errors[0].reason.contains("side"))
    }

    @Test func invalidDateIsRejected() {
        let csv = StockSageJournalCSV.header + "\n" +
            "AAPL,Long,100,90,,10,not-a-date,,,,"
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv)
        #expect(parsed.isEmpty)
        #expect(errors.count == 1)
        #expect(errors[0].reason.contains("openedAt"))
    }

    @Test func wrongColumnCountIsRejected() {
        let csv = StockSageJournalCSV.header + "\n" + "AAPL,Long,100,90"
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv)
        #expect(parsed.isEmpty)
        #expect(errors.count == 1)
        #expect(errors[0].reason.contains("11 columns"))
    }

    @Test func oneBadRowDoesNotDropGoodRows() {
        let csv = StockSageJournalCSV.header + "\n" +
            "AAPL,Long,100,90,,10,1970-01-01T00:00:00Z,,,,\n" +
            "BAD,Long,abc,90,,10,1970-01-01T00:00:00Z,,,,\n" +
            "MSFT,Short,50,55,,5,1970-01-01T00:00:00Z,,,,"
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv)
        #expect(parsed.count == 2)
        #expect(parsed.map(\.symbol) == ["AAPL", "MSFT"])
        #expect(errors.count == 1)
        #expect(errors[0].line == 3)   // header=1, AAPL=2, BAD=3
    }

    @Test func duplicateOfExistingTradeIsFlaggedAndSkipped() {
        let opened = Date(timeIntervalSince1970: 0)
        let existing = TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90, target: nil,
                                   shares: 10, openedAt: opened)
        let csv = StockSageJournalCSV.csv([TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90,
                                                        target: nil, shares: 10, openedAt: opened)])
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv, existing: [existing])
        #expect(parsed.isEmpty)
        #expect(errors.count == 1)
        #expect(errors[0].reason.contains("duplicate"))
    }

    @Test func duplicateMatchIsToTheMinuteNotToTheSecond() {
        let existingOpened = Date(timeIntervalSince1970: 0)
        let existing = TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90, target: nil,
                                   shares: 10, openedAt: existingOpened)
        // 45 seconds later — same MINUTE — should still be flagged a duplicate.
        let sameMinute = Date(timeIntervalSince1970: 45)
        let csv = StockSageJournalCSV.csv([TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90,
                                                        target: nil, shares: 10, openedAt: sameMinute)])
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv, existing: [existing])
        #expect(parsed.isEmpty)
        #expect(errors.count == 1)
        #expect(errors[0].reason.contains("duplicate"))
    }

    @Test func differentTradeIsNotFlaggedAsDuplicate() {
        let opened = Date(timeIntervalSince1970: 0)
        let existing = TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90, target: nil,
                                   shares: 10, openedAt: opened)
        // Different symbol → not a duplicate.
        let csv = StockSageJournalCSV.csv([TradeRecord(symbol: "MSFT", side: .long, entry: 100, stop: 90,
                                                        target: nil, shares: 10, openedAt: opened)])
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv, existing: [existing])
        #expect(parsed.count == 1)
        #expect(errors.isEmpty)
    }

    @Test func previewSummarizesImportedSkippedAndErrors() {
        let csv = StockSageJournalCSV.header + "\n" +
            "AAPL,Long,100,90,,10,1970-01-01T00:00:00Z,,,,\n" +
            "BAD,Long,abc,90,,10,1970-01-01T00:00:00Z,,,,"
        let preview = StockSageJournalCSVImport.preview(csv)
        #expect(preview.imported == 1)
        #expect(preview.skipped == 1)
        #expect(preview.errors.count == 1)
        #expect(preview.trades.count == 1)
    }

    @Test func targetAndExitPriceRejectNonPositive() {
        let badTarget = StockSageJournalCSV.header + "\n" +
            "AAPL,Long,100,90,0,10,1970-01-01T00:00:00Z,,,,"
        let (p1, e1) = StockSageJournalCSVImport.parse(badTarget)
        #expect(p1.isEmpty); #expect(e1.count == 1); #expect(e1[0].reason.contains("target"))

        let badExit = StockSageJournalCSV.header + "\n" +
            "AAPL,Long,100,90,,10,1970-01-01T00:00:00Z,-5,1970-01-02T00:00:00Z,,"
        let (p2, e2) = StockSageJournalCSVImport.parse(badExit)
        #expect(p2.isEmpty); #expect(e2.count == 1); #expect(e2[0].reason.contains("exitPrice"))
    }

    @Test func blankSymbolIsRejected() {
        let csv = StockSageJournalCSV.header + "\n" +
            ",Long,100,90,,10,1970-01-01T00:00:00Z,,,,"
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv)
        #expect(parsed.isEmpty)
        #expect(errors.count == 1)
        #expect(errors[0].reason.contains("symbol"))
    }

    @Test func emptyFileProducesOneError() {
        let (parsed, errors) = StockSageJournalCSVImport.parse("")
        #expect(parsed.isEmpty)
        #expect(errors.count == 1)
    }
}
