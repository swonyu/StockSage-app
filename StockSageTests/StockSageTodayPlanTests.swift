import Testing
import Foundation
@testable import StockSage

// MARK: - Today's plan (pure compose)

struct StockSageTodayPlanTests {

    @Test("unverified quote age never exports an order checklist",
          arguments: [Optional<Double>.none, 600, -3600])
    func unverifiedQuoteExportsDraft(_ age: Double?) {
        let asOf = age.map { Date().addingTimeInterval(-$0) }
        let i = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
            .withLivePrice(100, asOf: asOf)
        let one = StockSageTodayPlan.build(idea: i, ev: nil, account: 10_000,
                                          riskFraction: 0.01, priceAsOf: asOf)
        let ranked = StockSageTodayPlan.rankedActions([i], account: 10_000, riskFraction: 0.01)
        #expect(ranked.count == 1)
        for text in [one, StockSageTodayPlan.copyAllText(ranked)] {
            #expect(text.contains("Draft only — refresh price"))
            #expect(!text.contains("Entry ~"))
            #expect(!text.contains(" | entry "))
            #expect(!text.contains("Clear to trade"))
        }
    }

    @Test("all three export builders agree at the 60-second boundary")
    func exportFreshnessBoundaries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(Double?, Bool)] = [(nil, false), (-0.001, false), (0, true),
            (59.999, true), (60, true), (60.001, false), (600, false), (.nan, false), (.infinity, false)]
        for (age, ready) in cases {
            let asOf = age.map { now.addingTimeInterval(-$0) }
            let i = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
                .withLivePrice(100, asOf: asOf)
            let today = StockSageTodayPlan.build(idea: i, ev: nil, account: 10_000,
                                                 riskFraction: 0.01, now: now)
            let ranked = StockSageTodayPlan.copyAllText(
                StockSageTodayPlan.rankedActions([i], account: 10_000, riskFraction: 0.01), now: now)
            let detail = StockSageTradePlan.text(symbol: i.symbol, market: i.market, price: i.price,
                advice: i.advice, rewardRisk: nil, size: nil, flags: [], priceAsOf: asOf, now: now)
            for text in [today, ranked, detail] {
                #expect(text.contains("Draft only — refresh price") == !ready)
            }
            #expect(today.contains("Entry ~") == ready)
            #expect(ranked.contains(" | entry ") == ready)
            #expect(detail.contains("Entry:") == ready)
            let allocation = AllocatedPosition(symbol: i.symbol, riskFraction: 0.01, shares: 10,
                dollarsAtRisk: 100, notional: 1000, halfKelly: 0.1, evR: 0.2)
            let allocationText = StockSageTradePlan.allocationLine(allocation, priceAsOf: asOf, now: now)
            #expect(allocationText.contains("Draft only — refresh price") == !ready)
            #expect(allocationText.contains("10 sh") == ready)
        }
    }

    @Test("ranked export suppresses only the unverified row; sample never supplies a live ticket")
    func mixedFreshnessAndSampleExports() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130).withLivePrice(100, asOf: now)
        let unknown = idea("ETH-USD", conviction: 0.9, stop: 90, target: 130).withLivePrice(100, asOf: nil)
        let plans = StockSageTodayPlan.rankedActions([fresh, unknown], account: 10_000, riskFraction: 0.01)
        let text = StockSageTodayPlan.copyAllText(plans, now: now)
        #expect(text.components(separatedBy: " | entry ").count == 2)
        #expect(text.contains("ETH-USD: PRICE NOT LIVE — quote time is unknown"))
        let sample = StockSageTodayPlan.copyAllText(plans, isSample: true, now: now)
        #expect(sample.contains("SAMPLE DATA"))
        #expect(!sample.contains(" | entry "))
        #expect(fresh.advice == unknown.advice, "export status does not alter the underlying analysis")
    }

    @Test("a retained share/save payload expires even without a new view render")
    func delayedShareCannotExportOldTicket() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let document = PlanShareDocument(planText: "Entry: 100\nStop: 90\nSize: 10 shares",
                                         symbol: "AAPL", priceAsOf: now, isSample: false)
        #expect(document.text(at: now.addingTimeInterval(60)).contains("Entry:"))
        let late = document.text(at: now.addingTimeInterval(60.001))
        #expect(late.contains("Draft only — refresh price"))
        #expect(!late.contains("Entry:") && !late.contains("Size:"))
    }

    private func idea(_ symbol: String, action: TradeAdvice.Action = .strongBuy, conviction: Double,
                      stop: Double?, target: Double?) -> StockSageIdea {
        StockSageIdea(symbol: symbol, market: "M", price: 100,
                      advice: TradeAdvice(action: action, conviction: conviction, regime: .bullTrend, rationale: [],
                                          stopPrice: stop, targetPrice: target, suggestedWeight: 0.05, caveat: "x"),
                      spark: [], priceAsOf: Date())
    }

    @Test func composesBestGateSizeAndCaveat() {
        let i = idea("BTC-USD", conviction: 0.9, stop: 90, target: 130)
        let plan = StockSageTodayPlan.build(idea: i, ev: StockSageExpectedValue.ev(for: i),
                                            account: 10_000, riskFraction: 0.01)
        #expect(plan.contains("BTC-USD"))
        #expect(plan.contains("Gate"))
        #expect(plan.contains("Clear to trade"))          // stop + 4:1 RR + 1% risk → clears
        #expect(plan.lowercased().contains("stop"))
        #expect(plan.lowercased().contains("estimate"))   // honesty
        #expect(plan.contains("1.") && plan.contains("2.") && plan.contains("3."))
        #expect(plan.contains("shares"))                  // size present (account+risk supplied)
    }

    // T15 (rotation-3 triage): build()'s size segment dropped the "$" before the dollars-at-risk
    // figure ("≈ 150 at risk") while every sibling surface (copyAllText's "≈$150 at risk",
    // MarketsTodayActionsCard's "≈$150 at risk") already had it — the same figure read as a
    // bare share count next door. Hand-derived (StockSagePositionSizer.size, entry=100/stop=90):
    // riskPerShare = |100-90| = 10; riskBudget = 10,000 × 0.01 = 100; shares = floor(100/10) = 10;
    // dollarsAtRisk = 10 × 10 = 100; pctOfAccount = (10 × 100)/10,000 × 100 = 10%.
    @Test func sizeSegmentDollarFigureCarriesADollarSign() {
        // AAPL is USD, so the at-risk amount correctly reads "$100". Audit 2026-07-12 (wave-2 #1):
        // the size segment now routes through StockSageCurrency.approxAmount (so a NON-USD symbol
        // reads its own currency instead of a false "$") — for a USD symbol approxAmount returns
        // "≈$100" (no space after ≈), so the exact string tightened from "≈ $100" to "≈$100". The
        // value is unchanged and still correct; only the format was normalized to the shared helper.
        let i = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        let plan = StockSageTodayPlan.build(idea: i, ev: StockSageExpectedValue.ev(for: i),
                                            account: 10_000, riskFraction: 0.01)
        #expect(plan.contains("10 shares ≈$100 at risk (10% of acct)"))
    }

    @Test func sampleDataIsFlaggedInTheCopiedPlan() {
        let i = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        // Sample data → the copied plan (pasted into a broker) must carry the SAMPLE warning.
        let sample = StockSageTodayPlan.build(idea: i, ev: StockSageExpectedValue.ev(for: i),
                                              account: 10_000, riskFraction: 0.01, isSample: true)
        #expect(sample.uppercased().contains("SAMPLE"))
        #expect(sample.lowercased().contains("re-price"))
        // Live data (default) → no SAMPLE line, byte-for-byte the original behavior.
        let live = StockSageTodayPlan.build(idea: i, ev: StockSageExpectedValue.ev(for: i),
                                            account: 10_000, riskFraction: 0.01)
        #expect(!live.uppercased().contains("SAMPLE"))
    }

    // Round-H: a live scan (isSample == false) can still be served off a same-UTC-day cache
    // whose price bar is from a PRIOR trading day — the copied plan is the one artifact pasted
    // into a broker, so it must carry the SAME staleness warning the board card/detail sheet
    // already show, independent of isSample.
    @Test func staleCachePriceIsFlaggedInTheCopiedPlanIndependentOfIsSample() {
        let i = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        let priorDay = Calendar(identifier: .gregorian).date(byAdding: .day, value: -3, to: Date())!
        let stale = StockSageTodayPlan.build(idea: i, ev: StockSageExpectedValue.ev(for: i),
                                             account: 10_000, riskFraction: 0.01,
                                             isSample: false, priceAsOf: priorDay)
        #expect(stale.uppercased().contains("PRICE NOT LIVE"))
        #expect(stale.lowercased().contains("re-price"))
        #expect(!stale.uppercased().contains("SAMPLE"))   // isSample stayed false — no SAMPLE line

        // Same-UTC-day priceAsOf → no warning.
        let sameDay = StockSageTodayPlan.build(idea: i, ev: StockSageExpectedValue.ev(for: i),
                                               account: 10_000, riskFraction: 0.01,
                                               isSample: false, priceAsOf: Date())
        #expect(!sameDay.uppercased().contains("PRICE NOT LIVE"))

        // Missing source time is unknown, not evidence of freshness.
        let nilAsOf = StockSageTodayPlan.build(idea: i.withLivePrice(i.price, asOf: nil), ev: StockSageExpectedValue.ev(for: i),
                                               account: 10_000, riskFraction: 0.01)
        #expect(nilAsOf.contains("Draft only — refresh price"))
        #expect(!nilAsOf.contains("Entry ~"))
    }

    // A3: the analysis (advice/EV) can be >4h stale even when the price bar is today's — the
    // card shows "Analysis over 4h old"; the exported plan carries the same flag when the caller
    // passes analysisStale: true. Defaulted false ⇒ existing callers/tests are byte-unchanged.
    @Test func staleAnalysisIsFlaggedInTheCopiedPlanIndependentOfPrice() {
        let i = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        let staleAnalysis = StockSageTodayPlan.build(idea: i, ev: StockSageExpectedValue.ev(for: i),
                                                     account: 10_000, riskFraction: 0.01,
                                                     isSample: false, priceAsOf: Date(),  // price fresh today
                                                     analysisStale: true)
        #expect(staleAnalysis.uppercased().contains("ANALYSIS OVER 4H OLD"))
        #expect(!staleAnalysis.uppercased().contains("PRICE NOT LIVE"))   // price axis stayed fresh

        // Default (analysisStale omitted) → no analysis flag.
        let fresh = StockSageTodayPlan.build(idea: i, ev: StockSageExpectedValue.ev(for: i),
                                             account: 10_000, riskFraction: 0.01)
        #expect(!fresh.uppercased().contains("ANALYSIS OVER 4H OLD"))
    }

    @Test func noStopWarnsAndGateBlocks() {
        let i = idea("X", conviction: 0.9, stop: nil, target: nil)
        // F04-parity (2nd-read hunt, 2026-07-08): riskFraction must be supplied for the gate to
        // evaluate at all now — this test pins "no stop → gate blocks" given a real risk %, not
        // the honest-nil-gate path (that's rankedActionGateIsNilWhenRiskFractionNotSupplied below).
        let plan = StockSageTodayPlan.build(idea: i, ev: nil, account: nil, riskFraction: 0.01)
        // RE-PINNED 2026-07-09 (EXPORT-W4-1 parity): build() now mirrors the sheet's export —
        // a BLOCKED setup (here: no stop) returns a status report, never lines of a ticket.
        // The old pins ("no stop" prose + "Don't take this trade" + ticket scaffolding) belong
        // to the pre-parity contract; the refusal + reason + no-size guarantees remain.
        #expect(plan.contains("BLOCKED by the pre-trade gate"))
        #expect(plan.contains("No order plan exported"))
        #expect(plan.contains("FAIL"))                    // the no-stop failure is named
        #expect(!plan.contains("shares"))                 // still never a sized line
    }

    // F04-parity (2nd-read hunt, 2026-07-08): nil riskFraction must NOT fabricate a gate verdict
    // (the old `rf > 0 ? rf : 0.01` default always produced one) — mirrors
    // rankedActionGateIsNilWhenRiskFractionNotSuppliedAndCopyTextSaysNotEvaluated in
    // StockSageTodayPlanRankedTests.swift, but for the single-idea `build()` surface (the "Copy
    // today's plan" button, MarketsView.swift ~3878/~4215).
    @Test func rankedActionGateIsNilWhenRiskFractionNotSuppliedAndCopyTextSaysNotEvaluated() {
        let i = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        let plan = StockSageTodayPlan.build(idea: i, ev: nil, account: nil, riskFraction: nil)
        // Verbatim wording match with the sheet's copy-plan (MarketsView.swift ~5064-5065) and
        // copyAllText — all surfaces must agree on the exact same honest phrasing.
        #expect(plan.contains("Pre-trade gate: not evaluated — enter risk % to see the verdict."))
        #expect(!plan.contains("Clear to trade"))
        #expect(!plan.contains("Proceed with caution"))
        #expect(!plan.contains("Don't take this trade"))
    }

    // MARK: - TODAY-PARITY: held-position context (defaulted absent, held → present)

    @Test func heldContextAbsentWithoutPositions() {
        let i = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        // Defaulted `positions: []` — existing callers/tests byte-unchanged, no holds line.
        let plan = StockSageTodayPlan.build(idea: i, ev: StockSageExpectedValue.ev(for: i),
                                            account: 10_000, riskFraction: 0.01)
        #expect(!plan.contains("holds"))
        #expect(StockSagePortfolio.holding(for: "AAPL", in: []) == nil)   // pins the absent case
    }

    @Test func heldContextPresentWhenPositionsResolveViaStockSagePortfolioHolding() {
        let i = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        let positions = [PortfolioPosition(symbol: "AAPL", shares: 30, costBasis: 90)]
        let plan = StockSageTodayPlan.build(idea: i, ev: StockSageExpectedValue.ev(for: i),
                                            account: 10_000, riskFraction: 0.01, positions: positions)
        // Pinned against the SAME source-of-truth StockSagePortfolio.holding call, not a
        // re-derivation — can't silently diverge from the ideas board's own held-shares math.
        let expectedShares = StockSagePortfolio.holding(for: "AAPL", in: positions)?.shares
        #expect(expectedShares == 30)
        #expect(plan.contains("holds 30 sh"))
    }

    // EXPORT-W4-1 parity (2026-07-09, from the blocked-fixture QA): build() fed the best-opp
    // card/CTA "Copy today's plan" a full actionable ticket for a BLOCKED trade (verdict
    // buried mid-list) while the sheet's export auto-skips. Same rule now, pinned here.
    @Test func blockedIdeaExportsAStatusReportNeverATicket() {
        // Risk 3% (> the 2% cap) blocks the gate deterministically — same lever as the
        // markets_ideas_blocked QA fixture; entry/stop give a clean 2:1 gross setup.
        let idea = StockSageIdea(
            symbol: "BLK", market: "M", price: 100,
            advice: TradeAdvice(action: .buy, conviction: 0.8, regime: .bullTrend, rationale: [],
                                stopPrice: 90, targetPrice: 120, suggestedWeight: 0.05, caveat: "x"),
            spark: [], priceAsOf: Date())
        let text = StockSageTodayPlan.build(idea: idea, ev: nil, account: 10_000, riskFraction: 0.03)
        #expect(text.contains("BLOCKED by the pre-trade gate"))
        #expect(text.contains("No order plan exported"))
        #expect(!text.contains("Entry"))    // no actionable ticket lines
        #expect(!text.contains("shares"))
        // The non-blocked control at 1% still exports the ticket (guards the skip's scope).
        let ok = StockSageTodayPlan.build(idea: idea, ev: nil, account: 10_000, riskFraction: 0.01)
        #expect(ok.contains("Entry"))
        #expect(!ok.contains("No order plan exported"))
    }

    // F-review export-parity fix (2026-07-10): build()'s ticket line rendered "0 shares ≈ $0
    // at risk" with NO unfundability disclosure while the on-screen row (MarketsTodayActionsCard's
    // unfundableSuffix, StockSagePositionSizer.summaryLine) already discloses it — a pasted plan
    // read as a placeable order. Hand-derived: entry 100 / stop 90 → riskPerShare $10; $1 account
    // at 1% risk → riskBudget $0.01 ÷ $10 = 0.001, floors to 0 shares (StockSagePositionSizer.size).
    @Test func buildDisclosesUnfundableZeroShareSizing() {
        let i = idea("AAPL", conviction: 0.9, stop: 90, target: 130)
        let unfundable = StockSageTodayPlan.build(idea: i, ev: StockSageExpectedValue.ev(for: i),
                                                   account: 1, riskFraction: 0.01)
        #expect(unfundable.contains("0 shares"))
        #expect(unfundable.contains("below the 1-share minimum at your account size"))
        // Control: a comfortably-fundable account gets the size line WITHOUT the clause — the
        // fix must not fire on every sized row, only the genuinely-unfundable one.
        let fundable = StockSageTodayPlan.build(idea: i, ev: StockSageExpectedValue.ev(for: i),
                                                 account: 100_000, riskFraction: 0.01)
        #expect(fundable.contains("shares"))
        #expect(!fundable.contains("below the 1-share minimum"))
    }

    // F3 wave-A (2026-07-16): the FX map makes the plan's share count FX-correct. Hand-derived
    // from the sizer's contract (never the code): the fixture builds at price 100, stop 92 →
    // risk/share 8 SAR; $10,000 × 1% = $100 budget; SAR→USD = 1/3.75 ⇒ 37,500 SAR account,
    // 375 SAR budget → floor(375/8) = 46 shares, at-risk 368 SAR (≈$98 = the stated ~1%).
    // The currency-mixed path gave floor(100/8) = 12 shares (≈$25.6 = 0.26%). Without the map
    // (default [:]) a plan must now be blocked rather than reproduce the currency-mixed count.
    @Test func fxMapMakesTheSRShareCountMatchTheStatedRiskFraction() {
        let i = idea("2222.SR", conviction: 0.9, stop: 92, target: 132)   // 4:1 gross — the clearing ratio the BTC fixture pins
        let withFX = StockSageTodayPlan.build(idea: i, ev: StockSageExpectedValue.ev(for: i),
                                              account: 10_000, riskFraction: 0.01,
                                              fxRatesToUSD: ["SAR": 1.0 / 3.75])
        #expect(withFX.contains("46 shares"))
        #expect(withFX.contains("368 SAR"))               // native at-risk via approxAmount
        let withoutFX = StockSageTodayPlan.build(idea: i, ev: StockSageExpectedValue.ev(for: i),
                                                 account: 10_000, riskFraction: 0.01)
        #expect(!withoutFX.contains("12 shares"))
        #expect(withoutFX.contains("FX rate unavailable or invalid"))
        #expect(withoutFX.contains("No order plan exported"))
    }
}
