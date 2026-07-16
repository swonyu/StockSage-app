import Foundation

// MARK: - Net-of-cost simulation harness for the IRRX reversal overlay (roadmap gate)
//
// WHY THIS EXISTS. RESEARCH_2026-07-02_week_horizon_velocity.md, roadmap item 3: the ONE
// short-horizon equity signal that survives GROSS of costs is the industry-relative,
// earnings-window-excluded ("IRRX") reversal — ~58 bps/month, t=3.29 post-decimalization
// (Novy-Marx RRLP, verified 3-0). But that figure is GROSS; the plausible NET retail
// magnitude is "0–30 bps/month at best … NOT a standalone book." The research therefore
// GATES any activation behind a real net-of-cost simulation, "same rigor as the 2026-07-02
// confluence/RS ablation" (walk-forward, no look-ahead, purge/embargo).
//
// This harness IS that gate. It is deterministic, pure, and consumes only public APIs:
// `StockSageDeflatedSharpe` for the verdict, and a caller-supplied `roundTripBps` for the cost
// model (`StockSageNetEdge.defaultCosts(forSymbol:).roundTripBps` is the intended source). It
// edits nothing. It does NOT fetch data: the caller supplies an aligned return panel, so the same
// machinery runs on a synthetic fixture (tests) or a real backtest panel (a future Fable pass)
// without look-ahead risk from a live feed. A verdict on a SYNTHETIC panel validates the
// machinery only — it says NOTHING about the live edge until a real panel is run through it.
//
// HONESTY FLOOR. The point of the gate is falsification, not confirmation. If the overlay's
// NET Deflated Sharpe does not clear the DSR>0.95 bar, `clearsNetOfCost == false` — and that
// negative result IS the deliverable, not a failure of the harness. Gross figures are never
// presented as achievable net returns. Every number the harness emits is computed from the
// supplied panel; nothing is assumed.

enum StockSageNetCostSim {

    // MARK: Input panel

    /// An aligned return panel. `returns[s][t]` is symbol `s`'s SIMPLE return in period `t`
    /// (all symbols share one date axis). `industry[s]` groups symbols for the industry-relative
    /// demeaning. `earningsExcludedAt[t]` = the symbol indices to EXCLUDE from the signal at a
    /// rebalance that STARTS in period `t` (the earnings-window exclusion; default: none).
    nonisolated struct Panel: Sendable, Equatable {
        let returns: [[Double]]
        let industry: [Int]
        let earningsExcludedAt: [Int: Set<Int>]

        init(returns: [[Double]], industry: [Int], earningsExcludedAt: [Int: Set<Int>] = [:]) {
            self.returns = returns
            self.industry = industry
            self.earningsExcludedAt = earningsExcludedAt
        }

        var symbolCount: Int { returns.count }
        var periodCount: Int { returns.first?.count ?? 0 }
    }

    // MARK: Walk-forward folds (purge + embargo)

    nonisolated struct Fold: Sendable, Equatable {
        let train: Range<Int>
        let test: Range<Int>
    }

    /// Forward-chaining walk-forward split of `[0,n)` into `folds` contiguous test blocks.
    /// For each block k: `test = [⌊k·n/folds⌋, ⌊(k+1)·n/folds⌋)` and the (expanding) training
    /// window is `[0, test.lowerBound − labelSpan − embargo)`. `labelSpan` PURGES observations
    /// whose forward-return label window would overlap the test block; `embargo` adds a further
    /// serial-correlation gap (López de Prado). A fold is yielded only when its training window
    /// is non-empty, so the first block (no usable past) is skipped.
    nonisolated static func walkForwardFolds(n: Int, folds: Int, labelSpan: Int, embargo: Int) -> [Fold] {
        guard n > 0, folds > 0 else { return [] }
        var out: [Fold] = []
        for k in 0..<folds {
            let testLo = (k * n) / folds
            let testHi = ((k + 1) * n) / folds
            let trainHi = testLo - max(0, labelSpan) - max(0, embargo)
            if trainHi > 0 && testHi > testLo {
                out.append(Fold(train: 0..<trainHi, test: testLo..<testHi))
            }
        }
        return out
    }

    // MARK: IRRX reversal weights

    /// Industry-relative, earnings-excluded REVERSAL weights at a rebalance starting in period `t`.
    /// Uses ONLY returns in `[t−lookback, t)` (strictly the past — no look-ahead). Steps:
    ///   past[s]   = Σ returns[s][u], u ∈ [t−lookback, t)
    ///   included  = symbols not in `excluded`
    ///   score[s]  = past[s] − mean(past over included symbols in s's industry)   (industry-relative)
    ///   raw[s]    = −score[s]                                                     (REVERSAL: long losers)
    ///   w[s]      = normalize(demean(raw over included)) so Σ|w| = 1;  excluded → 0
    /// The demeaning makes the book dollar-neutral; the L1 normalization fixes gross exposure at 1.
    nonisolated static func irrxWeights(_ panel: Panel, at t: Int, lookback: Int, excluded: Set<Int> = []) -> [Double] {
        let s = panel.symbolCount
        guard s > 0, lookback > 0, t >= lookback, t <= panel.periodCount else {
            return [Double](repeating: 0, count: max(0, s))
        }
        var past = [Double](repeating: 0, count: s)
        for sym in 0..<s {
            var acc = 0.0
            for u in (t - lookback)..<t { acc += panel.returns[sym][u] }
            past[sym] = acc
        }
        let included = (0..<s).filter { !excluded.contains($0) }
        guard !included.isEmpty else { return [Double](repeating: 0, count: s) }

        var sum: [Int: Double] = [:]
        var cnt: [Int: Int] = [:]
        for sym in included {
            sum[panel.industry[sym], default: 0] += past[sym]
            cnt[panel.industry[sym], default: 0] += 1
        }
        var raw = [Double](repeating: 0, count: s)
        for sym in included {
            let g = panel.industry[sym]
            let mean = sum[g]! / Double(cnt[g]!)
            raw[sym] = -(past[sym] - mean)
        }
        let meanRaw = included.map { raw[$0] }.reduce(0, +) / Double(included.count)
        for sym in included { raw[sym] -= meanRaw }
        let gross = included.map { abs(raw[$0]) }.reduce(0, +)
        guard gross > 0 else { return [Double](repeating: 0, count: s) }
        var w = [Double](repeating: 0, count: s)
        for sym in included { w[sym] = raw[sym] / gross }
        return w
    }

    // MARK: Causal rebalance series

    /// One non-overlapping rebalance: weights formed at `t` from the past, held over `[t, t+hold)`.
    nonisolated struct Rebalance: Sendable, Equatable {
        let t: Int
        let grossReturn: Double   // Σ w·(forward return over the hold)
        let turnover: Double      // Σ|w − prevWeights|  (full turnover on the first rebalance)
        let netReturn: Double     // grossReturn − turnover·(roundTripBps/2/10_000) — per-side, see below
    }

    /// Build the causal, non-overlapping rebalance series. Rebalances start at
    /// `t = lookback, lookback+hold, …` while `t+hold ≤ periodCount`. `roundTripBps` is the
    /// ROUND-TRIP (both fills) cost for one unit of notional (see `StockSageNetEdge.defaultCosts`
    /// / `CostAssumption.roundTripBps` for asset-class defaults).
    ///
    /// COST ACCOUNTING. `turnover` = Σ|Δw| counts each ONE-WAY trade, and a full round trip on one
    /// unit of notional is 2 units of turnover (buy 1, later sell 1) — so the per-unit-turnover
    /// charge is `roundTripBps/2` (per side). Charging the full round trip per unit traded would
    /// double-count costs ~2× and bias the gate toward refusing a genuinely-passing edge; the
    /// research net figures this gate is compared against use standard one-way accounting.
    /// Known simplifications, both second-order at this series length: (a) the final book is never
    /// liquidated, understating total cost by one exit (≤ gross-exposure·roundTripBps/2 once);
    /// (b) `prevWeights` ignores intra-hold drift, so turnover is measured against the weights as
    /// set, not as drifted.
    nonisolated static func rebalanceSeries(_ panel: Panel, lookback: Int, hold: Int, roundTripBps: Double) -> [Rebalance] {
        let s = panel.symbolCount
        let T = panel.periodCount
        guard s > 0, lookback > 0, hold > 0, T >= lookback + hold else { return [] }
        let perSideCost = max(0, roundTripBps) / 2 / 10_000.0
        var out: [Rebalance] = []
        var prevW = [Double](repeating: 0, count: s)
        var t = lookback
        while t + hold <= T {
            let excluded = panel.earningsExcludedAt[t] ?? []
            let w = irrxWeights(panel, at: t, lookback: lookback, excluded: excluded)
            var gross = 0.0
            for sym in 0..<s {
                var fwd = 0.0
                for u in t..<(t + hold) { fwd += panel.returns[sym][u] }
                gross += w[sym] * fwd
            }
            var turnover = 0.0
            for sym in 0..<s { turnover += abs(w[sym] - prevW[sym]) }
            let net = gross - turnover * perSideCost
            out.append(Rebalance(t: t, grossReturn: gross, turnover: turnover, netReturn: net))
            prevW = w
            t += hold
        }
        return out
    }

    // MARK: Deflated-Sharpe verdict

    /// A Deflated-Sharpe verdict on a return series. `sharpe = mean / sampleStdDev(n−1)`, fed to
    /// `StockSageDeflatedSharpe` with the sample's own skew/kurtosis. nil if < 4 points or zero
    /// variance (the honest-unknown contract: too thin to judge).
    nonisolated static func verdict(_ series: [Double], trials: Int = 1, varTrialSharpe: Double = 0) -> StockSageDeflatedSharpe.Result? {
        let n = series.count
        guard n >= 4 else { return nil }
        let mean = series.reduce(0, +) / Double(n)
        let sampleVar = series.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(n - 1)
        guard sampleVar > 0 else { return nil }
        let sharpe = mean / sampleVar.squareRoot()
        guard let (skew, kurt) = StockSageDeflatedSharpe.moments(series) else { return nil }
        return StockSageDeflatedSharpe.deflated(observedSharpe: sharpe, nTrades: n,
                                                skew: skew, kurtosis: kurt,
                                                trials: max(1, trials), varTrialSharpe: max(0, varTrialSharpe))
    }

    /// Pool the out-of-sample (test-block) values of a rebalance series under a walk-forward split.
    /// The label span for non-overlapping holds is 1 rebalance; `embargo` gaps the boundary.
    nonisolated static func oosPooled(_ series: [Double], folds: Int, embargo: Int) -> [Double] {
        let folded = walkForwardFolds(n: series.count, folds: folds, labelSpan: 1, embargo: embargo)
        var out: [Double] = []
        for f in folded { out.append(contentsOf: series[f.test]) }
        return out
    }

    // MARK: End-to-end simulation

    nonisolated struct SimResult: Sendable, Equatable {
        let rebalances: [Rebalance]
        let grossReturns: [Double]
        let netReturns: [Double]
        /// Verdict over the FULL causal series (every rebalance uses only past data, so the whole
        /// series is already look-ahead-free for this parameter-free rule).
        let grossVerdictFull: StockSageDeflatedSharpe.Result?
        let netVerdictFull: StockSageDeflatedSharpe.Result?
        /// Verdict over the pooled walk-forward OOS test blocks (the stricter, fold-based read).
        let netVerdictOOS: StockSageDeflatedSharpe.Result?
        let meanGross: Double
        let meanNet: Double
        /// The gate: does the NET edge clear the DSR>0.95 bar — OOS when computable. When the
        /// walk-forward pool is too thin for a verdict (<4 pooled test points; first computable
        /// OOS verdict needs n≥10 rebalances at folds=3/embargo=1), `simulate` falls back to the
        /// FULL-series net verdict; `netVerdictOOS == nil` exposes the fallback to consumers.
        let clearsNetOfCost: Bool
    }

    /// Run the full net-of-cost gate for the IRRX overlay on a supplied panel.
    /// `roundTripBps` is the ROUND-TRIP (both fills) cost, charged at half per unit of one-way
    /// turnover — see `rebalanceSeries` COST ACCOUNTING. (Pass
    /// `StockSageNetEdge.defaultCosts(forSymbol:).roundTripBps` for an asset-class estimate.)
    /// `trials`/`varTrialSharpe` deflate for how many parameterizations were scanned (1 ⇒ no
    /// selection haircut). Returns nil if the panel is too thin to build ≥4 rebalances.
    nonisolated static func simulate(_ panel: Panel, lookback: Int, hold: Int, roundTripBps: Double,
                         folds: Int = 3, embargo: Int = 1,
                         trials: Int = 1, varTrialSharpe: Double = 0) -> SimResult? {
        let rebs = rebalanceSeries(panel, lookback: lookback, hold: hold, roundTripBps: roundTripBps)
        guard rebs.count >= 4 else { return nil }
        let gross = rebs.map { $0.grossReturn }
        let net = rebs.map { $0.netReturn }
        let grossFull = verdict(gross, trials: trials, varTrialSharpe: varTrialSharpe)
        let netFull = verdict(net, trials: trials, varTrialSharpe: varTrialSharpe)
        let oosNet = oosPooled(net, folds: folds, embargo: embargo)
        let netOOS = verdict(oosNet, trials: trials, varTrialSharpe: varTrialSharpe)
        let meanGross = gross.reduce(0, +) / Double(gross.count)
        let meanNet = net.reduce(0, +) / Double(net.count)
        // The gate uses the OOS read when it is computable, else the full-series net read.
        let gate = (netOOS ?? netFull)?.passes ?? false
        return SimResult(rebalances: rebs, grossReturns: gross, netReturns: net,
                         grossVerdictFull: grossFull, netVerdictFull: netFull,
                         netVerdictOOS: netOOS, meanGross: meanGross, meanNet: meanNet,
                         clearsNetOfCost: gate)
    }
}
