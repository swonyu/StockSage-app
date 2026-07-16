import Foundation

// MARK: - Crypto net-edge honesty (CRYPTO_RISK #2)
//
// A "profitable" crypto backtest can be net-negative invisibly: the equity curve flatters
// crypto because frictions are estimates and nothing reports HOW MUCH of the gross edge was
// friction. This engine runs the SAME real history through the EXISTING backtester three times
// — frictionless, at the tier's midpoint cost estimate, and at the high band — and surfaces the
// single most important honesty fact: did the edge flip from profitable to net-negative after
// costs. COMPOSES StockSageBacktester.run (never re-implements the walk) and CryptoLiquidityGate
// (a thin gate forces "unproven" — an unfillable edge is not an edge). Backward-looking,
// inherits every backtester caveat (survivorship, fixed rules, small samples). Pure.

struct CryptoNetEdgeHonesty: Sendable, Equatable {
    let grossAvgR: Double
    let netAvgRMid: Double
    let netAvgRWorst: Double
    let grossTotalR: Double
    let netTotalRMid: Double
    let netTotalRWorst: Double
    let frictionDragR: Double          // grossAvgR − netAvgRMid, floored at 0
    let trades: Int
    let isSignificant: Bool            // trades ≥ significanceFloor (same 20-trade bar as BacktestResult)
    let edgeSurvivesCostsMid: Bool
    let edgeSurvivesCostsWorst: Bool
    let liquidityGate: CryptoLiquidityGate?   // the gate consulted, surfaced; nil = not assessed
    let verdict: String
    let caveat: String
}

enum StockSageCryptoHonesty {
    nonisolated static let significanceFloor = 20

    nonisolated static let caveat = "A backward-looking estimate on ESTIMATED cost bands — your venue/tier/size differ, and past performance is not predictive. Inherits every backtester caveat (survivorship, fixed rules, sample size). 'Survives costs' means only 'historically net-positive after estimated frictions at this sample size' — never a profit promise. The stop is still the floor."

    /// Pure verdict classifier — split out so every branch is testable with hand numbers
    /// (the flip fixture cannot be honestly hand-derived THROUGH the walk-forward engine;
    /// spec-fidelity forbids deriving it FROM the engine). `thinNote` non-nil = the liquidity
    /// gate found the name thin, which forces "unproven" regardless of the R numbers.
    nonisolated static func classify(grossTotalR: Double, netTotalRMid: Double, netTotalRWorst: Double,
                                     trades: Int, thinNote: String? = nil)
        -> (verdict: String, survivesMid: Bool, survivesWorst: Bool) {
        if let thin = thinNote {
            return (thin + " An unfillable edge is not an edge — treat this backtest as UNPROVEN.", false, false)
        }
        guard trades >= significanceFloor else {
            return ("Too few trades (\(trades)) to judge — noise, not edge.", false, false)
        }
        if grossTotalR <= 0 {
            return ("No edge even BEFORE costs in this sample — nothing for frictions to eat.", false, false)
        }
        if netTotalRMid <= 0 {
            return ("This crypto edge exists ONLY before costs — after est. frictions it is net-negative. Do not trade it.", false, false)
        }
        if netTotalRWorst <= 0 {
            return ("Edge survives midpoint costs but dies under the high-cost estimate — fragile; treat as unproven.", true, false)
        }
        return ("Edge survives the est. cost haircut at this sample size — still an estimate; past performance is not predictive.", true, true)
    }

    /// Three runs of the EXISTING backtester (compose, never duplicate): frictionless, midpoint,
    /// high-band. The worst leg prices the whole high band as spread (taker/slippage already
    /// aggregated into `estimateHighBps` — see the CryptoCostEstimate band derivation).
    nonisolated static func evaluate(_ history: StockSagePriceHistory,
                                     costs: StockSageNetEdge.CryptoCostEstimate,
                                     warmup: Int = 200,
                                     liquidityGate: CryptoLiquidityGate? = nil) -> CryptoNetEdgeHonesty {
        let gross = StockSageBacktester.run(history, warmup: warmup, costs: nil)
        let netMid = StockSageBacktester.run(history, warmup: warmup, costs: costs.asCostAssumption)
        let netWorst = StockSageBacktester.run(history, warmup: warmup,
            costs: StockSageNetEdge.CostAssumption(spreadBps: costs.estimateHighBps, slippageBps: 0,
                                                   assetClass: "crypto-worst"))
        let thinNote: String? = (liquidityGate?.isThinForCrypto == true) ? liquidityGate?.note : nil
        let c = classify(grossTotalR: gross.totalR, netTotalRMid: netMid.totalR,
                         netTotalRWorst: netWorst.totalR, trades: netMid.trades, thinNote: thinNote)
        return CryptoNetEdgeHonesty(grossAvgR: gross.avgR, netAvgRMid: netMid.avgR,
                                    netAvgRWorst: netWorst.avgR, grossTotalR: gross.totalR,
                                    netTotalRMid: netMid.totalR, netTotalRWorst: netWorst.totalR,
                                    frictionDragR: Swift.max(0, gross.avgR - netMid.avgR),
                                    trades: netMid.trades,
                                    isSignificant: netMid.trades >= significanceFloor,
                                    edgeSurvivesCostsMid: c.survivesMid,
                                    edgeSurvivesCostsWorst: c.survivesWorst,
                                    liquidityGate: liquidityGate,
                                    verdict: c.verdict, caveat: caveat)
    }
}
