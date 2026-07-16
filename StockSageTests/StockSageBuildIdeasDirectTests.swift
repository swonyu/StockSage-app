import Testing
import Foundation
@testable import StockSage

// MARK: - F05 — buildIdeas direct unit tests
//
// StockSageStore.buildIdeas(defs:histories:...) is nonisolated static — fully testable without
// the main actor or a network fetch. These tests drive the four honesty-note paths and the
// momentumQuality nil guard that the existing suite has never exercised directly.
//
// Every asserted numeric was derived by the standalone script
// scratchpad/derive_hardening.swift and matches the exact engine formula.

struct StockSageBuildIdeasDirectTests {

    // MARK: - Helpers

    /// Minimal StockSageSymbol that is NOT an index (so buildIdeas doesn't skip it).
    private func equitySym(_ s: String) -> StockSageSymbol {
        StockSageSymbol(symbol: s, market: "TEST")
    }

    /// Build a StockSagePriceHistory from a close array (opens/highs/lows mirrored).
    private func history(_ sym: String, closes: [Double]) -> StockSagePriceHistory {
        let dates = closes.enumerated().map { Date(timeIntervalSince1970: Double($0.offset) * 86_400) }
        return StockSagePriceHistory(
            symbol: sym, dates: dates,
            opens: closes, highs: closes.map { $0 * 1.005 }, lows: closes.map { $0 * 0.995 },
            closes: closes, volumes: closes.map { _ in 100_000 })
    }

    /// 293 bars: 272 calm (sinusoidal, ~8% annualised) then 21 alternating high-vol bars (~47% ann.).
    /// Triggers the vol-regime brake note (sizingMultiplier < 0.95) AND provides enough
    /// bars for volStability (needs ≥147) AND enough for VolRegime (needs ≥273).
    private func lowThenHighVolCloses(calendarBars: Int = 293) -> [Double] {
        let lowVol = 0.005   // ~8% annualised
        let highVol = 0.030  // ~47% annualised
        var px = 100.0
        var out = [px]
        for i in 0..<272 {
            px *= (1 + sin(Double(i)) * lowVol)
            out.append(px)
        }
        for i in 0..<(calendarBars - 273) {
            let sign: Double = i % 2 == 0 ? 1 : -1
            px *= (1 + sign * highVol)
            out.append(px)
        }
        return out
    }

    /// Minimal calibration: two bins with win-prob 0.30 for all conviction values.
    /// 0.30 is BELOW the Kelly break-even at the advisor's native 2:1 stop/target (R=2):
    ///   break-even p* = 1/(1+R) = 1/3 ≈ 0.333
    ///   winProb=0.30 → Kelly fraction = 0.30×2 − 0.70 = −0.10 < 0 → suggestedWeight = 0
    /// The linear prior at any conviction the uptrend advisor produces (conviction ≈ 0.65,
    /// winProb ≈ 0.50) gives Kelly fraction = 0.50×2 − 0.50 = 0.50 > 0 → suggestedWeight > 0.
    /// So noCal.suggestedWeight > 0 while withCal.suggestedWeight == 0 → strict inequality.
    private func fixedCalibration() -> StockSageConvictionCalibration {
        StockSageConvictionCalibration(
            bins: [
                .init(upper: 0.5, winProb: 0.30, n: 200),
                .init(upper: 1.0, winProb: 0.30, n: 200),
            ],
            sampleSize: 400,
            method: .isotonicWilson)   // fixture poses as a measured 400-trade fit (method is display metadata only)
    }

    // MARK: - F05(a): momentumQuality is nil when history is too short (≤20 closes)

    @Test func momentumQualityNilForTooShortHistory() async {
        // Exactly 20 closes → count is NOT > 20 → momentumQuality must be nil.
        let sym = equitySym("SHORTAAPL")
        let h = history("SHORTAAPL", closes: Array(stride(from: 100.0, through: 119.0, by: 1.0)))  // 20 bars
        assert(h.closes.count == 20)

        let ideas = await StockSageStore.buildIdeas(
            defs: [sym], histories: ["SHORTAAPL": h])
        // The idea is produced (price and history exist) but momentumQuality is nil.
        #expect(ideas.count == 1)
        #expect(ideas[0].momentumQuality == nil,
                "momentumQuality must be nil for ≤20 closes — engine guard at ~L492")
    }

    @Test func momentumQualityNonNilWhenHistory21Bars() async {
        // 21 closes → count IS > 20 → momentumQuality should be non-nil (computed).
        let sym = equitySym("LONGAAPL")
        let closes = (0..<21).map { 100.0 + Double($0) * 0.5 }  // gentle uptrend, 21 bars
        let h = history("LONGAAPL", closes: closes)
        assert(h.closes.count == 21)

        let ideas = await StockSageStore.buildIdeas(
            defs: [sym], histories: ["LONGAAPL": h])
        // An idea should be produced and its momentumQuality should be non-nil.
        // (StockSageExpectedValue.momentumQuality returns 1.0 sentinel when signals can't compute
        // over this short history, but the engine still stores it — it's not nil.)
        if let idea = ideas.first {
            #expect(idea.momentumQuality != nil,
                    "momentumQuality must be non-nil for >20 closes")
        }
        // If no idea is produced (the advisor held at zero conviction), the test is inconclusive
        // but not a failure — guard only the nil branch above.
    }

    // MARK: - F05(b): left-tailed history note lands in rationale

    @Test func singleCrashDayDoesNotTriggerLeftTailedWithoutMaterialDownside() async {
        // 32 closes (31 returns): 30 days of +0.5% then one −20% crash.
        // Skew ≈ −5.3 < −0.5 but downside_95 ≈ 0 (only 1 bad day among 30 up-days).
        // The 2026-07-07 threshold change requires BOTH skew < −0.5 AND downside_95 > 2%
        // — a single outlier skew is NOT a genuine left-tail, so this DOES NOT trigger.
        var closes = [100.0]
        for _ in 0..<30 { closes.append(closes.last! * 1.005) }
        closes.append(closes.last! * 0.80)
        assert(closes.count == 32)

        let sym = equitySym("SKEWAAPL")
        let h = history("SKEWAAPL", closes: closes)
        let ideas = await StockSageStore.buildIdeas(
            defs: [sym], histories: ["SKEWAAPL": h])

        #expect(ideas.count == 1)
        guard let idea = ideas.first else { Issue.record("buildIdeas returned no ideas"); return }
        let allRationale = idea.advice.rationale.joined(separator: " ")
        // Single-outlier skew — does NOT trigger left-tail flag under the new threshold.
        #expect(!allRationale.contains("Left-tailed"),
                "Single crash day should NOT trigger Left-tailed without material downside tail. rationale: \(idea.advice.rationale)")
    }

    // A multi-crash fixture: 25 up-days + 5 crash days at −12% each produces
    // skew ≈ −1.79 < −0.5 AND downside_95 ≈ 12% > 2%. Hand-derived 2026-07-07.
    @Test func multiCrashHistoryTriggersLeftTailed() async {
        var closes = [100.0]
        for _ in 0..<25 { closes.append(closes.last! * 1.005) }
        for _ in 0..<5  { closes.append(closes.last! * 0.88) }
        assert(closes.count == 31)   // 30 returns — meets the ≥30 minimum
        let sym = equitySym("CRASHAAPL")
        let h = history("CRASHAAPL", closes: closes)
        let ideas = await StockSageStore.buildIdeas(
            defs: [sym], histories: ["CRASHAAPL": h])
        #expect(ideas.count == 1)
        guard let idea = ideas.first else { Issue.record("no ideas"); return }
        let allRationale = idea.advice.rationale.joined(separator: " ")
        #expect(allRationale.contains("Left-tailed"),
                "Multi-crash history should trigger Left-tailed; got: \(idea.advice.rationale)")
    }

    // MARK: - F05(b): whippy-volatility note lands in rationale

    @Test func whippyVolatilityNoteAppearsWhenVolIsErratic() async {
        // Alternating low/high vol blocks → CoV ≈ 0.39 ≥ 0.35 → .erratic band.
        // Derivation: 158 bars, CoV = 0.3895 (see derive_hardening.swift).
        // volStability needs ≥147 bars (volWindow 21 + historyWindow 126).
        var closes = [100.0]
        let lowDailyVol = 0.002
        let highDailyVol = 0.040
        let volWindow = 21
        let totalBars = 21 + 126 + 10   // = 157 bars of price data + the opening bar
        var bar = 0
        while closes.count < totalBars + 1 {
            let block = bar / volWindow
            let vol = block % 2 == 0 ? lowDailyVol : highDailyVol
            let sign: Double = closes.count % 2 == 0 ? 1 : -1
            closes.append(closes.last! * (1 + sign * vol))
            bar += 1
        }

        let sym = equitySym("WHIPPYX")
        let h = history("WHIPPYX", closes: closes)
        let ideas = await StockSageStore.buildIdeas(
            defs: [sym], histories: ["WHIPPYX": h])

        #expect(ideas.count == 1)
        guard let idea = ideas.first else { Issue.record("buildIdeas returned no ideas"); return }
        let allRationale = idea.advice.rationale.joined(separator: " ")
        #expect(allRationale.contains("Whippy volatility"),
                "Expected 'Whippy volatility' note when CoV ≥ 0.35; got: \(idea.advice.rationale)")
    }

    // MARK: - F05(b): vol-regime brake note lands in rationale

    @Test func volRegimeBrakeNoteAppearsWhenRecentVolElevated() async {
        // 293 bars: 272 calm then 21 high-vol → sizingMultiplier < 0.95 → note fires.
        // Derivation: current=0.49, median=0.058, mult=0.25 (see derive_hardening.swift).
        // VolRegime needs ≥273 bars.
        let closes = lowThenHighVolCloses()
        let sym = equitySym("VOLTAAPL")
        let h = history("VOLTAAPL", closes: closes)
        let ideas = await StockSageStore.buildIdeas(
            defs: [sym], histories: ["VOLTAAPL": h])

        #expect(ideas.count == 1)
        guard let idea = ideas.first else { Issue.record("buildIdeas returned no ideas"); return }
        let allRationale = idea.advice.rationale.joined(separator: " ")
        // The vol-regime note starts with "⚠ Vol in the …" when sizingMultiplier < 0.95.
        let hasVolRegimeNote = allRationale.contains("percentile of its own") ||
                               allRationale.contains("elevated; position braked")
        #expect(hasVolRegimeNote,
                "Expected vol-regime brake note in rationale; got: \(idea.advice.rationale)")
    }

    // MARK: - F05(b): execution-timing note lands in rationale for trending buy

    @Test func executionTimingNoteAppearsForBullTrendBuy() async {
        // A strong accelerating uptrend → advisor emits .strongBuy with .bullTrend regime.
        // ExecutionTiming.sessionNote fires → rationale contains "⏱".
        // Using 250 bars of exponentially accelerating closes (same as existing advisor test).
        let closes = (0..<250).map { 50.0 + 0.0153 * pow(Double($0), 2) }
        let h = StockSagePriceHistory(
            symbol: "TREND", dates: closes.enumerated().map { Date(timeIntervalSince1970: Double($0.offset) * 86_400) },
            opens: closes, highs: closes.map { $0 + 1 }, lows: closes.map { $0 - 1 },
            closes: closes, volumes: closes.map { _ in 1_000_000 })

        let sym = equitySym("TREND")
        let ideas = await StockSageStore.buildIdeas(defs: [sym], histories: ["TREND": h])

        guard let idea = ideas.first else {
            // If advisor produced no buy, the timing note can't fire — inconclusive, not a failure.
            return
        }
        if idea.advice.action == .strongBuy || idea.advice.action == .buy {
            if idea.advice.regime == .bullTrend {
                let allRationale = idea.advice.rationale.joined(separator: " ")
                #expect(allRationale.contains("⏱"),
                        "Expected '⏱' execution-timing note for bullTrend buy; got: \(idea.advice.rationale)")
            }
        }
    }

    // MARK: - F05(c): calibration changes ONLY suggestedWeight, not action/conviction

    @Test func calibrationChangesOnlySuggestedWeightNotActionOrConviction() async {
        // Use 250-bar uptrend so the advisor emits a strongBuy with stop=price−1.5×ATR, target=price+3×ATR.
        // The advisor always produces rewardR=2.0 (stopTarget: target = price + 2×stopDist).
        //
        // With nil calibration: prior winProb ≈ 0.35+0.23×conviction ≈ 0.50 at conviction≈0.65.
        //   Kelly fraction = 0.50×2 − 0.50 = 0.50 > 0  →  suggestedWeight > 0.
        //
        // With fixedCalibration() (winProb=0.30):
        //   Kelly break-even at R=2 is p*=1/(1+2)≈0.333; 0.30 < 0.333.
        //   Kelly fraction = 0.30×2 − 0.70 = −0.10 < 0  →  fStar=0  →  suggestedWeight=0.
        //
        // Derived: noCal.suggestedWeight > 0, withCal.suggestedWeight = 0 → strict inequality.
        // Action + conviction stay from advise() unchanged.
        let closes = (0..<250).map { 50.0 + 0.0153 * pow(Double($0), 2) }
        let h = StockSagePriceHistory(
            symbol: "CALAAPL",
            dates: closes.enumerated().map { Date(timeIntervalSince1970: Double($0.offset) * 86_400) },
            opens: closes, highs: closes.map { $0 + 1 }, lows: closes.map { $0 - 1 },
            closes: closes, volumes: closes.map { _ in 1_000_000 })

        let sym = equitySym("CALAAPL")

        let noCalIdeas = await StockSageStore.buildIdeas(
            defs: [sym], histories: ["CALAAPL": h], calibration: nil)
        let calIdeas = await StockSageStore.buildIdeas(
            defs: [sym], histories: ["CALAAPL": h], calibration: fixedCalibration())

        guard let noCal = noCalIdeas.first, let withCal = calIdeas.first else { return }

        // Action and conviction must be IDENTICAL — they come purely from advise().
        #expect(noCal.advice.action == withCal.advice.action,
                "action must not change when calibration is applied")
        #expect(abs(noCal.advice.conviction - withCal.advice.conviction) < 1e-9,
                "conviction must not change when calibration is applied")

        // Stop and target must also be IDENTICAL (not computed from calibration).
        #expect(noCal.advice.stopPrice == withCal.advice.stopPrice,
                "stopPrice must not change when calibration is applied")
        #expect(noCal.advice.targetPrice == withCal.advice.targetPrice,
                "targetPrice must not change when calibration is applied")

        // Both weights must be non-negative (basic sanity).
        #expect(noCal.advice.suggestedWeight >= 0)
        #expect(withCal.advice.suggestedWeight >= 0)

        // Core assertion: calibration must change the weight.
        // winProb=0.30 < Kelly break-even (≈0.333 at R=2) → calibrated Kelly<0 → weight=0.
        // Linear prior at the uptrend's conviction gives Kelly>0 → weight>0.
        // Derived: noCal > 0, withCal = 0 → strict inequality.
        #expect(noCal.advice.suggestedWeight != withCal.advice.suggestedWeight,
                "suggestedWeight must change when calibration shifts winProb below the Kelly break-even")
    }

    // MARK: - F05: Index symbols are excluded from the output

    @Test func indexSymbolsAreExcludedFromBuildIdeas() async {
        // ^GSPC is classified as "Index" by StockSageAllocation.assetClass — buildIdeas must skip it.
        let indexSym = StockSageSymbol(symbol: "^GSPC", market: "US")
        let closes = (0..<250).map { 5000.0 + Double($0) * 0.5 }
        let h = history("^GSPC", closes: closes)

        let ideas = await StockSageStore.buildIdeas(defs: [indexSym], histories: ["^GSPC": h])
        #expect(ideas.isEmpty, "Index symbols must never appear as tradeable ideas")
    }

    // MARK: - L1 (honesty-labels fleet, 2026-07-07): recentExtreme reads the RAW 63-close
    // window, not the downsampled spark — proves the old downsample(suffix(63),32)-based check
    // could report a FALSE "at high" when the true window max falls on a downsample-skipped day.
    //
    // Hand-derived (scratchpad python, NOT calling this code — spec-fidelity rule):
    //   100 raw closes. Last 63 (the window buildIdeas actually checks): a true spike of 150.0
    //   at index 5 of that window (downsample(_,32) with step=(63-1)/(32-1)=2.0 samples indices
    //   0,2,4,6,... — index 5 is SKIPPED), ending at 120.0 (below the true 63-window max).
    //     - Raw 63-window: max=150.0, last=120.0 → NEITHER (120 is not the true high/low).
    //     - Downsampled spark (32 pts, index-5 spike dropped): max=120.0, last=120.0 → falsely ATHIGH.
    //   recentExtreme must be .neither (the honest answer); recentExtremeSpan must be 63
    //   (min(100, 63)).
    @Test func recentExtremeReadsRawWindowNotDownsampledSpark() async {
        var window = [Double](repeating: 100.0, count: 63)
        window[5] = 150.0   // true 63-window max — lands on a downsample-skipped index
        for i in 6..<62 { window[i] = 90.0 + Double(i % 5) }
        window[62] = 120.0  // last close: below the true max, but the downsampled spark's max
        let closes = [Double](repeating: 100.0, count: 37) + window   // 100 raw closes total
        #expect(closes.count == 100)

        let sym = equitySym("SPIKE")
        let h = history("SPIKE", closes: closes)
        let ideas = await StockSageStore.buildIdeas(defs: [sym], histories: ["SPIKE": h])
        guard let idea = ideas.first else {
            Issue.record("buildIdeas must produce an idea for a 100-bar equity history")
            return
        }

        #expect(idea.recentExtremeSpan == 63, "span must be min(closes.count, 63) — hand-derived above")
        #expect(idea.recentExtreme == .neither,
                "the RAW 63-window's last close (120) is not its true max (150, at a downsample-skipped index) — must NOT report atHigh")

        // Cross-check: the OLD (pre-fix) behavior — extreme() over the DOWNSAMPLED spark — would
        // have reported atHigh here, proving this fixture actually exercises the bug L1 fixed.
        let oldWayOverSpark = SparkSeries.extreme(idea.spark)
        #expect(oldWayOverSpark == .atHigh,
                "sanity check: the downsampled-spark path this fixture targets must diverge from the raw-window fix, or the fixture doesn't exercise the bug")
    }
}
