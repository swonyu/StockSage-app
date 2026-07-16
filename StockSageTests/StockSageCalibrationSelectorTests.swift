import Testing
import Foundation
@testable import StockSage

// MARK: - iter7 Calibration Candidate-Selector Tests
//
// Tests for: Beta-3param fit, OOS candidate-selector, flag-off byte-identity regression-lock.
// Each flag-on test restores candidateSelectorEnabled in a defer{} — the flag is global.

struct StockSageCalibrationSelectorTests {
    typealias Cal = StockSageConvictionCalibration
    typealias Outcome = (conviction: Double, won: Bool)

    // MARK: - Shared helpers

    private static func makeOutcomes(count: Int, conviction: (Int) -> Double, won: (Int) -> Bool) -> [Outcome] {
        var result: [Outcome] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            result.append((conviction: conviction(i), won: won(i)))
        }
        return result
    }

    private static func verifyMonotone(_ cal: Cal, label: String) {
        for i in 1..<cal.bins.count {
            let prev = cal.bins[i-1].winProb
            let curr = cal.bins[i].winProb
            #expect(curr >= prev - 1e-9, "\(label): bins must be non-decreasing at index \(i)")
        }
    }

    private static func verifyUnitInterval(_ beta: Cal.BetaCalibration, label: String) {
        let testS: [Double] = [0.0, 0.001, 0.1, 0.5, 0.9, 0.999, 1.0]
        for s in testS {
            let p = beta.winProb(s)
            #expect(p >= 0.0 && p <= 1.0, "\(label): winProb(\(s))=\(p) not in [0,1]")
        }
    }

    // MARK: - 1. Beta-3param fits a logit-shaped map and is monotone

    @Test func betaFitsLogitShapedMapAndIsMonotone() {
        // Verify Beta-3param fit:
        // (a) learns a non-decreasing map on clearly separable data,
        // (b) a ≥ 0 and b ≥ 0 (monotonicity invariant),
        // (c) high conviction → higher win-prob than low conviction.
        //
        // Data: 1200 balanced outcomes — 600 high-conviction winners (s≈0.7-0.95), 600 low losses (s≈0.05-0.3).
        // This is a well-conditioned dataset for Beta fitting (roughly 50/50 positive rate).
        var outcomes: [Outcome] = []
        outcomes.reserveCapacity(1200)
        // 600 high-conviction wins (s ∈ [0.7, 0.95]).
        for i in 0..<600 {
            let s = 0.70 + 0.25 * (Double(i) + 0.5) / 600.0
            outcomes.append((conviction: s, won: true))
        }
        // 600 low-conviction losses (s ∈ [0.05, 0.30]).
        for i in 0..<600 {
            let s = 0.05 + 0.25 * (Double(i) + 0.5) / 600.0
            outcomes.append((conviction: s, won: false))
        }

        guard let beta = Cal.fitBeta(outcomes) else {
            Issue.record("fitBeta returned nil on 1200-trade balanced dataset")
            return
        }

        #expect(beta.a >= 0.0, "a must be non-negative for monotonicity")
        #expect(beta.b >= 0.0, "b must be non-negative for monotonicity")

        // Non-decreasing across sweep.
        var prev = -1.0
        for j in 1...18 {
            let s = Double(j) * 0.05
            let p = beta.winProb(s)
            #expect(p >= prev - 1e-9, "Beta map must be non-decreasing at s=\(s)")
            prev = p
        }

        // High conviction → higher win-prob than low (the signal is clear in this dataset).
        #expect(beta.winProb(0.9) > beta.winProb(0.1),
                "Beta fit must detect that high-s wins and low-s loses")
        // The map should meaningfully separate: high-s → win-prob well above 0.5.
        #expect(beta.winProb(0.9) > 0.6, "High-conviction win-prob should be well above 0.5")
        #expect(beta.winProb(0.1) < 0.4, "Low-conviction win-prob should be well below 0.5")
        // Values in (0,1).
        #expect(beta.winProb(0.1) > 0.0 && beta.winProb(0.9) < 1.0)
    }

    // MARK: - 2. Beta monotone on inverted sample (drop-and-refit enforces a≥0, b≥0)

    @Test func betaMonotoneOnInvertedSample() {
        // Inverted: high conviction → lose, low conviction → win.
        var outcomes: [Outcome] = []
        for i in 0..<50 { outcomes.append((conviction: 0.1 + Double(i)*0.001, won: true)) }
        for i in 0..<50 { outcomes.append((conviction: 0.8 + Double(i)*0.001, won: false)) }

        guard let beta = Cal.fitBeta(outcomes) else {
            Issue.record("fitBeta returned nil on inverted sample")
            return
        }
        #expect(beta.a >= 0.0, "drop-and-refit must ensure a≥0")
        #expect(beta.b >= 0.0, "drop-and-refit must ensure b≥0")

        var prev = -1.0
        for j in 1...18 {
            let s = Double(j) * 0.05
            let p = beta.winProb(s)
            #expect(p >= prev - 1e-9, "Beta map non-decreasing on inverted at s=\(s)")
            prev = p
        }
    }

    // MARK: - 3. Beta near-identity on already-calibrated data

    @Test func betaNearIdentityOnAlreadyCalibratedData() {
        // P(win) ≈ s: identity calibration. Beta should recover a sensible non-decreasing map.
        let n = 1000
        var outcomes: [Outcome] = []
        outcomes.reserveCapacity(n)
        for i in 0..<n {
            let s = (Double(i) + 0.5) / Double(n)
            let won = (Double(i % 100) + 0.5) / 100.0 < s
            outcomes.append((conviction: s, won: won))
        }

        guard let beta = Cal.fitBeta(outcomes) else {
            Issue.record("fitBeta returned nil on identity-calibrated data")
            return
        }

        #expect(beta.a >= 0.0)
        #expect(beta.b >= 0.0)

        var prev = -1.0
        for j in 1...18 {
            let s = Double(j) * 0.05
            let p = beta.winProb(s)
            #expect(p >= prev - 1e-9, "Non-decreasing on identity data at s=\(s)")
            prev = p
        }
        // Map should stay broadly reasonable.
        let p10 = beta.winProb(0.1)
        let p90 = beta.winProb(0.9)
        #expect(p10 < 0.6, "Low-conviction map should not be inflated on identity data")
        #expect(p90 > 0.4, "High-conviction map should not be deflated on identity data")
    }

    // MARK: - 4. Selector conservative contract: identity is the floor for thin splits

    @Test func selectorPicksIdentityWhenNoCandidateBeatsNoCalibration() {
        let saved = Cal.candidateSelectorEnabled; defer { Cal.candidateSelectorEnabled = saved }
        Cal.candidateSelectorEnabled = true

        // (A) Small-N guard: n=43, testN=13, gap=1, trainEnd=29 < minTrainSamples(30) → the thin
        //     identity floor. F01 (clamp, owner-approved 2026-07-04): that thin identity is now
        //     CLAMPED to the conservative prior — winProb = min(mid, 0.35+0.23·mid) — so it is
        //     genuinely "strictly more conservative" (≤ prior everywhere; the old inversion for
        //     conviction ≳ 0.45 is gone) while the low-conviction band is untouched (no promotion).
        //     Hand-derived in /tmp/derive_identity_clamp.swift (NOT read off the code), n=43 → nBins=2:
        //       bin[0] mid 0.25 → min(0.25, 0.4075) = 0.25    (low conv — clamp does NOT bind)
        //       bin[1] mid 0.75 → min(0.75, 0.5225) = 0.5225  (high conv — clamp BINDS, capped at prior)
        var tinyOutcomes: [Outcome] = []
        for i in 0..<43 {
            let s = (Double(i) + 0.5) / 43.0
            tinyOutcomes.append((conviction: s, won: i % 2 == 0))
        }
        // outer minSamples=30 passes (43 ≥ 30); selector's split gives train=29 < 30 → thin identity.
        let calTiny = try! #require(Cal.fit(tinyOutcomes, minSamples: 30),
                                    "n=43 must produce the thin identity floor, not nil")
        #expect(calTiny.method == .identity)   // still identity provenance → renders "assumed" (F02)
        #expect(calTiny.sampleSize == 43)
        let nBins = calTiny.bins.count
        #expect(nBins == 2)
        let width = 1.0 / Double(nBins)
        func priorLocal(_ c: Double) -> Double { 0.35 + max(0, min(1, c)) * 0.23 }
        for bin in calTiny.bins {
            let mid = bin.upper - width / 2.0
            let expected = min(mid, priorLocal(mid))   // the clamped contract
            #expect(abs(bin.winProb - expected) < 1e-9,
                    "thin identity must be prior-clamped: winProb \(bin.winProb) != min(mid,prior)=\(expected)")
            #expect(bin.winProb <= priorLocal(mid) + 1e-9,
                    "F01: clamped identity must be ≤ prior (the conservative-floor claim, now true)")
        }
        // Exact hand-derived band pins — the high band is where F01's inversion used to live.
        #expect(abs(calTiny.bins[0].winProb - 0.25) < 1e-9)     // low band: unchanged by the clamp
        #expect(abs(calTiny.bins[1].winProb - 0.5225) < 1e-9)   // high band: clamped 0.75 → prior 0.5225

        // (B) Structural invariants on regular-sized data (selector picks best OOS candidate
        //     and that result is always non-decreasing and in [0,1]).
        var regularOutcomes: [Outcome] = []
        for i in 0..<200 {
            regularOutcomes.append((conviction: (Double(i) + 0.5) / 200.0, won: i % 2 == 0))
        }
        let calRegular = Cal.fit(regularOutcomes, minSamples: 30)
        #expect(calRegular != nil)
        if let c = calRegular {
            #expect(c.sampleSize == 200)
            Self.verifyMonotone(c, label: "regular-200")
            for bin in c.bins {
                #expect(bin.winProb >= 0.0 && bin.winProb <= 1.0)
            }
        }

        // (C) Non-decreasing output on any input, regardless of which candidate the selector picks.
        var flippedOutcomes: [Outcome] = []
        for i in 0..<140 {
            let s = (Double(i) + 0.5) / 200.0
            flippedOutcomes.append((conviction: s, won: s >= 0.5))
        }
        for i in 140..<200 {
            let s = (Double(i) + 0.5) / 200.0
            flippedOutcomes.append((conviction: s, won: false))
        }
        let calFlipped = Cal.fit(flippedOutcomes, minSamples: 30)
        #expect(calFlipped != nil)
        if let c = calFlipped {
            Self.verifyMonotone(c, label: "flipped-200")
        }
    }

    // MARK: - 5. Selector picks non-identity when a candidate genuinely lowers OOS Brier

    @Test func selectorPicksNonIdentityWhenCandidateLowersOOSBrier() {
        let saved = Cal.candidateSelectorEnabled; defer { Cal.candidateSelectorEnabled = saved }
        Cal.candidateSelectorEnabled = true

        // Clean separable: first 200 low-conviction all lose, last 200 high-conviction all win.
        var outcomes: [Outcome] = []
        for i in 0..<200 { outcomes.append((conviction: 0.05 + Double(i)*0.001, won: false)) }
        for i in 0..<200 { outcomes.append((conviction: 0.55 + Double(i)*0.001, won: true)) }

        let cal = Cal.fit(outcomes, minSamples: 30)
        #expect(cal != nil)
        guard let cal else { return }

        // The calibrated map should reflect the separable relationship.
        #expect(cal.winProb(0.9) > cal.winProb(0.1))
        Self.verifyMonotone(cal, label: "separable-400")
        #expect(cal.winProb(0.9) > 0.5, "High conviction → high win-prob on separable data")
        #expect(cal.winProb(0.1) < 0.5, "Low conviction → low win-prob on separable data")
    }

    // MARK: - 6. Selector is leak-free

    @Test func selectorIsLeakFree() {
        let saved = Cal.candidateSelectorEnabled; defer { Cal.candidateSelectorEnabled = saved }
        Cal.candidateSelectorEnabled = true

        // n=100. trainEnd = 100 - 30 - 1 = 69. Train = [0,69), test = [70, 100).
        // Train: clear signal — high-s wins, low-s loses.
        // Test: all low-s but ALL WIN (opposite of train).
        // If test leaked into training, Beta would learn "low-s wins" and fit differently.
        var outcomes: [Outcome] = []
        for i in 0..<70 {
            let s = (Double(i) + 1.0) / 71.0
            outcomes.append((conviction: s, won: s >= 0.5))
        }
        for i in 0..<30 {
            let s = (Double(i) + 1.0) / 31.0
            outcomes.append((conviction: s, won: true))  // all win, contradicts train signal
        }

        // Train-only Beta: fit on rows [0,69).
        let trainOnly = Array(outcomes[0..<69])
        guard let betaTrain = Cal.fitBeta(trainOnly) else { return }

        Cal.candidateSelectorEnabled = true
        let cal = Cal.fit(outcomes, minSamples: 30)
        #expect(cal != nil)
        guard let cal else { return }

        // Leak-free check: train-only Beta at low conviction should be < 0.5
        // (since train says high-s wins, so Beta learns a map that gives LOW win-prob to LOW s).
        // If test leaked in, the "all-win" test rows would drag low-s win-prob up toward 1.0.
        let betaAtLow = betaTrain.winProb(0.15)
        #expect(betaAtLow < 0.5,
                "Train-only Beta at low conviction should be < 0.5 on separable train data")

        // Final calibration must be monotone and in [0,1].
        Self.verifyMonotone(cal, label: "leak-free-100")
    }

    // MARK: - 7. Flag-off is byte-identical to current behavior (regression-lock)

    @Test func flagOffIsByteIdenticalToCurrent() {
        // [iter7] The selector is now ACTIVE by default (owner-activated 2026-06-27). This test still
        // locks the flag-OFF path as byte-identical to the pre-iter7 Platt/isotonic seam, so it pins the
        // flag OFF explicitly and restores the prior value in a defer (don't leak global state).
        let saved = Cal.candidateSelectorEnabled; defer { Cal.candidateSelectorEnabled = saved }
        #expect(Cal.candidateSelectorEnabled == true, "Flag is now activated by default (iter7)")
        Cal.candidateSelectorEnabled = false

        // Fixture 1: 40-trade 80/20 split (same as StockSageConvictionCalibrationTests).
        var outcomes1: [Outcome] = []
        for i in 0..<20 { outcomes1.append((conviction: 0.1, won: i < 4)) }
        for i in 0..<20 { outcomes1.append((conviction: 0.9, won: i < 16)) }
        let a1 = Cal.fit(outcomes1, minSamples: 30)
        let b1 = Cal.fit(outcomes1, minSamples: 30)
        #expect(a1 == b1, "Two identical flag-off calls must be equal")
        if let c1 = a1 {
            #expect(c1.sampleSize == 40)
            #expect(c1.bins.count >= 2)
            #expect(c1.winProb(0.9) > c1.winProb(0.1))
        }

        // Fixture 2: Inverted (from isotonicFixesAnInvertedSample).
        var outcomes2: [Outcome] = []
        for i in 0..<15 { outcomes2.append((conviction: 0.1, won: i < 12)) }
        for i in 0..<15 { outcomes2.append((conviction: 0.9, won: i < 6)) }
        let a2 = Cal.fit(outcomes2, minSamples: 20)
        let b2 = Cal.fit(outcomes2, minSamples: 20)
        #expect(a2 == b2)
        if let c2 = a2 {
            #expect(c2.winProb(0.9) >= c2.winProb(0.1) - 1e-9)
        }

        // Fixture 3: EV-test fixture (30 high + 10 low).
        var outcomes3: [Outcome] = []
        for i in 0..<30 { outcomes3.append((conviction: 0.9, won: i < 24)) }
        for i in 0..<10 { outcomes3.append((conviction: 0.1, won: i < 1)) }
        let a3 = Cal.fit(outcomes3, minSamples: 30)
        let b3 = Cal.fit(outcomes3, minSamples: 30)
        #expect(a3 == b3)

        // Turn flag ON then OFF: output must return to identical.
        Cal.candidateSelectorEnabled = true
        let _ = Cal.fit(outcomes1, minSamples: 30)   // selector path
        Cal.candidateSelectorEnabled = false
        let afterReset = Cal.fit(outcomes1, minSamples: 30)
        #expect(afterReset == a1, "After resetting flag to false, output must equal pre-flag result")
    }

    // MARK: - 8. Selector structural invariants across data shapes (tie-break coverage)

    @Test func selectorTieBreaksToIdentityThenBeta() {
        let saved = Cal.candidateSelectorEnabled; defer { Cal.candidateSelectorEnabled = saved }
        Cal.candidateSelectorEnabled = true

        // Verify the selector produces valid (monotone, [0,1]) output across a range of data shapes.
        // Also verify determinism: same input → same output.

        var fixture0: [Outcome] = []
        for i in 0..<100 { fixture0.append((conviction: (Double(i)+0.5)/100.0, won: i%2==0)) }

        var fixture1: [Outcome] = []
        for i in 0..<100 {
            let s = (Double(i)+0.5)/100.0
            fixture1.append((conviction: s, won: s < 0.5))
        }

        var fixture2: [Outcome] = []
        for i in 0..<100 {
            let s = (Double(i)+0.5)/100.0
            fixture2.append((conviction: s, won: s >= 0.5))
        }

        let fixtures: [[Outcome]] = [fixture0, fixture1, fixture2]
        for (idx, outcomes) in fixtures.enumerated() {
            let cal = Cal.fit(outcomes, minSamples: 30)
            #expect(cal != nil, "Selector must not return nil on fixture \(idx)")
            guard let cal else { continue }
            #expect(cal.sampleSize == 100)
            Self.verifyMonotone(cal, label: "fixture-\(idx)")
            for bin in cal.bins {
                #expect(bin.winProb >= 0.0 && bin.winProb <= 1.0,
                        "Fixture \(idx): winProb must be in [0,1]")
            }
        }

        // Determinism: same input → same output.
        var data: [Outcome] = []
        for i in 0..<200 { data.append((conviction: (Double(i)+0.5)/200.0, won: i >= 100)) }
        let cal1 = Cal.fit(data, minSamples: 30)
        let cal2 = Cal.fit(data, minSamples: 30)
        #expect(cal1 == cal2, "Selector must be deterministic")
    }

    // MARK: - 9. F01/F02 provenance: identity carries .identity and renders "assumed", never "measured"

    @Test func identityProvenanceRendersAssumedNeverMeasured() {
        let saved = Cal.candidateSelectorEnabled; defer { Cal.candidateSelectorEnabled = saved }
        Cal.candidateSelectorEnabled = true

        // Small-N (n=43 → split too thin) → the selector's identity floor. Same fixture as the
        // selector-floor test above, which pins the NUMERIC behavior; this pins the PROVENANCE.
        var tiny: [Outcome] = []
        for i in 0..<43 { tiny.append((conviction: (Double(i) + 0.5) / 43.0, won: i % 2 == 0)) }
        guard let cal = Cal.fit(tiny, minSamples: 30) else {
            Issue.record("small-N fixture must produce an identity calibration, not nil")
            return
        }
        #expect(cal.method == .identity, "the thin-split floor must carry .identity provenance")
        #expect(cal.isMeasuredFromOutcomes == false)
        #expect(cal.chipTitle.contains("assumed"), "identity must render as 'win% assumed'")
        #expect(!cal.chipTitle.localizedCaseInsensitiveContains("measured"),
                "F02: the chip must NEVER say 'measured' for an identity calibration")
        #expect(cal.chipHelp.contains("ASSUMPTION"), "identity tooltip must say it is an assumption")

        // The production journal path (fit(fromJournal:)) inherits the same provenance: 40 closed
        // conviction-trades pass the outer minSamples but split too thin → identity.
        var trades: [TradeRecord] = []
        for i in 0..<40 {
            let opened = Date(timeIntervalSince1970: 1_600_000_000 + Double(i) * 86_400)
            trades.append(TradeRecord(symbol: "T\(i)", side: .long, entry: 100, stop: 95, target: 110,
                                      shares: 10, openedAt: opened,
                                      exitPrice: i % 2 == 0 ? 110 : 96,
                                      closedAt: opened.addingTimeInterval(3_600),
                                      conviction: (Double(i) + 0.5) / 40.0))
        }
        guard let jcal = Cal.fit(fromJournal: trades) else {
            Issue.record("40-closed-trade journal must produce an identity calibration, not nil")
            return
        }
        #expect(jcal.method == .identity, "journal thin-split path must carry .identity too")
        #expect(jcal.chipTitle.contains("assumed"))
        #expect(!jcal.chipTitle.localizedCaseInsensitiveContains("measured"))
    }

    // MARK: - 10. F01/F02 provenance: real fits carry their method; chip honesty invariant

    @Test func realFitsCarryTheirMethodProvenance() {
        let saved = Cal.candidateSelectorEnabled; defer { Cal.candidateSelectorEnabled = saved }
        Cal.candidateSelectorEnabled = false

        // Platt path (flag off, n=40 < isotonicMinSamples): a central MLE → "fitted", not "measured".
        var outcomes: [Outcome] = []
        for i in 0..<20 { outcomes.append((conviction: 0.1, won: i < 4)) }
        for i in 0..<20 { outcomes.append((conviction: 0.9, won: i < 16)) }
        guard let platt = Cal.fit(outcomes, minSamples: 30) else {
            Issue.record("40-trade flag-off fixture must fit via Platt, not nil")
            return
        }
        #expect(platt.method == .platt, "flag-off small-N path must carry .platt")
        #expect(platt.chipTitle == "win% fitted · n=40")
        #expect(!platt.chipTitle.contains("measured"), "Platt is a central MLE — never 'measured'")
        #expect(platt.isMeasuredFromOutcomes == false)
        #expect(platt.chipHelp.contains("NOT conservative"),
                "Platt tooltip must disclose central-MLE / no conservatism haircut")

        // Isotonic Wilson-LCB path (flag off, n ≥ isotonicMinSamples=1000): genuinely measured
        // AND conservative — the only paths allowed to say so.
        var big: [Outcome] = []
        for i in 0..<1200 { big.append((conviction: (Double(i) + 0.5) / 1200.0, won: i % 2 == 0)) }
        guard let iso = Cal.fit(big, minSamples: 30) else {
            Issue.record("1200-trade flag-off fixture must fit via isotonic, not nil")
            return
        }
        #expect(iso.method == .isotonicWilson, "flag-off large-N path must carry .isotonicWilson")
        #expect(iso.chipTitle == "win% measured · n=1200 (conservative)")
        #expect(iso.isMeasuredFromOutcomes)
    }

    @Test func chipTitleSaysMeasuredIffProvenanceIsMeasured() {
        // Direct-construction invariant across ALL four methods: the chip title claims "measured"
        // exactly when the provenance is genuinely measured-from-outcomes (F02 honesty floor).
        let bins = [Cal.Bin(upper: 0.5, winProb: 0.4, n: 10), Cal.Bin(upper: 1.0, winProb: 0.6, n: 10)]
        for m in [Cal.Method.isotonicWilson, .beta, .platt, .identity] {
            let cal = Cal(bins: bins, sampleSize: 20, method: m)
            #expect(cal.chipTitle.contains("measured") == cal.isMeasuredFromOutcomes,
                    "chipTitle must say 'measured' iff isMeasuredFromOutcomes (\(m))")
        }
        #expect(Cal(bins: bins, sampleSize: 20, method: .identity).chipTitle.contains("assumed"))
        #expect(Cal(bins: bins, sampleSize: 20, method: .platt).chipTitle.contains("fitted"))
        #expect(Cal(bins: bins, sampleSize: 20, method: .beta).chipTitle.contains("measured"))
    }

    // MARK: - 11. F12: journal calibration-fit cache — memoized on repeat reads, invalidated by ANY mutation

    @Test @MainActor func journalCalibrationCacheMemoizesAndInvalidates() {
        let saved = Cal.candidateSelectorEnabled; defer { Cal.candidateSelectorEnabled = saved }
        Cal.candidateSelectorEnabled = true

        func trade(_ i: Int, conviction: Double, win: Bool) -> TradeRecord {
            let opened = Date(timeIntervalSince1970: 1_600_000_000 + Double(i) * 86_400)
            return TradeRecord(symbol: "T\(i)", side: .long, entry: 100, stop: 95, target: 110,
                               shares: 10, openedAt: opened,
                               exitPrice: win ? 110 : 96, closedAt: opened.addingTimeInterval(3_600),
                               conviction: conviction)
        }
        var trades: [TradeRecord] = []
        for i in 0..<40 { trades.append(trade(i, conviction: (Double(i) + 0.5) / 40.0, win: i % 2 == 0)) }

        var cache = StockSageStore.JournalCalibrationCache()
        let direct = (fit: Cal.fit(fromJournal: trades), oos: Cal.validateOutOfSample(trades))

        // First read computes once; result identical to the uncached direct computation.
        let r1 = cache.value(for: trades)
        #expect(cache.fitCount == 1)
        #expect(r1.fit == direct.fit, "cached fit must be identical to the direct (pre-caching) fit")
        #expect(r1.oos == direct.oos, "cached OOS check must be identical to the direct computation")

        // Repeat reads with an unchanged journal never recompute and serve the same result.
        let r2 = cache.value(for: trades)
        let r3 = cache.value(for: trades)
        #expect(cache.fitCount == 1, "unchanged journal → no recompute")
        #expect(r2.fit == r1.fit && r3.fit == r1.fit)
        #expect(r2.oos == r1.oos && r3.oos == r1.oos)

        // ANY journal mutation (here: one more closed trade) invalidates on the very next read,
        // and the served result changes with it (sampleSize tracks the mutated journal).
        var mutated = trades
        mutated.append(trade(40, conviction: 0.5, win: true))
        let r4 = cache.value(for: mutated)
        #expect(cache.fitCount == 2, "journal mutation → recompute on next read")
        #expect(r4.fit == Cal.fit(fromJournal: mutated), "post-mutation result equals the direct fit")
        #expect(r4.fit?.sampleSize == 41)
        #expect(r1.fit?.sampleSize == 40)
        #expect(r4.fit != r1.fit, "a journal mutation must change the served fit")
    }

    // MARK: - 12. fitBeta returns nil on one-sided sample

    @Test func fitBetaReturnsNilOnOneSidedSample() {
        var allWin: [Outcome] = []
        for i in 0..<20 { allWin.append((conviction: Double(i)/20.0 + 0.025, won: true)) }
        #expect(Cal.fitBeta(allWin) == nil, "fitBeta must return nil when nNeg == 0")

        var allLose: [Outcome] = []
        for i in 0..<20 { allLose.append((conviction: Double(i)/20.0 + 0.025, won: false)) }
        #expect(Cal.fitBeta(allLose) == nil, "fitBeta must return nil when nPos == 0")

        let empty: [Outcome] = []
        #expect(Cal.fitBeta(empty) == nil, "fitBeta must return nil on empty input")
    }

    // MARK: - 13. Beta winProb is in (0,1) across full conviction range

    @Test func betaWinProbAlwaysInUnitInterval() {
        var outcomes: [Outcome] = []
        for i in 0..<40 {
            let s = (Double(i) + 0.5) / 40.0
            outcomes.append((conviction: s, won: i >= 20))
        }
        guard let beta = Cal.fitBeta(outcomes) else {
            Issue.record("fitBeta returned nil")
            return
        }
        Self.verifyUnitInterval(beta, label: "betaWinProbRange")
    }

    // MARK: - 14. D-1 (2026-07-03): clamped drop-and-refit re-anchors at the honest base rate
    //
    // Fixture hand-derived via the standalone replica /tmp/derive_d1_beta.swift (imports NOTHING
    // from the app; output pasted in the plan/dev-log). Routing proof: this exact sample runs the
    // full fit to a quasi-separated a0<0 (dropA), the x2-only refit lands b1=-1.161951 → clamp —
    // PRE-FIX the co-fitted intercept shipped a FLAT map σ(1.198654)=0.768285 vs base rate
    // 23/40=0.575000 (+0.193 overstatement; the o1-review concrete failing input). POST-FIX the
    // clamped drop branch refits the intercept alone (honest base-rate MLE σ(ln(23/17))=0.575000,
    // labeled .interceptOnly). NB: the both-slopes-negative path would have produced 0.575 even
    // pre-fix — the pre-fix RED value 0.768285 is what proves this fixture exercised dropA.
    private static let clampedDropAFixture: [Outcome] = [
        (conviction: 0.582699, won: true), (conviction: 0.385040, won: true),
        (conviction: 0.622915, won: true), (conviction: 0.389157, won: true),
        (conviction: 0.741439, won: false), (conviction: 0.919539, won: false),
        (conviction: 0.669856, won: true), (conviction: 0.532131, won: false),
        (conviction: 0.384320, won: true), (conviction: 0.181576, won: true),
        (conviction: 0.257043, won: false), (conviction: 0.316745, won: true),
        (conviction: 0.919362, won: false), (conviction: 0.856151, won: false),
        (conviction: 0.249474, won: false), (conviction: 0.425918, won: true),
        (conviction: 0.489555, won: true), (conviction: 0.098954, won: true),
        (conviction: 0.520780, won: true), (conviction: 0.321039, won: true),
        (conviction: 0.795625, won: true), (conviction: 0.771352, won: false),
        (conviction: 0.107302, won: false), (conviction: 0.292784, won: false),
        (conviction: 0.100518, won: false), (conviction: 0.585252, won: false),
        (conviction: 0.515824, won: true), (conviction: 0.050360, won: true),
        (conviction: 0.217092, won: false), (conviction: 0.144426, won: true),
        (conviction: 0.227532, won: true), (conviction: 0.628424, won: true),
        (conviction: 0.601865, won: true), (conviction: 0.613367, won: false),
        (conviction: 0.480133, won: true), (conviction: 0.442983, won: true),
        (conviction: 0.639978, won: false), (conviction: 0.285284, won: true),
        (conviction: 0.852147, won: false), (conviction: 0.286969, won: false)
    ]

    @Test func betaClampedDropARefitAnchorsAtHonestBaseRate() {
        guard let beta = Cal.fitBeta(Self.clampedDropAFixture) else {
            Issue.record("fitBeta returned nil on the D-1 dropA fixture")
            return
        }
        #expect(beta.activeFeatures == .interceptOnly,
                "clamped dropA must re-anchor as interceptOnly, got \(beta.activeFeatures)")
        for s in [0.05, 0.25, 0.5, 0.75, 0.95] {
            let p = beta.winProb(s)
            // derive_d1_beta.swift: POST-FIX honest intercept-only = 0.575000 (= base rate 23/40)
            #expect(abs(p - 0.575) < 1e-6, "honest flat base rate at s=\(s), got \(p)")
            // Honesty floor: NEVER overstate the sample base rate from a clamped fit.
            #expect(p <= 0.575 + 1e-9, "overstates base rate at s=\(s): \(p)")
        }
    }

    @Test func betaClampedDropBRefitAnchorsAtHonestBaseRate() {
        // Exact mirror (s → 1−s, won → !won) of the dropA fixture — lands dropB with
        // a1=-1.161951 clamped; PRE-FIX shipped σ(-1.198654)=0.231715 (an UNDERstated flat map —
        // same single cause, opposite sign); POST-FIX honest base rate 17/40 = 0.425000.
        let mirror: [Outcome] = Self.clampedDropAFixture.map {
            (conviction: 1.0 - $0.conviction, won: !$0.won)
        }
        guard let beta = Cal.fitBeta(mirror) else {
            Issue.record("fitBeta returned nil on the D-1 dropB mirror fixture")
            return
        }
        #expect(beta.activeFeatures == .interceptOnly,
                "clamped dropB must re-anchor as interceptOnly, got \(beta.activeFeatures)")
        for s in [0.05, 0.25, 0.5, 0.75, 0.95] {
            let p = beta.winProb(s)
            // derive_d1_beta.swift: POST-FIX honest intercept-only = 0.425000 (= base rate 17/40)
            #expect(abs(p - 0.425) < 1e-6, "honest flat base rate at s=\(s), got \(p)")
        }
    }

    // MARK: - 15. D-1b (2026-07-03): the re-anchor itself must not diverge at extreme base rates
    //
    // Residual honesty-floor breach found AFTER the D-1 fix (derived standalone via
    // scratchpad derive_d1b_witness.swift + verify_d1_enum.py exact enumeration): the
    // intercept-only refit's legacy init ln((nNeg+1)/(nPos+1)) is the LOSS-rate log-odds under
    // fitBeta's p = σ(+z) convention, and the undamped 1-D Newton started there oscillates past
    // the MLE and diverges under the 25-iter cap for 12,948/44,850 (n,nPos) pairs, 2 ≤ n ≤ 300
    // (6,474 OVERSTATE; the intercept-only refit depends ONLY on the counts). This 31-row
    // witness (base 28/31 = 0.903226) routes full-fit a0=+1029.9 / b0=−333.6 (quasi-separated)
    // → dropB → x1-refit a1=−9.07e7 ≤ 0 → intercept-only re-anchor; PRE-FIX the divergent
    // Newton shipped c=6.60e8 → flat winProb 1.000000 (+0.096774 overstatement THROUGH the D-1
    // guard). POST-FIX the intercept-only path inits at the exact MLE ln(nPos/nNeg) = ln(28/3)
    // → σ = 28/31 to full double precision (all values printed by the derive script, not the
    // app). The mid-band fixtures above sit in the convergent band and agree within ~1e-15
    // (~2 ulp) pre/post this init fix — NOT byte-identical (review-fleet re-measurement
    // 2026-07-03, verbatim fitBeta extraction at 51483d2 vs 9d26c48); identical at the
    // tests' 1e-6 tolerance.
    private static let extremeBaseRateWitness: [Outcome] = [
        (conviction: 0.776242, won: true), (conviction: 0.906762, won: true),
        (conviction: 0.308668, won: true), (conviction: 0.887846, won: true),
        (conviction: 0.776766, won: true), (conviction: 0.317633, won: true),
        (conviction: 0.573295, won: true), (conviction: 0.786991, won: true),
        (conviction: 0.181034, won: true), (conviction: 0.021712, won: true),
        (conviction: 0.012537, won: true), (conviction: 0.553954, won: true),
        (conviction: 0.871791, won: true), (conviction: 0.578940, won: true),
        (conviction: 0.970805, won: true), (conviction: 0.334388, won: true),
        (conviction: 0.552873, won: false), (conviction: 0.493216, won: true),
        (conviction: 0.012319, won: true), (conviction: 0.889939, won: false),
        (conviction: 0.933322, won: false), (conviction: 0.384393, won: true),
        (conviction: 0.201472, won: true), (conviction: 0.086514, won: true),
        (conviction: 0.007540, won: true), (conviction: 0.068483, won: true),
        (conviction: 0.091542, won: true), (conviction: 0.214991, won: true),
        (conviction: 0.216679, won: true), (conviction: 0.123498, won: true),
        (conviction: 0.792265, won: true)
    ]

    @Test func betaExtremeBaseRateReanchorAnchorsAtHonestBaseRate() {
        guard let beta = Cal.fitBeta(Self.extremeBaseRateWitness) else {
            Issue.record("fitBeta returned nil on the D-1b extreme-base-rate witness")
            return
        }
        #expect(beta.activeFeatures == .interceptOnly,
                "clamped dropB must re-anchor as interceptOnly, got \(beta.activeFeatures)")
        let base = 28.0 / 31.0  // 0.903226 — the honest sample base rate
        for s in [0.05, 0.25, 0.5, 0.75, 0.95] {
            let p = beta.winProb(s)
            #expect(abs(p - base) < 1e-6,
                    "honest flat base rate 0.903226 at s=\(s), got \(p)")
            // Honesty floor: the re-anchor must NEVER overstate the sample base rate.
            #expect(p <= base + 1e-9, "overstates base rate at s=\(s): \(p)")
        }
    }
}
