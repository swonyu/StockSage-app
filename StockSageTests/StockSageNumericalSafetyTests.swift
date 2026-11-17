import Testing
import Foundation
@testable import StockSage

// Synthetic records only. No owner store, quote feed, broker, model or network use.
struct StockSageNumericalSafetyTests {
    private func trade(_ r: Double, index: Int = 0) -> TradeRecord {
        TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90, target: nil,
                    shares: 1, openedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 100),
                    exitPrice: 100 + 10 * r,
                    closedAt: Date(timeIntervalSince1970: 1_700_000_050 + Double(index) * 100), denomination: SageFix.fixtureDenomination(for: "AAPL"))
    }

    private func extreme(_ index: Int = 0, positive: Bool = true, magnitude: Double = 1e308) -> TradeRecord {
        TradeRecord(symbol: "AAPL", side: positive ? .long : .short, entry: 1,
                    stop: positive ? 0.5 : 1.5, target: nil, shares: 1,
                    openedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 100),
                    exitPrice: magnitude / 2,
                    closedAt: Date(timeIntervalSince1970: 1_700_000_050 + Double(index) * 100), denomination: SageFix.fixtureDenomination(for: "AAPL"))
    }

    @Test func allPositiveFiniteOverflowIsUnavailableRatherThanRuin() throws {
        let records = (0..<20).map { extreme($0) }
        #expect(records.allSatisfy { $0.isFinalized && $0.realizedR == 1e308 && $0.realizedProfit?.isFinite == true })
        // At 1% risk, equity is about 1e306 after one win and overflows after two.
        // The previous implementation converted the second positive win to zero.
        #expect(StockSageMonteCarloRuin.simulate(records, riskFraction: 0.01, horizon: 2, sims: 10) == nil)
        #expect(StockSageJournal.compoundingCurve(records, fraction: 0.01) == nil)
    }

    @Test func monteCarloRetainsIndependentSeededReferenceDistribution() throws {
        let records = (0..<24).map { trade($0 % 2 == 0 ? 1 : -1, index: $0) }
        // Independently calculated with a Python UInt64 SplitMix64 implementation,
        // IEEE double arithmetic, 1500 paths, 100 draws/path and seed 42.
        let low = try #require(StockSageMonteCarloRuin.simulate(records, riskFraction: 0.02, sims: 1500, seed: 42))
        #expect(abs(low.pRuin - 1.0 / 1500) < 1e-15)
        #expect(abs(low.p20DrawdownProb - 774.0 / 1500) < 1e-15)
        #expect(abs(low.medianMaxDD - 0.20246581553279203) < 1e-12)
        #expect(abs(low.p95MaxDD - 0.36546424473522304) < 1e-12)
        let high = try #require(StockSageMonteCarloRuin.simulate(records, riskFraction: 0.1, sims: 1500, seed: 42))
        #expect(abs(high.pRuin - 964.0 / 1500) < 1e-15)
        #expect(high.p20DrawdownProb == 1)
        #expect(abs(high.medianMaxDD - 0.738208721381559) < 1e-12)
        #expect(abs(high.p95MaxDD - 0.9260375617226941) < 1e-12)
    }

    @Test func realWipeoutRemainsAbsorbingAndFinite() throws {
        let losses = (0..<20).map { trade(-1, index: $0) }
        let result = try #require(StockSageMonteCarloRuin.simulate(losses, riskFraction: 1, horizon: 5, sims: 20, ruinLevel: 0))
        #expect(result.pRuin == 1 && result.medianMaxDD == 1 && result.p95MaxDD == 1)
        let curve = try #require(StockSageJournal.compoundingCurve([trade(-1), trade(2, index: 1)], fraction: 1))
        #expect(curve.multiples == [0, 0] && curve.isRuined)
        let half = try #require(StockSageMonteCarloRuin.simulate(losses, riskFraction: 0.5, horizon: 1, sims: 10))
        #expect(half.pRuin == 1 && half.medianMaxDD == 0.5)
    }

    @Test func monteCarloRejectsInvalidDomainsAndArithmeticUnderflow() {
        let records = (0..<20).map { trade(1, index: $0) }
        for risk in [Double.nan, .infinity, -0.01, 0, 1.01] {
            #expect(StockSageMonteCarloRuin.simulate(records, riskFraction: risk, sims: 10) == nil)
        }
        for threshold in [Double.nan, .infinity, -0.1, 1, 1.1] {
            #expect(StockSageMonteCarloRuin.simulate(records, riskFraction: 0.01, sims: 10, ruinLevel: threshold) == nil)
        }
        let declining = (0..<20).map { trade(-0.9, index: $0) }
        #expect(StockSageMonteCarloRuin.simulate(declining, riskFraction: 1, horizon: 400, sims: 2) == nil)
    }

    @Test func rebalanceDoesNotBuyAnUnknownAlreadyHeldPosition() {
        // AAPL's finite shares1e308 × finite mark2 overflows. It is not a zero holding.
        let unknown = 1e308 * 2.0
        #expect(unknown.isInfinite)
        #expect(StockSageRebalance.plan(holdings: [("AAPL", unknown), ("MSFT", 100)],
                                       targets: ["AAPL": 0.5, "MSFT": 0.5]) == nil)
        for invalid in [Double.nan, -Double.infinity, -1] {
            #expect(StockSageRebalance.plan(holdings: [("AAPL", invalid), ("MSFT", 100)], targets: ["MSFT": 1]) == nil)
        }
    }

    @Test func rebalanceRejectsTargetOverflowUnknownTargetsAndInvalidBand() {
        let book: [(symbol: String, value: Double)] = [("A", 50), ("B", 50)]
        #expect(StockSageRebalance.plan(holdings: book, targets: ["A": 1e308, "B": 1e308]) == nil)
        for invalid in [Double.nan, .infinity, -1] {
            #expect(StockSageRebalance.plan(holdings: book, targets: ["A": invalid, "B": 1]) == nil)
        }
        for band in [Double.nan, .infinity, -0.1, 1.1] {
            #expect(StockSageRebalance.plan(holdings: book, targets: ["A": 1], band: band) == nil)
        }
        #expect(StockSageRebalance.plan(holdings: [("A", 1e308), ("B", 1e308)], targets: ["A": 1]) == nil)
    }

    @Test func rebalanceRetainsOrdinaryAmountsZeroTargetsAndExactBandBoundary() throws {
        let plan = try #require(StockSageRebalance.plan(holdings: [("A", 6000), ("B", 4000)], targets: ["A": 0.5, "B": 0.5]))
        #expect(plan.totalValue == 10_000 && plan.trades.count == 2)
        #expect(abs((plan.trades.first { $0.symbol == "A" }?.deltaValue ?? 0) + 1000) < 1e-9)
        #expect(abs((plan.trades.first { $0.symbol == "B" }?.deltaValue ?? 0) - 1000) < 1e-9)
        let exit = try #require(StockSageRebalance.plan(holdings: [("A", 5000), ("B", 5000)], targets: ["A": 0, "B": 1]))
        #expect(exit.trades.first { $0.symbol == "A" }?.deltaValue == -5000)
        let exact = try #require(StockSageRebalance.plan(holdings: [("A", 25), ("B", 75)], targets: ["A": 1, "B": 1], band: 0.25))
        #expect(exact.isBalanced)
    }

    @Test func allocationRejectsFiniteSumOverflowAndNeverDropsAnUnknownValue() {
        let overflow: [(symbol: String, value: Double)] = [("AAPL", 1e308), ("MSFT", 1e308)]
        #expect(StockSageAllocation.breakdown(overflow) == nil)
        #expect(StockSageAllocation.slices(overflow, by: StockSageSector.sector) == nil)
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(StockSageAllocation.breakdown([("AAPL", bad), ("MSFT", 100)]) == nil)
        }
    }

    @Test func allocationEmptyZeroAndNormalReferencesRemainDistinctFromUnavailable() throws {
        let empty = try #require(StockSageAllocation.breakdown([]))
        #expect(empty.totalValue == 0 && empty.byClass.isEmpty)
        let zero = try #require(StockSageAllocation.breakdown([("AAPL", 0)]))
        #expect(zero.totalValue == 0 && zero.byRegion.isEmpty)
        let valid = try #require(StockSageAllocation.breakdown([("AAPL", 100), ("MSFT", 100), ("2222.SR", 50), ("BTC-USD", 50)]))
        #expect(valid.totalValue == 300)
        #expect(abs((valid.byClass.first?.fraction ?? 0) - 5.0 / 6) < 1e-12)
        let sector = try #require(StockSageAllocation.slices([("AAPL", 100), ("MSFT", 100), ("JPM", 100)], by: StockSageSector.sector))
        #expect(sector.first?.label == "Technology")
        #expect(abs((sector.first?.fraction ?? 0) - 2.0 / 3) < 1e-12)
    }

    @Test func percentageBoundaryRejectsEveryUnsafeIntOrGeometryInput() {
        for value in [Double.nan, .infinity, -.infinity, -0.01, 1.01, .greatestFiniteMagnitude] {
            #expect(StockSageAllocation.percentage(value) == nil)
        }
        #expect(StockSageAllocation.percentage(0) == 0)
        #expect(StockSageAllocation.percentage(0.125) == 13)
        #expect(StockSageAllocation.percentage(1) == 100)
    }

    @Test func whatIfCannotDescribeUnknownAllocationAsBalanced() {
        #expect(StockSageWhatIf.addingHolding(symbol: "MSFT", addedValue: 100,
                                             to: [("AAPL", .infinity)]) == nil)
        #expect(StockSageWhatIf.addingHolding(symbol: "MSFT", addedValue: 1e308,
                                             to: [("AAPL", 1e308)]) == nil)
        #expect(StockSageWhatIf.proposedAddValue(sizedNotional: .nan, account: 100, bookTotal: 100) == nil)
        #expect(StockSageWhatIf.proposedAddValue(sizedNotional: nil, account: 100, bookTotal: .infinity) == nil)
        #expect(StockSageWhatIf.proposedAddValue(sizedNotional: .infinity, account: nil, bookTotal: 100) == nil)
        #expect(StockSageWhatIf.proposedAddValue(sizedNotional: nil, account: .nan, bookTotal: 100) == nil)
        #expect(StockSageWhatIf.proposedAddValue(sizedNotional: nil, account: 0, bookTotal: 100) == nil)
        #expect(StockSageWhatIf.proposedAddValue(sizedNotional: -1, account: nil, bookTotal: 100) == nil)
        let untrusted = WhatIfImpact(candidateClass: "Equity", beforeTopClass: "Equity",
                                    beforeTopFraction: .infinity, afterTopClass: "Equity",
                                    afterTopFraction: .nan, crossesConcentration: false)
        #expect(untrusted.note.localizedCaseInsensitiveContains("unavailable"))
        #expect(!untrusted.note.contains("balanced"))
    }

    @Test func alreadyConcentratedAndEmptyBooksDoNotClaimToBeBalanced() throws {
        let concentrated = try #require(StockSageWhatIf.addingHolding(symbol: "MSFT", addedValue: 50,
                                                                       to: [("AAPL", 100)]))
        #expect(concentrated.afterTopFraction == 1 && !concentrated.crossesConcentration)
        #expect(concentrated.note.contains("remains concentrated") && !concentrated.note.contains("balanced"))
        let empty = try #require(StockSageWhatIf.addingHolding(symbol: "MSFT", addedValue: 0, to: []))
        #expect(empty.afterTopFraction == 0 && empty.note.contains("No positive holding value"))
        #expect(!empty.note.contains("balanced"))
    }

    @Test func currencyExposureRejectsOverflowButPreservesNamedMissingRateScope() throws {
        #expect(StockSageCurrency.breakdown(holdings: [(1e308, "USD"), (1e308, "USD")], ratesToBase: [:], base: "USD") == nil)
        #expect(StockSageCurrency.breakdown(holdings: [(1e308, "EUR")], ratesToBase: ["EUR": 2], base: "USD") == nil)
        for bad in [Double.nan, .infinity] {
            #expect(StockSageCurrency.breakdown(holdings: [(100, "USD"), (100, "EUR")], ratesToBase: ["EUR": bad], base: "USD") == nil)
        }
        let valid = try #require(StockSageCurrency.breakdown(holdings: [(100, "USD"), (50, "EUR")], ratesToBase: [:], base: "USD"))
        #expect(valid.totalBase == 100 && valid.unpriced == ["EUR"])
        #expect(valid.exposures.count == 1 && valid.exposures[0].weight == 1)
    }

    @Test func finiteJournalRecordsSurviveJSONWhileOverflowStatisticsBecomeUnavailable() throws {
        let records = (0..<20).map { extreme($0) }
        let encoded = try JSONEncoder().encode(records)
        let restored = try JSONDecoder().decode([TradeRecord].self, from: encoded)
        #expect(restored == records && restored.count == 20)
        #expect(restored.allSatisfy { $0.isFinalized && $0.exitPrice == 5e307 && $0.realizedR == 1e308 })
        let stats = StockSageJournal.stats(restored)
        #expect(stats.closed == 20 && stats.wins == 20 && stats.winRate == 1)
        #expect(!stats.hasFiniteAggregates)
        #expect(!StockSageJournal.edge(restored).isAvailable)
        #expect(StockSageJournal.rDistribution(restored) == nil)
        #expect(StockSageJournal.expectancyConfidence(restored) == nil)
        #expect(StockSageJournal.tradesToSignificance(restored) == nil)
        #expect(StockSageJournal.expectancyTrend(restored) == nil)
        #expect(StockSageJournal.equityRisk(restored) == nil)
        let health = try #require(StockSageJournal.systemHealth(restored))
        #expect(health.verdict == .unproven && health.reason.localizedCaseInsensitiveContains("unavailable"))
    }

    @MainActor @Test func finiteExponentCSVRecordsRemainAcceptedWithoutInventedShapeOrConfidence() throws {
        let row = "AAPL,Long,1,0.5,,1,2026-01-01T00:00:00Z,5e307,2026-01-02T00:00:00Z,,synthetic"
        let csv = StockSageJournalCSV.header + "\n" + Array(repeating: row, count: 20).joined(separator: "\n")
        let parsed = StockSageJournalCSVImport.parse(csv)
        #expect(parsed.rowErrors.isEmpty && parsed.trades.count == 20)
        #expect(parsed.trades.allSatisfy { $0.exitPrice == 5e307 && $0.realizedR == 1e308 })
        #expect(StockSageJournal.stats(parsed.trades).closed == 20)
        #expect(StockSageJournal.rDistribution(parsed.trades) == nil)
        #expect(StockSageJournal.expectancyConfidence(parsed.trades) == nil)
        #expect(StockSageJournal.systemHealth(parsed.trades)?.verdict == .unproven)
    }

    @Test func nonfiniteConfidenceAndHealthCannotBecomePositiveClaims() {
        for mean in [Double.nan, .infinity, -.infinity] {
            let ci = ExpectancyCI(expectancyR: mean, stdErrR: .infinity, n: 20)
            #expect(!ci.isSignificant && ci.note.localizedCaseInsensitiveContains("unavailable"))
            #expect(StockSageJournal.classifyHealth(profitFactor: 2, expectancyR: mean, significant: true,
                                                   n: 20, maxDrawdownR: 0).verdict == .unproven)
        }
        for factor in [Double.nan, .infinity, -1] {
            #expect(StockSageJournal.classifyHealth(profitFactor: factor, expectancyR: 1, significant: true,
                                                   n: 20, maxDrawdownR: 0).verdict == .unproven)
        }
        #expect(StockSageJournal.classifyHealth(profitFactor: 2, expectancyR: 0, significant: true,
                                               n: 20, maxDrawdownR: 0).verdict == .unproven)
        #expect(StockSageJournal.classifyHealth(profitFactor: 2, expectancyR: 1, significant: true,
                                               n: 20, maxDrawdownR: .infinity).verdict == .unproven)
        let shape = RDistribution(bins: [], total: 20, skewness: .nan, kurtosis: .infinity, hasDispersion: true)
        #expect(shape.shapeNote.localizedCaseInsensitiveContains("unavailable"))
        #expect(!shape.shapeNote.localizedCaseInsensitiveContains("symmetric"))
    }

    @Test func finiteMeansWithOverflowingVarianceStillRejectConfidence() {
        let records = [extreme(0, positive: false, magnitude: 1e200),
                       extreme(1, magnitude: 1e200), extreme(2, magnitude: 1e200)]
        #expect(StockSageJournal.edge(records).isAvailable)
        #expect(StockSageJournal.expectancyConfidence(records) == nil)
        #expect(StockSageJournal.rDistribution(records) == nil)
        #expect(StockSageJournal.tradesToSignificance(records) == nil)
        #expect(StockSageJournal.systemHealth(records)?.verdict == .unproven)
    }

    @Test func ordinaryStatisticsAndTrueZeroSpreadRetainTheirMeaning() throws {
        let normal = [trade(3), trade(1, index: 1)]
        let ci = try #require(StockSageJournal.expectancyConfidence(normal))
        #expect(ci.expectancyR == 2 && abs(ci.stdErrR - 1) < 1e-12 && ci.isSignificant)
        let equal = (0..<4).map { trade(1, index: $0) }
        let shape = try #require(StockSageJournal.rDistribution(equal))
        #expect(shape.total == 4 && shape.skewness == 0 && shape.kurtosis == 3 && !shape.hasDispersion)
        #expect(shape.shapeNote.contains("No variation"))
        let zero = try #require(StockSageJournal.expectancyConfidence([trade(0), trade(0, index: 1)]))
        #expect(zero.expectancyR == 0 && zero.stdErrR == 0 && !zero.isSignificant)
        #expect(StockSageJournal.stats(normal).hasFiniteAggregates && StockSageJournal.edge(normal).isAvailable)
    }

    @Test func growthAndTrendRejectUnrepresentableDerivedValues() {
        #expect(StockSageJournal.projectGrowth(expectancyR: 1e308, trades: 2, fraction: 0.01) == nil)
        #expect(StockSageJournal.projectGrowth(expectancyR: .infinity, trades: 2) == nil)
        #expect(StockSageJournal.projectGrowth(expectancyR: -99, trades: 1000, fraction: 0.01) == nil)
        let records = (0..<6).map { trade(1, index: $0) }
        #expect(StockSageJournal.expectancyTrend(records, band: .nan) == nil)
        #expect(StockSageJournal.expectancyTrend(records, band: -1) == nil)
        #expect(StockSageJournal.tradesToSignificance(records, z: .nan) == nil)
        #expect(StockSageJournal.tradesToSignificance(records, z: -2) == nil)
    }

    @Test func journalFormattingNeverPresentsNonfiniteValuesAsMeasurements() {
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(StockSageJournal.formattedFinite(value, format: "%+.2fR") == "Unavailable")
        }
        #expect(StockSageJournal.formattedFinite(1.25, format: "%+.2fR") == "+1.25R")
        #expect(StockSageJournal.formattedFinite(0, format: "%+.2fR") == "+0.00R")
    }
}
