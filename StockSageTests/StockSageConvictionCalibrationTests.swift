import Testing
import Foundation
@testable import StockSage

// MARK: - Conviction → win-probability calibration (pure)

struct StockSageConvictionCalibrationTests {
    typealias Cal = StockSageConvictionCalibration

    @Test func fitReturnsNilBelowMinSamples() {
        let few = (0..<10).map { (conviction: Double($0) / 10, won: $0.isMultiple(of: 2)) }
        #expect(Cal.fit(few, minSamples: 30) == nil)
    }

    @Test func wilsonLowerBoundIsConservativeAndBounded() {
        // 8/10 raw = 0.8, but the lower bound must sit BELOW it (small-sample haircut) and in [0,1].
        let lb = Cal.wilsonLowerBound(wins: 8, n: 10, z: 1.0)
        #expect(lb < 0.8)
        #expect(lb > 0)
        #expect(Cal.wilsonLowerBound(wins: 0, n: 0) == 0)          // no data → 0
        #expect(Cal.wilsonLowerBound(wins: 10, n: 10) < 1.0)       // even all-wins isn't certainty
        // More samples at the same rate → a TIGHTER (higher) lower bound.
        #expect(Cal.wilsonLowerBound(wins: 80, n: 100) > Cal.wilsonLowerBound(wins: 8, n: 10))
    }

    @Test func poolAdjacentViolatorsProducesMonotoneResult() {
        let out = Cal.poolAdjacentViolators([0.6, 0.3, 0.5], weights: [1, 1, 1])
        #expect(out.count == 3)
        for i in 1..<out.count { #expect(out[i] >= out[i - 1] - 1e-9) }   // non-decreasing
        // The first two violate (0.6 > 0.3) → pooled to their mean 0.45.
        #expect(abs(out[0] - 0.45) < 1e-9)
        #expect(abs(out[1] - 0.45) < 1e-9)
        // Already-monotone input is returned unchanged.
        #expect(Cal.poolAdjacentViolators([0.1, 0.2, 0.9], weights: [1, 1, 1]) == [0.1, 0.2, 0.9])
    }

    @Test func higherConvictionCalibratesToHigherWinProb() {
        // Low-conviction trades mostly lose; high-conviction trades mostly win.
        var outcomes: [(conviction: Double, won: Bool)] = []
        for i in 0..<20 { outcomes.append((conviction: 0.1, won: i < 4)) }   // 20% win
        for i in 0..<20 { outcomes.append((conviction: 0.9, won: i < 16)) }  // 80% win
        let cal = Cal.fit(outcomes, minSamples: 30)
        #expect(cal != nil)
        guard let cal else { return }
        #expect(cal.sampleSize == 40)
        #expect(cal.winProb(0.9) > cal.winProb(0.1))            // edge increases with conviction
        #expect(cal.winProb(0.9) < 0.8)                         // conservative: below the raw 80%
        // Bands are monotonic non-decreasing by construction.
        for i in 1..<cal.bins.count { #expect(cal.bins[i].winProb >= cal.bins[i - 1].winProb - 1e-9) }
    }

    @Test func isotonicFixesAnInvertedSample() {
        // A LUCKY low-conviction band beats a high-conviction one — calibration must not reward it:
        // the monotone fit pools the violation so winProb never decreases with conviction.
        var outcomes: [(conviction: Double, won: Bool)] = []
        for i in 0..<15 { outcomes.append((conviction: 0.1, won: i < 12)) }  // 80% (lucky low band)
        for i in 0..<15 { outcomes.append((conviction: 0.9, won: i < 6)) }   // 40% high band
        let cal = Cal.fit(outcomes, minSamples: 20)
        #expect(cal != nil)
        guard let cal else { return }
        #expect(cal.winProb(0.9) >= cal.winProb(0.1) - 1e-9)   // monotonicity restored
    }

    @Test func winProbClampsAndLooksUpBand() {
        let outcomes = (0..<40).map { (conviction: Double($0 % 10) / 10, won: ($0 % 10) >= 5) }
        guard let cal = Cal.fit(outcomes, minSamples: 30) else { Issue.record("expected a fit"); return }
        #expect(cal.winProb(-5) == cal.winProb(0))     // clamps low
        #expect(cal.winProb(5) == cal.winProb(1))      // clamps high
    }

    @Test func fitFromBacktestUsesPositiveRAsWin() {
        // Build trades: high-conviction winners (r>0), low-conviction losers (r<0).
        var trades: [BacktestTrade] = []
        for _ in 0..<20 { trades.append(BacktestTrade(entryIndex: 1, exitIndex: 2, entry: 100, exit: 110,
                                                      r: 2.0, outcome: .target, conviction: 0.9)) }
        for _ in 0..<20 { trades.append(BacktestTrade(entryIndex: 1, exitIndex: 2, entry: 100, exit: 95,
                                                      r: -1.0, outcome: .stop, conviction: 0.1)) }
        let dates = (0..<4).map { Date(timeIntervalSince1970: Double($0) * 86_400) }
        let cal = Cal.fit(observations: Cal.observations(fromBacktest: trades, dates: dates))
        #expect(cal != nil)
        #expect((cal?.winProb(0.9) ?? 0) > (cal?.winProb(0.1) ?? 1))
    }

    @Test func pooledBacktestKeepsPredictionAndLabelTimesAcrossSymbols() throws {
        let dates = (0..<43).map { Date(timeIntervalSince1970: Double($0) * 86_400) }
        let trades: [BacktestTrade] = (0..<40).map { day -> BacktestTrade in
            let won = day >= 20
            return BacktestTrade(entryIndex: day + 1, exitIndex: day + 2, entry: 100,
                                 exit: won ? 110.0 : 95.0, r: won ? 2.0 : -1.0,
                                 outcome: won ? .target : .stop, conviction: Double(day) / 40)
        }
        // Two symbols share a calendar, but arrive in symbol-grouped order.
        let oneSymbol = Cal.observations(fromBacktest: trades, dates: dates)
        let pooled = oneSymbol + oneSymbol
        #expect(oneSymbol.first?.predictedAt == dates[0], "The conviction precedes the next-open fill")
        #expect(oneSymbol.first?.knownAt == dates[3])
        let fitted = try #require(Cal.fit(observations: pooled))
        let reversed = try #require(Cal.fit(observations: Array(pooled.reversed())))
        #expect(fitted == reversed)
        #expect(fitted.sampleSize == 80 && fitted.validation == .timePurged)
    }

    @Test func backtestCalibrationRejectsMissingTimesAndCensoredLabels() {
        let dates = (0..<4).map { Date(timeIntervalSince1970: Double($0) * 86_400) }
        let valid = BacktestTrade(entryIndex: 1, exitIndex: 2, entry: 100, exit: 110,
                                  r: 1, outcome: .target, conviction: 0.5)
        let open = BacktestTrade(entryIndex: 1, exitIndex: 2, entry: 100, exit: 110,
                                 r: 1, outcome: .openAtEnd, conviction: 0.5)
        let invalidIndex = BacktestTrade(entryIndex: 1, exitIndex: 100, entry: 100, exit: 110,
                                         r: 1, outcome: .target, conviction: 0.5)
        let noPrediction = BacktestTrade(entryIndex: 0, exitIndex: 2, entry: 100, exit: 110,
                                         r: 1, outcome: .target, conviction: 0.5)
        let rows = Cal.observations(fromBacktest: [valid, open, invalidIndex, noPrediction], dates: dates)
        #expect(rows.count == 1 && rows.first?.won == true)
        #expect(Cal.observations(fromBacktest: [valid], dates: []).isEmpty,
                "Missing chronology must never fall back to input order")
    }

    @Test func backtestOutcomeIsNotKnownAtBarStart() throws {
        let dates = (0..<4).map { Date(timeIntervalSince1970: Double($0) * 86_400) }
        let trade = BacktestTrade(entryIndex: 1, exitIndex: 2, entry: 100, exit: 110,
                                  r: 1, outcome: .target, conviction: 0.5)
        let observed = try #require(Cal.observations(fromBacktest: [trade], dates: dates).first)
        #expect(observed.predictedAt == dates[0])
        #expect(observed.knownAt == dates[3], "A daily bar's start timestamp does not establish when its outcome was available")
        #expect(Cal.observations(fromBacktest: [trade], dates: Array(dates.prefix(3))).isEmpty,
                "No following boundary: do not invent an availability time for the final bar")
        #expect(Cal.observations(fromBacktest: [trade], dates: [dates[0], dates[1], dates[0], dates[3]]).isEmpty)
    }

    @Test func fitFromJournalUsesClosedTradesWithConviction() {
        func rec(_ conv: Double?, exit: Double?) -> TradeRecord {
            TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: 130, shares: 1,
                        openedAt: Date(timeIntervalSince1970: 0),
                        exitPrice: exit, closedAt: exit == nil ? nil : Date(timeIntervalSince1970: 86_400),
                        conviction: conv)
        }
        var trades: [TradeRecord] = []
        for i in 0..<20 { trades.append(rec(0.9, exit: i < 16 ? 110 : 95)) }  // high conv, 80% win (R>0)
        for i in 0..<20 { trades.append(rec(0.1, exit: i < 4 ? 110 : 95)) }   // low conv, 20% win
        trades.append(rec(0.9, exit: nil))   // OPEN (no realized R) → excluded
        trades.append(rec(nil, exit: 110))   // no conviction → excluded
        let cal = StockSageConvictionCalibration.fit(fromJournal: trades, minSamples: 30)
        #expect(cal != nil)
        #expect(cal?.sampleSize == 40)       // only the 40 closed-with-conviction trades
        #expect((cal?.winProb(0.9) ?? 0) > (cal?.winProb(0.1) ?? 1))
    }

    @Test func chronologicalSplitIsTimeOrderedAndEmbargoed() {
        func rec(_ day: Int) -> TradeRecord {
            TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: 130, shares: 1,
                        openedAt: Date(timeIntervalSince1970: Double(day) * 86_400),
                        exitPrice: 110, closedAt: Date(timeIntervalSince1970: Double(day) * 86_400 + 3600),
                        conviction: Double(day) / 10)
        }
        let trades = (0..<10).map(rec)   // close days 0…9
        let s = StockSageConvictionCalibration.chronologicalSplit(trades, testFraction: 0.3, embargo: 1)
        #expect(s.test.count == 3)       // most-recent 30%
        #expect(s.train.count == 6)      // 10 − 3 test − 1 embargoed
        // Train strictly precedes test in time; the embargoed boundary trade is in neither set.
        #expect(s.train.allSatisfy { tr in s.test.allSatisfy { tr.openedAt < $0.openedAt } })
        #expect(!s.train.contains { $0.openedAt == s.test.first!.openedAt })
        // Too few closed trades to split honestly → empty.
        #expect(StockSageConvictionCalibration.chronologicalSplit(Array(trades.prefix(2))).test.isEmpty)
    }

    private static func timedTrade(_ open: Double, _ close: Double, symbol: String = "TEST") -> TradeRecord {
        TradeRecord(symbol: symbol, side: .long, entry: 100, stop: 90, target: 120, shares: 1,
                    openedAt: Date(timeIntervalSince1970: open * 86_400), exitPrice: 110,
                    closedAt: Date(timeIntervalSince1970: close * 86_400), conviction: 0.5)
    }

    @Test func journalHoldoutPurgesOverlappingLabels() {
        let overlap = (0..<3).map { Self.timedTrade(Double($0), Double($0 + 10), symbol: "TEST\($0)") }
        for input in [overlap, Array(overlap.reversed())] {
            let split = Cal.chronologicalSplit(input)
            #expect(split.train.allSatisfy { train in
                split.test.allSatisfy { train.closedAt! < $0.openedAt }
            }, "No training label may become known at or after a held-out prediction")
            #expect(split.train.isEmpty, "Every available training label overlaps this holdout")
        }
        let control = (0..<6).map { Self.timedTrade(Double($0), Double($0) + 0.25) }
        let clean = Cal.chronologicalSplit(control)
        #expect(clean.train.count == 3 && clean.test.count == 2)
    }

    @Test func unavailableLabelsCannotEarnAnOOSCalibration() throws {
        let trades = (0..<50).map { Self.timedTrade(Double($0), Double($0 + 100), symbol: "TEST\($0)") }
        let fitted = try #require(Cal.fit(fromJournal: trades))
        #expect(fitted.method == .identity, "Too little time-separated training evidence must remain assumed")
        #expect(fitted.validation == .unvalidated)
        #expect(fitted.winProb(0.5) <= 0.465 + 1e-12, "The prior ceiling must also hold at n>=44 after purging")
        let reloaded = try PropertyListDecoder().decode(Cal.self, from: PropertyListEncoder().encode(fitted))
        #expect(reloaded == fitted && reloaded.winProb(0.5) <= 0.465 + 1e-12)
        #expect(Cal.validateOutOfSample(trades) == nil, "An overlapping sample cannot report an OOS score")
    }

    @Test func simultaneousPredictionGroupsStayTogether() {
        let testEdge = (0..<6).map(Double.init) + [6, 6, 6, 6]
        let rows = testEdge.enumerated().map { Self.timedTrade($0.element, $0.element + 0.1 + Double($0.offset) / 1000) }
        let split = Cal.chronologicalSplit(rows)
        #expect(split.test.count == 4, "Move the test boundary to the beginning of its prediction group")
        let embargoEdge: [Double] = [0, 1, 2, 3, 4, 5, 5, 6, 7, 8]
        let embargoRows = embargoEdge.map { Self.timedTrade($0, $0 + 0.1) }
        let embargoSplit = Cal.chronologicalSplit(embargoRows)
        #expect(embargoSplit.train.count == 5, "Embargo the entire boundary prediction group")
        #expect(embargoSplit.test.count == 3)
    }

    @Test func purgedTrainingMinimumUsesAvailableLabelsNotTotalRows() throws {
        for delayed in [1, 4, 5] {
            let trades = (0..<50).map { i in
                Self.timedTrade(Double(i), i < delayed ? 1_000 : Double(i) + 0.1, symbol: "TEST\(i)")
            }
            let split = Cal.chronologicalSplit(trades)
            #expect(split.train.count == 34 - delayed && split.test.count == 15)
            #expect(split.train.allSatisfy { $0.closedAt! < split.test[0].openedAt })
            let fit = try #require(Cal.fit(fromJournal: trades))
            #expect(fit.sampleSize == 50)
            if delayed <= 4 {
                #expect(fit.validation == .timePurged && fit.method != .identity)
            } else {
                #expect(fit.validation == .unvalidated && fit.method == .identity)
                #expect(fit.winProb(0.5) <= 0.465 + 1e-12)
            }
        }
    }

    @Test func sameTimeLabelsAndInvalidSplitParametersFailClosed() {
        let equalBoundary = [Self.timedTrade(0, 2), Self.timedTrade(1, 1.1), Self.timedTrade(2, 2.1)]
        #expect(Cal.chronologicalSplit(equalBoundary).train.isEmpty, "A same-time label is not known before prediction")
        let control = (0..<6).map { Self.timedTrade(Double($0), Double($0) + 0.25) }
        for fraction in [0, 1, -1, 2, Double.nan, Double.infinity] {
            let split = Cal.chronologicalSplit(control, testFraction: fraction)
            #expect(split.train.isEmpty && split.test.isEmpty)
        }
        #expect(Cal.chronologicalSplit(control, embargo: Int.max).train.isEmpty)
        #expect(Cal.chronologicalSplit(control, embargo: -1).train.count == 4)
    }

    @Test func journalCalibrationExcludesUnfinalizedAndIncoherentLabels() throws {
        let valid = (0..<30).map { Self.timedTrade(Double($0), Double($0) + 0.1) }
        var exitWithoutClose = Self.timedTrade(40, 41); exitWithoutClose.closedAt = nil
        let invertedClose = Self.timedTrade(40, 39)
        var noExit = Self.timedTrade(40, 41); noExit.exitPrice = nil
        var nonfiniteR = Self.timedTrade(40, 41); nonfiniteR.exitPrice = .infinity
        let fit = try #require(Cal.fit(fromJournal: valid + [exitWithoutClose, invertedClose, noExit, nonfiniteR]))
        #expect(fit.sampleSize == 30, "Only coherent finalized outcomes can train the calibration")
    }

    @Test func validateOutOfSampleBeatsBaselineOnSeparableJournal() {
        func rec(_ day: Int, conv: Double, win: Bool) -> TradeRecord {
            TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: 130, shares: 1,
                        openedAt: Date(timeIntervalSince1970: Double(day) * 86_400),
                        exitPrice: win ? 110 : 95,
                        closedAt: Date(timeIntervalSince1970: Double(day) * 86_400 + 3600),
                        conviction: conv)
        }
        // 50 trades, relationship holds in BOTH train and test: high conviction wins, low loses.
        let trades = (0..<50).map { i -> TradeRecord in
            let high = i.isMultiple(of: 2)
            return rec(i, conv: high ? 0.9 : 0.1, win: high)
        }
        let chk = StockSageConvictionCalibration.validateOutOfSample(trades, testFraction: 0.3,
                                                                     embargo: 1, minTrainSamples: 20)
        #expect(chk != nil)
        guard let chk else { return }
        #expect(chk.n >= 1)
        #expect(chk.oosBrier >= 0)
        #expect(chk.oosBrier < chk.baselineBrier)   // beats the no-skill base-rate predictor OOS
        #expect(chk.addsSkill)
        // Too few trades to fit/split → nil (no false precision).
        #expect(StockSageConvictionCalibration.validateOutOfSample(Array(trades.prefix(5))) == nil)
    }

    // MARK: - F35 always-true invariant (assert replaces dead guard, dead width pair removed)
    //
    // The `if train.count >= minTrainSamples` guard in selectCalibration was ALWAYS true:
    // the guard at the top of selectCalibration ensures n - testN - gap >= minTrainSamples,
    // and train = outcomes[0..<(n-testN-gap)], so train.count == n-testN-gap >= minTrainSamples
    // by construction. The guard was replaced by an assert (F35 2026-07-02) that documents
    // this invariant. The dead `width` / `_ = width` pair was also removed.
    // This test exercises the selectCalibration path at the minimum-valid sample count to
    // confirm the assert never fires in practice (if it did, the build would crash).

    @Test func selectCalibrationInvariantHoldsAtMinimumSampleCount() {
        // Minimum input that passes the selectCalibration entry guard:
        //   testN = round(n * 0.3) >= 1  →  n >= 4
        //   n - testN - embargo >= minTrainSamples(30)
        //   For n=44: testN = round(44*0.3) = round(13.2) = 13, gap=1, train=44-13-1=30 ≥ 30 ✓
        // If the assert were wrong (train.count < minTrainSamples could happen), this call
        // would crash in Debug builds — the test passing proves the invariant holds.
        var outcomes: [(conviction: Double, won: Bool)] = []
        for i in 0..<44 {
            outcomes.append((conviction: Double(i % 10) / 10.0, won: i.isMultiple(of: 2)))
        }
        // candidateSelectorEnabled is true (owner-activated 2026-06-27); fit() calls selectCalibration.
        let cal = StockSageConvictionCalibration.fit(outcomes, minSamples: 30)
        #expect(cal != nil, "selectCalibration must succeed at n=44 (minimum passing boundary)")
    }

    @Test func expectedValueUsesCalibrationWhenProvided() {
        // Without calibration → the linear prior (0.35 + 0.23·c).
        #expect(abs(StockSageExpectedValue.winProbEstimate(conviction: 0.5) - (0.35 + 0.23 * 0.5)) < 1e-9)
        // With calibration → the calibrated band value, not the prior.
        var outcomes: [(conviction: Double, won: Bool)] = []
        for i in 0..<30 { outcomes.append((conviction: 0.9, won: i < 24)) }   // 80%
        for i in 0..<10 { outcomes.append((conviction: 0.1, won: i < 1)) }    // 10%
        guard let cal = StockSageConvictionCalibration.fit(outcomes, minSamples: 30) else {
            Issue.record("expected a fit"); return
        }
        let calibrated = StockSageExpectedValue.winProbEstimate(conviction: 0.9, calibration: cal)
        #expect(calibrated == cal.winProb(0.9))
        #expect(calibrated != 0.35 + 0.23 * 0.9)   // differs from the linear prior
        // EV plumbs it through too.
        let ev = StockSageExpectedValue.ev(conviction: 0.9, entry: 100, stop: 90, target: 120, calibration: cal)
        #expect(ev?.winProbEstimate == cal.winProb(0.9))
    }
}
