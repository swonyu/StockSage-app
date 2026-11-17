import Foundation
import Testing
@testable import StockSage

@Suite("Parked portfolio widget valuation")
@MainActor
struct PortfolioWidgetTests {
    private func trade(_ symbol: String, entry: Double, shares: Double = 10,
                       side: TradeRecord.Side = .long) -> TradeRecord {
        TradeRecord(symbol: symbol, side: side, entry: entry, stop: entry * 0.9,
                    target: nil, shares: shares, openedAt: Date(timeIntervalSince1970: 1), denomination: SageFix.fixtureDenomination(for: symbol))
    }

    @Test("USD, SAR, pence, cents and an FX quote leg all convert before summing")
    func mixedBook() throws {
        let trades = [trade("AAPL", entry: 100), trade("2222.SR", entry: 30),
                      trade("VOD.L", entry: 100), trade("AGL.JO", entry: 100),
                      trade("EURUSD=X", entry: 1.1, shares: 100)]
        let entry = PortfolioEntry.make(date: .now, openTrades: trades, closedTrades: [],
            prices: ["AAPL": 110, "2222.SR": 33.75, "VOD.L": 150,
                     "AGL.JO": 200, "EURUSD=X": 1.2],
            ratesToUSD: ["USD": 99, "SAR": 1 / 3.75, "GBP": 1.25, "ZAR": 0.05, "EUR": 1.2], priceDenominations: Dictionary(uniqueKeysWithValues: (["AAPL": 110, "2222.SR": 33.75, "VOD.L": 150,
                     "AGL.JO": 200, "EURUSD=X": 1.2] as [String: Double]).keys.compactMap { symbol in SageFix.fixtureDenomination(for: symbol).map { (symbol, $0) } }))
        // 100 USD + 37.5 SAR / 3.75 + 500p / 100 * 1.25 + 1000c / 100 * .05 + 10 USD
        #expect(abs(try #require(entry.totalPnL) - 126.75) < 1e-9)
        #expect(entry.openPositions == 5)
        #expect(entry.pnlText == "≈+126.75 USD")
    }

    @Test("One position cannot appear as both best and worst")
    func onePosition() throws {
        let entry = PortfolioEntry.make(date: .now,
            openTrades: [trade("2222.SR", entry: 30, side: .short)], closedTrades: [],
            prices: ["2222.SR": 27], ratesToUSD: ["SAR": 1 / 3.75], priceDenominations: Dictionary(uniqueKeysWithValues: (["2222.SR": 27] as [String: Double]).keys.compactMap { symbol in SageFix.fixtureDenomination(for: symbol).map { (symbol, $0) } }))
        #expect(abs(try #require(entry.totalPnL) - 8) < 1e-9)
        #expect(entry.bestPerformer?.rMultiple == 1)
        #expect(entry.worstPerformer == nil)
    }

    @Test("Missing, invalid or overflowing FX never produces a partial USD total",
          arguments: [nil, 0.0, -1.0, Double.nan, Double.infinity, Double.greatestFiniteMagnitude] as [Double?])
    func missingFX(_ rate: Double?) {
        let entry = PortfolioEntry.make(date: .now,
            openTrades: [trade("AAPL", entry: 100), trade("2222.SR", entry: 30)], closedTrades: [],
            prices: ["AAPL": 110, "2222.SR": 40],
            ratesToUSD: rate.map { ["SAR": $0] } ?? [:], priceDenominations: Dictionary(uniqueKeysWithValues: (["AAPL": 110, "2222.SR": 40] as [String: Double]).keys.compactMap { symbol in SageFix.fixtureDenomination(for: symbol).map { (symbol, $0) } }))
        let total: Double? = entry.totalPnL
        #expect(total == nil)
        #expect(entry.pnlText == "Needs prices / FX")
    }

    @Test("An unknown quote cannot be replaced with entry price or ranked as zero R",
          arguments: [nil, 0.0, -1.0, Double.nan, Double.infinity] as [Double?])
    func missingPrice(_ price: Double?) {
        let entry = PortfolioEntry.make(date: .now, openTrades: [trade("AAPL", entry: 100)],
            closedTrades: [], prices: price.map { ["AAPL": $0] } ?? [:], ratesToUSD: [:],
            priceDenominations: ["AAPL": SageFix.fixtureDenomination(for: "AAPL")!])
        let total: Double? = entry.totalPnL
        #expect(total == nil)
        #expect(entry.bestPerformer == nil)
        #expect(entry.worstPerformer == nil)
    }

    @Test("An empty book is zero, while two measured positions retain best and worst")
    func emptyAndTwoPositions() {
        let empty = PortfolioEntry.make(date: .now, openTrades: [], closedTrades: [], prices: [:], ratesToUSD: [:], priceDenominations: Dictionary(uniqueKeysWithValues: ([:] as [String: Double]).keys.compactMap { symbol in SageFix.fixtureDenomination(for: symbol).map { (symbol, $0) } }))
        #expect(empty.totalPnL == 0)
        #expect(empty.openPositions == 0)
        #expect(empty.bestPerformer == nil)
        #expect(empty.worstPerformer == nil)
        let two = PortfolioEntry.make(date: .now,
            openTrades: [trade("AAPL", entry: 100), trade("MSFT", entry: 100)], closedTrades: [],
            prices: ["AAPL": 110, "MSFT": 90], ratesToUSD: [:], priceDenominations: Dictionary(uniqueKeysWithValues: (["AAPL": 110, "MSFT": 90] as [String: Double]).keys.compactMap { symbol in SageFix.fixtureDenomination(for: symbol).map { (symbol, $0) } }))
        #expect(two.totalPnL == 0)
        #expect(two.bestPerformer?.symbol == "AAPL")
        #expect(two.worstPerformer?.symbol == "MSFT")
    }

    @Test("Refresh uses held venues, extended sessions, DST and the exchange calendar",
          arguments: [
            ("2026-09-11T19:59:59Z", "AAPL", 900.0), // 15:59 EDT
            ("2026-09-11T23:59:59Z", "AAPL", 900.0), // after-hours
            ("2026-09-12T00:00:00Z", "AAPL", 3600.0),
            ("2026-01-12T14:30:00Z", "AAPL", 900.0), // 09:30 EST
            ("2026-09-07T14:00:00Z", "AAPL", 3600.0), // Labor Day
            ("2026-09-13T07:00:00Z", "2222.SR", 900.0), // Sunday 10:00 Riyadh
            ("2026-09-13T12:00:00Z", "2222.SR", 3600.0),
            ("2026-11-27T22:00:00Z", "AAPL", 3600.0) // early extended close, 17:00 EST
          ])
    func refreshClock(_ fixture: (String, String, Double)) throws {
        let date = try #require(ISO8601DateFormatter().date(from: fixture.0))
        #expect(PortfolioEntry.refreshInterval(at: date, symbols: [fixture.1]) == fixture.2)
    }
}
