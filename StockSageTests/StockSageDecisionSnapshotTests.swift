import Testing
@testable import StockSage

struct StockSageDecisionSnapshotTests {

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
