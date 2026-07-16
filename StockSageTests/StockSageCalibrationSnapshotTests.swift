import Testing
import Foundation
@testable import StockSage

// MARK: - Calibration runtime activation: persistence, staleness trigger, honesty invariants
//
// Tests the `Snapshot` persistence seam (StockSageConvictionCalibration.swift), the
// `StockSageStore.shouldAutoFit` staleness rule, and `StockSageStrategyBacktest
// .offlineCalibrationFit`'s sufficiency gate — hermetic (no network, isolated
// `UserDefaults(suiteName:)` + teardown per test — StockSageJournal.swift:733 injectable-seam
// precedent; testing-discipline: never two tests mutating one defaults key in parallel). Tests
// 1-7 are literal Bin fixtures, no `fit()` calls. Tests 8/4 (F1/F4, adversarial-review additions)
// deliberately DO call the real `offlineCalibrationFit`/`autoFitCalibration` — literal-fixture-only
// coverage proved the plumbing's TYPES line up but could not catch a silent no-op (IL-23); these
// two are the positive/negative liveness pair that closes that gap. `autoFitCalibration`'s
// background-Task TRIGGERS (scan-end, launch) stay gated off under the test runner (F2,
// `StockSageStore.isRunningTests`) — the two tests here call the method directly, bypassing them.

struct StockSageCalibrationSnapshotTests {
    typealias Cal = StockSageConvictionCalibration

    /// F01 hand-derived clamped-identity fixture (StockSageConvictionCalibration.swift:674-687):
    /// winProb = min(conviction-band-identity, priorWinProb) — NOT computed by the code under
    /// test. min(0.25, 0.35+0.23·0.25)=min(0.25,0.4075)=0.25; min(0.75, 0.35+0.23·0.75)
    /// =min(0.75,0.5225)=0.5225.
    private static func identityFixture() -> Cal {
        Cal(bins: [Cal.Bin(upper: 0.5, winProb: 0.25, n: 15),
                   Cal.Bin(upper: 1.0, winProb: 0.5225, n: 15)],
            sampleSize: 30, method: .identity)
    }

    private static func freshSuite() -> (UserDefaults, String) {
        let name = UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    private static let key = "stocksage.calibration.v1"

    // MARK: 1. Persistence round-trip

    @Test func persistenceRoundTrip() {
        let (ud, name) = Self.freshSuite()
        defer { ud.removePersistentDomain(forName: name) }

        let original = Self.identityFixture()
        let snap = Cal.Snapshot(calibration: original, source: "cache-offline-1y",
                                fittedAt: Date(timeIntervalSince1970: 1_750_000_000), oosBrier: nil)
        snap.save(defaults: ud, key: Self.key)

        let loaded = Cal.Snapshot.load(defaults: ud, key: Self.key)
        #expect(loaded == snap, "binary plist must round-trip the snapshot bit-exact (Doubles included)")
    }

    // MARK: 2. Decode failure ⇒ nil ⇒ caller keeps the conservative prior (never a crash/partial read)

    @Test func decodeFailIsPrior() {
        let (ud, name) = Self.freshSuite()
        defer { ud.removePersistentDomain(forName: name) }

        // No key written at all.
        #expect(Cal.Snapshot.load(defaults: ud, key: Self.key) == nil)

        // Garbage bytes under the key.
        ud.set(Data("not a plist".utf8), forKey: Self.key)
        #expect(Cal.Snapshot.load(defaults: ud, key: Self.key) == nil)

        // A nil calibration routes winProbEstimate to the conservative linear prior — hand-derived:
        // 0.35 + 0.23·0.6 = 0.488 exactly (StockSageExpectedValue.swift:92-94; verified bit-exact
        // in IEEE754 double, not merely close).
        let p = StockSageExpectedValue.winProbEstimate(conviction: 0.6, calibration: nil)
        #expect(p == 0.488)
    }

    // MARK: 3. Staleness trigger — genuine boundary straddle of the strict >7-day rule

    @Test func staleFreshTrigger() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        #expect(StockSageStore.shouldAutoFit(snapshot: nil, now: now) == true,
                "no persisted snapshot ever ⇒ always fit")

        let justUnderSevenDays = Cal.Snapshot(calibration: Self.identityFixture(), source: "cache-offline-1y",
                                              fittedAt: now.addingTimeInterval(-(7 * 86_400 - 1)), oosBrier: nil)
        #expect(StockSageStore.shouldAutoFit(snapshot: justUnderSevenDays, now: now) == false,
                "6d23h59m59s old data is not yet stale (strict >, not >=)")

        let justOverSevenDays = Cal.Snapshot(calibration: Self.identityFixture(), source: "cache-offline-1y",
                                             fittedAt: now.addingTimeInterval(-(7 * 86_400 + 1)), oosBrier: nil)
        #expect(StockSageStore.shouldAutoFit(snapshot: justOverSevenDays, now: now) == true,
                "7d00h00m01s old data is stale")
    }

    // MARK: 4. Starved histories ⇒ offlineCalibrationFit nil ⇒ autoFit no-op (persisted bytes unchanged)

    @Test func insufficientCacheNoOp() async {
        // Sufficiency gate: runTrades' `n > warmup(200) + 5` guard (StockSageBacktester.swift:190)
        // — exactly 205 closes is ONE BAR SHORT, so every StockSageStrategyBacktest.sampleSymbols
        // entry (only "AAPL" is present here) yields zero trades ⇒ zero pooled sample ⇒ fit's
        // minSamples=30 floor (StockSageConvictionCalibration.swift:101) returns nil. Bar content
        // is irrelevant — the symbol is filtered on count alone before any bar is read.
        let n = 205
        let dates = (0..<n).map { Date(timeIntervalSince1970: 1_600_000_000 + Double($0) * 86_400) }
        let flat = [Double](repeating: 100, count: n)
        let starved = StockSagePriceHistory(symbol: "AAPL", dates: dates, opens: flat, highs: flat,
                                            lows: flat, closes: flat, volumes: [Double](repeating: 1_000, count: n))

        let fit = StockSageStrategyBacktest.offlineCalibrationFit(histories: ["AAPL": starved], benchmark: nil)
        #expect(fit == nil, "205 bars fails the >205 guard for the only sampleSymbol present — no trades, no fit")

        // F4 (assertion-theater trim, from review): the ORIGINAL version of this test asserted
        // `before == after` around an `if fit == nil { }` block that never called anything —
        // an assertion that could not fail regardless of whether `autoFitCalibration`'s no-op
        // guard actually works. Drive the REAL method instead (feasible now: F1 confirmed
        // `offlineCalibrationFit` never silently no-ops on real data, and F2 gates its OWN
        // background-Task triggers off under the test runner — calling the method directly here
        // bypasses those triggers entirely, which is what we want). `StockSageStore.shared` is a
        // singleton, so route its write through the F4 `defaults`/`key` injectable seam to an
        // isolated suite — a starved/nil-fit input never reaches `.save()` regardless, but an
        // isolated suite means a hypothetical regression can't touch real UserDefaults either.
        let (ud, name) = Self.freshSuite()
        defer { ud.removePersistentDomain(forName: name) }
        let existing = Cal.Snapshot(calibration: Self.identityFixture(), source: "cache-offline-1y",
                                    fittedAt: Date(timeIntervalSince1970: 1_700_000_000), oosBrier: nil)
        existing.save(defaults: ud, key: Self.key)
        let before = ud.data(forKey: Self.key)

        await StockSageStore.shared.autoFitCalibration(histories: ["AAPL": starved], benchmark: nil,
                                                        source: "cache-offline-1y", dataAsOf: Date(),
                                                        defaults: ud, key: Self.key)

        let after = ud.data(forKey: Self.key)
        #expect(before == after, "a nil fit must never touch the persisted snapshot — this now FAILS if the guard is ever removed/reordered")
    }

    // MARK: 8. Positive-path liveness (F1, IL-23 review finding): a real trending sample must
    // produce a real fit — this test would FAIL if the seam silently no-op'd (e.g. a wrong-cased
    // symbol key, an accidentally-empty histories dict, or a broken threading of the injectable
    // input). `offlineCalibrationFit(histories:benchmark:)` already takes histories as a plain
    // parameter (StockSageStrategyBacktest.swift) — it never reads StockSageHistoryCache or
    // StockSageQuoteService internally, so no new seam was needed; this test simply exercises the
    // one that was already there.

    @Test func offlineCalibrationFitProducesARealFitFromTrendingHistories() {
        // Same fixture SHAPE as the pinned `StockSageBacktestTests.cleanUptrendProducesWinningTargetTrades`
        // (100 + $1/day, ±$1 daily range — a clean uptrend that never hits the stop, so nearly every
        // entry rides to the 2:1 target; that independently-pinned test asserts winRate==1.0, avgR>1.9
        // on the identical shape). Bar budget, hand-derived via a scratch xcodebuild run of THIS exact
        // fixture shape through `StockSageBacktester.runDetailed` (NOT the selector under test —
        // only the walk-forward sim, to measure emergent trade cadence; same "hand-derive via an
        // independent run" discipline as the codebase's own precedent, e.g. simulateExitFillsAreGapHonest's
        // "/tmp/derive_gapfill.swift, NOT read off the code" comment):
        //   n=300 (100 post-warmup(200) bars) → 11 trades/symbol, avg hold ≈7 bars — in line with
        //   100÷7≈14 bars-of-runway ÷ hold, undershooting because the first signal needs a few bars
        //   past warmup to fire. offlineCalibrationFit's own filter needs bars>205 (mirrors runTrades'
        //   n>warmup+5); 300 clears it with room. 5 sampleSymbols entries (slopes 1.0…1.4/day, so the
        //   symbols aren't byte-identical to each other) × ~11 trades/symbol ≈ 55 pooled trades —
        //   comfortably clears fit()'s minSamples=30 floor (StockSageConvictionCalibration.swift:101)
        //   even allowing for run-to-run variance from the slope spread.
        func trendingHistory(_ symbol: String, slope: Double) -> StockSagePriceHistory {
            let n = 300
            let closes = (0..<n).map { 100.0 + Double($0) * slope }
            return StockSagePriceHistory(
                symbol: symbol,
                dates: closes.enumerated().map { Date(timeIntervalSince1970: Double($0.offset) * 86_400) },
                opens: closes, highs: closes.map { $0 + 1 }, lows: closes.map { $0 - 1 },
                closes: closes, volumes: closes.map { _ in 1_000 })
        }
        var histories: [String: StockSagePriceHistory] = [:]
        for (i, sym) in StockSageStrategyBacktest.sampleSymbols.prefix(5).enumerated() {
            histories[sym] = trendingHistory(sym, slope: 1.0 + Double(i) * 0.1)
        }

        let fit = StockSageStrategyBacktest.offlineCalibrationFit(histories: histories, benchmark: nil)

        guard let fit else {
            Issue.record("offlineCalibrationFit must not silently no-op on a real trending sample of sampleSymbols-matching histories — this is exactly the IL-23 regression")
            return
        }
        #expect(fit.sampleSize >= 30, "pooled trades across the 5 symbols must clear fit()'s minSamples=30 floor")
        // "Expected method provenance surfaces" (F1): a real trending sample must earn a genuine
        // fit, not silently fall back to the conservative identity floor — that would LOOK wired
        // (fit != nil) while actually masking the same no-op class of bug the selector's own
        // thin-sample fallback exists to catch honestly, not silently, in a REGRESSION test.
        #expect(fit.method != .identity, "a 55-trade near-all-wins sample must earn a measured/fitted map, not the assumed floor")
    }

    // MARK: 5. Identity provenance survives persistence — never launders "assumed" into "measured"

    @Test func identityLabelsThroughPersistence() {
        let (ud, name) = Self.freshSuite()
        defer { ud.removePersistentDomain(forName: name) }

        let snap = Cal.Snapshot(calibration: Self.identityFixture(), source: "cache-offline-1y",
                                fittedAt: Date(timeIntervalSince1970: 1_750_000_000), oosBrier: nil)
        snap.save(defaults: ud, key: Self.key)
        guard let loaded = Cal.Snapshot.load(defaults: ud, key: Self.key) else {
            Issue.record("round-trip must succeed for a just-saved snapshot")
            return
        }
        let cal = loaded.calibration
        #expect(cal.chipTitle == "win% assumed (identity)", "same pin as StockSageCalibrationSelectorTests")
        #expect(!cal.chipTitle.localizedCaseInsensitiveContains("measured"),
                "F01/F02: persistence must never launder 'assumed' into 'measured'")
    }

    // MARK: 6. Reloaded identity fixture ranks byte-identically to the in-memory original

    @Test func identityByteIdenticalRanking() {
        let (ud, name) = Self.freshSuite()
        defer { ud.removePersistentDomain(forName: name) }

        let original = Self.identityFixture()
        let snap = Cal.Snapshot(calibration: original, source: "cache-offline-1y",
                                fittedAt: Date(timeIntervalSince1970: 1_750_000_000), oosBrier: nil)
        snap.save(defaults: ud, key: Self.key)
        guard let reloaded = Cal.Snapshot.load(defaults: ud, key: Self.key) else {
            Issue.record("round-trip must succeed for a just-saved snapshot")
            return
        }
        let cal = reloaded.calibration

        // 0.5 is the exact internal bin edge — half-open lookup lands in the UPPER band
        // (StockSageConvictionCalibration.swift:59-64: idx = min(bins.count-1, Int(c*bins.count))).
        for c in [0.0, 0.25, 0.5, 0.75, 1.0] {
            #expect(cal.winProb(c) == original.winProb(c), "winProb(\(c)) must be bit-identical after reload")
        }

        let evOriginal = StockSageExpectedValue.ev(conviction: 0.75, entry: 100, stop: 95, target: 110, calibration: original)
        let evReloaded = StockSageExpectedValue.ev(conviction: 0.75, entry: 100, stop: 95, target: 110, calibration: cal)
        #expect(evOriginal == evReloaded, "persistence must not perturb EV — identical ExpectedValue both ways")
        // Hand-derived sanity: p=0.5225, rewardR=2, evR = p·rewardR − (1−p) = 1.045 − 0.4775 = 0.5675
        // (epsilon covers the ~1e-16 IEEE754 rounding between the decimal literal and the computed
        // double — NOT a loosened test; the bit-exact claim above is the `==` assertion).
        if let evR = evOriginal?.evR {
            #expect(abs(evR - 0.5675) < 1e-9)
        } else {
            Issue.record("ev(conviction:0.75, entry:100, stop:95, target:110) must not be nil for this fixture")
        }
    }

    // MARK: 7. Manual-backtest persist plumbing (no network — the 5y recipe stays covered by
    // the sentinel-gated StrategyBaselineMeasurementTests.swift)

    @Test func manualBacktestPersists() {
        let (ud, name) = Self.freshSuite()
        defer { ud.removePersistentDomain(forName: name) }

        // Literal non-identity (Platt) fixture — content is arbitrary, only its method/sampleSize/
        // source need to round-trip correctly through the same Snapshot construction
        // `refreshStrategyBacktest` performs after its fit call (StockSageStore.swift, Decision 4).
        let platt = Cal(bins: [Cal.Bin(upper: 0.5, winProb: 0.40, n: 20),
                               Cal.Bin(upper: 1.0, winProb: 0.60, n: 20)],
                        sampleSize: 40, method: .platt)
        let snap = Cal.Snapshot(calibration: platt, source: "strategy-backtest-5y",
                                fittedAt: Date(timeIntervalSince1970: 1_750_000_000), oosBrier: nil)
        snap.save(defaults: ud, key: Self.key)

        guard let loaded = Cal.Snapshot.load(defaults: ud, key: Self.key) else {
            Issue.record("round-trip must succeed for a just-saved snapshot")
            return
        }
        #expect(loaded.methodLabel == "platt")
        #expect(loaded.sampleCount == platt.sampleSize)
        #expect(loaded.source == "strategy-backtest-5y")
    }
}
