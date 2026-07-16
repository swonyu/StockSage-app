import Foundation

// MARK: - Portfolio risk analytics
//
// A full backward-looking risk/return suite over the owner's holdings, computed
// from a value-weighted daily portfolio return series. Pure + deterministic →
// unit-tested. Evidence/intent: MARKETS_INTELLIGENCE_RESEARCH.md §6 (diversify by
// RISK; a Sharpe of 0.3–0.8 is typical, 1+ is good; max drawdown is the real-world
// worst-case; lower cross-holding correlation = genuine diversification).
//
// Honest by construction: these are historical stats over whatever overlapping
// history exists, NOT a forecast — small samples and shifting correlations limit
// reliability, and every surface says so.

struct PortfolioAnalytics: Sendable, Equatable {
    let annualizedReturn: Double      // %, compounded
    let annualizedVolatility: Double  // %
    let sharpe: Double?               // (return − rf≈0) ÷ vol; nil = undefined (zero vol)
    let sortino: Double?              // return ÷ downside deviation; nil = undefined (zero downside)
    let maxDrawdown: Double           // %, positive magnitude (worst peak→trough)
    let calmar: Double?               // annualizedReturn ÷ maxDrawdown; nil = undefined (zero drawdown)
    let valueAtRisk95: Double         // %, 1-day historical 95% VaR (positive = a loss)
    let cVaR95: Double                // %, 1-day conditional VaR / expected shortfall: average loss GIVEN the VaR threshold is breached (positive = loss)
    let avgCorrelation: Double        // −1…1, average pairwise across holdings
    let diversificationScore: Double  // 0…100 (higher = better diversified)
    let holdingsAnalyzed: Int
    let observations: Int             // overlapping daily samples used
    let caveat: String
}

/// A labeled correlation matrix for the heatmap (symbols + symmetric matrix).
struct CorrelationMatrix: Sendable, Equatable {
    let symbols: [String]
    let matrix: [[Double]]
    /// Audit 2026-07-12 (ideas-card F3): parallel defined-ness mask (see `correlationDefinedMask`).
    /// `false` = the pair is undefined (zero-variance series) and `matrix` holds a display-only 0 that
    /// must render as "—", not a green "independent" cell. Defaults to all-defined so existing
    /// construction (and decode of any older value) is unchanged; the heatmap builder populates it.
    var defined: [[Bool]] = []
    /// Is cell (i,j) a genuinely measured correlation? Out-of-range or empty mask → treat as defined
    /// (fail toward the prior behavior, never crash).
    nonisolated func isDefined(_ i: Int, _ j: Int) -> Bool {
        guard i < defined.count, j < defined[i].count else { return true }
        return defined[i][j]
    }
}

enum StockSagePortfolioAnalytics {
    nonisolated static let caveat = "Backward-looking risk stats over the available history — not a forecast. Small samples and shifting correlations limit reliability."

    /// Compute the suite. `holdings` = each a (dollar weight, daily closes newest-last).
    /// Weights are normalized; histories are aligned on their common (shortest) tail.
    /// Returns nil when there isn't enough overlapping history.
    nonisolated static func compute(holdings: [(weight: Double, closes: [Double])],
                                    periodsPerYear: Double = 252) -> PortfolioAnalytics? {
        guard !holdings.isEmpty else { return nil }
        let series = holdings.map { dailyReturns($0.closes) }
        let minLen = series.map(\.count).min() ?? 0
        guard minLen >= 5 else { return nil }
        let aligned = series.map { Array($0.suffix(minLen)) }

        // Normalized non-negative weights. A non-finite weight (a bad quote/FX multiply
        // upstream) is excluded rather than clamped — Swift.max(w, 0) passes .infinity through
        // unchanged, which would make wSum infinite and silently zero out every OTHER holding's
        // normalized weight while turning the poisoned holding's own weight into NaN.
        let rawW = holdings.map { $0.weight.isFinite ? Swift.max($0.weight, 0) : 0 }
        let wSum = rawW.reduce(0, +)
        guard wSum > 0, wSum.isFinite else { return nil }
        let w = rawW.map { $0 / wSum }

        // Value-weighted daily portfolio returns.
        var port = [Double](repeating: 0, count: minLen)
        for i in 0..<aligned.count {
            let wi = w[i], ri = aligned[i]
            for t in 0..<minLen { port[t] += wi * ri[t] }
        }

        let mean = port.reduce(0, +) / Double(port.count)
        // Sample variance (÷(n−1)) — standard for Sharpe ratio per academic convention.
        // Sortino's downside deviation below uses population denominator (÷n) — the RMS
        // of ALL negative returns, also standard. The two denominators are intentionally
        // different, not a drift: Sharpe uses sample-estimate variance; Sortino uses
        // the actual mean squared negative return over the full observation window.
        let variance = port.count > 1
            ? port.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(port.count - 1) : 0
        let sd = variance.squareRoot()
        let annVol = sd * periodsPerYear.squareRoot() * 100

        // Compounded annualized return.
        let growth = port.reduce(1.0) { $0 * (1 + $1) }
        let annReturn = (growth > 0 ? pow(growth, periodsPerYear / Double(port.count)) - 1 : -1) * 100

        // Zero (or non-finite) realized vol → the ratio is UNDEFINED. Report nil so the UI
        // shows "n/a", not a sentinel that reads as a real (absurd) ratio of 100 — NaN != 0 is
        // TRUE under IEEE-754, so a NaN annVol must be checked explicitly, not just "!= 0".
        let sharpe: Double? = (annVol.isFinite && annVol != 0) ? annReturn / annVol : nil

        // Sortino — target-downside deviation (MAR = 0): the RMS of min(return, 0)
        // over ALL N observations (the standard definition), NOT only the down days
        // — dividing by the down-day count overstates it and biases Sortino low.
        let downSq = port.reduce(0) { $0 + Swift.min($1, 0) * Swift.min($1, 0) }
        let downVar = port.isEmpty ? 0 : downSq / Double(port.count)
        let downDev = downVar.squareRoot() * periodsPerYear.squareRoot() * 100
        let sortino: Double? = (downDev.isFinite && downDev != 0) ? annReturn / downDev : nil

        let maxDD = maxDrawdown(port) * 100
        // maxDD == 0 (no peak-to-trough loss at all — the BEST case) makes calmar a genuine
        // divide-by-zero, not "0" — mirrors sharpe/sortino's own nil-for-undefined convention
        // instead of displaying the single worst-looking calmar value for the best outcome.
        let calmar: Double? = maxDD != 0 ? annReturn / maxDD : nil

        // Historical 1-day 95% VaR — the 5th-percentile daily return, as a positive loss.
        let var95 = Swift.max(0, -percentile(port, 0.05) * 100)
        // Conditional VaR (expected shortfall): average of ALL returns strictly below
        // the VaR threshold — "if you lose, HOW BAD?" Uses the same 5% tail.
        let cVar95: Double = {
            let cutoff = percentile(port, 0.05)
            let tail = port.filter { $0 < cutoff }
            guard !tail.isEmpty else { return var95 }   // zero tail observations → fall back to VaR
            return Swift.max(0, -tail.reduce(0, +) / Double(tail.count) * 100)
        }()

        let avgCorr = averageCorrelation(aligned)
        let base = (1 - avgCorr) / 2                                   // 0…1 (corr 1→0, −1→1)
        let countFactor = Swift.min(Double(holdings.count), 8) / 8     // saturates at 8: typical retail risk-parity cap (Elton-Gruber 1977)
        // 70% correlation-weight + 30% count-weight: correlation dominates actual risk reduction;
        // count adds a simple concentration penalty. Weights are heuristic, not optimised.
        let divScore = Swift.max(0, Swift.min(100, (0.7 * base + 0.3 * countFactor) * 100))

        return PortfolioAnalytics(
            annualizedReturn: annReturn, annualizedVolatility: annVol,
            sharpe: sharpe, sortino: sortino, maxDrawdown: maxDD, calmar: calmar,
            valueAtRisk95: var95, cVaR95: cVar95, avgCorrelation: avgCorr,
            diversificationScore: divScore, holdingsAnalyzed: holdings.count,
            observations: minLen, caveat: caveat)
    }

    // MARK: - Pure helpers

    nonisolated static func dailyReturns(_ closes: [Double]) -> [Double] {
        guard closes.count >= 2 else { return [] }
        var out: [Double] = []
        out.reserveCapacity(closes.count - 1)
        for i in 1..<closes.count where closes[i - 1] > 0 {
            out.append((closes[i] - closes[i - 1]) / closes[i - 1])
        }
        return out
    }

    /// Max peak-to-trough drawdown of the equity curve built from a return series. 0…1.
    nonisolated static func maxDrawdown(_ returns: [Double]) -> Double {
        var equity = 1.0, peak = 1.0, maxDD = 0.0
        for r in returns {
            equity *= (1 + r)
            peak = Swift.max(peak, equity)
            if peak > 0 { maxDD = Swift.max(maxDD, (peak - equity) / peak) }
        }
        return maxDD
    }

    /// Nearest-rank percentile (p in 0…1).
    nonisolated static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = Swift.max(0, Swift.min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }

    /// Pearson correlation of two return series (aligned on their common tail). nil when either
    /// series has ZERO VARIANCE (flat/halted/newly-listed/illiquid) — correlation with a
    /// constant series is mathematically 0/0, UNDEFINED, not a "diversifying" 0. Also nil when
    /// n<2 (insufficient overlap for any correlation computation) — the same "undefined" semantic
    /// as the zero-variance case. Callers MUST exclude a nil pair from any average/matrix use.
    /// All three call sites pre-guard their inputs to n≥2 (ClusterCheck ≥2, Precheck ≥5,
    /// laneCorrelation filter{≥2}), so this change is behavior-identical in production.
    nonisolated static func correlation(_ a: [Double], _ b: [Double]) -> Double? {
        let n = Swift.min(a.count, b.count)
        guard n >= 2 else { return nil }   // UNDEFINED for n<2, same convention as zero-variance
        let aa = Array(a.suffix(n)), bb = Array(b.suffix(n))
        let ma = aa.reduce(0, +) / Double(n), mb = bb.reduce(0, +) / Double(n)
        var cov = 0.0, va = 0.0, vb = 0.0
        for i in 0..<n {
            let da = aa[i] - ma, db = bb[i] - mb
            cov += da * db; va += da * da; vb += db * db
        }
        let denom = (va * vb).squareRoot()
        guard denom > 0 else { return nil }   // zero variance in either series → UNDEFINED, not 0
        return Swift.max(-1, Swift.min(1, cov / denom))
    }

    /// Daily returns tagged with the END date of each step: (date_t, close_t/close_{t-1}−1).
    /// The unit that lets co-movement stats align by CALENDAR DATE, not array index —
    /// essential once holdings span exchanges with different holiday calendars.
    nonisolated static func datedReturns(dates: [Date], closes: [Double]) -> [(date: Date, ret: Double)] {
        guard dates.count == closes.count, closes.count >= 2 else { return [] }
        var out: [(date: Date, ret: Double)] = []
        out.reserveCapacity(closes.count - 1)
        for t in 1..<closes.count where closes[t - 1] > 0 {
            out.append((date: dates[t], ret: closes[t] / closes[t - 1] - 1))
        }
        return out
    }

    /// Align several dated-return series to their COMMON calendar days
    /// (intersection), returning vectors in shared chronological order — so element
    /// i of every output vector is the SAME trading day. Days are bucketed by UTC
    /// day number so two exchanges' differing close timestamps still match. Empty
    /// vectors if no overlap.
    nonisolated static func alignByDate(_ series: [[(date: Date, ret: Double)]]) -> [[Double]] {
        guard !series.isEmpty, series.allSatisfy({ !$0.isEmpty }) else { return series.map { _ in [] } }
        func dayKey(_ d: Date) -> Int { Int((d.timeIntervalSince1970 / 86_400).rounded(.down)) }
        var common = Set(series[0].map { dayKey($0.date) })
        for s in series.dropFirst() { common.formIntersection(s.map { dayKey($0.date) }) }
        guard !common.isEmpty else { return series.map { _ in [] } }
        let ordered = common.sorted()
        return series.map { s in
            let m = Dictionary(s.map { (dayKey($0.date), $0.ret) }, uniquingKeysWith: { a, _ in a })
            return ordered.map { m[$0] ?? 0 }
        }
    }

    /// The value-weighted daily portfolio return series (aligned on the shortest
    /// tail). Exposed so callers can correlate it with a benchmark (e.g. beta).
    nonisolated static func portfolioReturns(holdings: [(weight: Double, closes: [Double])]) -> [Double] {
        let series = holdings.map { dailyReturns($0.closes) }
        let minLen = series.map(\.count).min() ?? 0
        guard minLen >= 1 else { return [] }
        let aligned = series.map { Array($0.suffix(minLen)) }
        let rawW = holdings.map { Swift.max($0.weight, 0) }
        let wSum = rawW.reduce(0, +)
        guard wSum > 0 else { return [] }
        let w = rawW.map { $0 / wSum }
        var port = [Double](repeating: 0, count: minLen)
        for i in 0..<aligned.count {
            let wi = w[i], ri = aligned[i]
            for t in 0..<minLen { port[t] += wi * ri[t] }
        }
        return port
    }

    /// Beta of a return series vs the market's: cov(port, mkt) ÷ var(mkt). Aligned
    /// on the shorter tail. nil if <5 overlapping points or the market is flat.
    /// (The 1/N factors in cov and var cancel, so raw sums give the same ratio.)
    nonisolated static func beta(portfolio: [Double], market: [Double]) -> Double? {
        let n = Swift.min(portfolio.count, market.count)
        guard n >= 5 else { return nil }
        let p = Array(portfolio.suffix(n)), m = Array(market.suffix(n))
        let pm = p.reduce(0, +) / Double(n), mm = m.reduce(0, +) / Double(n)
        var cov = 0.0, varM = 0.0
        for i in 0..<n {
            cov += (p[i] - pm) * (m[i] - mm)
            varM += (m[i] - mm) * (m[i] - mm)
        }
        guard varM > 0 else { return nil }
        return cov / varM
    }

    /// Symmetric pairwise correlation matrix for a set of return series (diagonal 1).
    /// `matrix[i][j]` = correlation of series i and j. Drives the heatmap UI. An undefined pair
    /// (zero-variance series) stores a 0 here for DISPLAY purposes only — `[[Double]]` can't hold
    /// nil — but `averageCorrelation` below does NOT read this matrix; it recomputes pairs itself
    /// and correctly EXCLUDES undefined ones, so this display fallback never corrupts the average.
    nonisolated static func correlationMatrix(_ series: [[Double]]) -> [[Double]] {
        let n = series.count
        var m = Array(repeating: Array(repeating: 1.0, count: n), count: n)
        guard n >= 2 else { return m }
        for i in 0..<n {
            for j in (i + 1)..<n {
                let c = correlation(series[i], series[j]) ?? 0
                m[i][j] = c
                m[j][i] = c
            }
        }
        return m
    }

    /// Audit 2026-07-12 (ideas-card F3): which cells of `correlationMatrix` are DEFINED. An undefined
    /// pair (a zero-variance / constant series — e.g. a halted or delisted-but-in-book holding) is
    /// stored as `0` in the matrix for display, which the heatmap would otherwise paint as a green
    /// "0.0 independent" cell — a fabricated diversification claim on a mathematically-undefined
    /// value. This parallel mask lets the heatmap render such cells as a neutral "—" instead, WITHOUT
    /// changing `correlationMatrix`'s return (three other consumers rely on the `0` fallback — the
    /// allocation-optimizer reads it straight into a covariance, so NaN there would poison it). The
    /// diagonal is always defined (a series' self-correlation is 1). Same shape as `correlationMatrix`.
    nonisolated static func correlationDefinedMask(_ series: [[Double]]) -> [[Bool]] {
        let n = series.count
        var mask = Array(repeating: Array(repeating: true, count: n), count: n)
        guard n >= 2 else { return mask }
        for i in 0..<n {
            for j in (i + 1)..<n {
                let defined = correlation(series[i], series[j]) != nil
                mask[i][j] = defined
                mask[j][i] = defined
            }
        }
        return mask
    }

    /// Average pairwise correlation across holdings (1 holding → 1 = fully concentrated). A pair
    /// with an undefined correlation (zero-variance series — flat/halted/illiquid) is EXCLUDED
    /// from the average, not counted as 0 — otherwise a flat holding would silently pull the
    /// average toward "diversifying" instead of being left out of it. Divides by the count of
    /// DEFINED pairs only; all-undefined (or <2 holdings) falls back to 1 (fully concentrated),
    /// mirroring the existing "no data → assume the risk, not the diversification" convention.
    nonisolated static func averageCorrelation(_ series: [[Double]]) -> Double {
        guard series.count >= 2 else { return 1 }
        var sum = 0.0, pairs = 0
        for i in 0..<series.count {
            for j in (i + 1)..<series.count {
                if let c = correlation(series[i], series[j]) {
                    sum += c
                    pairs += 1
                }
            }
        }
        return pairs > 0 ? sum / Double(pairs) : 1
    }
}
