import Testing
import Foundation
@testable import StockSage

// TOM state pin. History: shipped as a default-OFF status lock (2026-07-09 morning, research
// chain underpowered), ACTIVATED the same day by explicit owner direction ("WIRE ACTIVATE"),
// then RATIFIED KEEP later that day with the powered-NULL multi-year panel in hand (owner
// option "a" — a deliberate disclosed preference, not an evidence promotion; TOM lane CLOSED).
// This suite pins the RATIFIED state so any silent flip (either direction) fails loudly.
//
// Every test acquires `TomFlagTestLock` (2026-07-09 review fix): the flag is a process-global
// with no injection seam, Swift Testing parallelizes ACROSS suites, and the inertness test's
// brief flag-off window raced the state pin + StockSageExpectedValueTests' activation test.
// Defer order matters: restore runs before unlock (LIFO).
struct StockSageTomGateTests {
    @Test func turnOfMonthFlagMatchesOwnerActivatedState() {
        TomFlagTestLock.lock.lock()
        defer { TomFlagTestLock.lock.unlock() }
        #expect(StockSageAdvisor.turnOfMonthEnabled == true,
                "TOM was owner-activated 2026-07-09 (\"WIRE ACTIVATE\") and RATIFIED KEEP the same day with the powered-NULL multi-year panel in hand (option \"a\" — a deliberate disclosed preference, not an evidence promotion); changing this default is an owner decision — update this pin only with a cited owner order")
    }

    @Test func seasonalityBonusIsInertWhenFlagIsOff() {
        TomFlagTestLock.lock.lock()
        defer { TomFlagTestLock.lock.unlock() }
        let saved = StockSageAdvisor.turnOfMonthEnabled
        defer { StockSageAdvisor.turnOfMonthEnabled = saved }
        StockSageAdvisor.turnOfMonthEnabled = false

        let m = StockSageSeasonality.currentMonth()
        let s = MonthlySeasonality(months: (1...12).map { month in
            MonthlySeasonality.MonthStat(month: month,
                                         avgReturn: month == m ? 0.05 : 0,
                                         samples: month == m ? 8 : 0)
        }, years: 8)
        // Flag OFF ⇒ the bonus must be EXACTLY zero even with a strong, reliable month stat.
        #expect(StockSageExpectedValue.seasonalityRankBonus(for: gateIdea("GATE"), seasonality: ["GATE": s]) == 0)
    }

    private func gateIdea(_ symbol: String, action: TradeAdvice.Action = .buy) -> StockSageIdea {
        StockSageIdea(
            symbol: symbol, market: "M", price: 100,
            advice: TradeAdvice(action: action, conviction: 0.8, regime: .bullTrend, rationale: [],
                                stopPrice: action == .sell ? 110 : 90,
                                targetPrice: action == .sell ? 80 : 120,
                                suggestedWeight: 0.05, caveat: "x"),
            spark: [])
    }

    private func monthFixture(mean: Double, std: Double, samples: Int) -> MonthlySeasonality {
        let m = StockSageSeasonality.currentMonth()
        return MonthlySeasonality(months: (1...12).map { month in
            MonthlySeasonality.MonthStat(month: month,
                                         avgReturn: month == m ? mean : 0,
                                         samples: month == m ? samples : 0,
                                         stdDev: month == m ? std : 0)
        }, years: Double(samples))
    }

    @Test func noisyMonthIsGatedToZeroDespitePositiveMean() {
        TomFlagTestLock.lock.lock()
        defer { TomFlagTestLock.lock.unlock() }
        let saved = StockSageAdvisor.turnOfMonthEnabled
        defer { StockSageAdvisor.turnOfMonthEnabled = saved }
        StockSageAdvisor.turnOfMonthEnabled = true
        // Yearly returns [+10%, −8%, +7%]: mean +3% but std 0.09643650760992956 →
        // t = 0.5388… < 1 (hand-derived, /tmp/derive_seasonality_robustness.swift) → NO tilt.
        let s = monthFixture(mean: 0.03, std: 0.09643650760992956, samples: 3)
        #expect(StockSageExpectedValue.seasonalityRankBonus(for: gateIdea("NOISY"),
                                                            seasonality: ["NOISY": s]) == 0)
    }

    @Test func consistentMonthTiltsByTheHandDerivedAmount() {
        TomFlagTestLock.lock.lock()
        defer { TomFlagTestLock.lock.unlock() }
        let saved = StockSageAdvisor.turnOfMonthEnabled
        defer { StockSageAdvisor.turnOfMonthEnabled = saved }
        StockSageAdvisor.turnOfMonthEnabled = true
        // Yearly returns [+10%, +4%, +7%]: mean 0.07, std 0.03 → t = 4.0414… ≥ 1 → tilt fires.
        // Hand-derived bonus: cap(0.07 → 0.03) × reliability(3/5) = 0.018.
        let s = monthFixture(mean: 0.07, std: 0.03, samples: 3)
        let bonus = StockSageExpectedValue.seasonalityRankBonus(for: gateIdea("STEADY"),
                                                                seasonality: ["STEADY": s])
        #expect(abs(bonus - 0.018) < 1e-12)
    }

    // TIGHT STRADDLE of the |t| < 1 noise-gate boundary (2026-07-09 review fix: the original
    // fixtures sat at t=0.539 / t=4.041, leaving the gate constant unpinned anywhere in
    // (0.54, 4.04) — a "tighten to |t|<2" regression would have passed both).
    // Hand-derived: t = mean·√n/std with mean 0.03, n=3 → t = 0.051961524227066314/std.
    @Test func tJustBelowOneIsGated() {
        TomFlagTestLock.lock.lock()
        defer { TomFlagTestLock.lock.unlock() }
        let saved = StockSageAdvisor.turnOfMonthEnabled
        defer { StockSageAdvisor.turnOfMonthEnabled = saved }
        StockSageAdvisor.turnOfMonthEnabled = true
        // std 0.0525 → t = 0.051961524227066314/0.0525 = 0.98974… < 1 → gated to zero.
        let s = monthFixture(mean: 0.03, std: 0.0525, samples: 3)
        #expect(StockSageExpectedValue.seasonalityRankBonus(for: gateIdea("EDGE0"),
                                                            seasonality: ["EDGE0": s]) == 0)
    }

    @Test func tJustAboveOnePassesWithTheHandDerivedTilt() {
        TomFlagTestLock.lock.lock()
        defer { TomFlagTestLock.lock.unlock() }
        let saved = StockSageAdvisor.turnOfMonthEnabled
        defer { StockSageAdvisor.turnOfMonthEnabled = saved }
        StockSageAdvisor.turnOfMonthEnabled = true
        // std 0.0515 → t = 0.051961524227066314/0.0515 = 1.00896… ≥ 1 → tilt fires:
        // cap(0.03) × reliability(3/5) = 0.018.
        let s = monthFixture(mean: 0.03, std: 0.0515, samples: 3)
        let bonus = StockSageExpectedValue.seasonalityRankBonus(for: gateIdea("EDGE1"),
                                                                seasonality: ["EDGE1": s])
        #expect(abs(bonus - 0.018) < 1e-12)
    }

    // DIRECTION (2026-07-09 review fix): the tilt is a statement about the SYMBOL's month —
    // a sell-family idea profits from the OPPOSITE move, so the sign flips; neutral actions
    // (hold/avoid) are non-trades and get no tilt at all.
    @Test func sellIdeaOnSeasonallyRisingNameIsPenalizedNotBoosted() {
        TomFlagTestLock.lock.lock()
        defer { TomFlagTestLock.lock.unlock() }
        let saved = StockSageAdvisor.turnOfMonthEnabled
        defer { StockSageAdvisor.turnOfMonthEnabled = saved }
        StockSageAdvisor.turnOfMonthEnabled = true
        // Same reliable up-month as the buy test (t=4.04, buy bonus +0.018) — the SHORT on a
        // seasonally-RISING name must get the mirror-image −0.018, never a boost.
        let s = monthFixture(mean: 0.07, std: 0.03, samples: 3)
        let bonus = StockSageExpectedValue.seasonalityRankBonus(for: gateIdea("SHRT", action: .sell),
                                                                seasonality: ["SHRT": s])
        #expect(abs(bonus - (-0.018)) < 1e-12)
    }

    @Test func neutralActionGetsNoTilt() {
        TomFlagTestLock.lock.lock()
        defer { TomFlagTestLock.lock.unlock() }
        let saved = StockSageAdvisor.turnOfMonthEnabled
        defer { StockSageAdvisor.turnOfMonthEnabled = saved }
        StockSageAdvisor.turnOfMonthEnabled = true
        let s = monthFixture(mean: 0.07, std: 0.03, samples: 3)
        #expect(StockSageExpectedValue.seasonalityRankBonus(for: gateIdea("HOLD", action: .hold),
                                                            seasonality: ["HOLD": s]) == 0)
    }
}
