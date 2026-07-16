import Testing
import Foundation
@testable import StockSage

// MARK: - Trade journal P&L / R math (pure)

struct StockSageJournalTests {

    private func t(_ side: TradeRecord.Side, entry: Double, stop: Double, shares: Double,
                   exit: Double? = nil) -> TradeRecord {
        tSym("X", side, entry: entry, stop: stop, shares: shares, exit: exit)
    }

    private func tSym(_ symbol: String, _ side: TradeRecord.Side, entry: Double, stop: Double,
                      shares: Double, exit: Double? = nil) -> TradeRecord {
        TradeRecord(symbol: symbol, side: side, entry: entry, stop: stop, target: nil,
                    shares: shares, openedAt: Date(timeIntervalSince1970: 0),
                    exitPrice: exit, closedAt: exit == nil ? nil : Date(timeIntervalSince1970: 100))
    }

    @Test func openActionsGivesSideAwareLiveVerdicts() {
        func open(_ side: TradeRecord.Side, _ stop: Double, _ target: Double?) -> TradeRecord {
            TradeRecord(symbol: "X", side: side, entry: 100, stop: stop, target: target, shares: 10,
                        openedAt: Date(timeIntervalSince1970: 0))
        }
        func at(_ p: Double) -> (String) -> Double? { { _ in p } }
        let long = open(.long, 90, 130)
        #expect(StockSageJournal.openActions([long], mark: at(89)).first?.kind == .stopHit)     // at/below stop
        #expect(StockSageJournal.openActions([long], mark: at(130)).first?.kind == .targetHit)  // at target
        #expect(StockSageJournal.openActions([long], mark: at(92.5)).first?.kind == .nearStop)  // −0.75R
        #expect(StockSageJournal.openActions([long], mark: at(120)).first?.kind == .inProfit)   // +2R
        // Short mirrors it: stop ABOVE, target BELOW.
        let short = open(.short, 110, 80)
        #expect(StockSageJournal.openActions([short], mark: at(111)).first?.kind == .stopHit)   // at/above stop
        #expect(StockSageJournal.openActions([short], mark: at(79)).first?.kind == .targetHit)  // at/below target
        // Short rNow-branches: a short PROFITS as price falls, so the R sign convention flips.
        #expect(StockSageJournal.openActions([short], mark: at(90)).first?.kind == .inProfit)    // +1R short
        #expect(StockSageJournal.openActions([short], mark: at(107.5)).first?.kind == .nearStop) // −0.75R short
        // No mark / closed trade → skipped.
        #expect(StockSageJournal.openActions([long], mark: { _ in nil }).isEmpty)
        // Urgent (stop hit) sorts before in-profit.
        let y = TradeRecord(symbol: "Y", side: .long, entry: 100, stop: 90, target: 130, shares: 10,
                            openedAt: Date(timeIntervalSince1970: 0))
        let two = StockSageJournal.openActions([long, y], mark: { $0 == "X" ? 120 : 89 })
        #expect(two.first?.symbol == "Y" && two.first?.kind == .stopHit)
    }

    @Test func perBucketReliabilityGatesSmallSamples() {
        // The min-n honesty gate: a thin bucket is "too few to tell", a full one is reliable.
        #expect(!StockSageJournal.bucketReliability(closedWithR: 4).isReliable)   // < 5 default
        #expect(StockSageJournal.bucketReliability(closedWithR: 5).isReliable)    // == 5
        let thin = StockSageJournal.bucketReliability(closedWithR: 4)
        #expect(thin.tooFewLabel.contains("n=4") && thin.tooFewLabel.contains("need 5"))
        // Overloads read the R-DEFINED sample (closedWithR), NOT the raw closed count — a bucket
        // with 8 closed trades but only 2 with a defined R must still gate (the bughunt fix).
        let thinSector = SectorPnL(sector: "Tech", trades: 2, wins: 2, totalR: 4, winRate: 1, closedWithR: 2)
        let fullSide = SidePnL(side: .long, trades: 8, wins: 5, totalR: 3, avgR: 0.4, winRate: 0.625, closedWithR: 6)
        let thinRSide = SidePnL(side: .long, trades: 8, wins: 5, totalR: 1, avgR: 0.5, winRate: 0.625, closedWithR: 2)
        #expect(!StockSageJournal.reliability(thinSector).isReliable)
        #expect(StockSageJournal.reliability(fullSide).isReliable)
        #expect(!StockSageJournal.reliability(thinRSide).isReliable)   // 8 closed but only 2 R-defined → gated
        // The row caveat is honest: descriptive of the past, not predictive.
        #expect(StockSageJournal.attributionCaveat.lowercased().contains("not predictive"))
    }

    @Test func longProfitAndRMultiple() {
        let trade = t(.long, entry: 100, stop: 90, shares: 10)   // risk/share = 10
        #expect(trade.profit(at: 120) == 200)                    // (120−100)*10
        #expect(trade.rMultiple(at: 120) == 2.0)                 // +20 / 10 risk
        #expect(trade.rMultiple(at: 90) == -1.0)                 // hit the stop = −1R
    }

    @Test func shortProfitAndRMultiple() {
        let trade = t(.short, entry: 100, stop: 110, shares: 5)  // risk/share = 10
        #expect(trade.profit(at: 80) == 100)                     // (100−80)*5
        #expect(trade.rMultiple(at: 80) == 2.0)                  // +20 / 10
        #expect(trade.rMultiple(at: 110) == -1.0)                // stop hit = −1R
    }

    @Test func zeroRiskRIsUndefinedNotInfinite() {
        #expect(t(.long, entry: 100, stop: 100, shares: 1).rMultiple(at: 120) == nil)
    }

    @Test func realizedUsesExitPrice() {
        let win = t(.long, entry: 50, stop: 45, shares: 4, exit: 60)
        #expect(win.realizedProfit == 40)        // (60−50)*4
        #expect(win.realizedR == 2.0)            // +10 / 5
        #expect(win.isOpen == false)
        #expect(t(.long, entry: 50, stop: 45, shares: 4).realizedProfit == nil)   // still open
    }

    @Test func edgeDecomposesWinsAndLosses() {
        let trades = [
            t(.long, entry: 100, stop: 90, shares: 1, exit: 120),   // +2R win
            t(.long, entry: 100, stop: 90, shares: 1, exit: 110),   // +1R win
            t(.long, entry: 100, stop: 90, shares: 1, exit: 90),    // −1R loss
            t(.long, entry: 100, stop: 90, shares: 1),              // open → excluded
        ]
        let e = StockSageJournal.edge(trades)
        #expect(e.closedWithR == 3)
        #expect(abs(e.avgWinR - 1.5) < 1e-9)        // (2+1)/2
        #expect(abs(e.avgLossR - 1.0) < 1e-9)       // |−1|
        #expect(abs(e.payoffRatio - 1.5) < 1e-9)    // 1.5 / 1.0
        #expect(abs(e.expectancyR - (2.0 + 1.0 - 1.0) / 3) < 1e-9)   // mean realized R = (+2 +1 −1)/3
        // Expectancy equals JournalStats.avgR (consistency).
        #expect(abs(e.expectancyR - StockSageJournal.stats(trades).avgR) < 1e-9)
    }

    private func closedAt(_ symbol: String, exit: Double, at time: Double) -> TradeRecord {
        TradeRecord(symbol: symbol, side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                    openedAt: Date(timeIntervalSince1970: time - 50),
                    exitPrice: exit, closedAt: Date(timeIntervalSince1970: time))
    }

    private func closedR(_ r: Double) -> TradeRecord {
        tSym("X", .long, entry: 100, stop: 90, shares: 1, exit: 100 + r * 10)   // R = (exit−100)/10
    }

    private func held(_ exit: Double, days: Double) -> TradeRecord {
        TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                    openedAt: Date(timeIntervalSince1970: 0),
                    exitPrice: exit, closedAt: Date(timeIntervalSince1970: days * 86_400))
    }

    @Test func holdingPeriodFlagsRidingLosers() {
        // winners held 10d & 14d (avg 12), loser held 31d → riding losers.
        let h = StockSageJournal.holdingPeriod([held(120, days: 10), held(120, days: 14), held(90, days: 31)])!
        #expect(abs(h.avgWinDays - 12) < 1e-9)
        #expect(abs(h.avgLossDays - 31) < 1e-9)
        #expect(h.winCount == 2 && h.lossCount == 1)
        #expect(h.ridingLosers)
        #expect(h.note.contains("ride non-winners"))
    }

    @Test func holdingPeriodGoodDisciplineAndEmpty() {
        // winners held long (20d), losers cut fast (3d) → not riding losers.
        let h = StockSageJournal.holdingPeriod([held(120, days: 20), held(90, days: 3)])!
        #expect(!h.ridingLosers)
        #expect(h.note.contains("cut non-winners fast"))
        #expect(StockSageJournal.holdingPeriod([]) == nil)
    }

    @Test func holdingPeriodCountsBreakevenAsNonWinner() {
        // exit 100 == entry 100 → a scratch (profit 0). It must count as a NON-winner,
        // not silently vanish from the averages/counts.
        let h = StockSageJournal.holdingPeriod([held(120, days: 5), held(100, days: 40)])!
        #expect(h.winCount == 1)                    // only the +20 win
        #expect(h.lossCount == 1)                   // the scratch folded into non-wins
        #expect(abs(h.avgLossDays - 40) < 1e-9)     // its 40 days are not invisible
        #expect(h.note.contains("non-winners"))
    }

    @Test func expectancyConfidenceBand() {
        // rs = [3, 1]: mean 2; sample var = ((1)+(1))/(2−1) = 2; stdev √2; stderr √2/√2 = 1.0.
        let c = StockSageJournal.expectancyConfidence([closedR(3), closedR(1)])!
        #expect(abs(c.expectancyR - 2.0) < 1e-9)
        #expect(abs(c.stdErrR - 1.0) < 1e-9)
        #expect(c.n == 2)
        #expect(c.isSignificant)        // |2.0| ≥ 1.0
    }

    private func seq(_ rs: [Double]) -> [TradeRecord] {
        rs.enumerated().map { i, r in
            TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                        openedAt: Date(timeIntervalSince1970: Double(i) * 100),
                        exitPrice: 100 + r * 10, closedAt: Date(timeIntervalSince1970: Double(i) * 100 + 50))
        }
    }

    @Test func projectGrowthCompoundsExpectancyForward() {
        // expectancy +1R at 10%/trade, 2 trades → (1.1)^2 = 1.21; 3 trades → 1.331.
        #expect(abs(StockSageJournal.projectGrowth(expectancyR: 1.0, trades: 2, fraction: 0.10)!.multiple - 1.21) < 1e-9)
        #expect(abs(StockSageJournal.projectGrowth(expectancyR: 1.0, trades: 3, fraction: 0.10)!.multiple - 1.331) < 1e-9)
        // Negative expectancy shrinks the account: −1R at 10%, 2 trades → 0.9^2 = 0.81.
        #expect(abs(StockSageJournal.projectGrowth(expectancyR: -1.0, trades: 2, fraction: 0.10)!.multiple - 0.81) < 1e-9)
        // Guards: no trades, and a wipeout step (1 + 0.01·−200 = −1 ≤ 0) → nil.
        #expect(StockSageJournal.projectGrowth(expectancyR: 1, trades: 0) == nil)
        #expect(StockSageJournal.projectGrowth(expectancyR: -200, trades: 2, fraction: 0.01) == nil)
    }

    @Test func projectGrowthNearWipeoutStaysFiniteAndGuardsZeroStep() {
        // step = 1 + 0.01·(−99) = 0.01 → ×0.01² = 0.0001 (survives, tiny).
        #expect(abs(StockSageJournal.projectGrowth(expectancyR: -99, trades: 2, fraction: 0.01)!.multiple - 0.0001) < 1e-12)
        // step = 1 + 0.01·(−100) = 0 → wipeout guard → nil (no 0^n weirdness).
        #expect(StockSageJournal.projectGrowth(expectancyR: -100, trades: 2, fraction: 0.01) == nil)
    }

    @Test func compoundingCurveSingleTrade() {
        let c = StockSageJournal.compoundingCurve(seq([2]), fraction: 0.01)!
        #expect(c.multiples.count == 1)
        #expect(abs(c.finalMultiple - 1.02) < 1e-9)
    }

    @Test func compoundingCurveCompoundsLoggedR() {
        // R = [+2, −1, +1] at 1%/trade → ×1.02, then ×1.02·0.99 = ×1.0098,
        // then ×1.0098·1.01 = ×1.019898.
        let c = StockSageJournal.compoundingCurve(seq([2, -1, 1]), fraction: 0.01)!
        #expect(c.multiples.count == 3)
        #expect(abs(c.multiples[0] - 1.02) < 1e-9)
        #expect(abs(c.multiples[1] - 1.0098) < 1e-9)
        #expect(abs(c.finalMultiple - 1.019898) < 1e-9)
        #expect(StockSageJournal.compoundingCurve([]) == nil)
    }

    @Test func yearlyPnLRollsUpDollarsAndR() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func tr(_ entry: Double, _ exit: Double, _ shares: Double, year: Int) -> TradeRecord {
            let d = cal.date(from: DateComponents(year: year, month: 6, day: 15))!
            return TradeRecord(symbol: "X", side: .long, entry: entry, stop: 90, target: nil, shares: shares,
                               openedAt: d.addingTimeInterval(-86_400), exitPrice: exit, closedAt: d)
        }
        // 2025: +100 (entry100→110×10, R+1) and −50 (→95×10, R−0.5). 2026: +100 (→120×5, R+2).
        let y = StockSageJournal.yearlyPnL([tr(100, 110, 10, year: 2025),
                                            tr(100, 95, 10, year: 2025),
                                            tr(100, 120, 5, year: 2026)])
        #expect(y.map(\.year) == ["2026", "2025"])             // newest first
        let y25 = y.first { $0.year == "2025" }!
        #expect(y25.trades == 2 && y25.wins == 1)
        #expect(abs(y25.realizedDollars - 50) < 1e-9)          // 100 − 50
        #expect(abs(y25.totalR - 0.5) < 1e-9)                  // 1 − 0.5
        #expect(abs(y25.winRate - 0.5) < 1e-9)
        let y26 = y.first { $0.year == "2026" }!
        #expect(abs(y26.realizedDollars - 100) < 1e-9)
        #expect(abs(y26.totalR - 2) < 1e-9)
        #expect(y26.winRate == 1.0)
        #expect(StockSageJournal.yearlyPnL([]).isEmpty)
        // First-real-trade review (2026-07-16): all "X" trades are USD → single-currency year,
        // profitSymbol carried so the display renders the total labeled (byte-identical bare USD).
        #expect(y25.profitSymbol == "X")
        #expect(y26.profitSymbol == "X")
    }

    // First-real-trade review (2026-07-16): a year mixing currencies has a MEANINGLESS
    // realizedDollars 1:1 sum → profitSymbol is nil so the row shows "mixed", never the number.
    // Single-currency years keep a representative symbol. Hand-derived from conversionCurrencyForSymbol.
    @Test func yearlyPnLProfitSymbolIsNilWhenAYearMixesCurrencies() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func tr(_ symbol: String, _ entry: Double, _ exit: Double, year: Int) -> TradeRecord {
            let d = cal.date(from: DateComponents(year: year, month: 6, day: 15))!
            return TradeRecord(symbol: symbol, side: .long, entry: entry, stop: 90, target: nil, shares: 1,
                               openedAt: d.addingTimeInterval(-86_400), exitPrice: exit, closedAt: d)
        }
        let y = StockSageJournal.yearlyPnL([
            tr("AAPL", 100, 150, year: 2025),      // +50 USD
            tr("2222.SR", 100, 130, year: 2025),   // +30 SAR — same year, different currency
            tr("2222.SR", 100, 120, year: 2026),   // +20 SAR — a single-SAR year
        ])
        let y25 = y.first { $0.year == "2025" }!
        #expect(y25.profitSymbol == nil)                  // mixed → display shows "mixed"
        #expect(abs(y25.realizedDollars - 80) < 1e-9)     // raw 50+30 still computed, never shown
        let y26 = y.first { $0.year == "2026" }!
        #expect(y26.profitSymbol == "2222.SR")            // single currency → labeled
    }

    private func closedInMonth(_ y: Int, _ m: Int, exit: Double) -> TradeRecord {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let d = cal.date(from: DateComponents(year: y, month: m, day: 15))!
        return TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                           openedAt: d.addingTimeInterval(-86_400), exitPrice: exit, closedAt: d)
    }

    @Test func systemHealthDecisionTable() {
        typealias H = StockSageJournal
        // Negative: PF<1 or expectancy<0 (regardless of n).
        #expect(H.classifyHealth(profitFactor: 0.8, expectancyR: -0.2, significant: true, n: 50, maxDrawdownR: 3).verdict == .negative)
        #expect(H.classifyHealth(profitFactor: 1.2, expectancyR: -0.1, significant: true, n: 50, maxDrawdownR: 3).verdict == .negative)
        // Unproven: profitable but too few or not significant.
        #expect(H.classifyHealth(profitFactor: 2, expectancyR: 0.5, significant: false, n: 50, maxDrawdownR: 2).verdict == .unproven)
        #expect(H.classifyHealth(profitFactor: 2, expectancyR: 0.5, significant: true, n: 10, maxDrawdownR: 2).verdict == .unproven)
        // Strong: significant, PF≥1.5, contained DD (and no-losses ⇒ ∞ PF strong).
        #expect(H.classifyHealth(profitFactor: 1.8, expectancyR: 0.4, significant: true, n: 50, maxDrawdownR: 3).verdict == .strong)
        #expect(H.classifyHealth(profitFactor: nil, expectancyR: 1.0, significant: true, n: 30, maxDrawdownR: 0).verdict == .strong)
        // Developing: significant + profitable but thin PF, or a deep drawdown.
        #expect(H.classifyHealth(profitFactor: 1.2, expectancyR: 0.2, significant: true, n: 50, maxDrawdownR: 3).verdict == .developing)
        #expect(H.classifyHealth(profitFactor: 2.0, expectancyR: 0.5, significant: true, n: 50, maxDrawdownR: 12).verdict == .developing)
    }

    @Test func systemHealthWiringAndEmpty() {
        // 20 flat +1R wins → significant (0 variance), no losses (∞ PF), DD 0 → Strong.
        let strong = StockSageJournal.systemHealth(Array(repeating: closedR(1), count: 20))!
        #expect(strong.verdict == .strong)
        #expect(StockSageJournal.systemHealth([]) == nil)
    }

    @Test func bySideSplitsLongAndShort() {
        let trades = [
            tSym("A", .long, entry: 100, stop: 90, shares: 1, exit: 120),    // long +2R win
            tSym("B", .long, entry: 100, stop: 90, shares: 1, exit: 90),     // long −1R loss
            tSym("C", .short, entry: 100, stop: 110, shares: 1, exit: 70),   // short +3R win
        ]
        let s = StockSageJournal.bySide(trades)
        #expect(s.count == 2)
        let long = s.first { $0.side == .long }!
        #expect(long.trades == 2 && long.wins == 1)
        #expect(abs(long.totalR - 1.0) < 1e-9 && abs(long.avgR - 0.5) < 1e-9 && abs(long.winRate - 0.5) < 1e-9)
        let short = s.first { $0.side == .short }!
        #expect(short.trades == 1 && short.wins == 1)
        #expect(abs(short.totalR - 3.0) < 1e-9 && short.winRate == 1.0)
        #expect(StockSageJournal.bySide([]).isEmpty)
    }

    @Test func monthlyPnLGroupsByCloseMonthNewestFirst() {
        // June: +2R & −1R (2 trades, +1R); May: +3R (1 trade).
        let trades = [closedInMonth(2026, 6, exit: 120), closedInMonth(2026, 6, exit: 90),
                      closedInMonth(2026, 5, exit: 130)]
        let m = StockSageJournal.monthlyPnL(trades)
        #expect(m.count == 2)
        #expect(m[0].month == "2026-06" && m[0].trades == 2 && abs(m[0].totalR - 1.0) < 1e-9)
        #expect(m[1].month == "2026-05" && m[1].trades == 1 && abs(m[1].totalR - 3.0) < 1e-9)
        #expect(StockSageJournal.monthlyPnL([]).isEmpty)
    }

    @Test func kellyInputsFromJournalNeedSampleAndBothSides() {
        // 6 wins of +2R, 4 losses of −1R → W 0.6, payoff 2/1 = 2.0, n 10.
        let trades = Array(repeating: closedR(2), count: 6) + Array(repeating: closedR(-1), count: 4)
        let k = StockSageJournal.kellyInputs(trades)!
        #expect(abs(k.winRate - 0.6) < 1e-9)
        #expect(abs(k.payoffRatio - 2.0) < 1e-9)
        #expect(k.n == 10)
        // Under 10 closed → nil.
        #expect(StockSageJournal.kellyInputs(Array(repeating: closedR(2), count: 5) + Array(repeating: closedR(-1), count: 3)) == nil)
        // No losses → nil (can't form a payoff).
        #expect(StockSageJournal.kellyInputs(Array(repeating: closedR(2), count: 12)) == nil)
    }

    @Test func expectancyTrendDirection() {
        // ordered early [0,0,0] mean 0, recent [1,1,1] mean 1 → delta +1 > band → improving.
        let up = StockSageJournal.expectancyTrend(seq([0, 0, 0, 1, 1, 1]))!
        #expect(up.direction == .improving)
        #expect(abs(up.earlyR) < 1e-9 && abs(up.recentR - 1) < 1e-9 && abs(up.delta - 1) < 1e-9)
        #expect(StockSageJournal.expectancyTrend(seq([2, 2, 2, 0, 0, 0]))!.direction == .fading)
        #expect(StockSageJournal.expectancyTrend(seq([1, 1, 1, 1, 1, 1]))!.direction == .flat)
        #expect(StockSageJournal.expectancyTrend(seq([1, 1, 1, 1, 1])) == nil)   // <6 closed
    }

    @Test func equityRiskRunAndDrawdown() {
        // ordered R: +3,−1,−1,−1,+1 → worst run 3 losses; cumR 3,2,1,0,1 → max DD 3R.
        let r = StockSageJournal.equityRisk(seq([3, -1, -1, -1, 1]))!
        #expect(r.maxConsecutiveLosses == 3)
        #expect(abs(r.maxDrawdownR - 3.0) < 1e-9)
        #expect(StockSageJournal.equityRisk([]) == nil)
    }

    @Test func rDistributionPartitionsEachTradeOnce() {
        // bins (−∞,−1]·(−1,0]·(0,1]·(1,2]·(2,∞): −2,−1→b0; −0.5,0→b1; 0.5,1→b2; 1.5,2→b3; 3→b4.
        let trades = [-2.0, -1, -0.5, 0, 0.5, 1, 1.5, 2, 3].map { closedR($0) }
        let d = StockSageJournal.rDistribution(trades)!
        #expect(d.total == 9)
        #expect(d.bins.map(\.count) == [2, 2, 2, 2, 1])
        #expect(d.bins.map(\.count).reduce(0, +) == d.total)   // exactly one bin per trade
        #expect(d.bins.map(\.label) == ["≤−1R", "−1..0R", "0..1R", "1..2R", ">2R"])
        #expect(StockSageJournal.rDistribution([]) == nil)
    }

    // MARK: - HARDENING_BACKLOG #26: skew/kurtosis (fragile vs robust shape)

    @Test func rDistributionSkewAndKurtosisMatchTheClosedFormMoments() {
        // Same 9-trade fixture as the partition test — python-verified population moments.
        let trades = [-2.0, -1, -0.5, 0, 0.5, 1, 1.5, 2, 3].map { closedR($0) }
        let d = StockSageJournal.rDistribution(trades)!
        #expect(abs(d.skewness - 0.0) < 1e-9)
        #expect(abs(d.kurtosis - 2.1390532544378704) < 1e-9)
    }

    @Test func allEqualRealizedRGuardsToSkew0Kurt3NotNaN() {
        // Zero variance → moments are mathematically undefined (0/0); guard to the neutral
        // baseline (skew 0 = no asymmetry to read, kurt 3 = a normal distribution's raw
        // kurtosis) rather than propagate NaN into the UI.
        let trades = [1.0, 1.0, 1.0, 1.0].map { closedR($0) }
        let d = StockSageJournal.rDistribution(trades)!
        #expect(d.skewness == 0)
        #expect(d.kurtosis == 3)
    }

    @Test func leftTailedLossesProduceNegativeSkewRightTailedWinsPositive() {
        // Four small wins + one big loss → left-tailed (fragile): rare big LOSSES → negative skew.
        let leftTailed = [0.5, 0.5, 0.5, 0.5, -3.0].map { closedR($0) }
        let dLeft = StockSageJournal.rDistribution(leftTailed)!
        #expect(dLeft.skewness < -0.2)
        #expect(dLeft.shapeNote.localizedCaseInsensitiveContains("fragile"))
        // Mirror: four small losses + one big win → right-tailed (robust): rare big WINS → positive skew.
        let rightTailed = [-0.5, -0.5, -0.5, -0.5, 3.0].map { closedR($0) }
        let dRight = StockSageJournal.rDistribution(rightTailed)!
        #expect(dRight.skewness > 0.2)
        #expect(dRight.shapeNote.localizedCaseInsensitiveContains("robust"))
    }

    @Test func tradesToSignificanceEstimate() {
        // rs = [4,−2,4,−2]: mean 1; sample var = 4·9/3 = 12; s = √12; needed = (2√12/1)² = 48.
        let r = StockSageJournal.tradesToSignificance([closedR(4), closedR(-2), closedR(4), closedR(-2)])!
        #expect(r.needed == 48)
        #expect(r.more == 44)        // 48 − 4 current
        // A zero-edge sample never confirms → nil.
        #expect(StockSageJournal.tradesToSignificance([closedR(1), closedR(-1)]) == nil)
        // <2 trades → nil.
        #expect(StockSageJournal.tradesToSignificance([closedR(2)]) == nil)
    }

    @Test func nearZeroMeanHighVarianceSampleReturnsNilRatherThanTrapping() {
        // A near-zero mean (just above the 1e-9 floor) with a wide spread pushes ratio² past
        // Int.max — Int(Double) traps on that instead of returning; this must return nil.
        let trades = [closedR(1000), closedR(-1000 + 3e-9)]
        #expect(StockSageJournal.tradesToSignificance(trades) == nil)
    }

    @Test func noisyZeroMeanSampleIsNotSignificant() {
        // rs = [1,1,−1,−1]: mean 0; var = 4/3; stdev 1.1547; stderr /√4 = 0.5774 > |mean|.
        let c = StockSageJournal.expectancyConfidence([closedR(1), closedR(1), closedR(-1), closedR(-1)])!
        #expect(abs(c.expectancyR) < 1e-9)
        #expect(abs(c.stdErrR - (4.0 / 3).squareRoot() / 2) < 1e-9)
        #expect(!c.isSignificant)
        #expect(StockSageJournal.expectancyConfidence([closedR(1)]) == nil)   // n < 2
    }

    @Test func streakFindsBestWorstAndCurrentRun() {
        // By close time: AAPL +2R, MSFT +1R, JPM −1R, XOM −0.5R → 2-loss streak.
        let trades = [
            closedAt("AAPL", exit: 120, at: 100),   // +2R
            closedAt("MSFT", exit: 110, at: 200),   // +1R
            closedAt("JPM", exit: 90, at: 300),     // −1R
            closedAt("XOM", exit: 95, at: 400),     // −0.5R
        ]
        let s = StockSageJournal.streak(trades)!
        #expect(abs(s.bestR - 2.0) < 1e-9 && s.bestSymbol == "AAPL")
        #expect(abs(s.worstR - (-1.0)) < 1e-9 && s.worstSymbol == "JPM")
        #expect(s.streakCount == 2 && s.streakIsWin == false)   // XOM, JPM are the trailing losses
    }

    @Test func streakCountsAWinningRun() {
        let trades = [closedAt("A", exit: 90, at: 100),    // −1R
                      closedAt("B", exit: 120, at: 200),   // +2R
                      closedAt("C", exit: 110, at: 300)]   // +1R
        let s = StockSageJournal.streak(trades)!
        #expect(s.streakCount == 2 && s.streakIsWin == true)   // B, C trailing wins
        #expect(StockSageJournal.streak([]) == nil)
    }

    @Test func bySectorGroupsAndSortsByTotalR() {
        let trades = [
            tSym("AAPL", .long, entry: 100, stop: 90, shares: 1, exit: 120),  // Tech +2R win
            tSym("AAPL", .long, entry: 100, stop: 90, shares: 1, exit: 90),   // Tech −1R loss
            tSym("JPM", .long, entry: 100, stop: 90, shares: 1, exit: 130),   // Financials +3R win
            tSym("MSFT", .long, entry: 100, stop: 90, shares: 1),             // Tech, open → excluded
        ]
        let s = StockSageJournal.bySector(trades)
        #expect(s.count == 2)
        #expect(s.first?.sector == "Financials")        // totalR 3 > 1 → first
        #expect(s.first?.totalR == 3 && s.first?.trades == 1 && s.first?.wins == 1)
        let tech = s.first { $0.sector == "Technology" }!
        #expect(tech.trades == 2 && tech.wins == 1)
        #expect(abs(tech.totalR - 1.0) < 1e-9)          // +2 −1
        #expect(abs(tech.winRate - 0.5) < 1e-9)
        #expect(StockSageJournal.bySector([]).isEmpty)
    }

    @Test func profitFactorIsGrossWinOverGrossLoss() {
        let trades = [
            t(.long, entry: 100, stop: 90, shares: 1, exit: 120),   // +2R
            t(.long, entry: 100, stop: 90, shares: 1, exit: 110),   // +1R
            t(.long, entry: 100, stop: 90, shares: 1, exit: 90),    // −1R
        ]
        #expect(abs(StockSageJournal.edge(trades).profitFactor! - 3.0) < 1e-9)   // (2+1)/1
        // No losses yet → nil (not Inf).
        #expect(StockSageJournal.edge([t(.long, entry: 100, stop: 90, shares: 1, exit: 120)]).profitFactor == nil)
    }

    @Test func edgeWithNoLossesHasZeroPayoffNotInfinity() {
        let onlyWins = [t(.long, entry: 100, stop: 90, shares: 1, exit: 120)]
        let e = StockSageJournal.edge(onlyWins)
        #expect(e.payoffRatio == 0)        // guarded, not inf/NaN
        #expect(StockSageJournal.edge([]).closedWithR == 0)
    }

    @Test func statsOverClosedTradesOnly() {
        let trades = [
            t(.long, entry: 100, stop: 90, shares: 1, exit: 120),   // +2R win
            t(.long, entry: 100, stop: 90, shares: 1, exit: 90),    // −1R loss
            t(.long, entry: 100, stop: 90, shares: 1),              // open → excluded
        ]
        let s = StockSageJournal.stats(trades)
        #expect(s.closed == 2)
        #expect(s.wins == 1)
        #expect(s.winRate == 0.5)
        #expect(s.totalR == 1.0)        // +2 −1
        #expect(s.avgR == 0.5)
        #expect(StockSageJournal.stats([]).closed == 0)
    }

    // First-real-trade review (2026-07-16): totalProfit sums each closed trade's profit in its
    // NATIVE currency, so it's only a valid single figure when the book is one currency. stats()
    // now reports profitCurrency (single ISO code, else nil=mixed) + profitSymbol (representative,
    // for pence normalization). Expected values HAND-DERIVED: profit(at:) = (exit-entry)*shares
    // for a long; conversionCurrencyForSymbol: no-dot → USD, .SR → SAR, .L → GBP (pence, ÷100).
    @Test func statsProfitCurrencyIsSingleCodeOrNilWhenMixed() {
        // All-USD closed book: single currency "USD", representative symbol carried.
        let usd = StockSageJournal.stats([tSym("AAPL", .long, entry: 100, stop: 90, shares: 1, exit: 150)])
        #expect(usd.totalProfit == 50)            // (150-100)*1
        #expect(usd.profitCurrency == "USD")
        #expect(usd.profitSymbol == "AAPL")

        // All-.SR: single currency "SAR".
        let sar = StockSageJournal.stats([tSym("2222.SR", .long, entry: 100, stop: 90, shares: 1, exit: 130)])
        #expect(sar.totalProfit == 30)
        #expect(sar.profitCurrency == "SAR")
        #expect(sar.profitSymbol == "2222.SR")

        // All-.L (pence): currency "GBP"; totalProfit is RAW pence (display ÷100 via signedAmount).
        let gbp = StockSageJournal.stats([tSym("SHEL.L", .long, entry: 500, stop: 400, shares: 1, exit: 900)])
        #expect(gbp.totalProfit == 400)           // 400 pence raw
        #expect(gbp.profitCurrency == "GBP")
        #expect(gbp.profitSymbol == "SHEL.L")

        // Mixed USD + SAR: raw sum still computed (80) but profitCurrency/Symbol are nil — the
        // display must refuse to present the meaningless 1:1 sum as one number.
        let mixed = StockSageJournal.stats([
            tSym("AAPL", .long, entry: 100, stop: 90, shares: 1, exit: 150),      // +50 USD
            tSym("2222.SR", .long, entry: 100, stop: 90, shares: 1, exit: 130),   // +30 SAR
        ])
        #expect(mixed.totalProfit == 80)
        #expect(mixed.profitCurrency == nil)
        #expect(mixed.profitSymbol == nil)

        // Empty closed set: nil (no currency to name).
        #expect(StockSageJournal.stats([]).profitCurrency == nil)
        #expect(StockSageJournal.stats([]).profitSymbol == nil)
    }

    // The signedAmount rendering the display uses over totalProfit: pence normalizes, SAR labels,
    // USD stays bare. (Guards that the .L raw-pence total is not shown ~100× over.)
    @Test func realizedProfitRendersInBookCurrencyWithPenceNormalized() {
        #expect(StockSageCurrency.signedAmount(50, symbol: "AAPL") == "+50.00")
        #expect(StockSageCurrency.signedAmount(30, symbol: "2222.SR") == "+30.00 SAR")
        #expect(StockSageCurrency.signedAmount(400, symbol: "SHEL.L") == "+4.00 GBP")   // pence ÷100
    }

    // First-real-trade review cycle-1 (2026-07-16): the close-form P&L preview pins the exact
    // number the owner sees before confirming a close. HAND-DERIVED: long 2222.SR, entry 30.00,
    // stop 28.00 (riskPerShare 2.00), 100 shares, exit 33.00 → profit (33-30)*100 = +300 SAR;
    // R = (33-30)/2.00 = +1.50; signedAmount(300,"2222.SR") = "+300.00 SAR". The rendered preview
    // string ("Closing here: +300.00 SAR · +1.50R") is asserted piecewise (the same pieces the
    // view interpolates) so a currency- or R-math regression fails here, not in pixels.
    @Test func closeFormPreviewShowsCurrencyCorrectPnLAndR() {
        let t = TradeRecord(symbol: "2222.SR", side: .long, entry: 30, stop: 28, target: nil,
                            shares: 100, openedAt: Date(timeIntervalSince1970: 0))
        #expect(t.profit(at: 33) == 300)                               // (33-30)*100 SAR
        #expect(abs(t.rMultiple(at: 33)! - 1.5) < 1e-9)                // (33-30)/2.00
        #expect(StockSageCurrency.signedAmount(t.profit(at: 33), symbol: t.symbol) == "+300.00 SAR")
        // A losing exit colors/labels negative and keeps the currency.
        #expect(StockSageCurrency.signedAmount(t.profit(at: 27), symbol: t.symbol) == "-300.00 SAR")
        #expect(abs(t.rMultiple(at: 27)! + 1.5) < 1e-9)               // (27-30)/2.00 = -1.5
    }

    @Test func streakSingleWinTradeIsStreakOfOne() {
        let single = [TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                                 openedAt: Date(timeIntervalSince1970: 0),
                                 exitPrice: 120, closedAt: Date(timeIntervalSince1970: 100))]
        let s = StockSageJournal.streak(single)!
        #expect(s.streakCount == 1)
        #expect(s.streakIsWin == true)
        #expect(abs(s.bestR - 2.0) < 1e-9 && s.bestSymbol == "AAPL")
    }

    @Test func streakNoStreakWhenAllBreakeven() {
        let breakeven = (0..<3).map { i in
            TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                        openedAt: Date(timeIntervalSince1970: Double(i) * 100),
                        exitPrice: 100, closedAt: Date(timeIntervalSince1970: Double(i) * 100 + 50))
        }
        let s = StockSageJournal.streak(breakeven)!
        #expect(s.streakCount == 0)
    }

    @Test func equityRiskAllWinnersZeroDrawdown() {
        let winners = [1.5, 2.0, 1.0].enumerated().map { i, r in
            TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                        openedAt: Date(timeIntervalSince1970: Double(i) * 100),
                        exitPrice: 100 + r * 10, closedAt: Date(timeIntervalSince1970: Double(i) * 100 + 50))
        }
        let risk = StockSageJournal.equityRisk(winners)!
        #expect(risk.maxConsecutiveLosses == 0)
        #expect(abs(risk.maxDrawdownR) < 1e-9)
    }

    @Test func expectancyTrendDeltaAtBandExactlyIsFlat() {
        let flat = (0..<6).map { i -> TradeRecord in
            let r = i < 3 ? 0.0 : 0.3
            return TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                              openedAt: Date(timeIntervalSince1970: Double(i) * 100),
                              exitPrice: 100 + r * 10, closedAt: Date(timeIntervalSince1970: Double(i) * 100 + 50))
        }
        let t = StockSageJournal.expectancyTrend(flat, band: 0.3)!
        #expect(t.direction == .flat)
    }

    @Test func classifyHealthPFBoundaryIsInclusive() {
        let atBound = StockSageJournal.classifyHealth(profitFactor: 1.5, expectancyR: 0.5, significant: true,
                                                      n: 30, maxDrawdownR: 3.0, minTrades: 20, deepDrawdownR: 8.0)
        #expect(atBound.verdict == .strong)
        let justBelow = StockSageJournal.classifyHealth(profitFactor: 1.49, expectancyR: 0.5, significant: true,
                                                        n: 30, maxDrawdownR: 3.0, minTrades: 20, deepDrawdownR: 8.0)
        #expect(justBelow.verdict == .developing)
    }

    // MARK: - history(for:in:) — "your history with this name" (2026-07-07, gap #2)
    //
    // Hand-derived (swift /tmp/derive_journal.swift, NOT calling this code — spec-fidelity rule):
    //   2 closed AAPL trades, realizedR +0.8 and −0.3 → count=2, totalR = 0.8 + (−0.3) = 0.5 exactly.

    @Test func historyAggregatesCountAndTotalR() {
        let trades = [
            tSym("AAPL", .long, entry: 190, stop: 185, shares: 10, exit: 194),     // R = +0.8
            tSym("AAPL", .long, entry: 190, stop: 185, shares: 10, exit: 188.5),   // R = −0.3
        ]
        let h = StockSageJournal.history(for: "AAPL", in: trades)!
        #expect(h.count == 2)
        #expect(abs(h.totalR - 0.5) < 1e-9)   // hand-derived above
        #expect(h.rDefinedCount == 2)         // both trades have a defined R
    }

    @Test func historyExcludesOpenTrades() {
        let open = TradeRecord(symbol: "AAPL", side: .long, entry: 190, stop: 185, target: nil,
                               shares: 10, openedAt: Date(timeIntervalSince1970: 0))
        let closed = tSym("AAPL", .long, entry: 190, stop: 185, shares: 10, exit: 194)   // R = +0.8
        let h = StockSageJournal.history(for: "AAPL", in: [open, closed])!
        #expect(h.count == 1)                  // only the closed one counts
        #expect(abs(h.totalR - 0.8) < 1e-9)
    }

    // L6 (honesty-labels fleet, 2026-07-07): count must include closed trades with an UNDEFINED
    // R (no exit price recorded) — the old compactMap(realizedR) implementation silently dropped
    // them from the count, not just from totalR.
    //
    // Hand-derived (swift /tmp/derive_journal.swift, NOT calling this code):
    //   3 closed AAPL trades: two with realizedR +0.8/−0.3 (sum 0.5, same fixtures as above),
    //   one closed WITHOUT an exit price (realizedR nil) → count=3, rDefinedCount=2, totalR=0.5.
    @Test func historyCountsClosedTradesWithUndefinedR() {
        let withR1 = tSym("AAPL", .long, entry: 190, stop: 185, shares: 10, exit: 194)     // R = +0.8
        let withR2 = tSym("AAPL", .long, entry: 190, stop: 185, shares: 10, exit: 188.5)   // R = −0.3
        // Closed (closedAt set) but no exit price recorded → realizedR is nil (undefined R).
        let undefinedR = TradeRecord(symbol: "AAPL", side: .long, entry: 190, stop: 185, target: nil,
                                      shares: 10, openedAt: Date(timeIntervalSince1970: 0),
                                      exitPrice: nil, closedAt: Date(timeIntervalSince1970: 100))
        let h = StockSageJournal.history(for: "AAPL", in: [withR1, withR2, undefinedR])!
        #expect(h.count == 3)                  // all three closed trades count
        #expect(h.rDefinedCount == 2)          // only two contributed a realized R
        #expect(abs(h.totalR - 0.5) < 1e-9)    // totalR sums only the defined-R subset
    }

    @Test func historyIsNilOnZeroClosedTrades() {
        #expect(StockSageJournal.history(for: "AAPL", in: []) == nil)
        let onlyOpen = TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 90, target: nil,
                                   shares: 1, openedAt: Date(timeIntervalSince1970: 0))
        #expect(StockSageJournal.history(for: "AAPL", in: [onlyOpen]) == nil)
        // Closed trades exist but for a DIFFERENT symbol.
        let msft = tSym("MSFT", .long, entry: 100, stop: 90, shares: 1, exit: 110)
        #expect(StockSageJournal.history(for: "AAPL", in: [msft]) == nil)
    }

    @Test func historyIsCaseInsensitive() {
        let trades = [tSym("AAPL", .long, entry: 190, stop: 185, shares: 10, exit: 194)]
        #expect(StockSageJournal.history(for: "aapl", in: trades)?.count == 1)
        #expect(StockSageJournal.history(for: "AaPl", in: trades)?.count == 1)
    }

    // PERF-2: historyBySymbol is a batch convenience for the ideas board (one O(T) pass instead
    // of O(T) per card); history(for:in:) stays the semantic source of truth. This proves the
    // dict agrees with the per-symbol function for every symbol present, including a symbol with
    // only open trades (must be ABSENT from the dict, matching history(for:in:) returning nil).
    @Test func historyBySymbolMatchesHistoryForEverySymbol() {
        let open = TradeRecord(symbol: "TSLA", side: .long, entry: 200, stop: 190, target: nil,
                               shares: 5, openedAt: Date(timeIntervalSince1970: 0))
        let trades = [
            tSym("AAPL", .long, entry: 190, stop: 185, shares: 10, exit: 194),     // R = +0.8
            tSym("AAPL", .long, entry: 190, stop: 185, shares: 10, exit: 188.5),   // R = −0.3
            tSym("MSFT", .long, entry: 100, stop: 90, shares: 1, exit: 110),
            open,
        ]
        let dict = StockSageJournal.historyBySymbol(in: trades)
        for sym in ["AAPL", "MSFT", "TSLA"] {
            let expected = StockSageJournal.history(for: sym, in: trades)
            let actual = dict[sym]
            #expect(actual?.count == expected?.count)
            #expect(actual == nil ? expected == nil : abs((actual!.totalR) - (expected!.totalR)) < 1e-9)
            #expect(actual?.rDefinedCount == expected?.rDefinedCount)
        }
        // TSLA has only an open trade → nil from history(for:in:) → absent from the dict.
        #expect(dict["TSLA"] == nil)
        #expect(dict.count == 2)   // AAPL + MSFT only
    }
}

/// Pins `StockSageJournalStore.qaSeed` — the QA in-memory REPLACE seam (money-critical: keeps
/// StockSageConvictionCalibration.fit(fromJournal:)'s minSamples=30 floor un-crossed during a
/// capture window). Runs against the shared singleton (no injectable-UserDefaults init exists
/// on this store, unlike StockSagePortfolio) and restores real state via defer — same
/// save→restore-exact shape QASnapshots.seedQAJournal itself uses.
@MainActor
struct StockSageJournalStoreQASeedTests {

    @Test func qaSeedReplacesInMemoryWithoutTouchingUserDefaults() {
        let store = StockSageJournalStore.shared
        let saved = store.trades
        let key = "stocksage.journal.v1"
        let beforeBytes = UserDefaults.standard.data(forKey: key)
        defer { store.qaSeed(saved) }

        let fake = [
            TradeRecord(symbol: "AAPL", side: .long, entry: 190, stop: 185, target: 200, shares: 10,
                       openedAt: Date(timeIntervalSince1970: 0), exitPrice: 194,
                       closedAt: Date(timeIntervalSince1970: 100)),
            TradeRecord(symbol: "AAPL", side: .long, entry: 190, stop: 185, target: 200, shares: 10,
                       openedAt: Date(timeIntervalSince1970: 200), exitPrice: 188.5,
                       closedAt: Date(timeIntervalSince1970: 300)),
        ]
        store.qaSeed(fake)

        // REPLACE semantics: trades is now EXACTLY the fake list, not the real list + fake.
        #expect(store.trades.count == 2)
        #expect(store.trades == fake)

        // Persistence-negative: UserDefaults bytes are byte-identical to before qaSeed ran —
        // qaSeed never calls save(). (Equivalent to StockSagePortfolioTests' "fresh instance
        // sees original" proof; StockSageJournalStore has no injectable init to construct a
        // fresh instance against the same suite, so this checks the persisted bytes directly.)
        let afterBytes = UserDefaults.standard.data(forKey: key)
        #expect(afterBytes == beforeBytes)
    }

    @Test func qaSeedRestoreRecoversExactOriginalTrades() {
        let store = StockSageJournalStore.shared
        let saved = store.trades
        store.qaSeed([tSymTopLevel("AAPL", .long, entry: 100, stop: 90, shares: 1, exit: 110)])
        #expect(store.trades.count == 1)
        store.qaSeed(saved)   // restore, exact — mirrors QASnapshots.seedQAJournal's returned closure
        #expect(store.trades == saved)
    }

    // 2-trade fake set stays under fit(fromJournal:)'s minSamples=30 floor
    // (StockSageConvictionCalibration.swift:99: `outcomes.count >= minSamples`) — the money-
    // critical property the QASnapshots seed depends on. Proven directly on the fit, not by
    // trusting the count.
    @Test func twoFakeTradesStayUnderCalibrationMinSamplesFloor() {
        let fake = [
            TradeRecord(symbol: "AAPL", side: .long, entry: 190, stop: 185, target: 200, shares: 10,
                       openedAt: Date(timeIntervalSince1970: 0), exitPrice: 194,
                       closedAt: Date(timeIntervalSince1970: 100), conviction: 0.6),
            TradeRecord(symbol: "AAPL", side: .long, entry: 190, stop: 185, target: 200, shares: 10,
                       openedAt: Date(timeIntervalSince1970: 200), exitPrice: 188.5,
                       closedAt: Date(timeIntervalSince1970: 300), conviction: 0.6),
        ]
        #expect(StockSageConvictionCalibration.fit(fromJournal: fake) == nil)
    }

    private func tSymTopLevel(_ symbol: String, _ side: TradeRecord.Side, entry: Double, stop: Double,
                              shares: Double, exit: Double? = nil) -> TradeRecord {
        TradeRecord(symbol: symbol, side: side, entry: entry, stop: stop, target: nil,
                    shares: shares, openedAt: Date(timeIntervalSince1970: 0),
                    exitPrice: exit, closedAt: exit == nil ? nil : Date(timeIntervalSince1970: 100))
    }

    // MARK: JournalStore save() cross-process reconciliation (2026-07-09 — the paper store's
    // LIVE-evidenced lost-update defect, fixed in the same class here because this journal
    // feeds calibration/brake/analytics with REAL outcomes: a clobbered close silently
    // distorts win-prob. Two stores on ONE suite simulate two app instances.)

    private func isolatedJournal() -> (a: StockSageJournalStore, defaults: UserDefaults, suite: String) {
        let suite = "journal.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (StockSageJournalStore(defaults: defaults, key: "stocksage.journal.v1"), defaults, suite)
    }

    private func journalTrade(_ symbol: String, day: Int) -> TradeRecord {
        TradeRecord(symbol: symbol, side: .long, entry: 100, stop: 90, target: 120, shares: 1,
                    openedAt: Date(timeIntervalSince1970: Double(day) * 86_400))
    }

    @Test func journalStaleProcessSaveCannotResurrectAClosedTrade() {
        let (a, defaults, suite) = isolatedJournal()
        defer { defaults.removePersistentDomain(forName: suite) }
        let t = journalTrade("AAA", day: 0)
        a.add(t)
        let b = StockSageJournalStore(defaults: defaults, key: "stocksage.journal.v1")
        #expect(b.trades.first?.isOpen == true)
        a.close(t.id, exitPrice: 118, at: Date(timeIntervalSince1970: 5 * 86_400))
        b.add(journalTrade("BBB", day: 1))   // stale process writes
        let final = StockSageJournalStore(defaults: defaults, key: "stocksage.journal.v1")
        let aaa = final.trades.first { $0.symbol == "AAA" }
        #expect(aaa?.isOpen == false)
        #expect(aaa?.exitPrice == 118)
        #expect(final.trades.contains { $0.symbol == "BBB" })
    }

    @Test func journalForeignAddsSurviveAStaleSave() {
        let (a, defaults, suite) = isolatedJournal()
        defer { defaults.removePersistentDomain(forName: suite) }
        let b = StockSageJournalStore(defaults: defaults, key: "stocksage.journal.v1")   // loads empty
        a.add(journalTrade("AAA", day: 0))
        b.add(journalTrade("BBB", day: 1))
        let final = StockSageJournalStore(defaults: defaults, key: "stocksage.journal.v1")
        #expect(Set(final.trades.map(\.symbol)) == ["AAA", "BBB"])
    }

    @Test func journalRemoveStillDeletesDespiteTheReconcilingSave() {
        let (a, defaults, suite) = isolatedJournal()
        defer { defaults.removePersistentDomain(forName: suite) }
        let t = journalTrade("AAA", day: 0)
        a.add(t)
        a.remove(t.id)
        #expect(StockSageJournalStore(defaults: defaults, key: "stocksage.journal.v1").trades.isEmpty)
    }
}
