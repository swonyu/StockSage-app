import Testing
import Foundation
@testable import StockSage

// MARK: - Portfolio heat (pure)

struct StockSagePortfolioHeatTests {
    typealias H = StockSagePortfolioHeat

    @Test func sumsOpenRiskAndLevels() {
        // 10·|100−95| + 5·|200−180| = 50 + 100 = 150 on a 10k account → 1.5% → cool.
        let h = H.compute(openTrades: [(10, 100, 95), (5, 200, 180)], accountSize: 10_000)!
        #expect(abs(h.dollarsAtRisk - 150) < 1e-9)
        #expect(abs(h.heatPct - 0.015) < 1e-9)
        #expect(h.level == .cool && h.openCount == 2)
        #expect(h.percentageText == "1.5")
        #expect(!h.verdict.contains("room to add"))
    }

    @Test func warmAndHotBands() {
        // 7% → warm.
        #expect(H.compute(openTrades: [(70, 100, 90)], accountSize: 10_000)!.level == .warm)   // 70·10=700 → 7%
        // 12% → hot.
        let hot = H.compute(openTrades: [(120, 100, 90)], accountSize: 10_000)!                 // 120·10=1200 → 12%
        #expect(hot.level == .hot)
        #expect(hot.percentageText == "12.0")
        #expect(hot.verdict.contains("planned stop risk"))
        #expect(hot.caveat.lowercased().contains("gap"))
    }

    @Test func guardsAndEmpties() {
        #expect(H.compute(openTrades: [], accountSize: 10_000)?.dollarsAtRisk == 0)   // no trades → 0% heat (valid)
        #expect(H.compute(openTrades: [], accountSize: 10_000)?.level == .cool)
        #expect(H.compute(openTrades: [(10, 100, 95)], accountSize: 0) == nil)        // no account → nil
    }

    @Test func heatAtExact10PercentBoundaryIsHot() {
        let h = StockSagePortfolioHeat.compute(openTrades: [(shares: 100, entry: 100, stop: 90)], accountSize: 10_000)!
        #expect(abs(h.heatPct - 0.10) < 1e-9)
        #expect(h.level == .hot)
        #expect(h.percentageText == "10.0")
    }

    @Test func heatAtExact5PercentBoundaryIsWarm() {
        let h = StockSagePortfolioHeat.compute(openTrades: [(shares: 100, entry: 100, stop: 95)], accountSize: 10_000)!
        #expect(abs(h.heatPct - 0.05) < 1e-9)
        #expect(h.level == .warm)
        #expect(h.percentageText == "5.0")
    }

    @Test func invalidTradeLegMakesTheCompleteTotalUnavailable() {
        #expect(H.compute(openTrades: [(10, .infinity, 95), (5, 200, 180)], accountSize: 10_000) == nil)
        #expect(H.compute(openTrades: [(.nan, 100, 95)], accountSize: 10_000) == nil)
        #expect(H.compute(openTrades: [(.infinity, 100, 95), (.nan, 200, 180)], accountSize: 10_000) == nil)
        #expect(H.compute(openTrades: [(-1, 100, 95)], accountSize: 10_000) == nil)
        #expect(H.compute(openTrades: [(1, 100, -95)], accountSize: 10_000) == nil)
    }

    @Test func tinyValidAccountHasRangeSafeVisibleAndAccessibleText() throws {
        let account = try #require(StockSageInput.positiveAmount("0.000000000000000001"))
        let heat = try #require(H.compute(openTrades: [(10, 100, 95)], accountSize: account))
        #expect(heat.dollarsAtRisk == 50)
        #expect(heat.percentageText == "5.00e+21")
        #expect(heat.verdict.contains("5.00e+21"))
        #expect(heat.accessibilitySummary.contains("5.00e+21"))
        #expect(!heat.verdict.contains("room to add"))
    }

    @Test func overflowingMathAndNonFiniteAccountAreUnavailable() {
        #expect(H.compute(openTrades: [(1e308, 100, 95)], accountSize: 10_000) == nil)
        #expect(H.compute(openTrades: [(1e307, 10, 2), (1e307, 10, 2), (1e307, 10, 2)], accountSize: 1e308) == nil)
        #expect(H.compute(openTrades: [(10, 100, 95)], accountSize: 1e-308) == nil)
        #expect(H.compute(openTrades: [(1e-308, 2, 1)], accountSize: 1e308) == nil)
        #expect(H.compute(openTrades: [(10, 100, 95)], accountSize: .infinity) == nil)
        #expect(H.compute(openTrades: [(10, 100, 95)], accountSize: .nan) == nil)
    }

    @MainActor @Test func tinyPositionAndCollapsedFXCannotInventZeroRisk() throws {
        let tinyShares = try #require(StockSageInput.positiveAmount("0." + String(repeating: "0", count: 307) + "1"))
        let stop = try #require(StockSageInput.positiveAmount("0.9999999999999999"))
        #expect(tinyShares > 0 && stop > 0 && stop < 1)
        #expect(H.compute(openTrades: [(tinyShares, 1, stop)], accountSize: 10_000) == nil)
        let foreign = trade("2222.SR", shares: 1, entry: 1, stop: stop)
        #expect(H.compute(trades: [foreign], accountSize: 10_000, ratesToUSD: ["SAR": 1e-308]) == nil)
    }

    @MainActor @Test func missingFXRejectsBothAllUnknownAndPartialTotals() {
        let us = trade("AAPL", shares: 10, entry: 100, stop: 95)
        let sar = trade("2222.SR", shares: 10, entry: 100, stop: 90)
        #expect(H.compute(trades: [sar], accountSize: 10_000, ratesToUSD: [:]) == nil)
        #expect(H.compute(trades: [us, sar], accountSize: 10_000, ratesToUSD: [:]) == nil)
        #expect(H.compute(trades: [us], accountSize: 10_000, ratesToUSD: [:])?.dollarsAtRisk == 50)
    }

    @MainActor @Test func invalidFXCannotBecomeZeroOrPartialHeat() {
        let sar = trade("2222.SR", shares: 10, entry: 100, stop: 90)
        for rate in [0.0, -1.0, .infinity, .nan, 1e308] {
            #expect(H.compute(trades: [sar], accountSize: 10_000, ratesToUSD: ["SAR": rate]) == nil)
        }
    }

    @MainActor @Test func completeUSDMixedCurrencyAndPenceMathRemainsCorrect() throws {
        let us = trade("AAPL", shares: 10, entry: 100, stop: 95)
        let sar = trade("2222.SR", shares: 10, entry: 100, stop: 90)
        let mixed = try #require(H.compute(trades: [us, sar], accountSize: 10_000, ratesToUSD: ["SAR": 1 / 3.75]))
        #expect(abs(mixed.dollarsAtRisk - (50 + 100 / 3.75)) < 1e-10)
        #expect(mixed.openCount == 2)
        let pence = trade("VOD.L", shares: 100, entry: 100, stop: 90)
        let converted = try #require(H.compute(trades: [pence], accountSize: 10_000, ratesToUSD: ["GBP": 1.25]))
        #expect(abs(converted.dollarsAtRisk - 12.5) < 1e-10)
    }

    @Test func widgetShowsUnknownForMissingOrInvalidRisk() {
        let invalidValues: [Double?] = [nil, .infinity, .nan, -1]
        for heat in invalidValues {
            let value = snapshot(heat)
            #expect(value.paperHeatText == "Paper stop risk unavailable")
            #expect(value.heatFractionOfCap == nil)
            #expect(!value.isAtHeatCap)
        }
        #expect(snapshot(1.5).paperHeatText == "Paper stop risk 1.5% of account; cap 8.0%")
        #expect(snapshot(0).paperHeatText.contains("0.0%"))
    }

    @Test func percentageFormattingPreservesTinyPositiveAndRejectsInvalidValues() {
        #expect(StockSageRiskDisplay.percentageText(0) == "0.0")
        #expect(StockSageRiskDisplay.percentageText(0.01) == "<0.1")
        #expect(StockSageRiskDisplay.percentageText(1.5) == "1.5")
        #expect(StockSageRiskDisplay.percentageText(5e21) == "5.00e+21")
        #expect(StockSageRiskDisplay.percentageText(.infinity) == nil)
        #expect(StockSageRiskDisplay.percentageText(.nan) == nil)
        #expect(StockSageRiskDisplay.percentageText(-1) == nil)
    }

    @MainActor private func trade(_ symbol: String, shares: Double, entry: Double, stop: Double) -> TradeRecord {
        TradeRecord(symbol: symbol, side: .long, entry: entry, stop: stop, target: nil,
                    shares: shares, openedAt: Date(timeIntervalSince1970: 0), denomination: SageFix.fixtureDenomination(for: symbol))
    }

    private func snapshot(_ heat: Double?) -> StockSageWidgetSnapshot {
        StockSageWidgetSnapshot(asOf: Date(timeIntervalSince1970: 0), bestSymbol: nil, bestAction: nil,
            bestStrength: nil, openPositions: 1, portfolioHeatPct: heat, heatCapPct: 8,
            forwardCloses: nil, forwardNeeded: 30, isSampleData: false,
            portfolioHeatIsComplete: heat != nil)
    }
}
