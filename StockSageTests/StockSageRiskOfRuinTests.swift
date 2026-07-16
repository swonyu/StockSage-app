import Testing
import Foundation
@testable import StockSage

// MARK: - Drawdown survival / risk-of-ruin (pure)

struct StockSageRiskOfRuinTests {

    @Test func compoundsLossesDown() {
        // 5 stop-outs at 1% → ×0.99^5 = 0.9509900499 → ~4.9% down, not steep.
        let mild = StockSageRiskOfRuin.scenario(losses: 5, fraction: 0.01)!
        #expect(abs(mild.survivalMultiple - 0.9509900499) < 1e-9)
        #expect(abs(mild.drawdownPct - 0.0490099501) < 1e-9)
        #expect(!mild.isSteep)
        // 3 stop-outs at 10% → ×0.9^3 = 0.729 → 27.1% down, steep.
        let steep = StockSageRiskOfRuin.scenario(losses: 3, fraction: 0.10)!
        #expect(abs(steep.survivalMultiple - 0.729) < 1e-9)
        #expect(abs(steep.drawdownPct - 0.271) < 1e-9)
        #expect(steep.isSteep)
    }

    @Test func guardsBadInputs() {
        #expect(StockSageRiskOfRuin.scenario(losses: 0, fraction: 0.01) == nil)    // no streak
        #expect(StockSageRiskOfRuin.scenario(losses: 3, fraction: 1.0) == nil)     // fraction ≥ 1
        #expect(StockSageRiskOfRuin.scenario(losses: 3, fraction: 0.0) == nil)     // fraction ≤ 0
    }

    @Test func drawdownPctIsFractionScaleNotPercent() {
        // Contract lock (adversarial-review finding): drawdownPct is a 0–1 fraction,
        // NOT already ×100 like the sibling UnderwaterCurve.maxDrawdown
        // (StockSageDrawdown.swift). A near-total-wipe streak must still report a
        // value < 1 — and callers (MarketsView's two display sites) are the ones
        // responsible for the ×100 before showing it as a percent. If a future edit
        // ever flips this property to a pre-scaled 0–100 value without updating
        // those call sites, this test catches the silent 100x understatement.
        let nearWipe = StockSageRiskOfRuin.scenario(losses: 1, fraction: 0.95)!
        #expect(abs(nearWipe.drawdownPct - 0.95) < 1e-9)          // fraction, not 95
        #expect(nearWipe.drawdownPct < 1.0)
        #expect(abs(nearWipe.drawdownPct * 100 - 95.0) < 1e-9)    // caller must ×100 to display as %
    }
}
