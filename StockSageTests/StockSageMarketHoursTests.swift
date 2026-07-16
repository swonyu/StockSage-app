import Testing
import Foundation
@testable import StockSage

// MARK: - Dual-market session clock tests (pure, deterministic)
//
// Fixtures are hand-derived UTC instants (via Python zoneinfo, independent of the Swift
// engine under test — see the task's derivation), NOT read back from StockSageMarketHours.
// Each local wall-clock instant below was converted to UTC offline:
//   Riyadh  Sun 2026-07-19 11:00 AST (+03:00) -> 2026-07-19 08:00 UTC
//   Riyadh  Fri 2026-07-17 11:00 AST (+03:00) -> 2026-07-17 08:00 UTC
//   Riyadh  Sun 2026-07-19 15:05 AST (+03:00) -> 2026-07-19 12:05 UTC
//   NY      Tue 2026-07-21 10:00 EDT (-04:00) -> 2026-07-21 14:00 UTC
//   NY      Sat 2026-07-25 12:00 EDT (-04:00) -> 2026-07-25 16:00 UTC
//   NY      Tue 2026-07-21 04:30 EDT (-04:00) -> 2026-07-21 08:30 UTC
struct StockSageMarketHoursTests {
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h; comps.minute = mi
        return Self.utcCalendar.date(from: comps)!
    }

    // MARK: Tadawul

    @Test func sundayElevenAMRiyadhIsOpen() {
        let date = utc(2026, 7, 19, 8, 0) // Sun 11:00 AST
        let state = StockSageMarketHours.tadawulState(at: date, calendar: Self.utcCalendar)
        #expect(state.phase == .open)
        #expect(state.market == .tadawul)
    }

    @Test func fridayIsClosedAllDay() {
        let date = utc(2026, 7, 17, 8, 0) // Fri 11:00 AST
        let state = StockSageMarketHours.tadawulState(at: date, calendar: Self.utcCalendar)
        #expect(state.phase == .closed)
        #expect(state.phaseLabel.lowercased().contains("weekend"))
    }

    @Test func fiveMinutesAfterCloseIsClosingAuction() {
        let date = utc(2026, 7, 19, 12, 5) // Sun 15:05 AST
        let state = StockSageMarketHours.tadawulState(at: date, calendar: Self.utcCalendar)
        #expect(state.phase == .closingAuction)
    }

    @Test func tadawulCaveatIsAlwaysPresentAndHonest() {
        let date = utc(2026, 7, 19, 8, 0)
        let state = StockSageMarketHours.tadawulState(at: date, calendar: Self.utcCalendar)
        #expect(!state.caveat.isEmpty)
        #expect(state.caveat.lowercased().contains("holiday"))
    }

    @Test func tadawulNextTransitionIsAfterNow() throws {
        let date = utc(2026, 7, 17, 8, 0) // Friday, closed
        let state = StockSageMarketHours.tadawulState(at: date, calendar: Self.utcCalendar)
        let next = try #require(state.nextTransition)
        #expect(next > date)
    }

    // MARK: NASDAQ

    @Test func tuesdayTenAMETIsOpen() {
        let date = utc(2026, 7, 21, 14, 0) // Tue 10:00 EDT
        let state = StockSageMarketHours.nasdaqState(at: date, calendar: Self.utcCalendar)
        #expect(state.phase == .open)
        #expect(state.market == .nasdaq)
    }

    @Test func saturdayIsClosedAllDay() {
        let date = utc(2026, 7, 25, 16, 0) // Sat 12:00 EDT
        let state = StockSageMarketHours.nasdaqState(at: date, calendar: Self.utcCalendar)
        #expect(state.phase == .closed)
        #expect(state.phaseLabel.lowercased().contains("weekend"))
    }

    @Test func fourThirtyAMETIsPreMarket() {
        let date = utc(2026, 7, 21, 8, 30) // Tue 4:30 EDT
        let state = StockSageMarketHours.nasdaqState(at: date, calendar: Self.utcCalendar)
        #expect(state.phase == .preMarket)
    }

    @Test func nasdaqCaveatNamesTheMissingHolidayTable() {
        let date = utc(2026, 7, 21, 14, 0)
        let state = StockSageMarketHours.nasdaqState(at: date, calendar: Self.utcCalendar)
        #expect(!state.caveat.isEmpty)
        #expect(state.caveat.lowercased().contains("holiday"))
    }

    @Test func nasdaqNextTransitionIsAfterNow() throws {
        let date = utc(2026, 7, 21, 14, 0) // Tue open
        let state = StockSageMarketHours.nasdaqState(at: date, calendar: Self.utcCalendar)
        let next = try #require(state.nextTransition)
        #expect(next > date)
    }
}
