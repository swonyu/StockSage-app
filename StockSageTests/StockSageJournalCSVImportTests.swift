import Testing
import Foundation
@testable import StockSage

// MARK: - Journal CSV import (pure) — round-trips StockSageJournalCSV's export format.

struct StockSageJournalCSVImportTests {

    @MainActor @Test(arguments: ["\n", "\r", "\r\n"])
    func lineEndingsAndQuotedNotesRoundTripIntoIsolatedJournal(ending: String) throws {
        let suite = "stocksage-csv-lines-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = TradeRecord(symbol: "LINES", side: .long, entry: 100, stop: 90,
            target: nil, shares: 2, openedAt: Date(timeIntervalSince1970: 0),
            note: "first\(ending)second, قال \"انتظر\"")
        let row = String(try StockSageJournalCSV.csv([original]).dropFirst(StockSageJournalCSV.header.count + 1))
        let preview = StockSageJournalCSVImport.preview(StockSageJournalCSV.header + ending + row + ending)
        #expect(preview.errors.isEmpty)
        #expect(preview.imported == 1 && preview.skipped == 0)
        #expect(preview.trades.first?.note == original.note)
        let journal = StockSageJournalStore(defaults: defaults)
        let result = journal.importNew(preview.trades)
        #expect(result.added == 1 && result.rejected == 0)
        #expect(StockSageJournalStore(defaults: defaults).trades.first?.note == original.note)
    }

    @Test(arguments: ["\n", "\r", "\r\n"])
    func errorAfterMultilineNoteNamesThePhysicalFileLine(ending: String) throws {
        let original = TradeRecord(symbol: "LINES", side: .long, entry: 100, stop: 90,
            target: nil, shares: 2, openedAt: Date(timeIntervalSince1970: 0), note: "first\(ending)second")
        let row = String(try StockSageJournalCSV.csv([original]).dropFirst(StockSageJournalCSV.header.count + 1))
        let bad = "BAD,Long,-100,90,,2,1970-01-01T00:00:00Z,,,,"
        let preview = StockSageJournalCSVImport.preview(StockSageJournalCSV.header + ending + row + ending + bad)
        #expect(preview.imported == 1)
        #expect(preview.trades.first?.note == original.note)
        #expect(preview.errors.map(\.line) == [4]) // header=1, quoted record spans2–3, BAD=4
    }

    @Test(arguments: [100.0, 1e-6, 1e20])
    func exporterNumberNotationRoundTripsAllNumericFields(scale: Double) throws {
        let original = TradeRecord(symbol: "NUMBERS", side: .long, entry: scale, stop: scale / 2,
            target: scale * 2, shares: scale, openedAt: Date(timeIntervalSince1970: 0),
            exitPrice: scale * 1.1, closedAt: Date(timeIntervalSince1970: 60))
        let preview = StockSageJournalCSVImport.preview(try StockSageJournalCSV.csv([original]))
        #expect(preview.errors.isEmpty)
        #expect(preview.imported == 1)
        #expect(preview.trades.first?.entry == original.entry)
        #expect(preview.trades.first?.stop == original.stop)
        #expect(preview.trades.first?.target == original.target)
        #expect(preview.trades.first?.shares == original.shares)
        #expect(preview.trades.first?.exitPrice == original.exitPrice)
    }

    @Test func csvExponentSupportDoesNotWeakenNumericOrHumanInputGuards() {
        let fields = ["GUARDS", "Long", "100", "90", "120", "1", "1970-01-01T00:00:00Z",
                      "110", "1970-01-02T00:00:00Z", "", ""]
        for index in [2, 3, 4, 5, 7] {
            for value in ["NaN", "inf", "-1e2", "0e0", "1e309", "1e-999", "0x1p4", "1e2junk", "1e", "1,2e3"] {
                var row = fields; row[index] = value
                let preview = StockSageJournalCSVImport.preview(StockSageJournalCSV.header + "\n" + row.map(StockSageJournalCSV.escape).joined(separator: ","))
                #expect(preview.imported == 0 && preview.skipped == 0, "field \(index), token \(value)")
                #expect(preview.errors.count == 1)
            }
        }
        for (text, expected) in [("2E+3", 2000.0), (".5e2", 50.0), ("1,234.5", 1234.5), ("2,5", 2.5)] {
            var row = fields; row[2] = text
            let preview = StockSageJournalCSVImport.preview(StockSageJournalCSV.header + "\n" + row.map(StockSageJournalCSV.escape).joined(separator: ","))
            #expect(preview.trades.first?.entry == expected)
            #expect(preview.errors.isEmpty)
        }
        #expect(StockSageInput.positiveAmount("1e-6") == nil)
        #expect(StockSageInput.percent("1e1") == nil)
    }

    @MainActor @Test func inBatchDuplicatesDoNotCreateDuplicateJournalRecords() throws {
        let suite = "stocksage-csv-duplicates-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let csv = StockSageJournalCSV.header + "\n" +
            "AAPL,Long,100,90,,1,1970-01-01T00:00:00Z,110,,,invalid closure\n" +
            "AAPL,Long,100,90,,1,1970-01-01T00:00:00Z,,,,first valid\n" +
            "aapl,Long,100,90,,1,1970-01-01T00:00:45Z,,,,same minute\n" +
            "AAPL,Long,100,90,,1,1970-01-01T00:01:00Z,,,,next minute"
        let preview = StockSageJournalCSVImport.preview(csv)
        #expect(preview.imported == 2 && preview.skipped == 1)
        #expect(preview.errors.map(\.line) == [2]) // a rejected row must not reserve its dedup key
        let journal = StockSageJournalStore(defaults: defaults)
        let result = journal.importNew(preview.trades)
        #expect(result.added == 2 && result.rejected == 0)
        let reloaded = StockSageJournalStore(defaults: defaults)
        #expect(reloaded.trades.count == 2)
        let repeatPreview = StockSageJournalCSVImport.preview(csv, existing: reloaded.trades)
        #expect(repeatPreview.imported == 0 && repeatPreview.skipped == 3)
        #expect(repeatPreview.errors.map(\.line) == [2]) // invalid is not an intentional duplicate skip
    }

    @Test func incoherentClosureReportsRowErrorsAndKeepsTheValidRow() {
        let csv = StockSageJournalCSV.header + "\n" +
            "GOOD,Long,100,90,,1,1970-01-02T00:00:00Z,110,1970-01-03T00:00:00Z,,\n" +
            "EXIT_ONLY,Long,100,90,,1,1970-01-02T00:00:00Z,110,,,\n" +
            "CLOSE_ONLY,Long,100,90,,1,1970-01-02T00:00:00Z,,1970-01-03T00:00:00Z,,\n" +
            "INVERTED,Long,100,90,,1,1970-01-02T00:00:00Z,110,1970-01-01T00:00:00Z,,"
        let result = StockSageJournalCSVImport.preview(csv)
        #expect(result.trades.map(\.symbol) == ["GOOD"])
        #expect(result.imported == 1 && result.skipped == 0)
        #expect(result.errors.map(\.line) == [3, 4, 5])
    }

    @Test func roundTripsExportedTrades() throws {
        let trades = [
            TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90, target: 124, shares: 10,
                       openedAt: Date(timeIntervalSince1970: 0), exitPrice: 120,
                       closedAt: Date(timeIntervalSince1970: 86_400), note: "Bought dip, added size",
                       conviction: 0.72, plannedEntry: 99.5, entryFill: 100.4,
                       plannedExit: 121.0, exitFill: 119.6),
            TradeRecord(symbol: "X", side: .short, entry: 50, stop: 55, target: nil, shares: 3,
                       openedAt: Date(timeIntervalSince1970: 1_000)),   // open, no exit/close/note
        ]
        let csv = try StockSageJournalCSV.csv(trades)
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

        // CSV BOUNDARY (2026-09-11): the 11-column interchange format carries neither conviction
        // nor ANY of the four planned/fill prices, so a round trip loses all five. The fixture
        // pins come FIRST on purpose — a nil assertion passes whether or not the input ever held
        // a value, so without these the five nil pins below would be vacuous.
        #expect(trades[0].conviction == 0.72)
        #expect(trades[0].plannedEntry == 99.5 && trades[0].entryFill == 100.4)
        #expect(trades[0].plannedExit == 121.0 && trades[0].exitFill == 119.6)
        #expect(!csv.contains("0.72") && !csv.contains("99.5") && !csv.contains("100.4"))
        #expect(!csv.contains("121.0") && !csv.contains("119.6"))
        #expect(parsed[0].conviction == nil)
        #expect(parsed[0].plannedEntry == nil)
        #expect(parsed[0].entryFill == nil)
        #expect(parsed[0].plannedExit == nil)
        #expect(parsed[0].exitFill == nil)

        #expect(parsed[1].symbol == "X")
        #expect(parsed[1].side == .short)
        #expect(parsed[1].target == nil)
        #expect(parsed[1].exitPrice == nil)
        #expect(parsed[1].closedAt == nil)
        #expect(parsed[1].note == nil)
    }

    @Test func quotedCommaNoteRoundTrips() throws {
        let t = TradeRecord(symbol: "MSFT", side: .long, entry: 200, stop: 190, target: nil, shares: 5,
                            openedAt: Date(timeIntervalSince1970: 0), note: "Earnings beat, raised guidance")
        let csv = try StockSageJournalCSV.csv([t])
        #expect(csv.contains("\"Earnings beat, raised guidance\""))   // sanity: export really quotes it
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv)
        #expect(errors.isEmpty)
        #expect(parsed.count == 1)
        #expect(parsed[0].note == "Earnings beat, raised guidance")
    }

    @Test func quotedNewlineAndDoubledQuoteNoteRoundTrips() throws {
        let t = TradeRecord(symbol: "TSLA", side: .short, entry: 300, stop: 310, target: nil, shares: 2,
                            openedAt: Date(timeIntervalSince1970: 0), note: "Line one\nLine two, said \"sell\"")
        let csv = try StockSageJournalCSV.csv([t])
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

    @Test func duplicateOfExistingTradeIsFlaggedAndSkipped() throws {
        let opened = Date(timeIntervalSince1970: 0)
        let existing = TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90, target: nil,
                                   shares: 10, openedAt: opened)
        let csv = try StockSageJournalCSV.csv([TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90,
                                                        target: nil, shares: 10, openedAt: opened)])
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv, existing: [existing])
        #expect(parsed.isEmpty)
        #expect(errors.count == 1)
        #expect(errors[0].reason.contains("duplicate"))
    }

    @Test func duplicateMatchIsToTheMinuteNotToTheSecond() throws {
        let existingOpened = Date(timeIntervalSince1970: 0)
        let existing = TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90, target: nil,
                                   shares: 10, openedAt: existingOpened)
        // 45 seconds later — same MINUTE — should still be flagged a duplicate.
        let sameMinute = Date(timeIntervalSince1970: 45)
        let csv = try StockSageJournalCSV.csv([TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90,
                                                        target: nil, shares: 10, openedAt: sameMinute)])
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv, existing: [existing])
        #expect(parsed.isEmpty)
        #expect(errors.count == 1)
        #expect(errors[0].reason.contains("duplicate"))
    }

    @Test func differentTradeIsNotFlaggedAsDuplicate() throws {
        let opened = Date(timeIntervalSince1970: 0)
        let existing = TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90, target: nil,
                                   shares: 10, openedAt: opened)
        // Different symbol → not a duplicate.
        let csv = try StockSageJournalCSV.csv([TradeRecord(symbol: "MSFT", side: .long, entry: 100, stop: 90,
                                                        target: nil, shares: 10, openedAt: opened)])
        let (parsed, errors) = StockSageJournalCSVImport.parse(csv, existing: [existing])
        #expect(parsed.count == 1)
        #expect(errors.isEmpty)
    }

    // Semantics corrected WITH the 2026-07-16 review fix (not to make a failing test pass):
    // the old expectation `skipped == 1` pinned the conflation bug — a bad-number row (a
    // FAILURE, no duplicates present) counted as a "skipped duplicate" because preview()
    // set skipped = errors.count. Hand-derived: 1 good row imported, 1 malformed row
    // failed, 0 duplicates skipped.
    @Test func previewSummarizesImportedSkippedAndErrors() {
        let csv = StockSageJournalCSV.header + "\n" +
            "AAPL,Long,100,90,,10,1970-01-01T00:00:00Z,,,,\n" +
            "BAD,Long,abc,90,,10,1970-01-01T00:00:00Z,,,,"
        let preview = StockSageJournalCSVImport.preview(csv)
        #expect(preview.imported == 1)
        #expect(preview.skipped == 0)
        #expect(preview.errors.count == 1)
        #expect(preview.trades.count == 1)
    }

    // The partition itself: one duplicate (intentional skip) + one malformed row (failure)
    // must land in DISJOINT counts. Hand-derived: MSFT matches `existing`'s dupe key
    // (symbol/side/entry/shares/openedAt-to-the-minute) → skipped == 1; the abc-entry row
    // fails parsing → errors == 1 (and its reason is NOT the duplicate reason); AAPL imports.
    @Test func previewSeparatesDuplicatesFromFailures() {
        let existing = TradeRecord(symbol: "MSFT", side: .long, entry: 100, stop: 90,
                                   target: nil, shares: 10, openedAt: Date(timeIntervalSince1970: 0))
        let csv = StockSageJournalCSV.header + "\n" +
            "AAPL,Long,100,90,,10,1970-01-01T00:00:00Z,,,,\n" +
            "MSFT,Long,100,90,,10,1970-01-01T00:00:00Z,,,,\n" +
            "BAD,Long,abc,90,,10,1970-01-01T00:00:00Z,,,,"
        let preview = StockSageJournalCSVImport.preview(csv, existing: [existing])
        #expect(preview.imported == 1)
        #expect(preview.skipped == 1)
        #expect(preview.errors.count == 1)
        #expect(preview.errors.first?.reason != StockSageJournalCSVImport.duplicateReason)
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
