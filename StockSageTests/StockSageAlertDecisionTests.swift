import Testing
import Foundation
@testable import StockSage

// MARK: - Alert decision (pure)

struct StockSageAlertDecisionTests {
    typealias AD = StockSageAlertDecision

    @Test func newStrongSignalAlertsOnceThenDedupes() {
        // First time we see a Strong Buy (nothing alerted before) → fire.
        let a = AD.evaluate(symbol: "AAPL", recommendation: .strongBuy, price: 100, priorPrice: 100,
                            stop: 90, target: 120, lastAlertedRecommendation: nil)
        #expect(a?.kind == .newStrongBuy)
        // Same Strong Buy already alerted → silent (dedupe).
        #expect(AD.evaluate(symbol: "AAPL", recommendation: .strongBuy, price: 101, priorPrice: 100,
                            stop: 90, target: 120, lastAlertedRecommendation: .strongBuy) == nil)
    }

    @Test func flipFiresWhenStrongReverses() {
        let a = AD.evaluate(symbol: "T", recommendation: .strongBuy, price: 100, priorPrice: 100,
                            stop: 90, target: 120, lastAlertedRecommendation: .strongSell)
        #expect(a?.kind == .flip)
    }

    @Test func nonStrongSignalsStaySilent() {
        for rec in [StockSageRecommendation.buy, .hold, .sell] {
            #expect(AD.evaluate(symbol: "X", recommendation: rec, price: 100, priorPrice: 100,
                                stop: 90, target: 120, lastAlertedRecommendation: nil) == nil)
        }
    }

    @Test func stopCrossFiresOnceOnTheCrossing() {
        // Crossed DOWN through 90 this update (95 → 89): fire.
        #expect(AD.evaluate(symbol: "X", recommendation: .buy, price: 89, priorPrice: 95,
                            stop: 90, target: 120, lastAlertedRecommendation: nil)?.kind == .stopBreach)
        // Already below before (89 → 88): no fresh cross → silent.
        #expect(AD.evaluate(symbol: "X", recommendation: .buy, price: 88, priorPrice: 89,
                            stop: 90, target: 120, lastAlertedRecommendation: nil) == nil)
    }

    @Test func shortStopAndTargetCrossesAreSideAware() {
        // SHORT (sell/strongSell): stop ABOVE (110), target BELOW (80).
        // Stop-out = price crosses UP through the stop (105 → 111): fire.
        #expect(AD.evaluate(symbol: "X", recommendation: .sell, price: 111, priorPrice: 105,
                            stop: 110, target: 80, lastAlertedRecommendation: nil)?.kind == .stopBreach)
        // A WINNING short falling toward target (105 → 99) must NOT fire a stop breach.
        #expect(AD.evaluate(symbol: "X", recommendation: .sell, price: 99, priorPrice: 105,
                            stop: 110, target: 80, lastAlertedRecommendation: nil) == nil)
        // Target = price crosses DOWN through the target (82 → 79): fire targetHit.
        #expect(AD.evaluate(symbol: "X", recommendation: .strongSell, price: 79, priorPrice: 82,
                            stop: 110, target: 80, lastAlertedRecommendation: nil)?.kind == .targetHit)
    }

    @Test func targetCrossFiresOnceOnTheCrossing() {
        #expect(AD.evaluate(symbol: "X", recommendation: .buy, price: 121, priorPrice: 115,
                            stop: 90, target: 120, lastAlertedRecommendation: nil)?.kind == .targetHit)
        // Already above before → silent.
        #expect(AD.evaluate(symbol: "X", recommendation: .buy, price: 122, priorPrice: 121,
                            stop: 90, target: 120, lastAlertedRecommendation: nil) == nil)
    }

    @Test func stopBreachOutranksASignalChange() {
        // A SHORT (strongSell) stops ABOVE: both a fresh stop cross (105 → 111 UP through 110) AND a
        // new strong-sell signal fire this update → the stop breach wins (it is checked first).
        let a = AD.evaluate(symbol: "X", recommendation: .strongSell, price: 111, priorPrice: 105,
                            stop: 110, target: 80, lastAlertedRecommendation: nil)
        #expect(a?.kind == .stopBreach)
    }

    // MARK: - TEST_BACKLOG: exact-boundary crossings (>= / <= guards)

    @Test func targetCrossedExactlyOnTheLevel() {
        let a = AD.evaluate(symbol: "X", recommendation: .buy, price: 120, priorPrice: 115,
                            stop: 90, target: 120, lastAlertedRecommendation: nil)
        #expect(a?.kind == .targetHit)
    }

    @Test func stopCrossedExactlyOnTheLevel() {
        let a = AD.evaluate(symbol: "X", recommendation: .buy, price: 90, priorPrice: 95,
                            stop: 90, target: 120, lastAlertedRecommendation: nil)
        #expect(a?.kind == .stopBreach)
    }

    // MARK: - ALERT-FMT-1: alert reason text uses the shared 3-tier adaptive formatter, not bare %.2f
    //
    // DOGE-USD-class fixture: stop 0.099, target 0.104 — hand-derived standalone
    // (`swift /tmp/derive_alert_reason.swift`, not by calling `evaluate`):
    //   adaptive: "DOGE-USD hit its stop (0.0980 ≤ 0.0990) — the setup is invalidated; risk is realized."
    //   bare %.2f (pre-fix): "DOGE-USD hit its stop (0.10 ≤ 0.10) — ..." — stop and price read IDENTICAL.

    @Test func stopBreachReasonUsesAdaptiveTierNotBareTwoDecimals() {
        // Long stop at 0.099: crossed DOWN through it (0.101 -> 0.098).
        let a = AD.evaluate(symbol: "DOGE-USD", recommendation: .buy, price: 0.098, priorPrice: 0.101,
                            stop: 0.099, target: 0.104, lastAlertedRecommendation: nil)
        #expect(a?.kind == .stopBreach)
        #expect(a?.reason == "DOGE-USD hit its stop (0.0980 ≤ 0.0990) — the setup is invalidated; risk is realized.")
        // Distinct strings for price vs stop — the bare-%.2f collision ("0.10 ≤ 0.10") is gone.
        #expect(a?.reason.contains("0.10 ≤ 0.10") == false)
    }

    @Test func targetHitReasonUsesAdaptiveTierNotBareTwoDecimals() {
        // Long target at 0.104: crossed UP through it (0.102 -> 0.105).
        let a = AD.evaluate(symbol: "DOGE-USD", recommendation: .buy, price: 0.105, priorPrice: 0.102,
                            stop: 0.099, target: 0.104, lastAlertedRecommendation: nil)
        #expect(a?.kind == .targetHit)
        #expect(a?.reason == "DOGE-USD reached its target (0.1050 ≥ 0.1040) — consider taking profit or trailing the stop.")
    }
}
