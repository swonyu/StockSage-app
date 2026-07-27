import Foundation

/// EFFECTIVE (independent) strategy trials for the Deflated Sharpe selection-bias term —
/// external-report item 8, owner-signed 2026-07-28.
///
/// The False Strategy Theorem's `N` assumes INDEPENDENT trials. A parameter sweep does not
/// produce independent strategies: 200 moving-average windows around the same idea are one
/// idea tested 200 slightly different ways, and feeding the raw combo count into
/// `expectedMaxSharpe` inflates the bar toward infinity (the report's stated failure mode).
///
/// This computes the honest count instead: correlate the per-variant return streams, take the
/// eigenvalues of that correlation matrix, and report how many principal components are needed
/// to explain `varianceTarget` (default 95%) of total variance. Perfectly collinear variants
/// collapse to 1; genuinely independent ones stay separate.
///
/// STATUS IN THIS APP: the advisor runs a FIXED rule set — there is no live sweep, so
/// `StockSageStrategyBacktest.estimatedStrategyTrials` (a hand-derived lower bound of 12)
/// remains the value in use. This type is the correct machinery for the moment a sweep exists
/// (the ablation harness), and is deliberately pure + testable so it can be trusted then.
/// It NEVER fabricates a count from a single stream — fewer than 2 streams returns nil.
enum StockSagePCATrials {

    /// Number of independent trials implied by `returnStreams` (one stream per strategy variant,
    /// all the same length, ≥2 observations). nil when the input can't support the estimate —
    /// fewer than 2 streams, ragged lengths, or a zero-variance stream (correlation undefined).
    /// Result is clamped to 1…streams.count.
    nonisolated static func effectiveTrials(returnStreams: [[Double]],
                                            varianceTarget: Double = 0.95) -> Int? {
        let n = returnStreams.count
        guard n >= 2, let len = returnStreams.first?.count, len >= 2,
              returnStreams.allSatisfy({ $0.count == len }),
              varianceTarget > 0, varianceTarget <= 1 else { return nil }
        guard let corr = correlationMatrix(returnStreams) else { return nil }
        let eigenvalues = symmetricEigenvalues(corr).sorted(by: >)
        // For a correlation matrix the eigenvalues sum to n (unit diagonal), but sum explicitly
        // so numerical drift can't skew the ratio.
        let total = eigenvalues.reduce(0, +)
        guard total > 0 else { return nil }
        var cumulative = 0.0
        for (i, e) in eigenvalues.enumerated() {
            cumulative += Swift.max(0, e)
            if cumulative / total >= varianceTarget - 1e-12 { return Swift.min(i + 1, n) }
        }
        return n
    }

    /// Pearson correlation matrix across streams. nil if any stream has zero variance.
    nonisolated static func correlationMatrix(_ streams: [[Double]]) -> [[Double]]? {
        let n = streams.count
        var means = [Double](repeating: 0, count: n)
        var sds = [Double](repeating: 0, count: n)
        for (i, s) in streams.enumerated() {
            let m = s.reduce(0, +) / Double(s.count)
            let v = s.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(s.count)
            guard v > 0 else { return nil }          // a constant stream has no correlation
            means[i] = m; sds[i] = v.squareRoot()
        }
        var out = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            out[i][i] = 1
            guard i + 1 < n else { continue }
            for j in (i + 1)..<n {
                let a = streams[i], b = streams[j]
                var cov = 0.0
                for k in 0..<a.count { cov += (a[k] - means[i]) * (b[k] - means[j]) }
                cov /= Double(a.count)
                let r = Swift.max(-1, Swift.min(1, cov / (sds[i] * sds[j])))
                out[i][j] = r; out[j][i] = r
            }
        }
        return out
    }

    /// Eigenvalues of a real symmetric matrix by the cyclic Jacobi method — chosen over anything
    /// fancier because these matrices are tiny (one row per strategy variant), Jacobi is
    /// unconditionally stable for symmetric input, and it needs no external linear-algebra
    /// dependency. Returns the diagonal once the off-diagonal mass is driven below tolerance.
    nonisolated static func symmetricEigenvalues(_ matrix: [[Double]],
                                                 maxSweeps: Int = 100,
                                                 tolerance: Double = 1e-12) -> [Double] {
        var a = matrix
        let n = a.count
        guard n > 0 else { return [] }
        guard n > 1 else { return [a[0][0]] }
        for _ in 0..<maxSweeps {
            // Off-diagonal Frobenius mass — the quantity Jacobi monotonically reduces.
            var off = 0.0
            for i in 0..<n where i + 1 < n {
                for j in (i + 1)..<n { off += a[i][j] * a[i][j] }
            }
            if off <= tolerance { break }
            for p in 0..<(n - 1) {
                for q in (p + 1)..<n where abs(a[p][q]) > tolerance {
                    // Rotation that zeroes a[p][q]: standard Golub & Van Loan form, using the
                    // numerically stable branch for t = tan(theta).
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c
                    for k in 0..<n {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                }
            }
        }
        return (0..<n).map { a[$0][$0] }
    }
}
