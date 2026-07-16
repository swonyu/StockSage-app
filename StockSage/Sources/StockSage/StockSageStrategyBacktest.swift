import Foundation

// MARK: - Aggregate (strategy-wide) backtest
//
// The per-symbol backtester answers "did these rules work on AAPL?" This rolls
// many symbols up into one honest verdict on the strategy itself: how it did
// across the whole watchlist, not cherry-picked names. Pure aggregation →
// unit-tested. Brutally honest about its own limits (small samples, survivorship,
// fixed-not-optimized rules) — past performance is not predictive.

struct StrategyBacktest: Sendable, Equatable {
    let symbolsTested: Int
    let symbolsWithTrades: Int
    let symbolsProfitable: Int     // total R > 0
    let totalTrades: Int
    let wins: Int
    let blendedWinRate: Double     // wins ÷ total trades
    let avgR: Double               // total R ÷ total trades (expectancy)
    let totalR: Double
    let worstDrawdownR: Double     // worst single-symbol max drawdown, in R
    /// Pooled portfolio-PROXY max drawdown, in R: take EVERY trade across ALL symbols, sort by entry
    /// date (chronological), build the cumulative-sum-of-R equity curve, report its worst peak-to-trough.
    /// EQUAL-WEIGHT and IGNORES concurrency/position sizing — NOT a true sized-portfolio drawdown; it is
    /// strictly ≥ the per-symbol worstDrawdownR because cross-symbol losses stack in time. 0 when no trades.
    let pooledDrawdownR: Double
    /// Pooled per-trade t-statistic across ALL symbols' trades = (mean R ÷ stdev R) × √trades.
    /// 0 when unknown (<2 pooled trades or no dispersion). Honest significance gauge.
    let tStat: Double
    /// Skew/fat-tail-adjusted pooled t = SR·√(n−1) ÷ √(1 − g3·SR + ((g4−1)/4)·SR²) — the IID NON-normal
    /// Sharpe standard error (Mertens 2002 / Lo 2002; same moment math as the per-symbol PSR, NON-excess
    /// kurtosis). The raw `tStat` assumes normal returns; this widens the SE for negative skew + fat tails,
    /// so it's the honest companion. 0 when unknown. Does NOT correct for serial correlation.
    let momentCorrectedTStat: Double
    /// Deflated Sharpe result — PSR haircut for sample/skew/kurtosis PLUS selection-bias haircut for the
    /// estimated number of strategy variants tried (StockSageStrategyBacktest.estimatedStrategyTrials).
    /// nil when there are too few pooled trades (<4) or no dispersion. The `passes` flag (DSR > 0.95) is
    /// the honest "real edge" bar; because the measured DSR is ≈ 0, the verdict is "unproven edge" — and
    /// with a higher trials estimate it can only become FIRMER, never flip to "proven."
    let deflatedSharpe: StockSageDeflatedSharpe.Result?
    /// Below this the aggregate is still noise.
    var isSignificant: Bool { totalTrades >= 100 }
    /// Clears the t > 3 multiple-testing bar (Harvey-Liu-Zhu 2016) — NOT the textbook 2.0. Necessary,
    /// not sufficient: it can't see how many rule variants were tried, which only raises the hurdle.
    var clearsMultipleTestingBar: Bool { tStat > 3.0 }
    /// The HONEST green-light: enough trades to be meaningful AND the raw t clears the bar AND — when the
    /// fat-tail-corrected t is known — IT clears the bar too. A "PASS" glyph must satisfy all three, so it
    /// can never sit next to a "not meaningful yet" verdict (#8) or survive on a normal-assumption t the
    /// fat tails would sink (#10).
    var passesHonestSignificance: Bool {
        isSignificant && clearsMultipleTestingBar && (momentCorrectedTStat <= 0 || momentCorrectedTStat > 3.0)
    }
    /// The DSR seal may render its green "PASS" ONLY when the sample is also statistically meaningful.
    /// `deflatedSharpe.passes` is `dsr > 0.95` and DSR populates at n≥4, so a high small-sample Sharpe
    /// can clear 0.95 at <100 trades — which would sit a green seal beside this panel's own "not
    /// meaningful yet" verdict (#8, the invariant `passesHonestSignificance` documents above). The DSR
    /// NUMBER still always displays; this gates only the seal glyph/word/color. Mirrors the per-symbol
    /// PSR `psr > 0.95 && isSignificant` gate (round-g FIX-4).
    var deflatedSharpeShowsPass: Bool { (deflatedSharpe?.passes ?? false) && isSignificant }
    var significanceVerdict: String {
        if !isSignificant { return "Only \(totalTrades) trades — the aggregate isn't statistically meaningful yet." }
        let adjKnown = momentCorrectedTStat > 0
        // Surface the skew/fat-tail-adjusted t when it materially differs from the normal-assumption raw t.
        let adjNote = (adjKnown && abs(momentCorrectedTStat - tStat) >= 0.3)
            ? String(format: " Skew/fat-tail-adjusted t ≈ %.1f.", momentCorrectedTStat) : ""
        if tStat > 3.0 {
            // Raw t clears, but the fat-tail-corrected t does NOT → don't claim a pass.
            if adjKnown && momentCorrectedTStat <= 3.0 {
                return String(format: "t = %.1f clears t>3, but the skew/fat-tail-adjusted t ≈ %.1f does NOT — treat as unproven.", tStat, momentCorrectedTStat)
            }
            return String(format: "t = %.1f — clears the t>3 multiple-testing bar (necessary, not sufficient).", tStat) + adjNote
        }
        if tStat > 2.0 { return String(format: "t = %.1f — significant at 2σ but BELOW the t>3 bar; treat as unproven.", tStat) + adjNote }
        return String(format: "t = %.1f — not significant; likely noise.", tStat) + adjNote
    }
    let caveat: String

    nonisolated init(symbolsTested: Int, symbolsWithTrades: Int, symbolsProfitable: Int, totalTrades: Int,
                     wins: Int, blendedWinRate: Double, avgR: Double, totalR: Double, worstDrawdownR: Double,
                     pooledDrawdownR: Double = 0,
                     tStat: Double = 0, momentCorrectedTStat: Double = 0,
                     deflatedSharpe: StockSageDeflatedSharpe.Result? = nil, caveat: String) {
        self.symbolsTested = symbolsTested; self.symbolsWithTrades = symbolsWithTrades
        self.symbolsProfitable = symbolsProfitable; self.totalTrades = totalTrades; self.wins = wins
        self.blendedWinRate = blendedWinRate; self.avgR = avgR; self.totalR = totalR
        self.worstDrawdownR = worstDrawdownR; self.pooledDrawdownR = pooledDrawdownR; self.tStat = tStat
        self.momentCorrectedTStat = momentCorrectedTStat; self.deflatedSharpe = deflatedSharpe
        self.caveat = caveat
    }
}

enum StockSageStrategyBacktest {
    /// A bounded sample of liquid global equities (no indices/FX/crypto — the
    /// long-side rules are built for equities). Keeps the run cost reasonable.
    nonisolated static let sampleSymbols: [String] = [
        "AAPL", "MSFT", "NVDA", "AMZN", "GOOGL", "META", "TSLA", "JPM",
        "SHEL.L", "AZN.L", "SAP.DE", "MC.PA", "NESN.SW", "ASML.AS",
        "7203.T", "6758.T", "0700.HK", "RELIANCE.NS", "TCS.NS",
        "BHP.AX", "RY.TO", "2222.SR", "1120.SR", "005930.KS",
    ]

    /// Offline conviction-calibration fit recipe (calibration runtime activation): the SAME
    /// per-symbol walk-forward + pooled-fit that `StockSageStore.refreshStrategyBacktest` runs
    /// manually, minus the network fetch — `histories` comes from a caller-supplied cache/scan
    /// result, so this can NEVER reach `StockSageQuoteService` ("no new network" holds by
    /// construction). `h.closes.count > 205` mirrors `StockSageBacktester.runTrades`'s own
    /// `n > warmup(200) + 5` guard (StockSageBacktester.swift:190) — a shorter history yields zero
    /// trades there anyway; checking here just skips the wasted walk-forward call. `fit(fromBacktest:)`
    /// has its own minSamples=30 floor and returns nil below it — the caller keeps its existing
    /// snapshot / the conservative prior. Tolerates `benchmark == nil` the same way the manual
    /// path does (relative-strength term drops out, RS-disabled but not a failure).
    nonisolated static func offlineCalibrationFit(histories: [String: StockSagePriceHistory],
                                                  benchmark: StockSagePriceHistory?) -> StockSageConvictionCalibration? {
        var trades: [BacktestTrade] = []
        var dates: [Date] = []
        for sym in sampleSymbols {
            guard let h = histories[sym.uppercased()], h.closes.count > 205 else { continue }
            let d = StockSageBacktester.runDetailed(h, costs: StockSageNetEdge.defaultCosts(forSymbol: sym), benchmark: benchmark)
            trades.append(contentsOf: d.trades)
            dates.append(contentsOf: d.trades.map { h.dates[$0.entryIndex] })
        }
        return StockSageConvictionCalibration.fit(fromBacktest: trades, dates: dates)
    }

    /// ESTIMATE of the number of distinct strategy variants explored across this engine's
    /// development — the researcher degrees of freedom the Deflated Sharpe selection-bias term
    /// (López de Prado) must discount. NOT precisely derivable (we did not log every config), so
    /// this is a DEFENSIBLE LOWER BOUND: ~8–12 documented iterations (ITER1…ITER6+ in the
    /// refinement plan) each trying a few configs (weights, caps, exit modes) ⇒ on the order of
    /// 12. A LOWER bound is the conservative choice: under-counting trials makes the DSR bar
    /// EASIER, so picking a modest 12 cannot unfairly fail a real edge. Because measured DSR is
    /// already ≈ 0 (PSR ≈ expected-max already ⇒ unproven), raising trials can only RAISE the
    /// selection-bias bar and make the "unproven-edge" verdict FIRMER — it can never flip an
    /// unproven edge to proven. Bump this if a future audit enumerates more variants.
    nonisolated static let estimatedStrategyTrials = 12

    nonisolated static let caveat = "Aggregate of the advisor's FIXED rules over ~5y of these names — backward-looking and small-sample-prone. SURVIVORSHIP-BIASED: the universe is only currently-listed names (delisted losers are absent), so the measured Sharpe is a CEILING, not an expectation. The Deflated Sharpe further discounts for ~\(estimatedStrategyTrials) estimated strategy variants tried (selection bias). Past performance is not future performance."

    /// `trades` (optional) are the POOLED per-trade records across all symbols — when supplied, the
    /// aggregate carries an honest pooled t-statistic, Deflated Sharpe, and pooled portfolio-proxy
    /// drawdown. Omit (default) → tStat 0, deflatedSharpe nil, pooledDrawdownR 0, behaviour unchanged.
    /// `tradeEntryDates` (optional) — when provided, must be 1:1 aligned with `trades`; the pooled
    /// equity curve is built in chronological entry-date order (stable tie-break by position). When
    /// omitted or misaligned, the received order is used (single-symbol callers are already entry-ordered).
    nonisolated static func aggregate(_ results: [BacktestResult], trades: [BacktestTrade] = [],
                                      tradeEntryDates: [Date] = []) -> StrategyBacktest {
        let withTrades = results.filter { $0.trades > 0 }
        let totalTrades = results.reduce(0) { $0 + $1.trades }
        let wins = results.reduce(0) { $0 + $1.wins }
        let totalR = results.reduce(0.0) { $0 + $1.totalR }
        let profitable = withTrades.filter { $0.totalR > 0 }.count
        let worstDD = results.map(\.maxDrawdownR).max() ?? 0
        // Pooled portfolio-proxy drawdown: all trades in chronological entry-date order (equal-weight,
        // ignores concurrency/sizing — see StrategyBacktest.pooledDrawdownR doc). When tradeEntryDates
        // is aligned 1:1 with trades, sort chronologically with stable offset tie-break; else use the
        // received order (single-symbol callers are already entry-ordered — still a valid proxy).
        let pooledDD: Double = {
            let rs = trades.map(\.r)
            guard !rs.isEmpty else { return 0 }
            let ordered: [Double]
            if tradeEntryDates.count == rs.count {
                ordered = zip(tradeEntryDates, rs)
                    .enumerated()
                    .sorted { lhs, rhs in
                        lhs.element.0 == rhs.element.0 ? lhs.offset < rhs.offset : lhs.element.0 < rhs.element.0
                    }
                    .map { $0.element.1 }
            } else {
                ordered = rs
            }
            var cum = 0.0, peak = 0.0, maxDD = 0.0
            for r in ordered { cum += r; peak = Swift.max(peak, cum); maxDD = Swift.max(maxDD, peak - cum) }
            return maxDD
        }()
        // Pooled per-trade t-stat across every symbol's trades (mean/stdev × √n).
        let rs = trades.map(\.r)
        let tStat: Double = {
            guard rs.count >= 2 else { return 0 }
            let mean = rs.reduce(0, +) / Double(rs.count)
            let variance = rs.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rs.count - 1)
            let sd = variance.squareRoot()
            return sd > 0 ? (mean / sd) * Double(rs.count).squareRoot() : 0
        }()
        // Skew/fat-tail-adjusted pooled t = SR·√(n−1)/√(1 − g3·SR + ((g4−1)/4)·SR²) — the IID non-normal
        // Sharpe SE (Bailey & López de Prado / Mertens / Lo), reusing the python-verified moment math.
        let momentCorrectedTStat: Double = {
            guard rs.count >= 4, let m = StockSageDeflatedSharpe.moments(rs) else { return 0 }
            let mean = rs.reduce(0, +) / Double(rs.count)
            let variance = rs.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rs.count - 1)
            let sd = variance.squareRoot()
            guard sd > 0 else { return 0 }
            let sr = mean / sd
            let denom = Swift.max(1e-12, 1 - m.skew*sr + ((m.kurtosis - 1)/4)*sr*sr).squareRoot()
            return sr * Double(rs.count - 1).squareRoot() / denom
        }()
        // Deflated Sharpe: PSR haircut (sample/skew/kurtosis) PLUS selection-bias haircut for
        // estimatedStrategyTrials. varTrialSharpe = variance of per-symbol Sharpes — the honest
        // in-run dispersion; when zero/degenerate, deflated() falls back to DSR==PSR (no fabricated
        // haircut). Trials = estimatedStrategyTrials (12), NOT results.count (symbol count ≠ strategy
        // variants — the researcher DOF that matters is iterations × configs, not scan breadth).
        let deflatedSharpe: StockSageDeflatedSharpe.Result? = {
            guard rs.count >= 4, let m = StockSageDeflatedSharpe.moments(rs) else { return nil }
            let mean = rs.reduce(0, +) / Double(rs.count)
            let variance = rs.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rs.count - 1)
            let sd = variance.squareRoot()
            guard sd > 0 else { return nil }
            let pooledSharpe = mean / sd   // per-trade Sharpe (same unit as PSR/expectedMaxSharpe)
            // Variance of per-symbol Sharpes: honest in-run cross-symbol dispersion.
            let symbolSharpes = results.map(\.sharpe)
            let symMean = symbolSharpes.reduce(0, +) / Double(symbolSharpes.count)
            let varTrial = symbolSharpes.reduce(0.0) { $0 + ($1 - symMean) * ($1 - symMean) } / Double(Swift.max(1, symbolSharpes.count - 1))
            return StockSageDeflatedSharpe.deflated(observedSharpe: pooledSharpe, nTrades: rs.count,
                                                    skew: m.skew, kurtosis: m.kurtosis,
                                                    trials: estimatedStrategyTrials,
                                                    varTrialSharpe: varTrial)
        }()
        return StrategyBacktest(
            symbolsTested: results.count,
            symbolsWithTrades: withTrades.count,
            symbolsProfitable: profitable,
            totalTrades: totalTrades,
            wins: wins,
            blendedWinRate: totalTrades > 0 ? Double(wins) / Double(totalTrades) : 0,
            avgR: totalTrades > 0 ? totalR / Double(totalTrades) : 0,
            totalR: totalR,
            worstDrawdownR: worstDD,
            pooledDrawdownR: pooledDD,
            tStat: tStat,
            momentCorrectedTStat: momentCorrectedTStat,
            deflatedSharpe: deflatedSharpe,
            caveat: caveat)
    }
}
