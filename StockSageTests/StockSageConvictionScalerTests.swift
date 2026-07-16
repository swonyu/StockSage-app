import Testing
import Foundation
@testable import StockSage

// MARK: - Conviction-scaled, regime-gated per-trade risk cap (FASTMONEY_BACKLOG #6) — pure,
// hand-verified. Anchors the new function against the REAL constants it composes
// (StockSageAdvisor.riskPerTrade, StockSageRegime's documented 0.25/0.40/1.25 bias bounds) so a
// drift in either upstream constant is caught here too.

struct StockSageConvictionScalerTests {
    typealias Scaler = StockSageConvictionScaler

    // Regime bias bounds taken verbatim from StockSageRegime.swift's sizingBias formula:
    // crisis fixed 0.25; bear clamps to a floor of 0.40 (worst case) up to ~0.55 at the
    // trendingBear boundary; bull ranges ~0.95 (boundary) up to a ceiling of 1.25.
    private let crisisBias = 0.25
    private let bearFloorBias = 0.40
    private let bearBoundaryBias = 0.55
    private let bullBoundaryBias = 0.95
    private let bullCeilingBias = 1.25

    @Test func convictionBelowPoint3NeverExceedsBase() {
        let base = 0.01
        for conviction in [0.0, 0.1, 0.2, 0.29] {
            for bias in [crisisBias, bearFloorBias, bearBoundaryBias, bullBoundaryBias, bullCeilingBias] {
                let f = Scaler.scaledRiskFraction(base: base, conviction: conviction, regimeBias: bias)
                #expect(f <= base, "conviction \(conviction) bias \(bias) -> \(f) exceeded base \(base)")
            }
        }
    }

    @Test func crisisRegimeAlwaysFloorsAtMinRiskFractionRegardlessOfConviction() {
        // 0.25 crisis bias is small enough that even max conviction (1.5x) can't clear the floor:
        // 0.01 * 1.5 * 0.25 = 0.00375 < 0.005, so every crisis case floors to EXACTLY 0.005.
        for conviction in [0.0, 0.2, 0.5, 0.8, 1.0] {
            let f = Scaler.scaledRiskFraction(base: 0.01, conviction: conviction, regimeBias: crisisBias)
            #expect(f == Scaler.minRiskFraction)
            #expect(f <= 0.005)
        }
    }

    @Test func neverExceedsTheHardTwoPercentCapAcrossRealisticInputs() {
        let convictions = [0.0, 0.25, 0.5, 0.75, 1.0]
        let biases = [crisisBias, bearFloorBias, bearBoundaryBias, bullBoundaryBias, bullCeilingBias]
        for c in convictions {
            for b in biases {
                #expect(Scaler.scaledRiskFraction(base: 0.01, conviction: c, regimeBias: b) <= Scaler.maxRiskFraction)
            }
        }
        // Max attainable WITHIN today's real regime-bias range (1.0 conviction, 1.25 bull ceiling)
        // is 0.01875 — under the 2% cap, so the cap doesn't even bind on realistic inputs; it only
        // bites on adversarial/out-of-range bias (guarding a future caller, e.g. a mis-scaled input).
        let maxRealistic = Scaler.scaledRiskFraction(base: 0.01, conviction: 1.0, regimeBias: bullCeilingBias)
        #expect(abs(maxRealistic - 0.01875) < 1e-9)
    }

    @Test func capBitesOnAnAdversarialOutOfRangeBias() {
        // A bias well beyond the documented 1.25 ceiling (e.g. a future caller's bug) must still
        // be clamped at the hard 2% ceiling, not silently propagate an oversized fraction.
        let f = Scaler.scaledRiskFraction(base: 0.01, conviction: 1.0, regimeBias: 10.0)
        #expect(f == Scaler.maxRiskFraction)
    }

    @Test func convictionMonotonicallyScalesUpAtAFixedRegime() {
        // Bull-boundary bias, conviction 0 → 1: strictly non-decreasing risk fraction.
        var last = 0.0
        for c in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0] {
            let f = Scaler.scaledRiskFraction(base: 0.01, conviction: c, regimeBias: bullBoundaryBias)
            #expect(f >= last)
            last = f
        }
    }

    @Test func nonFinitOrNonPositiveBaseYieldsZero() {
        #expect(Scaler.scaledRiskFraction(base: 0, conviction: 1.0, regimeBias: 1.0) == 0)
        #expect(Scaler.scaledRiskFraction(base: -0.01, conviction: 1.0, regimeBias: 1.0) == 0)
        #expect(Scaler.scaledRiskFraction(base: .nan, conviction: 1.0, regimeBias: 1.0) == 0)
        #expect(Scaler.scaledRiskFraction(base: .infinity, conviction: 1.0, regimeBias: 1.0) == 0)
    }

    @Test func nonFiniteOrNonPositiveRegimeBiasFallsBackToNeutralOne() {
        // A degenerate bias (0, negative, NaN, infinite) must not propagate garbage — falls back
        // to a neutral 1.0x, so the result equals the plain conviction-scaled (unbiased) fraction.
        let expectedNeutral = Scaler.scaledRiskFraction(base: 0.01, conviction: 0.7, regimeBias: 1.0)
        #expect(Scaler.scaledRiskFraction(base: 0.01, conviction: 0.7, regimeBias: 0) == expectedNeutral)
        #expect(Scaler.scaledRiskFraction(base: 0.01, conviction: 0.7, regimeBias: -5) == expectedNeutral)
        #expect(Scaler.scaledRiskFraction(base: 0.01, conviction: 0.7, regimeBias: .nan) == expectedNeutral)
        #expect(Scaler.scaledRiskFraction(base: 0.01, conviction: 0.7, regimeBias: .infinity) == expectedNeutral)
    }

    @Test func convictionClampsToZeroToOneRange() {
        // Out-of-range conviction (negative or >1) must clamp, not extrapolate the multiplier.
        let below = Scaler.scaledRiskFraction(base: 0.01, conviction: -1.0, regimeBias: 1.0)
        let atZero = Scaler.scaledRiskFraction(base: 0.01, conviction: 0.0, regimeBias: 1.0)
        #expect(below == atZero)
        let above = Scaler.scaledRiskFraction(base: 0.01, conviction: 5.0, regimeBias: 1.0)
        let atOne = Scaler.scaledRiskFraction(base: 0.01, conviction: 1.0, regimeBias: 1.0)
        #expect(above == atOne)
    }

    @Test func caveatIsAlwaysPresentAndLoadBearing() {
        #expect(!Scaler.caveat.isEmpty)
        #expect(Scaler.caveat.localizedCaseInsensitiveContains("size"))
        #expect(Scaler.caveat.localizedCaseInsensitiveContains("stop"))
    }

    // 2026-07-09 review fix: the absolute 0.5% floor was designed for the documented 1% base —
    // fed a smaller USER-configured base (the wave-7 Today-plan wiring passes the user's own
    // risk %) it silently scaled the DISPLAYED risk UP to 5x the configured budget. The floor is
    // now min(0.5%, base * 0.5): byte-identical for base >= 1% (pinned above), never above the
    // conviction multiplier's own 0.5x lower bound for smaller bases. All hand-derived.
    @Test func smallBaseIsNeverFlooredAboveItself() {
        // base 0.1%, conviction 0.2, neutral bias: raw = 0.001 * 0.7 * 1.0 = 0.0007.
        // OLD behavior floored this UP to 0.005 (5x the user's budget); now it passes through.
        let f = Scaler.scaledRiskFraction(base: 0.001, conviction: 0.2, regimeBias: 1.0)
        #expect(abs(f - 0.0007) < 1e-15)
        #expect(f < Scaler.minRiskFraction)
    }

    @Test func smallBaseFloorIsHalfTheBase() {
        // base 0.1%, conviction 0, crisis bias 0.25: raw = 0.001 * 0.5 * 0.25 = 0.000125 —
        // floors at base * 0.5 = 0.0005 (the multiplier's own lower bound), NOT at 0.005.
        let f = Scaler.scaledRiskFraction(base: 0.001, conviction: 0.0, regimeBias: 0.25)
        #expect(abs(f - 0.0005) < 1e-15)
    }

    @Test func onePercentBaseFloorBehaviorIsUnchangedByTheSmallBaseFix() {
        // Legacy pin: base 1%, conviction 0, crisis 0.25 -> raw 0.00125 -> floor still 0.005
        // (min(0.005, 0.01 * 0.5) = 0.005 - identical to the pre-fix absolute floor).
        let f = Scaler.scaledRiskFraction(base: 0.01, conviction: 0.0, regimeBias: 0.25)
        #expect(f == Scaler.minRiskFraction)
    }
}
