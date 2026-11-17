import Testing
import Foundation
@testable import StockSage

// MARK: - Net-of-cost simulation harness for the IRRX reversal overlay (roadmap-item-3 gate).
// Every expected value is HAND-DERIVED in standalone derive scripts that do NOT import the app
// (derive_netcostsim.swift; net/cost columns re-derived in derive_netcostsim_v2.swift after the
// per-side cost fix — turnover counts one-way trades, so the charge is roundTripBps/2 per unit),
// per skills/testing-discipline. Key arithmetic is pasted inline so the literals stay auditable
// after the throwaway scripts are gone. The headline test proves the harness kills a
// gross-passing edge once costs are charged — the reason the gate exists.

struct StockSageNetCostSimTests {
    typealias NC = StockSageNetCostSim

    // F1 — walk-forward folds with purge (labelSpan) + embargo; first block skipped (no past).
    @Test func walkForwardFoldsPurgeAndEmbargo() {
        let folds = NC.walkForwardFolds(n: 20, folds: 4, labelSpan: 2, embargo: 1)
        #expect(folds == [
            NC.Fold(train: 0..<2,  test: 5..<10),
            NC.Fold(train: 0..<7,  test: 10..<15),
            NC.Fold(train: 0..<12, test: 15..<20),
        ])
        #expect(folds.count == 3)
    }

    // F2 — industry-relative reversal weights: short recent winners, long recent losers; Σw=0, Σ|w|=1.
    @Test func irrxWeightsIndustryRelativeReversal() {
        let panel = NC.Panel(returns: [[0.10,0.10],[0.00,0.00],[-0.10,-0.10],[0.00,0.00]], industry: [0,0,1,1])
        let w = NC.irrxWeights(panel, at: 2, lookback: 2)
        let expected = [-0.25, 0.25, 0.25, -0.25]
        #expect(w.count == 4)
        for i in 0..<4 { #expect(abs(w[i] - expected[i]) < 1e-12) }
        #expect(abs(w.reduce(0, +)) < 1e-12)                       // dollar-neutral
        #expect(abs(w.map { abs($0) }.reduce(0, +) - 1.0) < 1e-12) // gross exposure 1
    }

    // F3 — earnings-window exclusion zeroes the name and re-forms the book on the survivors.
    @Test func irrxWeightsEarningsExclusionZeroesTheName() {
        let panel = NC.Panel(returns: [[0.10,0.10],[0.00,0.00],[-0.10,-0.10],[0.00,0.00]], industry: [0,0,1,1])
        let w = NC.irrxWeights(panel, at: 2, lookback: 2, excluded: [0])
        #expect(w[0] == 0.0)                 // excluded → exactly zero
        #expect(abs(w[1] - 0.0) < 1e-12)
        #expect(abs(w[2] - 0.5) < 1e-12)
        #expect(abs(w[3] + 0.5) < 1e-12)
    }

    // F8 — rebalance series gross/turnover/net (covers gross=Σw·fwd, net=gross−turnover·perSide,
    // and the exclusion-driven turnover at t=3). Values from derive_netcostsim_v2.swift.
    // perSide = 50/2/10_000 = 0.0025 per unit turnover. Arithmetic:
    //   t=2: w=[−¼,¼,¼,−¼] (F2); gross=−¼·0.05+¼·(−0.05)=−0.025; turn=Σ|w−0|=1; net=−0.025−0.0025
    //   t=3: excl s0 → w=[0,0,½,−½]; gross=½·(−0.05)=−0.025; turn=4·0.25=1;     net=−0.025−0.0025
    //   t=4: w back to [−¼,¼,¼,−¼]; gross=−¼·0.04+¼·(−0.05)=−0.0225; turn=1;    net=−0.0225−0.0025
    //   t=5: past=[0.09,0,−0.10,0] → raw=[−.045,.045,.05,−.05]/0.19; gross=−0.0273684…;
    //        turn=4·(0.26316−0.25)=0.0526316; net=−0.0273684−0.0526316·0.0025=−0.0275
    @Test func rebalanceSeriesGrossTurnoverNet() {
        let panel = NC.Panel(
            returns: [[0.06,0.04,0.05,0.05,0.04,0.06],[0,0,0,0,0,0],
                      [-0.05,-0.05,-0.05,-0.05,-0.05,-0.05],[0,0,0,0,0,0]],
            industry: [0,0,1,1], earningsExcludedAt: [3: [0]])
        let rs = NC.rebalanceSeries(panel, lookback: 2, hold: 1, roundTripBps: 50)
        #expect(rs.count == 4)
        let exp: [(Int, Double, Double, Double)] = [
            (2, -0.025,                1.0,                 -0.0275),
            (3, -0.025,                1.0,                 -0.0275),
            (4, -0.0225,               1.0,                 -0.025),
            (5, -0.027368421052631577, 0.05263157894736842, -0.0275),
        ]
        for (i, e) in exp.enumerated() {
            #expect(rs[i].t == e.0)
            #expect(abs(rs[i].grossReturn - e.1) < 1e-12)
            #expect(abs(rs[i].turnover - e.2) < 1e-12)
            #expect(abs(rs[i].netReturn - e.3) < 1e-12)
        }
    }

    // F6 — the DSR verdict chain (sr = mean/sampleSD(n−1) → moments → deflated). dsr < 0.95 ⇒ fails.
    @Test func verdictMatchesDeflatedSharpeChain() {
        let v = NC.verdict([0.02, -0.01, 0.03, 0.00, 0.01, -0.02], trials: 1)
        #expect(v != nil)
        #expect(abs(v!.dsr - 0.7236601105752472) < 1e-9)
        #expect(v!.passes == false)
    }

    // F7 — THE HEADLINE: charging cost flips a gross verdict that CLEARS DSR>0.95 into one that fails.
    // net = gross − 0.028 (constant shift: same variance/skew/kurt, only the mean — hence SR — moves).
    // Cross-derived twice, independently (derive_netcostsim.swift + a Python erf re-derivation,
    // 2026-07-03 review): gross DSR = 0.99999999997741, net DSR = 0.10204033468237.
    @Test func costsFlipGrossPassToNetFail() {
        let gross = [0.030,0.025,0.028,0.022,0.031,0.027,0.029,0.024,0.026,0.030,0.023,0.028]
        let net = gross.map { $0 - 0.028 }
        let vg = NC.verdict(gross, trials: 1)
        let vn = NC.verdict(net, trials: 1)
        #expect(vg != nil && vn != nil)
        // gross clears the honest bar…
        #expect(vg!.passes == true)
        #expect(vg!.dsr > 0.99)
        // …net does NOT — the round-trip drag kills it (the whole reason for the gate).
        #expect(vn!.passes == false)
        #expect(vn!.dsr < 0.95)
        #expect(abs(vn!.dsr - 0.10204033468237034) < 1e-9)
    }

    // F9 (end-to-end on the F8 panel) — the honest gate answers "does NOT clear net-of-cost".
    // meanNet = (−0.0275 − 0.0275 − 0.025 − 0.0275)/4 = −0.026875 (derive_netcostsim_v2.swift).
    @Test func simulateHonestVerdictDoesNotClear() {
        let panel = NC.Panel(
            returns: [[0.06,0.04,0.05,0.05,0.04,0.06],[0,0,0,0,0,0],
                      [-0.05,-0.05,-0.05,-0.05,-0.05,-0.05],[0,0,0,0,0,0]],
            industry: [0,0,1,1], earningsExcludedAt: [3: [0]])
        let sim = NC.simulate(panel, lookback: 2, hold: 1, roundTripBps: 50, folds: 3, embargo: 1)
        #expect(sim != nil)
        #expect(sim!.clearsNetOfCost == false)
        #expect(sim!.grossVerdictFull?.passes == false)
        #expect(sim!.netVerdictFull?.passes == false)
        #expect(abs(sim!.meanNet - (-0.026875)) < 1e-12)
        #expect(sim!.grossReturns.count == 4)
    }

    // oosPooled selects exactly the walk-forward test blocks (fold 0 skipped → OOS = indices 5..<20).
    @Test func oosPooledSelectsTestBlocks() {
        let series = (0..<20).map { Double($0) }
        let oos = NC.oosPooled(series, folds: 4, embargo: 1)
        #expect(oos == (5..<20).map { Double($0) })
    }

    // Degenerate guards — honest nil rather than a fabricated verdict.
    @Test func verdictNilWhenTooThinOrFlat() {
        #expect(NC.verdict([0.01, 0.02, 0.03]) == nil)        // < 4 points
        #expect(NC.verdict([0.01, 0.01, 0.01, 0.01]) == nil)  // zero variance
    }

    @Test func simulateNilWhenPanelTooThin() {
        let panel = NC.Panel(returns: [[0.01, 0.02], [0.0, 0.0]], industry: [0, 1])
        #expect(NC.simulate(panel, lookback: 2, hold: 1, roundTripBps: 50) == nil)  // < 4 rebalances
    }

    // No look-ahead: mutating a FUTURE bar (index ≥ t) must not change the weights formed at t.
    @Test func irrxWeightsAreLookAheadFree() {
        var returns = [[0.10,0.10,0.99],[0.00,0.00,0.99],[-0.10,-0.10,0.99],[0.00,0.00,0.99]]
        let w1 = NC.irrxWeights(NC.Panel(returns: returns, industry: [0,0,1,1]), at: 2, lookback: 2)
        returns[0][2] = -0.99; returns[2][2] = 0.42   // future bar for t=2
        let w2 = NC.irrxWeights(NC.Panel(returns: returns, industry: [0,0,1,1]), at: 2, lookback: 2)
        for i in 0..<4 { #expect(abs(w1[i] - w2[i]) < 1e-15) }
    }
}
