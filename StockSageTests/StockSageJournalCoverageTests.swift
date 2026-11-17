import Foundation
import Testing
@testable import StockSage

// Independently calculated synthetic records only. No store, provider, account or network.
struct StockSageJournalCoverageTests {
    private func closed(entry: Double = 100, stop: Double = 90, shares: Double = 1,
                        exit: Double = 110, side: TradeRecord.Side = .long,
                        currency: String? = "USD", year: Int = 2026, month: Int = 6,
                        symbol: String = "PERSONAL") -> TradeRecord {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let close = calendar.date(from: DateComponents(year: year, month: month, day: 15))!
        let unit = currency.flatMap {
            StockSagePriceDenomination(currencyCode: $0, rawUnitsPerMajor: .major,
                                       provenance: .manualEntry)
        }
        return TradeRecord(symbol: symbol, side: side, entry: entry, stop: stop,
                           target: nil, shares: shares, openedAt: close.addingTimeInterval(-60),
                           exitPrice: exit, closedAt: close, denomination: unit)
    }

    @Test func unavailableProfitCannotBecomeAnApparentlyCompleteMonetaryTotal() {
        // Entry notional 1e308 is finite. (3 - 1) * 1e308 overflows, but R = 4.
        let huge = closed(entry: 1, stop: 0.5, shares: 1e308, exit: 3)
        let ordinary = closed() // $10 and +1R, independently from (110 - 100).
        #expect(huge.isFinalized && (huge.entry * huge.shares).isFinite)
        #expect(huge.realizedProfit == nil && huge.realizedR == 4)
        #expect(ordinary.realizedProfit == 10 && ordinary.realizedR == 1)
        let summary = StockSageJournal.stats([huge, ordinary])
        #expect(summary.closed == 2 && summary.wins == 1)
        #expect(summary.closedWithProfit == 1 && summary.closedWithMajorProfit == 1)
        #expect(summary.totalProfit.isNaN && summary.winRate.isNaN)
        #expect(summary.profitCurrency == "USD") // Known identity is not erased by failed arithmetic.
        #expect(summary.closedWithR == 2 && summary.totalR == 5 && summary.avgR == 2.5)
        #expect(summary.hasCompleteRCoverage && !summary.hasCompleteProfitCoverage)
        #expect(summary.profitUnavailableReason?.contains("1 of 2") == true)
        #expect(summary.rUnavailableReason == nil && !summary.hasFiniteAggregates)
    }

    @Test func unavailableRDoesNotEraseIndependentlyAvailableMoneyAndWinRate() {
        // Profit is finite at 1e308; dividing by the 0.5 stop risk overflows R.
        let huge = closed(entry: 1, stop: 0.5, exit: 1e308)
        #expect(huge.realizedProfit == 1e308 && huge.realizedR == nil)
        let summary = StockSageJournal.stats([huge, closed()])
        #expect(summary.closed == 2 && summary.closedWithProfit == 2 && summary.wins == 2)
        #expect(summary.closedWithMajorProfit == 2 && summary.winRate == 1)
        #expect(summary.totalProfit == 1e308 && summary.profitCurrency == "USD")
        #expect(summary.closedWithR == 1 && summary.totalR.isNaN && summary.avgR.isNaN)
        #expect(summary.profitUnavailableReason == nil)
        #expect(summary.rUnavailableReason?.contains("1 of 2") == true)
    }

    @Test func allUnavailableOutcomesRemainDifferentFromAnEmptyJournal() {
        let huge = closed(entry: 1, stop: 0.5, shares: 1e308, exit: 1e308)
        #expect(huge.isFinalized && huge.realizedProfit == nil && huge.realizedR == nil)
        let present = StockSageJournal.stats([huge])
        #expect(present.closed == 1 && present.closedWithProfit == 0 && present.closedWithR == 0)
        #expect(present.totalProfit.isNaN && present.winRate.isNaN)
        #expect(present.totalR.isNaN && present.avgR.isNaN)
        #expect(present.profitUnavailableReason != nil && present.rUnavailableReason != nil)
        let empty = StockSageJournal.stats([])
        #expect(empty.closed == 0 && empty.wins == 0 && empty.winRate == 0)
        #expect(empty.totalProfit == 0 && empty.totalR == 0 && empty.avgR == 0)
        #expect(empty.profitCurrency == nil && empty.profitUnavailableReason == nil)
        #expect(empty.rUnavailableReason == nil && empty.hasFiniteAggregates)
        #expect(StockSageJournal.yearlyPnL([]).isEmpty)
        #expect(StockSageJournal.systemHealth([]) == nil)
    }

    @Test func zeroRiskLegacyRecordKeepsMoneyButCannotDefineWholeJournalR() {
        let legacy = closed(entry: 100, stop: 100, exit: 110)
        #expect(legacy.isFinalized && legacy.realizedProfit == 10 && legacy.realizedR == nil)
        let summary = StockSageJournal.stats([legacy, closed()])
        #expect(summary.closed == 2 && summary.closedWithProfit == 2 && summary.totalProfit == 20)
        #expect(summary.winRate == 1 && summary.closedWithR == 1)
        #expect(summary.totalR.isNaN && summary.avgR.isNaN)
        #expect(summary.rUnavailableReason?.contains("undefined") == true)
    }

    @Test func eachYearRequiresItsOwnCompleteMoneyAndRPopulation() throws {
        let huge = closed(entry: 1, stop: 0.5, shares: 1e308, exit: 3, year: 2025)
        let records = [huge, closed(year: 2025), closed(year: 2026)]
        let years = StockSageJournal.yearlyPnL(records)
        #expect(years.map(\.year) == ["2026", "2025"])
        let older = try #require(years.last)
        #expect(older.trades == 2 && older.wins == 1 && older.closedWithProfit == 1)
        #expect(older.realizedDollars.isNaN && older.winRate.isNaN)
        #expect(older.profitCurrency == "USD" && older.closedWithR == 2 && older.totalR == 5)
        #expect(older.profitUnavailableReason?.contains("1 of 2") == true)
        #expect(older.rUnavailableReason == nil)
        let newer = try #require(years.first)
        #expect(newer.trades == 1 && newer.realizedDollars == 10 && newer.totalR == 1)
        #expect(newer.winRate == 1 && newer.closedWithProfit == 1 && newer.closedWithR == 1)
        #expect(newer.profitUnavailableReason == nil && newer.rUnavailableReason == nil)
    }

    @Test func yearlyRFailureDoesNotHideKnownMoneyOrInventZeroR() throws {
        let huge = closed(entry: 1, stop: 0.5, exit: 1e308)
        let year = try #require(StockSageJournal.yearlyPnL([huge, closed()]).first)
        #expect(year.trades == 2 && year.closedWithProfit == 2 && year.closedWithR == 1)
        #expect(year.realizedDollars == 1e308 && year.profitCurrency == "USD" && year.winRate == 1)
        #expect(year.totalR.isNaN && year.rUnavailableReason != nil)
    }

    @Test func unknownCurrencyDoesNotInvalidateRawWinRateOrCompleteR() {
        let summary = StockSageJournal.stats([closed(currency: nil), closed()])
        #expect(summary.closed == 2 && summary.closedWithProfit == 2 && summary.closedWithMajorProfit == 1)
        #expect(summary.winRate == 1 && summary.totalR == 2 && summary.avgR == 1)
        #expect(summary.profitCurrency == nil && summary.totalProfit.isNaN)
        #expect(summary.profitUnavailableReason?.contains("currency or unit is unknown") == true)
        #expect(summary.rUnavailableReason == nil)
    }

    @Test func mixedCurrenciesRetainCompleteRawOutcomeCoverageWithoutSummingMoney() {
        let summary = StockSageJournal.stats([closed(currency: "USD"), closed(currency: "EUR")])
        #expect(summary.closedWithProfit == 2 && summary.closedWithMajorProfit == 2)
        #expect(summary.totalProfit.isNaN && summary.profitCurrency == nil)
        #expect(summary.winRate == 1 && summary.totalR == 2 && summary.avgR == 1)
        #expect(summary.profitUnavailableReason?.contains("different currencies") == true)
    }

    @Test func finiteIndividualProfitsCanStillOverflowOnlyTheirMonetarySum() {
        let record = closed(entry: 1, stop: 0.5, shares: 1e308, exit: 2)
        #expect(record.realizedProfit == 1e308 && record.realizedR == 2)
        let other = closed(entry: 1, stop: 0.5, shares: 1e308, exit: 2)
        #expect(record.id != other.id)
        let summary = StockSageJournal.stats([record, other])
        #expect(summary.closed == 2 && summary.closedWithProfit == 2 && summary.closedWithMajorProfit == 2)
        #expect(summary.winRate == 1 && summary.totalR == 4 && summary.avgR == 2)
        #expect(summary.totalProfit.isNaN && summary.profitCurrency == "USD")
        #expect(summary.profitUnavailableReason?.contains("sum cannot be represented") == true)
    }

    @Test func nonzeroProfitUnderflowDoesNotBecomeAFabricatedBreakEvenOutcome() {
        let tiny = closed(entry: 1, stop: 0.5, shares: Double.leastNonzeroMagnitude, exit: 1.5)
        // Positive half of the smallest representable amount cannot be represented.
        #expect(tiny.isFinalized && tiny.entry * tiny.shares > 0)
        #expect(tiny.realizedProfit == nil && tiny.realizedR == 1)
        let summary = StockSageJournal.stats([tiny])
        #expect(summary.closed == 1 && summary.totalProfit.isNaN && summary.winRate.isNaN)
        #expect(summary.totalR == 1 && summary.avgR == 1)
    }

    @Test func nonzeroRUnderflowKeepsTheLossAndWithholdsAnInventedZeroR() {
        let tiny = closed(entry: 1e-300, stop: 1e308, exit: 2e-300, side: .short)
        #expect(tiny.isFinalized && tiny.realizedProfit == -1e-300 && tiny.realizedR == nil)
        let summary = StockSageJournal.stats([tiny])
        #expect(summary.closedWithProfit == 1 && summary.winRate == 0 && summary.totalProfit == -1e-300)
        #expect(summary.totalR.isNaN && summary.avgR.isNaN && summary.closedWithR == 0)
    }

    @Test func systemHealthCannotCertifyOnlyTheRepresentableRSubset() throws {
        let ordinary = (0..<20).map { _ in closed() }
        let incomplete = ordinary + [closed(entry: 1, stop: 0.5, exit: 1e308)]
        let assessment = try #require(StockSageJournal.systemHealth(incomplete))
        #expect(assessment.verdict == .unproven)
        #expect(assessment.reason.contains("unavailable") && assessment.reason.contains("20 of 21"))
        let missingAll = try #require(StockSageJournal.systemHealth([closed(entry: 100, stop: 100)]))
        #expect(missingAll.verdict == .unproven && missingAll.reason.contains("0 of 1"))
        let complete = try #require(StockSageJournal.systemHealth(ordinary))
        #expect(complete.verdict == .strong)
    }

    @Test func invalidClosureAndUnrepresentableOutcomesKeepTheirOriginalEncodedRecords() throws {
        var invalid = closed()
        invalid.exitPrice = nil // Keep the invalid legacy pair as evidence, outside finalized totals.
        let records = [invalid, closed(entry: 1, stop: 0.5, shares: 1e308, exit: 3)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(records)
        let restored = try JSONDecoder().decode([TradeRecord].self, from: original)
        #expect(restored == records && restored[0].closureError != nil)
        let summary = StockSageJournal.stats(restored)
        #expect(summary.closed == 1 && summary.totalProfit.isNaN && summary.totalR == 4)
        #expect(try encoder.encode(restored) == original)
        #expect(StockSageJournal.formattedFinite(summary.winRate * 100, format: "%.0f%%") == "Unavailable")
    }

    @Test func monthlyTotalsCannotBorrowCoverageFromAnotherMonth() throws {
        let missingR = closed(entry: 1, stop: 0.5, exit: 1e308)
        let months = StockSageJournal.monthlyPnL([missingR, closed(), closed(month: 5)])
        #expect(months.map(\.month) == ["2026-06", "2026-05"])
        let june = try #require(months.first)
        #expect(june.trades == 2 && june.closedWithR == 1 && june.totalR.isNaN)
        let may = try #require(months.last)
        #expect(may.trades == 1 && may.closedWithR == 1 && may.totalR == 1)
        let noR = try #require(StockSageJournal.monthlyPnL([closed(stop: 100)]).first)
        #expect(noR.trades == 1 && noR.closedWithR == 0 && noR.totalR.isNaN)
        #expect(StockSageJournal.monthlyPnL([]).isEmpty)
    }

    @Test func sideWinRateCannotTreatUnrepresentableProfitAsALoss() throws {
        let huge = closed(entry: 1, stop: 0.5, shares: 1e308, exit: 3)
        let short = closed(stop: 110, exit: 90, side: .short)
        let sides = StockSageJournal.bySide([huge, closed(), short])
        let long = try #require(sides.first { $0.side == .long })
        #expect(long.trades == 2 && long.wins == 1 && long.closedWithProfit == 1)
        #expect(long.winRate.isNaN && long.closedWithR == 2 && long.totalR == 5 && long.avgR == 2.5)
        let shortRow = try #require(sides.first { $0.side == .short })
        #expect(shortRow.trades == 1 && shortRow.closedWithProfit == 1 && shortRow.winRate == 1)
        #expect(shortRow.closedWithR == 1 && shortRow.totalR == 1 && shortRow.avgR == 1)
    }

    @Test func sectorWinRateRequiresItsOwnCompleteRawProfitPopulation() throws {
        let huge = closed(entry: 1, stop: 0.5, shares: 1e308, exit: 3, symbol: "AAPL")
        let sectors = StockSageJournal.bySector([huge, closed(symbol: "MSFT"), closed(symbol: "JPM")])
        let tech = try #require(sectors.first { $0.sector == "Technology" })
        #expect(tech.trades == 2 && tech.wins == 1 && tech.closedWithProfit == 1)
        #expect(tech.winRate.isNaN && tech.closedWithR == 2 && tech.totalR == 5)
        let finance = try #require(sectors.first { $0.sector == "Financials" })
        #expect(finance.trades == 1 && finance.closedWithProfit == 1 && finance.winRate == 1)
        #expect(finance.closedWithR == 1 && finance.totalR == 1)
    }

    @Test func sideAndSectorRSubsetsKeepExplicitCoverageAndNoEmptySampleZero() throws {
        let noR = closed(stop: 100, symbol: "AAPL")
        let ordinary = closed(symbol: "MSFT")
        let side = try #require(StockSageJournal.bySide([noR, ordinary]).first)
        #expect(side.trades == 2 && side.closedWithR == 1 && side.totalR == 1 && side.avgR == 1)
        #expect(side.closedWithProfit == 2 && side.winRate == 1)
        let sector = try #require(StockSageJournal.bySector([noR, ordinary]).first)
        #expect(sector.trades == 2 && sector.closedWithR == 1 && sector.totalR == 1)
        #expect(sector.closedWithProfit == 2 && sector.winRate == 1)
        let emptySide = try #require(StockSageJournal.bySide([noR]).first)
        let emptySector = try #require(StockSageJournal.bySector([noR]).first)
        #expect(emptySide.closedWithR == 0 && emptySide.totalR.isNaN && emptySide.avgR.isNaN)
        #expect(emptySector.closedWithR == 0 && emptySector.totalR.isNaN)
        #expect(StockSageJournal.bySide([]).isEmpty && StockSageJournal.bySector([]).isEmpty)
    }

    @Test func bucketCoverageHandlesUnderflowAndMixedCurrenciesIndependently() throws {
        let tiny = closed(entry: 1, stop: 0.5, shares: Double.leastNonzeroMagnitude,
                          exit: 1.5, symbol: "AAPL")
        let known = closed(currency: "EUR", symbol: "MSFT")
        let side = try #require(StockSageJournal.bySide([tiny, known]).first)
        let sector = try #require(StockSageJournal.bySector([tiny, known]).first)
        #expect(side.closedWithProfit == 1 && side.winRate.isNaN && side.closedWithR == 2 && side.totalR == 2)
        #expect(sector.closedWithProfit == 1 && sector.winRate.isNaN && sector.closedWithR == 2 && sector.totalR == 2)
        let mixedSide = try #require(StockSageJournal.bySide([closed(currency: "USD"), closed(currency: "EUR")]).first)
        #expect(mixedSide.closedWithProfit == 2 && mixedSide.winRate == 1)
        #expect(mixedSide.closedWithR == 2 && mixedSide.totalR == 2 && mixedSide.avgR == 1)
        let mixedSector = try #require(StockSageJournal.bySector([
            closed(currency: "USD", symbol: "AAPL"), closed(currency: "EUR", symbol: "MSFT")]).first)
        #expect(mixedSector.closedWithProfit == 2 && mixedSector.winRate == 1)
        #expect(mixedSector.closedWithR == 2 && mixedSector.totalR == 2)
    }
}
