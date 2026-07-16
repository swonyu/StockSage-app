import Testing
import Foundation
@testable import StockSage

// MARK: - Correlation clusters (pure)

struct StockSageCorrelationClusterTests {

    typealias CC = StockSageCorrelationCluster

    @Test func findsTheMutuallyCorrelatedBlock() {
        // A,B,C all 0.8; D ~0.1 to everyone → cluster {AAA,BBB,CCC}.
        let m = CorrelationMatrix(symbols: ["AAA", "BBB", "CCC", "DDD"], matrix: [
            [1.0, 0.8, 0.8, 0.1],
            [0.8, 1.0, 0.8, 0.1],
            [0.8, 0.8, 1.0, 0.1],
            [0.1, 0.1, 0.1, 1.0],
        ])
        let c = CC.largest(m)!
        #expect(c.symbols == ["AAA", "BBB", "CCC"])
        #expect(abs(c.minPairwise - 0.8) < 1e-9)
        #expect(c.note.contains("~1 bet"))
    }

    @Test func uncorrelatedBookHasNoCluster() {
        let m = CorrelationMatrix(symbols: ["A", "B", "C"], matrix: [
            [1.0, 0.3, 0.2],
            [0.3, 1.0, 0.25],
            [0.2, 0.25, 1.0],
        ])
        #expect(CC.largest(m) == nil)
    }

    @Test func pairIsNotACluster() {
        // Only two names ≥0.7 → not a cluster (needs ≥3).
        let m = CorrelationMatrix(symbols: ["A", "B", "C"], matrix: [
            [1.0, 0.9, 0.1],
            [0.9, 1.0, 0.1],
            [0.1, 0.1, 1.0],
        ])
        #expect(CC.largest(m) == nil)
    }

    @Test func growsToTheFullCliqueWhenAllCorrelated() {
        let m = CorrelationMatrix(symbols: ["W", "X", "Y", "Z"], matrix: [
            [1.0, 0.9, 0.9, 0.9],
            [0.9, 1.0, 0.9, 0.9],
            [0.9, 0.9, 1.0, 0.9],
            [0.9, 0.9, 0.9, 1.0],
        ])
        let c = CC.largest(m)!
        #expect(c.symbols.count == 4)
        #expect(abs(c.minPairwise - 0.9) < 1e-9)
    }

    @Test func tooFewSymbolsIsNil() {
        let m = CorrelationMatrix(symbols: ["A", "B"], matrix: [[1.0, 0.9], [0.9, 1.0]])
        #expect(CC.largest(m) == nil)
    }
}

// MARK: - Effective bets (Kish/design-effect concentration diagnostic, L1 2026-07-09)
//
// Every fixture and expected value hand-derived from scratch in
// derive_effective_bets.swift (replicates correlation() + the effectiveBets formula,
// never calls the code under test) — printed values pasted into the comments below.

struct StockSageEffectiveBetsTests {

    typealias CC = StockSageCorrelationCluster

    @Test func threeIdenticalSeriesGiveFullyConcentratedNEffOfOne() {
        // Period-2 [1,-1,...] × 20 bars, all 3 series identical → every pairwise correlation
        // is EXACTLY 1.0 (cov/denom = 20/20). rho_bar = 1.0; n_eff = 3/(1+2*1) = 1.0.
        let s = (0..<20).map { $0 % 2 == 0 ? 1.0 : -1.0 }
        let eb = CC.effectiveBets(symbols: ["AAA", "BBB", "CCC"], returns: [s, s, s])
        #expect(eb != nil)
        guard let eb else { Issue.record("effectiveBets returned nil"); return }
        #expect(abs(eb.meanPairwise - 1.0) < 1e-9)
        #expect(abs(eb.nEff - 1.0) < 1e-9)
        #expect(eb.n == 3)
        #expect(eb.windowBars == 20)
    }

    @Test func periodFourOrthogonalPatternGivesNEffOfOnePointEight() {
        // s2=[1,1,-1,-1]x5, s3=[1,-1,1,-1]x5 (20 bars, Walsh-orthogonal): corr(s2,s2)=1.0,
        // corr(s2,s3)=0.0 exactly (both derived in derive_effective_bets.swift). Symbols
        // A,B share s2 (rho=1), C is s3 (rho=0 to both) -> pairwise {1,0,0}, rho_bar=1/3.
        // n_eff = 3/(1+2*(1/3)) = 3/(5/3) = 1.8.
        let s2 = (0..<20).map { [1.0, 1.0, -1.0, -1.0][$0 % 4] }
        let s3 = (0..<20).map { [1.0, -1.0, 1.0, -1.0][$0 % 4] }
        let eb = CC.effectiveBets(symbols: ["A", "B", "C"], returns: [s2, s2, s3])
        #expect(eb != nil)
        guard let eb else { Issue.record("effectiveBets returned nil"); return }
        #expect(abs(eb.meanPairwise - 1.0 / 3.0) < 1e-9)
        #expect(abs(eb.nEff - 1.8) < 1e-9)
    }

    @Test func negativeCorrelationRaisesRawAboveNAndClamps() {
        // N=2, [2,-1,-1] vs [-1,2,-1] (mean 0 both): cov=-3, denom=sqrt(6*6)=6, rho=-0.5 exactly.
        // raw = 2/(1+1*(-0.5)) = 2/0.5 = 4.0 -> clamped to N=2.0. minBars overridden to 3 (array
        // length) to keep the fixture small and exact — production default (20) tested separately.
        let a = [2.0, -1.0, -1.0]
        let b = [-1.0, 2.0, -1.0]
        let eb = CC.effectiveBets(symbols: ["X", "Y"], returns: [a, b], minBars: 3)
        #expect(eb != nil)
        guard let eb else { Issue.record("effectiveBets returned nil"); return }
        #expect(abs(eb.meanPairwise - (-0.5)) < 1e-9)
        #expect(abs(eb.nEff - 2.0) < 1e-9)
    }

    @Test func perfectNegativeCorrelationAtNTwoIsNilDenominatorZero() {
        // N=2, [1,-1] vs [-1,1]: rho = -1.0 exactly (cov/denom = -2/2). denom = 1+1*(-1) = 0
        // -> guard fails -> nil (the ONLY N=2 case where the denominator can hit zero).
        let eb = CC.effectiveBets(symbols: ["X", "Y"], returns: [[1.0, -1.0], [-1.0, 1.0]], minBars: 2)
        #expect(eb == nil)
    }

    @Test func fewerThanTwoSymbolsIsNil() {
        #expect(CC.effectiveBets(symbols: ["A"], returns: [[1.0, -1.0]], minBars: 2) == nil)
        #expect(CC.effectiveBets(symbols: [], returns: []) == nil)
    }

    @Test func mismatchedSymbolAndReturnCountsIsNil() {
        #expect(CC.effectiveBets(symbols: ["A", "B"], returns: [[1.0, -1.0]], minBars: 2) == nil)
    }

    @Test func duplicateSymbolsIsNil() {
        let s = [1.0, -1.0, 1.0, -1.0]
        #expect(CC.effectiveBets(symbols: ["A", "A"], returns: [s, s], minBars: 4) == nil)
    }

    @Test func windowShorterThanMinBarsIsNil() {
        // Default minBars=20; a 5-bar series is too short.
        let s = [1.0, -1.0, 1.0, -1.0, 1.0]
        #expect(CC.effectiveBets(symbols: ["A", "B"], returns: [s, s]) == nil)
    }

    // Review fix 2026-07-10: undefined (zero-variance) pairs are EXCLUDED, not counted as 0.
    // Fixture: A and B wiggle with exact ρ=+1 (identical series); C is FLAT (zero variance ⇒
    // correlation nil vs both). Defined pairs = {A,B} only ⇒ ρ̄ = 1 exactly ⇒
    // n_eff = 3 ÷ (1 + 2·1) = 1.0 (clamped floor already 1). Hand-derived: were the flat
    // pair counted as 0, ρ̄ would be 1/3 and n_eff = 3 ÷ (1+2/3) = 1.8 — the fabricated
    // diversification this fix kills.
    @Test func zeroVariancePairsAreExcludedNotCountedAsZero() {
        let wiggle: [Double] = (0..<24).map { Double($0 % 4) - 1.5 }
        let flat = [Double](repeating: 0, count: 24)
        let eb = StockSageCorrelationCluster.effectiveBets(
            symbols: ["A", "B", "C"], returns: [wiggle, wiggle, flat], minBars: 20)
        #expect(eb != nil)
        #expect(abs((eb?.meanPairwise ?? 0) - 1.0) < 1e-12)
        #expect(abs((eb?.nEff ?? 0) - 1.0) < 1e-12)
    }

    // All pairs undefined (two flat series) ⇒ nil — unknown renders as NOTHING on a display
    // diagnostic, never a fabricated verdict (nil = unknown, honesty floor).
    @Test func allPairsUndefinedIsNil() {
        let flat = [Double](repeating: 0, count: 24)
        let eb = StockSageCorrelationCluster.effectiveBets(
            symbols: ["A", "B"], returns: [flat, flat], minBars: 20)
        #expect(eb == nil)
    }
}
