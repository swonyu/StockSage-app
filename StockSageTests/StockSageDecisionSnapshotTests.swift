import Testing
@testable import StockSage

struct StockSageDecisionSnapshotTests {

    @Test func sizedMinimumFeesReachGateMetricsAndCopiedPlan() throws {
        let idea = SageFix.idea("SAP.DE", conviction: 0.9, action: .strongBuy,
                                rr: 3, price: 100, riskDistance: 1)
        let fx = ["EUR": 1.1]
        let snap = StockSageDecisionSnapshotBuilder.build(idea: idea, account: 120,
                                                         riskFraction: 0.01, fxRatesToUSD: fx)
        let size = try #require(snap.positionSize)
        #expect(size.shares == 1)
        let costs = StockSageNetEdge.defaultCosts(forSymbol: idea.symbol)
        let edge = try #require(StockSageNetEdge.evaluate(entry: 100, stop: 99, target: 103,
            spreadBps: costs.spreadBps, slippageBps: costs.slippageBps,
            takerFeeBps: costs.takerFeeBps,
            winProb: StockSageExpectedValue.winProbEstimate(conviction: 0.9),
            perOrderMinimum: costs.perOrderMinimum, orderNotional: size.notional))
        #expect(snap.netRR == edge.netRR)
        #expect(snap.netEVR == edge.netExpectancyR)
        let hold = try #require(StockSageExpectedValue.expectedHoldDays(for: idea))
        #expect(snap.netVelocity == edge.netExpectancyR.map { $0 / hold })
        #expect(snap.floorFlag.isDeranked)
        #expect(snap.rankReasons.contains(.costFails))
        #expect(snap.gate?.decision == .blocked)
        let copied = StockSageTodayPlan.build(idea: idea, ev: snap.ev, account: 120,
            riskFraction: 0.01, fxRatesToUSD: fx)
        #expect(copied.contains("No order plan exported"))
        #expect(!copied.contains("Entry ~"))
        let plan = try #require(StockSageTodayPlan.rankedActions([idea], account: 120,
            riskFraction: 0.01, fxRatesToUSD: fx).first)
        #expect(plan.gate == snap.gate)
        #expect(plan.netVelocityRank == snap.netVelocity)
        #expect(plan.netCostFloorFlag == snap.floorFlag)
        let copiedAll = StockSageTodayPlan.copyAllText([plan])
        #expect(copiedAll.contains("No order plan exported"))
        #expect(!copiedAll.contains("entry "))
    }

    @Test func snapshotMirrorsCoreExpectedValueFields() {
        let idea = SageFix.idea("AAPL", conviction: 0.82, action: .strongBuy, rr: 2.0, price: 100, riskDistance: 10)

        let snap = StockSageDecisionSnapshotBuilder.build(idea: idea)

        #expect(snap.ev == StockSageExpectedValue.ev(for: idea))
        #expect(snap.velocityGross == StockSageExpectedValue.velocity(for: idea))
        #expect(snap.netEVR == StockSageExpectedValue.netEVR(for: idea))
        #expect(snap.netVelocity == StockSageExpectedValue.netVelocity(for: idea))
        #expect(snap.floorFlag == StockSageExpectedValue.netCostFloorFlag(for: idea))
        #expect(snap.earningsFlag == .unknown)
    }

    @Test func sizedCostsRecalculateForFXSizeAndMissingInputs() throws {
        for action in [TradeAdvice.Action.buy, .sell] {
            let idea = SageFix.idea("SAP.DE", conviction: 0.9, action: action, rr: 3, price: 100, riskDistance: 1)
            let small = StockSageDecisionSnapshotBuilder.build(idea: idea, account: 120, riskFraction: 0.01, fxRatesToUSD: ["EUR": 1.1])
            let large = StockSageDecisionSnapshotBuilder.build(idea: idea, account: 12_000, riskFraction: 0.01, fxRatesToUSD: ["EUR": 1.1])
            let differentFX = StockSageDecisionSnapshotBuilder.build(idea: idea, account: 120, riskFraction: 0.01, fxRatesToUSD: ["EUR": 0.5])
            #expect(small.positionSize?.shares == 1)
            #expect(differentFX.positionSize?.shares == 2)
            #expect(try #require(small.netEVR) < #require(differentFX.netEVR))
            #expect(try #require(differentFX.netEVR) < #require(large.netEVR))
            // Short financing is still priced: a large short can be CAUTION, not CLEAR.
            #expect(large.gate?.decision == (action == .sell ? .caution : .clear))
            #expect(small.costSizeNote?.contains("1-share order") == true)
            let noFX = StockSageDecisionSnapshotBuilder.build(idea: idea, account: 120, riskFraction: 0.01)
            #expect(noFX.positionSize == nil)
            #expect(noFX.gate?.decision == .blocked)
            let zero = StockSageDecisionSnapshotBuilder.build(idea: idea, account: 10, riskFraction: 0.01, fxRatesToUSD: ["EUR": 1.1])
            #expect(zero.positionSize?.shares == 0)
            #expect(zero.gate?.decision == .blocked)
            let unsized = StockSageDecisionSnapshotBuilder.build(idea: idea, riskFraction: 0.01, fxRatesToUSD: ["EUR": 1.1])
            #expect(unsized.gate?.decision == .caution)
            #expect(unsized.netRR == StockSageNetEdge.netRR(for: idea))
            #expect(unsized.costSizeNote?.contains("exclude per-order") == true)
            let huge = StockSageDecisionSnapshotBuilder.build(idea: idea, account: 1e12, riskFraction: 0.01, fxRatesToUSD: ["EUR": 1.1])
            let hugeShares = try #require(huge.positionSize?.shares)
            #expect(huge.costSizeNote?.contains("\(hugeShares)-share order") == true)
        }
    }

    @Test func sizedRankingAndAllocationRejectMinimumFeeLosers() throws {
        let feeLoser = SageFix.idea("SAP.DE", conviction: 1, action: .strongBuy, rr: 3, price: 100, riskDistance: 1)
        let clean = SageFix.idea("MSFT", conviction: 0.8, action: .buy, rr: 3, price: 100, riskDistance: 1)
        for mode in [StockSageTodayPlan.RankedMode.fastestCompounding, .equityExecutableFirst] {
            let first = StockSageTodayPlan.rankedActions([feeLoser, clean], account: 120, riskFraction: 0.01,
                mode: mode, max: 1, fxRatesToUSD: ["EUR": 1.1]).first
            #expect(first?.symbol == "MSFT")
        }
        let allocation = StockSageCapitalAllocator.allocate(ideas: [feeLoser], account: 120,
            maxHeat: 0.01, fxRatesToUSD: ["EUR": 1.1])
        #expect(allocation.positions.isEmpty)
        #expect(allocation.totalHeat == 0)
        #expect(allocation.fundableCandidateCount == 0)
        #expect(allocation.caveat.contains("Excluded after final-size cost check: SAP.DE"))
        let add = try #require(StockSageCapitalAllocator.suggestAdd(idea: feeLoser, openTrades: [],
            holdings: [], candidateReturns: [], account: 120, maxHeat: 0.01, fxRatesToUSD: ["EUR": 1.1]))
        #expect(!add.approved)
        #expect(add.reason.contains("per-order broker minimums"))
    }

    @Test func snapshotCapturesDemotionReasonsFromInputs() {
        let idea = SageFix.idea("XYZ", conviction: 0.30, action: .buy, rr: 2.0, price: 100, riskDistance: 10)
        let earnings = ["XYZ": EarningsProximity(daysUntil: 2, severity: .imminent)]
        let liquidity = ["XYZ": LiquidityProfile(avgDollarVolume: 10_000, tier: .thin)]

        let snap = StockSageDecisionSnapshotBuilder.build(
            idea: idea,
            earnings: earnings,
            liquidity: liquidity
        )

        #expect(snap.rankReasons.contains(.lowConviction))
        #expect(snap.rankReasons.contains(.earningsImminent))
        #expect(snap.rankReasons.contains(.liquidityThin))
    }

    @Test func snapshotGateAndSizingMatchEngineSeams() {
        let idea = SageFix.idea("MSFT", conviction: 0.85, action: .strongBuy, rr: 2.0, price: 100, riskDistance: 10)

        let snap = StockSageDecisionSnapshotBuilder.build(
            idea: idea,
            account: 10_000,
            riskFraction: 0.01
        )

        let expectedSize = StockSagePositionSizer.size(account: 10_000, riskFraction: 0.01, entry: 100, stop: 90)
        #expect(snap.positionSize == expectedSize)

        let expectedGate = StockSageTradeGate.evaluate(
            hasStop: true,
            rewardToRisk: snap.netRR,
            riskFraction: 0.01,
            rrIsNet: true
        )
        #expect(snap.gate == expectedGate)   // riskFraction: 0.01 supplied above ⇒ gate is non-nil
    }

    // F04-parity (2nd-read hunt, 2026-07-08): the detail sheet and copy-plan already refuse to
    // fabricate a verdict when no real risk % was typed — this builder was still silently
    // defaulting an unsupplied riskFraction to `?? 0.01` and always producing a CLEAR/CAUTION/
    // BLOCKED verdict via StockSageTradeGate.evaluate. The gate must now be honestly nil.
    @Test func snapshotGateIsNilWhenRiskFractionIsNotSupplied() {
        let idea = SageFix.idea("MSFT", conviction: 0.85, action: .strongBuy, rr: 2.0, price: 100, riskDistance: 10)

        let noRisk = StockSageDecisionSnapshotBuilder.build(idea: idea)
        #expect(noRisk.gate == nil)

        let zeroRisk = StockSageDecisionSnapshotBuilder.build(idea: idea, riskFraction: 0)
        #expect(zeroRisk.gate == nil)

        let negativeRisk = StockSageDecisionSnapshotBuilder.build(idea: idea, riskFraction: -0.01)
        #expect(negativeRisk.gate == nil)

        // A real positive risk % still produces an actual verdict (not swallowed by the fix) —
        // mirrors the engine call directly rather than hardcoding a decision, matching
        // snapshotGateAndSizingMatchEngineSeams' own pattern above.
        let withRisk = StockSageDecisionSnapshotBuilder.build(idea: idea, riskFraction: 0.01)
        #expect(withRisk.gate != nil)
        let expectedWithRiskGate = StockSageTradeGate.evaluate(
            hasStop: true,
            rewardToRisk: withRisk.netRR,
            riskFraction: 0.01,
            rrIsNet: true
        )
        #expect(withRisk.gate == expectedWithRiskGate)
    }

    @Test func snapshotAddsRegimeBannedReasonForBuyInCrisis() {
        let idea = SageFix.idea("NVDA", conviction: 0.9, action: .strongBuy, rr: 2.0, price: 100, riskDistance: 10)
        let crisis = MarketRegime(state: .crisis, riskScore: -1.0, signals: [], sizingBias: 0.25, caveat: "x")

        let snap = StockSageDecisionSnapshotBuilder.build(idea: idea, regime: crisis)

        #expect(snap.rankReasons.contains(.regimeBanned))
    }

    @Test func snapshotCalibrationProvenanceFlagsMeasuredVsAssumed() {
        let idea = SageFix.idea("AMD", conviction: 0.8, action: .buy, rr: 2.0, price: 100, riskDistance: 10)

        let noCal = StockSageDecisionSnapshotBuilder.build(idea: idea)
        #expect(noCal.calibrationMethod == nil)
        #expect(noCal.calibrationTitle == "win% assumed")
        #expect(noCal.hasMeasuredCalibration == false)

        let betaCal = StockSageConvictionCalibration(
            bins: [.init(upper: 1.0, winProb: 0.58, n: 120)],
            sampleSize: 120,
            method: .beta
        )
        let measured = StockSageDecisionSnapshotBuilder.build(idea: idea, calibration: betaCal)
        #expect(measured.calibrationMethod == .beta)
        #expect(measured.hasMeasuredCalibration)
    }

    @Test func cardAndDetailAdaptersShareParityFields() {
        let idea = SageFix.idea("AAPL", conviction: 0.84, action: .strongBuy, rr: 2.0, price: 100, riskDistance: 10)
        let snap = StockSageDecisionSnapshotBuilder.build(idea: idea)

        let card = snap.cardViewModel
        let detail = snap.detailViewModel

        #expect(card.symbol == detail.symbol)
        #expect(card.action == detail.action)
        #expect(card.evText == detail.evText)
        #expect(card.velocityText == detail.velocityText)
        #expect(card.netVelocityText == detail.netVelocityText)
        #expect(card.gateBadge == detail.gateBadge)
        #expect(card.earningsWarningBadge == detail.earningsWarningBadge)
        #expect(card.floorWarningBadge == detail.floorWarningBadge)
        #expect(card.hasEarningsWarning == detail.hasEarningsWarning)
        #expect(card.hasFloorWarning == detail.hasFloorWarning)
        #expect(card.warningBadges == detail.warningBadges)
        #expect(card.calibrationTitle == detail.calibrationTitle)
        #expect(card.calibrationHelp == detail.calibrationHelp)
    }

    @Test func adaptersSurfaceWarningsAndReasonCodesFromSnapshot() {
        let idea = SageFix.idea("XYZ", conviction: 0.30, action: .buy, rr: 2.0, price: 100, riskDistance: 10)
        let earnings = ["XYZ": EarningsProximity(daysUntil: 2, severity: .imminent)]
        let liquidity = ["XYZ": LiquidityProfile(avgDollarVolume: 10_000, tier: .thin)]

        let snap = StockSageDecisionSnapshotBuilder.build(idea: idea, earnings: earnings, liquidity: liquidity)
        let card = snap.cardViewModel
        let detail = snap.detailViewModel

        #expect(card.warningBadges.contains("low conviction"))
        #expect(card.warningBadges.contains("thin liquidity"))
        #expect(card.warningBadges.contains(where: { $0.contains("earnings") }))
        #expect(card.earningsWarningBadge != nil)
        #expect(card.hasEarningsWarning)
        #expect(detail.rankReasonCodes.contains("lowConviction"))
        #expect(detail.rankReasonCodes.contains("earningsImminent"))
        #expect(detail.rankReasonCodes.contains("liquidityThin"))
        #expect(detail.earningsWarningBadge != nil)
        #expect(detail.hasEarningsWarning)
    }

    @Test func adaptersMirrorNetCostFloorWarningFromSnapshotFlag() {
        let idea = SageFix.idea("FLOOR", conviction: 0.45, action: .buy, rr: 1.2, price: 100, riskDistance: 10)
        let snap = StockSageDecisionSnapshotBuilder.build(idea: idea)

        let card = snap.cardViewModel
        let detail = snap.detailViewModel
        let expectsFloorWarning = snap.floorFlag.isDeranked

        #expect(card.warningBadges.contains("below net-cost floor") == expectsFloorWarning)
        #expect((card.floorWarningBadge != nil) == expectsFloorWarning)
        #expect(card.hasFloorWarning == expectsFloorWarning)
        #expect(detail.warningBadges.contains("below net-cost floor") == expectsFloorWarning)
        #expect((detail.floorWarningBadge != nil) == expectsFloorWarning)
        #expect(detail.hasFloorWarning == expectsFloorWarning)
        #expect(detail.rankReasonCodes.contains("belowNetCostFloor") == expectsFloorWarning)
    }
}
