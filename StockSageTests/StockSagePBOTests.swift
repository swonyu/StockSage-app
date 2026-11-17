import Testing
import Foundation
@testable import StockSage

// MARK: - Probability of Backtest Overfitting (CSCV, Bailey-Borwein-Lopez de Prado-Zhu 2017)
//
// All expected values below come from an INDEPENDENT hand-derivation (/tmp/derive_pbo.py,
// pure Python itertools/statistics, imports NO StockSage code — spec-fidelity gate 3), never
// from calling StockSagePBO. See that script's per-split table for fixture (a)'s full working.

struct StockSagePBOTests {
    typealias PBO = StockSagePBO

    // (a) Tiny fully worked case: N=3, S=4, T=8, blockLen=2, C(4,2)=6 splits.
    // config0 steady, config1 regime-flip (great blocks 0,2 / terrible 1,3), config2 noise.
    // Exactly one split (IS={0,2}) makes the flip-config the IS winner and it craters OOS
    // (rank 1 -> weight 1); one split (IS={1,3}) lands exactly on the median (weight 0.5);
    // the other four splits pick config0 which stays OOS-top (weight 0). PBO = 1.5/6 = 0.25.
    @Test func tinyWorkedCaseMatchesHandDerivation() throws {
        let config0 = [0.01, 0.02, 0.01, 0.02, 0.01, 0.02, 0.01, 0.02]
        let config1 = [0.05, 0.06, -0.04, -0.05, 0.05, 0.06, -0.04, -0.05]
        let config2 = [0.03, -0.02, 0.02, -0.01, -0.03, 0.04, -0.02, 0.03]
        let r = try #require(PBO.cscv(returns: [config0, config1, config2], blocks: 4))
        #expect(r.pbo == 0.25)
        #expect(abs(r.medianLogit - Foundation.log(3.0)) < 1e-12)
        #expect(r.splits == 6)
        #expect(r.configs == 3)
        #expect(r.blocks == 4)
        #expect(r.blockLength == 2)
    }

    // (b) IDENTICAL configs -> PBO ~ 0.5 (no information), NOT 1.0 and NOT 0.0. This is the
    // load-bearing boundary the tie/rank convention exists to get right (see StockSagePBO.swift
    // doc comment on mid-rank + the rank-vs-(N+1)/2 weight threshold).
    @Test func identicalConfigsYieldCoinFlipNotCertainOverfit() throws {
        let noise = [0.03, -0.02, 0.02, -0.01, -0.03, 0.04, -0.02, 0.03]
        let r = try #require(PBO.cscv(returns: [noise, noise, noise], blocks: 4))
        #expect(r.pbo == 0.5)
        #expect(r.medianLogit == 0.0)
        #expect(r.splits == 6)
    }

    // (c) PURE OVERFIT boundary: N=2, S=2, T=4. Whichever config the (single) IS half-sample
    // selects, it lands OOS-worst on both mirrored splits -> PBO == 1.0 exactly.
    @Test func pureOverfitBoundaryYieldsPBOofOne() throws {
        let a = [0.10, 0.09, -0.10, -0.09]
        let b = [0.01, 0.005, 0.01, 0.005]
        let r = try #require(PBO.cscv(returns: [a, b], blocks: 2))
        #expect(r.pbo == 1.0)
        #expect(abs(r.medianLogit - Foundation.log(0.5)) < 1e-12)
        #expect(r.splits == 2)
    }

    // (d) DOMINANT config: wins IS and ranks best OOS on every split -> PBO == 0.0 exactly.
    @Test func dominantConfigYieldsPBOofZero() throws {
        let a = [0.05, 0.04, 0.05, 0.06, 0.05, 0.04, 0.06, 0.05]
        let b = [0.02, -0.03, 0.01, -0.02, 0.03, -0.01, -0.02, 0.02]
        let c = [-0.01, -0.02, -0.01, -0.03, -0.02, -0.01, -0.02, -0.01]
        let r = try #require(PBO.cscv(returns: [a, b, c], blocks: 4))
        #expect(r.pbo == 0.0)
        #expect(abs(r.medianLogit - Foundation.log(3.0)) < 1e-12)
        #expect(r.splits == 6)
    }

    // (e) ZERO-VARIANCE guard: every sub-series has sd==0 -> Sharpe := 0 -> everything ties ->
    // PBO == 0.5, medianLogit == 0.0, never NaN/inf.
    @Test func zeroVarianceConfigsNeverProduceNaNOrInf() throws {
        let flat = [0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01]
        let r = try #require(PBO.cscv(returns: [flat, flat, flat], blocks: 4))
        #expect(r.pbo == 0.5)
        #expect(r.medianLogit == 0.0)
        #expect(r.pbo.isFinite && r.medianLogit.isFinite)
    }

    // (f) REMAINDER-DROP: appending a junk tail that doesn't fill a whole block must be dropped
    // from the END and reproduce fixture (a)'s result exactly.
    @Test func trailingRemainderIsDroppedFromTheEnd() throws {
        let config0 = [0.01, 0.02, 0.01, 0.02, 0.01, 0.02, 0.01, 0.02, 9.9, -9.9]
        let config1 = [0.05, 0.06, -0.04, -0.05, 0.05, 0.06, -0.04, -0.05, 9.9, -9.9]
        let config2 = [0.03, -0.02, 0.02, -0.01, -0.03, 0.04, -0.02, 0.03, 9.9, -9.9]
        let r = try #require(PBO.cscv(returns: [config0, config1, config2], blocks: 4))
        #expect(r.pbo == 0.25)
        #expect(abs(r.medianLogit - Foundation.log(3.0)) < 1e-12)
        #expect(r.blockLength == 2)   // T=10, S=4 -> blockLen=2; obs 8,9 dropped
    }

    // Nil-guard contract — no derivation needed, these are structural refusals.
    @Test func nilGuardsRefuseUnmeasurableInputs() {
        let row8 = [0.01, 0.02, 0.01, 0.02, 0.01, 0.02, 0.01, 0.02]
        #expect(PBO.cscv(returns: [row8], blocks: 4) == nil)                      // N<2
        #expect(PBO.cscv(returns: [row8, row8], blocks: 3) == nil)                // S odd
        #expect(PBO.cscv(returns: [row8, row8], blocks: 0) == nil)                // S<2
        let row6 = [0.01, 0.02, 0.01, 0.02, 0.01, 0.02]
        #expect(PBO.cscv(returns: [row6, row6], blocks: 4) == nil)                // blockLen=1 <2
        let ragged = [0.01, 0.02, 0.01, 0.02, 0.01, 0.02, 0.01]
        #expect(PBO.cscv(returns: [row8, ragged], blocks: 4) == nil)              // ragged rows
        #expect(PBO.cscv(returns: [], blocks: 4) == nil)                          // empty matrix
    }
}
