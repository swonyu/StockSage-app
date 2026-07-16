import Testing
import Foundation
@testable import StockSage

// MARK: - Probabilistic / Deflated Sharpe (pure, python-verified formulas)

struct StockSageDeflatedSharpeTests {
    typealias DS = StockSageDeflatedSharpe

    @Test func normalCDFAndInverseAreTextbookInverses() {
        #expect(abs(DS.normalCDF(0) - 0.5) < 1e-9)
        #expect(abs(DS.normalCDF(1.959964) - 0.975) < 1e-4)
        #expect(abs(DS.normalCDF(-1.959964) - 0.025) < 1e-4)
        #expect(abs(DS.inverseNormalCDF(0.975) - 1.959964) < 1e-3)
        #expect(abs(DS.inverseNormalCDF(0.025) + 1.959964) < 1e-3)
        #expect(abs(DS.inverseNormalCDF(0.5)) < 1e-9)
    }

    @Test func probabilisticSharpeHaircutsForSampleAndSkew() {
        // PSR in [0,1], rises with sample size, falls with negative skew / fat tails.
        let p30 = DS.probabilisticSharpe(observedSharpe: 0.2, nTrades: 30, skew: 0, kurtosis: 3)
        let p100 = DS.probabilisticSharpe(observedSharpe: 0.2, nTrades: 100, skew: 0, kurtosis: 3)
        #expect(p30 >= 0 && p30 <= 1 && p30 < p100)
        #expect(DS.probabilisticSharpe(observedSharpe: 0.2, nTrades: 100, skew: -2, kurtosis: 5) < p100)
        #expect(DS.probabilisticSharpe(observedSharpe: 0.5, nTrades: 1, skew: 0, kurtosis: 3) == 0)  // <2 obs
    }

    @Test func deflatedSharpeHaircutsForTrialsScanned() {
        // Expected-max-Sharpe: 0 at ≤1 trial, rises with the number of trials scanned.
        #expect(DS.expectedMaxSharpe(trials: 1, varTrialSharpe: 0.04) == 0)
        #expect(DS.expectedMaxSharpe(trials: 10, varTrialSharpe: 0.04)
                < DS.expectedMaxSharpe(trials: 100, varTrialSharpe: 0.04))
        // DSR < PSR once >1 trial, falls as trials rise, and DSR == PSR at exactly 1 trial.
        let d10 = DS.deflated(observedSharpe: 0.3, nTrades: 100, skew: 0, kurtosis: 3, trials: 10, varTrialSharpe: 0.04)
        let d50 = DS.deflated(observedSharpe: 0.3, nTrades: 100, skew: 0, kurtosis: 3, trials: 50, varTrialSharpe: 0.04)
        let d1  = DS.deflated(observedSharpe: 0.3, nTrades: 100, skew: 0, kurtosis: 3, trials: 1,  varTrialSharpe: 0.04)
        #expect(d10.dsr < d10.psr)
        #expect(d50.dsr < d10.dsr)
        #expect(abs(d1.dsr - d1.psr) < 1e-12)
        #expect(d50.passes == (d50.dsr > 0.95))
    }

    @Test func momentsOfASymmetricSampleAreZeroSkew() {
        let sym: [Double] = [-2, -1, 0, 1, 2, -2, -1, 0, 1, 2]
        if let m = DS.moments(sym) { #expect(abs(m.skew) < 1e-9) } else { Issue.record("moments should compute") }
        #expect(DS.moments([1, 2, 3]) == nil)   // <4 points
        #expect(DS.moments(Array(repeating: 5.0, count: 10)) == nil)   // zero variance
    }
}
