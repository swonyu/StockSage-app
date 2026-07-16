import Testing
@testable import StockSage

// MARK: - Tier-aware crypto cost estimate (CRYPTO_RISK #1)
//
// All literals hand-derived in /tmp/derive_cryptocost.swift (output pasted in
// plans/PLAN_2026-07-03_calc_wave2_cost_honesty.md Step 11a) — never from the code under test.

struct StockSageCryptoCostTests {
    typealias NE = StockSageNetEdge

    @Test func tierMappingHonorsHonestyFloor() {
        // Majors are majors regardless of a (noisy) advDollar — even one below the thin floor.
        #expect(NE.cryptoTier(forSymbol: "BTC-USD", advDollar: nil) == .majorBTCETH)
        #expect(NE.cryptoTier(forSymbol: "eth-usd", advDollar: 1_000) == .majorBTCETH)
        // Unknown depth is NOT assumed liquid: nil → .mid.
        #expect(NE.cryptoTier(forSymbol: "DOGE-USD", advDollar: nil) == .mid)
        // Straddle the reused liquidity floors (thinBelow 2M, deepAbove 50M — PF-11):
        #expect(NE.cryptoTier(forSymbol: "ALT-USD", advDollar: 1_999_999) == .thin)
        #expect(NE.cryptoTier(forSymbol: "ALT-USD", advDollar: 2_000_000) == .mid)
        #expect(NE.cryptoTier(forSymbol: "ALT-USD", advDollar: 49_999_999) == .mid)
        #expect(NE.cryptoTier(forSymbol: "ALT-USD", advDollar: 50_000_000) == .large)
    }

    @Test func frictionIsStrictlyMonotonicAcrossTiersAndBandsBracketTheMidpoint() {
        // derive_cryptocost: RT 37.5 < 60 < 125 < 300; low < RT < high per tier.
        let major = NE.cryptoCosts(forSymbol: "BTC-USD", advDollar: nil)
        let large = NE.cryptoCosts(forSymbol: "ALT-USD", advDollar: 60_000_000)
        let mid   = NE.cryptoCosts(forSymbol: "ALT-USD", advDollar: 10_000_000)
        let thin  = NE.cryptoCosts(forSymbol: "ALT-USD", advDollar: 1_000_000)
        #expect(abs(major.roundTripBps - 37.5) < 1e-9 && abs(large.roundTripBps - 60) < 1e-9)
        #expect(abs(mid.roundTripBps - 125) < 1e-9 && abs(thin.roundTripBps - 300) < 1e-9)
        for e in [major, large, mid, thin] {
            #expect(e.estimateLowBps < e.roundTripBps && e.roundTripBps < e.estimateHighBps)
            // Algebra: roundTrip == 2·half + slip + 2·taker to 1e-9.
            #expect(abs(e.roundTripBps - (2 * e.halfSpreadBps + e.slippageBps + 2 * e.takerFeeBpsPerSide)) < 1e-9)
        }
    }

    @Test func composesThroughTheUnchangedEvaluateSeam() {
        // derive_cryptocost: entry 100 / stop 90 / target 130 → major netRR 2.85542…,
        // thin netRR 2.07692… — both in (0, gross 3.0), thin strictly worse than major.
        let major = NE.cryptoCosts(forSymbol: "BTC-USD", advDollar: nil).asCostAssumption
        let thin  = NE.cryptoCosts(forSymbol: "ALT-USD", advDollar: 1_000_000).asCostAssumption
        let neMajor = NE.evaluate(entry: 100, stop: 90, target: 130, spreadBps: major.spreadBps,
                                  slippageBps: major.slippageBps, takerFeeBps: major.takerFeeBps)
        let neThin = NE.evaluate(entry: 100, stop: 90, target: 130, spreadBps: thin.spreadBps,
                                 slippageBps: thin.slippageBps, takerFeeBps: thin.takerFeeBps)
        guard let neMajor, let neThin else { Issue.record("evaluate returned nil on a clean setup"); return }
        #expect(abs(neMajor.netRR - 2.855421686746988) < 1e-9)
        #expect(abs(neThin.netRR - 2.076923076923077) < 1e-9)
        #expect(neThin.netRR < neMajor.netRR && neMajor.netRR < 3.0 && neThin.netRR > 0)
    }

    @Test func estimateNeverReadsAsAQuoteAndDefaultsStayByteIdentical() {
        let e = NE.cryptoCosts(forSymbol: "BTC-USD", advDollar: nil)
        #expect(e.isEstimate)
        let d = e.disclaimer.lowercased()
        #expect(d.contains("estimate") && !d.contains("guarantee") && !d.contains("guaranteed"))
        // Backward-compat (register entry 5): production defaults UNCHANGED — 70bps crypto.
        #expect(NE.defaultCosts(forSymbol: "BTC-USD").roundTripBps == 70)
        #expect(NE.defaultCosts(forSymbol: "BTC-USD").takerFeeBps == 20)
    }
}
