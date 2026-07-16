import Foundation

// MARK: - Expected value (the "what's the best BET" score)
//
// Signal strength ranks how confident the RULES are; expected value ranks how much
// you can EXPECT to make. EV (in R) = pWin·rewardR − (1−pWin)·1, where the loss is
// −1R (a stop-out) and rewardR is the reward:risk ratio. The catch: pWin is an
// ESTIMATE — the advisor's conviction is NOT a probability, so we map it into a
// deliberately conservative band and SAY it's an estimate. EV ranks opportunities
// by payoff, but it is not a promise; over-betting a positive-EV edge still ruins.

struct ExpectedValue: Sendable, Equatable {
    let winProbEstimate: Double   // 0–1, an ESTIMATE derived from conviction
    let rewardR: Double           // reward:risk
    let evR: Double               // expected R per trade
    nonisolated var isPositive: Bool { evR > 0 }
}

/// How concentrated the top fast-lane setups are by asset class — the honest check on
/// chasing velocity (which tends to crowd into one fast-turnover class, e.g. crypto).
struct FastLaneConcentration: Sendable, Equatable {
    let dominantClass: String
    let count: Int        // how many of the top-N are the dominant class
    let total: Int        // size of the top-N considered
    nonisolated var isConcentrated: Bool { total >= 2 && count == total }
}

/// Tunable per-asset-class holding-period assumptions feeding velocity (EV/day), so
/// the owner can match it to his real holding periods. Defaults equal the original
/// hardcoded values (crypto 3d, equity 12d) so nothing shifts silently.
struct VelocityHoldDays: Sendable, Equatable {
    var crypto: Double
    var equity: Double
    nonisolated static let defaults = VelocityHoldDays(crypto: 3, equity: 12)
}

/// One-glance money-velocity rollup for the top-of-Markets header. Every field is a
/// value computed by a dedicated, tested helper — this just gathers them.
struct MoneyVelocitySummary: Sendable, Equatable {
    let bestSymbol: String?       // highest positive-EV buy
    let bestEV: Double?
    let fastestSymbol: String?    // highest EV/day (fast lane)
    let fastestVelocity: Double?
    let weeklyR: Double?          // est. weekly R running the top setups (GROSS — see weeklyRNet)
    let weeklyRNet: Double?       // same, net of est. frictions (F03/F44: the decision-relevant headline)
    /// F9 (2026-07-09): GROSS weekly R summed over the EXACT SAME top-N basket `weeklyRNet` used
    /// (the earnings/liquidity-AWARE lane) — for the "net X (gross Y)" PAIRED display only. `weeklyR`
    /// deliberately stays basket-UNAWARE (trend-continuity contract with `VelocityHistory`, see
    /// MarketsView's onAppear .task comment) so a caller pairing it next to `weeklyRNet` could be
    /// showing two different top-3 baskets as if they were the same one — this field fixes exactly
    /// that display-string correctness bug, without touching `weeklyR`'s own recorded value, any
    /// rank key, or any gate/cost math. nil under the identical conditions `weeklyRNet` is nil.
    let weeklyRGrossSameBasket: Double?
    let weeklyTopCount: Int?      // how many setups the weekly figures actually sum (min(3, lane)) — the "top N" claim
    let worstRunLosses: Int?      // worst losing streak in the journal (the brake)
    let worstRunDrawdownPct: Double?  // that streak at the modeled risk % → account drawdown
    let riskFraction: Double      // the per-trade risk the drawdown brake was modeled at (so the label can't drift)
    nonisolated var hasContent: Bool { bestSymbol != nil || fastestSymbol != nil || weeklyR != nil }

    nonisolated init(bestSymbol: String? = nil, bestEV: Double? = nil, fastestSymbol: String? = nil,
                     fastestVelocity: Double? = nil, weeklyR: Double? = nil, weeklyRNet: Double? = nil,
                     weeklyRGrossSameBasket: Double? = nil,
                     weeklyTopCount: Int? = nil,
                     worstRunLosses: Int? = nil,
                     worstRunDrawdownPct: Double? = nil, riskFraction: Double = 0.01) {
        self.bestSymbol = bestSymbol; self.bestEV = bestEV; self.weeklyRNet = weeklyRNet
        self.weeklyRGrossSameBasket = weeklyRGrossSameBasket
        self.weeklyTopCount = weeklyTopCount
        self.fastestSymbol = fastestSymbol; self.fastestVelocity = fastestVelocity
        self.weeklyR = weeklyR; self.worstRunLosses = worstRunLosses
        self.worstRunDrawdownPct = worstRunDrawdownPct; self.riskFraction = riskFraction
    }
}

enum StockSageExpectedValue {
    // MARK: - Band display constant (F22)
    // Single source of truth for the assumed win-probability band displayed across the UI.
    // Derived directly from the linear prior: conviction=0 → 0.35, conviction=1 → 0.35+0.23=0.58.
    // Every display site that previously hardcoded "35-58%" or "35–58%" now interpolates this.
    nonisolated static let assumedWinBandLabel = "35–58%"

    /// Conviction (0–1) → an estimated win probability. With a `calibration` it returns that
    /// calibration's band value — HOW honest that number is depends on `calibration.method`
    /// (F43 2026-07-02: the old "MEASURED, conservative" claim here was false for two paths):
    ///   .isotonicWilson → measured from realized outcomes AND conservative (Wilson-LCB bins);
    ///   .beta           → measured + OOS-validated, but a CENTRAL fit, not a lower bound;
    ///   .platt          → a central MLE fit, NOT conservative;
    ///   .identity       → ASSUMED (winProb ≈ conviction, measured from zero outcomes).
    /// Without one it falls back to the conservative linear prior (0 → 35%, 1 → 58%). conviction
    /// is a signal-strength ordinal, NOT inherently a probability — only a real fit earns the
    /// right to treat it as one.
    nonisolated static func winProbEstimate(conviction: Double,
                                            calibration: StockSageConvictionCalibration? = nil) -> Double {
        if let calibration { return calibration.winProb(conviction) }
        return priorWinProb(conviction)
    }

    /// The conservative linear win-prob prior: conviction 0 → 35%, 1 → 58%. SINGLE SOURCE OF
    /// TRUTH — `winProbEstimate`'s no-calibration fallback AND the F01 thin-identity clamp
    /// (`StockSageConvictionCalibration.buildIdentity(clampToPrior:)`) both route through this,
    /// so the two can never drift (F46). Byte-identical to the former inline expression.
    nonisolated static func priorWinProb(_ conviction: Double) -> Double {
        0.35 + Swift.max(0, Swift.min(1, conviction)) * 0.23
    }

    /// Expected value in R: pWin·rewardR − (1−pWin)·1. nil if there's no defined
    /// risk or reward (entry==stop or no target). Pass `calibration` to size on a measured
    /// win rate instead of the linear prior.
    nonisolated static func ev(conviction: Double, entry: Double, stop: Double, target: Double,
                               calibration: StockSageConvictionCalibration? = nil) -> ExpectedValue? {
        let risk = abs(entry - stop), reward = abs(target - entry)
        guard risk > 0, reward > 0 else { return nil }
        // Cap reward:risk at a sane ceiling. A hair-thin stop (risk → 0) otherwise makes rewardR
        // unbounded, which overruns the FIXED regime/cost/conviction demotion constants in the rank
        // key (−1_000_000 / −500_000 / −1000) and lets a BANNED side rank #1. No real setup exceeds
        // 50:1 reward:risk; beyond it the stop is degenerate, not a genuine edge.
        let rewardR = Swift.min(reward / risk, 50)
        let p = winProbEstimate(conviction: conviction, calibration: calibration)
        return ExpectedValue(winProbEstimate: p, rewardR: rewardR, evR: p * rewardR - (1 - p))
    }

    /// Canonical user-facing warning line for the money-velocity concentration risk. Keeping this
    /// in one helper prevents wording drift between cards/copy paths while preserving identical
    /// warning semantics (`isConcentrated` over top-N fast-lane setups).
    nonisolated static func moneyVelocityConcentrationWarning(_ concentration: FastLaneConcentration?) -> String? {
        guard let concentration, concentration.isConcentrated else { return nil }
        return "⚠︎ Fast lane is concentrated — your top \(concentration.total) fastest are all \(concentration.dominantClass); that's closer to one bet, not \(concentration.total). Diversify or size them as one."
    }

    /// Typical hold in days by asset class — crypto turns over fast (24/7), equities
    /// swing. nil for index/FX (not traded for velocity here). A rough default, not
    /// a per-symbol measurement.
    nonisolated static func expectedHoldDays(forSymbol symbol: String, holds: VelocityHoldDays = .defaults) -> Double? {
        switch StockSageAllocation.assetClass(symbol) {
        case "Crypto": return holds.crypto
        case "Equity": return holds.equity
        default: return nil
        }
    }

    /// SETUP-derived expected hold: distance-to-target ÷ the name's typical daily move (from its
    /// recent sparkline). A NEARER target turns over faster than a far one of equal EV — the real
    /// driver of compounding cadence, which a single per-class constant is blind to. Falls back to
    /// the asset-class default when the target or a daily-move estimate is missing, and is clamped
    /// to a sane band around that default so a noisy spark can't yield a 0.1-day or 500-day fantasy.
    /// nil for classes not ranked for velocity (index/FX) — unchanged.
    nonisolated static func expectedHoldDays(for idea: StockSageIdea, holds: VelocityHoldDays = .defaults) -> Double? {
        guard let base = expectedHoldDays(forSymbol: idea.symbol, holds: holds) else { return nil }
        // Prefer the TRUE daily move (raw closes); fall back to the spark (≈2-day spacing, so only
        // used for ideas built without dailyMove, e.g. tests) — never derive a "daily" move from the
        // down-sampled spark when the real one is available, which would halve the hold (2× velocity).
        guard let target = idea.advice.targetPrice, idea.price > 0,
              let daily = idea.dailyMove ?? typicalDailyMove(idea.spark), daily > 0 else { return base }
        let dist = abs(target - idea.price)
        guard dist > 0 else { return base }
        return Swift.max(base * 0.4, Swift.min(base * 3, dist / daily))
    }

    /// Typical one-day move = average absolute close-to-close change of a sparkline. nil if too short.
    nonisolated static func typicalDailyMove(_ spark: [Double]) -> Double? {
        guard spark.count >= 3 else { return nil }
        var sum = 0.0
        for i in 1..<spark.count { sum += abs(spark[i] - spark[i - 1]) }
        let avg = sum / Double(spark.count - 1)
        return avg > 0 ? avg : nil
    }

    /// Velocity = EV ÷ expected hold = expected R PER DAY, so a fast-turnover setup
    /// beats a slow swing of equal EV (more compounding cycles). nil if no EV or no
    /// hold estimate. An estimate on an estimate — the UI says so.
    nonisolated static func velocity(for idea: StockSageIdea, holds: VelocityHoldDays = .defaults,
                                     calibration: StockSageConvictionCalibration? = nil) -> Double? {
        guard let e = ev(for: idea, calibration: calibration),
              let hold = expectedHoldDays(for: idea, holds: holds), hold > 0 else { return nil }
        return e.evR / hold
    }

    /// Ideas ranked by velocity (EV/day) desc; ideas without a velocity fall last (stable).
    /// A near-zero-CONVICTION idea with a fantasy wide target inflates EV (winProb only
    /// spans 35–58%, but reward:risk is unbounded), so it could out-rank a REAL
    /// high-conviction setup. These RANKING keys down-weight by conviction (mirroring the
    /// advisor's 0.4+0.6 size scaler) and demote anything below the conviction floor — so a
    /// junk idea can never top the board. The DISPLAYED EV/velocity stays the raw estimate.
    nonisolated static let minConvictionToRank = 0.40
    private nonisolated static func qualityWeight(_ conviction: Double) -> Double {
        0.4 + 0.6 * Swift.max(0, Swift.min(1, conviction))
    }

    /// Named, testable mirror of the exact `idea.advice.conviction < minConvictionToRank`
    /// comparison every rank-key function above already applies internally — so a caller OUTSIDE
    /// the ranking math (e.g. `StockSageTodayPlan.TodayActionPlan`) can check the same demotion
    /// condition without duplicating the threshold or risking it drifting out of sync.
    nonisolated static func isLowConviction(_ idea: StockSageIdea) -> Bool {
        idea.advice.conviction < minConvictionToRank
    }
    /// Quality-adjusted EV — the ranking key (the raw `ev` is still shown to the user).
    nonisolated static func qualityAdjustedEVR(for idea: StockSageIdea,
                                               calibration: StockSageConvictionCalibration? = nil) -> Double? {
        ev(for: idea, calibration: calibration).map { $0.evR * qualityWeight(idea.advice.conviction) }
    }

    /// Expected per-CYCLE log-growth at half-Kelly — the growth-rate-optimal objective. Arithmetic
    /// EV (p·R − (1−p)) is variance-blind: it over-ranks high-R, low-probability lottery setups,
    /// whose −1 outcome at a meaningful bet fraction craters compound growth. Log-growth
    /// (E[ln(1 + f·outcome)] at f = half-Kelly) penalizes that, so ranking by it favors steady
    /// compounders — exactly "make money fastest" = maximize growth RATE, not arithmetic expectancy.
    /// 0 when there's no positive-edge bet.
    nonisolated static func expectedLogGrowth(winProb: Double, rewardR: Double) -> Double {
        let w = Swift.max(0, Swift.min(1, winProb))
        let r = Swift.max(0.0001, rewardR)
        let f = Swift.max(0, Swift.min(0.5, (w - (1 - w) / r) / 2))   // half-Kelly risk fraction, capped
        guard f > 0 else { return 0 }
        let up = 1 + f * r, down = 1 - f
        guard up > 0, down > 0 else { return 0 }
        return w * Foundation.log(up) + (1 - w) * Foundation.log(down)
    }
    /// Overnight borrow/margin cost inputs for `StockSageNetEdge.evaluate`'s `annualFinancingRate`/
    /// `holdDays` params. A cash LONG owns the shares outright and pays nothing (0, 0, byte-
    /// identical to before this existed). A sell/reduce idea is a genuine SHORT-side plan
    /// (`StockSageAdvisor.stopTarget`'s stop-above/target-below construction) and is definitionally
    /// a margin transaction — it pays `defaultShortBorrowRate` for every day it's expected to be
    /// held. Week-horizon research (RESEARCH_2026-07-02_week_horizon_velocity.md, roadmap #2):
    /// "overnight borrow/margin costs charged into short-side... EV." Not private: MarketsView's
    /// own net-cost displays (detail sheet, "Copy plan") reuse this so they can never show a
    /// different net figure than the one actually driving the idea's rank/velocity.
    nonisolated static func financingCostInputs(for idea: StockSageIdea) -> (rate: Double, days: Double) {
        guard idea.advice.action == .sell || idea.advice.action == .reduce else { return (0, 0) }
        return (StockSageNetEdge.defaultShortBorrowRate, expectedHoldDays(for: idea) ?? 0)
    }

    /// F27: single source of truth for the financing-cost note appended to net-cost display strings.
    /// Returns " + ~NNNbps/yr short financing (assumed hold)" when BOTH rate > 0 AND days > 0;
    /// otherwise "". Keyed on BOTH conditions: rate > 0 alone would falsely claim financing was
    /// modeled for FX/index sells whose expectedHoldDays returns nil → 0 (no hold estimate → $0
    /// financing). F10 (2026-07-09): `days` is ALWAYS `expectedHoldDays(for:)`'s tuned per-class
    /// estimator (crypto 3d/equity 12d, target-distance adjusted) — it never reads the owner's OWN
    /// measured holds (`StockSageJournal.holdingPeriod`), even when the journal has them. The
    /// "(assumed hold)" qualifier says so, matching the honesty floor's "estimates labeled
    /// assumed". Disclosure-only: `days` itself is untouched here — swapping in a measured hold
    /// would change `netEVR`/`clearsCostAfterFrictions`/`velocityRankKey` (ranking-adjacent), not
    /// just this string.
    nonisolated static func financingNoteSuffix(rate: Double, days: Double) -> String {
        (rate > 0 && days > 0) ? String(format: " + ~%.0fbps/yr short financing (assumed hold)", rate * 10_000) : ""
    }

    /// Does the idea's conviction-mapped win prob clear its AFTER-COST break-even? A thin,
    /// high-cost flip can be positive-EV on paper yet net-negative once frictions are paid.
    /// No defined R (no stop/target) ⇒ treated as clearing (don't demote — unchanged).
    private nonisolated static func clearsCostAfterFrictions(_ idea: StockSageIdea,
                                                             calibration: StockSageConvictionCalibration? = nil) -> Bool {
        guard let stop = idea.advice.stopPrice, let target = idea.advice.targetPrice else { return true }
        let c = StockSageNetEdge.defaultCosts(forSymbol: idea.symbol)
        let (rate, days) = financingCostInputs(for: idea)
        guard let ne = StockSageNetEdge.evaluate(entry: idea.price, stop: stop, target: target,
                                                 spreadBps: c.spreadBps, slippageBps: c.slippageBps,
                                                 takerFeeBps: c.takerFeeBps,
                                                 annualFinancingRate: rate, holdDays: days) else { return true }
        // Gate on the SAME win prob the EV/ranking uses (calibrated when fitted) — not the linear prior,
        // which would demote-for-cost on a different probability than the one shown.
        return ne.clearsCost(estWinProb: winProbEstimate(conviction: idea.advice.conviction, calibration: calibration))
    }

    // ── [AUDIT] Net-of-cost EV/day velocity helpers (iter6) ──────────────────────────────────────
    //
    // These five helpers (constant + 3 functions + enum) are the ONLY new surface from iter6.
    // They reuse StockSageNetEdge.evaluate(...).netExpectancyR — the existing net-edge model —
    // so cost is subtracted from EV BEFORE the /hold_days, replacing the binary pass/fail gate.
    // All are nonisolated + Sendable; nil only on no-defined-R (same guard as ev(for:)).

    /// [AUDIT] Minimum NET-of-cost EV/day to surface an idea as a buy on the velocity board.
    /// 0.005R/day = +0.5% of 1R per day. Justification (conservative, honestly chosen):
    ///   • A retail account risking 1%/trade earns 0.005R/day ≈ 0.005% of equity/day on that
    ///     slot — at ~250 trading days that is ~1.25R/yr of pure edge AFTER frictions, the floor
    ///     below which a slot is "dead money" the churn (Barber&Odean −7.1pp/yr) overwhelms.
    ///   • Set on the NET (post-cost) per-day rate, NOT gross, so it bites exactly the
    ///     churny-short-hold ideas the gross sort over-ranks.
    ///   • Deliberately LOW (not a profitability hurdle) so it only skips barely-positive
    ///     dregs — must NOT hide a genuinely high-net idea (Guardrail 2). A slow high-net
    ///     swing clears it by orders of magnitude.
    nonisolated static let minNetEVPerDayFloor = 0.005

    /// [AUDIT] NET-of-cost expected R for an idea: round-trip frictions (spread+slippage+taker,
    /// from StockSageNetEdge.defaultCosts) subtracted from the reward AND added to the risk via
    /// StockSageNetEdge.evaluate(...).netExpectancyR — the EXISTING net edge model, not a new one.
    /// Win prob is the SAME conviction-mapped (calibrated) estimate the gross EV uses, so net and
    /// gross are computed on one probability. nil when there's no defined R (no stop/target) OR the
    /// gross setup is degenerate — the only nil-fallback path.
    nonisolated static func netEVR(for idea: StockSageIdea,
                                   calibration: StockSageConvictionCalibration? = nil) -> Double? {
        guard let stop = idea.advice.stopPrice, let target = idea.advice.targetPrice else { return nil }
        let c = StockSageNetEdge.defaultCosts(forSymbol: idea.symbol)
        let p = winProbEstimate(conviction: idea.advice.conviction, calibration: calibration)
        let (rate, days) = financingCostInputs(for: idea)
        return StockSageNetEdge.evaluate(entry: idea.price, stop: stop, target: target,
                                         spreadBps: c.spreadBps, slippageBps: c.slippageBps,
                                         takerFeeBps: c.takerFeeBps,
                                         annualFinancingRate: rate, holdDays: days, winProb: p)?.netExpectancyR
    }

    /// [AUDIT] NET EV/day = net-of-cost EV ÷ expected hold. The honest velocity rate after frictions.
    /// nil when there's no net EV or no hold estimate (index/FX). When cost data nets to nothing
    /// (cost == 0) this equals the gross velocity exactly (Guardrail 4: net==gross when cost=0).
    nonisolated static func netVelocity(for idea: StockSageIdea, holds: VelocityHoldDays = .defaults,
                                        calibration: StockSageConvictionCalibration? = nil) -> Double? {
        guard let ne = netEVR(for: idea, calibration: calibration),
              let hold = expectedHoldDays(for: idea, holds: holds), hold > 0 else { return nil }   // [AUDIT] hold→0 guarded
        return ne / hold
    }

    /// [AUDIT] Is the idea's NET EV/day strictly below the floor? At-floor (==) counts as PASSING
    /// (>= floor) — "below" means strictly under. Ideas with no net velocity (no R / no hold) are
    /// treated as not-below (nil ⇒ the gross path's nil handling already sinks them last; this
    /// floor never resurrects nor newly-buries a nil-key idea).
    nonisolated static func belowNetCostFloor(for idea: StockSageIdea, holds: VelocityHoldDays = .defaults,
                                              calibration: StockSageConvictionCalibration? = nil) -> Bool {
        guard let nv = netVelocity(for: idea, holds: holds, calibration: calibration) else { return false }
        return nv < minNetEVPerDayFloor   // [AUDIT] exactly-at-floor → false (passes)
    }

    /// [AUDIT] Legible companion to the floor de-rank, mirroring earningsRankFlag's pattern so the
    /// on-card badge can never disagree with the actual rank shift. `.belowFloor` fires EXACTLY when
    /// belowNetCostFloor is true.
    enum NetCostFloorFlag: Sendable, Equatable {
        case belowFloor(netVelocity: Double)   // de-ranked: net EV/day under the floor
        case clears                            // at/above floor (or no defined net velocity)
        nonisolated var isDeranked: Bool { if case .belowFloor = self { return true }; return false }
        var badge: String {
            if case .belowFloor = self { return "below net-cost floor" }
            return ""
        }
    }

    nonisolated static func netCostFloorFlag(for idea: StockSageIdea, holds: VelocityHoldDays = .defaults,
                                             calibration: StockSageConvictionCalibration? = nil) -> NetCostFloorFlag {
        guard let nv = netVelocity(for: idea, holds: holds, calibration: calibration),
              nv < minNetEVPerDayFloor else { return .clears }
        return .belowFloor(netVelocity: nv)
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// Imminent-earnings (binary-event) demotion for the rank keys. ONLY a real fetched `.imminent`
    /// date (≤3 days) is penalized — an UNKNOWN symbol (no map entry) and `.soon`/`.clear` return 0,
    /// so absence is never assumed dangerous (only-real-data). 2000 sits above the conviction band
    /// (1000) and the max base EV (~28.6) but below the cost (500k) and regime (1M) bands — so an
    /// imminent-earnings idea sinks below every clean same-or-lower-EV peer, yet still ranks above a
    /// cost-failed or regime-banned one. The DISPLAYED EV/velocity never changes — only the rank key.
    /// Rationale: a protective stop is an intraday promise an overnight earnings gap opens through;
    /// ranking such an idea #1 the night before it reports puts the biggest position where the stop
    /// is least likely to hold. The per-idea EarningsProximity.note stays the load-bearing disclosure.
    nonisolated static func earningsRankPenalty(for idea: StockSageIdea,
                                                earnings: [String: EarningsProximity]) -> Double {
        guard let prox = earnings[idea.symbol.uppercased()] else { return 0 }   // unknown → not penalized
        return prox.severity == .imminent ? 2000 : 0
    }

    /// Thin-liquidity demotion for the rank keys. 3000 sits above the earnings-imminent band
    /// (2000) — a name your own order moves is a worse risk than a name that merely has an
    /// event coming — but far below the cost (500k) and regime (1M) bands, so a thin name still
    /// outranks a cost-failed or regime-banned one. No entry (FX/indices report no real share
    /// volume, or the symbol hasn't been priced yet) → 0, only-real-data. Moderate/deep → 0.
    /// The DISPLAYED EV/velocity never changes — only the rank key. The per-idea
    /// LiquidityProfile.note stays the load-bearing slippage disclosure.
    nonisolated static func liquidityRankPenalty(for idea: StockSageIdea,
                                                 liquidity: [String: LiquidityProfile]) -> Double {
        guard let profile = liquidity[idea.symbol.uppercased()] else { return 0 }
        return profile.tier == .thin ? 3000 : 0
    }

    /// Why an idea sits where it does on the earnings-aware board — the legible companion to
    /// earningsRankPenalty, so the silent re-order shows its reason. Reads the SAME cached
    /// EarningsProximity (no Date math, no network). `isDemoted` mirrors `earningsRankPenalty > 0` exactly,
    /// so the on-card badge can never disagree with the actual rank shift.
    enum EarningsRankFlag: Sendable, Equatable {
        case demoted(daysUntil: Int)      // .imminent (≤3d) — the penalized, ranked-down case
        case approaching(daysUntil: Int)  // .soon (≤10d) — event risk nearing, not yet penalized
        case clear(daysUntil: Int)        // .clear (>10d) — no immediate event risk
        case unknown                      // no fetched date (or not equity) — never assumed dangerous

        var isDemoted: Bool { if case .demoted = self { return true }; return false }
        /// Short on-card badge; empty for the quiet clear/unknown cases (nothing to surface).
        var badge: String {
            switch self {
            case .demoted(let d):     return "⚠︎ earnings ~\(d)d"
            case .approaching(let d): return "earnings ~\(d)d"
            case .clear, .unknown:    return ""
            }
        }
    }

    nonisolated static func earningsRankFlag(for idea: StockSageIdea,
                                             earnings: [String: EarningsProximity]) -> EarningsRankFlag {
        guard let prox = earnings[idea.symbol.uppercased()] else { return .unknown }
        switch prox.severity {
        case .imminent: return .demoted(daysUntil: prox.daysUntil)
        case .soon:     return .approaching(daysUntil: prox.daysUntil)
        case .clear:    return .clear(daysUntil: prox.daysUntil)
        }
    }

    private nonisolated static func evRankKey(for idea: StockSageIdea,
                                              calibration: StockSageConvictionCalibration? = nil) -> Double? {
        guard let base = qualityAdjustedEVR(for: idea, calibration: calibration) else { return nil }
        // Continuous net-cost ratio: matches velocityRankKey's pattern so EV ranking
        // and velocity ranking are consistent — a barely-clears-cost setup scales lower
        // than a strongly-clears one, instead of tying on the binary gate alone.
        // NOTE: when `netEVR` returns nil (degenerate setup where `StockSageNetEdge.evaluate`
        // can't compute a net edge, e.g. zero reward/risk — guarded separately by the `evR>0`
        // check above), `netRatio` defaults to 1 (treat unknown net as full gross). This is
        // intentionally optimistic for the nil path, which is only reachable on degenerate
        // inputs that the upstream `ev(for:)` guard (`risk>0, reward>0`) already excludes.
        // If `evaluate` failures become observable in production, this fallback should be
        // re-evaluated (conservative → 0 would silently de-rank valid ideas; optimistic → 1
        // preserves pre-cost ranking for setups whose net-cost can't be computed).
        let netRatio: Double = {
            guard let e = ev(for: idea, calibration: calibration), e.evR > 0 else { return 1 }
            guard let ne = netEVR(for: idea, calibration: calibration) else { return 1 }
            return Swift.max(0, Swift.min(1, ne / e.evR))   // net≤0 → 0, net>gross → cap 1
        }()
        var key = base * netRatio
        if idea.advice.conviction < minConvictionToRank { key -= 1000 }       // low-conviction band
        if !clearsCostAfterFrictions(idea, calibration: calibration) { key -= 500_000 }   // costs eat the edge → below clean setups
        return key
    }

    // Regime gate: don't crown a BUY in a crisis/bear tape, or a SHORT in a bull. A banned side
    // is demoted by 1_000_000 (an order of magnitude past the conviction band) so it always ranks
    // below every non-banned idea. The DISPLAYED EV never changes — only the ranking key.
    private enum RankSide { case buyFamily, sellFamily, neutral }
    private nonisolated static func side(_ idea: StockSageIdea) -> RankSide {
        switch idea.advice.action {
        case .buy, .strongBuy: return .buyFamily
        case .sell, .reduce:   return .sellFamily
        case .hold, .avoid:    return .neutral
        }
    }
    private nonisolated static func bannedFromTopRank(_ s: RankSide, regime: MarketRegime.State) -> Bool {
        switch regime {
        case .crisis, .trendingBear:                            // no BUY ranks #1 in a risk-off tape
            if case .buyFamily = s { return true }; return false
        case .trendingBull:                                     // no SHORT ranks #1 in a bull
            if case .sellFamily = s { return true }; return false
        case .ranging:               return false               // neutral regime gates nothing
        }
    }
    private nonisolated static func regimeAdjustedEVRankKey(for idea: StockSageIdea, regime: MarketRegime?,
                                                            calibration: StockSageConvictionCalibration? = nil) -> Double? {
        guard let base = evRankKey(for: idea, calibration: calibration) else { return nil }   // nil-EV ideas still fall last
        guard let r = regime else { return base }                   // nil regime → IDENTICAL to today
        return bannedFromTopRank(side(idea), regime: r.state) ? base - 1_000_000 : base
    }
    private nonisolated static func velocityRankKey(for idea: StockSageIdea, holds: VelocityHoldDays,
                                                    calibration: StockSageConvictionCalibration? = nil) -> Double? {
        // Velocity is the BUY-side compounding lane (matches bestOpportunity / CapitalAllocator) —
        // a short does not compound the same way, so only buy-family ideas qualify. (Fixes a short
        // topping the Fast Lane while it is correctly barred from the best-opportunity card.)
        guard case .buyFamily = side(idea) else { return nil }
        // Rank by per-DAY LOG-GROWTH (growth-rate-optimal), not arithmetic EV/day — so a steady
        // compounder beats a high-variance lottery setup of equal raw EV. Displayed velocity is
        // still EV/day; this is only the ordering key.
        guard let e = ev(for: idea, calibration: calibration),
              let hold = expectedHoldDays(for: idea, holds: holds), hold > 0 else { return nil }
        // [AUDIT] NET-of-cost ordering (iter6): rank by per-day log-growth scaled by the NET/gross
        // EV ratio, so round-trip frictions (StockSageNetEdge) shrink the rate CONTINUOUSLY —
        // a churny flip whose gross EV survives but whose NET EV is thin now sorts BELOW a slower
        // high-net idea, instead of keeping its full gross velocity behind a binary pass/fail.
        // Log-growth stays the growth-rate-optimal core; the net ratio is the cost haircut.
        let grossLG = expectedLogGrowth(winProb: e.winProbEstimate, rewardR: e.rewardR)
        let netRatio: Double = {                                  // [AUDIT] net EV ÷ gross EV, clamped ≥ 0
            guard let ne = netEVR(for: idea, calibration: calibration), e.evR > 0 else { return 1 }  // [AUDIT] no net data ⇒ ratio 1 (=gross)
            return Swift.max(0, ne / e.evR)                       // [AUDIT] net≤0 ⇒ ratio 0 ⇒ key 0 (below every +rate peer)
        }()
        let v = grossLG * netRatio / hold                         // [AUDIT] PROXY for net per-day log-growth: gross log-growth scaled by netEV/grossEV arithmetic-cost haircut (not true net log-growth, but correct for ranking).
        // [AUDIT] Min net-EV/day FLOOR: a barely-positive-gross churn idea whose NET EV/day is
        // under the floor is de-ranked below clean setups (−500_000) so it cannot top the board.
        // The old clearsCostAfterFrictions binary gate is SUBSUMED: anything net≤0 has ratio=0
        // ⇒ key=0, and the floor (< 0.005) then adds the −500_000 de-rank. Nothing previously
        // demoted is resurrected. Honest companion label via netCostFloorFlag(for:).
        if belowNetCostFloor(for: idea, holds: holds, calibration: calibration) { return v - 500_000 }
        return idea.advice.conviction >= minConvictionToRank ? v : v - 1000
    }

    nonisolated static func rankByVelocity(_ ideas: [StockSageIdea], holds: VelocityHoldDays = .defaults,
                                           earnings: [String: EarningsProximity] = [:],
                                           liquidity: [String: LiquidityProfile] = [:],
                                           calibration: StockSageConvictionCalibration? = nil) -> [StockSageIdea] {
        // Demote imminent-earnings + thin-liquidity ideas inside the velocity key
        // (both empty → 0 penalty → unchanged order).
        func key(_ idea: StockSageIdea) -> Double? {
            velocityRankKey(for: idea, holds: holds, calibration: calibration).map {
                $0 - earningsRankPenalty(for: idea, earnings: earnings) - liquidityRankPenalty(for: idea, liquidity: liquidity)
            }
        }
        // F12: decorate-sort-undecorate — key() (a full EV + NetEdge evaluation) is computed ONCE
        // per idea instead of twice per comparison. key() is pure & deterministic and the comparator
        // logic (incl. the offset tie-break, a strict weak ordering) is unchanged → order identical.
        // (Explicitly-typed statements, not one chained tuple expression — type-checker budget.)
        var decorated: [(offset: Int, idea: StockSageIdea, key: Double?)] = []
        decorated.reserveCapacity(ideas.count)
        for (offset, idea) in ideas.enumerated() {
            decorated.append((offset: offset, idea: idea, key: key(idea)))
        }
        decorated.sort { a, b in
            switch (a.key, b.key) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x > y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }
        return decorated.map(\.idea)
    }

    /// EV for a ranked idea, or nil when it lacks a stop/target (no defined R:R).
    nonisolated static func ev(for idea: StockSageIdea,
                               calibration: StockSageConvictionCalibration? = nil) -> ExpectedValue? {
        guard let stop = idea.advice.stopPrice, let target = idea.advice.targetPrice else { return nil }
        return ev(conviction: idea.advice.conviction, entry: idea.price, stop: stop, target: target,
                  calibration: calibration)
    }

    /// Why `ev(for:)` is nil for this idea — the legible companion to rankByEV/rankByVelocity's
    /// nil-key stable-sort, so a board can show "Ranked: N · Incomplete: M" instead of silently
    /// rendering fewer names than the full ideas count with no explanation. nil when the idea
    /// DOES have a defined EV (nothing to explain). Additive — does not change ranking/sorting.
    enum EvSkipReason: Sendable, Equatable {
        case noStop
        case noTarget
        case noStopOrTarget

        nonisolated var label: String {
            switch self {
            case .noStop:         return "no stop"
            case .noTarget:       return "no target"
            case .noStopOrTarget: return "no stop or target"
            }
        }
    }
    nonisolated static func evSkipReason(for idea: StockSageIdea) -> EvSkipReason? {
        switch (idea.advice.stopPrice, idea.advice.targetPrice) {
        case (nil, nil): return .noStopOrTarget
        case (nil, _?):  return .noStop
        case (_?, nil):  return .noTarget
        case (_?, _?):   return nil
        }
    }

    /// Ideas sorted by EV (best bet first). Ideas without a defined EV fall to the
    /// bottom keeping their original relative order (stable).
    nonisolated static func rankByEV(_ ideas: [StockSageIdea], regime: MarketRegime? = nil,
                                     earnings: [String: EarningsProximity] = [:],
                                     liquidity: [String: LiquidityProfile] = [:],
                                     seasonality: [String: MonthlySeasonality] = [:],
                                     calibration: StockSageConvictionCalibration? = nil) -> [StockSageIdea] {
        // Demote imminent-earnings + thin-liquidity ideas inside the EV key
        // (both empty → 0 penalty → unchanged order).
        func key(_ idea: StockSageIdea) -> Double? {
            regimeAdjustedEVRankKey(for: idea, regime: regime, calibration: calibration).map {
                $0 - earningsRankPenalty(for: idea, earnings: earnings)
                   - liquidityRankPenalty(for: idea, liquidity: liquidity)
                   + seasonalityRankBonus(for: idea, seasonality: seasonality)
            }
        }
        // F12: decorate-sort-undecorate — same rationale as rankByVelocity (key computed once per
        // idea, comparator + tie-breaks unchanged → behavior-identical order).
        // (Explicitly-typed statements, not one chained tuple expression — type-checker budget.)
        var decorated: [(offset: Int, idea: StockSageIdea, key: Double?)] = []
        decorated.reserveCapacity(ideas.count)
        for (offset, idea) in ideas.enumerated() {
            decorated.append((offset: offset, idea: idea, key: key(idea)))
        }
        decorated.sort { a, b in
            switch (a.key, b.key) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x > y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }
        return decorated.map(\.idea)
    }

    /// The single best BET right now: the buy-family idea with the highest POSITIVE
    /// expected value (or, when `preferVelocity` is on, the highest EV/day). nil if no
    /// buy idea has positive EV (don't manufacture one).
    ///
    /// RANKING_BACKLOG #10: today's default ranks by `qualityAdjustedEVR` (a slow, high-R:R
    /// setup can be "best" over a faster-compounding one the Fast Lane would prefer), and an
    /// exact rank-value tie falls back to input-array order rather than conviction.
    /// `preferVelocity` (default false — IDENTICAL to today for every existing caller) opts
    /// into: (1) ranking by the idea's raw EV/day when it has one (falls back to
    /// `qualityAdjustedEVR` for index/FX, which never have a velocity), and (2) on a near-tie
    /// (|Δ| < 0.01) preferring the HIGHER conviction idea instead of whichever happens to sit
    /// earlier in `ideas`. This is a genuine design tradeoff (the ranking metric changes, and
    /// above the existing `minConvictionToRank` floor raw velocity is not conviction-weighted
    /// the way `qualityAdjustedEVR` is) — ship opt-in only; do not flip the default in
    /// MarketsView without owner sign-off.
    ///
    /// `preferConfluence` (default false — byte-identical when off, CONFLUENCE.md item #5's
    /// tie-break wiring) additionally breaks a near-tie by preferring the idea whose
    /// `TradeAdvice.timeframeAligned` is true (three-timeframe agreement — see
    /// `StockSageIndicators.timeframeConfluence`) over one that isn't, applied AFTER the
    /// conviction tie-break when `preferVelocity` is also on. Composable but independent: either
    /// flag can be used alone. Like `preferVelocity`, this is a genuine ranking-behavior choice —
    /// ship opt-in only.
    nonisolated static func bestOpportunity(_ ideas: [StockSageIdea], regime: MarketRegime? = nil,
                                            earnings: [String: EarningsProximity] = [:],
                                            liquidity: [String: LiquidityProfile] = [:],
                                            seasonality: [String: MonthlySeasonality] = [:],
                                            calibration: StockSageConvictionCalibration? = nil,
                                            preferVelocity: Bool = false,
                                            preferConfluence: Bool = false,
                                            holds: VelocityHoldDays = .defaults) -> (idea: StockSageIdea, ev: ExpectedValue)? {
        // No "best buy" in a risk-off tape — a crisis/bear is sometimes exactly when an intraday
        // stop gets gapped through. (nil regime → no gate, identical to before.)
        if let r = regime, bannedFromTopRank(.buyFamily, regime: r.state) { return nil }
        // Same earnings demotion the EV/velocity boards apply, so the "Best opportunity now" card,
        // Today tile and summary can't crown an imminent-earnings name the boards already sank
        // (empty earnings → 0 → identical to before). Demotion, not exclusion: it can still surface
        // if it's the only positive-EV buy.
        func rankVal(_ idea: StockSageIdea) -> Double {
            let base: Double
            if preferVelocity, let v = velocity(for: idea, holds: holds, calibration: calibration) {
                base = v   // RANKING_BACKLOG #10: EV/day, not raw/quality-adjusted EV, when available
            } else {
                base = qualityAdjustedEVR(for: idea, calibration: calibration) ?? 0
            }
            let seasonalBonus = seasonalityRankBonus(for: idea, seasonality: seasonality)
            // Continuous net-cost ratio — matches evRankKey's new pattern so the
            // "best opportunity" ranking is consistent with the EV/velocity boards:
            // a barely-clears-cost candidate ranks below a strongly-clears one.
            let netRatio: Double = {
                guard let e = ev(for: idea, calibration: calibration), e.evR > 0 else { return 1 }
                guard let ne = netEVR(for: idea, calibration: calibration) else { return 1 }
                return Swift.max(0, Swift.min(1, ne / e.evR))
            }()
            // Seasonal bonus is additive AFTER cost-scaling — the same placement rankByEV uses
            // (key + bonus − penalties) — so the board and this card cannot diverge on identical
            // inputs just because netRatio < 1 shrank the bonus on one surface but not the other.
            return base * netRatio + seasonalBonus
                - earningsRankPenalty(for: idea, earnings: earnings)
                - liquidityRankPenalty(for: idea, liquidity: liquidity)
        }
        let candidates = ideas.compactMap { idea -> (StockSageIdea, ExpectedValue)? in
            guard idea.advice.action == .buy || idea.advice.action == .strongBuy,
                  idea.advice.conviction >= minConvictionToRank,   // a #1 pick can't be a low-conviction bet
                  clearsCostAfterFrictions(idea, calibration: calibration),   // …nor a setup that's net-negative after costs
                  // …nor a name your own order would move (no entry → not gated, only-real-data).
                  liquidity[idea.symbol.uppercased()]?.tier != .thin,
                  let e = ev(for: idea, calibration: calibration), e.evR > 0 else { return nil }
            return (idea, e)
        }
        guard preferVelocity || preferConfluence else {
            // UNCHANGED default path — byte-identical reduction to before #10/CONFLUENCE#5 (same
            // tie behavior: the first candidate in `ideas` wins an exact rankVal tie).
            return candidates.max { rankVal($0.0) < rankVal($1.0) }.map { (idea: $0.0, ev: $0.1) }
        }
        // Opt-in tie-breaking: near-ties (|Δ rankVal| < 0.01) are broken by higher conviction
        // (if preferVelocity), then by confluence alignment (if preferConfluence), instead of
        // whichever happens to sit earlier in `ideas`. (Not strictly transitive across a long
        // chain of near-ties, same caveat RANKING #10 already documented — acceptable for the
        // small idea lists this ranks.)
        let tieBand = 0.01
        return candidates.max { a, b in
            let av = rankVal(a.0), bv = rankVal(b.0)
            guard abs(av - bv) < tieBand else { return av < bv }
            if preferVelocity, a.0.advice.conviction != b.0.advice.conviction {
                return a.0.advice.conviction < b.0.advice.conviction
            }
            if preferConfluence, a.0.advice.timeframeAligned != b.0.advice.timeframeAligned {
                return !a.0.advice.timeframeAligned && b.0.advice.timeframeAligned
            }
            return false   // fully tied on every enabled criterion → keep the earlier candidate
        }.map { (idea: $0.0, ev: $0.1) }
    }

    /// Turn-of-month seasonal bonus for the current calendar month. Uses the already-fetched
    /// monthly seasonality cache and stays inert when the activation flag is off or no reliable
    /// month stat exists. This is a ranking bonus only — it does not alter conviction, stop,
    /// target, or sizing.
    ///
    /// SCOPE (activation 2026-07-09): applies to the EV-quality ranks only (`rankByEV` +
    /// `bestOpportunity`). Velocity surfaces (`rankByVelocity`/`fastLane`) are DELIBERATELY
    /// exempt — a monthly-return tendency has no per-day unit meaning in an EV/day key (the
    /// opt-in `preferVelocity` branch of bestOpportunity would mix scales; production never
    /// passes it — RANKING #10 parked). COVERAGE: the cache is populated by the top-ideas
    /// prefetch after each full scan + on sheet-open; a symbol without an entry simply gets 0
    /// (unknown → no tilt, never fabricated).
    /// TRUE exactly when `seasonalityRankBonus` would produce a NON-ZERO tilt for this month
    /// stat (flag on + reliable sample + |t|<1 noise gate passed) — disclosure surfaces (the
    /// detail sheet's seasonality row) key on THIS so they cannot drift from the engine's own
    /// firing conditions. Side/direction is the caller's concern (hold/avoid ideas get 0 from
    /// the bonus regardless — gate the disclosure on the idea's side at the call site).
    nonisolated static func seasonalityTiltFires(_ stat: MonthlySeasonality.MonthStat) -> Bool {
        guard StockSageAdvisor.turnOfMonthEnabled, stat.samples >= 3 else { return false }
        if let t = stat.tStat, abs(t) < 1.0 { return false }
        return true
    }

    nonisolated static func seasonalityRankBonus(for idea: StockSageIdea,
                                                seasonality: [String: MonthlySeasonality] = [:]) -> Double {
        guard let s = seasonality[idea.symbol.uppercased()] else { return 0 }
        let m = StockSageSeasonality.currentMonth()
        guard let stat = StockSageSeasonality.stat(s, month: m), seasonalityTiltFires(stat) else { return 0 }
        // Flag + reliability + the |t|<1 NOISE GATE all live in `seasonalityTiltFires` above
        // (single source of truth shared with the sheet's disclosure — hand-derivations and
        // rationale documented there and in the 2026-07-09 dev-log entries).
        // Keep the effect small and monotonic: positive seasonal drift gets a mild boost,
        // negative drift gets a mild penalty. Scale by sample count so a thin month never
        // dominates the rank key.
        let capped = Swift.max(-0.03, Swift.min(0.03, stat.avgReturn))
        let reliability = min(1.0, Double(stat.samples) / 5.0)
        let tilt = capped * reliability
        // DIRECTION (2026-07-09 review fix): the tilt is a statement about the SYMBOL's month
        // ("historically drifts up in July") — a sell-family idea profits from the OPPOSITE move,
        // so the sign flips (direction-blind, a short on a seasonally-rising name was BOOSTED,
        // the exact inverse of the trade's EV). Neutral actions (hold/avoid) are non-trades: no
        // tilt. `bestOpportunity` is buy-family-only by its own guard, so this changes sell rows
        // on the EV board only.
        switch side(idea) {
        case .buyFamily:  return tilt
        case .sellFamily: return -tilt
        case .neutral:    return 0
        }
    }

    /// Audit 2026-07-12 (ideas-card LANE 2 — "why this rank"): the DECOMPOSITION of an idea's EV
    /// rank key into the exact terms `rankByEV` sums, so the detail sheet can show WHY an idea sits
    /// where it does. This calls the SAME term functions the ranker uses (never a parallel
    /// re-derivation), so `total` provably equals the real sort key — `base + seasonality −
    /// earningsPenalty − liquidityPenalty` (matching `rankByEV.key` exactly). Display-only: it reads
    /// the rank, it does not change it. `nil` for an idea with no EV key (a nil-EV row that sorts
    /// last) — the caller shows nothing rather than a fabricated breakdown.
    struct RankExplanation: Sendable, Equatable {
        let base: Double            // regime-adjusted EV rank key (the dominant term)
        let seasonalityBonus: Double   // + (owner-activated month tilt, capped ±0.03, may be −)
        let earningsPenalty: Double    // ≥0, SUBTRACTED (imminent-earnings demotion)
        let liquidityPenalty: Double   // ≥0, SUBTRACTED (thin-liquidity demotion)
        nonisolated var total: Double { base + seasonalityBonus - earningsPenalty - liquidityPenalty }
        /// The terms that ACTUALLY moved this idea off its raw EV, largest-magnitude first — for a
        /// concise "why" line. Empty when only the base EV drove the rank (nothing to explain).
        nonisolated var activeAdjustments: [(label: String, delta: Double)] {
            var out: [(String, Double)] = []
            if seasonalityBonus != 0 { out.append(("seasonal month tilt", seasonalityBonus)) }
            if earningsPenalty != 0 { out.append(("earnings-soon demotion", -earningsPenalty)) }
            if liquidityPenalty != 0 { out.append(("thin-liquidity demotion", -liquidityPenalty)) }
            return out.sorted { abs($0.1) > abs($1.1) }
        }
    }

    nonisolated static func rankExplanation(for idea: StockSageIdea, regime: MarketRegime? = nil,
                                            earnings: [String: EarningsProximity] = [:],
                                            liquidity: [String: LiquidityProfile] = [:],
                                            seasonality: [String: MonthlySeasonality] = [:],
                                            calibration: StockSageConvictionCalibration? = nil) -> RankExplanation? {
        guard let base = regimeAdjustedEVRankKey(for: idea, regime: regime, calibration: calibration) else { return nil }
        return RankExplanation(base: base,
                               seasonalityBonus: seasonalityRankBonus(for: idea, seasonality: seasonality),
                               earningsPenalty: earningsRankPenalty(for: idea, earnings: earnings),
                               liquidityPenalty: liquidityRankPenalty(for: idea, liquidity: liquidity))
    }

    /// Fast lane: positive-EV ideas that HAVE a velocity (crypto/equity), ranked by
    /// velocity (EV/day) desc — the fastest-compounding opportunities. Index/FX (no
    /// hold) and non-positive-EV ideas are excluded. Faster turnover = more cycles
    /// AND more chances to be wrong; the UI carries that caveat.
    ///
    /// Membership includes demoted ideas (low-conviction, below-cost-floor) — they
    /// receive a negative `velocityRankKey` that sorts them to the bottom, but are
    /// NOT excluded. This is intentional (demotion, not exclusion): a demoted idea
    /// can be the only fast-lane member in a thin scan, and the caller may still
    /// want to surface it with appropriate warnings. Callers that need only "clean"
    /// fast-lane members should additionally filter by `velocityRankKey > 0` or
    /// check `netCostFloorFlag.isDeranked` + `isLowConviction`.
    ///
    /// `earnings` and `liquidity` (default empty) apply the same demotion penalties
    /// that `rankByVelocity` already uses, so the fast-lane strip and the velocity
    /// board are consistent: an imminent-earnings or thin-liquidity idea ranks lower
    /// in the lane. Empty dicts → byte-identical to the pre-penalty ordering.
    nonisolated static func fastLane(_ ideas: [StockSageIdea], holds: VelocityHoldDays = .defaults,
                                     calibration: StockSageConvictionCalibration? = nil,
                                     earnings: [String: EarningsProximity] = [:],
                                     liquidity: [String: LiquidityProfile] = [:]) -> [StockSageIdea] {
        ideas.enumerated().compactMap { idx, idea -> (Int, StockSageIdea, Double)? in
            guard let e = ev(for: idea, calibration: calibration), e.evR > 0,
                  let v = velocityRankKey(for: idea, holds: holds, calibration: calibration) else { return nil }
            let key = v - earningsRankPenalty(for: idea, earnings: earnings) - liquidityRankPenalty(for: idea, liquidity: liquidity)
            return (idx, idea, key)
        }
        .sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2 }
        .map { $0.1 }
    }

    /// ~21 trading bars — the "1-month" leg of the classic 12-1 momentum construction
    /// (`StockSageIndicators.timeSeriesMomentum`'s `skipRecent` default), reused here as the
    /// short-horizon follow-through window for `momentumQuality`.
    private nonisolated static let momentumQualityLookback = 21
    /// Kaufman efficiency-ratio floor read as "a genuine trend, not chop" (Kaufman's own guidance
    /// is roughly 0.3–0.4 for a tradable trend). Below this, net price movement is mostly noise.
    private nonisolated static let momentumQualityTrendThreshold = 0.35

    /// 0–1 read on whether a fast-lane idea's SHORT-HORIZON momentum is genuinely hot right now —
    /// not just technically positive — so `rankByVelocityWeighted` can out-rank a clean compounder
    /// over a flat/mean-reverting setup of equal velocity (a classic whipsaw trap: pure EV/day never
    /// inspects the SHAPE of recent price action). Built from THREE signals `StockSageAdvisor`
    /// already computes via `StockSageIndicators` — no new math:
    ///   • Kaufman efficiency ratio (`efficiencyRatio`, default 20-bar) ≥ 0.35 — clean trend vs chop.
    ///   • MACD histogram (`macd`, default 12/26/9) > 0 — momentum currently accelerating.
    ///   • Positive ~21-bar return (`returnOverPeriod`) — real short-horizon follow-through.
    /// DEVIATION FROM THE ORIGINAL BACKLOG WORDING (disclosed, not silent): the spec text proposed
    /// "RSI in the trend zone" as the third leg; a bounded RSI band is a WEAKER discriminator for
    /// exactly the failure mode this function exists to catch — a mean-reverting oscillator can sit
    /// in a "bullish" RSI band repeatedly WHILE chopping sideways. Kaufman's efficiency ratio is the
    /// purpose-built trend-vs-chop read (already in this engine) and is the correct substitute.
    /// Quality = (# hot signals) ÷ (# signals `closes` was long enough to compute) — a signal that
    /// can't be computed is EXCLUDED from the average, never counted as cold, so a shorter series is
    /// never punished for missing data. When `closes` is too short for ALL THREE (≤ 20 bars — even
    /// `efficiencyRatio`, the loosest of the three at a >20-bar minimum, is uncomputable there),
    /// returns the NEUTRAL ceiling 1.0 — no data ⇒ no penalty, the same only-real-data / floor-never-inflate
    /// convention `cryptoRiskScaler` uses elsewhere in this file — so an unweighted call (or a symbol
    /// with no history) never gets silently demoted. HONESTY (the "reversal caveat"): a score near
    /// 1.0 means recent momentum LOOKS clean and hot RIGHT NOW — it is not a forecast that it
    /// continues; a hot short-horizon run can still reverse. The caller-facing copy must say so.
    nonisolated static func momentumQuality(for idea: StockSageIdea, closes: [Double]) -> Double {
        var hot = 0, total = 0
        if let er = StockSageIndicators.efficiencyRatio(closes) {
            total += 1
            if er >= momentumQualityTrendThreshold { hot += 1 }
        }
        if let m = StockSageIndicators.macd(closes) {
            total += 1
            if m.histogram > 0 { hot += 1 }
        }
        if let ret = StockSageIndicators.returnOverPeriod(closes, period: momentumQualityLookback) {
            total += 1
            if ret > 0 { hot += 1 }
        }
        guard total > 0 else { return 1.0 }   // no computable signal → neutral, never a phantom penalty
        return Double(hot) / Double(total)
    }

    /// `fastLane`, re-ranked within itself by `fastLane`'s OWN ordering key × `momentumQuality`,
    /// so a setup whose short-horizon momentum is genuinely hot out-ranks a same-velocity flat/
    /// mean-reverting one. This is a SEPARATE lens from `fastLane`'s own ordering (log-growth at
    /// half-Kelly, net-cost-scaled) — it never changes `fastLane`'s membership, only re-sorts the
    /// SAME idea set it already returned. `closes` maps symbol → raw daily closes (newest last)
    /// for whichever ideas history is available for; deliberately keyed by symbol (not threaded
    /// through `StockSageIdea`, which only carries a down-sampled `spark` too short for `macd`'s
    /// 35-bar minimum) so a caller can supply real daily bars without any model change.
    ///
    /// 2026-07-01 adversarial-review fix: this PREVIOUSLY weighted the RAW `velocity(for:)`
    /// (undemoted EV/day) instead of `fastLane`'s own `velocityRankKey`. `fastLane`'s membership
    /// guard only requires `evR > 0` — it does NOT exclude a sub-`minConvictionToRank` "junk" idea
    /// or a below-net-cost-floor idea, it only buries them at the bottom of the lane via a demoted
    /// key (−1000 / −500,000). Because raw velocity ignores those penalties entirely, a demoted
    /// idea with a merely-larger raw velocity could get RESURRECTED to #1 by this function —
    /// directly contradicting `velocityRankKey`'s own documented invariant ("nothing previously
    /// demoted is resurrected") and `fastLane`'s real order. Fixed: weight `velocityRankKey`
    /// itself, and ONLY when it's already positive (clean/non-demoted) — a demoted idea's negative
    /// key passes through completely UNCHANGED (not multiplied), preserving the original design's
    /// own correct concern that multiplying a NEGATIVE key by a 0–1 quality factor would perversely
    /// REWARD a demoted, cold setup by pulling it toward zero. This also makes the `closes: [:]`
    /// default TRULY byte-identical to `fastLane`'s own order (same key, unweighted), not merely
    /// "usually similar."
    nonisolated static func rankByVelocityWeighted(_ ideas: [StockSageIdea], closes: [String: [Double]] = [:],
                                                   holds: VelocityHoldDays = .defaults,
                                                   calibration: StockSageConvictionCalibration? = nil,
                                                   earnings: [String: EarningsProximity] = [:],
                                                   liquidity: [String: LiquidityProfile] = [:]) -> [StockSageIdea] {
        let lane = fastLane(ideas, holds: holds, calibration: calibration, earnings: earnings, liquidity: liquidity)
        func weightedVelocity(_ idea: StockSageIdea) -> Double {
            let rawKey = velocityRankKey(for: idea, holds: holds, calibration: calibration) ?? 0
            // Apply the same e/l penalties fastLane already applies so a momentum-hot
            // demoted idea can't be resurrected by the quality multiplier (same class
            // of bug as the 2026-07-01 adversarial-review fix — a demoted idea's
            // raw key must NEVER outrank below the penalty threshold).
            let key = rawKey
                - earningsRankPenalty(for: idea, earnings: earnings)
                - liquidityRankPenalty(for: idea, liquidity: liquidity)
            guard key > 0 else { return key }   // demoted/non-positive → pass through unchanged, never resurrected
            let series = closes[idea.symbol] ?? []
            guard !series.isEmpty else { return key }   // no history for THIS symbol → unweighted (×1)
            return key * momentumQuality(for: idea, closes: series)
        }
        // F12: decorate-sort-undecorate — weightedVelocity (EV + NetEdge + momentumQuality) computed
        // once per idea, not per comparison; comparator + offset tie-break unchanged → identical order.
        // (Split into explicitly-typed statements: the single chained tuple expression exceeded the
        // type-checker budget — "unable to type-check this expression in reasonable time".)
        var decorated: [(offset: Int, idea: StockSageIdea, key: Double)] = []
        decorated.reserveCapacity(lane.count)
        for (offset, idea) in lane.enumerated() {
            decorated.append((offset: offset, idea: idea, key: weightedVelocity(idea)))
        }
        decorated.sort { a, b in
            a.key == b.key ? a.offset < b.offset : a.key > b.key
        }
        return decorated.map(\.idea)
    }

    /// A heavily-caveated estimate of weekly R IF you actually run AND re-cycle the
    /// top `maxConcurrent` fast-lane setups: sum of their GROSS velocities (EV/day, BEFORE
    /// round-trip costs) × trading days. nil if the fast lane is empty. NOT a promise — it
    /// assumes you take these, each carries variance, and it ignores fills/slippage/correlation.
    /// F03/F44 (2026-07-02, label-only — the gross→net NETTING decision is owner-held): every
    /// display site must label this "gross, before costs", and note that the sum can include
    /// ideas the net-cost floor DEMOTES on the velocity board (fastLane demotes, never excludes)
    /// while the same summary's "Fastest" pick excludes them.
    nonisolated static func expectedWeeklyR(_ ideas: [StockSageIdea], maxConcurrent: Int = 3, tradingDays: Double = 5,
                                            holds: VelocityHoldDays = .defaults,
                                            calibration: StockSageConvictionCalibration? = nil) -> Double? {
        expectedWeeklyR(lane: fastLane(ideas, holds: holds, calibration: calibration), ideas: ideas,
                        maxConcurrent: maxConcurrent, tradingDays: tradingDays, holds: holds, calibration: calibration)
    }

    /// BIND-ONCE variant: identical body to `expectedWeeklyR` above, but takes an ALREADY-COMPUTED
    /// `fastLane(...)` result instead of re-deriving it — for a caller (e.g. a SwiftUI body) that
    /// already has the lane bound from a prior call with the SAME `ideas`/`holds`/`calibration`
    /// (and, when the lane was earnings/liquidity-aware, the SAME `earnings`/`liquidity` too — the
    /// caller is responsible for that match; this function trusts `lane` as given, same contract
    /// `fastLaneByClass`'s PERF-STRIP replacement already established). `ideas` is still required
    /// (unchanged) because `fastLaneConcentration` below re-derives ITS OWN lane from `ideas` for
    /// the concentration check. `earnings`/`liquidity` (default empty, F-review fix 2026-07-10)
    /// are threaded straight into that concentration check so it analyzes the SAME earnings/
    /// liquidity-aware top-N the caller's `lane` was built with — a caller passing an AWARE `lane`
    /// (e.g. `summary()`'s `netAwareLane`) but leaving these defaulted would otherwise silently
    /// haircut against the UNAWARE lane's concentration instead, which can put the concentration
    /// verdict on the wrong side of `isConcentrated` vs the AWARE haircut `netExpectedWeeklyR(lane:
    /// ...)` already applies (was: `weeklyRGrossSameBasket` could show gross ≈0.70× below net when
    /// the aware/unaware top-3 diverge across that boundary — see
    /// `summaryWeeklyRGrossSameBasketUsesAwareConcentrationAcrossAssetClasses`). Every PRE-EXISTING
    /// call site (the `ideas`-only overload below, `weeklyR`) omits `earnings`/`liquidity` and so
    /// stays byte-identical (defaults to empty ⇒ UNAWARE, unchanged).
    /// Equivalence to the `ideas`-only overload holds BY CONSTRUCTION whenever `lane ==
    /// fastLane(ideas, holds:calibration:)`: the `ideas`-only overload's body IS `expectedWeeklyR(lane:
    /// fastLane(ideas, ...), ideas: ideas, ...)` — it delegates to this function, so the two share one
    /// body and cannot diverge (this is a `same-body-different-entrypoint` equivalence, not an
    /// independently-verified one; `StockSagePerfProbeTests.dedupedFastLaneFamilyMatchesDirectCallsAt2400Scale`
    /// exercises the delegation but, because both call paths run identical code, cannot catch a body
    /// mutation — see `expectedWeeklyRLaneOverloadMatchesHandDerivedPin` for a hand-derived value pin
    /// that does).
    nonisolated static func expectedWeeklyR(lane: [StockSageIdea], ideas: [StockSageIdea], maxConcurrent: Int = 3,
                                            tradingDays: Double = 5, holds: VelocityHoldDays = .defaults,
                                            calibration: StockSageConvictionCalibration? = nil,
                                            earnings: [String: EarningsProximity] = [:],
                                            liquidity: [String: LiquidityProfile] = [:]) -> Double? {
        let vels = lane.prefix(Swift.max(0, maxConcurrent)).compactMap { velocity(for: $0, holds: holds, calibration: calibration) }
        guard !vels.isEmpty else { return nil }
        // If the top-N fast-lane setups are all one asset class, they tend to move together —
        // summing their velocities as if independent overstates the real weekly R by counting
        // one correlated bet N times. Haircut the total (not each leg) so the raw per-idea
        // velocities stay honest; 0.70 is a conservative single-token estimate, not a fit.
        // Must analyze the SAME earnings/liquidity-aware top-N `lane` was built with (F-review fix
        // 2026-07-10, mirrors the identical `netExpectedWeeklyR(lane:ideas:...)` contract note
        // below) — otherwise the 0.70 factor is decided on a different top-3 than the one `lane`'s
        // velocities were summed over.
        let concentrationFactor = fastLaneConcentration(ideas, topN: maxConcurrent, holds: holds, calibration: calibration, earnings: earnings, liquidity: liquidity)?.isConcentrated == true ? 0.70 : 1.0
        return vels.reduce(0, +) * tradingDays * concentrationFactor
    }

    /// NET-of-cost weekly R estimate — companion to `expectedWeeklyR` that sums
    /// `netVelocity` (EV/day after round-trip frictions, costs, and financing)
    /// instead of gross velocities. Uses the same fast-lane ordering (now
    /// earnings/liquidity-aware via `fastLane`'s optional params), concentration
    /// haircut, and trading-days cadence as the gross version. nil when the fast
    /// lane is empty or no net velocity is computable. An estimate, not income.
    nonisolated static func netExpectedWeeklyR(_ ideas: [StockSageIdea], maxConcurrent: Int = 3,
                                               tradingDays: Double = 5,
                                               holds: VelocityHoldDays = .defaults,
                                               calibration: StockSageConvictionCalibration? = nil,
                                               earnings: [String: EarningsProximity] = [:],
                                               liquidity: [String: LiquidityProfile] = [:]) -> Double? {
        netExpectedWeeklyR(lane: fastLane(ideas, holds: holds, calibration: calibration, earnings: earnings, liquidity: liquidity),
                           ideas: ideas, maxConcurrent: maxConcurrent, tradingDays: tradingDays, holds: holds,
                           calibration: calibration, earnings: earnings, liquidity: liquidity)
    }

    /// BIND-ONCE variant of `netExpectedWeeklyR` — see `expectedWeeklyR(lane:ideas:...)`'s doc for
    /// the contract (caller supplies an already-computed, earnings/liquidity-aware `fastLane(...)`
    /// result with matching `ideas`/`holds`/`calibration`/`earnings`/`liquidity`). Equivalence to
    /// the `ideas`-only overload under that match holds BY CONSTRUCTION (the `ideas`-only overload's
    /// body delegates to this function — same body, not an independently-verified match; see
    /// `expectedWeeklyR(lane:ideas:...)`'s doc for why the existing dedup-proof test cannot catch a
    /// body mutation here either).
    nonisolated static func netExpectedWeeklyR(lane: [StockSageIdea], ideas: [StockSageIdea], maxConcurrent: Int = 3,
                                               tradingDays: Double = 5,
                                               holds: VelocityHoldDays = .defaults,
                                               calibration: StockSageConvictionCalibration? = nil,
                                               earnings: [String: EarningsProximity] = [:],
                                               liquidity: [String: LiquidityProfile] = [:]) -> Double? {
        let vels = lane
            .prefix(Swift.max(0, maxConcurrent))
            .compactMap { netVelocity(for: $0, holds: holds, calibration: calibration) }
        guard !vels.isEmpty else { return nil }
        // Haircut must analyze the SAME earnings/liquidity-demoted top-N the velocities
        // above are summed over (line 809 passes earnings+liquidity) — otherwise the 0.70
        // concentration factor is decided on a different top-3 than the one being summed
        // (audit L4-1/F2, 2026-07-07). fastLaneConcentration's own contract requires this.
        let concentrationFactor = fastLaneConcentration(ideas, topN: maxConcurrent, holds: holds, calibration: calibration, earnings: earnings, liquidity: liquidity)?.isConcentrated == true ? 0.70 : 1.0
        return vels.reduce(0, +) * tradingDays * concentrationFactor
    }

    /// Account-aware weekly $ estimate: expected weekly R × the dollar value of 1R
    /// (account × riskFraction). nil without an account, risk, or a non-empty fast
    /// lane. An ESTIMATE that assumes you take & re-cycle the top setups — NOT income.
    nonisolated static func expectedWeeklyDollars(_ ideas: [StockSageIdea], account: Double, riskFraction: Double,
                                                  maxConcurrent: Int = 3, tradingDays: Double = 5,
                                                  holds: VelocityHoldDays = .defaults,
                                                  calibration: StockSageConvictionCalibration? = nil) -> Double? {
        guard account > 0, riskFraction > 0, account.isFinite, riskFraction.isFinite,
              let wkR = expectedWeeklyR(ideas, maxConcurrent: maxConcurrent, tradingDays: tradingDays, holds: holds, calibration: calibration) else { return nil }
        return wkR * account * riskFraction   // finite inputs → never "+$inf/week"
    }

    /// How many ROUND TRIPS the weekly projection implicitly assumes. `expectedWeeklyR`
    /// multiplies each top-N idea's per-day velocity by `tradingDays` — i.e. it assumes each
    /// slot stays deployed all week, re-entering as its setups resolve: tradingDays ÷
    /// expectedHold re-cycles per slot (a 3-day crypto hold ⇒ ~1.7 round trips in a 5-day
    /// week; a 12-day equity swing ⇒ ~0.4 — you pay its round trip roughly every 2.4 weeks).
    /// Each re-cycle pays the full round-trip frictions the GROSS weekly figure excludes —
    /// week-horizon research roadmap #1 (turnover awareness): turnover is the #1 documented
    /// edge-killer at the 1–5d horizon. DISCLOSURE ONLY: consumed by display labels; nothing
    /// in ranking/sizing reads it. nil when the fast lane is empty or no top idea has a hold
    /// (mirrors expectedWeeklyR's own nil — never a fabricated cadence).
    nonisolated static func assumedWeeklyRoundTrips(_ ideas: [StockSageIdea], maxConcurrent: Int = 3,
                                                    tradingDays: Double = 5,
                                                    holds: VelocityHoldDays = .defaults,
                                                    calibration: StockSageConvictionCalibration? = nil) -> Double? {
        let lane = fastLane(ideas, holds: holds, calibration: calibration).prefix(Swift.max(0, maxConcurrent))
        let cycles = lane.compactMap { idea -> Double? in
            guard let hold = expectedHoldDays(for: idea, holds: holds), hold > 0 else { return nil }
            return tradingDays / hold
        }
        guard !cycles.isEmpty else { return nil }
        return cycles.reduce(0, +)
    }

    /// F03/F44-SAFE disclosure line for the weekly-R display sites: names the re-cycle count
    /// the gross figure assumes. LABEL ONLY — never alters the number itself (the gross→net
    /// netting decision stays owner-held, F03/F44). nil when no cadence is estimable.
    nonisolated static func weeklyTurnoverNote(_ ideas: [StockSageIdea], maxConcurrent: Int = 3,
                                               tradingDays: Double = 5,
                                               holds: VelocityHoldDays = .defaults,
                                               calibration: StockSageConvictionCalibration? = nil) -> String? {
        guard let trips = assumedWeeklyRoundTrips(ideas, maxConcurrent: maxConcurrent, tradingDays: tradingDays,
                                                  holds: holds, calibration: calibration) else { return nil }
        // Audit 2026-07-12 (wave-2 #5): the label said "the top 3" regardless of how many lane members
        // actually have a hold — contradicting the card subtitle ("top 1") when the lane is thinner.
        // Count the REAL members the round-trip figure covers (same lane + hold filter as
        // assumedWeeklyRoundTrips), so the label and the number describe the same setups.
        let laneCount = fastLane(ideas, holds: holds, calibration: calibration)
            .prefix(Swift.max(0, maxConcurrent))
            .filter { (expectedHoldDays(for: $0, holds: holds) ?? 0) > 0 }
            .count
        return String(format: "Assumes ≈%.1f round trips across the top %d this week — every re-entry pays the est. round-trip costs this gross figure excludes (turnover is the #1 documented edge-killer at this horizon).",
                      trips, laneCount)
    }

    /// Trading days per week for the fast lane. Equities trade ~5 days; crypto is 24/7 (~7).
    /// Blends by the crypto share of the fast lane: round(5 + 2·cryptoFraction) — all-crypto → 7,
    /// equity-only → 5 (so nothing shifts for the existing equity case), 1-of-3 crypto → 6.
    /// Empty lane → 5. NOTE: more trading days ≠ more edge — crypto's extra cadence carries
    /// extra variance, which `cryptoRiskScaler` sizes DOWN for.
    nonisolated static func tradingDaysForLane(_ ideas: [StockSageIdea], holds: VelocityHoldDays = .defaults,
                                               calibration: StockSageConvictionCalibration? = nil) -> Double {
        tradingDaysForLane(lane: fastLane(ideas, holds: holds, calibration: calibration))
    }

    /// BIND-ONCE variant: identical body, but takes an already-computed `fastLane(...)` result.
    /// ORDER- and MEMBERSHIP-INSENSITIVE for this function specifically (it only reads `.count`
    /// and an asset-class `.filter{}.count` — earnings/liquidity dicts don't change fastLane's
    /// MEMBERSHIP, only its ranking order, so a lane the caller computed WITH earnings/liquidity
    /// gives the identical crypto-share fraction as one computed without). Equivalence to the
    /// `ideas`-only overload holds BY CONSTRUCTION — its body is `tradingDaysForLane(lane:
    /// fastLane(ideas, ...))`, i.e. it delegates here, so the two share one body and cannot diverge.
    /// `StockSagePerfProbeTests.dedupedFastLaneFamilyMatchesDirectCallsAt2400Scale` exercises the
    /// delegation but, running identical code on both sides, cannot catch a body mutation.
    nonisolated static func tradingDaysForLane(lane: [StockSageIdea]) -> Double {
        guard !lane.isEmpty else { return 5 }
        let crypto = lane.filter { StockSageAllocation.assetClass($0.symbol) == "Crypto" }.count
        return (5 + 2 * Double(crypto) / Double(lane.count)).rounded()
    }

    /// How much to SHRINK per-trade risk for an asset's realized volatility: max(1, vol/baseline).
    /// FLOORED at 1 so it can only reduce risk, never inflate it — even fast money needs brakes.
    /// e.g. 70%-vol crypto vs a 20% baseline → 3.5× (size 1%/3.5 ≈ 0.29%/trade). Feed `vol` from
    /// `StockSageIndicators.annualizedVolatility`.
    nonisolated static func cryptoRiskScaler(annualizedVol: Double, baseline: Double = 0.20) -> Double {
        guard baseline > 0 else { return 1 }
        return Swift.max(1, annualizedVol / baseline)
    }

    /// Honest "how big is a typical day" read for a 24/7 asset: de-annualizes the
    /// ALREADY-COMPUTED annualized realized vol (the same `idea.realizedVol` that already
    /// drives the crypto stop-multiple in StockSageAdvisor and the risk scaler above) back
    /// to a daily figure. NOT a forecast — a rough one-standard-deviation-ish daily-move
    /// estimate to size against. nil when there's no realized-vol input (not enough
    /// history) or it's non-finite/non-positive — never invents a number.
    ///
    /// 2026-07-01 adversarial-review fix: this PREVIOUSLY divided by √365 on the stated
    /// (but false) premise that crypto's `realizedVol` is computed on a 365-day calendar.
    /// It never was — `idea.realizedVol` is ALWAYS `StockSageIndicators.annualizedVolatility
    /// (history.closes)` at its default `periodsPerYear: 252`, for every asset class,
    /// crypto included (verified: grepped every call site — no caller ever passes 365).
    /// Dividing a 252-basis annualized figure by √365 instead of √252 understated the
    /// reported daily move by a factor of √(252/365) ≈ 0.83 (~17% too low) — the OPPOSITE
    /// of the original (mistaken) intent. Fixed to the basis the input is ACTUALLY computed
    /// with. (A genuinely 365-basis crypto realizedVol would need a wider, separate change —
    /// that annualizedVolatility call also feeds StockSageAdvisor's variance-scaled momentum
    /// and stop sizing, both already tuned against the existing 252-basis figure — out of
    /// scope for this contained fix.)
    nonisolated static func dailyVariancePct(annualizedVol: Double?) -> Double? {
        guard let vol = annualizedVol, vol.isFinite, vol > 0 else { return nil }
        return vol / 252.0.squareRoot() * 100
    }

    /// A one-glance money-velocity rollup: the best bet now, the fastest-compounding
    /// setup, and the estimated weekly R — each a value already computed elsewhere,
    /// composed for a single header. All optional; `hasContent` gates the card.
    nonisolated static func summary(_ ideas: [StockSageIdea], trades: [TradeRecord] = [],
                                    fraction: Double = 0.01, holds: VelocityHoldDays = .defaults,
                                    regime: MarketRegime? = nil,
                                    earnings: [String: EarningsProximity] = [:],
                                    liquidity: [String: LiquidityProfile] = [:],
                                    seasonality: [String: MonthlySeasonality] = [:],
                                    calibration: StockSageConvictionCalibration? = nil) -> MoneyVelocitySummary {
        // Regime-aware so the card's displayed "best bet" matches the regime-gated nav target
        // (a risk-off tape suppresses the best-buy on BOTH). nil regime → identical to before.
        // Earnings/liquidity-aware so the summary best-bet matches the demoted/gated board
        // (both empty → unchanged). Calibration-aware so every headline number (best EV, fastest
        // velocity, weekly R) uses the SAME measured win-prob as the idea cards — no
        // calibrated-next-to-uncalibrated mismatch. Seasonality-aware (2026-07-09 review fix)
        // for the same reason: this was the FIFTH bestOpportunity call site — the four direct
        // UI sites got the TOM tilt but this indirect one didn't, so the money-velocity
        // headline/playbook/velocityHistory could crown a different "best" than the board.
        let best = bestOpportunity(ideas, regime: regime, earnings: earnings, liquidity: liquidity, seasonality: seasonality, calibration: calibration)
        // Use rankByVelocity (earnings/liquidity-aware) then skip below-floor and negative-EV
        // ideas — so the "Fastest" headline matches the board's floor-de-ranked, penalized sort.
        let fastest = rankByVelocity(ideas, holds: holds, earnings: earnings, liquidity: liquidity, calibration: calibration)
            .first(where: { (ev(for: $0, calibration: calibration)?.evR ?? -1) > 0
                            && !netCostFloorFlag(for: $0, holds: holds, calibration: calibration).isDeranked })
        // The brake: the owner's worst losing streak, compounded down at the risk fraction.
        let dd = StockSageJournal.equityRisk(trades)
            .flatMap { StockSageRiskOfRuin.scenario(losses: $0.maxConsecutiveLosses, fraction: fraction) }
        // F9 (2026-07-09, display-sum correctness): the earnings/liquidity-AWARE lane, computed
        // ONCE and fed into BOTH weeklyRNet and its gross same-basket companion below, so a caller
        // pairing them as "net X (gross Y)" sums over the identical top-N — not two different
        // baskets. `weeklyR` (a few lines up) deliberately stays the UNAWARE lane, unchanged, for
        // VelocityHistory's cross-session trend continuity (see MarketsView's onAppear .task).
        let netAwareLane = fastLane(ideas, holds: holds, calibration: calibration, earnings: earnings, liquidity: liquidity)
        return MoneyVelocitySummary(
            bestSymbol: best?.idea.symbol,
            bestEV: best?.ev.evR,
            fastestSymbol: fastest?.symbol,
            fastestVelocity: fastest.flatMap { netVelocity(for: $0, holds: holds, calibration: calibration) },
            // Honest cadence: an all-crypto lane re-cycles ~7 days/week, equity ~5.
            weeklyR: expectedWeeklyR(ideas, tradingDays: tradingDaysForLane(ideas, holds: holds, calibration: calibration), holds: holds, calibration: calibration),
            // F03/F44 (owner gate lifted 2026-07-09): the NET figure is the headline the card
            // shows; earnings/liquidity passed so it equals the fast-lane strip's own net line
            // (the same number rendered twice must be identical). Routed through the bind-once
            // lane overload with `netAwareLane` — equivalent BY CONSTRUCTION to the ideas-only
            // overload's own internal `fastLane(...)` call, so this is byte-identical to before.
            weeklyRNet: netExpectedWeeklyR(lane: netAwareLane, ideas: ideas, tradingDays: tradingDaysForLane(ideas, holds: holds, calibration: calibration), holds: holds, calibration: calibration, earnings: earnings, liquidity: liquidity),
            // F9: the SAME netAwareLane basket, summed GROSS — for pairing next to weeklyRNet ONLY.
            // F-review fix (2026-07-10): earnings/liquidity now passed through so the concentration
            // haircut is judged on this SAME aware basket, not the unaware one weeklyR uses — see
            // the doc on `expectedWeeklyR(lane:ideas:...)` above for why that mismatch mattered.
            weeklyRGrossSameBasket: expectedWeeklyR(lane: netAwareLane, ideas: ideas, tradingDays: tradingDaysForLane(ideas, holds: holds, calibration: calibration), holds: holds, calibration: calibration, earnings: earnings, liquidity: liquidity),
            // C7a (2026-07-09): the card's "top 3" subtitle overstated when the lane held fewer —
            // expose the count the weekly sums ACTUALLY use. Lane membership is earnings/
            // liquidity-independent (they adjust only the sort key), so the bare lane's count
            // is exact for both the gross and net figures.
            weeklyTopCount: Swift.min(3, fastLane(ideas, holds: holds, calibration: calibration).count),
            worstRunLosses: dd?.losses,
            worstRunDrawdownPct: dd?.drawdownPct,
            riskFraction: fraction)
    }

    /// A short, ordered, copyable action list built from the summary — best bet, fastest,
    /// est. weekly, and a hard risk rule. Every line is hedged; it is NOT advice.
    nonisolated static func playbook(_ s: MoneyVelocitySummary) -> String {
        var lines = ["Money-velocity playbook — estimates, not advice. Size every entry with a stop."]
        var n = 1
        if let sym = s.bestSymbol, let ev = s.bestEV {
            lines.append("\(n). Best bet now: \(sym) — est. EV \(String(format: "%+.2f", ev))R (gross). Enter only with a defined stop.")
            n += 1
        }
        if let sym = s.fastestSymbol, let v = s.fastestVelocity {
            // F03: summary() feeds netVelocity here — label it "net" so the copyable artifact
            // can't silently mix an unlabeled net figure next to the gross lines around it.
            lines.append("\(n). Fastest compounding: \(sym) — est. \(String(format: "%+.2f", v))R/day net (faster turnover, more variance).")
            n += 1
        }
        if let netWk = s.weeklyRNet {
            // F03/F44 net headline (2026-07-09): the copyable artifact carries the SAME
            // decision-relevant net figure the card headlines, with gross beside it labeled —
            // a pasted plan must never revert to the number the card demoted to hover-only.
            // F9: the parenthetical uses weeklyRGrossSameBasket (same top-N as netWk), never the
            // basket-unaware weeklyR — pairing those two would sum two different baskets.
            let grossPart = s.weeklyRGrossSameBasket.map { String(format: " (gross %+.1fR before costs)", $0) } ?? ""
            lines.append("\(n). Run the top setups: ~\(String(format: "%+.1f", netWk))R/week net of est. costs\(grossPart) — an estimate assuming you take and re-cycle them, not income.")
            n += 1
        } else if let wk = s.weeklyR {
            // Labeled-gross fallback when the net figure can't form — never a fabricated net.
            lines.append("\(n). Run the top setups: ~\(String(format: "%+.1f", wk))R/week gross, before costs — an estimate assuming you take and re-cycle them, not income.")
            n += 1
        }
        if let losses = s.worstRunLosses, let dd = s.worstRunDrawdownPct {
            let pct = Int((s.riskFraction * 100).rounded())
            lines.append("\(n). Risk control: your worst run (\(losses)) at \(pct)%/trade ≈ −\(String(format: "%.1f", dd * 100))%. Keep risk small enough to survive it.")
            n += 1
        }
        lines.append("\(n). Rule: risk ≤1% per trade, always a stop, never chase. Speed compounds only if you stay in the game.")
        return lines.joined(separator: "\n")
    }

    /// Concentration of the top fast-lane setups by asset class. Chasing velocity
    /// (shortest holds) tends to pile into crypto — so the "diversification" of the
    /// fast lane can be an illusion. `isConcentrated` = the top-N are ALL one class.
    nonisolated static func fastLaneConcentration(_ ideas: [StockSageIdea], topN: Int = 3,
                                                  holds: VelocityHoldDays = .defaults,
                                                  calibration: StockSageConvictionCalibration? = nil,
                                                  earnings: [String: EarningsProximity] = [:],
                                                  liquidity: [String: LiquidityProfile] = [:]) -> FastLaneConcentration? {
        // Same earnings/liquidity demotions as the displayed lane — the "top 3 are all X"
        // warning must analyze the SAME top-3 the strip shows, or the warning lies.
        fastLaneConcentration(lane: fastLane(ideas, holds: holds, calibration: calibration, earnings: earnings, liquidity: liquidity), topN: topN)
    }

    /// BIND-ONCE variant: identical body, but takes an already-computed `fastLane(...)` result
    /// instead of re-deriving it. ORDER-SENSITIVE — the caller's `lane` must be the SAME
    /// earnings/liquidity-aware fastLane(ideas, holds, calibration, earnings, liquidity) call this
    /// function's other overload would make internally (membership is earnings/liquidity-
    /// INVARIANT — those dicts only re-rank, never exclude — but `.prefix(topN)` IS order-sensitive,
    /// so a lane computed WITHOUT earnings/liquidity here would silently analyze the wrong top-N).
    /// Equivalence to the `ideas`-only overload holds BY CONSTRUCTION whenever that lane match
    /// holds — its body is `fastLaneConcentration(lane: fastLane(ideas, ...), topN: topN)`, i.e. it
    /// delegates here, so the two share one body and cannot diverge.
    /// `StockSagePerfProbeTests.dedupedFastLaneFamilyMatchesDirectCallsAt2400Scale` exercises the
    /// delegation but, running identical code on both sides, cannot catch a body mutation.
    nonisolated static func fastLaneConcentration(lane: [StockSageIdea], topN: Int = 3) -> FastLaneConcentration? {
        let top = Array(lane.prefix(Swift.max(0, topN)))
        guard top.count >= 2 else { return nil }
        let counts = Dictionary(grouping: top.map { StockSageAllocation.assetClass($0.symbol) }, by: { $0 })
            .mapValues(\.count)
        guard let dominant = counts.max(by: { $0.value < $1.value }) else { return nil }
        return FastLaneConcentration(dominantClass: dominant.key, count: dominant.value, total: top.count)
    }

    /// F4 (2026-07-09): does ANY of `lane`'s top-N (the exact setups a caller's "≈ +$N/week"
    /// dollarization sums) floor to 0 shares at this account/risk — i.e. is the header
    /// dollarizing a setup that literally isn't placeable at this size (the F1/F3 whole-share-
    /// flooring finding)? Reuses `StockSagePositionSizer.size` — the SAME sizer every "Size it
    /// now" line already calls — no new sizing math, no rank change, and the header's own dollar
    /// figure is untouched by this: it only gates whether a qualifier renders beside it.
    /// false (never flags) when account/riskFraction is unusable, or a lane idea has no stop to
    /// size against — only-real-data, matches this file's "unknown ⇒ no penalty" convention.
    nonisolated static func weeklyDollarsIncludesUnfundableRow(lane: [StockSageIdea], account: Double,
                                                               riskFraction: Double, maxConcurrent: Int = 3,
                                                               fxRatesToUSD: [String: Double] = [:]) -> Bool {
        // F3 wave-A (2026-07-16): fxRatesToUSD (ccy→USD) sizes non-USD rows FX-correctly —
        // the currency-mixed count over-flagged .SR rows as unfundable (~3.75× fewer shares).
        // Empty map (the default) = prior behavior byte-identical.
        guard account > 0, riskFraction > 0, account.isFinite, riskFraction.isFinite else { return false }
        for idea in lane.prefix(Swift.max(0, maxConcurrent)) {
            guard let stop = idea.advice.stopPrice,
                  let ps = StockSagePositionSizer.size(account: account, riskFraction: riskFraction,
                                                       entry: idea.price, stop: stop,
                                                       symbol: idea.symbol, fxRatesToUSD: fxRatesToUSD)
            else { continue }
            if ps.shares == 0 { return true }
        }
        return false
    }

    // ── FASTMONEY_BACKLOG #7 — crypto vs equity fast-lane board split + cross-correlation ──────
    //
    // fastLane() blends crypto (3d hold) and equity (12d hold) into one ranked list; the owner
    // still has to eyeball the mix. These three helpers are PURE compositions of existing,
    // already-tested primitives — no new ranking math, no new correlation math:
    //   • fastLaneByClass    partitions the EXISTING fastLane() order by StockSageAllocation.assetClass
    //     — a pure filter, does not re-rank.
    //   • cryptoRotationDominant sums the SAME per-idea `velocity(for:)` the weekly-R math already
    //     sums, just split by side.
    //   • laneCorrelation reuses StockSagePortfolioAnalytics.correlation/dailyReturns (the SAME
    //     Pearson-with-alignment primitive the portfolio heatmap and cluster-check already use).

    /// Crypto vs equity partition of the fast lane, each bucket keeping fastLane()'s existing
    /// growth-rate order — this only SPLITS the list, it never re-ranks. Every fastLane() member
    /// lands in exactly one bucket: expectedHoldDays(forSymbol:) already returns nil (so fastLane()
    /// excludes them) for anything that isn't Crypto or Equity (Index/FX), so nothing is dropped or
    /// double-counted by this split.
    nonisolated static func fastLaneByClass(_ ideas: [StockSageIdea], holds: VelocityHoldDays = .defaults,
                                            calibration: StockSageConvictionCalibration? = nil,
                                            earnings: [String: EarningsProximity] = [:],
                                            liquidity: [String: LiquidityProfile] = [:])
    -> (crypto: [StockSageIdea], equity: [StockSageIdea]) {
        let lane = fastLane(ideas, holds: holds, calibration: calibration, earnings: earnings, liquidity: liquidity)
        return (lane.filter { StockSageAllocation.assetClass($0.symbol) == "Crypto" },
                lane.filter { StockSageAllocation.assetClass($0.symbol) == "Equity" })
    }

    /// Is the fast lane's rotation dominated by 24/7 crypto? Compares the SUM of each side's
    /// velocity (EV/day — the same per-idea number expectedWeeklyR already sums): crypto's sum
    /// clearing 1.5× equity's sum flags the honest gap-risk warning (you can't hedge an overnight
    /// crypto move with a 9:30–4 equity position). false when there's no crypto velocity to compare
    /// (nothing to flag) — never manufactures a warning from an empty side.
    nonisolated static func cryptoRotationDominant(crypto: [StockSageIdea], equity: [StockSageIdea],
                                                   holds: VelocityHoldDays = .defaults,
                                                   calibration: StockSageConvictionCalibration? = nil) -> Bool {
        let cryptoSum = crypto.compactMap { velocity(for: $0, holds: holds, calibration: calibration) }.reduce(0, +)
        let equitySum = equity.compactMap { velocity(for: $0, holds: holds, calibration: calibration) }.reduce(0, +)
        guard cryptoSum > 0 else { return false }
        return cryptoSum > equitySum * 1.5
    }

    /// Live cross-correlation between the crypto and equity fast-lane boards: the AVERAGE Pearson
    /// correlation (StockSagePortfolioAnalytics.correlation — the SAME primitive the portfolio
    /// heatmap/cluster-check use) across every (crypto-symbol, equity-symbol) pair that has a
    /// usable history. `histories` is keyed by UPPERCASED symbol (daily closes, newest last) —
    /// supplied by the caller (e.g. StockSageStore, from StockSageQuoteService.fetchHistories), so
    /// this stays pure/network-free/testable. nil when either side has no symbol with ≥2 daily
    /// returns (nothing to correlate) — NOT a within-group correlation, and not a forecast.
    nonisolated static func laneCorrelation(crypto: [StockSageIdea], equity: [StockSageIdea],
                                            histories: [String: [Double]]) -> Double? {
        func returns(_ ideas: [StockSageIdea]) -> [[Double]] {
            ideas.compactMap { histories[$0.symbol.uppercased()] }
                 .map(StockSagePortfolioAnalytics.dailyReturns)
                 .filter { $0.count >= 2 }
        }
        let cryptoReturns = returns(crypto), equityReturns = returns(equity)
        guard !cryptoReturns.isEmpty, !equityReturns.isEmpty else { return nil }
        var sum = 0.0, pairs = 0
        for c in cryptoReturns {
            for e in equityReturns {
                // A zero-variance leg (flat/halted/illiquid) has an UNDEFINED correlation (0/0) —
                // excluded from the average rather than counted as an "uncorrelated" 0.
                guard let corr = StockSagePortfolioAnalytics.correlation(c, e) else { continue }
                sum += corr; pairs += 1
            }
        }
        return pairs > 0 ? sum / Double(pairs) : nil
    }

    /// Audit 2026-07-12 (ideas-card, laneCorrelation date-alignment): the closes-only overload above
    /// tail-index-pairs the two lanes' returns, so a crypto 7-day week vs an equity 5-day week
    /// correlates MISMATCHED calendar days (every crypto weekend bar shifts the pairing) — a
    /// meaningless number shown with a confident hedge verdict. This dated overload aligns EACH
    /// crypto×equity pair to its common calendar days (StockSagePortfolioAnalytics.alignByDate)
    /// before correlating, so the number measures the real cross-lane co-movement. Pure/testable;
    /// nil when no pair shares ≥2 common days. Same zero-variance exclusion as the sibling.
    nonisolated static func laneCorrelation(crypto: [StockSageIdea], equity: [StockSageIdea],
                                            dated histories: [String: [(date: Date, ret: Double)]]) -> Double? {
        func series(_ ideas: [StockSageIdea]) -> [[(date: Date, ret: Double)]] {
            ideas.compactMap { histories[$0.symbol.uppercased()] }.filter { $0.count >= 2 }
        }
        let cryptoSeries = series(crypto), equitySeries = series(equity)
        guard !cryptoSeries.isEmpty, !equitySeries.isEmpty else { return nil }
        var sum = 0.0, pairs = 0
        for c in cryptoSeries {
            for e in equitySeries {
                // Align this pair to its shared calendar days, THEN correlate. A pair with <2 common
                // days, or a zero-variance leg, is UNDEFINED → excluded (never counted as an
                // uncorrelated 0), same as the closes-only sibling.
                let aligned = StockSagePortfolioAnalytics.alignByDate([c, e])
                guard aligned.count == 2,
                      let corr = StockSagePortfolioAnalytics.correlation(aligned[0], aligned[1]) else { continue }
                sum += corr; pairs += 1
            }
        }
        return pairs > 0 ? sum / Double(pairs) : nil
    }

    nonisolated static let caveat =
        "EV uses an ESTIMATED win probability from conviction (not a real probability) and a −1R loss. It ranks payoff, it doesn't predict it — size with the cap and a stop."
}
