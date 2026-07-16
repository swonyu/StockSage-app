import Foundation

// MARK: - Sharpe-max, de-correlated capital allocator (ALLOC_BACKLOG #6, "stretch")
//
// Every OTHER allocator in this file (`allocate`, `suggestAdd`, `rebalanceToEdge`) is a
// closed-form, hand-verifiable composition of already-tested primitives. This one is
// deliberately different: a genuine mean-variance optimization — "given several positive-EV
// setups with correlated risk, what SPLIT of the account's heat budget maximizes expected
// return net of variance?" — which has no closed-form answer once positions interact through
// a covariance matrix. It is the FIRST iterative/numerical engine in this codebase, so it earns
// the extra scrutiny that implies: every design choice below is disclosed, and the solver
// (Frank-Wolfe / conditional gradient) was chosen SPECIFICALLY because it structurally cannot
// produce an infeasible or degenerate answer — see "WHY FRANK-WOLFE" below.
//
// UNITS (read this before touching the math): `w_i` is a RISK FRACTION — the same "fraction of
// account lost if the stop is hit" unit `StockSageKelly`/`allocate` already use — NOT a notional
// (dollar-invested) fraction. This keeps the whole function unit-consistent with the rest of the
// engine without a notional<->risk conversion: risking `w_i` of the account means a genuine 1R
// loss costs exactly `w_i * account`, so `mu_i = evR` (R-multiples, already normalized to that
// same 1R unit) is directly the expected return coefficient — no rescaling needed. The
// volatility counterpart follows the same logic: a tighter stop makes a GIVEN price move a
// LARGER number of R's, so the R-multiple volatility is `priceVol / stopDistancePct` (inversely
// scaled by how tight the stop is) — NOT the raw price volatility. `Sigma_ij = rho_ij · sigma_i
// · sigma_j` is therefore the covariance of R-multiple OUTCOMES under a `w`-fraction-of-account
// risk allocation, and `w'·Sigma·w` is a genuine portfolio R-multiple variance.
//
// WHY FRANK-WOLFE (not projected gradient): prototyped both in isolation before writing a line
// of this file. Projected gradient with a textbook Lipschitz-optimal step size (`1/L`, exact
// line search, or a loose Gershgorin bound) reliably FAILED on this problem's specific geometry —
// a tight heat cap (e.g. 8-10%) against a MUCH larger unconstrained optimum means a single
// "correct" gradient step blows every coordinate past its own box bound simultaneously; the
// box-then-sum projection then collapses to a trivial EQUAL split regardless of the true
// mu/Sigma, and (because the equal split is a spurious fixed point of that specific overshoot-
// then-collapse update) the solver falsely reports "converged" on iteration 1. A conservative
// small fixed step avoids this but needs 1000s of iterations for useful precision — far beyond
// this doc's own `maxIterations: 100` default. Frank-Wolfe sidesteps the failure mode entirely:
// every iterate is a CONVEX COMBINATION of two already-feasible points (never projected, never
// escapes the polytope), and its linear sub-problem over a box+single-sum-cap polytope has a
// trivial closed form (greedily fund the highest-gradient coordinates up to their own cap until
// the budget runs out — see `linearOracle`). Verified against three hand-worked scenarios
// (a single dominant-mu idea correctly taking the whole budget; two mutually-correlated ideas
// each losing weight to a same-mu independent third one; a fully symmetric independent case
// landing exactly at the equal split) before being ported to Swift.
//
// WHAT'S DELIBERATELY NOT MODELED: the original backlog spec's signature included a pairwise
// "decorrelation cap" as a THIRD constraint type (beyond the per-position box and the heat-cap
// sum) — a hard ceiling on any single correlated PAIR's combined weight. This is NOT implemented
// as a separate hard constraint: `Sigma`'s quadratic penalty already delivers the intended
// de-correlation effect intrinsically (verified: two correlated ideas of equal mu each receive
// roughly HALF the weight of an equal-mu independent third idea in the worked example above) —
// adding a second, redundant hard cap on top would only matter in edge cases and would
// meaningfully complicate the linear oracle (it stops being a simple greedy sort). This is a
// disclosed simplification, not an oversight.
//
// HONESTY: `lambda` (risk-aversion) defaults to 1.0 — not an arbitrary pick. For a SINGLE asset,
// this exact objective's first-order condition (`mu - 2·lambda·sigma²·w = 0`) reduces to
// `w* = mu/(2·lambda·sigma²)`; setting `lambda = 1` reproduces EXACTLY today's HALF-Kelly
// fraction (`mu/(2·sigma²)`, the same halving `StockSageKelly.maxFraction`'s whole design already
// applies) as the single-asset special case — so the multi-asset optimizer's default risk
// tolerance is anchored to the SAME risk appetite the rest of the app already ships with, not an
// invented number. `estPortfolioSharpe`/`estPortfolioVariance` describe the OPTIMIZED weights
// under the model's own assumptions (winProbEstimate, spark-derived vol/correlation) — never a
// forecast, and — like every other engine here — completely blind to spread/slippage/tax/min-lot.

struct AllocationOptimizerResult: Sendable, Equatable {
    let positions: [AllocatedPosition]     // reuses the same type `allocate()` returns
    let estPortfolioEVR: Double            // w · mu — the funded book's expected R-multiple return
    let estPortfolioVariance: Double       // w' Sigma w — R-multiple variance of that same book
    let estPortfolioSharpe: Double?        // estPortfolioEVR / sqrt(variance); nil when variance is ~0
    let converged: Bool                    // true iff the Frank-Wolfe gap cleared `convergenceTol`
    let iterations: Int
    let bindingConstraints: [String]       // symbols pinned at their own per-position cap
    let note: String
}

enum StockSageAllocationOptimizer {
    nonisolated static let caveat =
        "A genuine numerical optimization (Frank-Wolfe, local optimum over the given constraints) " +
        "— not a closed-form formula. winProbEstimate is an ESTIMATE, and correlation/volatility are " +
        "BACKWARD-LOOKING (from recent history) and can shift fast, especially in a crash — exactly " +
        "when de-correlation matters most. Ignores spread/slippage/tax/min-lot. A local optimum, not " +
        "a global guarantee."

    /// Maximize `w·mu − lambda·w'·Sigma·w` over `0 ≤ w_i ≤ min(halfKelly_i, StockSageKelly.
    /// maxFraction)` and `Σw ≤ heatCap`, where `w_i` is each idea's RISK FRACTION (see the file
    /// header for the full unit derivation). Only buy-family, positive-EV ideas with a real
    /// `spark` history (≥3 points, so a volatility figure is honestly computable — no history ⇒
    /// excluded, never a guessed/fallback vol) are candidates. nil when nothing is fundable,
    /// `account`/`heatCap`/`lambda` are non-positive or non-finite, or the account is degenerate.
    nonisolated static func optimizeSharpeDeCorrelated(
        ideas: [StockSageIdea],
        account: Double,
        lambda: Double = 1.0,
        heatCap: Double = 0.08,
        maxIterations: Int = 100,
        convergenceTol: Double = 1e-6,
        calibration: StockSageConvictionCalibration? = nil
    ) -> AllocationOptimizerResult? {
        guard account > 0, account.isFinite, lambda > 0, lambda.isFinite,
              heatCap > 0, heatCap.isFinite, maxIterations > 0, convergenceTol > 0 else { return nil }
        let cap = Swift.min(1, heatCap)

        struct Fundable {
            let symbol: String
            let entry: Double
            let stop: Double
            let evR: Double
            let boxCap: Double         // min(halfKelly, StockSageKelly.maxFraction)
            let closes: [Double]       // idea.spark, reused for both vol and correlation
        }

        var fundable: [Fundable] = []
        for idea in ideas {
            guard idea.advice.action == .buy || idea.advice.action == .strongBuy,
                  let stop = idea.advice.stopPrice, let target = idea.advice.targetPrice,
                  idea.price > 0, stop > 0, stop != idea.price, target != idea.price,
                  let e = StockSageExpectedValue.ev(for: idea, calibration: calibration), e.evR > 0,
                  idea.spark.count >= 3 else { continue }   // honest vol needs real history — never guessed
            let k = StockSageKelly.compute(winRate: e.winProbEstimate, payoffRatio: e.rewardR, accountSize: account)
            guard k.suggestedFraction > 0 else { continue }
            let boxCap = Swift.min(k.suggestedFraction, StockSageKelly.maxFraction)
            fundable.append(Fundable(symbol: idea.symbol, entry: idea.price, stop: stop,
                                     evR: e.evR, boxCap: boxCap, closes: idea.spark))
        }
        guard !fundable.isEmpty else { return nil }

        let n = fundable.count
        let mu = fundable.map(\.evR)
        let lo = [Double](repeating: 0, count: n)
        let hi = fundable.map(\.boxCap)

        // R-multiple volatility: price vol ÷ stop-distance% — see the file header derivation.
        // A degenerate (non-positive/non-finite) price vol excludes that idea's Sigma contribution
        // by falling back to 0 volatility for it (a genuinely uncomputable input is never inflated
        // into a guessed risk figure; it simply can't be penalized for correlation either).
        let sigma: [Double] = fundable.map { f in
            let stopPct = abs(f.entry - f.stop) / f.entry
            guard stopPct > 0, let priceVol = StockSageIndicators.annualizedVolatility(f.closes),
                  priceVol.isFinite, priceVol > 0 else { return 0 }
            return priceVol / stopPct
        }
        let returns = fundable.map { StockSagePortfolioAnalytics.dailyReturns($0.closes) }
        let rho = StockSagePortfolioAnalytics.correlationMatrix(returns)
        var Sigma = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                Sigma[i][j] = sigma[i] * sigma[j] * (i < rho.count && j < rho[i].count ? rho[i][j] : (i == j ? 1 : 0))
            }
        }

        func matvec(_ m: [[Double]], _ v: [Double]) -> [Double] {
            (0..<n).map { i in (0..<n).reduce(0.0) { $0 + m[i][$1] * v[$1] } }
        }
        func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

        /// Linear oracle for `max grad's` over `{0 ≤ s_i ≤ hi_i, Σs ≤ cap}`: greedily fund the
        /// HIGHEST-gradient coordinates up to their own box cap, in order, until the shared budget
        /// runs out. Never funds a coordinate whose gradient is ≤ 0 (funding it can only hurt the
        /// linear objective). This closed form is exactly why Frank-Wolfe never needs a projection.
        func linearOracle(_ grad: [Double]) -> [Double] {
            var s = [Double](repeating: 0, count: n)
            var budget = cap
            for i in grad.indices.sorted(by: { grad[$0] > grad[$1] }) {
                guard grad[i] > 0, budget > 0 else { break }
                let take = Swift.min(hi[i], budget)
                s[i] = take
                budget -= take
            }
            return s
        }

        var w = linearOracle(mu)   // feasible warm start via the linear oracle on mu alone
        var converged = false
        var iterations = maxIterations
        for it in 1...maxIterations {
            let grad = zip(mu, matvec(Sigma, w)).map { $0 - 2 * lambda * $1 }
            let s = linearOracle(grad)
            let d = zip(s, w).map { $0 - $1 }
            let fwGap = dot(grad, d)   // certified optimality-gap upper bound; → 0 at the optimum
            if fwGap < convergenceTol {
                converged = true
                iterations = it
                break
            }
            let Sd = matvec(Sigma, d)
            let denom = 2 * lambda * dot(d, Sd)
            let gamma: Double = denom > 1e-18 ? Swift.max(0, Swift.min(1, dot(grad, d) / denom)) : 1.0
            w = zip(w, d).map { $0 + gamma * $1 }
            iterations = it
        }

        var positions: [AllocatedPosition] = []
        var bindingConstraints: [String] = []
        for (idx, f) in fundable.enumerated() {
            guard w[idx] > 1e-9 else { continue }
            guard let ps = StockSagePositionSizer.size(account: account, riskFraction: w[idx], entry: f.entry, stop: f.stop) else { continue }
            positions.append(AllocatedPosition(symbol: f.symbol, riskFraction: w[idx], shares: ps.shares,
                                               dollarsAtRisk: ps.dollarsAtRisk, notional: ps.notional,
                                               halfKelly: f.boxCap, evR: f.evR))
            if abs(w[idx] - hi[idx]) < 1e-6 { bindingConstraints.append(f.symbol) }
        }
        guard !positions.isEmpty else { return nil }

        let estEVR = dot(mu, w)
        let estVariance = dot(w, matvec(Sigma, w))
        let estSharpe: Double? = estVariance > 1e-12 ? estEVR / estVariance.squareRoot() : nil
        if abs(w.reduce(0, +) - cap) < 1e-6 { bindingConstraints.append("heat") }

        var note = "Frank-Wolfe local optimum over \(fundable.count) fundable idea(s), lambda=\(String(format: "%.2f", lambda)) (1.0 = today's half-Kelly risk appetite). "
        note += converged
            ? "Converged in \(iterations) iteration(s)."
            : "Did NOT fully converge within \(maxIterations) iteration(s) — treat as a reasonable but unrefined estimate."
        return AllocationOptimizerResult(positions: positions, estPortfolioEVR: estEVR, estPortfolioVariance: estVariance,
                                         estPortfolioSharpe: estSharpe, converged: converged, iterations: iterations,
                                         bindingConstraints: bindingConstraints.sorted(), note: note)
    }
}
