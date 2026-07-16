import Foundation

// MARK: - Conviction → win-probability calibration
//
// The advisor's `conviction` is a 0–1 signal-STRENGTH ordinal, NOT a probability of profit. The
// expected-value engine historically mapped it with a hand-picked line (winProb = 0.35 + 0.23·c),
// which has no grounding in realized outcomes — yet it is fed into Kelly, whose bet fraction is
// acutely sensitive to it (over-state the win rate and you over-bet into ruin).
//
// This learns the map from realized (conviction, won) trades — e.g. the walk-forward backtester:
//   1. Bin trades by conviction.
//   2. Each bin's win prob = a CONSERVATIVE Wilson LOWER confidence bound (so a thin or lucky bin
//      can't over-state edge → Kelly stays cautious; under-stating only under-bets, which is safe).
//   3. Enforce MONOTONICITY (higher conviction ⇒ ≥ win prob) via pool-adjacent-violators (isotonic
//      regression), weighting by sample size.
//   4. Require a minimum total sample; below it, `fit` returns nil and the caller keeps the
//      conservative linear prior.
//
// Two fitting paths (selected by sample size in `fit`):
//   • ≥ isotonicMinSamples → the Wilson-LOWER-BOUND + isotonic path above: genuinely conservative
//     (each bin's win-prob is a one-sided lower confidence bound, so a thin/lucky bin can't
//     over-state edge).
//   • < isotonicMinSamples → Platt scaling, which is a CENTRAL MLE estimate of P(win | conviction),
//     NOT a one-sided lower bound. It does NOT apply a Wilson/LCB haircut. Conservatism for this
//     small-N path is therefore NOT provided by Platt itself — it is the job of the planned
//     candidate-selector ({isotonic, Beta, identity}, OOS-picked) + identity fallback (iter7).
//
// Pure + deterministic → unit-tested. The isotonic path is honest about uncertainty via its lower
// bound; the Platt path is a best-estimate central map and must not be read as a conservative bound.
struct StockSageConvictionCalibration: Sendable, Equatable, Codable {
    /// One ascending conviction band and its calibrated win probability.
    struct Bin: Sendable, Equatable, Codable {
        let upper: Double     // upper edge of the half-open band [lower, upper) — matches fit()'s bucketing
        let winProb: Double   // calibrated P(win) for this band (monotonic non-decreasing in `upper`)
        let n: Int            // realized trades in the band (transparency)
    }
    /// HOW this calibration's winProb map was produced (F01/F02 provenance — display honesty).
    /// The UI keys its "measured / fitted / assumed" wording on THIS, never on `calibration != nil`:
    ///   • isotonicWilson — Wilson-LCB binned + isotonic (PAV): measured from realized outcomes AND
    ///     genuinely conservative (each band is a one-sided lower confidence bound).
    ///   • beta — Beta-3param (Kull 2017), selected only after beating the identity floor
    ///     out-of-sample, then refit on all data: measured from realized outcomes and OOS-validated,
    ///     but a CENTRAL fit — NOT a lower bound.
    ///   • platt — Platt sigmoid (legacy non-selector small-N path): a central MLE estimate,
    ///     NOT conservative (no sampling-uncertainty haircut).
    ///   • identity — the selector's floor: winProb(c) ≈ c. Conviction is used AS the win
    ///     probability — an ASSUMPTION measured from ZERO outcomes. Rendering this as
    ///     "measured" was the F01/F02 CRITICAL; it must always render as "assumed".
    enum Method: String, Sendable, Equatable, Codable {
        case isotonicWilson, beta, platt, identity
    }
    let bins: [Bin]           // ascending by `upper`, equal-width over [0,1]
    let sampleSize: Int       // total trades the fit was built from
    let method: Method        // provenance of the winProb map (F01/F02) — metadata only, no numeric effect

    // MARK: - Persisted snapshot (calibration runtime activation)
    //
    // Wraps a fitted calibration with its provenance (source recipe + data-as-of date) so the
    // effective calibration survives a process restart instead of living in-memory only (the
    // pre-activation gap: `backtestConvictionCalibration` was set ONLY by the manual Strategy-
    // backtest button and reset to nil on every relaunch). `oosBrier` is nil in v1 — `fit()` does
    // not expose the selector's internal OOS Brier outside `selectCalibration`, and we never
    // re-derive one separately (honesty floor: nil = unknown, never fabricated).
    struct Snapshot: Codable, Sendable, Equatable {
        let calibration: StockSageConvictionCalibration   // the selected map — bins/sampleSize/method
        let source: String        // "strategy-backtest-5y" | "scan-offline-1y" | "cache-offline-1y"
        /// AS-OF date of the TRAINING DATA (F5): equals the fit-run time when the histories were
        /// fetched immediately prior to fitting (manual "strategy-backtest-5y", scan-end
        /// "scan-offline-1y" — both fit on data they just fetched/scanned THIS run); equals
        /// `cache.savedAt` when fitted from the on-disk HistoryCache instead ("cache-offline-1y" —
        /// the data could be up to 7 days old, per `StockSageStore.shouldAutoFit`'s staleness rule).
        let fittedAt: Date
        let oosBrier: Double?     // nil in v1 — see note above
        var sampleCount: Int { calibration.sampleSize }   // computed, no duplicated storage
        var methodLabel: String { calibration.method.rawValue }

        /// Binary plist round-trips Doubles bit-exactly, so a reloaded fit reproduces the
        /// in-memory original's ranking byte-for-byte. `defaults`/`key` injectable (mirrors
        /// StockSageJournalStore's seam, StockSageJournal.swift:733) for isolated tests.
        static func load(defaults: UserDefaults = .standard, key: String = "stocksage.calibration.v1") -> Snapshot? {
            guard let data = defaults.data(forKey: key),
                  let decoded = try? PropertyListDecoder().decode(Snapshot.self, from: data) else { return nil }
            return decoded
        }

        func save(defaults: UserDefaults = .standard, key: String = "stocksage.calibration.v1") {
            guard let data = try? PropertyListEncoder().encode(self) else { return }
            defaults.set(data, forKey: key)
        }
    }

    /// Calibrated win probability for a conviction in [0,1]: the band it falls into. Uses the SAME
    /// half-open index math as `fit()`'s bucketing, so a conviction on an exact internal edge is
    /// looked up in the band it was trained into (not the one below).
    nonisolated func winProb(_ conviction: Double) -> Double {
        guard !bins.isEmpty else { return 0.5 }
        let c = Swift.max(0, Swift.min(1, conviction))
        let idx = Swift.min(bins.count - 1, Int(c * Double(bins.count)))
        return bins[idx].winProb
    }

    /// [AUDIT] Sample-count seam: isotonic regression is unreliable below ~1000–2000 realized
    /// outcomes (Niculescu-Mizil & Caruana 2005; Alasalmi 2020 ACM TKDD; sklearn: "isotonic
    /// ≥ ~1000 samples"). Below it we fit a 2-parameter Platt sigmoid (parametric, small-N-safe);
    /// at or above it we keep the existing Wilson-lower-bound + isotonic path BYTE-IDENTICAL.
    /// 1000 is the canonical lower edge of the isotonic-reliable range — the conservative choice
    /// (a retail journal is far below it, so it almost always takes the Platt branch).
    nonisolated static let isotonicMinSamples = 1000

    /// iter7 OOS candidate-selector ({identity, Beta-3param, isotonic}, OOS-Brier-picked).
    /// ACTIVE (owner-activated 2026-06-27 after OOS review). When true, fit(...) routes through the
    /// leak-free chronological-split selector: candidates are fit on TRAIN, scored on TEST by OOS
    /// Brier, and the winner refit on ALL data — with IDENTITY as the floor (selected unless a
    /// candidate beats it by >1e-9 OOS, and the only option when the sample is too thin to split
    /// honestly). HONESTY NOTE (F01/F43): identity is a floor in the OOS-Brier selection sense.
    /// RESOLVED (F01, owner-approved 2026-07-04 — clamp option): the THIN-split identity (n∈[30,43],
    /// no OOS validation) is now clamped to the 0.35+0.23·c prior in `buildIdentity(clampToPrior:)`,
    /// so it is genuinely "strictly more conservative" (winProb ≤ prior everywhere — the old
    /// inversion for conviction ≳ 0.45 is gone) while the low-conviction band is untouched (clamp
    /// only lowers → no idea is promoted). The OOS-VALIDATED identity winner (sufficient data) stays
    /// raw — it is empirically selected, not an unvalidated fallback. The `method` provenance field
    /// still renders every identity as "assumed", never "measured" (F02). The nil-calibration prior
    /// in winProbEstimate is the single source both paths route through (F46). Set false to restore
    /// the byte-identical pre-iter7 Platt/isotonic seam (regression-locked by flagOffIsByteIdenticalToCurrent).
    nonisolated(unsafe) static var candidateSelectorEnabled = true

    /// Fit from realized outcomes. Returns nil when too few samples to calibrate honestly.
    /// - binCount: MAX equal-width conviction bands over [0,1] (the effective count adapts down to
    ///   keep ~`minPerBin` samples/band on small samples — see below).
    /// - minSamples: total-trade floor below which we don't trust a calibration.
    /// - minPerBin: target samples per band; the effective bin count is capped so bands aren't starved.
    /// - z: Wilson z-score for the lower bound (1.0 ≈ a ~84% one-sided LCB — conservative, not paranoid).
    /// - prior: win-prob assigned to EMPTY bands before isotonic smoothing.
    nonisolated static func fit(_ outcomes: [(conviction: Double, won: Bool)],
                                binCount: Int = 5, minSamples: Int = 30, minPerBin: Int = 20,
                                z: Double = 1.0, prior: Double = 0.5) -> StockSageConvictionCalibration? {
        guard binCount > 0, outcomes.count >= minSamples else { return nil }
        // [iter7] OOS candidate-selector gate (default OFF — byte-identical to pre-iter7 when false).
        if candidateSelectorEnabled {
            return selectCalibration(outcomes, binCount: binCount, minPerBin: minPerBin, z: z, prior: prior)
        }
        // [AUDIT] Selection seam. <1000 → Platt (parametric, small-N-safe); ≥1000 → the existing
        // Wilson+isotonic path, reached BYTE-IDENTICALLY (same args threaded through unchanged).
        if outcomes.count < isotonicMinSamples {
            return fitPlatt(outcomes, binCount: binCount, minPerBin: minPerBin, prior: prior)
        }
        return fitIsotonic(outcomes, binCount: binCount, minPerBin: minPerBin, z: z, prior: prior)
    }

    /// The existing Wilson-lower-bound + isotonic fit, unchanged. Reached only for ≥isotonicMinSamples
    /// outcomes, so for every history that took this path before, it is byte-for-byte identical.
    private nonisolated static func fitIsotonic(_ outcomes: [(conviction: Double, won: Bool)],
                                                binCount: Int, minPerBin: Int,
                                                z: Double, prior: Double) -> StockSageConvictionCalibration? {
        // Adapt the band count to sample size: too many bands with too few samples each over-fits —
        // the documented small-sample failure mode of isotonic/binned calibration (Niculescu-Mizil &
        // Caruana 2005, which prefers Platt below ~1–2k samples). Keep ≥ ~minPerBin samples/band on
        // average; the Wilson lower bound + monotonic pooling below add further conservatism. A
        // 60-trade backtest → 3 bands, not 5; a 30-trade one → 2.
        let nBins = Swift.max(2, Swift.min(binCount, Swift.max(1, outcomes.count / Swift.max(1, minPerBin))))

        // 1. Bucket by conviction into equal-width bands.
        var wins = [Int](repeating: 0, count: nBins)
        var total = [Int](repeating: 0, count: nBins)
        for o in outcomes {
            let c = Swift.max(0, Swift.min(1, o.conviction))
            let idx = Swift.min(nBins - 1, Int(c * Double(nBins)))   // c == 1.0 → last band
            total[idx] += 1
            if o.won { wins[idx] += 1 }
        }

        // 2. Per-band conservative win prob (Wilson lower bound); empty bands take the prior.
        var values = [Double](repeating: prior, count: nBins)
        var weights = [Double](repeating: 0.5, count: nBins)   // empty bands: tiny weight, easily pooled
        for k in 0..<nBins where total[k] > 0 {
            values[k] = wilsonLowerBound(wins: wins[k], n: total[k], z: z)
            weights[k] = Double(total[k])
        }

        // 3. Isotonic (non-decreasing) regression via pool-adjacent-violators, weighted by n.
        let smoothed = poolAdjacentViolators(values, weights: weights)

        // 4. Emit ascending bands with their upper edges.
        let width = 1.0 / Double(nBins)
        let bins = (0..<nBins).map { k in
            Bin(upper: Double(k + 1) * width, winProb: smoothed[k], n: total[k])
        }
        return StockSageConvictionCalibration(bins: bins, sampleSize: outcomes.count, method: .isotonicWilson)
    }

    /// [AUDIT] Platt scaling: P(win | s) = 1 / (1 + exp(A·s + B)) fit by MLE on (conviction s,
    /// realized-win y) with Platt's target smoothing — the small-N-safe parametric alternative to
    /// isotonic. Deterministic (fixed init, bounded Newton). Produces the SAME [Bin] substrate as the
    /// isotonic path (sigmoid evaluated at each band's midpoint), so winProb(_:)/bins/sampleSize and
    /// every downstream consumer are unchanged. Monotone non-decreasing iff A ≤ 0, which we enforce.
    /// HONESTY: this is a CENTRAL MLE estimate of P(win | conviction) (with Platt target smoothing),
    /// NOT a one-sided conservative lower bound — UNLIKE the isotonic path's Wilson-LCB bins. It does
    /// not haircut for sampling uncertainty; small-N conservatism is provided by the OOS
    /// candidate-selector + identity fallback (iter7: `candidateSelectorEnabled`) when that flag is on.
    private nonisolated static func fitPlatt(_ outcomes: [(conviction: Double, won: Bool)],
                                             binCount: Int, minPerBin: Int,
                                             prior: Double) -> StockSageConvictionCalibration? {
        let n = outcomes.count
        let nPos = outcomes.lazy.filter { $0.won }.count          // [AUDIT] N+
        let nNeg = n - nPos                                        // [AUDIT] N-

        // [AUDIT] Band count: SAME adaptive rule as the isotonic path so the two paths emit an
        // identically-shaped Bin array (display parity). 40 trades → 2 bands, etc.
        let nBins = Swift.max(2, Swift.min(binCount, Swift.max(1, n / Swift.max(1, minPerBin))))
        let width = 1.0 / Double(nBins)

        // [AUDIT] Per-band realized n (transparency only — Platt fits on the raw pairs, NOT bins, so
        // tail bands keep their true sparse n; calibration does NOT flatten the distribution).
        var total = [Int](repeating: 0, count: nBins)
        for o in outcomes {
            let c = Swift.max(0, Swift.min(1, o.conviction))
            total[Swift.min(nBins - 1, Int(c * Double(nBins)))] += 1
        }

        // [AUDIT] Degenerate guards → fall back to the conservative flat prior (same shape the
        // isotonic empty-band case uses). A one-sided sample (no winner OR no loser) cannot identify
        // a slope; inventing one would be the small-N overfit Platt exists to avoid.
        guard nPos > 0, nNeg > 0 else {
            let bins = (0..<nBins).map { k in
                Bin(upper: Double(k + 1) * width, winProb: Swift.max(0, Swift.min(1, prior)), n: total[k])
            }
            return StockSageConvictionCalibration(bins: bins, sampleSize: n, method: .platt)
        }

        // [AUDIT] Platt target smoothing (Platt 1999; Lin–Lin–Weng 2007). GLOBAL counts:
        //   t+ = (N+ + 1)/(N+ + 2)   t- = 1/(N- + 2)
        let tPos = (Double(nPos) + 1.0) / (Double(nPos) + 2.0)    // [AUDIT]
        let tNeg = 1.0 / (Double(nNeg) + 2.0)                     // [AUDIT]

        // [AUDIT] Standard Platt init: A = 0, B = ln((N- + 1)/(N+ + 1)) — the all-features-zero log-odds.
        var A = 0.0
        var B = Foundation.log((Double(nNeg) + 1.0) / (Double(nPos) + 1.0))

        // [AUDIT] Newton's method on the cross-entropy of the smoothed targets. Bounded to 25 iters,
        // early-exit on ‖Δ‖ < 1e-12. dL/dz = (t − p), Hessian weight w = p(1−p), z = A·s + B.
        // (Verified: converges to full double precision by ~iter 5 on the golden set.)
        let smoothed = outcomes.map { o -> (s: Double, t: Double) in
            (s: Swift.max(0, Swift.min(1, o.conviction)), t: o.won ? tPos : tNeg)
        }
        for _ in 0..<25 {
            var g0 = 0.0, g1 = 0.0, h00 = 0.0, h01 = 0.0, h11 = 0.0
            for st in smoothed {
                let fz = A * st.s + B
                let p = 1.0 / (1.0 + Foundation.exp(fz))          // [AUDIT] sigmoid(−z)
                let dz = st.t - p
                let w = p * (1.0 - p)
                g0 += dz * st.s;  g1 += dz
                h00 += w * st.s * st.s;  h01 += w * st.s;  h11 += w
            }
            let det = h00 * h11 - h01 * h01                       // [AUDIT]
            guard abs(det) > 1e-12 else { break }                 // singular → stop at current estimate
            let dA = (h11 * g0 - h01 * g1) / det                  // [AUDIT] H⁻¹·g, row 0
            let dB = (h00 * g1 - h01 * g0) / det                  // [AUDIT] H⁻¹·g, row 1
            A -= dA;  B -= dB
            if abs(dA) + abs(dB) < 1e-12 { break }                // [AUDIT] converged
        }

        // [AUDIT] Monotonicity clamp: winProb is non-decreasing in conviction iff A ≤ 0 (since
        // p = 1/(1+e^{A·s+B}) decreases in (A·s+B)). A degenerate fit could land A > 0 (e.g. a tiny,
        // noisy inverted sample); clamp A to ≤ 0 so a higher conviction can NEVER map to a lower
        // win-prob. CRITICAL: when A is clamped, also re-anchor B to the smoothed prior log-odds
        // (= B_init = ln((N-+1)/(N++1))). Leaving B at the Newton-converged value (which was
        // co-fitted for the now-discarded positive slope) produces a flat sigmoid far above the true
        // base rate — e.g. 88.5% vs 50% on a symmetric inverted sample — which inflates Kelly EV
        // for every conviction band and violates the module's conservatism contract.
        if A > 0 {
            A = 0
            B = Foundation.log((Double(nNeg) + 1.0) / (Double(nPos) + 1.0))  // [AUDIT] reset to prior log-odds
        }

        // [AUDIT] Emit the SAME Bin substrate: evaluate the (now monotone) sigmoid at each band's
        // MIDPOINT and clamp to [0,1]. Midpoint (not edge) is the band's representative conviction,
        // matching winProb(_:)'s "value for the whole band" contract. Non-decreasing midpoints +
        // A ≤ 0 ⇒ bins are non-decreasing by construction.
        let bins = (0..<nBins).map { k -> Bin in
            let mid = (Double(k) + 0.5) * width                   // [AUDIT] band-k center
            let p = 1.0 / (1.0 + Foundation.exp(A * mid + B))     // [AUDIT]
            return Bin(upper: Double(k + 1) * width,
                       winProb: Swift.max(0, Swift.min(1, p)), n: total[k])
        }
        return StockSageConvictionCalibration(bins: bins, sampleSize: n, method: .platt)
    }

    /// Wilson score interval LOWER bound for a binomial proportion — well-behaved for small n
    /// (unlike the naive p̂ ± z·SE), and never below 0. Conservative by design.
    nonisolated static func wilsonLowerBound(wins: Int, n: Int, z: Double = 1.0) -> Double {
        guard n > 0 else { return 0 }
        let nD = Double(n), p = Double(wins) / nD, z2 = z * z
        let denom = 1 + z2 / nD
        let center = p + z2 / (2 * nD)
        let margin = z * ((p * (1 - p) + z2 / (4 * nD)) / nD).squareRoot()
        return Swift.max(0, (center - margin) / denom)
    }

    /// Pool-adjacent-violators: the L2-optimal non-decreasing fit to `y` with weights `w`.
    /// Merges any block whose value would exceed its right neighbour, replacing both with their
    /// weighted mean, until the sequence is monotone non-decreasing.
    nonisolated static func poolAdjacentViolators(_ y: [Double], weights w: [Double]) -> [Double] {
        guard y.count == w.count, !y.isEmpty else { return y }
        struct Block { var value: Double; var weight: Double; var count: Int }
        var blocks: [Block] = []
        for k in 0..<y.count {
            var b = Block(value: y[k], weight: Swift.max(w[k], 1e-9), count: 1)
            while let last = blocks.last, last.value > b.value {
                blocks.removeLast()
                let wgt = last.weight + b.weight
                b = Block(value: (last.value * last.weight + b.value * b.weight) / wgt,
                          weight: wgt, count: last.count + b.count)
            }
            blocks.append(b)
        }
        var out: [Double] = []
        out.reserveCapacity(y.count)
        for b in blocks { out.append(contentsOf: repeatElement(b.value, count: b.count)) }
        return out
    }

    // MARK: - iter7: Beta-3param calibration (Kull, Silva Filho & Flach, AISTATS 2017)

    /// Fitted Beta-3param calibration parameters. Map: p = σ(c + a·ln(s) − b·ln(1−s)).
    /// Monotone iff a ≥ 0 ∧ b ≥ 0 (enforced by fitBeta via drop-and-refit).
    struct BetaCalibration: Sendable, Equatable {
        let a: Double   // slope on ln(s): coefficient for log-odds feature from scores
        let b: Double   // slope on −ln(1−s): coefficient for complementary log-odds feature
        let c: Double   // intercept: baseline log-odds shift
        let activeFeatures: BetaFeatures  // which features survived the monotonicity drop-and-refit

        enum BetaFeatures: Sendable, Equatable {
            case full           // a, b, c all active
            case dropA          // a was negative → refit with b, c only
            case dropB          // b was negative → refit with a, c only
            case interceptOnly  // both a and b negative → flat base-rate
        }

        /// Evaluate the Beta map for a given conviction s ∈ [0,1].
        /// Clamps s to (eps, 1-eps) to avoid ±∞ features, consistent with the fitting clamp.
        nonisolated func winProb(_ s: Double) -> Double {
            let eps = 1e-6
            let sc = Swift.max(eps, Swift.min(1.0 - eps, s))
            let x1 = Foundation.log(sc)
            let x2 = -Foundation.log(1.0 - sc)
            let z: Double
            switch activeFeatures {
            case .full:          z = c + a * x1 + b * x2
            case .dropA:         z = c + b * x2
            case .dropB:         z = c + a * x1
            case .interceptOnly: z = c
            }
            return 1.0 / (1.0 + Foundation.exp(-z))
        }
    }

    /// Fit a Beta-3param (Kull 2017) calibration on raw (conviction, won) outcomes.
    /// Returns nil when the sample is one-sided (nPos==0 or nNeg==0 — slope unidentifiable).
    /// Deterministic IRLS, 25-iter cap, 3×3 Cramer inverse, drop-and-refit for monotonicity.
    /// Does NOT use Wilson shrinkage on targets (spec: no double-shrinkage).
    nonisolated static func fitBeta(_ outcomes: [(conviction: Double, won: Bool)]) -> BetaCalibration? {
        let n = outcomes.count
        guard n > 0 else { return nil }
        let nPos = outcomes.lazy.filter { $0.won }.count
        let nNeg = n - nPos
        guard nPos > 0, nNeg > 0 else { return nil }

        let eps = 1e-6

        // Build feature rows: [1, ln(s), -ln(1-s)] → params [c, a, b]
        let rows: [(x0: Double, x1: Double, x2: Double, y: Double)] = outcomes.map { o in
            let sc = Swift.max(eps, Swift.min(1.0 - eps, o.conviction))
            return (x0: 1.0,
                    x1: Foundation.log(sc),
                    x2: -Foundation.log(1.0 - sc),
                    y: o.won ? 1.0 : 0.0)
        }

        // Inner IRLS solver for a 3-feature design (with features selected by inclusion mask).
        // includeX1 = use x1 (ln s); includeX2 = use x2 (-ln(1-s)).
        // Returns (c, a, b) where a==0 if !includeX1, b==0 if !includeX2.
        func irls(includeX1: Bool, includeX2: Bool) -> (c: Double, a: Double, b: Double) {
            // Init: slopes = 1 (identity start); the intercept init depends on the path.
            // [D-1b 2026-07-03] The legacy intercept init ln((nNeg+1)/(nPos+1)) is a sign-flipped
            // copy of fitPlatt's B-init: under THIS function's p = σ(+z) convention it is the
            // smoothed LOSS-rate log-odds. An earlier comment here called that "harmless at
            // convergence … the intercept-only fit converges to ln(nPos/nNeg) regardless" —
            // FALSIFIED by exact enumeration (the intercept-only refit depends only on the counts;
            // scratchpad verify_d1_enum.py / derive_d1b_witness.swift): started on the wrong side,
            // the undamped 1-D Newton oscillates past the MLE and diverges under the 25-iter cap
            // for 12,948/44,850 (n,nPos) pairs, 2 ≤ n ≤ 300 — half of them OVERSTATING (worst:
            // base 0.0435 shipped as flat 1.0), so the D-1 clamped-slope re-anchor itself could
            // breach the honesty floor at extreme base rates. Fix: the intercept-only path inits
            // at the exact MLE ln(nPos/nNeg) (the score nPos − n·σ(c) is 0 there; Newton converges
            // immediately — enumeration-proven exact on all 44,850 pairs, worst |dev| 3e-16).
            // The full/2-param paths keep the legacy init: their converged fits are
            // init-independent and existing fixtures pin their non-converged landings. A
            // divergent full-path fit reaches this fixed re-anchor ONLY when a slope lands
            // ≤ 0 (the aNeg/bNeg drop-refit branches); both slopes diverging POSITIVE
            // together (x1 = ln s and x2 = −ln(1−s) are both increasing in s, so a
            // quasi-separated sample drives a and b to +∞ jointly) ships .full with extreme
            // step-map params and never touches the re-anchor — there the OOS-Brier
            // selector floor is the only guard (pre-existing iter7 fitBeta behavior).
            var c: Double
            if includeX1 || includeX2 {
                c = Foundation.log((Double(nNeg) + 1.0) / (Double(nPos) + 1.0))
            } else {
                c = Foundation.log(Double(nPos) / Double(nNeg))  // exact intercept-only MLE (nPos, nNeg > 0 guarded above)
            }
            var a = includeX1 ? 1.0 : 0.0
            var b = includeX2 ? 1.0 : 0.0

            for _ in 0..<25 {
                // Accumulate gradient and Hessian (3×3 but we only use the active sub-matrix).
                // We always keep params as (c, a, b) and zero out inactive ones.
                var g0 = 0.0, g1 = 0.0, g2 = 0.0
                var h00 = 0.0, h01 = 0.0, h02 = 0.0
                var h11 = 0.0, h12 = 0.0, h22 = 0.0

                for row in rows {
                    let z = c * row.x0 + a * row.x1 + b * row.x2
                    let p = 1.0 / (1.0 + Foundation.exp(-z))
                    let dz = row.y - p
                    let w = Swift.max(p * (1.0 - p), 1e-9)

                    g0 += dz * row.x0
                    if includeX1 { g1 += dz * row.x1 }
                    if includeX2 { g2 += dz * row.x2 }

                    h00 += w * row.x0 * row.x0
                    if includeX1 { h01 += w * row.x0 * row.x1; h11 += w * row.x1 * row.x1 }
                    if includeX2 { h02 += w * row.x0 * row.x2; h22 += w * row.x2 * row.x2 }
                    if includeX1 && includeX2 { h12 += w * row.x1 * row.x2 }
                }

                // Add tiny ridge for numerical stability (conditioning guard, not L2 shrinkage).
                let ridge = 1e-8
                h00 += ridge
                if includeX1 { h11 += ridge }
                if includeX2 { h22 += ridge }

                let (dc, da, db): (Double, Double, Double)
                if includeX1 && includeX2 {
                    // Full 3×3 Cramer inverse.
                    // H = [[h00,h01,h02],[h01,h11,h12],[h02,h12,h22]]
                    let det = h00*(h11*h22 - h12*h12) - h01*(h01*h22 - h12*h02) + h02*(h01*h12 - h11*h02)
                    guard abs(det) > 1e-12 else { break }
                    // Cofactors for row 0 (solving H·Δ = g via Cramer's rule = H^{-1}·g)
                    let c00 =  (h11*h22 - h12*h12)
                    let c01 = -(h01*h22 - h12*h02)
                    let c02 =  (h01*h12 - h11*h02)
                    let c10 = -(h01*h22 - h12*h02)  // = c01 (symmetric)
                    let c11 =  (h00*h22 - h02*h02)
                    let c12 = -(h00*h12 - h01*h02)
                    let c20 =  (h01*h12 - h11*h02)  // = c02
                    let c21 = -(h00*h12 - h01*h02)  // = c12
                    let c22 =  (h00*h11 - h01*h01)
                    dc = (c00*g0 + c10*g1 + c20*g2) / det
                    da = (c01*g0 + c11*g1 + c21*g2) / det
                    db = (c02*g0 + c12*g1 + c22*g2) / det
                } else if includeX1 {
                    // 2×2: params (c, a), b=0.
                    let det = h00*h11 - h01*h01
                    guard abs(det) > 1e-12 else { break }
                    dc = (h11*g0 - h01*g1) / det
                    da = (h00*g1 - h01*g0) / det
                    db = 0.0
                } else if includeX2 {
                    // 2×2: params (c, b), a=0.
                    let det = h00*h22 - h02*h02
                    guard abs(det) > 1e-12 else { break }
                    dc = (h22*g0 - h02*g2) / det
                    da = 0.0
                    db = (h00*g2 - h02*g0) / det
                } else {
                    // Intercept only.
                    guard abs(h00) > 1e-12 else { break }
                    dc = g0 / h00
                    da = 0.0
                    db = 0.0
                }
                c += dc; a += da; b += db
                if abs(dc) + abs(da) + abs(db) < 1e-10 { break }
            }
            return (c: c, a: a, b: b)
        }

        // Full fit.
        let (c0, a0, b0) = irls(includeX1: true, includeX2: true)

        // Monotonicity enforcement: a≥0 ∧ b≥0. Drop-and-refit if violated.
        let aNeg = a0 < 0
        let bNeg = b0 < 0

        if !aNeg && !bNeg {
            return BetaCalibration(a: a0, b: b0, c: c0, activeFeatures: .full)
        } else if aNeg && bNeg {
            // Both negative → intercept-only (flat base-rate map).
            let (c1, _, _) = irls(includeX1: false, includeX2: false)
            return BetaCalibration(a: 0.0, b: 0.0, c: c1, activeFeatures: .interceptOnly)
        } else if aNeg {
            // Drop x1 (ln s), refit with x2 only.
            let (c1, _, b1) = irls(includeX1: false, includeX2: true)
            // [D-1 2026-07-03] If the surviving slope ALSO fails monotonicity (b1 ≤ 0) the map is
            // flat — but c1 was co-fitted WITH that discarded negative slope and sits above the
            // sample's base-rate log-odds (score equation: mean σ(c1 + b1·x2) = base rate; with
            // b1 < 0 and x2 > 0 for all rows, σ(c1) > base rate strictly). Shipping σ(c1) would
            // overstate win-prob for EVERY conviction band (honesty floor). Mirror the Platt
            // A-clamp B-re-anchor above and the .interceptOnly sibling: refit the intercept
            // alone → the honest base-rate MLE.
            if b1 <= 0 {
                let (c2, _, _) = irls(includeX1: false, includeX2: false)
                return BetaCalibration(a: 0.0, b: 0.0, c: c2, activeFeatures: .interceptOnly)
            }
            return BetaCalibration(a: 0.0, b: b1, c: c1, activeFeatures: .dropA)
        } else {
            // Drop x2 (-ln(1-s)), refit with x1 only.
            let (c1, a1, _) = irls(includeX1: true, includeX2: false)
            // [D-1 2026-07-03] Symmetric guard. A CONVERGED clamped dropB understates (the score-
            // equation sign flips), and a non-converged quasi-separated fit can land here
            // overstating — same single cause (intercept co-fitted with a discarded slope),
            // same re-anchor.
            if a1 <= 0 {
                let (c2, _, _) = irls(includeX1: false, includeX2: false)
                return BetaCalibration(a: 0.0, b: 0.0, c: c2, activeFeatures: .interceptOnly)
            }
            return BetaCalibration(a: a1, b: 0.0, c: c1, activeFeatures: .dropB)
        }
    }

    // MARK: - iter7: OOS candidate-selector (leak-free, identity-conservative)

    /// Materialize a calibration function into the standard Bin[] substrate.
    /// `mapFn` is called at each band midpoint; bins are non-decreasing by construction when mapFn is monotone.
    private nonisolated static func materializeBins(
        mapFn: (Double) -> Double,
        nBins: Int,
        bandCounts: [Int]
    ) -> [Bin] {
        let width = 1.0 / Double(nBins)
        return (0..<nBins).map { k in
            let mid = (Double(k) + 0.5) * width
            let p = Swift.max(0.0, Swift.min(1.0, mapFn(mid)))
            return Bin(upper: Double(k + 1) * width, winProb: p, n: bandCounts[k])
        }
    }

    /// Compute OOS Brier score of a calibration on test rows.
    private nonisolated static func brierScore(
        _ cal: StockSageConvictionCalibration,
        test: [(conviction: Double, won: Bool)]
    ) -> Double {
        guard !test.isEmpty else { return Double.greatestFiniteMagnitude }
        let eps = 1e-9
        var sum = 0.0
        for row in test {
            let p = Swift.max(eps, Swift.min(1.0 - eps, cal.winProb(row.conviction)))
            let y = row.won ? 1.0 : 0.0
            sum += (p - y) * (p - y)
        }
        return sum / Double(test.count)
    }

    /// OOS candidate-selector (iter7). Called from fit(_:) only when candidateSelectorEnabled == true.
    /// Leak-free: candidates are fit on TRAIN only, scored on TEST only, then the winner is refit on ALL data.
    /// Identity is the conservative floor — selected if nothing beats it by more than 1e-9.
    private nonisolated static func selectCalibration(
        _ outcomes: [(conviction: Double, won: Bool)],
        binCount: Int, minPerBin: Int, z: Double, prior: Double
    ) -> StockSageConvictionCalibration? {
        let n = outcomes.count
        // Need enough for a meaningful split. minTrainSamples mirrors the outer minSamples guard (30).
        let testFraction = 0.3
        let embargo = 1
        let minTrainSamples = 30

        let testN = Int((Double(n) * testFraction).rounded())
        let gap = Swift.max(0, embargo)
        guard testN >= 1, n - testN - gap >= minTrainSamples else {
            // Too thin to split honestly → prior-clamped identity (F01: conservative floor, not conviction-as-P(win)).
            return buildIdentity(outcomes, binCount: binCount, minPerBin: minPerBin, clampToPrior: true)
        }
        let trainEnd = n - testN - gap
        let train = Array(outcomes[0..<trainEnd])
        let test  = Array(outcomes[(n - testN)..<n])
        guard !train.isEmpty, !test.isEmpty else {
            return buildIdentity(outcomes, binCount: binCount, minPerBin: minPerBin, clampToPrior: true)
        }

        // Adaptive nBins (same rule as isotonic/Platt paths).
        let nBinsAll = Swift.max(2, Swift.min(binCount, Swift.max(1, n / Swift.max(1, minPerBin))))

        // Band counts for the FULL dataset (used in final refit materialization).
        var bandCountsAll = [Int](repeating: 0, count: nBinsAll)
        for o in outcomes {
            let c = Swift.max(0, Swift.min(1, o.conviction))
            let idx = Swift.min(nBinsAll - 1, Int(c * Double(nBinsAll)))
            bandCountsAll[idx] += 1
        }

        // --- CANDIDATE 1: IDENTITY ---
        let identityCal = buildIdentity(outcomes, binCount: binCount, minPerBin: minPerBin)
        guard let identityCal else { return nil }
        let identityBrier = brierScore(identityCal, test: test)

        // --- CANDIDATE 2: BETA-3PARAM (fit on TRAIN only) ---
        var betaTrainCal: StockSageConvictionCalibration? = nil
        if let beta = fitBeta(train) {
            let bins = materializeBins(mapFn: { beta.winProb($0) },
                                       nBins: nBinsAll, bandCounts: bandCountsAll)
            betaTrainCal = StockSageConvictionCalibration(bins: bins, sampleSize: n, method: .beta)
        }

        // --- CANDIDATE 3: ISOTONIC (fit on TRAIN only) ---
        var isoTrainCal: StockSageConvictionCalibration? = nil
        // INVARIANT (F35 2026-07-02): train.count >= minTrainSamples is ALWAYS true here —
        // the guard at line 479 ensures n - testN - gap >= minTrainSamples, and
        // train = outcomes[0..<trainEnd] where trainEnd = n - testN - gap, so
        // train.count == n - testN - gap >= minTrainSamples by construction.
        // The assert documents this invariant; it must never fire.
        assert(train.count >= minTrainSamples,
               "Invariant violated: train.count \(train.count) < minTrainSamples \(minTrainSamples); guard at selectCalibration entry should have prevented this path")
        do {
            // Use same adaptive nBins but fit on train subset.
            let nBinsTrain = Swift.max(2, Swift.min(binCount, Swift.max(1, train.count / Swift.max(1, minPerBin))))
            var trainCounts = [Int](repeating: 0, count: nBinsTrain)
            for o in train {
                let c = Swift.max(0, Swift.min(1, o.conviction))
                let idx = Swift.min(nBinsTrain - 1, Int(c * Double(nBinsTrain)))
                trainCounts[idx] += 1
            }
            var wins = [Int](repeating: 0, count: nBinsTrain)
            var total = [Int](repeating: 0, count: nBinsTrain)
            for o in train {
                let c = Swift.max(0, Swift.min(1, o.conviction))
                let idx = Swift.min(nBinsTrain - 1, Int(c * Double(nBinsTrain)))
                total[idx] += 1
                if o.won { wins[idx] += 1 }
            }
            var values = [Double](repeating: prior, count: nBinsTrain)
            var weights = [Double](repeating: 0.5, count: nBinsTrain)
            for k in 0..<nBinsTrain where total[k] > 0 {
                values[k] = wilsonLowerBound(wins: wins[k], n: total[k], z: z)
                weights[k] = Double(total[k])
            }
            let smoothed = poolAdjacentViolators(values, weights: weights)
            // Materialize train-fit isotonic at nBinsAll breakpoints for OOS scoring.
            let isoTrainBins = (0..<nBinsAll).map { k -> Bin in
                let mid = (Double(k) + 0.5) / Double(nBinsAll)
                let isoIdx = Swift.min(nBinsTrain - 1, Int(mid * Double(nBinsTrain)))
                return Bin(upper: Double(k + 1) / Double(nBinsAll),
                           winProb: Swift.max(0, Swift.min(1, smoothed[isoIdx])), n: bandCountsAll[k])
            }
            isoTrainCal = StockSageConvictionCalibration(bins: isoTrainBins, sampleSize: n, method: .isotonicWilson)
        }

        // --- SCORE OOS and SELECT ---
        let betaBrier = betaTrainCal.map { brierScore($0, test: test) } ?? Double.greatestFiniteMagnitude
        let isoBrier  = isoTrainCal.map  { brierScore($0, test: test) } ?? Double.greatestFiniteMagnitude

        // Identity wins any tie (within 1e-9). Among non-identity, Beta beats isotonic on tie (simpler).
        let strictMargin = 1e-9
        var bestBrier = identityBrier
        var winner: String = "identity"  // "identity" | "beta" | "isotonic"

        if betaBrier < bestBrier - strictMargin {
            bestBrier = betaBrier
            winner = "beta"
        }
        if isoBrier < bestBrier - strictMargin {
            // bestBrier = isoBrier  // not read after this
            winner = "isotonic"
        }
        // (if both beta and isotonic beat identity but are within 1e-9 of each other, the earlier
        // winner — beta — stays, giving the tie-break to the simpler candidate.)

        // --- REFIT WINNER ON FULL DATA and return ---
        switch winner {
        case "beta":
            guard let beta = fitBeta(outcomes) else {
                // Fallback: identity (shouldn't happen — train succeeded, full set has same structure).
                return identityCal
            }
            let bins = materializeBins(mapFn: { beta.winProb($0) },
                                       nBins: nBinsAll, bandCounts: bandCountsAll)
            return StockSageConvictionCalibration(bins: bins, sampleSize: n, method: .beta)
        case "isotonic":
            return fitIsotonic(outcomes, binCount: binCount, minPerBin: minPerBin, z: z, prior: prior)
        default: // "identity"
            return identityCal
        }
    }

    /// Build an identity (pass-through) calibration: winProb(s) ≈ s.
    /// Materialized at band midpoints so it has the same Bin[] structure as other paths.
    private nonisolated static func buildIdentity(
        _ outcomes: [(conviction: Double, won: Bool)],
        binCount: Int, minPerBin: Int, clampToPrior: Bool = false
    ) -> StockSageConvictionCalibration? {
        let n = outcomes.count
        guard n > 0 else { return nil }
        let nBins = Swift.max(2, Swift.min(binCount, Swift.max(1, n / Swift.max(1, minPerBin))))
        var bandCounts = [Int](repeating: 0, count: nBins)
        for o in outcomes {
            let c = Swift.max(0, Swift.min(1, o.conviction))
            let idx = Swift.min(nBins - 1, Int(c * Double(nBins)))
            bandCounts[idx] += 1
        }
        // F01 (owner-approved 2026-07-04): the THIN-split identity (n∈[30,43], NO OOS validation)
        // is clamped to the conservative prior — winProb = min(conviction, prior) — so it is
        // GENUINELY "strictly more conservative" (never conviction-as-P(win) for c ≳ 0.45, the
        // exact defect F01 named). Low conviction (< ~0.4545, identity already below prior) is
        // untouched, so no idea is ever promoted — the clamp only lowers. The OOS-floor scoring
        // and the OOS-VALIDATED identity winner pass clampToPrior:false → byte-identical (the
        // large-journal identity is empirically OOS-selected, not an unvalidated fallback).
        let mapFn: (Double) -> Double = clampToPrior
            ? { Swift.min($0, StockSageExpectedValue.priorWinProb($0)) }
            : { $0 }
        let bins = materializeBins(mapFn: mapFn, nBins: nBins, bandCounts: bandCounts)
        // F01/F02: identity MUST carry .identity — the UI renders it "assumed", never "measured".
        return StockSageConvictionCalibration(bins: bins, sampleSize: n, method: .identity)
    }
}

// MARK: - Display provenance (F01/F02 — single source for the UI's measured/fitted/assumed wording)
extension StockSageConvictionCalibration {
    /// True when winProb genuinely comes from realized outcomes (isotonic Wilson-LCB or the
    /// OOS-validated Beta refit). False for identity (assumed) — Platt counts as fitted-from-
    /// outcomes but is surfaced as "fitted", not "measured", because it carries no
    /// conservatism haircut and no OOS validation.
    nonisolated var isMeasuredFromOutcomes: Bool {
        switch method {
        case .isotonicWilson, .beta: return true
        case .platt, .identity:      return false
        }
    }

    /// The compact provenance chip title (MarketsView's calibrationChip + test pins).
    /// INVARIANT (F02): NEVER contains "measured" for an identity calibration.
    nonisolated var chipTitle: String {
        switch method {
        case .isotonicWilson: return "win% measured · n=\(sampleSize) (conservative)"
        case .beta:           return "win% measured · n=\(sampleSize) (OOS-validated)"
        case .platt:          return "win% fitted · n=\(sampleSize)"
        case .identity:       return "win% assumed (identity)"
        }
    }

    /// The chip/label tooltip, honest per fit path (F02/F43).
    nonisolated var chipHelp: String {
        switch method {
        case .isotonicWilson:
            return "Win-rate measured from \(sampleSize) realized trades (your journal when it has enough, else the backtest) via Wilson lower-bound bins + isotonic smoothing — conservative and monotonic."
        case .beta:
            return "Win-rate fit from \(sampleSize) realized trades with a Beta-3param map that beat the identity floor out-of-sample. Measured and OOS-validated, but a CENTRAL estimate — not a conservative lower bound."
        case .platt:
            return "Win-rate fit from \(sampleSize) realized trades with Platt scaling — a central MLE estimate, NOT conservative (no sampling-uncertainty haircut)."
        case .identity:
            return "No fitted map beat the honesty floor out-of-sample, so conviction — capped at the conservative ~\(StockSageExpectedValue.assumedWinBandLabel) prior when the sample is too thin to validate out-of-sample — is used as the win probability (identity map) — an ASSUMPTION, not a rate measured from your \(sampleSize) outcomes. More closed trades let a real fit earn 'measured'."
        }
    }
}

// MARK: - Build straight from backtest trades
extension StockSageConvictionCalibration {
    /// Fit from walk-forward backtest trades (a win is a positive realized R). nil when too thin.
    /// `dates`, when supplied 1:1-aligned with `trades` (e.g. the caller's own per-trade entry
    /// dates), sorts trades chronologically first — required so selectCalibration's positional
    /// train/test split (test = the most-recent slice) is a genuine "OOS = future" holdout, the
    /// same guarantee `fit(fromJournal:)` already provides. `trades` is aggregated across MANY
    /// symbols by callers (e.g. StockSageStore.refreshStrategyBacktest appends symbol-by-symbol),
    /// so it is NOT already globally time-ordered on its own — without `dates`, a positional split
    /// can silently mix an early trade from a later-processed symbol into "test" while a later
    /// trade from an earlier symbol sits in "train". Omitting `dates` preserves prior behavior
    /// exactly (trusts the caller's own order), for callers (tests) that already supply
    /// chronologically-intentional fixtures.
    nonisolated static func fit(fromBacktest trades: [BacktestTrade], dates: [Date] = [],
                                binCount: Int = 5, minSamples: Int = 30,
                                z: Double = 1.0, prior: Double = 0.5) -> StockSageConvictionCalibration? {
        let ordered: [BacktestTrade]
        if dates.count == trades.count {
            ordered = zip(dates, trades).sorted { $0.0 < $1.0 }.map { $0.1 }
        } else {
            ordered = trades
        }
        return fit(ordered.map { (conviction: $0.conviction, won: $0.r > 0) },
                   binCount: binCount, minSamples: minSamples, z: z, prior: prior)
    }

    /// Fit from the owner's JOURNAL — their OWN realized executions (fills, slippage, discipline),
    /// which the sample-universe backtest can't capture. Only CLOSED trades that carry a conviction
    /// contribute (a win = realized R > 0); manual trades without a conviction are excluded. nil when
    /// too thin — the caller keeps the backtest fit / conservative prior.
    nonisolated static func fit(fromJournal trades: [TradeRecord],
                                binCount: Int = 5, minSamples: Int = 30,
                                z: Double = 1.0, prior: Double = 0.5) -> StockSageConvictionCalibration? {
        // Sort by CLOSE time before the conviction/outcome projection so the positional train/test
        // split inside selectCalibration (test = the most-recent slice) is a genuine "OOS = future"
        // holdout, not merely disjoint. The journal store can hand trades back in insertion/edit order;
        // this pins chronology so the OOS selection honors its intended semantics. Leak-free either way.
        let outcomes = trades
            .sorted { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }
            .compactMap { t -> (conviction: Double, won: Bool)? in
                guard let c = t.conviction, let r = t.realizedR else { return nil }
                return (conviction: c, won: r > 0)
            }
        return fit(outcomes, binCount: binCount, minSamples: minSamples, z: z, prior: prior)
    }

    /// Chronological train/test split of CLOSED journal trades for OUT-OF-SAMPLE calibration validation:
    /// fit the conviction→win-prob map on `train`, then score it on `test` — trades it never saw. Trades
    /// are ordered by CLOSE time; the most recent `testFraction` become the test set, and `embargo`
    /// trades straddling the boundary are DROPPED (purge) so a position whose window spans the split can't
    /// leak its outcome across. Returns empty sets when too few closed trades to split honestly.
    /// (The backtest's headline R/Sharpe/t carry no such leakage — those rules don't use the calibration;
    /// the calibration is the only FITTED component, so it's the one that needs OOS validation.)
    nonisolated static func chronologicalSplit(_ trades: [TradeRecord],
                                               testFraction: Double = 0.3,
                                               embargo: Int = 1) -> (train: [TradeRecord], test: [TradeRecord]) {
        let closed = trades.filter { $0.closedAt != nil }
            .sorted { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }
        let f = Swift.max(0, Swift.min(1, testFraction))
        let n = closed.count
        let testN = Int((Double(n) * f).rounded())
        let gap = Swift.max(0, embargo)
        guard testN >= 1, n - testN - gap >= 1 else { return (train: [], test: []) }
        let trainEnd = n - testN - gap   // [0, trainEnd) train · [trainEnd, n-testN) embargoed · [n-testN, n) test
        return (train: Array(closed[0..<trainEnd]), test: Array(closed[(n - testN)..<n]))
    }

    /// Out-of-sample quality of the conviction→win-prob map: fit on the chronological TRAIN slice, then
    /// score the held-out TEST slice it never saw. `oosBrier`/`oosLogLoss` are proper scores (lower =
    /// better); `baselineBrier` is the no-skill predictor (TRAIN base win-rate for every test trade). The
    /// map only EARNS its place if it beats that baseline OOS (`addsSkill`). nil when too thin to fit/score.
    /// Honest + small-sample-noisy by nature — a few-dozen-trade journal gives a wide, jumpy estimate.
    struct OOSCalibrationCheck: Sendable, Equatable {
        let oosBrier: Double
        let baselineBrier: Double
        let oosLogLoss: Double
        let n: Int
        /// The calibration generalizes only if it beats the no-skill base-rate predictor out-of-sample.
        nonisolated var addsSkill: Bool { oosBrier < baselineBrier }
    }

    nonisolated static func validateOutOfSample(_ trades: [TradeRecord],
                                                testFraction: Double = 0.3, embargo: Int = 1,
                                                minTrainSamples: Int = 30) -> OOSCalibrationCheck? {
        let (train, test) = chronologicalSplit(trades, testFraction: testFraction, embargo: embargo)
        guard let cal = fit(fromJournal: train, minSamples: minTrainSamples) else { return nil }
        // No-skill baseline = the TRAIN base win-rate (what you'd predict knowing nothing about conviction).
        let trainWon = train.compactMap { t -> Bool? in
            guard t.conviction != nil, let r = t.realizedR else { return nil }
            return r > 0
        }
        guard !trainWon.isEmpty else { return nil }
        let baseRate = Double(trainWon.filter { $0 }.count) / Double(trainWon.count)

        let eps = 1e-9
        var brier = 0.0, baseBrier = 0.0, logloss = 0.0, count = 0
        for t in test {
            guard let c = t.conviction, let r = t.realizedR else { continue }
            let a = r > 0 ? 1.0 : 0.0
            let p = Swift.max(eps, Swift.min(1 - eps, cal.winProb(c)))
            brier += (p - a) * (p - a)
            baseBrier += (baseRate - a) * (baseRate - a)
            logloss += -(a * Foundation.log(p) + (1 - a) * Foundation.log(1 - p))
            count += 1
        }
        guard count >= 1 else { return nil }
        let nD = Double(count)
        return OOSCalibrationCheck(oosBrier: brier / nD, baselineBrier: baseBrier / nD,
                                   oosLogLoss: logloss / nD, n: count)
    }
}
