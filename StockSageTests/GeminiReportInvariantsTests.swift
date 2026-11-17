import Testing
import Foundation
@testable import StockSage

// Invariant locks for the 2026-07-27 external (Gemini) report items whose prescriptions
// target defect classes rather than live defects — each test PINS the property the report
// wanted guaranteed, so the class can never silently appear (owner directive: "do all").
// Fixtures hand-derived below, never copied from the code under test (spec-fidelity).

@Suite("Gemini-report invariant locks")
struct GeminiReportInvariantsTests {

    // MARK: item 3 — kurtosis convention (report claimed excess-vs-raw mismatch)

    @Test("moments() returns RAW kurtosis — the (γ4−1)/4 consumer's expected convention")
    func momentsRawKurtosisConvention() throws {
        // Hand-derived fixture {-1, 0, 0, 1}: mean 0; m2 = (1+0+0+1)/4 = 0.5;
        // m4 = (1+0+0+1)/4 = 0.5; RAW kurtosis = m4/m2² = 0.5/0.25 = 2.0 exactly
        // (an EXCESS-kurtosis implementation would return −1.0 here); skew = 0.
        let m = try #require(StockSageDeflatedSharpe.moments([-1, 0, 0, 1]))
        #expect(abs(m.kurtosis - 2.0) < 1e-12)
        #expect(abs(m.skew) < 1e-12)
    }

    @Test("PSR at normal-sample moments matches the hand-derived Bailey denominator")
    func psrDenominatorUsesRawKurtosis() {
        // Bailey & López de Prado variance term with RAW kurtosis γ4: 1 − γ3·SR + (γ4−1)/4·SR².
        // Normal moments (skew 0, RAW kurtosis 3), SR 1, n 101, bench 0:
        // denom = √(1 − 0 + (3−1)/4·1) = √1.5; z = 1·√100/√1.5 = 10/1.224744871 = 8.164965809.
        // Φ(8.16) ≈ 1 to double precision — and the WRONG (excess-fed) pipeline would compute
        // denom = √(1 + (0−1)/4) = √0.75, z = 11.547 — also Φ≈1, so pin the DENOMINATOR path
        // via a skew/kurtosis pair where conventions diverge on the OPPOSITE side:
        // skew 0, kurtosis 1 (platykurtic RAW), SR 2, n 26:
        // raw: denom = √(1 + (1−1)/4·4) = 1.0 exactly → z = 2·5/1 = 10 → Φ(10) ≈ 1.
        // excess-fed (kurtosis −2 treated as raw −? impossible) — an excess pipeline feeding
        // its normal 0 here would give denom = √(1 + (0−1)/4·4) = 0 → clamped 1e-12 → z astronomical.
        // The DISCRIMINATING pin: kurtosis 5 (raw, fat), SR 1, n 2:
        // denom = √(1 − 0 + (5−1)/4) = √2; z = 1·√1/√2 = 0.7071067812; Φ(0.70710678) = 0.76024994.
        let p = StockSageDeflatedSharpe.probabilisticSharpe(observedSharpe: 1, nTrades: 2,
                                                            skew: 0, kurtosis: 5)
        #expect(abs(p - 0.7602499389) < 1e-6)
    }

    // MARK: item 7 — NetEdge cap order (report claimed cap-first leaks negative-edge trades)

    @Test("cap-first can never pass a trade that friction-first would block")
    func capOrderNeverLeaksNegativeEdge() {
        // cappedGrossReward ≤ grossReward ⟹ netReward(capped) ≤ netReward(uncapped),
        // so a negative uncapped expectancy forces a negative capped expectancy — the
        // claimed leak is impossible. Property-checked over a broad grid including the
        // degenerate hair-thin stop that motivated the 50:1 cap.
        for (entry, stop, target) in [(100.0, 99.99, 110.0), (100.0, 95.0, 101.0),
                                      (100.0, 99.5, 100.6), (50.0, 49.9, 50.2),
                                      (10.0, 9.99, 10.05)] {
            for winProb in [0.05, 0.2, 0.4, 0.6] {
                guard let e = StockSageNetEdge.evaluate(entry: entry, stop: stop, target: target,
                                                        spreadBps: 8, slippageBps: 5,
                                                        winProb: winProb),
                      let netExp = e.netExpectancyR else { continue }
                let grossRisk = abs(entry - stop)
                let grossReward = e.grossRR * grossRisk
                let cost = e.costPerShare
                // friction-first (uncapped) expectancy per the report's proposed order:
                let uncappedNet = (winProb * (grossReward - cost)
                                   - (1 - winProb) * (grossRisk + cost)) / grossRisk
                if uncappedNet < 0 {
                    #expect(netExp < 0,
                            "cap-first passed a trade friction-first blocks: \(entry)/\(stop)/\(target) p=\(winProb)")
                }
            }
        }
    }

    // MARK: item 2 companion — fail-closed staleness contract (owner-signed flip)

    @Test("nil marketTime is STALE — fail-closed alert gating")
    func nilMarketTimeIsStale() {
        #expect(StockSageQuoteFreshness.isStale(symbol: "AAPL", marketTime: nil) == true)
        // fresh timestamps still pass
        #expect(StockSageQuoteFreshness.isStale(symbol: "AAPL", marketTime: Date()) == false)
        // materially old equity close still stale
        #expect(StockSageQuoteFreshness.isStale(symbol: "AAPL",
                                                marketTime: Date(timeIntervalSinceNow: -60 * 3600)) == true)
    }
}
