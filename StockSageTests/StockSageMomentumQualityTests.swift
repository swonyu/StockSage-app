import Testing
import Foundation
@testable import StockSage

// MARK: - Fast-lane momentum-quality re-rank (FASTMONEY_BACKLOG #5)
//
// `momentumQuality` scores whether a fast-lane idea's SHORT-HORIZON momentum is genuinely hot
// (clean efficiency-ratio trend, MACD histogram > 0, positive ~21-bar return) vs a flat/
// mean-reverting setup that only LOOKS positive-EV. `rankByVelocityWeighted` re-sorts
// `fastLane`'s own idea set by velocity × quality. Both are additive — neither touches
// `fastLane`'s signature, membership, or ordering.

struct StockSageMomentumQualityTests {

    typealias EV = StockSageExpectedValue

    private func idea(_ symbol: String, conviction: Double, stop: Double, target: Double) -> StockSageIdea {
        StockSageIdea(symbol: symbol, market: "M", price: 100,
                      advice: TradeAdvice(action: .buy, conviction: conviction, regime: .bullTrend, rationale: [],
                                          stopPrice: stop, targetPrice: target, suggestedWeight: 0.05, caveat: "x"),
                      spark: [])
    }

    // MARK: Fixtures (verified against the CURRENT sma/ema/rsi/macd/efficiencyRatio/
    // returnOverPeriod implementations by hand-simulating them, not assumed from the doc).

    /// An accelerating uptrend (45 bars): clean net move (efficiencyRatio == 1.0), a clearly
    /// positive MACD histogram (momentum still accelerating, not just positive-level), and a
    /// strongly positive 21-bar return. All three signals fire ⇒ momentumQuality == 1.0.
    private var strongUptrendCloses: [Double] {
        var out: [Double] = [100.0]
        var inc = 0.3
        for _ in 0..<44 {
            inc += 0.05
            out.append(out[out.count - 1] + inc)
        }
        return out
    }

    /// A pure oscillation (40 bars, period 8, phase-shifted): efficiencyRatio ≈ 0 (net move is
    /// nearly nothing next to the round-trip noise — the textbook chop read), MACD histogram
    /// negative, and the 21-bar return negative. All three signals are cold ⇒ momentumQuality == 0.0.
    private var choppyCloses: [Double] {
        (0..<40).map { i in 100 + 3 * sin(Double(i + 1) * 2 * Double.pi / 8) }
    }

    /// Too short for ANY of the three signals (efficiencyRatio needs >20 bars, macd needs ≥35,
    /// returnOverPeriod(period:21) needs >21) — exercises the "no data" neutral sentinel.
    private var tooShortCloses: [Double] {
        (0..<15).map { 100 + Double($0) * 0.5 }
    }

    // MARK: - momentumQuality

    @Test func strongUptrendScoresHot() {
        let closes = strongUptrendCloses
        // Pin the fixture's own signals so a future indicator change can't silently invalidate
        // the "hot" premise without failing loudly here first.
        #expect(StockSageIndicators.efficiencyRatio(closes)! >= 0.99)
        #expect(StockSageIndicators.macd(closes)!.histogram > 0)
        #expect(StockSageIndicators.returnOverPeriod(closes, period: 21)! > 0)
        let i = idea("HOT", conviction: 0.8, stop: 90, target: 120)
        #expect(EV.momentumQuality(for: i, closes: closes) == 1.0)
    }

    @Test func choppyFlatScoresCold() {
        let closes = choppyCloses
        #expect(StockSageIndicators.efficiencyRatio(closes)! < 0.35)   // mirrors momentumQuality's private trend threshold
        #expect(StockSageIndicators.macd(closes)!.histogram <= 0)
        #expect(StockSageIndicators.returnOverPeriod(closes, period: 21)! <= 0)
        let i = idea("COLD", conviction: 0.8, stop: 90, target: 120)
        #expect(EV.momentumQuality(for: i, closes: closes) == 0.0)
    }

    @Test func tooShortHistoryIsNeutralNotPenalized() {
        let closes = tooShortCloses
        #expect(StockSageIndicators.efficiencyRatio(closes) == nil)
        #expect(StockSageIndicators.macd(closes) == nil)
        #expect(StockSageIndicators.returnOverPeriod(closes, period: 21) == nil)
        let i = idea("THIN", conviction: 0.8, stop: 90, target: 120)
        // No computable signal ⇒ neutral ceiling (no penalty for absent data), matching the
        // only-real-data / floor-never-inflate convention `cryptoRiskScaler` uses elsewhere.
        #expect(EV.momentumQuality(for: i, closes: closes) == 1.0)
    }

    @Test func emptyClosesIsAlsoNeutral() {
        let i = idea("EMPTY", conviction: 0.8, stop: 90, target: 120)
        #expect(EV.momentumQuality(for: i, closes: []) == 1.0)
    }

    // MARK: - rankByVelocityWeighted

    @Test func missingClosesReproducesPlainVelocityOrder() {
        // Same conviction/hold (Equity default) for all three; only reward:risk differs, so raw
        // velocity strictly separates them: AAA > BBB > CCC.
        let aaa = idea("AAA", conviction: 0.8, stop: 90, target: 140)   // RR 4
        let bbb = idea("BBB", conviction: 0.8, stop: 90, target: 120)   // RR 2
        let ccc = idea("CCC", conviction: 0.8, stop: 90, target: 112)   // RR 1.2
        let ideas = [ccc, bbb, aaa]   // deliberately NOT already in velocity order
        let lane = EV.fastLane(ideas)
        #expect(Set(lane.map(\.symbol)) == ["AAA", "BBB", "CCC"])   // sanity: all three kept
        let vA = EV.velocity(for: aaa)!, vB = EV.velocity(for: bbb)!, vC = EV.velocity(for: ccc)!
        #expect(vA > vB && vB > vC)   // fixture sanity: strictly separated
        // No closes supplied (the default) ⇒ every quality term is the neutral 1.0, so the order
        // must be EXACTLY plain velocity descending — the regression guard for "unchanged without
        // history".
        let weighted = EV.rankByVelocityWeighted(ideas)
        #expect(weighted.map(\.symbol) == ["AAA", "BBB", "CCC"])
    }

    @Test func hotMomentumOutranksColdAtEqualVelocity() {
        // Identical conviction/stop/target ⇒ identical raw velocity; only the supplied closes
        // differ. Deliberately order COLD first in the input so a naive stable tie (no history)
        // would keep COLD ahead of HOT — proving any reorder is driven by momentum, not input order.
        let cold = idea("COLD", conviction: 0.8, stop: 90, target: 120)
        let hot  = idea("HOT",  conviction: 0.8, stop: 90, target: 120)
        let ideas = [cold, hot]
        #expect(EV.velocity(for: cold)! == EV.velocity(for: hot)!)   // fixture sanity: a true tie

        // Baseline: with no closes, the tie is broken by fastLane's own stable order (input order).
        #expect(EV.rankByVelocityWeighted(ideas).map(\.symbol) == ["COLD", "HOT"])

        // With history supplied, HOT's momentum is genuinely hot and COLD's is genuinely cold —
        // the weighted order must flip to put HOT first despite COLD being input first.
        let closes: [String: [Double]] = ["HOT": strongUptrendCloses, "COLD": choppyCloses]
        #expect(EV.rankByVelocityWeighted(ideas, closes: closes).map(\.symbol) == ["HOT", "COLD"])
    }

    @Test func partialHistoryOnlyWeightsTheSymbolThatHasIt() {
        // BBB has no entry in `closes` at all (not even an empty array) — must fall back to its
        // plain velocity (×1), never demoted just because a SIBLING idea supplied history.
        let aaa = idea("AAA", conviction: 0.8, stop: 90, target: 120)
        let bbb = idea("BBB", conviction: 0.8, stop: 90, target: 120)
        #expect(EV.velocity(for: aaa)! == EV.velocity(for: bbb)!)
        // AAA gets a COLD history (would rank it last if weighted); BBB gets none.
        let weighted = EV.rankByVelocityWeighted([aaa, bbb], closes: ["AAA": choppyCloses])
        #expect(weighted.map(\.symbol) == ["BBB", "AAA"])
    }

    @Test func neverResurrectsAnIdeaFastLaneExcluded() {
        // A sell-side idea and a non-positive-EV idea are excluded by `fastLane` itself; supplying
        // a red-hot close history for them must not smuggle them into `rankByVelocityWeighted`'s
        // output — this function only ever RE-SORTS `fastLane`'s existing set.
        let sell = StockSageIdea(symbol: "SHORT-ME", market: "M", price: 100,
                                  advice: TradeAdvice(action: .sell, conviction: 0.9, regime: .bearTrend, rationale: [],
                                                       stopPrice: 110, targetPrice: 80, suggestedWeight: 0.05, caveat: "x"),
                                  spark: [])
        let goodBuy = idea("KEEP", conviction: 0.8, stop: 90, target: 120)
        let weighted = EV.rankByVelocityWeighted([sell, goodBuy], closes: ["SHORT-ME": strongUptrendCloses])
        #expect(weighted.map(\.symbol) == ["KEEP"])
    }

    // MARK: - 2026-07-01 adversarial-review fix: a demoted idea must never be resurrected

    @Test func aSubMinConvictionJunkIdeaIsNeverResurrectedByAHotHistory() {
        // JUNK is below minConvictionToRank (0.40) — fastLane KEEPS it (its own guard is only
        // evR > 0), but demotes it deep below every clean idea via velocityRankKey's -1000
        // penalty. A tight stop gives JUNK a large RAW velocity(for:) — exactly the shape that,
        // before this fix, could resurrect it to #1 once weighted by a red-hot momentum history
        // (since raw velocity ignores the demotion penalty entirely).
        let junk = idea("JUNK", conviction: 0.35, stop: 99, target: 112)     // tight stop → high raw velocity
        let clean = idea("CLEAN", conviction: 0.80, stop: 90, target: 115)  // wider stop → lower raw velocity
        #expect(EV.velocity(for: junk)! > EV.velocity(for: clean)!)          // fixture sanity: raw velocity favors JUNK
        let baseline = EV.fastLane([junk, clean])
        #expect(baseline.map(\.symbol) == ["CLEAN", "JUNK"])                 // fastLane already demotes JUNK to last
        // Give JUNK a red-hot history and CLEAN a cold one — the old bug would have let JUNK's
        // large raw velocity × 1.0 quality beat CLEAN's smaller raw velocity × reduced quality.
        let weighted = EV.rankByVelocityWeighted([junk, clean],
                                                  closes: ["JUNK": strongUptrendCloses, "CLEAN": choppyCloses])
        #expect(weighted.map(\.symbol) == ["CLEAN", "JUNK"])                 // still demoted — never resurrected
    }

    @Test func aBelowNetCostFloorIdeaIsNeverResurrectedByAHotHistory() {
        // THIN clears the raw-EV bar (fastLane keeps it) but its net-of-cost EV/day is under the
        // floor once round-trip frictions are applied (very tight stop/target ⇒ a thin edge that
        // costs eat entirely) — velocityRankKey demotes it -500,000. A tight stop again gives it a
        // large RAW velocity, the exact shape a hot history could previously exploit.
        let thin = idea("THIN", conviction: 0.80, stop: 99.8, target: 100.4)   // razor-thin edge
        let clean = idea("CLEAN", conviction: 0.80, stop: 90, target: 115)
        #expect(EV.belowNetCostFloor(for: thin))                               // fixture sanity: genuinely demoted
        #expect(!EV.belowNetCostFloor(for: clean))
        let baseline = EV.fastLane([thin, clean])
        #expect(baseline.map(\.symbol) == ["CLEAN", "THIN"])
        let weighted = EV.rankByVelocityWeighted([thin, clean],
                                                  closes: ["THIN": strongUptrendCloses, "CLEAN": choppyCloses])
        #expect(weighted.map(\.symbol) == ["CLEAN", "THIN"])                   // still demoted — never resurrected
    }

    @Test func closesEmptyDefaultIsByteIdenticalToFastLanesOwnOrder() {
        // 2026-07-01 fix strengthened this claim from "usually similar" to genuinely byte-identical:
        // weightedVelocity now uses the SAME key fastLane sorts by (velocityRankKey), so with no
        // closes supplied the order can never differ, for ANY mix of clean and demoted ideas.
        let junk = idea("JUNK", conviction: 0.35, stop: 99, target: 112)
        let clean1 = idea("CLEAN1", conviction: 0.80, stop: 90, target: 140)
        let clean2 = idea("CLEAN2", conviction: 0.80, stop: 90, target: 120)
        let ideas = [junk, clean2, clean1]
        #expect(EV.rankByVelocityWeighted(ideas).map(\.symbol) == EV.fastLane(ideas).map(\.symbol))
    }
}
