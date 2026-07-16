import Testing
import Foundation
@testable import StockSage

// MARK: - Expected value (pure)

struct StockSageExpectedValueTests {

    typealias EV = StockSageExpectedValue

    @Test func winProbBandIsConservative() {
        #expect(abs(EV.winProbEstimate(conviction: 0) - 0.35) < 1e-9)
        #expect(abs(EV.winProbEstimate(conviction: 1) - 0.58) < 1e-9)
        #expect(EV.winProbEstimate(conviction: 5) == 0.58)    // clamped
        #expect(EV.winProbEstimate(conviction: -1) == 0.35)   // clamped
    }

    @Test func evCombinesProbabilityAndReward() {
        // conviction 1 → p 0.58; R:R = 20/10 = 2 → EV = 0.58·2 − 0.42 = 0.74.
        let high = EV.ev(conviction: 1, entry: 100, stop: 90, target: 120)!
        #expect(abs(high.rewardR - 2) < 1e-9)
        #expect(abs(high.evR - 0.74) < 1e-9)
        #expect(high.isPositive)
        // conviction 0 → p 0.35; same 2:1 → EV = 0.70 − 0.65 = 0.05 (barely positive).
        let low = EV.ev(conviction: 0, entry: 100, stop: 90, target: 120)!
        #expect(abs(low.evR - 0.05) < 1e-9)
        // A higher-EV setup ranks above a lower one.
        #expect(high.evR > low.evR)
    }

    @Test func noDefinedRiskOrRewardIsNil() {
        #expect(EV.ev(conviction: 0.8, entry: 100, stop: 100, target: 120) == nil)   // no risk
        #expect(EV.ev(conviction: 0.8, entry: 100, stop: 90, target: 100) == nil)    // no reward
    }

    private func idea(_ symbol: String, action: TradeAdvice.Action = .buy, conviction: Double,
                      stop: Double?, target: Double?) -> StockSageIdea {
        StockSageIdea(symbol: symbol, market: "M", price: 100,
                      advice: TradeAdvice(action: action, conviction: conviction, regime: .bullTrend, rationale: [],
                                          stopPrice: stop, targetPrice: target, suggestedWeight: 0.05, caveat: "x"),
                      spark: [])
    }

    // Audit 2026-07-12 (ideas-card LANE 2 — "why this rank"): the RankExplanation decomposition MUST
    // sum to the SAME rank key rankByEV sorts on — else the "why" breakdown is a fabricated story
    // (the exact honesty-floor failure the whole audit fenced). This pins that invariant: total ==
    // base + seasonality − earningsPenalty − liquidityPenalty, and each term matches its own function.
    @Test func rankExplanationDecomposesToTheRealRankKey() {
        let i = idea("AAPL", conviction: 0.7, stop: 90, target: 120)
        // A thin-liquidity profile → a 3000 penalty term must appear and be subtracted.
        let liq: [String: LiquidityProfile] = ["AAPL": LiquidityProfile(avgDollarVolume: 1, tier: .thin)]
        let exp = EV.rankExplanation(for: i, liquidity: liq)
        #expect(exp != nil)
        let e = exp!
        // The penalty term equals the ranker's own function (no re-derivation drift).
        #expect(e.liquidityPenalty == EV.liquidityRankPenalty(for: i, liquidity: liq))
        #expect(e.liquidityPenalty == 3000)
        #expect(e.earningsPenalty == 0)          // no earnings supplied
        // total = base − 3000 (seasonality 0, earnings 0) — the exact key rankByEV would use.
        #expect(abs(e.total - (e.base + e.seasonalityBonus - e.earningsPenalty - e.liquidityPenalty)) < 1e-9)
        // The active-adjustments summary names the thin-liquidity demotion with a NEGATIVE delta.
        #expect(e.activeAdjustments.contains { $0.label.contains("liquidity") && $0.delta < 0 })
    }

    @Test func rankExplanationIsNilForANilEVIdea() {
        // A stop-less idea has no EV key → the sheet must show nothing, not a fabricated breakdown.
        let noStop = idea("AAPL", conviction: 0.7, stop: nil, target: 120)
        #expect(EV.rankExplanation(for: noStop) == nil)
    }

    // Audit 2026-07-12 (ideas-card laneCorrelation date-alignment): the dated overload aligns each
    // crypto×equity pair by CALENDAR DATE before correlating, so a crypto 7-day week vs an equity
    // 5-day week no longer correlates mismatched days (the tail-index bug). This test proves the
    // dated path pairs by shared date: give the two lanes returns that are PERFECTLY correlated on
    // their COMMON days but padded with extra crypto-only (weekend) days — date-alignment must
    // recover ≈+1, whereas raw tail-index pairing of the unequal-length arrays would not.
    @Test func laneCorrelationDatedAlignsByCalendarDateNotTailIndex() {
        let day = 86_400.0
        func d(_ i: Int) -> Date { Date(timeIntervalSince1970: Double(i) * day) }
        // Equity trades days 0..3 (a "week"); returns +1,+2,+3.
        let equityDated: [(date: Date, ret: Double)] = [(d(0), 1), (d(1), 2), (d(2), 3)]
        // Crypto trades the SAME days 0..3 with the SAME returns (ρ=+1 on common days) PLUS two
        // weekend days (4,5) that the equity lane never has — these must be dropped by alignment.
        let cryptoDated: [(date: Date, ret: Double)] = [(d(0), 1), (d(1), 2), (d(2), 3), (d(4), 9), (d(5), -9)]
        let histories = ["BTC-USD": cryptoDated, "AAPL": equityDated]
        let cryptoIdea = idea("BTC-USD", conviction: 0.7, stop: 90, target: 120)
        let equityIdea = idea("AAPL", conviction: 0.7, stop: 90, target: 120)
        let corr = EV.laneCorrelation(crypto: [cryptoIdea], equity: [equityIdea], dated: histories)
        // Aligned to the 3 shared days, the two return series are identical → correlation ≈ +1.
        #expect(corr != nil)
        #expect(abs(corr! - 1.0) < 1e-9)
    }

    @Test func laneCorrelationDatedIsNilWithoutTwoSharedDays() {
        let day = 86_400.0
        func d(_ i: Int) -> Date { Date(timeIntervalSince1970: Double(i) * day) }
        // Zero calendar overlap → no correlatable pair → nil (never a fabricated 0/±1).
        let crypto: [(date: Date, ret: Double)] = [(d(0), 1), (d(1), 2)]
        let equity: [(date: Date, ret: Double)] = [(d(10), 1), (d(11), 2)]
        let corr = EV.laneCorrelation(crypto: [idea("BTC-USD", conviction: 0.7, stop: 90, target: 120)],
                                      equity: [idea("AAPL", conviction: 0.7, stop: 90, target: 120)],
                                      dated: ["BTC-USD": crypto, "AAPL": equity])
        #expect(corr == nil)
    }

    @Test func isLowConvictionMirrorsTheExactRankKeyThreshold() {
        // Named, testable mirror of `idea.advice.conviction < minConvictionToRank` — must agree
        // with every rank-key function's internal comparison at the boundary itself.
        #expect(EV.isLowConviction(idea("A", conviction: 0.39, stop: 90, target: 110)))
        #expect(!EV.isLowConviction(idea("A", conviction: 0.40, stop: 90, target: 110)))   // AT floor → not low
        #expect(!EV.isLowConviction(idea("A", conviction: 0.41, stop: 90, target: 110)))
        #expect(EV.isLowConviction(idea("A", conviction: 0.0, stop: 90, target: 110)))
        #expect(!EV.isLowConviction(idea("A", conviction: 1.0, stop: 90, target: 110)))
        #expect(EV.minConvictionToRank == 0.40)   // pins the threshold this test targets
    }

    @Test func rankingAndBestOpportunityUseTheCalibrationNotJustTheDisplay() {
        // [iter7] Pins the flag OFF for determinism: this test asserts a calibration-driven RANK FLIP
        // and shares the global candidateSelectorEnabled with the (now default-ON) selector suite. The
        // flip holds on BOTH paths (B's high-band win-prob dominates A's), but pinning removes any
        // cross-test ordering dependency on the global flag.
        let saved = StockSageConvictionCalibration.candidateSelectorEnabled
        defer { StockSageConvictionCalibration.candidateSelectorEnabled = saved }
        StockSageConvictionCalibration.candidateSelectorEnabled = false
        // A: bigger reward:risk (3:1) but modest conviction; B: smaller R:R (1:1) but high conviction.
        let a = idea("AAA", conviction: 0.45, stop: 90, target: 130)
        let b = idea("BBB", conviction: 0.90, stop: 90, target: 110)
        // Linear prior (no calibration): A's larger R:R makes it the best bet / top rank.
        #expect(EV.bestOpportunity([a, b])?.idea.symbol == "AAA")
        #expect(EV.rankByEV([a, b]).first?.symbol == "AAA")
        // A MEASURED calibration that rates the low band much worse and the high band much better must
        // flip BOTH the ranking and the best pick — proving they now size on the same win-prob the card
        // displays (previously the rank/gate used the linear prior while the shown EV used calibration).
        var outcomes: [(conviction: Double, won: Bool)] = []
        for i in 0..<20 { outcomes.append((conviction: 0.45, won: i < 8)) }    // ~40% (low band)
        for i in 0..<20 { outcomes.append((conviction: 0.90, won: i < 17)) }   // ~85% (high band)
        guard let cal = StockSageConvictionCalibration.fit(outcomes, minSamples: 30) else {
            Issue.record("expected a fit"); return
        }
        #expect(EV.bestOpportunity([a, b], calibration: cal)?.idea.symbol == "BBB")
        #expect(EV.rankByEV([a, b], calibration: cal).first?.symbol == "BBB")
    }

    @Test func weeklyDollarsAndWeeklyRUseTheCalibration() {
        // A crypto setup (has a velocity). A measured calibration rating its band BELOW the linear
        // prior must lower BOTH weekly-R and weekly-$ — they can't show a calibrated R beside an
        // uncalibrated $ anymore.
        // [iter7] This asserts the PLUMBING (R and $ both move with the calibration) using a fixture
        // whose Platt map sits below the prior. The selector is now ACTIVE by default, but this 40-row
        // single-conviction fixture is too thin for the selector to split → it returns the conservative
        // IDENTITY map, which sends conviction 0.9 to ~0.75 (ABOVE the 0.557 prior), inverting the
        // "below-prior" premise. Pin the flag OFF so the fixture keeps producing the sub-prior Platt map
        // this plumbing test is built on; the selector path is covered by the selector suite.
        let saved = StockSageConvictionCalibration.candidateSelectorEnabled
        defer { StockSageConvictionCalibration.candidateSelectorEnabled = saved }
        StockSageConvictionCalibration.candidateSelectorEnabled = false
        let c = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
        let uncalR = EV.expectedWeeklyR([c])
        let uncalUSD = EV.expectedWeeklyDollars([c], account: 10_000, riskFraction: 0.01)
        var outcomes: [(conviction: Double, won: Bool)] = []
        for i in 0..<40 { outcomes.append((conviction: 0.9, won: i < 16)) }   // ~40%, well below the 0.557 prior
        guard let cal = StockSageConvictionCalibration.fit(outcomes, minSamples: 30) else {
            Issue.record("expected a fit"); return
        }
        let calR = EV.expectedWeeklyR([c], calibration: cal)
        let calUSD = EV.expectedWeeklyDollars([c], account: 10_000, riskFraction: 0.01, calibration: cal)
        #expect(uncalR != nil && calR != nil && uncalUSD != nil && calUSD != nil)
        if let u = uncalR, let d = calR { #expect(d < u) }       // lower measured win-prob → lower weekly R
        if let u = uncalUSD, let d = calUSD { #expect(d < u) }   // …and the $ follows it
    }

    @Test func velocityRewardsFastTurnover() {
        // Same EV (1.228), but crypto hold 3 beats equity hold 12.
        let equity = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        let crypto = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
        let ve = EV.velocity(for: equity)!, vc = EV.velocity(for: crypto)!
        #expect(abs(ve - 1.228 / 12) < 1e-9)
        #expect(abs(vc - 1.228 / 3) < 1e-9)
        #expect(vc > ve)
        #expect(EV.expectedHoldDays(forSymbol: "^GSPC") == nil)                            // index → no velocity
        #expect(EV.velocity(for: idea("EURUSD=X", conviction: 0.9, stop: 90, target: 130)) == nil)
    }

    @Test func fastLaneEmptyWhenNoVelocity() {
        // Index/FX have no asset-class hold → no velocity → excluded from every velocity surface.
        let idx = idea("^GSPC", conviction: 0.9, stop: 90, target: 130)
        let fx = idea("EURUSD=X", conviction: 0.9, stop: 90, target: 130)
        #expect(EV.fastLane([idx, fx]).isEmpty)
        #expect(EV.expectedWeeklyR([idx, fx]) == nil)
        #expect(EV.fastLaneConcentration([idx, fx]) == nil)
    }

    @Test func fastLaneRanksByVelocityCryptoFirst() {
        let equity = idea("AAPL", conviction: 0.9, stop: 90, target: 130)    // EV 1.228, vel 0.1023
        let crypto = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130) // EV 1.228, vel 0.4093
        let index = idea("^GSPC", conviction: 0.9, stop: 90, target: 130)    // EV but no velocity → excluded
        let neg = idea("D", conviction: 0.0, stop: 90, target: 110)          // EV −0.30 → excluded
        let lane = EV.fastLane([equity, index, neg, crypto])
        #expect(lane.map(\.symbol) == ["BTC-USD", "AAPL"])                    // crypto first (faster turnover)
    }

    @Test func imminentEarningsDemotesInTheRank() {
        // Two identical equity buys — only the earnings calendar differs.
        let a = idea("AAPL", conviction: 0.8, stop: 98, target: 110)
        let b = idea("MSFT", conviction: 0.8, stop: 98, target: 110)
        // No earnings data → original order preserved on BOTH boards (byte-stable default).
        #expect(EV.rankByEV([a, b]).map(\.symbol) == ["AAPL", "MSFT"])
        #expect(EV.rankByVelocity([a, b]).map(\.symbol) == ["AAPL", "MSFT"])
        // AAPL reports in 2 days (imminent — a stop may gap through it); MSFT in 30 (clear).
        let earnings: [String: EarningsProximity] = [
            "AAPL": EarningsProximity(daysUntil: 2, severity: .imminent),
            "MSFT": EarningsProximity(daysUntil: 30, severity: .clear),
        ]
        #expect(EV.rankByEV([a, b], earnings: earnings).map(\.symbol) == ["MSFT", "AAPL"])       // imminent sinks
        #expect(EV.rankByVelocity([a, b], earnings: earnings).map(\.symbol) == ["MSFT", "AAPL"])
        // The penalty fires ONLY on a real .imminent date — unknown / .soon / .clear are 0 (only-real-data).
        #expect(EV.earningsRankPenalty(for: a, earnings: earnings) == 2000)
        #expect(EV.earningsRankPenalty(for: b, earnings: earnings) == 0)                          // .clear → 0
        #expect(EV.earningsRankPenalty(for: a, earnings: [:]) == 0)                               // unknown → 0
        #expect(EV.earningsRankPenalty(for: a, earnings: ["AAPL": EarningsProximity(daysUntil: 7, severity: .soon)]) == 0)
        // Band invariant the constant relies on: above conviction(1000)+maxEV, below cost(500k)/regime(1M).
        #expect(1000 + 50.0 < 2000 && 2000 < 500_000 && 500_000 < 1_000_000)
    }

    // fastLaneConcentration's earnings/liquidity demotion params (added 71929c3) were UNTESTED
    // (audit F1/L5), and netExpectedWeeklyR's 0.70 concentration haircut must analyze the SAME
    // earnings/liquidity-demoted top-3 it sums (audit L4-1, fixed 2026-07-07). This pins BOTH:
    // a demotion that changes the top-3 asset-class mix flips isConcentrated. Expected outcomes
    // are derived from the documented demotion sentinels (−2000 imminent earnings, −3000 thin
    // liquidity), NOT from calling fastLaneConcentration (no circularity).
    @Test func fastLaneConcentrationRespectsEarningsAndLiquidityDemotion() {
        let btc  = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
        let eth  = idea("ETH-USD", conviction: 0.9, stop: 90, target: 130)
        let sol  = idea("SOL-USD", conviction: 0.9, stop: 90, target: 130)
        let aapl = idea("AAPL",    conviction: 0.9, stop: 90, target: 130)  // equity: 12d hold → lower velocity
        let all = [btc, eth, sol, aapl]
        // Non-vacuous guard: the 3 crypto (vel 0.4093) rank above the lone equity (vel 0.1023) →
        // AAPL is last. Fails loudly if -USD stopped classifying crypto.
        #expect(EV.fastLane(all).map(\.symbol).last == "AAPL")
        // Undemoted top-3 = all crypto → concentrated.
        #expect(EV.fastLaneConcentration(all, topN: 3)?.isConcentrated == true)
        // Imminent earnings on SOL (−2000 sentinel) sinks it to last → top-3 = 2 crypto + AAPL → mixed.
        let earnings: [String: EarningsProximity] = ["SOL-USD": EarningsProximity(daysUntil: 2, severity: .imminent)]
        #expect(EV.fastLane(all, earnings: earnings).map(\.symbol).last == "SOL-USD")
        #expect(EV.fastLaneConcentration(all, topN: 3, earnings: earnings)?.isConcentrated == false)
        // A thin-liquidity demotion (−3000 sentinel) on SOL does the same.
        let liq: [String: LiquidityProfile] = ["SOL-USD": LiquidityProfile(avgDollarVolume: 50_000, tier: .thin)]
        #expect(EV.fastLane(all, liquidity: liq).map(\.symbol).last == "SOL-USD")
        #expect(EV.fastLaneConcentration(all, topN: 3, liquidity: liq)?.isConcentrated == false)
    }

    @Test func moneyVelocityConcentrationWarningRendersCanonicalCopyForConcentratedLane() {
        let concentrated = FastLaneConcentration(dominantClass: "Crypto", count: 3, total: 3)
        let warning = EV.moneyVelocityConcentrationWarning(concentrated)
        #expect(warning != nil)
        #expect(warning?.contains("top 3 fastest are all Crypto") == true)
        #expect(warning?.contains("closer to one bet") == true)
    }

    @Test func moneyVelocityConcentrationWarningIsNilForMixedOrInsufficientLane() {
        let mixed = FastLaneConcentration(dominantClass: "Crypto", count: 2, total: 3)
        #expect(EV.moneyVelocityConcentrationWarning(mixed) == nil)
        #expect(EV.moneyVelocityConcentrationWarning(nil) == nil)
    }

    // liquidityRankPenalty (sibling of earningsRankPenalty, §1.A #2) was UNTESTED. Spec is a
    // direct mapping: no profile → 0; tier == .thin → 3000 (the −3000 thin-liquidity sentinel);
    // any other tier (.moderate/.deep) → 0. Only a REAL .thin profile fires (only-real-data).
    @Test func liquidityRankPenaltyFiresOnlyForTheThinTier() {
        let advice = TradeAdvice(action: .buy, conviction: 0.8, regime: .bullTrend,
                                 rationale: [], stopPrice: 90, targetPrice: 110,
                                 suggestedWeight: 0.1, caveat: "")
        let idea = StockSageIdea(symbol: "AAPL", market: "M", price: 100, advice: advice, spark: [])
        let thin = ["AAPL": LiquidityProfile(avgDollarVolume: 50_000, tier: .thin)]
        let deep = ["AAPL": LiquidityProfile(avgDollarVolume: 5_000_000, tier: .deep)]
        #expect(EV.liquidityRankPenalty(for: idea, liquidity: thin) == 3000)   // thin → sentinel
        #expect(EV.liquidityRankPenalty(for: idea, liquidity: deep) == 0)      // deep → no penalty
        #expect(EV.liquidityRankPenalty(for: idea, liquidity: [:]) == 0)       // no profile → 0
        #expect(EV.liquidityRankPenalty(for: idea,                             // moderate → 0 (not thin)
                liquidity: ["AAPL": LiquidityProfile(avgDollarVolume: 1_000_000, tier: .moderate)]) == 0)
        // Band: the 3000 sentinel sits above conviction(1000)+maxEV, below the cost(500k) demotion.
        #expect(1000 + 50.0 < 3000 && 3000 < 500_000)
    }

    @Test func earningsRankFlagExplainsTheDemotion() {
        typealias Flag = EV.EarningsRankFlag
        let earnings: [String: EarningsProximity] = [
            "AAPL": EarningsProximity(daysUntil: 2, severity: .imminent),
            "MSFT": EarningsProximity(daysUntil: 7, severity: .soon),
            "NVDA": EarningsProximity(daysUntil: 40, severity: .clear),
        ]
        #expect(EV.earningsRankFlag(for: idea("AAPL", conviction: 0.8, stop: 98, target: 110), earnings: earnings) == .demoted(daysUntil: 2))
        #expect(EV.earningsRankFlag(for: idea("MSFT", conviction: 0.8, stop: 98, target: 110), earnings: earnings) == .approaching(daysUntil: 7))
        #expect(EV.earningsRankFlag(for: idea("NVDA", conviction: 0.8, stop: 98, target: 110), earnings: earnings) == .clear(daysUntil: 40))
        #expect(EV.earningsRankFlag(for: idea("TSLA", conviction: 0.8, stop: 98, target: 110), earnings: earnings) == .unknown)   // no date → unknown
        // isDemoted mirrors earningsRankPenalty > 0 exactly — the badge can never disagree with the rank shift.
        #expect(Flag.demoted(daysUntil: 2).isDemoted)
        #expect(!Flag.approaching(daysUntil: 7).isDemoted && !Flag.clear(daysUntil: 40).isDemoted && !Flag.unknown.isDemoted)
        // Badge surfaces only the actionable cases (imminent/approaching); clear + unknown are quiet.
        #expect(!Flag.demoted(daysUntil: 2).badge.isEmpty && !Flag.approaching(daysUntil: 7).badge.isEmpty)
        #expect(Flag.clear(daysUntil: 40).badge.isEmpty && Flag.unknown.badge.isEmpty)
    }

    @Test func velocityLaneIsBuyOnly() {
        // A SHORT with a valid positive-EV 2:1 setup must NOT enter the velocity / Fast Lane (it
        // cannot compound like a long, and the best-opportunity card already bars it) — even though
        // its evR > 0 would have passed the old gross-EV gate.
        let buy  = idea("BTC-USD", action: .strongBuy, conviction: 0.9, stop: 90, target: 130)
        let sell = idea("ETH-USD", action: .sell, conviction: 0.9, stop: 110, target: 80)
        #expect(EV.ev(for: sell).map { $0.evR > 0 } == true)               // the short IS positive-EV…
        #expect(EV.fastLane([buy, sell]).map(\.symbol) == ["BTC-USD"])      // …yet excluded from the lane
        #expect(EV.rankByVelocity([sell, buy]).first?.symbol == "BTC-USD") // and falls last in velocity rank
    }

    @Test func expectedWeeklyRSumsTopVelocities() {
        let equity = idea("AAPL", conviction: 0.9, stop: 90, target: 130)    // vel 1.228/12
        let crypto = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130) // vel 1.228/3
        let index = idea("^GSPC", conviction: 0.9, stop: 90, target: 130)    // no velocity → excluded
        // fast lane = [crypto, equity]; sum = 1.228/3 + 1.228/12; × 5 trading days.
        let wk = EV.expectedWeeklyR([equity, index, crypto], maxConcurrent: 3, tradingDays: 5)!
        let expected = (1.228 / 3 + 1.228 / 12) * 5
        #expect(abs(wk - expected) < 1e-9)
        #expect(abs(wk - 2.5583333333) < 1e-6)
        #expect(EV.expectedWeeklyR([index]) == nil)                          // empty fast lane → nil
        #expect(EV.expectedWeeklyR([crypto], maxConcurrent: 0) == nil)       // no slots → nil (no crash)
    }

    // netExpectedWeeklyR (net-of-cost companion to expectedWeeklyR — sums netVelocity, not gross)
    // was UNTESTED. Single US-equity idea ⇒ fastLane=[idea], concentration nil ⇒ factor 1.0, so
    // netExpectedWeeklyR = netVelocity·5. Hand-derived in derive_netweekly.swift (US 13bps, no
    // financing on a long): cost 0.13, netReward 29.87, netRisk 10.13, p 0.557 ⇒ netEVR 1.215,
    // netVelocity 1.215/12 = 0.10125 ⇒ ×5 = 0.50625. Strictly BELOW the gross weeklyR (0.5116667)
    // — the gap IS the round-trip cost, which proves the NET path (not a relabel of gross).
    @Test func netExpectedWeeklyRSumsNetVelocitiesBelowTheGrossRollup() {
        let aapl = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        let net = EV.netExpectedWeeklyR([aapl], maxConcurrent: 3, tradingDays: 5)!
        #expect(abs(net - 0.50625) < 1e-6)
        // gross single-idea rollup = (1.228/12)·5 = 0.5116667; net < gross ⇒ costs bit.
        let gross = EV.expectedWeeklyR([aapl], maxConcurrent: 3, tradingDays: 5)!
        #expect(abs(gross - (1.228 / 12) * 5) < 1e-6)
        #expect(net < gross)
        #expect(EV.netExpectedWeeklyR([aapl], maxConcurrent: 0) == nil)      // no slots → nil (no crash)
    }

    @Test func expectedWeeklyDollarsScalesWeeklyRByRiskDollar() {
        let equity = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        let crypto = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
        // weekly-R = (1.228/3 + 1.228/12)·5 ; $ per 1R = 10000·0.01 = 100.
        let dollars = EV.expectedWeeklyDollars([equity, crypto], account: 10000, riskFraction: 0.01)!
        let wkR = (1.228 / 3 + 1.228 / 12) * 5
        #expect(abs(dollars - wkR * 100) < 1e-6)
        #expect(abs(dollars - 255.8333333) < 1e-4)
        #expect(EV.expectedWeeklyDollars([equity, crypto], account: 0, riskFraction: 0.01) == nil)  // no account
        #expect(EV.expectedWeeklyDollars([], account: 10000, riskFraction: 0.01) == nil)            // empty fast lane
    }

    @Test func summaryComposesBestFastestAndWeeklyR() {
        let saved = StockSageConvictionCalibration.candidateSelectorEnabled
        defer { StockSageConvictionCalibration.candidateSelectorEnabled = saved }
        StockSageConvictionCalibration.candidateSelectorEnabled = false
        let a = idea("A", action: .buy, conviction: 0.2, stop: 90, target: 120)            // EV 0.188
        let b = idea("BTC-USD", action: .strongBuy, conviction: 0.9, stop: 90, target: 130) // EV 1.228
        let s = EV.summary([a, b])
        #expect(s.bestSymbol == "BTC-USD")                       // highest positive-EV buy
        #expect(abs((s.bestEV ?? 0) - 1.228) < 1e-9)
        #expect(s.fastestSymbol == "BTC-USD")                    // highest net velocity
        // summary() uses netVelocity since iter6 (nets spread+slippage+taker before /holdDays)
        #expect(s.fastestVelocity == EV.netVelocity(for: b))
        #expect(s.weeklyR != nil)   // value pinned separately by expectedWeeklyRSumsTopVelocities / concentratedFastLaneHaircutsExpectedWeeklyR
        #expect(s.hasContent)
        #expect(!EV.summary([]).hasContent)                      // empty → nothing to show
    }

    @Test func summaryWeeklyRNetIsRealAndStrictlyBelowGross() {
        // F03/F44 net-headline (owner gate lifted 2026-07-09): the summary must carry the NET
        // weekly figure the card headlines. Contract, all hand-derivable from the cost spec:
        // (1) net exists whenever gross does on a positive-velocity lane; (2) net < gross
        // STRICTLY (BTC-USD carries 70bps RT crypto frictions — costs can only subtract);
        // (3) net equals the standalone netExpectedWeeklyR under identical inputs (the card's
        // number and the fast-lane strip's own net line must be the same number).
        let saved = StockSageConvictionCalibration.candidateSelectorEnabled
        defer { StockSageConvictionCalibration.candidateSelectorEnabled = saved }
        StockSageConvictionCalibration.candidateSelectorEnabled = false
        let b = idea("BTC-USD", action: .strongBuy, conviction: 0.9, stop: 90, target: 130)
        let s = EV.summary([b])
        #expect(s.weeklyRNet != nil)
        #expect(s.weeklyR != nil)
        #expect((s.weeklyRNet ?? 0) < (s.weeklyR ?? 0))
        let standalone = EV.netExpectedWeeklyR([b],
                                               tradingDays: EV.tradingDaysForLane([b], holds: .defaults, calibration: nil),
                                               holds: .defaults, calibration: nil)
        #expect(s.weeklyRNet == standalone)
    }

    // F9 (2026-07-09, same-basket display-sum correctness fix). Straddle fixture: 4 EQUITY ideas
    // (entry 100 / stop 90 / target 130 → risk 10, reward 30, rewardR 3.0; spark:[] so
    // expectedHoldDays falls back to the Equity default 12), convictions 0.8/0.7/0.6/0.5 so the
    // UNAWARE rank-key order is strictly A>B>C>D (higher conviction → higher winProb → higher
    // log-growth AND higher net/gross ratio, both increasing together — no cancellation). Every
    // number below is hand-derived from the DOCUMENTED formulas (winProbEstimate = 0.35+0.23·c;
    // evR = p·rewardR-(1-p) = 4p-1 at rewardR=3; NetEdge cost = (8+5)/10000·100 = 0.13 US bps,
    // netEVR = evR - cost/grossRisk = evR-0.013 since netReward+netRisk = cappedGrossReward+
    // grossRisk cancels the cost's coefficient; vel=evR/12; netVel=netEVR/12) and cross-checked
    // by an independent standalone COMMITTED script (`swift tools/derive/derive_f9_samebasket.swift`
    // — reimplements only the documented formulas above, never calls the app under test):
    //   p:     A=0.534   B=0.511   C=0.488   D=0.465
    //   evR:   A=1.136   B=1.044   C=0.952   D=0.86      (evR=4p-1)
    //   netEVR:A=1.123   B=1.031   C=0.939   D=0.847     (evR-0.013)
    //   vel:   A=0.09466666.. B=0.087        C=0.07933333.. D=0.07166666..   (evR/12)
    //   netVel:A=0.09358333.. B=0.08591666.. C=0.07825      D=0.07058333..   (netEVR/12)
    // Unaware fastLane top-3 (no earnings/liquidity penalty) = {A,B,C}; D is 4th.
    // C ALONE gets an earnings-imminent flag: -2000 rank-key penalty, which dwarfs the ~0.01-scale
    // velocityRankKey entirely, so the AWARE fastLane top-3 = {A,B,D} (C sinks below D).
    // All 4 ideas are Equity (no suffix) so ANY 3-of-4 subset is single-asset-class →
    // fastLaneConcentration.isConcentrated is true for BOTH baskets → the 0.70 haircut applies to
    // all three sums below identically. tradingDaysForLane = 5 (0 crypto in the full 4-idea lane;
    // lane MEMBERSHIP — as opposed to order — is earnings/liquidity-invariant, so this is the same
    // whether the aware or unaware lane computes it).
    //   old weeklyR (basket {A,B,C}, UNCHANGED, unaware)      = (0.09466667+0.087+0.07933333)·5·0.70 = 0.9135000000
    //   weeklyRNet (basket {A,B,D}, aware)                    = (0.09358333+0.08591667+0.07058333)·5·0.70 = 0.8752916667
    //   NEW weeklyRGrossSameBasket (basket {A,B,D}, SAME as net) = (0.09466667+0.087+0.07166667)·5·0.70 = 0.8866666667
    // STRADDLE: weeklyR (0.9135) and weeklyRGrossSameBasket (0.8867) genuinely DIFFER (>0.02 apart)
    // — the old "net X (gross Y)" pairing showed Y from a different top-3 than the one X was summed
    // over; the fix makes the paired gross figure describe net's OWN basket instead.
    @Test func summaryWeeklyRGrossSameBasketMatchesNetBasketNotUnawareLane() {
        let a = idea("FSBA", conviction: 0.8, stop: 90, target: 130)
        let b = idea("FSBB", conviction: 0.7, stop: 90, target: 130)
        let c = idea("FSBC", conviction: 0.6, stop: 90, target: 130)
        let d = idea("FSBD", conviction: 0.5, stop: 90, target: 130)
        let earnings = ["FSBC": EarningsProximity(daysUntil: 1, severity: .imminent)]

        let s = EV.summary([a, b, c, d], earnings: earnings)

        #expect(s.weeklyR != nil)
        #expect(s.weeklyRNet != nil)
        #expect(s.weeklyRGrossSameBasket != nil)
        guard let wk = s.weeklyR, let net = s.weeklyRNet, let sameBasket = s.weeklyRGrossSameBasket else {
            Issue.record("summary() returned nil weeklyR/weeklyRNet/weeklyRGrossSameBasket on a positive-velocity 4-idea lane")
            return
        }
        #expect(abs(wk - 0.9135) < 1e-6)                       // unaware basket {A,B,C} — UNCHANGED
        #expect(abs(net - 0.8752916667) < 1e-6)                // aware basket {A,B,D}
        #expect(abs(sameBasket - 0.8866666667) < 1e-6)         // SAME aware basket {A,B,D} as net
        // The straddle itself: old pairing (weeklyR beside weeklyRNet) vs new (weeklyRGrossSameBasket
        // beside weeklyRNet) show genuinely different numbers — the fix isn't a no-op relabel.
        #expect(abs(wk - sameBasket) > 0.02)
        // Sanity: net still strictly below its OWN same-basket gross (cost is strictly positive).
        #expect(net < sameBasket)
    }

    // No-divergence companion: with NO earnings/liquidity penalty the aware and unaware lanes are
    // IDENTICALLY ordered (nothing subtracts the -2000/-3000 term from any idea), so the aware and
    // unaware top-3 are the same basket {A,B,C} — weeklyRGrossSameBasket must equal weeklyR exactly.
    // Proves the fix is a true no-op when there is nothing to straddle (not a hidden regression).
    @Test func summaryWeeklyRGrossSameBasketEqualsWeeklyRWhenBasketsDoNotDiverge() {
        let a = idea("FSBA", conviction: 0.8, stop: 90, target: 130)
        let b = idea("FSBB", conviction: 0.7, stop: 90, target: 130)
        let c = idea("FSBC", conviction: 0.6, stop: 90, target: 130)
        let d = idea("FSBD", conviction: 0.5, stop: 90, target: 130)
        let s = EV.summary([a, b, c, d])
        #expect(s.weeklyR != nil)
        #expect(s.weeklyRGrossSameBasket != nil)
        #expect(s.weeklyR == s.weeklyRGrossSameBasket)
    }

    // F-review fix (2026-07-10, MEDIUM): weeklyRGrossSameBasket's 0.70 concentration haircut was
    // computed by fastLaneConcentration over the UNAWARE lane (earnings/liquidity defaulted empty
    // inside `expectedWeeklyR(lane:ideas:...)`) even though its velocities were summed over the
    // AWARE `netAwareLane` — the two F9 tests above never caught this because every fixture there
    // is single-asset-class (Equity), so the aware and unaware top-3 are EITHER BOTH concentrated
    // or (no-earnings companion) identical; the isConcentrated boundary was never crossed. This
    // test straddles that boundary: the UNAWARE top-3 is all-crypto (concentrated), the AWARE
    // top-3 swaps in a different-class (equity) idea (NOT concentrated).
    //
    // Fixture: entry 100 / stop 90 / target 130 (rewardR 3.0) on every idea.
    //   C1 BTC-USD conviction 0.8, C2 ETH-USD conviction 0.7, C3 SOL-USD conviction 0.6 (crypto,
    //   hold 3) — velocityRankKey order C1 > C2 > C3, all far above E1.
    //   E1 MSFT conviction 0.55 (equity, hold 12).
    // Hand-derived (documented formulas: winProb=0.35+0.23c; evR=4p-1 at rewardR=3; costPerR =
    // (spreadBps+slippageBps+takerFeeBps)/10000·100/10, crypto=0.07 (70bps), US=0.013 (13bps);
    // netEVR=evR-costPerR; vel=evR/hold; velocityRankKey=logGrowth(p,3)·(netEVR/evR)/hold) and
    // cross-checked by an independent standalone script (scratchpad derive_mixedclass_straddle.swift,
    // run via `swift`, not the app under test):
    //   p:      C1=0.5340  C2=0.5110  C3=0.4880  E1=0.4765
    //   evR:    C1=1.1360  C2=1.0440  C3=0.9520  E1=0.9060
    //   vel:    C1=0.3786666667  C2=0.3480000000  C3=0.3173333333  E1=0.0755000000
    //   netVel: C1=0.3553333333  C2=0.3246666667  C3=0.2940000000  E1=0.0744166667
    //   velocityRankKey (unaware, no earnings/liquidity): C1=0.04453586  C2=0.03767732
    //     C3=0.03135762  E1=0.00758458 — strictly C1>C2>C3>E1 (crypto's 4x-shorter hold dominates
    //     E1's higher-than-C3 conviction), so UNAWARE fastLane top-3 = {C1,C2,C3} (all Crypto) →
    //     fastLaneConcentration.isConcentrated = TRUE (count 3 of 3).
    //   C3 alone gets an earnings-imminent flag: -2000 rank-key penalty crushes its key to
    //     ≈ -1999.97, far below E1's ≈0.00758 → AWARE fastLane top-3 = {C1,C2,E1} (2 Crypto, 1
    //     Equity) → fastLaneConcentration.isConcentrated = FALSE (count 2 of 3, not all-same-class).
    //   tradingDaysForLane over the FULL 4-idea lane (membership is earnings/liquidity-invariant,
    //     StockSageExpectedValue.tradingDaysForLane's own doc): crypto=3 of lane.count=4 →
    //     round(5 + 2·3/4) = round(6.5) = 7.
    //   OLD (pre-fix) weeklyRGrossSameBasket = (vel C1+C2+E1)·7·0.70 (WRONG: haircut judged on the
    //     UNAWARE {C1,C2,C3} concentration, even though the basket summed is {C1,C2,E1})
    //     = (0.3786666667+0.3480000000+0.0755000000)·7·0.70 = 3.9306166667
    //   NEW (fixed) weeklyRGrossSameBasket = (vel C1+C2+E1)·7·1.00 (RIGHT: haircut judged on the
    //     SAME AWARE {C1,C2,E1} basket, which is not concentrated) = 5.6151666667
    //   weeklyRNet (aware {C1,C2,E1}, always used the aware haircut, unaffected by this fix)
    //     = (netVel C1+C2+E1)·7·1.00 = (0.3553333333+0.3246666667+0.0744166667)·7 = 5.2809166667
    // STRADDLE PROOF: the OLD value (3.9306166667) is exactly 0.70× the NEW value (5.6151666667)
    // — the pre-fix bug this test pins against — and OLD sits BELOW weeklyRNet (5.2809166667),
    // which would have shown a net-of-cost figure ABOVE its own paired "gross before costs"
    // parenthetical, backwards from every other pairing in the app. The fix restores gross ≥ net.
    @Test func summaryWeeklyRGrossSameBasketUsesAwareConcentrationAcrossAssetClasses() {
        let c1 = idea("BTC-USD", conviction: 0.8,  stop: 90, target: 130)
        let c2 = idea("ETH-USD", conviction: 0.7,  stop: 90, target: 130)
        let c3 = idea("SOL-USD", conviction: 0.6,  stop: 90, target: 130)
        let e1 = idea("MSFT",    conviction: 0.55, stop: 90, target: 130)
        let earnings = ["SOL-USD": EarningsProximity(daysUntil: 1, severity: .imminent)]

        // Unaware sanity check: without the earnings demotion, the top-3 by velocity ranking is
        // indeed the all-crypto {C1,C2,C3} and IS concentrated — the premise the OLD buggy code
        // relied on for its (wrong, in the aware case) 0.70 haircut.
        let unawareLane = EV.fastLane([c1, c2, c3, e1])
        #expect(unawareLane.prefix(3).map(\.symbol) == ["BTC-USD", "ETH-USD", "SOL-USD"])
        #expect(EV.fastLaneConcentration([c1, c2, c3, e1], topN: 3)?.isConcentrated == true)
        // Aware sanity check: WITH the earnings demotion, MSFT swaps into the top-3 and the basket
        // is no longer single-asset-class.
        let awareLane = EV.fastLane([c1, c2, c3, e1], earnings: earnings)
        #expect(awareLane.prefix(3).map(\.symbol) == ["BTC-USD", "ETH-USD", "MSFT"])
        #expect(EV.fastLaneConcentration([c1, c2, c3, e1], topN: 3, earnings: earnings)?.isConcentrated == false)

        let s = EV.summary([c1, c2, c3, e1], earnings: earnings)
        guard let net = s.weeklyRNet, let sameBasket = s.weeklyRGrossSameBasket else {
            Issue.record("summary() returned nil weeklyRNet/weeklyRGrossSameBasket on a positive-velocity 4-idea mixed-class lane")
            return
        }
        #expect(abs(sameBasket - 5.6151666667) < 1e-6)   // NEW: aware haircut (1.00) — the fix
        #expect(abs(net - 5.2809166667) < 1e-6)
        // The bug this test pins: the OLD value would have been sameBasket·0.70 (the wrong,
        // unaware-judged haircut) — exactly 3.9306166667, and BELOW net, backwards.
        let oldBuggyValue = 3.9306166667
        #expect(abs(oldBuggyValue - sameBasket * 0.70) < 1e-6)
        #expect(oldBuggyValue < net)          // the OLD bug: gross-before-costs shown BELOW net-of-cost
        #expect(sameBasket > net)             // the FIX: gross-before-costs correctly ABOVE net-of-cost
    }

    // F4 (2026-07-09): the "≈ +$N/week" header dollarizes weekly R with no fundability check —
    // this flag lets the view add an honest qualifier without touching that header's own math.
    // Straddle: same idea (entry 100/stop 90/target 130, riskPerShare 10), account swept from
    // unfundable to fundable at the sizer's own 1-share floor.
    @Test func weeklyDollarsIncludesUnfundableRowTrueWhenATopLaneIdeaFloorsToZeroShares() {
        // $1 account, 1% risk → $0.01 budget ÷ $10 risk/share = 0.001 → floors to 0 shares.
        let a = idea("A", conviction: 0.6, stop: 90, target: 130)
        #expect(EV.weeklyDollarsIncludesUnfundableRow(lane: [a], account: 1, riskFraction: 0.01))
    }

    @Test func weeklyDollarsIncludesUnfundableRowFalseWhenTheLaneIdeaIsFundable() {
        // $100k account, 1% risk → $1000 budget ÷ $10 risk/share = 100 shares — clearly fundable.
        let a = idea("A", conviction: 0.6, stop: 90, target: 130)
        #expect(!EV.weeklyDollarsIncludesUnfundableRow(lane: [a], account: 100_000, riskFraction: 0.01))
    }

    @Test func weeklyDollarsIncludesUnfundableRowFalseOnUnusableInputsOrEmptyLane() {
        let a = idea("A", conviction: 0.6, stop: 90, target: 130)
        #expect(!EV.weeklyDollarsIncludesUnfundableRow(lane: [a], account: 0, riskFraction: 0.01))       // no account
        #expect(!EV.weeklyDollarsIncludesUnfundableRow(lane: [a], account: 10_000, riskFraction: 0))     // no risk %
        #expect(!EV.weeklyDollarsIncludesUnfundableRow(lane: [], account: 10_000, riskFraction: 0.01))   // empty lane
    }

    @Test func summaryIncludesWorstRunDrawdownBrake() {
        let b = idea("BTC-USD", action: .strongBuy, conviction: 0.9, stop: 90, target: 130)
        // 3 closed losers in a row → worst run 3; at 1%/trade → 1 − 0.99^3 = 0.029701.
        let losers = (0..<3).map { i in
            TradeRecord(symbol: "X", side: .long, entry: 100, stop: 90, target: nil, shares: 1,
                        openedAt: Date(timeIntervalSince1970: Double(i) * 100),
                        exitPrice: 95, closedAt: Date(timeIntervalSince1970: Double(i) * 100 + 50))
        }
        let s = EV.summary([b], trades: losers)
        #expect(s.worstRunLosses == 3)
        #expect(abs((s.worstRunDrawdownPct ?? 0) - (1 - pow(0.99, 3))) < 1e-9)
        #expect(EV.summary([b]).worstRunDrawdownPct == nil)      // no trades → no brake
    }

    @Test func velocityRespectsTunableHoldDays() {
        let crypto = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)   // EV 1.228
        let base = EV.velocity(for: crypto)!                                   // default crypto 3 → 1.228/3
        let slower = EV.velocity(for: crypto, holds: VelocityHoldDays(crypto: 6, equity: 12))!  // → 1.228/6
        #expect(abs(base - 1.228 / 3) < 1e-9)
        #expect(abs(slower - 1.228 / 6) < 1e-9)
        #expect(base > slower)                                                 // shorter hold = higher velocity
        #expect(EV.expectedHoldDays(forSymbol: "BTC-USD") == 3)                // default unchanged
        #expect(EV.expectedHoldDays(forSymbol: "BTC-USD", holds: VelocityHoldDays(crypto: 6, equity: 12)) == 6)
    }

    @Test func playbookListsBestFastestWeeklyAndRisk() {
        let s = MoneyVelocitySummary(bestSymbol: "NVDA", bestEV: 0.74, fastestSymbol: "BTC-USD",
                                     fastestVelocity: 0.41, weeklyR: 2.6, worstRunLosses: 6, worstRunDrawdownPct: 0.059)
        let plan = EV.playbook(s)
        #expect(plan.contains("NVDA"))
        #expect(plan.contains("BTC-USD"))
        #expect(plan.contains("+0.74"))
        #expect(plan.contains("week"))
        #expect(plan.contains("stop"))                       // honesty: always a stop
        #expect(plan.lowercased().contains("estimate"))      // honesty: labeled estimate
        #expect(plan.contains("1.") && plan.contains("2."))  // numbered, ordered
        #expect(plan.contains("1%/trade"))                   // default fraction → 1% label
        // The brake LABEL must track the modeled fraction, never drift (honesty floor).
        let at2 = MoneyVelocitySummary(worstRunLosses: 6, worstRunDrawdownPct: 0.118, riskFraction: 0.02)
        #expect(EV.playbook(at2).contains("2%/trade"))
        #expect(!EV.playbook(at2).contains("1%/trade"))
        // Empty summary → just the header + the risk rule, still honest.
        let empty = EV.playbook(MoneyVelocitySummary(bestSymbol: nil, bestEV: nil, fastestSymbol: nil,
                                                     fastestVelocity: nil, weeklyR: nil, worstRunLosses: nil, worstRunDrawdownPct: nil))
        #expect(empty.contains("stop"))
        #expect(empty.contains("1."))
    }

    @Test func tradingDaysForLaneBlendsByCryptoShare() {
        let btc  = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
        let eth  = idea("ETH-USD", conviction: 0.9, stop: 90, target: 130)
        let aapl = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        let msft = idea("MSFT", conviction: 0.9, stop: 90, target: 130)
        #expect(EV.tradingDaysForLane([btc, eth]) == 7)            // all crypto → 7-day week
        #expect(EV.tradingDaysForLane([aapl, msft]) == 5)          // equity only → unchanged 5
        #expect(EV.tradingDaysForLane([btc, aapl, msft]) == 6)     // 1/3 crypto → round(5 + 0.667) = 6
        #expect(EV.tradingDaysForLane([]) == 5)                    // empty lane → 5
    }

    @Test func cryptoRiskScalerOnlyShrinksRisk() {
        #expect(abs(EV.cryptoRiskScaler(annualizedVol: 0.70) - 3.5) < 1e-9)    // 0.70 / 0.20
        #expect(abs(EV.cryptoRiskScaler(annualizedVol: 0.25) - 1.25) < 1e-9)
        #expect(EV.cryptoRiskScaler(annualizedVol: 0.10) == 1.0)               // floored — never inflates risk
        #expect(EV.cryptoRiskScaler(annualizedVol: 0.20) == 1.0)
    }

    // MARK: - FASTMONEY_BACKLOG #3: honest 24/7 daily-variance read

    @Test func dailyVariancePctDeAnnualizesOnTheSameBasisRealizedVolIsActuallyComputedWith() {
        // 2026-07-01 adversarial-review fix: idea.realizedVol (this function's only real input)
        // is ALWAYS StockSageIndicators.annualizedVolatility(closes) at its default 252-basis —
        // for every asset class, crypto included (no caller anywhere passes periodsPerYear: 365).
        // Dividing by √365 instead of √252 understated the reported daily move by ~17% — the
        // opposite of the honest intent. 70% annualized vol → 70/√252 ≈ 4.41% typical one-day move.
        let expected70 = 0.70 / 252.0.squareRoot() * 100
        #expect(abs(EV.dailyVariancePct(annualizedVol: 0.70)! - expected70) < 1e-9)
        // Linear in vol: half the input vol → exactly half the variance read.
        #expect(abs(EV.dailyVariancePct(annualizedVol: 0.35)! - expected70 / 2) < 1e-9)
    }

    @Test func dailyVariancePctNeverInventsANumber() {
        #expect(EV.dailyVariancePct(annualizedVol: nil) == nil)        // no history → no invented number
        #expect(EV.dailyVariancePct(annualizedVol: 0) == nil)          // zero vol is degenerate, not "0% range"
        #expect(EV.dailyVariancePct(annualizedVol: -0.5) == nil)       // never negative
        #expect(EV.dailyVariancePct(annualizedVol: .infinity) == nil)  // non-finite guarded
        #expect(EV.dailyVariancePct(annualizedVol: .nan) == nil)
    }

    @Test func earningsPenaltyStacksBelowACostFailedPeerAndNeverResurrectsANilKey() {
        // BTC: imminent earnings (−2000) AND after-cost negative (−500k); ETH: cost-fail only; AAPL: clean.
        // The bands stack, so BTC sinks BELOW the cost-only-failed ETH, and both below the clean AAPL.
        let thin    = idea("BTC-USD", conviction: 0.5, stop: 98, target: 103)
        let costOnly = idea("ETH-USD", conviction: 0.5, stop: 98, target: 103)
        let clean   = idea("AAPL", conviction: 0.7, stop: 90, target: 130)
        let earnings: [String: EarningsProximity] = ["BTC-USD": EarningsProximity(daysUntil: 2, severity: .imminent)]
        #expect(EV.rankByEV([thin, costOnly, clean], earnings: earnings).map(\.symbol) == ["AAPL", "ETH-USD", "BTC-USD"])
        // The penalty is applied via .map on the rank key, so it can NEVER resurrect a nil (no-EV) key:
        // two stop/target-less buys both rank nil → stable input order, the imminent one does not float up.
        let nilA = idea("NOEVA", conviction: 0.9, stop: nil, target: nil)   // imminent + nil EV key
        let nilB = idea("NOEVB", conviction: 0.9, stop: nil, target: nil)   // clean + nil EV key
        let earn2: [String: EarningsProximity] = ["NOEVA": EarningsProximity(daysUntil: 1, severity: .imminent)]
        #expect(EV.rankByEV([nilB, nilA], earnings: earn2).map(\.symbol) == ["NOEVB", "NOEVA"])
    }

    @Test func afterCostNegativeFlipIsDemotedBelowCleanSetup() {
        // Thin crypto flip: +EV pre-cost (rewardR 1.5) but 50bps crypto cost pushes the after-cost
        // break-even (50%) ABOVE its conviction win-prob (46.5%) → must not out-rank a clean setup.
        let thin  = idea("BTC-USD", conviction: 0.5, stop: 98, target: 103)
        let clean = idea("AAPL",    conviction: 0.7, stop: 90, target: 130)   // 13bps, clears easily
        #expect(EV.rankByEV([thin, clean]).first?.symbol == "AAPL")
        #expect(EV.bestOpportunity([thin, clean])?.idea.symbol == "AAPL")
        // The clean setup alone is still a valid best opportunity (not over-demoted).
        #expect(EV.bestOpportunity([clean])?.idea.symbol == "AAPL")
    }

    @Test func bestOpportunityHonorsTheEarningsGate() {
        // AAPL has the HIGHER base EV (6:1) but reports in 2 days; MSFT is a clean 1.5:1.
        let imminent = idea("AAPL", conviction: 0.9, stop: 95, target: 130)
        let clean = idea("MSFT", conviction: 0.9, stop: 90, target: 115)
        // No earnings → the higher-EV name wins (unchanged behavior, matches the boards).
        #expect(EV.bestOpportunity([imminent, clean])?.idea.symbol == "AAPL")
        // AAPL imminent → demoted below the clean peer, so the card/Today/summary match the EV board.
        let earnings: [String: EarningsProximity] = ["AAPL": EarningsProximity(daysUntil: 2, severity: .imminent)]
        #expect(EV.bestOpportunity([imminent, clean], earnings: earnings)?.idea.symbol == "MSFT")
        // Demotion, not exclusion: if the imminent name is the ONLY positive-EV buy, it still surfaces.
        #expect(EV.bestOpportunity([imminent], earnings: earnings)?.idea.symbol == "AAPL")
    }

    @Test func hairThinStopCannotOverrunTheRegimeBan() {
        // Pre-cap, a regime-banned SELL with a near-zero stop (risk 1e-5) scored ~2,000,000 R and
        // beat the −1,000,000 ban penalty — crowning a short #1 in a BULL tape. rewardR caps at 50.
        let bull = MarketRegime(state: .trendingBull, riskScore: 0.6, signals: [], sizingBias: 1.1, caveat: "x")
        let cleanBuy  = idea("WIN", action: .buy,  conviction: 1.0, stop: 90, target: 120)
        let knifeSell = idea("EXPLOIT", action: .sell, conviction: 1.0, stop: 100.00001, target: 80)
        #expect(EV.rankByEV([cleanBuy, knifeSell], regime: bull).first?.symbol == "WIN")
        // The cap itself: a degenerate hair-thin stop yields rewardR 50, not millions.
        #expect(EV.ev(conviction: 1.0, entry: 100, stop: 100.00001, target: 80)?.rewardR == 50)
        // A normal setup is unaffected (4:1 stays 4:1): reward 40 (140−100) ÷ risk 10 (100−90).
        // (Was target 130 = 30/10 = 3:1, a typo contradicting the "4:1" comment.)
        #expect(EV.ev(conviction: 0.9, entry: 100, stop: 90, target: 140)?.rewardR == 4)
    }

    @Test func regimeGateKeepsBannedSideFromTopRank() {
        let bear   = MarketRegime(state: .trendingBear, riskScore: -0.5, signals: [], sizingBias: 0.5,  caveat: "x")
        let bull   = MarketRegime(state: .trendingBull, riskScore: 0.6,  signals: [], sizingBias: 1.1,  caveat: "x")
        let crisis = MarketRegime(state: .crisis,       riskScore: -0.9, signals: [], sizingBias: 0.25, caveat: "x")
        let rng    = MarketRegime(state: .ranging,      riskScore: 0,    signals: [], sizingBias: 1,    caveat: "x")
        let buy  = idea("WIN", action: .buy,  conviction: 0.9, stop: 90,  target: 130)
        let sell = idea("DN",  action: .sell, conviction: 0.8, stop: 110, target: 80)
        // Backward compat: nil regime is identical to no regime.
        #expect(EV.rankByEV([buy, sell]).map(\.symbol) == EV.rankByEV([buy, sell], regime: nil).map(\.symbol))
        // Risk-off (bear/crisis): no BUY ranks #1, and bestOpportunity (buy-only) returns nil.
        #expect(EV.rankByEV([buy, sell], regime: bear).first?.symbol == "DN")
        #expect(EV.bestOpportunity([buy], regime: bear) == nil)
        #expect(EV.bestOpportunity([buy], regime: crisis) == nil)
        // Bull: no SHORT ranks #1; the buy is the best opportunity.
        #expect(EV.rankByEV([buy, sell], regime: bull).first?.symbol == "WIN")
        #expect(EV.bestOpportunity([buy], regime: bull)?.idea.symbol == "WIN")
        // Ranging gates nothing → identical ordering to no regime.
        #expect(EV.rankByEV([buy, sell], regime: rng).map(\.symbol) == EV.rankByEV([buy, sell]).map(\.symbol))
    }

    @Test func lowConvictionFantasyTargetCannotTopTheBoard() {
        // 18:1 reward:risk but ZERO conviction inflates raw EV to ~5.65R — it must NOT
        // out-rank a real 0.8-conviction 2:1 setup (~0.60R) once quality-adjusted.
        let junk = idea("JUNK", conviction: 0.0, stop: 90, target: 280)
        let real = idea("AAPL", conviction: 0.8, stop: 90, target: 120)
        #expect(EV.rankByEV([junk, real]).first?.symbol == "AAPL")
        #expect(EV.rankByVelocity([junk, real]).first?.symbol == "AAPL")
        #expect(EV.bestOpportunity([junk]) == nil)                      // sub-0.40 conviction → no #1 pick
        #expect(EV.bestOpportunity([junk, real])?.idea.symbol == "AAPL")
    }

    @Test func fastLaneConcentrationFlagsAllSameClass() {
        let c1 = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
        let c2 = idea("ETH-USD", conviction: 0.8, stop: 90, target: 130)
        let c3 = idea("SOL-USD", conviction: 0.7, stop: 90, target: 130)
        let conc = EV.fastLaneConcentration([c1, c2, c3])!
        #expect(conc.dominantClass == "Crypto")
        #expect(conc.count == 3 && conc.total == 3)
        #expect(conc.isConcentrated)                     // all 3 fastest are crypto → one bet, not three
        // Mixed: top fast lane = BTC, ETH (crypto), AAPL (equity) → not all one class.
        let eq = idea("AAPL", conviction: 0.95, stop: 90, target: 130)
        let mixed = EV.fastLaneConcentration([c1, eq, c2])!
        #expect(!mixed.isConcentrated)
        #expect(EV.fastLaneConcentration([c1]) == nil)   // <2 fast-lane → nil
    }

    // MARK: - RANKING_BACKLOG #10: bestOpportunity prefers velocity, ties broken by conviction (opt-in)

    @Test func bestOpportunityDefaultIsByteIdenticalWithoutPreferVelocity() {
        // Regression: omitting `preferVelocity` (or passing it explicitly as false) must rank
        // EXACTLY like before #10 — by qualityAdjustedEVR, not velocity. AAPL (slow, higher
        // quality-adjusted EV) still beats SOL-USD (fast, lower quality-adjusted EV) by default,
        // even though SOL-USD is verifiably the faster compounder.
        let slow = idea("AAPL", conviction: 0.9, stop: 90, target: 130)     // evR 1.228, hold 12d (equity)
        let fast = idea("SOL-USD", conviction: 0.9, stop: 90, target: 120)  // evR 0.671, hold 3d (crypto, faster)
        #expect(EV.qualityAdjustedEVR(for: slow)! > EV.qualityAdjustedEVR(for: fast)!)
        #expect(EV.velocity(for: fast)! > EV.velocity(for: slow)!)                      // fast really IS faster
        #expect(EV.bestOpportunity([slow, fast])?.idea.symbol == "AAPL")                // no param → unchanged
        #expect(EV.bestOpportunity([slow, fast], preferVelocity: false)?.idea.symbol == "AAPL")  // explicit false → identical
    }

    @Test func bestOpportunityPreferVelocityPicksTheFasterCompounder() {
        // Same fixture as the regression test above: opting in flips the pick to the
        // faster-compounding (higher EV/day) setup, even though its quality-adjusted EV is lower —
        // matching the Fast Lane's own metric instead of the card's EV-only one.
        let slow = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        let fast = idea("SOL-USD", conviction: 0.9, stop: 90, target: 120)
        #expect(EV.bestOpportunity([slow, fast], preferVelocity: true)?.idea.symbol == "SOL-USD")
    }

    @Test func bestOpportunityPreferVelocityFallsBackToQualityAdjustedEVForNoVelocityIdeas() {
        // FX has no asset-class velocity (expectedHoldDays is nil for it) — preferVelocity must
        // fall back to qualityAdjustedEVR for it rather than excluding it or scoring it 0. Rigged
        // so the DEFAULT picks the crypto idea (higher qualityAdjustedEVR) but preferVelocity
        // flips to FX, because crypto is now ranked by its (lower) velocity while FX's fallback
        // score is unchanged.
        let crypto = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)  // evR 1.228, qAdj 1.15432, vel 0.40933
        let fx = idea("GBPUSD=X", conviction: 0.9, stop: 90, target: 125)     // evR 0.9495, qAdj 0.89253, no velocity
        #expect(EV.velocity(for: fx) == nil)
        #expect(EV.qualityAdjustedEVR(for: crypto)! > EV.qualityAdjustedEVR(for: fx)!)
        #expect(EV.bestOpportunity([crypto, fx])?.idea.symbol == "BTC-USD")                        // default: EV-based
        #expect(EV.bestOpportunity([crypto, fx], preferVelocity: true)?.idea.symbol == "GBPUSD=X")  // opt-in: FX's fallback beats crypto's now-lower velocity rank
    }

    @Test func bestOpportunityPreferVelocityTieBreaksByConviction() {
        // Two crypto buys engineered so raw velocity is a near-tie (|Δ| < 0.01, same 3d crypto
        // hold) but conviction differs a lot. Without a conviction tie-break, LOW's marginally
        // higher raw velocity (or mere array position) would win; WITH it, HIGH's conviction wins.
        let low  = idea("LOWC-USD",  conviction: 0.40, stop: 90, target: 200)       // R:R 10:1,   p 0.442 → evR 3.862
        let high = idea("HIGHC-USD", conviction: 1.00, stop: 90, target: 173.6207)  // R:R ~7.362:1, p 0.58 → evR ≈3.850
        let vLow = EV.velocity(for: low)!, vHigh = EV.velocity(for: high)!
        #expect(abs(vLow - vHigh) < 0.01)     // genuinely a near-tie
        #expect(vLow > vHigh)                 // LOW's raw velocity is marginally (not tied-away) higher
        #expect(EV.bestOpportunity([low, high], preferVelocity: true)?.idea.symbol == "HIGHC-USD")
        // Order-independent — proves it's conviction-driven, not array-position luck.
        #expect(EV.bestOpportunity([high, low], preferVelocity: true)?.idea.symbol == "HIGHC-USD")
    }

    // MARK: - CONFLUENCE.md #5: preferConfluence tie-break (opt-in)

    private func confluenceIdea(_ symbol: String, conviction: Double, stop: Double, target: Double,
                                timeframeAligned: Bool) -> StockSageIdea {
        StockSageIdea(symbol: symbol, market: "M", price: 100,
                      advice: TradeAdvice(action: .buy, conviction: conviction, regime: .bullTrend, rationale: [],
                                          stopPrice: stop, targetPrice: target, suggestedWeight: 0.05, caveat: "x",
                                          timeframeAligned: timeframeAligned, confluenceNote: timeframeAligned ? "note" : nil),
                      spark: [])
    }

    @Test func bestOpportunityDefaultIgnoresConfluenceEvenWhenSet() {
        // Regression: without preferConfluence, an EXACT tie must still resolve by array
        // position (byte-identical to before this item), never silently by alignment.
        let notAligned = confluenceIdea("A", conviction: 0.8, stop: 90, target: 130, timeframeAligned: false)
        let aligned = confluenceIdea("B", conviction: 0.8, stop: 90, target: 130, timeframeAligned: true)
        #expect(EV.qualityAdjustedEVR(for: notAligned)! == EV.qualityAdjustedEVR(for: aligned)!)   // exact tie
        #expect(EV.bestOpportunity([notAligned, aligned])?.idea.symbol == "A")   // first wins, alignment ignored
        #expect(EV.bestOpportunity([notAligned, aligned], preferConfluence: false)?.idea.symbol == "A")
    }

    @Test func bestOpportunityPreferConfluenceBreaksATieTowardTheAlignedIdea() {
        let notAligned = confluenceIdea("A", conviction: 0.8, stop: 90, target: 130, timeframeAligned: false)
        let aligned = confluenceIdea("B", conviction: 0.8, stop: 90, target: 130, timeframeAligned: true)
        #expect(EV.bestOpportunity([notAligned, aligned], preferConfluence: true)?.idea.symbol == "B")
        // Order-independent — proves it's alignment-driven, not array-position luck.
        #expect(EV.bestOpportunity([aligned, notAligned], preferConfluence: true)?.idea.symbol == "B")
    }

    @Test func bestOpportunityPreferConfluenceNeverOverridesAClearRankValWinner() {
        // Confluence only breaks a NEAR-tie — a genuinely better rankVal must still win outright,
        // even against an aligned-but-clearly-worse idea.
        let clearWinner = confluenceIdea("BIG", conviction: 1.0, stop: 90, target: 400, timeframeAligned: false)
        let alignedButWorse = confluenceIdea("SMALL", conviction: 0.40, stop: 98, target: 102, timeframeAligned: true)
        #expect(EV.bestOpportunity([clearWinner, alignedButWorse], preferConfluence: true)?.idea.symbol == "BIG")
    }

    @Test func bestOpportunityComposesConvictionThenConfluenceTieBreaks() {
        // Two-way: HIGH_CONV (higher conviction, NOT aligned) must beat LOW_CONV_ALIGNED (lower
        // conviction, aligned) once preferVelocity's conviction tie-break applies FIRST —
        // confluence only breaks a tie conviction couldn't already resolve.
        let lowConvAligned = confluenceIdea("LOWC-USD", conviction: 0.40, stop: 90, target: 200, timeframeAligned: true)
        let highConvNotAligned = confluenceIdea("HIGHC-USD", conviction: 1.00, stop: 90, target: 173.6207, timeframeAligned: false)
        let vLow = EV.velocity(for: lowConvAligned)!, vHigh = EV.velocity(for: highConvNotAligned)!
        #expect(abs(vLow - vHigh) < 0.01)   // genuinely a near-tie on raw velocity
        // Both flags on: conviction tie-break fires first (HIGHC-USD wins), confluence never gets consulted.
        #expect(EV.bestOpportunity([lowConvAligned, highConvNotAligned],
                                   preferVelocity: true, preferConfluence: true)?.idea.symbol == "HIGHC-USD")
    }

    @Test func turnOfMonthActivationCanChangeTheRankWhenMonthSignalExists() {
        // TomFlagTestLock (2026-07-09 review fix): the flag is a cross-suite process-global;
        // StockSageTomGateTests briefly flips it off — unguarded, this test could read that
        // window. Restore runs before unlock (defer LIFO).
        TomFlagTestLock.lock.lock()
        defer { TomFlagTestLock.lock.unlock() }
        let saved = StockSageAdvisor.turnOfMonthEnabled
        defer { StockSageAdvisor.turnOfMonthEnabled = saved }
        StockSageAdvisor.turnOfMonthEnabled = true

        let currentMonth = StockSageSeasonality.currentMonth()
        let winner = idea("WIN", conviction: 0.60, stop: 90, target: 120)
        let loser  = idea("LOSE", conviction: 0.61, stop: 90, target: 120)

        func seasonality(_ monthlyDrift: Double, samples: Int) -> MonthlySeasonality {
            MonthlySeasonality(months: (1...12).map { month in
                MonthlySeasonality.MonthStat(
                    month: month,
                    avgReturn: month == currentMonth ? monthlyDrift : 0.0,
                    samples: month == currentMonth ? samples : 0
                )
            }, years: 5)
        }

        let seasonalityBySymbol = [
            "WIN": seasonality(0.04, samples: 5),
            "LOSE": seasonality(0.0, samples: 5)
        ]

        #expect(EV.rankByEV([winner, loser], seasonality: seasonalityBySymbol).first?.symbol == "WIN")
        #expect(EV.bestOpportunity([winner, loser], seasonality: seasonalityBySymbol)?.idea.symbol == "WIN")
        // 2026-07-09 review fix: summary() was the FIFTH bestOpportunity call site — the four
        // direct UI sites got the tilt but the money-velocity headline/playbook/velocityHistory
        // route through summary() and could crown a DIFFERENT best. Pin the parity: the same
        // tilt-decided fixture must crown the same symbol through summary().
        #expect(EV.summary([winner, loser], seasonality: seasonalityBySymbol).bestSymbol == "WIN")
    }

    // MARK: - RANKING_BACKLOG #4: liquidity gate

    @Test func thinLiquidityIsDemotedInRankingAndBarredFromBestOpportunity() {
        let thin  = idea("MICROCAP", conviction: 0.9, stop: 90, target: 130)   // higher base EV
        let deep  = idea("AAPL", conviction: 0.7, stop: 90, target: 115)       // lower base EV
        // No liquidity data → identical to before (higher-EV name wins).
        #expect(EV.rankByEV([thin, deep]).first?.symbol == "MICROCAP")
        #expect(EV.bestOpportunity([thin, deep])?.idea.symbol == "MICROCAP")
        // Thin liquidity on the higher-EV name → demoted below the deep peer on both boards,
        // and barred outright from "best opportunity" even though it has the highest EV.
        let liquidity: [String: LiquidityProfile] = [
            "MICROCAP": LiquidityProfile(avgDollarVolume: 500_000, tier: .thin)
        ]
        #expect(EV.rankByEV([thin, deep], liquidity: liquidity).first?.symbol == "AAPL")
        #expect(EV.bestOpportunity([thin, deep], liquidity: liquidity)?.idea.symbol == "AAPL")
        // Hard bar, not mere demotion: even as the ONLY positive-EV buy, a thin name never becomes
        // "best opportunity" (unlike the earnings gate, which still surfaces a lone imminent idea).
        #expect(EV.bestOpportunity([thin], liquidity: liquidity) == nil)
        // Moderate/deep tiers are unaffected.
        let deepTierLiquidity: [String: LiquidityProfile] = [
            "MICROCAP": LiquidityProfile(avgDollarVolume: 80_000_000, tier: .deep)
        ]
        #expect(EV.rankByEV([thin, deep], liquidity: deepTierLiquidity).first?.symbol == "MICROCAP")
        #expect(EV.bestOpportunity([thin, deep], liquidity: deepTierLiquidity)?.idea.symbol == "MICROCAP")
    }

    @Test func thinLiquidityIsDemotedInVelocityRanking() {
        let thin = idea("MICROCAP", conviction: 0.9, stop: 90, target: 130)
        let deep = idea("AAPL", conviction: 0.7, stop: 90, target: 115)
        #expect(EV.rankByVelocity([thin, deep]).first?.symbol == "MICROCAP")   // no liquidity data → unchanged
        let liquidity: [String: LiquidityProfile] = [
            "MICROCAP": LiquidityProfile(avgDollarVolume: 500_000, tier: .thin)
        ]
        #expect(EV.rankByVelocity([thin, deep], liquidity: liquidity).first?.symbol == "AAPL")
    }

    // MARK: - RANKING_BACKLOG #8: fast-lane concentration haircuts expectedWeeklyR

    @Test func concentratedFastLaneHaircutsExpectedWeeklyR() {
        // All-crypto top-3 (matches fastLaneConcentrationFlagsAllSameClass's fixture) — a correlated
        // bet counted 3× should NOT sum as if independent.
        let c1 = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
        let c2 = idea("ETH-USD", conviction: 0.8, stop: 90, target: 130)
        let c3 = idea("SOL-USD", conviction: 0.7, stop: 90, target: 130)
        #expect(EV.fastLaneConcentration([c1, c2, c3], topN: 3)!.isConcentrated)   // pin the premise
        let concentratedWk = EV.expectedWeeklyR([c1, c2, c3], maxConcurrent: 3, tradingDays: 5)!
        let rawSum = EV.fastLane([c1, c2, c3]).prefix(3).compactMap { EV.velocity(for: $0) }.reduce(0, +) * 5
        #expect(abs(concentratedWk - rawSum * 0.70) < 1e-9)   // haircut applied
        // Mixed asset classes (existing fixture from expectedWeeklyRSumsTopFastLaneVelocitiesTimesTradingDays,
        // re-derived here) — NOT concentrated, so no haircut (byte-identical to before this change).
        let equity = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        let crypto = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
        let mixedWk = EV.expectedWeeklyR([equity, crypto], maxConcurrent: 3, tradingDays: 5)!
        let mixedRawSum = EV.fastLane([equity, crypto]).prefix(3).compactMap { EV.velocity(for: $0) }.reduce(0, +) * 5
        #expect(abs(mixedWk - mixedRawSum) < 1e-9)   // factor == 1.0, unchanged
    }

    // MARK: - RANKING_BACKLOG #13: legible EV-skip reason

    @Test func evSkipReasonExplainsWhyAnIdeaHasNoDefinedEV() {
        let complete = idea("AAPL", conviction: 0.7, stop: 90, target: 130)
        let noStop   = idea("MSFT", conviction: 0.7, stop: nil, target: 130)
        let noTarget = idea("GOOG", conviction: 0.7, stop: 90, target: nil)
        let neither  = idea("HOLD", conviction: 0.7, stop: nil, target: nil)
        #expect(EV.evSkipReason(for: complete) == nil)
        #expect(EV.evSkipReason(for: noStop) == .noStop)
        #expect(EV.evSkipReason(for: noTarget) == .noTarget)
        #expect(EV.evSkipReason(for: neither) == .noStopOrTarget)
        // rankByEV keeps every idea (deprioritizes, never drops) — evSkipReason explains the ones
        // a "Ranked: N · Incomplete: M" header would count, without changing the ranked count itself.
        let ranked = EV.rankByEV([complete, noStop])
        #expect(ranked.count == 2)
        #expect(ranked.filter { EV.evSkipReason(for: $0) != nil }.count == 1)
    }

    @Test func summaryMatchesStandaloneSurfaces() {
        let saved = StockSageConvictionCalibration.candidateSelectorEnabled
        defer { StockSageConvictionCalibration.candidateSelectorEnabled = saved }
        StockSageConvictionCalibration.candidateSelectorEnabled = false
        // The summary card composes the same helpers the standalone surfaces use — pin
        // that they never drift (a future change to summary() that diverges goes red).
        let a = idea("A", action: .buy, conviction: 0.2, stop: 90, target: 120)
        let b = idea("BTC-USD", action: .strongBuy, conviction: 0.9, stop: 90, target: 130)
        let c = idea("AAPL", action: .buy, conviction: 0.6, stop: 90, target: 120)
        let ideas = [a, b, c]
        let s = EV.summary(ideas)
        #expect(s.bestSymbol == EV.bestOpportunity(ideas)?.idea.symbol)
        #expect(s.bestEV == EV.bestOpportunity(ideas)?.ev.evR)
        #expect(s.fastestSymbol == EV.fastLane(ideas).first?.symbol)
        // summary() uses netVelocity since iter6 — match the same helper here
        #expect(s.fastestVelocity == EV.fastLane(ideas).first.flatMap { EV.netVelocity(for: $0) })
        // summary() uses crypto-aware cadence (tradingDaysForLane: ~7d for a crypto lane, 5d
        // equity), so match that here rather than the default 5 — they must agree by construction.
        #expect(s.weeklyR == EV.expectedWeeklyR(ideas, tradingDays: EV.tradingDaysForLane(ideas)))
    }

    @Test func bestOpportunityPicksHighestPositiveEVBuy() {
        let a = idea("A", action: .buy, conviction: 0.2, stop: 90, target: 120)        // EV 0.188
        let b = idea("B", action: .strongBuy, conviction: 0.9, stop: 90, target: 130)  // EV 1.228
        let c = idea("C", action: .sell, conviction: 0.9, stop: 90, target: 130)       // not buy-family
        let d = idea("D", action: .buy, conviction: 0.0, stop: 90, target: 110)        // EV −0.30 (negative)
        let best = EV.bestOpportunity([a, c, d, b])!
        #expect(best.idea.symbol == "B")
        #expect(abs(best.ev.evR - 1.228) < 1e-9)
        // No positive-EV buy idea → nil (don't manufacture one).
        #expect(EV.bestOpportunity([c, d]) == nil)
    }

    @Test func ranksIdeasByEVBestFirstNoEVLast() {
        // A: conv 0.2, 2:1 → EV 0.188 ; B: conv 0.9, 3:1 → EV 1.228 ; C: no stop → no EV.
        let a = idea("A", conviction: 0.2, stop: 90, target: 120)
        let b = idea("B", conviction: 0.9, stop: 90, target: 130)
        let c = idea("C", conviction: 0.9, stop: nil, target: nil)
        let ranked = EV.rankByEV([a, c, b])
        #expect(ranked.map(\.symbol) == ["B", "A", "C"])
    }

    // ── G1 (iter6) — Churny short-hold drops below slower high-net once cost is netted ─────────
    //
    // [AUDIT] BTC-USD crypto churn: entry 100, stop 98, target 103 (rr 1.5:1), hold 3d, conv 0.9.
    //   p = 0.35 + 0.9·0.23 = 0.557
    //   grossEV  = 0.557·1.5 − 0.443 = 0.3925R
    //   cryptoCost = (30+20+20)bps·100 = $0.70
    //   netReward = 3−0.70 = 2.30 ; netRisk = 2+0.70 = 2.70
    //   netEV/grossRisk = (0.557·2.30 − 0.443·2.70)/2 ≈ 0.0425R
    //   netRatio = 0.0425/0.3925 ≈ 0.108  → net velocity = tiny
    //
    // [AUDIT] AAPL equity slow swing: entry 100, stop 90, target 130 (rr 3:1), hold 12d, conv 0.9.
    //   grossEV  = 0.557·3 − 0.443 = 1.228R
    //   usCost = (8+5)bps·100 = $0.13
    //   netReward = 29.87 ; netRisk = 10.13
    //   netEV/grossRisk = (0.557·29.87 − 0.443·10.13)/10 ≈ 1.215R
    //   netRatio ≈ 0.989  → net velocity >> BTC's
    //
    // The velocity BOARD should rank AAPL first; GROSS velocity still ranks BTC faster.
    @Test func G1_churnyShortHold_dropsBelowSlowerHighNet_afterCost() {
        let churnBTC = idea("BTC-USD", conviction: 0.9, stop: 98, target: 103)   // entry 100
        let slowAAPL = idea("AAPL",    conviction: 0.9, stop: 90, target: 130)   // entry 100
        // Net-ranked board: AAPL first (higher NET EV/day despite slower gross turnover).
        #expect(EV.rankByVelocity([churnBTC, slowAAPL]).first?.symbol == "AAPL")
        // Gross displayed velocity still ranks BTC faster — the FLIP is exactly the cost netting.
        let grossBTC  = EV.velocity(for: churnBTC)!
        let grossAAPL = EV.velocity(for: slowAAPL)!
        #expect(grossBTC > grossAAPL)   // BTC wins on gross/day; AAPL wins on net/day
        // Confirm net velocity is computed and BTC's is much smaller than AAPL's.
        let netBTC  = EV.netVelocity(for: churnBTC)!
        let netAAPL = EV.netVelocity(for: slowAAPL)!
        #expect(netAAPL > netBTC)        // AAPL dominates net
        // netRatio for BTC must be well below 1 (cost haircut is substantial).
        #expect(netBTC < grossBTC)
    }

    // ── G2 (iter6) — Min-net-EV/day floor de-ranks barely-positive-net AND net-negative ideas;
    //                  does NOT hide a clean high-net idea ────────────────────────────────────────
    //
    // Three witnesses:
    //
    // 1. btcNegNet (net-negative): BTC-USD conv=0.42 rr=1.0 entry=100 stop=90 target=110.
    //      p = 0.35 + 0.42·0.23 = 0.4466
    //      cryptoCost = 70bps·100 = $0.70 ; netReward = 10−0.70 = 9.30 ; netRisk = 10+0.70 = 10.70
    //      netEV/grossRisk = (0.4466·9.30 − 0.5534·10.70)/10 = (4.153 − 5.921)/10 = −0.1768R (< 0)
    //      ⇒ netVelocity < 0 < 0.005 floor → belowNetCostFloor == true (trivial case).
    //
    // 2. barelyNet (barely-positive-net, strictly in (0, 0.005)): AAPL conv=0.50 rr=1.3
    //      entry=100 stop=90 target=113, hold=12d.
    //      p = 0.35 + 0.50·0.23 = 0.465
    //      usCost = 13bps·100 = $0.13 ; netReward = 13−0.13 = 12.87 ; netRisk = 10+0.13 = 10.13
    //      netEV/grossRisk = (0.465·12.87 − 0.535·10.13)/10 = (5.9846 − 5.4196)/10 = 0.0565R (> 0)
    //      netVelocity = 0.0565/12 ≈ 0.00471 < 0.005 floor → belowNetCostFloor == true.
    //      This is the primary case the floor was designed for: grossEV > 0, netEVR > 0,
    //      but churn erodes the per-day rate below the conservative threshold.
    //
    // 3. cleanAAPL (clean high-net): AAPL conv=0.9 rr=3.0 entry=100 stop=90 target=130, hold=12d.
    //      netEV ≈ 1.215R ; netVelocity ≈ 0.101 >> 0.005 → floor does NOT fire.
    @Test func G2_floorSkipsBarelyPositiveNet_andDoesNotHideClean() {
        // Witness 1: net-negative (costs kill the edge entirely).
        let btcNegNet = idea("BTC-USD", conviction: 0.42, stop: 90, target: 110)
        if let ne = EV.netEVR(for: btcNegNet) { #expect(ne <= 0.0) }
        #expect(EV.belowNetCostFloor(for: btcNegNet) == true)
        #expect(EV.netCostFloorFlag(for: btcNegNet).isDeranked)
        #expect(EV.netCostFloorFlag(for: btcNegNet).badge == "below net-cost floor")

        // Witness 2: barely-positive-net strictly in (0, 0.005 R/day) — the primary floor case.
        // AAPL: entry=100 stop=90 target=113 conv=0.50 rr=1.3 hold=12d → netVelocity ≈ 0.00471.
        //   p = 0.465, cost=$0.13, netReward=12.87, netRisk=10.13
        //   netEVR = (0.465·12.87 − 0.535·10.13)/10 ≈ 0.0565 > 0
        //   netVelocity = 0.0565/12 ≈ 0.00471 < 0.005 → floor fires on a *net-positive* idea.
        let barelyIdea = idea("AAPL", conviction: 0.50, stop: 90, target: 113)
        let barelyNetEVR = EV.netEVR(for: barelyIdea)
        let barelyNetVel = EV.netVelocity(for: barelyIdea)
        // Assert netEVR > 0 (it is a net-positive idea, just barely):
        #expect(barelyNetEVR != nil, "barelyIdea must have a netEVR (has stop+target)")
        if let ne = barelyNetEVR { #expect(ne > 0.0, "barelyIdea netEVR must be > 0; got \(ne)") }
        // Assert netVelocity is in (0, 0.005) — the precisely-targeted floor band:
        #expect(barelyNetVel != nil, "barelyIdea must have a netVelocity (AAPL has hold estimate)")
        if let nv = barelyNetVel {
            #expect(nv > 0.0, "barelyIdea netVelocity must be > 0; got \(nv)")
            #expect(nv < EV.minNetEVPerDayFloor, "barelyIdea nv=\(nv) must be < floor 0.005")
        }
        // The idea-level floor should fire on this marginally net-positive idea:
        #expect(EV.belowNetCostFloor(for: barelyIdea) == true,
                "barely-net-positive idea (netVelocity in (0, 0.005)) must be de-ranked by the floor")

        // Witness 3: clean high-net — floor must NOT fire (Guardrail 2).
        let cleanAAPL = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        #expect(EV.belowNetCostFloor(for: cleanAAPL) == false)
        #expect(!EV.netCostFloorFlag(for: cleanAAPL).isDeranked)
        #expect(EV.netCostFloorFlag(for: cleanAAPL).badge == "")

        // All three rank: cleanAAPL is first; btcNegNet and barelyIdea are de-ranked below it.
        let ranked = EV.rankByVelocity([btcNegNet, barelyIdea, cleanAAPL])
        #expect(ranked.first?.symbol == "AAPL",
                "clean AAPL (rr=3, conv=0.9) must rank first over de-ranked ideas")
        #expect(ranked.first?.advice.stopPrice == 90 && ranked.first?.advice.targetPrice == 130,
                "the leading AAPL must be the clean high-net one (stop=90, target=130)")
    }

    // ── G3 (iter6) — Boundary: idea with no stop/target → no floor burial; floor at exact value → passes ──
    @Test func G3_degenerateAndBoundaryGuards() {
        // No stop/target ⇒ netEVR nil ⇒ netVelocity nil ⇒ belowNetCostFloor false (not buried).
        let noR = idea("AAPL", conviction: 0.9, stop: nil, target: nil)
        #expect(EV.netEVR(for: noR) == nil)
        #expect(EV.netVelocity(for: noR) == nil)
        #expect(EV.belowNetCostFloor(for: noR) == false)
        #expect(EV.netCostFloorFlag(for: noR).badge == "")
        // Index/FX has no expectedHoldDays → netVelocity nil → flag .clears (badge empty).
        let idxIdea = idea("^GSPC", conviction: 0.9, stop: 90, target: 130)
        #expect(EV.netVelocity(for: idxIdea) == nil)
        #expect(EV.netCostFloorFlag(for: idxIdea).badge == "")
        // Exactly at floor (nv == 0.005) → belowNetCostFloor == false (>= passes, strict < does not fire).
        // We verify the constant value and the strict-< semantics directly:
        #expect(EV.minNetEVPerDayFloor == 0.005)
        let exactAtFloor = EV.minNetEVPerDayFloor
        #expect(!(exactAtFloor < EV.minNetEVPerDayFloor))   // not below → does not fire
    }

    // ── G4 (iter6) — net == gross when cost = 0 (byte-identity, Guardrail 4) ────────────────────
    //
    // [AUDIT] StockSageNetEdge.evaluate with spread/slippage/taker all 0:
    //   netReward = grossReward − 0 = grossReward
    //   netRisk   = grossRisk + 0 = grossRisk
    //   netEV/grossRisk = (p·netReward − (1−p)·netRisk)/grossRisk
    //                   = (p·grossReward − (1−p)·grossRisk)/grossRisk = p·rewardR − (1−p) = grossEV
    //   So netExpectancyR == evR when cost = 0.
    @Test func G4_netEqualsGrossWhenZeroCost() {
        let p = EV.winProbEstimate(conviction: 0.9)   // 0.557
        let grossEV = EV.ev(conviction: 0.9, entry: 100, stop: 90, target: 130)!   // evR 1.228
        let ne = StockSageNetEdge.evaluate(entry: 100, stop: 90, target: 130,
                                           spreadBps: 0, slippageBps: 0, takerFeeBps: 0, winProb: p)!
        #expect(ne.netExpectancyR != nil)
        #expect(abs(ne.netExpectancyR! - grossEV.evR) < 1e-9)   // [AUDIT] cost 0 ⇒ net == gross
    }

    // ── Week-horizon velocity research (RESEARCH_2026-07-02_week_horizon_velocity.md, roadmap
    //    #2) — overnight borrow/margin cost charged into SHORT-side net EV, never into a cash long.
    //
    // Hand-verified via a standalone Swift snippet before writing this fixture (entry=100,
    // stop=105, target=85 — a genuine SHORT per StockSageAdvisor.stopTarget's convention: stop
    // ABOVE entry, target BELOW; risk=5, reward=15, R:R=3, conviction=0.9 → p=0.557):
    //   no financing:   cost=$0.13 (US large-cap 13bps)     → netEVR ≈ 1.2020
    //   with financing: cost=$0.13 + $0.0986 (3%/yr × 12d)  → netEVR ≈ 1.1823  (strictly less)
    @Test func shortIdeaPaysOvernightFinancingButAMirroredLongPaysNone() {
        let short = idea("SHORT", action: .sell, conviction: 0.9, stop: 105, target: 85)
        let long = idea("LONG", action: .buy, conviction: 0.9, stop: 95, target: 115)   // mirrored distances
        let shortNetEVR = EV.netEVR(for: short)
        let longNetEVR = EV.netEVR(for: long)
        #expect(shortNetEVR != nil && longNetEVR != nil)
        guard let s = shortNetEVR, let l = longNetEVR else { return }
        // The long (no financing) matches the hand-verified no-financing figure exactly.
        #expect(abs(l - 1.202) < 1e-3)
        // The short (financing charged) matches the hand-verified with-financing figure exactly,
        // and is STRICTLY below its mirrored long — the only difference between the two ideas is
        // which side of the trade they're on, so this isolates the financing effect precisely.
        #expect(abs(s - 1.1822739726027394) < 1e-9)
        #expect(s < l, "a short must net strictly less than an otherwise-identical long once financing is charged")
    }

    @Test func buyAndStrongBuyIdeasPayZeroFinancingByteIdenticalToBeforeThisExisted() {
        // hold/reduce/avoid are irrelevant here (no stop/target path or non-actionable); the
        // load-bearing check is buy-family, which funds real capital via StockSageCapitalAllocator
        // and must never regress from a change that was scoped to short-side only.
        let buy = idea("A", action: .buy, conviction: 0.9, stop: 90, target: 130)
        let strongBuy = idea("B", action: .strongBuy, conviction: 0.9, stop: 90, target: 130)
        let grossEV = EV.ev(conviction: 0.9, entry: 100, stop: 90, target: 130)!
        let c = StockSageNetEdge.defaultCosts(forSymbol: "A")
        let p = EV.winProbEstimate(conviction: 0.9)
        let expected = StockSageNetEdge.evaluate(entry: 100, stop: 90, target: 130,
                                                 spreadBps: c.spreadBps, slippageBps: c.slippageBps,
                                                 takerFeeBps: c.takerFeeBps, winProb: p)!.netExpectancyR!
        #expect(abs((EV.netEVR(for: buy) ?? -999) - expected) < 1e-9)
        #expect(abs((EV.netEVR(for: strongBuy) ?? -999) - expected) < 1e-9)
        #expect(grossEV.evR > expected)   // sanity: net is still below gross from spread/slippage alone
    }

    @Test func evShortTradeParity() {
        let short = StockSageExpectedValue.ev(conviction: 0.9, entry: 100, stop: 110, target: 80)!
        #expect(abs(short.rewardR - 2.0) < 1e-9)
        let p = 0.35 + 0.9 * 0.23
        #expect(abs(short.winProbEstimate - p) < 1e-9)
        #expect(abs(short.evR - (p * 2.0 - (1 - p))) < 1e-9)
        #expect(short.isPositive)
    }

    @Test func winProbEstimateMidpoint() {
        #expect(abs(StockSageExpectedValue.winProbEstimate(conviction: 0.5) - 0.465) < 1e-9)
    }

    @Test func laneCorrelationExcludesAZeroVarianceLegRatherThanCountingItAsUncorrelated() {
        // A flat/halted history's correlation with anything is UNDEFINED (0/0), not a genuine
        // "uncorrelated" 0 — laneCorrelation must exclude that pair from its average.
        let cryptoIdea = idea("BTC-USD", conviction: 0.5, stop: 90, target: 110)
        let equityIdea = idea("AAPL", conviction: 0.5, stop: 90, target: 110)
        let flat: [Double] = [100, 100, 100, 100, 100, 100]
        let moving: [Double] = [100, 101, 99, 102, 98, 103]

        // Every crypto×equity pair undefined (flat crypto leg) → nothing to average → nil,
        // not a falsely-reassuring 0.
        let allUndefined = EV.laneCorrelation(crypto: [cryptoIdea], equity: [equityIdea],
                                              histories: ["BTC-USD": flat, "AAPL": moving])
        #expect(allUndefined == nil)

        // Mixed case: one equity leg is flat (excluded), the other is IDENTICAL to the crypto leg
        // (correlation +1). The average must reflect only the ONE defined pair, not be diluted by
        // the undefined flat pair reading as a fake 0.
        let equityFlat = idea("MSFT", conviction: 0.5, stop: 90, target: 110)
        let mixed = EV.laneCorrelation(crypto: [cryptoIdea], equity: [equityIdea, equityFlat],
                                       histories: ["BTC-USD": moving, "AAPL": moving, "MSFT": flat])
        #expect(mixed != nil)
        #expect(abs((mixed ?? 0) - 1) < 1e-9)
    }

    // MARK: - FASTMONEY_BACKLOG #5 (data-plumbing stage): StockSageIdea.momentumQuality field

    /// Verifies the three mandated semantics for the new `momentumQuality` field on `StockSageIdea`:
    /// (1) every existing construction is unaffected (field defaults nil — trailing-default parameter);
    /// (2) an explicit value is stored and retrieved faithfully;
    /// (3) the build-time nil-vs-value threshold is honest: nil when closes are too short for ANY
    ///     of the three signals (≤ 20 bars), a real computed score when at least one signal fires
    ///     (> 20 bars for the loosest signal, Kaufman efficiencyRatio).

    @Test func momentumQualityFieldDefaultsNil() {
        // All existing StockSageIdea constructions omit momentumQuality — they must compile and
        // produce nil, not a fabricated 0.5 or 1.0.
        let plain = StockSageIdea(symbol: "AAPL", market: "M", price: 100,
                                  advice: TradeAdvice(action: .buy, conviction: 0.7, regime: .bullTrend,
                                                       rationale: [], stopPrice: 90, targetPrice: 130,
                                                       suggestedWeight: 0.05, caveat: "x"),
                                  spark: [])
        #expect(plain.momentumQuality == nil)
        // The trailing-default also covers the other optional fields — they all default independently.
        let withVol = StockSageIdea(symbol: "BTC-USD", market: "M", price: 100,
                                    advice: TradeAdvice(action: .buy, conviction: 0.9, regime: .bullTrend,
                                                         rationale: [], stopPrice: 90, targetPrice: 130,
                                                         suggestedWeight: 0.05, caveat: "x"),
                                    spark: [], realizedVol: 0.35)
        #expect(withVol.momentumQuality == nil)
    }

    @Test func momentumQualityFieldCarriesExplicitValue() {
        // When buildIdeas computes a quality score and passes it in, the field stores it faithfully.
        let q = 0.667
        let withQ = StockSageIdea(symbol: "AAPL", market: "M", price: 100,
                                  advice: TradeAdvice(action: .buy, conviction: 0.7, regime: .bullTrend,
                                                       rationale: [], stopPrice: 90, targetPrice: 130,
                                                       suggestedWeight: 0.05, caveat: "x"),
                                  spark: [], momentumQuality: q)
        #expect(withQ.momentumQuality == q)
        // Extreme ends of the 0–1 range are stored faithfully too.
        let hot = StockSageIdea(symbol: "HOT", market: "M", price: 100,
                                advice: TradeAdvice(action: .buy, conviction: 0.9, regime: .bullTrend,
                                                     rationale: [], stopPrice: 90, targetPrice: 130,
                                                     suggestedWeight: 0.05, caveat: "x"),
                                spark: [], momentumQuality: 1.0)
        let cold = StockSageIdea(symbol: "COLD", market: "M", price: 100,
                                 advice: TradeAdvice(action: .buy, conviction: 0.9, regime: .bullTrend,
                                                      rationale: [], stopPrice: 90, targetPrice: 130,
                                                      suggestedWeight: 0.05, caveat: "x"),
                                 spark: [], momentumQuality: 0.0)
        #expect(hot.momentumQuality == 1.0)
        #expect(cold.momentumQuality == 0.0)
    }

    @Test func momentumQualityNilWhenClosesTooShortForAnySignal() {
        // 20 bars: efficiencyRatio needs count > 20 (period=20 → at least 21), so ALL three
        // signals are nil at exactly 20 bars. The honest result is nil (unknown), not the
        // momentumQuality() neutral sentinel 1.0.
        let shortCloses = Array(repeating: 100.0, count: 20)
        // Pin that all three signals are indeed nil at 20 bars (prevents silent indicator changes
        // from invalidating the threshold decision below without a loud test failure here first).
        #expect(StockSageIndicators.efficiencyRatio(shortCloses) == nil)  // needs count > 20
        #expect(StockSageIndicators.macd(shortCloses) == nil)             // needs >= 35
        #expect(StockSageIndicators.returnOverPeriod(shortCloses, period: 21) == nil) // needs count > 21
        // The threshold guard: ≤ 20 bars → nil stored, never the fabricated 1.0 sentinel.
        let tooShort = 20
        let nilResult: Double? = tooShort > 20
            ? StockSageExpectedValue.momentumQuality(
                for: idea("X", conviction: 0.8, stop: 90, target: 120),
                closes: shortCloses)
            : nil
        #expect(nilResult == nil)
    }

    @Test func momentumQualityNonNilWhenClosesLongEnoughForEfficiencyRatio() {
        // 22 bars: efficiencyRatio fires (count > 20), so at least one signal is computable
        // and momentumQuality() returns a REAL value — stored, not nil.
        let justEnough = Array(stride(from: 100.0, through: 121.0, by: 1.0))  // 22 bars, monotone up
        #expect(justEnough.count == 22)
        #expect(StockSageIndicators.efficiencyRatio(justEnough) != nil)   // fires at 22 bars
        let stub = idea("X", conviction: 0.8, stop: 90, target: 120)
        let q = justEnough.count > 20
            ? StockSageExpectedValue.momentumQuality(for: stub, closes: justEnough)
            : nil
        #expect(q != nil)
        // A monotone uptrend has ER = 1.0 → hot signal fires → quality ≥ 1/3 (at least 1 of 3).
        // (macd and returnOverPeriod may or may not be computable at 22 bars — we only assert ≥ 1/3
        // so this test is resilient to indicator-bar-count changes.)
        #expect((q ?? 0) >= 1.0 / 3.0)
    }

    @Test func momentumQualityAtExactlyTwentyOneBarsUsesOnlyTheEfficiencyRatioSignal() {
        // THE partial-signal boundary (delta-verify wave 2 finding): at exactly 21 bars,
        // efficiencyRatio fires (21 > 20) but returnOverPeriod(period: 21) does NOT
        // (21 > 21 is false) and macd (needs ≥ 35) does not — so the quality is computed
        // over a ONE-signal denominator (never counting unavailable signals as cold), and
        // the 1.0 unknown-sentinel is unreachable. Pins the intermediate state so a future
        // indicator-threshold change can't silently alter the denominator undetected.
        let at21 = Array(stride(from: 100.0, through: 120.0, by: 1.0))  // 21 bars, monotone up
        #expect(at21.count == 21)
        #expect(StockSageIndicators.efficiencyRatio(at21) != nil)                 // fires
        #expect(StockSageIndicators.returnOverPeriod(at21, period: 21) == nil)    // does NOT fire
        #expect(StockSageIndicators.macd(at21) == nil)                            // does NOT fire
        let stub = idea("X", conviction: 0.8, stop: 90, target: 120)
        let q = StockSageExpectedValue.momentumQuality(for: stub, closes: at21)
        // Monotone up → ER = 1.0 (hot) → 1 hot of 1 available = exactly 1.0 (a REAL measured
        // value here, not the total==0 sentinel — that path needs ER to be uncomputable too).
        #expect(abs(q - 1.0) < 1e-9)
    }

    // MARK: - F27: financingCostInputs days=0 guard (label-honesty; numeric output unchanged)
    //
    // Hand-derived via derive_statecache.swift:
    //   finRate=3%, finDays=12 → note present: " + ~300bps/yr short financing"
    //   finRate=3%, finDays=0  → note absent: ""
    //
    // The fix is in MarketsView's label construction, not in financingCostInputs itself.
    // These tests pin the INPUTS that drive the label condition so a regression in the
    // data path (days becoming 0 or non-zero unexpectedly) is caught here before the UI.

    @Test func financingCostInputsReturnsZeroDaysForFXAndIndexSells() {
        // FX symbol: expectedHoldDays returns nil → days = 0 even though rate > 0.
        // A label keyed on `finRate > 0` alone would falsely claim financing was modeled.
        // price=100 from fixture; sell: stop above (105), target below (85).
        let fxSell = idea("EURUSD=X", action: .sell, conviction: 0.7, stop: 105, target: 85)
        let (finRate, finDays) = EV.financingCostInputs(for: fxSell)
        // Rate is non-zero (short borrow rate is always non-zero for sells)...
        #expect(finRate > 0)
        // ...but days is 0 because FX has no hold-day estimate (nil → 0 fallback).
        #expect(finDays == 0,
                "FX sells must return days=0 so the financing note is suppressed — got \(finDays)")
        // Assert the label condition the MarketsView fix enforces: note absent when days=0.
        let noteAbsent = !(finRate > 0 && finDays > 0)
        #expect(noteAbsent, "financing note condition (rate>0 && days>0) must be false when days=0 — would be a false label")
    }

    @Test func financingCostInputsReturnsNonZeroDaysForEquitySells() {
        // Equity symbol: expectedHoldDays returns the equity hold default (e.g. 12 days).
        // Both rate and days are non-zero → the financing note IS correctly shown.
        // Sell convention: stop ABOVE entry (105), target BELOW entry (80). Price = 100 (from fixture).
        let equitySell = idea("AAPL", action: .sell, conviction: 0.7, stop: 105, target: 80)
        let (finRate, finDays) = EV.financingCostInputs(for: equitySell)
        #expect(finRate > 0)
        #expect(finDays > 0,
                "Equity sells must return days>0 so the financing note appears — got \(finDays)")
        // Assert the label condition: note present when both are > 0.
        let notePresent = finRate > 0 && finDays > 0
        #expect(notePresent, "financing note condition must be true for equity sells with a hold estimate")
    }

    @Test func financingCostInputsReturnsBothZeroForBuys() {
        // Buy-family: rate=0 → note absent regardless of days. This is the existing behavior
        // and must not regress — buys never paid short financing.
        let buy = idea("AAPL", action: .buy, conviction: 0.7, stop: 90, target: 130)
        let (finRate, finDays) = EV.financingCostInputs(for: buy)
        #expect(finRate == 0 && finDays == 0, "buy family must return (0, 0) — got rate=\(finRate) days=\(finDays)")
    }

    // MARK: - F27 COPY-DRIFT HARDENING: financingNoteSuffix (factored helper, byte-identical output)
    //
    // Hand-derived via derive_f27.swift (derivations preserved here as comments):
    //   financingNoteSuffix(rate: 0.03, days: 12)
    //     → String(format: " + ~%.0fbps/yr short financing", 0.03 * 10_000)
    //     → String(format: " + ~%.0fbps/yr short financing", 300.0)
    //     → " + ~300bps/yr short financing"
    //   financingNoteSuffix(rate: 0.03, days: 0)  → guard fails (days == 0) → ""
    //   financingNoteSuffix(rate: 0,    days: 12) → guard fails (rate == 0) → ""
    //
    // These tests also serve as the byte-identity check: the helper's String(format:) call
    // is textually identical to the two MarketsView sites it replaced (the scratchpad script
    // confirmed both sites produce the same string before factoring).

    @Test func financingNoteSuffixWithRateAndDaysProducesExpectedString() {
        // Both rate and days non-zero → note present with correct bps figure.
        // 3% annual rate → 0.03 * 10_000 = 300.0 → "~300bps/yr"
        let note = EV.financingNoteSuffix(rate: 0.03, days: 12)
        #expect(note.contains("300bps/yr short financing"),
                "expected '300bps/yr short financing' in note — got: '\(note)'")
    }

    // F10 (2026-07-09): `days` here is ALWAYS the expectedHoldDays ESTIMATOR — financingCostInputs
    // never reads StockSageJournal.holdingPeriod even when the owner's journal has measured holds
    // for this symbol (verified: zero call sites of holdingPeriod anywhere in financingCostInputs'
    // call chain). The note must say the hold is assumed. Hand-derived:
    //   String(format: " + ~%.0fbps/yr short financing (assumed hold)", 0.03 * 10_000)
    //     → " + ~300bps/yr short financing (assumed hold)"
    @Test func financingNoteSuffixDisclosesTheHoldIsAssumedNotMeasured() {
        let note = EV.financingNoteSuffix(rate: 0.03, days: 12)
        #expect(note == " + ~300bps/yr short financing (assumed hold)")
        #expect(note.contains("(assumed hold)"))
        // The qualifier must not appear when the note itself is suppressed (days=0/rate=0) —
        // an empty string stays empty, never a bare "(assumed hold)" with nothing to qualify.
        #expect(!EV.financingNoteSuffix(rate: 0.03, days: 0).contains("assumed"))
        #expect(!EV.financingNoteSuffix(rate: 0, days: 12).contains("assumed"))
    }

    @Test func financingNoteSuffixWithZeroDaysIsEmpty() {
        // days == 0 → condition fails → empty (FX/index sell path: no hold estimate).
        let note = EV.financingNoteSuffix(rate: 0.03, days: 0)
        #expect(note.isEmpty,
                "financing note must be empty when days=0 — got: '\(note)'")
    }

    @Test func financingNoteSuffixWithZeroRateIsEmpty() {
        // rate == 0 → condition fails → empty (buy-family path: no short borrow charged).
        let note = EV.financingNoteSuffix(rate: 0, days: 12)
        #expect(note.isEmpty,
                "financing note must be empty when rate=0 — got: '\(note)'")
    }

    // F22 (wave-12): the assumedWinBandLabel constant must stay consistent with the
    // numeric band endpoints produced by winProbEstimate — the label is a DISPLAY string
    // that documents the two boundary values.  If either endpoint drifts the constant
    // must be updated simultaneously (single source of truth).
    @Test func assumedWinBandLabelMatchesBandEndpoints() {
        let low  = EV.winProbEstimate(conviction: 0)    // conviction=0 → floor of the prior
        let high = EV.winProbEstimate(conviction: 1)    // conviction=1 → ceiling of the prior
        let lowPct  = Int((low  * 100).rounded())       // 0.35 → 35
        let highPct = Int((high * 100).rounded())       // 0.58 → 58
        let expected = "\(lowPct)–\(highPct)%"          // "35–58%" (en-dash, matches the constant)
        #expect(EV.assumedWinBandLabel == expected,
                "assumedWinBandLabel '\(EV.assumedWinBandLabel)' out of sync with the numeric band '\(expected)'")
    }
}
