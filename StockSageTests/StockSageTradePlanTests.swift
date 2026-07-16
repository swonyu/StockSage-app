import Testing
import Foundation
@testable import StockSage

// MARK: - Trade-plan export (pure)

struct StockSageTradePlanTests {

    private func advice() -> TradeAdvice {
        TradeAdvice(action: .buy, conviction: 0.72, regime: .bullTrend,
                    rationale: ["50DMA rising", "RSI not overbought"],
                    stopPrice: 95, targetPrice: 124, suggestedWeight: 0.08,
                    caveat: "Not a guarantee — manage your risk.")
    }

    @Test func planContainsTheKeyLinesAndCaveat() {
        let rr = StockSageRewardRisk.assess(entry: 100, stop: 95, target: 124)   // ratio 4.8 → strong
        let size = StockSagePositionSizer.size(account: 10_000, riskFraction: 0.01, entry: 100, stop: 95)
        let flags = [RiskFlag(label: "Earnings ≤3d", level: .high)]
        let plan = StockSageTradePlan.text(symbol: "AAPL", market: "NASDAQ", price: 100,
                                           advice: advice(), rewardRisk: rr, size: size, flags: flags)
        #expect(plan.contains("TRADE PLAN — AAPL (NASDAQ)"))
        #expect(plan.contains("Action: Buy"))
        #expect(plan.contains("Entry: 100.00"))
        #expect(plan.contains("Stop: 95.00"))
        #expect(plan.contains("Target: 124.00"))
        #expect(plan.contains("R:R:"))
        #expect(plan.contains("Size: 20 shares"))          // $100 budget ÷ $5 stop = 20
        #expect(plan.contains("Risk flags: Earnings ≤3d"))
        #expect(plan.contains("Why: 50DMA rising; RSI not overbought"))
        #expect(plan.contains("Not a guarantee"))          // the caveat is always present
    }

    // Audit 2026-07-12 (export-parity): the pasted-into-broker plan hardcoded "$" on the
    // native-currency dollarsAtRisk, so a .SR/.L idea's Size line was ~3.75×/100× mislabeled AND
    // diverged from the now-currency-correct on-screen sheet. Hand-derived: entry 100, stop 95 →
    // risk/share 5; account 10000 × 1% = 100 budget ÷ 5 = 20 shares; dollarsAtRisk = 20×5 = 100 (SAR,
    // no minor-unit ÷100). approxAmount(100, "1120.SR") == "≈100 SAR" — the Size line must read the
    // symbol's own currency, never a bare "$".
    @Test func sizeLineLabelsAtRiskInTheSymbolsOwnCurrencyNotDollars() {
        let size = StockSagePositionSizer.size(account: 10_000, riskFraction: 0.01, entry: 100, stop: 95)
        // A Saudi symbol → SAR, not "$".
        let sr = StockSageTradePlan.text(symbol: "1120.SR", market: "Tadawul", price: 100,
                                         advice: advice(), rewardRisk: nil, size: size, flags: [])
        #expect(sr.contains("20 shares · ≈100 SAR at risk"))
        #expect(!sr.contains("$100 at risk"))
        // A USD symbol → still "$" (approxAmount keeps the dollar prefix for USD).
        let us = StockSageTradePlan.text(symbol: "AAPL", market: "NASDAQ", price: 100,
                                         advice: advice(), rewardRisk: nil, size: size, flags: [])
        #expect(us.contains("≈$100 at risk"))
    }

    @Test func planMirrorsTheLeverageWarning() {
        // entry 400, stop 399 → risk/share 1; $100 budget → 100 sh, notional $40k = 400% → leveraged.
        let lev = StockSagePositionSizer.size(account: 10_000, riskFraction: 0.01, entry: 400, stop: 399)
        let plan = StockSageTradePlan.text(symbol: "X", market: "M", price: 400,
                                           advice: advice(), rewardRisk: nil, size: lev, flags: [])
        #expect(plan.contains("margin/leverage"))
        // Normal sizing (20 sh, 20% of account) → no warning.
        let normal = StockSagePositionSizer.size(account: 10_000, riskFraction: 0.01, entry: 100, stop: 95)
        let plan2 = StockSageTradePlan.text(symbol: "X", market: "M", price: 100,
                                            advice: advice(), rewardRisk: nil, size: normal, flags: [])
        #expect(!plan2.contains("margin/leverage"))
    }

    @Test func planOmitsAbsentOptionalsButKeepsCaveat() {
        var a = advice()
        a = TradeAdvice(action: .hold, conviction: 0.3, regime: .range, rationale: [],
                        stopPrice: nil, targetPrice: nil, suggestedWeight: 0, caveat: "Stand aside.")
        let plan = StockSageTradePlan.text(symbol: "X", market: "M", price: 50,
                                           advice: a, rewardRisk: nil, size: nil, flags: [])
        #expect(!plan.contains("Stop:"))
        #expect(!plan.contains("R:R:"))
        #expect(!plan.contains("Risk flags:"))
        #expect(!plan.contains("Why:"))
        #expect(plan.contains("Stand aside."))             // caveat still there
    }

    // MARK: - Wave-9: adaptive price formatting + relabeled action line

    /// Fix B: Action line must use "signal strength X/100" (not "conviction X%")
    /// with the explicit "rules-based score, not a win probability" disclaimer.
    /// Fix G partial: the relabeled action line is self-contained — no double disclaimer.
    @Test func actionLineUsesSignalStrengthLabel() {
        let plan = StockSageTradePlan.text(symbol: "AAPL", market: "NASDAQ", price: 100,
                                           advice: advice(), rewardRisk: nil, size: nil, flags: [])
        // New intentional contract: "signal strength X/100" replaces "conviction X%"
        #expect(plan.contains("signal strength 72/100"))
        #expect(plan.contains("rules-based score, not a win probability"))
        // Old label must NOT appear
        #expect(!plan.contains("conviction 72%"))
        #expect(!plan.contains("conviction"))
    }

    // Fix A (case 1): non-nil ladder with entry=100, stop=95, target=115
    // Fixture hand-verified by derive_wave9_fixture.swift:
    //   rung 1: price=105.00 (+1.0R), rung 2: price=110.00 (+2.0R), rung 3: price=115.00 (+3.0R)
    //   blendedExitR=2.0
    //   Scale-out line: "Scale-out (⅓ each): 105.00 (+1.0R) / 110.00 (+2.0R) / 115.00 (+3.0R) — blended exit +2.0R. Assumes each level fills."
    @Test func ladderPlanTextAdaptivePriceAndOrdering() {
        let ladder = StockSagePartialLadder.levels(entry: 100, stop: 95, target: 115, rungs: 3)!
        let rr = StockSageRewardRisk.assess(entry: 100, stop: 95, target: 115)
        let plan = StockSageTradePlan.text(symbol: "XYZ", market: "TSX", price: 100,
                                           advice: advice(), rewardRisk: rr, size: nil, flags: [],
                                           ladder: ladder)

        // Rung price strings: all ≥ $1 so adaptivePrice → "%.2f"
        #expect(plan.contains("105.00 (+1.0R)"))
        #expect(plan.contains("110.00 (+2.0R)"))
        #expect(plan.contains("115.00 (+3.0R)"))

        // Blended-R formatted as %.1f (= "2.0")
        #expect(plan.contains("blended exit +2.0R"))

        // "Assumes each level fills" caveat
        #expect(plan.contains("Assumes each level fills"))

        // Ordering: Scale-out line appears AFTER the R:R line and BEFORE Size
        let lines = plan.components(separatedBy: "\n")
        let rrIdx   = lines.firstIndex(where: { $0.hasPrefix("R:R:") })!
        let scaleIdx = lines.firstIndex(where: { $0.hasPrefix("Scale-out") })!
        // Scale-out must come after R:R and before any Size line (or end of plan if no size)
        #expect(scaleIdx > rrIdx)
        if let sizeIdx = lines.firstIndex(where: { $0.hasPrefix("Size:") }) {
            #expect(scaleIdx < sizeIdx)
        }
    }

    // Fix A (case 2): non-nil chandelierLevel with a sub-dollar value (0.0062)
    // Fixture hand-verified: abs(0.0062) < 0.01 → "%.6f" → "0.006200"
    @Test func chandelierPlanTextAdaptiveSubDollar() {
        let subDollarLevel = 0.0062
        let plan = StockSageTradePlan.text(symbol: "SHIB-USD", market: "Crypto", price: 0.0062,
                                           advice: advice(), rewardRisk: nil, size: nil, flags: [],
                                           chandelierLevel: subDollarLevel)

        // %.6f path for sub-cent values
        #expect(plan.contains("~0.006200"))

        // Exact qualifier phrasing from the implementation
        #expect(plan.contains("STARTING trailing level"))
        #expect(plan.contains("never down"))
        #expect(plan.contains("An exit rule, not a target"))

        // The "Chandelier exit:" prefix
        #expect(plan.contains("Chandelier exit:"))

        // Old %.2f formatting (2dp) would format 0.0062 as "0.01". Confirm it does NOT appear.
        // Note: we can't check !contains("~0.00") because "~0.006200" itself starts with "0.00" —
        // instead confirm "0.01" (the 2dp rounding artifact) is absent.
        #expect(!plan.contains("~0.01"))
    }
}
