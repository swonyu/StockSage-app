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
    let sharpe: Double?               // Annualized mean daily return / sample SD; zero benchmark.
    let sortino: Double?              // return ÷ downside deviation; nil = undefined (zero downside)
    let maxDrawdown: Double           // %, positive magnitude (worst peak→trough)
    let calmar: Double?               // annualizedReturn ÷ maxDrawdown; nil = undefined (zero drawdown)
    let valueAtRisk95: Double         // %, 1-day historical 95% VaR (positive = a loss)
    let cVaR95: Double                // %, mean loss in worst 5% empirical probability mass; floored at zero.
    let avgCorrelation: Double        // −1…1, average pairwise across holdings
    let diversificationScore: Double  // 0…100 (higher = better diversified)
    let holdingsAnalyzed: Int
    /// Positions in the book WHEN THE ANALYSIS RAN (review fix 2026-07-16): the footer
    /// previously compared holdingsAnalyzed against the LIVE portfolio count — after an
    /// add/remove that fabricated "N had no history" exclusions or impossible "3 of 2
    /// holdings" copy. attempted − analyzed is the true recorded had-no-history count.
    let holdingsAttempted: Int
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
    nonisolated static let caveat = "Historical risk estimates, not a forecast. Sharpe assumes a 0% benchmark. Small samples and changing correlations limit reliability."

    /// Compute the suite. `holdings` = each a (same-currency value weight, daily closes newest-last).
    /// Weights are normalized; histories are aligned on their common (shortest) tail.
    /// Returns nil when there isn't enough overlapping history. `attempted` = the book's
    /// position count when the analysis ran (defaults to holdings.count so pure-math
    /// callers/tests are unchanged); the store passes the real pre-exclusion count.
    /// The store first aligns common PRICE dates and checks provider metadata.
    /// `contextCaveat` describes its established basis and any excluded holdings.
    nonisolated static func compute(holdings: [(weight: Double, closes: [Double])],
                                    attempted: Int? = nil,
                                    periodsPerYear: Double = 252,
                                    contextCaveat: String? = nil) -> PortfolioAnalytics? {
        guard !holdings.isEmpty, periodsPerYear.isFinite, periodsPerYear > 0 else { return nil }
        let series = holdings.map { dailyReturns($0.closes) }
        let minLen = series.map(\.count).min() ?? 0
        guard minLen >= 5 else { return nil }
        let aligned = series.map { Array($0.suffix(minLen)) }

        // Every supplied holding must have a known positive weight. Excluding an
        // invalid value would report a partial book while counting it as analyzed.
        guard let w = normalizedWeights(holdings.map { $0.weight }) else { return nil }

        // Value-weighted daily portfolio returns.
        guard let port = weightedReturns(aligned, weights: w) else { return nil }

        let mean = port.reduce(0, +) / Double(port.count)
        // Sample variance (÷(n−1)) — standard for Sharpe ratio per academic convention.
        // Sortino's downside deviation below uses population denominator (÷n) — the RMS
        // of ALL negative returns, also standard. The two denominators are intentionally
        // different, not a drift: Sharpe uses sample-estimate variance; Sortino uses
        // the actual mean squared negative return over the full observation window.
        let variance = port.count > 1
            ? port.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(port.count - 1) : 0
        guard mean.isFinite, variance.isFinite, variance >= 0 else { return nil }
        let sd = variance.squareRoot()
        let annVol = sd * periodsPerYear.squareRoot() * 100

        // Compounded annualized return.
        var growth = 1.0
        for value in port {
            growth *= 1 + value
            guard growth.isFinite, growth > 0 else { return nil }
        }
        let annualGrowth = pow(growth, periodsPerYear / Double(port.count))
        guard annualGrowth.isFinite, annualGrowth > 0 else { return nil }
        let annReturn = (annualGrowth - 1) * 100

        // Historical Sharpe uses the arithmetic mean differential PERIOD return,
        // not compounded annual growth. With the disclosed zero benchmark, the
        // differential series is the portfolio return series. Square-root-time
        // annualization assumes uncorrelated period returns. Zero SD stays undefined.
        let sharpe: Double? = sd > 0 ? (mean / sd) * periodsPerYear.squareRoot() : nil

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

        // Empirical loss-side definition: VaR is the inverse empirical CDF at
        // 95%, i.e. sortedLosses[ceil(0.95 * N) - 1]. Reflecting a lower-return
        // quantile is not equivalent at discrete boundaries. Display loss magnitudes
        // floored at zero so an all-gain history does not display a negative loss.
        let losses = port.map { -$0 * 100 }
        guard losses.allSatisfy(\.isFinite) else { return nil }
        let var95 = Swift.max(0, inverseEmpiricalCDF(losses, 0.95))

        // Expected shortfall averages exactly the worst 5% probability mass.
        // A boundary observation contributes proportionally; tied VaR observations
        // are not discarded. This handles finite samples and discrete distributions.
        let descendingLosses = losses.sorted(by: >)
        let tailMass = Double(descendingLosses.count) * 0.05
        var tailMean = 0.0
        for (index, loss) in descendingLosses.enumerated() {
            let includedMass = Swift.min(1.0, Swift.max(0.0, tailMass - Double(index)))
            if includedMass == 0 { break }
            let contribution = loss * (includedMass / tailMass)
            guard contribution.isFinite, loss == 0 || contribution != 0 else { return nil }
            tailMean += contribution
            guard tailMean.isFinite else { return nil }
        }
        let cVar95 = Swift.max(0, tailMean)

        let avgCorr = averageCorrelation(aligned)
        let base = (1 - avgCorr) / 2                                   // 0…1 (corr 1→0, −1→1)
        let countFactor = Swift.min(Double(holdings.count), 8) / 8     // saturates at 8: typical retail risk-parity cap (Elton-Gruber 1977)
        // 70% correlation-weight + 30% count-weight: correlation dominates actual risk reduction;
        // count adds a simple concentration penalty. Weights are heuristic, not optimised.
        let divScore = Swift.max(0, Swift.min(100, (0.7 * base + 0.3 * countFactor) * 100))

        let required = [annReturn, annVol, maxDD, var95, cVar95, avgCorr, divScore]
        let ratios = [sharpe, sortino, calmar].compactMap { $0 }
        guard required.allSatisfy(\.isFinite), ratios.allSatisfy(\.isFinite) else { return nil }

        return PortfolioAnalytics(
            annualizedReturn: annReturn, annualizedVolatility: annVol,
            sharpe: sharpe, sortino: sortino, maxDrawdown: maxDD, calmar: calmar,
            valueAtRisk95: var95, cVaR95: cVar95, avgCorrelation: avgCorr,
            diversificationScore: divScore, holdingsAnalyzed: holdings.count,
            holdingsAttempted: max(attempted ?? holdings.count, holdings.count),
            observations: minLen, caveat: (contextCaveat ?? "") + caveat)
    }

    // MARK: - Pure helpers

    nonisolated private static func normalizedWeights(_ values: [Double]) -> [Double]? {
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let total = values.reduce(0, +)
        guard total.isFinite, total > 0 else { return nil }
        let normalized = values.map { $0 / total }
        // A positive holding that underflows to zero must not disappear.
        guard normalized.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return normalized
    }

    nonisolated private static func weightedReturns(_ series: [[Double]], weights: [Double]) -> [Double]? {
        guard let count = series.first?.count, count > 0, series.count == weights.count,
              series.allSatisfy({ $0.count == count && $0.allSatisfy { $0.isFinite && $0 > -1 } }) else { return nil }
        var result = [Double](repeating: 0, count: count)
        for i in series.indices {
            for t in 0..<count {
                let contribution = weights[i] * series[i][t]
                guard contribution.isFinite, series[i][t] == 0 || contribution != 0 else { return nil }
                result[t] += contribution
                guard result[t].isFinite else { return nil }
            }
        }
        guard result.allSatisfy({ $0 > -1 }) else { return nil }
        return result
    }

    nonisolated static func dailyReturns(_ closes: [Double]) -> [Double] {
        guard closes.count >= 2, closes.allSatisfy({ $0.isFinite && $0 > 0 }) else { return [] }
        var out: [Double] = []
        out.reserveCapacity(closes.count - 1)
        for i in 1..<closes.count {
            let value = (closes[i] - closes[i - 1]) / closes[i - 1]
            guard value.isFinite, value > -1,
                  closes[i] == closes[i - 1] || value != 0 else { return [] }
            out.append(value)
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

    /// Legacy rounded-index percentile: round((N - 1) * p), p in 0…1.
    /// This is not the inverse empirical CDF. Keep its existing callers stable;
    /// portfolio loss VaR uses inverseEmpiricalCDF below.
    nonisolated static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = Swift.max(0, Swift.min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }

    /// Nearest-rank percentile / inverse empirical CDF (p in 0…1).
    /// The endpoints are the minimum and maximum. Invalid input stays unavailable.
    nonisolated static func inverseEmpiricalCDF(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty, p.isFinite, (0...1).contains(p),
              values.allSatisfy(\.isFinite) else { return .nan }
        let sorted = values.sorted()
        if p == 0 { return sorted[0] }
        if p == 1 { return sorted[sorted.count - 1] }
        let rank = (Double(sorted.count) * p).rounded(.up)
        guard let oneBased = Int(exactly: rank), oneBased > 0,
              oneBased <= sorted.count else { return .nan }
        return sorted[oneBased - 1]
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
        guard aa.allSatisfy(\.isFinite), bb.allSatisfy(\.isFinite) else { return nil }
        let ma = aa.reduce(0, +) / Double(n), mb = bb.reduce(0, +) / Double(n)
        var cov = 0.0, va = 0.0, vb = 0.0
        for i in 0..<n {
            let da = aa[i] - ma, db = bb[i] - mb
            cov += da * db; va += da * da; vb += db * db
        }
        let denom = (va * vb).squareRoot()
        guard denom.isFinite, denom > 0, cov.isFinite else { return nil }
        let result = cov / denom
        guard result.isFinite else { return nil }
        return Swift.max(-1, Swift.min(1, result))
    }

    /// Daily returns tagged with the END date of each step: (date_t, close_t/close_{t-1}−1).
    /// The unit that lets co-movement stats align by CALENDAR DATE, not array index —
    /// essential once holdings span exchanges with different holiday calendars.
    nonisolated static func datedReturns(dates: [Date], closes: [Double]) -> [(date: Date, ret: Double)] {
        guard dates.count == closes.count, closes.count >= 2,
              closes.allSatisfy({ $0.isFinite && $0 > 0 }) else { return [] }
        var out: [(date: Date, ret: Double)] = []
        out.reserveCapacity(closes.count - 1)
        for t in 1..<closes.count {
            let value = closes[t] / closes[t - 1] - 1
            guard value.isFinite, value > -1,
                  closes[t] == closes[t - 1] || value != 0 else { return [] }
            out.append((date: dates[t], ret: value))
        }
        return out
    }

    nonisolated struct AlignedPriceHistories: Sendable {
        let sessionDays: [Int]
        let closes: [[Double]]
    }

    /// Intersect PRICE dates first, then let callers compute each adjacent
    /// return. Intersecting only return end dates paired a Friday-to-Monday
    /// equity move with a Sunday-to-Monday crypto move. Duplicate local dates,
    /// unsorted/invalid prices or unknown calendar metadata remain unavailable.
    /// Prices close at their own exchange times; a shared session date does not
    /// claim simultaneous observations across exchanges.
    nonisolated static func alignPriceHistories(_ histories: [StockSagePriceHistory]) -> AlignedPriceHistories? {
        guard !histories.isEmpty else { return nil }
        var maps: [[Int: Double]] = []
        for history in histories {
            guard let basis = history.analyticsBasis,
                  history.dates.count == history.closes.count, history.closes.count >= 2,
                  history.closes.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
            var prices: [Int: Double] = [:]
            var previous: Int?
            for (date, price) in zip(history.dates, history.closes) {
                guard let day = basis.sessionDay(date), previous.map({ day > $0 }) ?? true,
                      prices.updateValue(price, forKey: day) == nil else { return nil }
                previous = day
            }
            maps.append(prices)
        }
        var common = Set(maps[0].keys)
        for values in maps.dropFirst() { common.formIntersection(values.keys) }
        let days = common.sorted()
        guard days.count >= 2 else { return nil }
        // Membership is proved by the intersection; no missing price becomes 0.
        return AlignedPriceHistories(sessionDays: days,
                                     closes: maps.map { prices in days.map { prices[$0]! } })
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
        guard let w = normalizedWeights(holdings.map { $0.weight }) else { return [] }
        return weightedReturns(aligned, weights: w) ?? []
    }

    /// Beta of a return series vs the market's: cov(port, mkt) ÷ var(mkt). Aligned
    /// on the shorter tail. nil if <5 overlapping points or the market is flat.
    /// (The 1/N factors in cov and var cancel, so raw sums give the same ratio.)
    nonisolated static func beta(portfolio: [Double], market: [Double]) -> Double? {
        let n = Swift.min(portfolio.count, market.count)
        guard n >= 5 else { return nil }
        let p = Array(portfolio.suffix(n)), m = Array(market.suffix(n))
        guard p.allSatisfy(\.isFinite), m.allSatisfy(\.isFinite) else { return nil }
        let pm = p.reduce(0, +) / Double(n), mm = m.reduce(0, +) / Double(n)
        var cov = 0.0, varM = 0.0
        for i in 0..<n {
            cov += (p[i] - pm) * (m[i] - mm)
            varM += (m[i] - mm) * (m[i] - mm)
        }
        guard varM.isFinite, varM > 0, cov.isFinite else { return nil }
        let result = cov / varM
        return result.isFinite ? result : nil
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
