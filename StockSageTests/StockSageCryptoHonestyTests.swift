import Testing
import Foundation
@testable import StockSage

// MARK: - Crypto net-edge honesty (CRYPTO_RISK #2)
//
// classify() branches take HAND numbers (spec-fidelity: a "flip" fixture cannot be derived
// THROUGH the walk-forward engine); evaluate() is pinned by INVARIANTS on the house's own
// 600-bar uptrend fixture (StockSageBacktestTests precedent: it provably produces winning
// trades) plus byte-equality of the gross leg against an independent run — compose-not-duplicate.

struct StockSageCryptoHonestyTests {
    typealias H = StockSageCryptoHonesty

    private func uptrendHistory() -> StockSagePriceHistory {
        // Same shape as StockSageBacktestTests.cleanUptrendProducesWinningTargetTrades:
        // 100 → 699 over 600 bars, ~0.17%/day, vol ≈ 2.7% ⇒ buy signals fire normally.
        let closes = (0..<600).map { 100.0 + Double($0) }
        return StockSagePriceHistory(
            symbol: "TST-USD",
            dates: closes.enumerated().map { Date(timeIntervalSince1970: Double($0.offset) * 86_400) },
            opens: closes, highs: closes.map { $0 + 1 }, lows: closes.map { $0 - 1 },
            closes: closes, volumes: closes.map { _ in 1000 })
    }

    @Test func classifyCoversEveryVerdictBranchHonestly() {
        // Hand numbers; branch order matters (thin → noise → no-gross → flip → fragile → survives).
        let thin = H.classify(grossTotalR: 9, netTotalRMid: 8, netTotalRWorst: 7, trades: 30,
                              thinNote: "THIN crypto liquidity (~$3.0M/day est.) — modeled fills are optimistic.")
        #expect(!thin.survivesMid && !thin.survivesWorst && thin.verdict.contains("UNPROVEN"))
        let noise = H.classify(grossTotalR: 9, netTotalRMid: 8, netTotalRWorst: 7, trades: 19)
        #expect(!noise.survivesMid && noise.verdict.contains("noise"))
        let noGross = H.classify(grossTotalR: -1, netTotalRMid: -2, netTotalRWorst: -3, trades: 30)
        #expect(!noGross.survivesMid && noGross.verdict.contains("BEFORE costs"))
        let flip = H.classify(grossTotalR: 5, netTotalRMid: -0.5, netTotalRWorst: -1, trades: 30)
        #expect(!flip.survivesMid && flip.verdict.contains("net-negative") && flip.verdict.contains("Do not trade"))
        let fragile = H.classify(grossTotalR: 5, netTotalRMid: 2, netTotalRWorst: -0.1, trades: 30)
        #expect(fragile.survivesMid && !fragile.survivesWorst && fragile.verdict.contains("fragile"))
        let survives = H.classify(grossTotalR: 5, netTotalRMid: 4, netTotalRWorst: 2, trades: 30)
        #expect(survives.survivesMid && survives.survivesWorst && survives.verdict.contains("estimate"))
        for v in [thin, noise, noGross, flip, fragile, survives] {
            #expect(!v.verdict.lowercased().contains("guarantee") && !v.verdict.lowercased().contains("risk-free"))
        }
    }

    @Test func evaluateComposesTheRealBacktesterExactly() {
        let history = uptrendHistory()
        let costs = StockSageNetEdge.cryptoCosts(forSymbol: "BTC-USD", advDollar: nil)
        let h = H.evaluate(history, costs: costs)
        #expect(h.trades > 0)                                        // hard count FIRST (WHIPPYX)
        let independentGross = StockSageBacktester.run(history, costs: nil)
        #expect(h.grossAvgR == independentGross.avgR && h.grossTotalR == independentGross.totalR)
        #expect(h.netAvgRMid < h.grossAvgR)                          // strict: positive cost, winning trades
        #expect(h.netAvgRWorst <= h.netAvgRMid)                      // high band ≥ midpoint cost
        #expect(h.frictionDragR > 0 && abs(h.frictionDragR - (h.grossAvgR - h.netAvgRMid)) < 1e-12)
        #expect(H.evaluate(history, costs: costs) == h)              // deterministic, byte-equal
    }

    @Test func thinLiquidityGateForcesUnproven() {
        // derive_cryptorisk: the uptrend's own volumes (1000/bar) → ADV$ 689_500 < 5M → thin.
        let history = uptrendHistory()
        let gate = StockSageCryptoLiquidityGate.assess(symbol: "TST-USD", closes: history.closes,
                                                       opens: history.opens, volumes: history.volumes)
        guard let gate else { Issue.record("gate nil for a -USD symbol"); return }
        #expect(gate.isThinForCrypto)
        let h = H.evaluate(history, costs: StockSageNetEdge.cryptoCosts(forSymbol: "TST-USD", advDollar: gate.advDollar),
                           liquidityGate: gate)
        #expect(h.trades > 0)                                        // the numbers were fine…
        #expect(!h.edgeSurvivesCostsMid && !h.edgeSurvivesCostsWorst)  // …but thin forces UNPROVEN
        #expect(h.verdict.contains("UNPROVEN") && h.liquidityGate == gate)
    }

    @Test func caveatIsPermanentAndHedged() {
        let c = StockSageCryptoHonesty.caveat.lowercased()
        #expect(c.contains("estimate") && c.contains("past performance") && !c.contains("guarantee"))
    }

    // MARK: - Audit 2026-07-12 #1 — crypto band-vs-priced optimism disclosure
    //
    // The detail sheet shows the tier BAND (costsDisplayLabel) but computes net R:R / verdict at the
    // flat `defaultCosts` (70bps crypto) to keep the displayed net == the ranking net (rank-consistency
    // contract). When the band's LOW exceeds the flat priced cost (the THIN tier, 160 > 70), the net is
    // OPTIMISTIC vs the header — costsDisplayNote / costsOptimismSentence disclose exactly that, and MUST
    // stay empty everywhere the priced 70bps is not below what the label states (mid/large/BTC-ETH/non-crypto).
    @Test func cryptoOptimismNoteFiresOnlyWhenBandLowExceedsPricedCost() {
        let priced = StockSageNetEdge.defaultCosts(forSymbol: "TST-USD").roundTripBps  // flat 70 crypto
        // THIN: advDollar < thinBelow ⇒ band 160–440, low 160 > 70 ⇒ note fires.
        let thinAdv = StockSageLiquidity.thinBelow - 1
        let thinBand = StockSageNetEdge.cryptoCosts(forSymbol: "ALT-USD", advDollar: thinAdv)
        #expect(thinBand.estimateLowBps > priced)                                       // premise
        #expect(!StockSageNetEdge.costsDisplayNote(forSymbol: "ALT-USD", advDollar: thinAdv).isEmpty)
        #expect(StockSageNetEdge.costsOptimismSentence(forSymbol: "ALT-USD", advDollar: thinAdv) != nil)
        // The disclosure must name the direction honestly (optimistic / floor), never imply a guarantee.
        let sentence = StockSageNetEdge.costsOptimismSentence(forSymbol: "ALT-USD", advDollar: thinAdv)!.lowercased()
        #expect(sentence.contains("optimistic") && sentence.contains("floor") && !sentence.contains("guarantee"))

        // majorBTCETH: band 21–54, low 21 < 70 ⇒ priced cost is CONSERVATIVE, no note (safe direction).
        #expect(StockSageNetEdge.cryptoCosts(forSymbol: "BTC-USD", advDollar: nil).estimateLowBps < priced)
        #expect(StockSageNetEdge.costsDisplayNote(forSymbol: "BTC-USD", advDollar: nil).isEmpty)
        #expect(StockSageNetEdge.costsOptimismSentence(forSymbol: "BTC-USD", advDollar: nil) == nil)

        // Non-crypto: never a crypto-band note.
        #expect(StockSageNetEdge.costsDisplayNote(forSymbol: "AAPL", advDollar: nil).isEmpty)
        #expect(StockSageNetEdge.costsOptimismSentence(forSymbol: "AAPL", advDollar: nil) == nil)
    }
}
