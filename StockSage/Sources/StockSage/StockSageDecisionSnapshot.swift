import Foundation

// MARK: - Unified decision snapshot (Slice A)
//
// A single immutable payload that composes ranking, gate, sizing, costs, and event/liquidity
// flags for one idea under one input state. This is ENGINE-ONLY in Slice A: no view wiring yet.
//
// Purpose:
// - Prevent silent drift across board/sheet/today/export by centralizing the computed facts.
// - Keep display labels honest (gross vs net, measured/fitted/assumed provenance).
// - Surface demotion/explainability reasons in one place.

struct StockSageDecisionSnapshot: Sendable, Equatable {
    enum RankReason: String, Sendable, Equatable {
        case lowConviction
        case belowNetCostFloor
        case earningsImminent
        case liquidityThin
        case costFails
        case regimeBanned
    }

    let idea: StockSageIdea

    // Core edge figures
    let ev: ExpectedValue?
    let velocityGross: Double?
    let netEVR: Double?
    let netVelocity: Double?
    let netRR: Double?

    // Flags / provenance
    let calibrationMethod: StockSageConvictionCalibration.Method?
    let calibrationTitle: String
    let calibrationHelp: String
    let earningsFlag: StockSageExpectedValue.EarningsRankFlag
    let floorFlag: StockSageExpectedValue.NetCostFloorFlag
    let liquidityProfile: LiquidityProfile?

    // Risk + execution checks
    // nil ⇒ gate not evaluated (no real risk % supplied) — honest, never a fabricated verdict.
    // F04 reached the detail-sheet/copy-plan surfaces (parsedRiskFraction guards there) but not
    // this shared snapshot, which silently defaulted to `?? 0.01` and always produced a verdict
    // (2nd-read hunt, 2026-07-08).
    let gate: TradeGateVerdict?
    let positionSize: PositionSize?

    // Explainability summary
    let rankReasons: [RankReason]

    nonisolated var hasMeasuredCalibration: Bool {
        guard let m = calibrationMethod else { return false }
        return m == .isotonicWilson || m == .beta
    }

    // Shared adapters for ideas card/sheet parity (Slice B wiring seam).
    var cardViewModel: IdeaCardViewModel {
        IdeaCardViewModel(
            symbol: idea.symbol,
            action: idea.advice.action.rawValue,
            evText: ev.map { String(format: "%+.2fR (gross)", $0.evR) },
            velocityText: velocityGross.map { String(format: "%+.3fR/day gross", $0) },
            netVelocityText: netVelocity.map { String(format: "%+.3fR/day net", $0) },
            gateBadge: gateBadge,
            earningsWarningBadge: earningsWarningBadge,
            floorWarningBadge: floorWarningBadge,
            hasEarningsWarning: hasEarningsWarning,
            hasFloorWarning: hasFloorWarning,
            warningBadges: warningBadges,
            calibrationTitle: calibrationTitle,
            calibrationHelp: calibrationHelp
        )
    }

    var detailViewModel: IdeaDetailViewModel {
        IdeaDetailViewModel(
            symbol: idea.symbol,
            action: idea.advice.action.rawValue,
            evText: ev.map { String(format: "%+.2fR (gross)", $0.evR) },
            velocityText: velocityGross.map { String(format: "%+.3fR/day gross", $0) },
            netVelocityText: netVelocity.map { String(format: "%+.3fR/day net", $0) },
            gateBadge: gateBadge,
            earningsWarningBadge: earningsWarningBadge,
            floorWarningBadge: floorWarningBadge,
            hasEarningsWarning: hasEarningsWarning,
            hasFloorWarning: hasFloorWarning,
            warningBadges: warningBadges,
            rankReasonCodes: rankReasons.map(\.rawValue),
            calibrationTitle: calibrationTitle,
            calibrationHelp: calibrationHelp
        )
    }

    private var earningsWarningBadge: String? {
        switch earningsFlag {
        case .demoted(let d): return "⚠︎ earnings ~\(d)d"
        case .approaching(let d): return "earnings ~\(d)d"
        case .clear, .unknown: return nil
        }
    }

    private var floorWarningBadge: String? {
        if case .belowFloor = floorFlag { return "below net-cost floor" }
        return nil
    }

    private var hasEarningsWarning: Bool {
        switch earningsFlag {
        case .demoted, .approaching: return true
        case .clear, .unknown: return false
        }
    }

    private var hasFloorWarning: Bool {
        floorFlag.isDeranked
    }

    private var gateBadge: String {
        guard let gate else { return "set risk %" }
        switch gate.decision {
        case .clear: return "CLEAR"
        case .caution: return "CAUTION"
        case .blocked: return "BLOCKED"
        }
    }

    private var warningBadges: [String] {
        var out: [String] = []
        if let earningsWarningBadge { out.append(earningsWarningBadge) }
        if let floorWarningBadge { out.append(floorWarningBadge) }

        if rankReasons.contains(.lowConviction) { out.append("low conviction") }
        if liquidityProfile?.tier == .thin { out.append("thin liquidity") }
        return out
    }
}

struct IdeaCardViewModel: Sendable, Equatable {
    let symbol: String
    let action: String
    let evText: String?
    let velocityText: String?
    let netVelocityText: String?
    let gateBadge: String
    let earningsWarningBadge: String?
    let floorWarningBadge: String?
    let hasEarningsWarning: Bool
    let hasFloorWarning: Bool
    let warningBadges: [String]
    let calibrationTitle: String
    let calibrationHelp: String
}

struct IdeaDetailViewModel: Sendable, Equatable {
    let symbol: String
    let action: String
    let evText: String?
    let velocityText: String?
    let netVelocityText: String?
    let gateBadge: String
    let earningsWarningBadge: String?
    let floorWarningBadge: String?
    let hasEarningsWarning: Bool
    let hasFloorWarning: Bool
    let warningBadges: [String]
    let rankReasonCodes: [String]
    let calibrationTitle: String
    let calibrationHelp: String
}

enum StockSageDecisionSnapshotBuilder {
    /// Build a deterministic decision snapshot for one idea using the SAME engine seams already
    /// used by ranking/today-plan/card surfaces. Slice A keeps this engine-only (no UI wiring).
    nonisolated static func build(
        idea: StockSageIdea,
        holds: VelocityHoldDays = .defaults,
        calibration: StockSageConvictionCalibration? = nil,
        earnings: [String: EarningsProximity] = [:],
        liquidity: [String: LiquidityProfile] = [:],
        account: Double? = nil,
        riskFraction: Double? = nil,
        regime: MarketRegime? = nil,
        maxRiskFraction: Double = 0.02,
        // F3 wave-A (2026-07-16): ccy→USD map for an FX-correct share count in the journaled
        // snapshot (.SR was under-sized ~3.75×); empty default = byte-identical.
        fxRatesToUSD: [String: Double] = [:]
    ) -> StockSageDecisionSnapshot {
        let ev = StockSageExpectedValue.ev(for: idea, calibration: calibration)
        let velocityGross = StockSageExpectedValue.velocity(for: idea, holds: holds, calibration: calibration)
        let netEVR = StockSageExpectedValue.netEVR(for: idea, calibration: calibration)
        let netVelocity = StockSageExpectedValue.netVelocity(for: idea, holds: holds, calibration: calibration)

        let netRR: Double? = {
            guard let stop = idea.advice.stopPrice, let target = idea.advice.targetPrice else { return nil }
            let (rate, days) = StockSageExpectedValue.financingCostInputs(for: idea)
            return StockSageNetEdge.netRR(symbol: idea.symbol, entry: idea.price, stop: stop, target: target,
                                          annualFinancingRate: rate, holdDays: days)
        }()

        let rrForGate: Double? = {
            if let netRR { return netRR }
            guard let stop = idea.advice.stopPrice, let target = idea.advice.targetPrice else { return nil }
            let risk = abs(idea.price - stop)
            guard risk > 0 else { return nil }
            return abs(target - idea.price) / risk
        }()

        let earningsFlag = StockSageExpectedValue.earningsRankFlag(for: idea, earnings: earnings)
        let floorFlag = StockSageExpectedValue.netCostFloorFlag(for: idea, holds: holds, calibration: calibration)
        let liq = liquidity[idea.symbol.uppercased()]

        // F04-parity (2nd-read hunt, 2026-07-08): the detail sheet/copy-plan already refuse to
        // fabricate a verdict when no real risk % was typed (guarded on `parsedRiskFraction`,
        // MarketsView.swift ~5054/~5935) — this shared builder was the one surface still defaulting
        // an unsupplied riskFraction to `?? 0.01` and always producing a CLEAR/CAUTION/BLOCKED
        // verdict. Evaluate ONLY when riskFraction is a real positive value; otherwise the gate is
        // honestly nil ("not evaluated"), matching the detail sheet's "set risk %" wording.
        let gate: TradeGateVerdict? = {
            guard let rf = riskFraction, rf > 0 else { return nil }
            return StockSageTradeGate.evaluate(
                hasStop: idea.advice.stopPrice != nil,
                rewardToRisk: rrForGate,
                riskFraction: rf,
                maxRiskFraction: maxRiskFraction,
                maxCorrelation: nil,
                daysToEarnings: earnings[idea.symbol.uppercased()]?.daysUntil,
                rrIsNet: netRR != nil
            )
        }()

        let size: PositionSize? = {
            guard let account, account > 0,
                  let rf = riskFraction, rf > 0,
                  let stop = idea.advice.stopPrice else { return nil }
            return StockSagePositionSizer.size(account: account, riskFraction: rf, entry: idea.price, stop: stop,
                                                symbol: idea.symbol, fxRatesToUSD: fxRatesToUSD)
        }()

        var reasons: [StockSageDecisionSnapshot.RankReason] = []
        if StockSageExpectedValue.isLowConviction(idea) { reasons.append(.lowConviction) }
        if floorFlag.isDeranked { reasons.append(.belowNetCostFloor) }
        if case .demoted = earningsFlag { reasons.append(.earningsImminent) }
        if liq?.tier == .thin { reasons.append(.liquidityThin) }
        // F2 (owner-signed 2026-07-10): the sized gate path passes the order notional so flat
        // per-order minimums (intl tiers) can bite; unsized calls (account/risk unset, or a
        // 0-share floor) stay byte-identical (the cost fn guards notional greater than 0).
        let f2Notional: Double? = size.map { Double($0.shares) * idea.price }
        if !clearsCostAfterFrictions(idea, calibration: calibration, orderNotional: f2Notional) { reasons.append(.costFails) }
        if let regime {
            if bannedFromTopRank(idea: idea, regime: regime) { reasons.append(.regimeBanned) }
        }

        let calTitle = calibration?.chipTitle ?? "win% assumed"
        let calHelp = calibration?.chipHelp
            ?? "No fitted calibration yet; using the conservative assumed win-probability prior (not measured from outcomes)."

        return StockSageDecisionSnapshot(
            idea: idea,
            ev: ev,
            velocityGross: velocityGross,
            netEVR: netEVR,
            netVelocity: netVelocity,
            netRR: netRR,
            calibrationMethod: calibration?.method,
            calibrationTitle: calTitle,
            calibrationHelp: calHelp,
            earningsFlag: earningsFlag,
            floorFlag: floorFlag,
            liquidityProfile: liq,
            gate: gate,
            positionSize: size,
            rankReasons: reasons
        )
    }

    // Same regime-ban semantics as StockSageExpectedValue rank keys (read-only mirror).
    private nonisolated static func bannedFromTopRank(idea: StockSageIdea, regime: MarketRegime) -> Bool {
        switch regime.state {
        case .crisis, .trendingBear:
            return idea.advice.action == .buy || idea.advice.action == .strongBuy
        case .trendingBull:
            return idea.advice.action == .sell || idea.advice.action == .reduce
        case .ranging:
            return false
        }
    }

    // Mirrors StockSageExpectedValue's internal cost-gate semantics (private there).
    private nonisolated static func clearsCostAfterFrictions(
        _ idea: StockSageIdea,
        calibration: StockSageConvictionCalibration?,
        orderNotional: Double? = nil
    ) -> Bool {
        guard let stop = idea.advice.stopPrice, let target = idea.advice.targetPrice else { return true }
        let costs = StockSageNetEdge.defaultCosts(forSymbol: idea.symbol)
        let (rate, days) = StockSageExpectedValue.financingCostInputs(for: idea)
        guard let ne = StockSageNetEdge.evaluate(entry: idea.price, stop: stop, target: target,
                                                 spreadBps: costs.spreadBps,
                                                 slippageBps: costs.slippageBps,
                                                 takerFeeBps: costs.takerFeeBps,
                                                 annualFinancingRate: rate,
                                                 holdDays: days,
                                                 perOrderMinimum: costs.perOrderMinimum,
                                                 orderNotional: orderNotional) else { return true }
        let p = StockSageExpectedValue.winProbEstimate(conviction: idea.advice.conviction, calibration: calibration)
        return ne.clearsCost(estWinProb: p)
    }
}
