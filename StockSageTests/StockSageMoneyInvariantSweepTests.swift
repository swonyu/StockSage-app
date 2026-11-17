import Testing
import Foundation
@testable import StockSage

/// Parametric invariant sweeps for the money engine's safety guarantees.
///
/// Every asserted literal is HAND-DERIVED in `scratchpad/derive_invariants.swift`
/// (replicates the spec, never calls the code under test — testing-discipline / F40).
/// These pin three invariants surfaced by the 2026-07-07 money-math verification pass
/// (Opus/Fable blind derivations + DeepSeek-proposed sweeps, re-derived and corrected here):
///   1. half-Kelly ≤ full/2 and ≤ 0.20 cap, across a (W,R) grid
///   2. grossRR ≥ netRR, monotone non-increasing in cost
///   3. PositionSizer keeps dollarsAtRisk ≤ budget even when shares floor to 0
struct StockSageMoneyInvariantSweepTests {

    // MARK: 1. half-Kelly never exceeds full/2 nor the 0.20 cap

    @Test func halfKellyStaysUnderFullAndCap_parametricSweep() {
        // fStar = clamp01(w − (1−w)/r); half = fStar/2; suggested = min(0.20, half).
        // Corner pins (derive_invariants.swift):
        //   w=0.30 r=0.5 → fStar 0.000000, half 0.000000, suggested 0.000000
        //   w=0.30 r=5.0 → fStar 0.160000, half 0.080000, suggested 0.080000
        //   w=0.90 r=0.5 → fStar 0.700000, half 0.350000, suggested 0.200000 (capped)
        //   w=0.90 r=5.0 → fStar 0.880000, half 0.440000, suggested 0.200000 (capped)
        let ws: [Double] = [0.3, 0.45, 0.5, 0.55, 0.7, 0.9]
        let rs: [Double] = [0.5, 1.0, 2.0, 3.0, 5.0]
        var count = 0
        for w in ws {
            for r in rs {
                let expectedFStar = max(0.0, min(1.0, w - (1 - w) / r))   // hand-derived, not from code
                let k = StockSageKelly.compute(winRate: w, payoffRatio: r, accountSize: 10_000)
                // fullKelly matches the hand-derived clamped f*
                #expect(abs(k.fullKelly - expectedFStar) < 1e-9)
                // halfKelly is exactly full/2
                #expect(abs(k.halfKelly - k.fullKelly / 2) < 1e-12)
                // suggested never exceeds half, never exceeds the cap
                #expect(k.suggestedFraction <= k.halfKelly + 1e-12)
                #expect(k.suggestedFraction <= StockSageKelly.maxFraction + 1e-12)
                // fullKelly stays clamped to [0,1]
                #expect(k.fullKelly >= 0 && k.fullKelly <= 1)
                count += 1
            }
        }
        #expect(count == 30)   // 6 × 5 grid all exercised (hard count — no vacuous pass)
        // Spot-pin the two capped corners so the cap is genuinely straddled.
        let hot = StockSageKelly.compute(winRate: 0.9, payoffRatio: 5.0, accountSize: 10_000)
        #expect(abs(hot.fullKelly - 0.88) < 1e-9 && abs(hot.halfKelly - 0.44) < 1e-9)
        #expect(abs(hot.suggestedFraction - 0.20) < 1e-9)   // half 0.44 capped to 0.20
        let cold = StockSageKelly.compute(winRate: 0.3, payoffRatio: 0.5, accountSize: 10_000)
        #expect(cold.fullKelly == 0 && cold.suggestedFraction == 0)   // no edge → don't bet
    }

    // MARK: 2. grossRR ≥ netRR, monotone non-increasing in cost

    @Test func grossRRneverBelowNetRR_costSweep() {
        // entry=100 stop=95 target=110 → grossReward 10, grossRisk 5, grossRR 2.0.
        // cost($) = spreadBps/10000·100 ; netRR = (min(grossRR,50)·5 − cost)/(5 + cost).
        // Hand-derived netRR (derive_invariants.swift): strictly decreasing
        //   0bps→2.000000  5→1.970297  13→1.923977  30→1.830189  70→1.631579  200→1.142857
        let expected: [(Double, Double)] = [
            (0, 2.000000), (5, 1.970297), (13, 1.923977),
            (30, 1.830189), (70, 1.631579), (200, 1.142857),
        ]
        var prev = Double.infinity
        var count = 0
        for (bps, wantNetRR) in expected {
            guard let e = StockSageNetEdge.evaluate(entry: 100, stop: 95, target: 110, spreadBps: bps) else {
                Issue.record("evaluate returned nil for spreadBps \(bps)"); return
            }
            #expect(abs(e.grossRR - 2.0) < 1e-9)                 // gross is cost-independent
            #expect(abs(e.netRR - wantNetRR) < 1e-6)             // exact hand-derived net
            #expect(e.grossRR >= e.netRR)                        // the invariant
            #expect(e.netRR <= prev + 1e-12)                     // monotone non-increasing in cost
            prev = e.netRR
            count += 1
        }
        #expect(count == 6)
    }

    // MARK: 3. dollarsAtRisk ≤ budget even when shares floor to 0

    @Test func positionSizerRespectsBudgetWhenSharesFloorToZero() {
        // budget = account·riskFraction ; riskPerShare = entry−stop ; shares = floor(budget/rps).
        // Both cases: budget/rps < 1 → shares 0 → dollarsAtRisk 0 (derive_invariants.swift).
        //   acct 100 rf 0.01 entry 50 stop 38 → budget 1.0  rps 12 → 0 shares
        //   acct 500 rf 0.005 entry 200 stop 190 → budget 2.5 rps 10 → 0 shares
        let cases: [(Double, Double, Double, Double)] = [
            (100, 0.01, 50, 38),
            (500, 0.005, 200, 190),
        ]
        var count = 0
        for (acct, rf, entry, stop) in cases {
            guard let ps = StockSagePositionSizer.size(account: acct, riskFraction: rf, entry: entry, stop: stop) else {
                Issue.record("size returned nil for acct \(acct)"); return
            }
            #expect(ps.shares == 0)                              // floored to zero
            #expect(ps.dollarsAtRisk == 0)                       // 0 shares × rps
            #expect(ps.dollarsAtRisk <= acct * rf + 1e-12)       // never over budget
            count += 1
        }
        #expect(count == 2)
    }

    // MARK: 4. priorWinProb output stays finite and in [0.35, 0.58] for ANY input

    @Test func priorWinProbStaysInBandForAnyInputIncludingNaN() {
        // priorWinProb(c) = 0.35 + max(0, min(1, c))·0.23. The clamp is the load-bearing money-path
        // guard: a NaN/Inf/out-of-range conviction must NOT escape as a non-finite win-prob (which
        // would poison evR and the rank comparator — strict-weak-ordering). Swift's min/max return
        // the NON-NaN operand, and here `conviction` is the SECOND arg to min(1, ·), so min(1, NaN)=1.
        // Reorder that to min(NaN, 1) and NaN would leak — this test locks the current safe order.
        // Hand-derived exacts (derive_priorwinprob_band.swift): 0→0.35, 0.5→0.465, 1→0.58,
        // −5→0.35, 5→0.58, +Inf→0.58, −Inf→0.35, NaN→0.58 (all finite, all in-band).
        let exact: [(Double, Double)] = [(0, 0.35), (0.5, 0.465), (1, 0.58), (-5, 0.35), (5, 0.58)]
        for (c, want) in exact { #expect(abs(StockSageExpectedValue.priorWinProb(c) - want) < 1e-9) }
        for c in [Double.infinity, -Double.infinity, Double.nan] {
            let r = StockSageExpectedValue.priorWinProb(c)
            #expect(r.isFinite)                          // never escapes as ±Inf/NaN
            #expect(r >= 0.35 && r <= 0.58)              // stays in the assumed-band (F02)
        }
    }
}
