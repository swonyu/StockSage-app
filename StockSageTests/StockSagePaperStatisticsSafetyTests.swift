import Foundation
import Testing
@testable import StockSage

// Pure, synthetic values only: no store, defaults, network, provider, model or broker calls.
@Suite("Paper statistic numeric safety")
@MainActor
struct StockSagePaperStatisticsSafetyTests {
    typealias DS = StockSageDeflatedSharpe

    private func closedR(_ r: Double) -> TradeRecord {
        TradeRecord(symbol: "TST", side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                    openedAt: Date(timeIntervalSince1970: 0), exitPrice: 100 + 10*r,
                    closedAt: Date(timeIntervalSince1970: 86_400))
    }

    private func extremeClosedRecords() -> [TradeRecord] {
        // Entry 1, risk 0.5: these finite exits give finite R of 8e307 ... 1.1e308.
        // The four-element sum overflows even though every stored field and each R is finite.
        [4e307, 4.5e307, 5e307, 5.5e307].map { exit in
            TradeRecord(symbol: "TST", side: .long, entry: 1, stop: 0.5, target: nil, shares: 1,
                        openedAt: Date(timeIntervalSince1970: 0), exitPrice: exit,
                        closedAt: Date(timeIntervalSince1970: 86_400))
        }
    }

    @Test func momentsRejectNonFiniteObservations() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            #expect(DS.moments([-1, 0, 1, invalid]) == nil)
        }
    }

    @Test func momentsRejectFiniteSumOverflow() {
        let values = [8e307, 9e307, 1e308, 1.1e308]
        #expect(values.allSatisfy { $0.isFinite })
        #expect(DS.moments(values) == nil)
    }

    @Test func momentsRejectFiniteVarianceOverflow() {
        // Symmetry keeps the sum/mean finite; squaring these deviations overflows instead.
        let values = [-1e200, -1e200, 1e200, 1e200]
        #expect(values.reduce(0, +).isFinite)
        #expect(DS.moments(values) == nil)
    }

    @Test func momentsRejectFourthMomentOverflow() {
        // Second and third powers are representable; the fourth powers are not.
        #expect(DS.moments([-2e80, -1e80, 1e80, 2e80]) == nil)
    }

    @Test func momentsRejectUnderflowedFourthMoment() {
        // Nonzero inputs and positive second moment cannot justify a fabricated zero kurtosis.
        #expect(DS.moments([-2e-100, -1e-100, 1e-100, 2e-100]) == nil)
    }

    @Test func momentsPreserveIndependentOrdinaryReferences() throws {
        let symmetric = try #require(DS.moments([-1, 0, 0, 1]))
        #expect(abs(symmetric.skew) < 1e-12)
        #expect(abs(symmetric.kurtosis - 2) < 1e-12)
        // Independently evaluated with 80-digit decimal moments, not this implementation.
        let asymmetric = try #require(DS.moments([-1, 0, 1, 3]))
        #expect(abs(asymmetric.skew - 0.4346507595746656684) < 1e-12)
        #expect(abs(asymmetric.kurtosis - 1.8457142857142857143) < 1e-12)
    }

    @Test func finiteClosedRecordsWithOverflowHaveUnavailableStatistics() throws {
        let records = extremeClosedRecords()
        #expect(records.count == 4)
        for record in records {
            #expect(record.isFinalized && record.closureError == nil)
            let realizedR = try #require(record.realizedR)
            #expect(realizedR.isFinite)
        }
        #expect(StockSagePaperTrader.forwardStats(records) == nil)
    }

    @Test func retainedFiniteRecordsRoundTripWithoutInventingAStatistic() throws {
        let records = extremeClosedRecords()
        let data = try JSONEncoder().encode(records)
        let restored = try JSONDecoder().decode([TradeRecord].self, from: data)
        #expect(restored == records)
        #expect(restored.allSatisfy { $0.isFinalized })
        #expect(StockSagePaperTrader.forwardStats(restored) == nil)
    }

    @Test func ordinaryForwardStatisticsKeepIndependentKnownValues() throws {
        let stats = try #require(StockSagePaperTrader.forwardStats([2, 1, -1, 1.5].map(closedR)))
        #expect(stats.closed == 4)
        #expect(stats.winRate == 0.75)
        #expect(stats.avgR == 0.875)
        #expect(abs(stats.sharpe - 0.6654104630507018091) < 1e-12)
        #expect(abs(stats.deflated.psr - 0.813340160814995) < 1e-12)
        #expect(stats.deflated.dsr == stats.deflated.psr && stats.deflated.trials == 1)
        #expect(stats.deflated.isAvailable && !stats.passesForwardBar)
        #expect(stats.deflated.displayedDSRPercentage == 81.3)
    }

    @Test func aZeroMeanWithRealVariationRemainsAvailable() throws {
        let stats = try #require(StockSagePaperTrader.forwardStats([-1, 0, 0, 1].map(closedR)))
        #expect(stats.avgR == 0 && stats.sharpe == 0)
        #expect(stats.deflated.psr == 0.5 && stats.deflated.dsr == 0.5)
        #expect(stats.deflated.displayedDSRPercentage == 50)
        #expect(!stats.passesForwardBar)
    }

    @Test func tooFewOrConstantClosedSamplesStayUnavailable() {
        #expect(StockSagePaperTrader.forwardStats([-1, 0, 1].map(closedR)) == nil)
        #expect(StockSagePaperTrader.forwardStats([1, 1, 1, 1].map(closedR)) == nil)
    }

    @Test func displayRejectsNonFiniteAndOutOfRangeProbabilities() {
        for invalid in [Double.nan, .infinity, -.infinity, -0.001, 1.001] {
            let invalidDSR = DS.Result(psr: 0.5, dsr: invalid, trials: 1)
            #expect(!invalidDSR.isAvailable && !invalidDSR.passes)
            #expect(invalidDSR.displayedDSRPercentage == nil)
            let invalidPSR = DS.Result(psr: invalid, dsr: 0.99, trials: 1)
            #expect(!invalidPSR.isAvailable && !invalidPSR.passes)
            #expect(invalidPSR.displayedDSRPercentage == nil)
        }
        for invalidTrials in [0, -1] {
            let result = DS.Result(psr: 0.99, dsr: 0.99, trials: invalidTrials)
            #expect(!result.isAvailable && !result.passes)
            #expect(result.displayedDSRPercentage == nil)
        }
    }

    @Test func displayKeepsBoundaryAndThresholdSemantics() {
        for (probability, expected, passes) in [
            (0.0, 0.0, false), (1.0, 100.0, true),
            (0.947, 94.7, false), (0.95, 95.0, false), (0.9505, 95.0, true)
        ] {
            let result = DS.Result(psr: probability, dsr: probability, trials: 1)
            #expect(result.isAvailable)
            #expect(result.displayedDSRPercentage == expected)
            #expect(result.passes == passes)
        }
    }

    @Test func displayedFinitePercentagesStayBoundedAndNeverRoundUp() throws {
        for numerator in 0...1000 {
            let probability = Double(numerator) / 1000
            let result = DS.Result(psr: probability, dsr: probability, trials: 1)
            let shown = try #require(result.displayedDSRPercentage)
            #expect(shown.isFinite && (0...100).contains(shown))
            #expect(shown <= probability * 100 + 1e-12)
            #expect(probability * 100 - shown < 0.100000000001)
        }
    }
}
