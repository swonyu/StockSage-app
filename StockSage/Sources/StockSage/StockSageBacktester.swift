import Foundation

// MARK: - StockSageBacktester
//
// A walk-forward backtest of the advisor's LONG rules over one symbol's candle
// history — the honesty check on the whole "ideas" feature. Pure + deterministic
// so it's unit-tested, and built to NOT lie to the owner:
//
//  • No look-ahead: the decision at bar `i` uses ONLY closes/highs/lows up to and
//    including `i`; the entry fills at bar `i+1`'s OPEN (data that exists the next
//    session). We never peek at a bar to decide trading it.
//  • Conservative tie-break: if a single bar touches both the stop and the target,
//    we assume the STOP hit first (worst case), so results aren't flattered.
//  • One position at a time: scanning resumes only after a trade closes — no
//    overlapping, no compounding fantasy.
//  • Honesty surfaced, not hidden: we report trade COUNT and max drawdown, and
//    flag small samples (`isSignificant`). Survivorship bias is inherent (we test
//    today's listed symbols) and overfitting is bounded (few FIXED rules, not
//    per-symbol optimization) — both are called out in the UI caveat.
//
// Past performance is not predictive; this measures whether the rules *held up*,
// nothing more.

/// One simulated trade.
struct BacktestTrade: Sendable, Equatable {
    enum Outcome: String, Sendable { case target, stop, openAtEnd, timeStop }
    let entryIndex: Int
    let exitIndex: Int
    let entry: Double
    let exit: Double
    /// Result in R-multiples: (exit − entry) ÷ (entry − stop). +2 = hit a 2:1 target.
    let r: Double
    let outcome: Outcome
    /// The advisor's conviction AT ENTRY — recorded so conviction can be CALIBRATED against the
    /// realized outcome (see StockSageConvictionCalibration). Defaulted so older constructions
    /// (tests) stay valid. `won` for calibration is `r > 0`.
    let conviction: Double

    nonisolated init(entryIndex: Int, exitIndex: Int, entry: Double, exit: Double,
                     r: Double, outcome: Outcome, conviction: Double = 0) {
        self.entryIndex = entryIndex; self.exitIndex = exitIndex
        self.entry = entry; self.exit = exit; self.r = r; self.outcome = outcome
        self.conviction = conviction
    }
}

/// Aggregate, honestly-framed backtest metrics.
struct BacktestResult: Sendable, Equatable {
    let trades: Int
    let wins: Int
    let winRate: Double        // 0–1
    let avgR: Double           // expectancy per trade, in R
    let totalR: Double
    let maxDrawdownR: Double   // worst peak-to-trough of cumulative R
    let sharpe: Double         // per-trade mean ÷ stdev (0 when <2 trades or zero variance)
    let avgHoldBars: Double
    let avgWinR: Double        // average R of winning trades
    let avgLossR: Double       // average R of losing trades, as a POSITIVE magnitude
    /// P(true per-trade Sharpe > 0), the Probabilistic Sharpe Ratio haircut for sample size + skew
    /// + fat tails. nil when there are too few trades (<4) or no dispersion to judge. A raw Sharpe
    /// from a short, skewed record overstates the edge; this says how likely it is actually positive.
    let probabilisticSharpe: Double?
    /// In-sample vs out-of-sample edge decay (overfit red-flag). nil for too few trades to split.
    let decay: WalkForwardDecay?
    /// Trades still open when history ran out — they inflate avgR/winRate vs truly closed trades.
    /// Non-zero means the backtest result is optimistic; the UI must say so.
    let openAtEndCount: Int
    /// Most negative single-trade R (rs.min()) — the realized left-tail, for the trail-vs-fixed
    /// truncation display (quant_engine_II.md checklist #3). 0 when trades is empty (== .empty).
    let worstTradeR: Double
    /// Per-trade sample stdev of R (n−1), the SAME `sd` summarize() already computes for Sharpe —
    /// exposed here rather than recomputed, so the two-channel display reads one number twice.
    let stdevR: Double

    /// Defaulted new fields so older constructions (empty, tests) stay valid.
    nonisolated init(trades: Int, wins: Int, winRate: Double, avgR: Double, totalR: Double,
                     maxDrawdownR: Double, sharpe: Double, avgHoldBars: Double,
                     avgWinR: Double = 0, avgLossR: Double = 0, probabilisticSharpe: Double? = nil,
                     decay: WalkForwardDecay? = nil, openAtEndCount: Int = 0,
                     worstTradeR: Double = 0, stdevR: Double = 0) {
        self.trades = trades; self.wins = wins; self.winRate = winRate; self.avgR = avgR
        self.totalR = totalR; self.maxDrawdownR = maxDrawdownR; self.sharpe = sharpe
        self.avgHoldBars = avgHoldBars; self.avgWinR = avgWinR; self.avgLossR = avgLossR
        self.probabilisticSharpe = probabilisticSharpe
        self.decay = decay; self.openAtEndCount = openAtEndCount
        self.worstTradeR = worstTradeR; self.stdevR = stdevR
    }

    /// Below this, the numbers are noise — the UI must say so.
    var isSignificant: Bool { trades >= 20 }

    /// t-statistic of the per-trade mean return = per-trade Sharpe × √trades. The honest
    /// significance gauge. 0 when <2 trades.
    var tStat: Double { trades >= 2 ? sharpe * Double(trades).squareRoot() : 0 }

    /// Does the edge clear the t > 3 bar? The deep-research (Harvey-Liu-Zhu 2016) sets the hurdle at
    /// t > 3.0 — NOT the textbook 2.0 — to survive the multiple-testing / backtest-overfitting
    /// haircut. NECESSARY, not sufficient: it ignores how many strategy variants were actually tried,
    /// which only raises the true hurdle further.
    var clearsMultipleTestingBar: Bool { tStat > 3.0 }

    /// One honest line on statistical strength, for the UI.
    var significanceVerdict: String {
        if trades < 20 { return "Only \(trades) trades — not statistically meaningful yet." }
        if tStat > 3.0 { return String(format: "t = %.1f — clears the t>3 multiple-testing bar (necessary, not sufficient).", tStat) }
        if tStat > 2.0 { return String(format: "t = %.1f — significant at 2σ but BELOW the t>3 bar for a mined backtest; treat as unproven.", tStat) }
        return String(format: "t = %.1f — not significant; likely noise.", tStat)
    }

    nonisolated static let empty = BacktestResult(trades: 0, wins: 0, winRate: 0, avgR: 0,
                                                  totalR: 0, maxDrawdownR: 0, sharpe: 0, avgHoldBars: 0)
}

/// Edge DECAY across time: the pooled Sharpe/avgR answers "did this work overall?" but hides whether
/// the edge survived into UNSEEN data. Split the (chronological) trades into in-sample (first part)
/// and out-of-sample (last `oosFraction`) and compare avg R. A robust rule keeps most of its edge OOS;
/// an overfit one collapses (ratio → 0 or negative). Suspicion, not proof — pair with sample size.
struct WalkForwardDecay: Sendable, Equatable {
    let isAvgR: Double
    let oosAvgR: Double
    let decayRatio: Double      // oosAvgR / isAvgR; 0 when isAvgR ≤ 0 (no in-sample edge to decay from)
    let oosTrades: Int
    let oosSignificant: Bool    // ≥ 20 OOS trades — below this the OOS slice is itself noise
    /// Had a real in-sample edge but kept less than half of it out-of-sample → likely overfit. Gated on
    /// `oosSignificant`: with fewer than ~20 OOS trades the slice is itself noise, so a low decay ratio
    /// there is not evidence of overfitting — the UI shows a "thin OOS" caveat instead of a false RED FLAG.
    nonisolated var isRedFlag: Bool { oosSignificant && isAvgR > 0 && decayRatio < 0.5 }
}

extension StockSageBacktester {
    /// Chronological in-sample/out-of-sample split of backtest trades. `trades` come out of run() in
    /// entry order (the cursor only advances), so a positional split IS a time split — no re-sort.
    nonisolated static func walkForwardDecay(_ trades: [BacktestTrade],
                                             oosFraction: Double = 0.30) -> WalkForwardDecay {
        let n = trades.count
        guard n >= 2, oosFraction > 0, oosFraction < 1 else {
            return WalkForwardDecay(isAvgR: 0, oosAvgR: 0, decayRatio: 0, oosTrades: 0, oosSignificant: false)
        }
        let oosCount = Swift.max(1, Int((Double(n) * oosFraction).rounded()))
        let split = n - oosCount
        let isSlice = trades[0..<split], oosSlice = trades[split..<n]
        let isAvg = isSlice.isEmpty ? 0 : isSlice.map(\.r).reduce(0, +) / Double(isSlice.count)
        let oosAvg = oosSlice.isEmpty ? 0 : oosSlice.map(\.r).reduce(0, +) / Double(oosSlice.count)
        let ratio = isAvg > 0 ? oosAvg / isAvg : 0
        return WalkForwardDecay(isAvgR: isAvg, oosAvgR: oosAvg, decayRatio: ratio,
                                oosTrades: oosSlice.count, oosSignificant: oosSlice.count >= 20)
    }
}

/// How an open position is closed in the backtest. `.allAtTarget` is the original
/// behavior (ride to the fixed 2:1 target or the stop); the other modes are measured
/// head-to-head against it via `run(_:exitMode:)`. (chandelierTrail / scaleOutLadder land
/// in EXIT #2/#3 once their engines are wired — only the cases below are simulated today.)
enum ExitMode: Sendable, Equatable {
    case allAtTarget
    case timeStop(maxBars: Int)
    case chandelierTrail(atrMult: Double, period: Int)
    case scaleOutLadder(rungs: Int)
}

enum StockSageBacktester {

    /// Walk forward over `history`. `warmup` bars are skipped so the 200-day trend
    /// and the other indicators are valid before the first decision (use a multi-year
    /// history so there's room to trade after the warmup).
    /// `costs` (optional) charges a round-trip friction (spread+slippage, in bps of the
    /// fill price) against EVERY trade's R — so the equity curve reflects what you'd
    /// actually net, not a frictionless fantasy. nil = the original cost-free result,
    /// byte-for-byte (existing callers/tests unchanged). Pass e.g.
    /// `StockSageNetEdge.defaultCosts(forSymbol:)` for an asset-class default.
    nonisolated static func run(_ history: StockSagePriceHistory, warmup: Int = 200,
                                costs: StockSageNetEdge.CostAssumption? = nil,
                                exitMode: ExitMode = .allAtTarget,
                                benchmark: StockSagePriceHistory? = nil) -> BacktestResult {
        summarize(runTrades(history, warmup: warmup, costs: costs, exitMode: exitMode, benchmark: benchmark))
    }

    /// Both the aggregate result AND the raw trades from ONE simulation pass — so a caller that
    /// wants both (e.g. strategy stats + conviction calibration) doesn't run the sim twice.
    nonisolated static func runDetailed(_ history: StockSagePriceHistory, warmup: Int = 200,
                                        costs: StockSageNetEdge.CostAssumption? = nil,
                                        exitMode: ExitMode = .allAtTarget,
                                        benchmark: StockSagePriceHistory? = nil)
        -> (result: BacktestResult, trades: [BacktestTrade]) {
        let trades = runTrades(history, warmup: warmup, costs: costs, exitMode: exitMode, benchmark: benchmark)
        return (summarize(trades), trades)
    }

    /// The raw simulated trades (each carrying its entry `conviction`) — the training set for
    /// conviction calibration and for any per-trade analysis. `run` is exactly
    /// `summarize(runTrades(...))`, so the aggregate result is unchanged.
    nonisolated static func runTrades(_ history: StockSagePriceHistory, warmup: Int = 200,
                                      costs: StockSageNetEdge.CostAssumption? = nil,
                                      exitMode: ExitMode = .allAtTarget,
                                      benchmark: StockSagePriceHistory? = nil) -> [BacktestTrade] {
        let closes = history.closes, opens = history.opens, highs = history.highs, lows = history.lows
        let n = closes.count
        guard n > warmup + 5, opens.count == n, highs.count == n, lows.count == n else { return [] }

        // VOLUME FIDELITY: forward real volumes ONLY when the series is fully aligned to closes
        // (matches advise()'s nil-gate; FX/indices with empty/short volume arrays pass nil). The
        // live path forwards history.volumes unconditionally and advise() handles zero-volume
        // internally — so the only gap to close here is the alignment precondition.
        let volumesAligned = history.volumes.count == n

        // BENCHMARK DATE-ALIGNMENT: relativeStrength compares each side's TRAILING-126-bar return,
        // so the benchmark slice handed to advise() for symbol-bar i MUST end on the SAME CALENDAR
        // DATE as bar i — NOT the same index (symbol & benchmark differ in length/holidays). Walk a
        // forward-only pointer `bj` over benchmark.dates: for bar i (date d = history.dates[i]) it is
        // the largest j with benchmark.dates[j] <= d (nearest-prior). dates are ascending on both
        // sides and i only advances, so bj only advances → O(n) total.
        let benchDates = benchmark?.dates
        let benchCloses = benchmark?.closes
        let datesUsable = (benchDates?.count == benchCloses?.count) && history.dates.count == n
        var bj = -1   // last benchmark index with date <= current symbol date; -1 = none yet

        var trades: [BacktestTrade] = []
        var i = warmup
        while i < n - 1 {
            // Volumes for this decision: same-array prefix, only when aligned.
            let vol: [Double]? = volumesAligned ? Array(history.volumes[0...i]) : nil

            // Date-aligned benchmark prefix ending on or before symbol bar i's date.
            var benchPrefix: [Double]? = nil
            if datesUsable, let bd = benchDates, let bc = benchCloses {
                let d = history.dates[i]
                while bj + 1 < bd.count, bd[bj + 1] <= d { bj += 1 }   // advance to nearest-prior
                if bj >= 0 { benchPrefix = Array(bc[0...bj]) }          // else nil → relStr nil-gated
            }

            // Decide using ONLY data available at the close of bar i — NOW with the same volume +
            // benchmark terms the LIVE path feeds advise(), so the backtest measures the SHIPPED rule.
            let advice = StockSageAdvisor.advise(closes: Array(closes[0...i]),
                                                 highs: Array(highs[0...i]),
                                                 lows: Array(lows[0...i]),
                                                 volumes: vol,
                                                 benchmarkCloses: benchPrefix)
            guard advice.action == .buy || advice.action == .strongBuy,
                  let stop = advice.stopPrice else { i += 1; continue }

            // Fill at the NEXT bar's open (no look-ahead). Size the target 2:1 off
            // the actual fill. Skip if the open already gapped below the stop.
            let entryIdx = i + 1
            let entry = opens[entryIdx]
            let risk = entry - stop
            guard risk > 0 else { i += 1; continue }
            let target = entry + 2 * risk

            // Walk forward to the exit dictated by `exitMode` (stop always wins ties).
            let (exitIdx, exitPrice, outcome) = simulateExit(
                entryIdx: entryIdx, stop: stop, target: target,
                opens: opens, highs: highs, lows: lows, closes: closes, n: n, mode: exitMode)

            // Round-trip friction (in price units) eats into realized R, measured against the
            // PLANNED 1R risk (entry−stop). This is the honest R-multiple: a stop-out costs your
            // risk distance PLUS the friction, so a loser nets WORSE than −1R (e.g. −1.05), and a
            // winner banks less than its gross R. (An audit proposed dividing by risk+cost for
            // "NetEdge consistency" — REJECTED: that redefines the unit and makes losers read as
            // exactly −1R, HIDING the friction. NetEdge's net R:R is a different quantity.)
            // costs == nil → costPerShare 0 → r == (exit − entry)/risk, byte-for-byte.
            let costPerShare = costs.map { Swift.max(0, $0.roundTripBps) / 10_000 * entry } ?? 0
            let r = (exitPrice - entry - costPerShare) / risk
            trades.append(BacktestTrade(entryIndex: entryIdx, exitIndex: exitIdx,
                                        entry: entry, exit: exitPrice, r: r, outcome: outcome,
                                        conviction: advice.conviction))
            i = exitIdx + 1   // one position at a time — resume after the close
        }
        return trades
    }

    /// Resolve a single trade's exit per `mode`. `.allAtTarget` is the original walk — the
    /// first stop or 2:1 target touch, stop winning ties, adverse-gap honest (a stop that
    /// gaps through fills at the worse open, not magically at the stop). `.timeStop(maxBars)`
    /// adds: if neither level is hit within `maxBars` bars of entry, close at that bar's close.
    /// `internal` (not private) so the exit logic is unit-tested directly against hand-computed
    /// fills. For `.allAtTarget` this is byte-for-byte the pre-seam exit-walk.
    nonisolated static func simulateExit(entryIdx: Int, stop: Double, target: Double,
                                         opens: [Double], highs: [Double], lows: [Double], closes: [Double],
                                         n: Int, mode: ExitMode)
        -> (exitIdx: Int, exitPrice: Double, outcome: BacktestTrade.Outcome) {
        // Scale-out ladder: a multi-fill exit collapsed to one equivalent (blended-R) fill so
        // run()'s single-exit accounting still holds. Degenerate ladder → fall through to the
        // fixed walk below (no crash).
        if case let .scaleOutLadder(rungs) = mode {
            let entry = opens[entryIdx]
            if entry > stop,
               let res = scaleOutLadderExit(entryIdx: entryIdx, entry: entry, stop: stop, target: target,
                                            opens: opens, highs: highs, lows: lows, closes: closes, n: n, rungs: rungs) {
                return (res.exitIdx, entry + res.blendedR * (entry - stop), res.outcome)
            }
        }
        // Precompute the ratcheting trail once for the chandelier mode (nil otherwise — and
        // nil if ATR can't be computed, in which case we fall back to the fixed stop, no crash).
        var trail: [Double]? = nil
        if case let .chandelierTrail(atrMult, period) = mode {
            trail = trailLevels(highs: highs, lows: lows, closes: closes,
                                entryIndex: entryIdx, atrMult: atrMult, period: period)
        }
        var j = entryIdx
        while j < n {
            // Effective stop this bar. For the chandelier trail, use the PRIOR bar's ratcheted
            // level (data through j−1 only — no look-ahead), never looser than the initial stop.
            var effStop = stop
            if let trail, j > entryIdx + 1 {
                let pi = (j - 1) - (entryIdx + 1)
                if pi >= 0, pi < trail.count { effStop = Swift.max(stop, trail[pi]) }
            }
            if lows[j] <= effStop { return (j, Swift.min(effStop, opens[j]), .stop) }
            if highs[j] >= target { return (j, target, .target) }
            if case let .timeStop(maxBars) = mode, j - entryIdx >= maxBars {
                return (j, closes[j], .timeStop)
            }
            j += 1
        }
        return (n - 1, closes[n - 1], .openAtEnd)
    }

    /// Scale-out ladder exit for a LONG: bank an equal fraction at each `StockSagePartialLadder`
    /// rung as price reaches it, the remainder riding. Fills happen at the RESTING rung level
    /// even when a bar gaps through it (a gap can't pay you more than your limit). The stop
    /// applies to whatever is still open and WINS ties (checked before rungs). Returns the
    /// blended realized R across all chunks, the bar the position fully closes, and a
    /// representative outcome. nil if the ladder is degenerate. Realized R ≤ the ladder's
    /// theoretical blendedExitR — banking early can only lower it (equal only when every rung
    /// fills). `internal` so it's unit-tested directly.
    nonisolated static func scaleOutLadderExit(entryIdx: Int, entry: Double, stop: Double, target: Double,
                                               opens: [Double], highs: [Double], lows: [Double], closes: [Double],
                                               n: Int, rungs: Int)
        -> (exitIdx: Int, blendedR: Double, outcome: BacktestTrade.Outcome)? {
        guard entry > stop,
              let ladder = StockSagePartialLadder.levels(entry: entry, stop: stop, target: target, rungs: rungs)
        else { return nil }
        let risk = entry - stop
        var remaining = 1.0, realized = 0.0, nextRung = 0
        var j = entryIdx
        while j < n {
            // Stop wins ties: the still-open fraction exits at the gap-honest stop fill.
            if lows[j] <= stop {
                realized += remaining * (Swift.min(stop, opens[j]) - entry) / risk
                return (j, realized, .stop)
            }
            // Bank each rung reached this bar at its RESTING price (not the gapped high).
            while nextRung < ladder.rungs.count, highs[j] >= ladder.rungs[nextRung].price {
                realized += ladder.rungs[nextRung].fraction * ladder.rungs[nextRung].rMultiple
                remaining -= ladder.rungs[nextRung].fraction
                nextRung += 1
            }
            if nextRung >= ladder.rungs.count { return (j, realized, .target) }   // last rung == target
            j += 1
        }
        realized += remaining * (closes[n - 1] - entry) / risk   // remainder closes at the last bar
        return (n - 1, realized, .openAtEnd)
    }

    /// Ratcheting Chandelier trail for a LONG. For each bar AFTER entry, the raw stop is
    /// (highest high SINCE ENTRY) − atrMult·ATR(through that bar); the emitted level is then
    /// ratcheted so it can only RISE — the up-only discipline `StockSageTrailingStop.suggest`
    /// deliberately omits, and the single behavior that most removes blow-ups. Each level uses
    /// only data through its own bar (no look-ahead). Returns one level per post-entry bar
    /// (entryIndex+1 … last); empty when entry IS the last bar; nil on misaligned arrays, a bad
    /// index, or when ATR is NEVER computable for the whole post-entry range. ATR needs > period
    /// bars of history, so if entryIndex is early in the supplied window it may not be computable
    /// yet on the first few post-entry bars — those bars simply carry the sentinel (no ratchet
    /// yet, so `Swift.max(stop, level)` downstream falls back to the fixed stop) rather than
    /// aborting the whole trail; the ratchet picks up once ATR becomes computable. On a clean
    /// uptrend the final element equals `suggest(...).level` on the same window (consistency
    /// with the static engine).
    nonisolated static func trailLevels(highs: [Double], lows: [Double], closes: [Double],
                                        entryIndex: Int, atrMult: Double = 3, period: Int = 14) -> [Double]? {
        let n = closes.count
        guard highs.count == n, lows.count == n, n > 0,
              entryIndex >= 0, entryIndex < n, atrMult > 0 else { return nil }
        if entryIndex == n - 1 { return [] }            // no bars after entry
        var levels: [Double] = []
        var anchorHigh = highs[entryIndex]              // highest high since entry (monotonic ↑)
        var ratchet = -Double.greatestFiniteMagnitude
        var atrEverComputed = false
        for b in (entryIndex + 1)..<n {
            anchorHigh = Swift.max(anchorHigh, highs[b])
            if let atr = StockSageIndicators.atr(highs: Array(highs[0...b]), lows: Array(lows[0...b]),
                                                 closes: Array(closes[0...b]), period: period) {
                ratchet = Swift.max(ratchet, anchorHigh - atrMult * atr)   // up-only
                atrEverComputed = true
            }
            levels.append(ratchet)   // one entry per bar, even before ATR is computable (see above)
        }
        return atrEverComputed ? levels : nil
    }

    /// Contiguous, NON-overlapping test windows that tile the post-warmup region [warmup, n).
    /// Pure index math (no data) so the partition itself is unit-tested. Empty if folds<1 or
    /// there are no post-warmup bars.
    nonisolated static func foldRanges(n: Int, warmup: Int, folds: Int) -> [Range<Int>] {
        guard folds > 0, n > warmup else { return [] }
        let testLen = n - warmup
        return (0..<folds).map { k in
            (warmup + k * testLen / folds) ..< (warmup + (k + 1) * testLen / folds)
        }
    }

    /// Walk-forward / out-of-sample stability: run() over each fold's test window separately,
    /// so the owner sees whether the edge HOLDS across time or was one lucky regime. Each fold
    /// gets its own `warmup` prefix of preceding bars (shared history, NOT counted trades — the
    /// test windows never overlap), then trades only its window. A strategy that worked in one
    /// stretch shows degraded avgR in the others; thin folds carry isSignificant == false so the
    /// UI can't over-trust them. Empty when the history is too short to fold.
    nonisolated static func walkForward(_ history: StockSagePriceHistory, warmup: Int = 200,
                                        folds: Int = 3) -> [BacktestResult] {
        let n = history.closes.count
        guard history.opens.count == n, history.highs.count == n, history.lows.count == n,
              history.dates.count == n, history.volumes.count == n else { return [] }
        return foldRanges(n: n, warmup: warmup, folds: folds).map { range in
            let sliceStart = range.lowerBound - warmup    // ≥ 0 by construction
            guard sliceStart >= 0 else { return .empty }
            return run(subHistory(history, from: sliceStart, to: range.upperBound), warmup: warmup)
        }
    }

    /// A contiguous [lo, hi) slice of a history across every parallel array.
    private nonisolated static func subHistory(_ h: StockSagePriceHistory, from lo: Int, to hi: Int)
        -> StockSagePriceHistory {
        StockSagePriceHistory(symbol: h.symbol,
                              dates: Array(h.dates[lo..<hi]), opens: Array(h.opens[lo..<hi]),
                              highs: Array(h.highs[lo..<hi]), lows: Array(h.lows[lo..<hi]),
                              closes: Array(h.closes[lo..<hi]), volumes: Array(h.volumes[lo..<hi]))
    }

    /// Aggregate the simulated trades into honest metrics. `internal` (not private) so the
    /// aggregation math is unit-tested directly with synthetic trades.
    nonisolated static func summarize(_ trades: [BacktestTrade]) -> BacktestResult {
        guard !trades.isEmpty else { return .empty }
        let rs = trades.map(\.r)
        let winRs = rs.filter { $0 > 0 }
        let lossRs = rs.filter { $0 < 0 }
        let wins = winRs.count
        let totalR = rs.reduce(0, +)
        let avgR = totalR / Double(rs.count)
        let avgWinR = winRs.isEmpty ? 0 : winRs.reduce(0, +) / Double(winRs.count)
        let avgLossR = lossRs.isEmpty ? 0 : -lossRs.reduce(0, +) / Double(lossRs.count)   // positive magnitude

        // Max drawdown of the cumulative-R curve.
        var cum = 0.0, peak = 0.0, maxDD = 0.0
        for r in rs { cum += r; peak = Swift.max(peak, cum); maxDD = Swift.max(maxDD, peak - cum) }

        // Per-trade Sharpe (mean ÷ stdev); 0 when there's no dispersion to measure.
        let sd: Double = {
            guard rs.count > 1 else { return 0 }
            let variance = rs.reduce(0) { $0 + ($1 - avgR) * ($1 - avgR) } / Double(rs.count - 1)
            return variance.squareRoot()
        }()
        let sharpe = sd > 0 ? avgR / sd : 0
        let avgHold = trades.map { Double($0.exitIndex - $0.entryIndex) }.reduce(0, +) / Double(trades.count)

        // Deflate the raw Sharpe for sample size + skew/kurtosis (PSR). nil when too few trades
        // (<4) or no dispersion — the engine returns nil there, never a fabricated confidence.
        let psr: Double? = {
            guard sd > 0, let m = StockSageDeflatedSharpe.moments(rs) else { return nil }
            return StockSageDeflatedSharpe.probabilisticSharpe(observedSharpe: sharpe, nTrades: trades.count,
                                                               skew: m.skew, kurtosis: m.kurtosis)
        }()
        // In-sample vs out-of-sample edge decay (overfit guard). Needs enough trades for a real
        // 70/30 split (≥ 8 → OOS slice ≥ 2); below that it's meaningless, so leave it nil.
        let decay = trades.count >= 8 ? walkForwardDecay(trades) : nil

        let openAtEnd = trades.filter { $0.outcome == .openAtEnd }.count
        return BacktestResult(trades: trades.count, wins: wins,
                              winRate: Double(wins) / Double(trades.count),
                              avgR: avgR, totalR: totalR, maxDrawdownR: maxDD,
                              sharpe: sharpe, avgHoldBars: avgHold,
                              avgWinR: avgWinR, avgLossR: avgLossR, probabilisticSharpe: psr,
                              decay: decay, openAtEndCount: openAtEnd,
                              worstTradeR: rs.min() ?? 0, stdevR: sd)
    }
}
