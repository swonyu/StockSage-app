import Testing
import Foundation
@testable import StockSage

// MARK: - Glossary & asset-class risk notes (pure)

struct StockSageGlossaryTests {

    @Test func assetClassRiskNotesMatchClass() {
        #expect(StockSageGlossary.assetClassRiskNote(for: "BTC-USD")?.contains("24/7") == true)
        #expect(StockSageGlossary.assetClassRiskNote(for: "EURUSD=X")?.contains("notional") == true)
        #expect(StockSageGlossary.assetClassRiskNote(for: "^GSPC")?.contains("index") == true)
        // A plain equity has no special note.
        #expect(StockSageGlossary.assetClassRiskNote(for: "AAPL") == nil)
        #expect(StockSageGlossary.assetClassRiskNote(for: "2222.SR") == nil)
    }

    @Test func everyCardHelpIsNonEmptyAndHonest() {
        let helps = [
            StockSageGlossary.analyticsHelp, StockSageGlossary.regimeHelp,
            StockSageGlossary.kellyHelp, StockSageGlossary.heatmapHelp,
            StockSageGlossary.strategyHelp, StockSageGlossary.journalHelp,
        ]
        for h in helps { #expect(h.count > 40) }
        // The honesty thread: backward-looking / not-a-forecast language somewhere.
        let joined = helps.joined(separator: " ").lowercased()
        #expect(joined.contains("backward-looking") || joined.contains("not a") || joined.contains("doesn't"))
    }

    @Test func diversificationHelpMatchesRendered0to100Scale() {
        // UI renders "%.0f / 100"; the tooltip must not claim a 0–1 scale.
        #expect(StockSageGlossary.analyticsHelp.contains("0–100"))
    }

    @Test func everyMoneyVelocitySurfaceKeepsAnHonestHedge() {
        // Structural guard: every user-facing money-velocity string must carry a hedge,
        // so a future edit can't silently turn an estimate into a promise.
        // NOTE: "surviv" is the STEM so it matches both "survive" and "survivable"
        // (the drawdown-survival explainer says "survivable" — "survive" alone would miss it).
        let hedges = ["estimate", "not ", "rough", "hypothetical", "past", "surviv", "variance", "wrong", "assumes"]
        func hedged(_ s: String) -> Bool { let l = s.lowercased(); return hedges.contains { l.contains($0) } }

        for c in MoneyVelocityCopy.all { #expect(hedged(c)) }
        for term in MoneyVelocityTerm.allCases { #expect(hedged(StockSageGlossary.explain(term))) }
        #expect(hedged(StockSageGlossary.moneyVelocityHelp))
        // A fully-populated playbook must stay hedged too.
        let plan = StockSageExpectedValue.playbook(
            MoneyVelocitySummary(bestSymbol: "NVDA", bestEV: 0.7, fastestSymbol: "BTC-USD",
                                 fastestVelocity: 0.4, weeklyR: 2.5, worstRunLosses: 5, worstRunDrawdownPct: 0.05))
        #expect(hedged(plan))
    }

    @Test func everyMoneyVelocityTermHasAnHonestExplainer() {
        // Each term carries at least one honest hedge — the surfaces must never read as a promise.
        let hedges = ["estimate", "not ", "past", "rough", "assumes", "variance", "survivable", "wrong"]
        #expect(MoneyVelocityTerm.allCases.count == 8)
        for term in MoneyVelocityTerm.allCases {
            let text = StockSageGlossary.explain(term)
            #expect(text.count > 40)
            #expect(hedges.contains { text.lowercased().contains($0) })
        }
        #expect(StockSageGlossary.moneyVelocityHelp.count > 80)
        #expect(StockSageGlossary.moneyVelocityHelp.lowercased().contains("estimate"))
    }
}
