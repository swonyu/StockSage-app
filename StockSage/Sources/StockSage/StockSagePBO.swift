import Foundation

/// Probability of Backtest Overfitting (CSCV — Combinatorially Symmetric Cross-Validation).
/// Bailey, Borwein, López de Prado, Zhu, "The Probability of Backtest Overfitting",
/// J. Computational Finance 20(4), 2017. Extends `StockSageDeflatedSharpe`: DSR haircuts a
/// single winner's Sharpe for how many strategies were scanned; PBO instead asks a sharper
/// question directly — across every symmetric in-sample/out-of-sample split of the data,
/// how often does the IN-SAMPLE winner turn out to be an OUT-OF-SAMPLE loser? Every formula
/// here is pure and python-verified against an independent hand-derivation before coding.
enum StockSagePBO {

    /// All C(n, k) combinations of indices from 0..<n, each already ascending. No cap on n —
    /// growth is combinatorial: C(10,5)=252, C(16,8)=12,870, C(20,10)=184,756. Fine at these
    /// sizes; keep S modest (10-20) if this is ever called with a larger S.
    nonisolated static func combinations(_ n: Int, _ k: Int) -> [[Int]] {
        guard k >= 0, k <= n else { return [] }
        var result: [[Int]] = []
        var combo: [Int] = []
        func recurse(_ start: Int) {
            if combo.count == k {
                result.append(combo)
                return
            }
            var i = start
            while i < n {
                combo.append(i)
                recurse(i + 1)
                combo.removeLast()
                i += 1
            }
        }
        recurse(0)
        return result
    }

    /// Sharpe = mean / sample SD (n-1, Bessel), matching `weeklyStats` in
    /// tools/cap_ablation/main.swift. Zero variance -> 0 (never ±inf, never nil at this level).
    nonisolated static func sharpe(_ xs: [Double]) -> Double {
        let n = xs.count
        guard n > 0 else { return 0 }
        let mean = xs.reduce(0, +) / Double(n)
        guard n > 1 else { return 0 }
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)
        let sd = variance.squareRoot()
        return sd > 0 ? mean / sd : 0
    }

    nonisolated struct Result: Sendable, Equatable {
        let pbo: Double            // fraction of splits where the IS-selected winner lands OOS-below-median
        let medianLogit: Double    // median of ln(omega/(1-omega)) across splits; >0 <=> typical OOS-above-median
        let splits: Int            // C(blocks, blocks/2)
        let configs: Int           // N
        let blocks: Int            // S
        let blockLength: Int       // T / S, remainder dropped from the end
    }

    /// `returns`: N candidate-configuration rows, each T aligned observations (e.g. the
    /// cap-ablation arms' weekly net returns). `blocks`: S, the number of contiguous blocks
    /// each row is split into (even; a few observations per block). nil = no selection was
    /// possible to measure (N<2, S<2 or odd, ragged rows, or too few observations per block).
    nonisolated static func cscv(returns: [[Double]], blocks S: Int = 10) -> Result? {
        let N = returns.count
        guard N >= 2 else { return nil }
        guard S >= 2, S % 2 == 0 else { return nil }
        guard let T = returns.first?.count, returns.allSatisfy({ $0.count == T }) else { return nil }
        let blockLen = T / S
        guard blockLen >= 2 else { return nil }

        let half = S / 2
        var logits: [Double] = []
        var weights: [Double] = []
        logits.reserveCapacity(combinations(S, half).count)

        for J in combinations(S, half) {
            let Jset = Set(J)
            let Jbar = (0..<S).filter { !Jset.contains($0) }

            var isSh = [Double](repeating: 0, count: N)
            var oosSh = [Double](repeating: 0, count: N)
            for c in 0..<N {
                var isSeries: [Double] = []
                isSeries.reserveCapacity(J.count * blockLen)
                for b in J { isSeries.append(contentsOf: returns[c][(b * blockLen)..<((b + 1) * blockLen)]) }
                var oosSeries: [Double] = []
                oosSeries.reserveCapacity(Jbar.count * blockLen)
                for b in Jbar { oosSeries.append(contentsOf: returns[c][(b * blockLen)..<((b + 1) * blockLen)]) }
                isSh[c] = sharpe(isSeries)
                oosSh[c] = sharpe(oosSeries)
            }

            // IS argmax, ties -> lowest config index.
            var nstar = 0
            for c in 1..<N where isSh[c] > isSh[nstar] { nstar = c }

            // OOS relative rank of the IS winner, ascending, MID-RANK on ties (this is what
            // keeps N-identical-configs at PBO 0.5 instead of 0 or 1 — see StockSagePBOTests).
            let v = oosSh[nstar]
            let below = oosSh.filter { $0 < v }.count
            let tied = oosSh.filter { $0 == v }.count   // includes nstar itself
            let rank = Double(below) + (Double(tied) + 1) / 2
            let omega = rank / Double(N + 1)            // in (0,1) for every rank in [1,N] -> logit always finite
            logits.append(Foundation.log(omega / (1 - omega)))

            // Overfit weight decided on rank (exact .5-granular Doubles), never on the logit,
            // so fp noise inside log() can't flip an exact-median tie.
            let mid = Double(N + 1) / 2
            weights.append(rank < mid ? 1.0 : (rank == mid ? 0.5 : 0.0))
        }

        let splits = weights.count
        let pbo = weights.reduce(0, +) / Double(splits)
        let sorted = logits.sorted()
        let mid = sorted.count / 2
        let medianLogit = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2

        return Result(pbo: pbo, medianLogit: medianLogit, splits: splits, configs: N, blocks: S, blockLength: blockLen)
    }

    nonisolated static let caveat =
        "CSCV only sees the N configs you hand it — hidden or unreported trials it never saw make PBO an UNDERestimate. Contiguous-block recombination assumes rough stationarity across blocks; a regime shift mid-sample leaks information from IS into OOS. PBO measures whether the SELECTED winner's rank is real, not whether any config has true edge — N uniformly bad configs can still score PBO near 0. There is no canonical pass/fail bar the way DSR has 0.95, so this Result has no `passes` field; complements DSR and net-of-cost, replaces neither."
}
