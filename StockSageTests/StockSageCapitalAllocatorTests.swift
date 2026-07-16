import Testing
import Foundation
@testable import StockSage

// MARK: - Capital allocator (pure) — half-Kelly, edge-weighted, heat-capped.
// All literals python-verified (halfKelly fraction, whole-share floor, heat cap).

struct StockSageCapitalAllocatorTests {
    typealias Alloc = StockSageCapitalAllocator

    private func idea(_ symbol: String, price: Double, stop: Double, target: Double,
                      conviction: Double, action: TradeAdvice.Action = .buy, spark: [Double] = []) -> StockSageIdea {
        StockSageIdea(symbol: symbol, market: "TEST", price: price,
                      advice: TradeAdvice(action: action, conviction: conviction, regime: .bullTrend,
                                          rationale: [], stopPrice: stop, targetPrice: target,
                                          suggestedWeight: 0, caveat: "x"),
                      spark: spark)
    }

    @Test func halfKellyIsAFractionNotDividedByAccount() {
        // conviction 0.5, 100/90/130 (payoff 3, p 0.465) → half-Kelly 0.14333…; account 10k,
        // maxHeat 0.50 (no scaling) → 143 shares, $1430 at risk. (python-verified)
        let a = Alloc.allocate(ideas: [idea("AAPL", price: 100, stop: 90, target: 130, conviction: 0.5)],
                               account: 10_000, maxHeat: 0.50)
        #expect(a.positions.count == 1)
        #expect(abs(a.positions[0].halfKelly - 0.1433333333) < 1e-6)
        #expect(abs(a.positions[0].riskFraction - 0.1433333333) < 1e-6)   // no scaling under the cap
        #expect(abs(a.scaleApplied - 1.0) < 1e-9)
        #expect(a.positions[0].shares == 143)
        #expect(abs(a.positions[0].dollarsAtRisk - 1430) < 1e-9)
        // Whole-share floor keeps realized risk ≤ the scaled target.
        #expect(a.positions[0].dollarsAtRisk <= a.positions[0].riskFraction * 10_000 + 1e-9)
    }

    // F5 (2026-07-09): allocate() silently dropped every 0-share position — the Deploy card just
    // vanished with no way to tell "nothing qualified" apart from "everything qualified but was
    // too small to buy 1 share here". fundableCandidateCount distinguishes the two.
    @Test func fundableCandidateCountNamesWhyThePlanIsEmptyWhenEveryPositionFloorsToZeroShares() {
        // Same fixture as halfKellyIsAFractionNotDividedByAccount (conviction 0.5, 100/90/130,
        // halfKelly ≈ 0.1433 — confirmed fundable at the qualitative level by that sibling test,
        // which produces 143 real shares at a $10k account/maxHeat 0.50). At a $1 account with the
        // default maxHeat 0.08, the single-idea scaled budget is EXACTLY account×maxHeat = $0.08
        // (scaleApplied = cap/requestedHeat when one idea's weight alone exceeds the cap, so
        // weight×scaleApplied = cap identically) — $0.08 ÷ $10 stop distance floors to 0 shares.
        let a = Alloc.allocate(ideas: [idea("AAPL", price: 100, stop: 90, target: 130, conviction: 0.5)],
                               account: 1, maxHeat: 0.08)
        #expect(a.positions.isEmpty)
        #expect(a.fundableCandidateCount == 1)
    }

    @Test func fundableCandidateCountIsZeroWhenNothingQualifiesAtAll() {
        // No ideas at all → the ORIGINAL silent-empty case — must stay 0, not resurrect a
        // phantom candidate the view would then wrongly claim "floored to 0 shares".
        let a = Alloc.allocate(ideas: [], account: 10_000, maxHeat: 0.08)
        #expect(a.positions.isEmpty)
        #expect(a.fundableCandidateCount == 0)
    }

    @Test func capBindsAndTotalHeatNeverExceedsMax() {
        // Three high-conviction 6:1 buys (each half-Kelly ≈ 0.2416, Σ ≈ 0.725 ≫ 0.08).
        let ideas = [idea("AAA", price: 100, stop: 90,  target: 160, conviction: 0.9),
                     idea("BBB", price: 50,  stop: 45,  target: 80,  conviction: 0.9),
                     idea("CCC", price: 200, stop: 180, target: 320, conviction: 0.9)]
        let a = Alloc.allocate(ideas: ideas, account: 100_000, maxHeat: 0.08)
        #expect(a.positions.count == 3)
        #expect(a.scaleApplied < 1.0)                              // the cap bound
        #expect(a.totalHeat <= 0.08 + 1e-9)                        // realized heat never exceeds the cap
        #expect(abs(a.totalHeat - 0.07985) < 1e-4)                 // python-verified
        #expect(a.positions.allSatisfy { $0.shares > 0 })
        #expect(abs(a.maxHeat - 0.08) < 1e-9)
        // Deterministic order: desc by riskFraction (ties broken by symbol).
        #expect(zip(a.positions, a.positions.dropFirst()).allSatisfy { $0.riskFraction >= $1.riskFraction })
    }

    @Test func noSinglePositionExceedsTheKellyCap() {
        // A lone very-strong idea (raw half-Kelly ≈ 0.28 > 0.20) under a generous maxHeat must
        // still be capped at Kelly's 20% per-position limit — not sit at ~half-Kelly (up to 50%).
        let a = Alloc.allocate(ideas: [idea("AAA", price: 100, stop: 90, target: 400, conviction: 0.99)],
                               account: 100_000, maxHeat: 0.50)
        #expect(a.positions.count == 1)
        #expect(a.positions[0].riskFraction <= 0.20 + 1e-9)   // capped, not up to 0.50
        #expect(a.positions[0].halfKelly > 0.20)              // raw half-Kelly WAS above the cap (transparency)
    }

    @Test func unscaledWhenRequestedHeatBelowCap() {
        // A weak-edge buy whose half-Kelly is under the cap → no scaling, riskFraction == halfKelly.
        let a = Alloc.allocate(ideas: [idea("LOW", price: 100, stop: 95, target: 110, conviction: 0.3)],
                               account: 10_000, maxHeat: 0.08)
        #expect(a.positions.count == 1)
        #expect(abs(a.scaleApplied - 1.0) < 1e-9)
        #expect(abs(a.positions[0].riskFraction - a.positions[0].halfKelly) < 1e-12)
    }

    @Test func allocatorVolTargetsHighVolNames() {
        func ideaVol(_ vol: Double?) -> StockSageIdea {
            StockSageIdea(symbol: "X", market: "M", price: 100,
                          advice: TradeAdvice(action: .buy, conviction: 0.6, regime: .bullTrend, rationale: [],
                                              stopPrice: 90, targetPrice: 130, suggestedWeight: 0, caveat: "x"),
                          spark: [], dailyMove: nil, realizedVol: vol)
        }
        func rf(_ vol: Double?) -> Double {
            Alloc.allocate(ideas: [ideaVol(vol)], account: 100_000, maxHeat: 0.5).positions.first?.riskFraction ?? 0
        }
        let calm = rf(0.15)       // ≤ 0.20 baseline → scaler 1 → no shrink
        #expect(calm > 0)
        #expect(rf(nil) == calm)  // no vol known → no shrink
        #expect(rf(0.80) < calm * 0.5)   // 0.80/0.20 = 4× → ~quarter the deployed risk
    }

    @Test func regimeSizingBiasScalesTheBook() {
        let i = idea("LOW", price: 100, stop: 95, target: 110, conviction: 0.3)
        func regime(_ bias: Double, _ state: MarketRegime.State) -> MarketRegime {
            MarketRegime(state: state, riskScore: 0, signals: [], sizingBias: bias, caveat: "x")
        }
        func rf(_ r: MarketRegime?) -> Double {
            Alloc.allocate(ideas: [i], account: 100_000, maxHeat: 0.5, regime: r).positions.first?.riskFraction ?? 0
        }
        let baseline = rf(nil)
        #expect(baseline > 0)
        #expect(rf(regime(1.25, .trendingBull)) > baseline)   // strong bull sizes the book up
        #expect(rf(regime(0.25, .crisis)) < baseline)         // risk-off sizes it down
        let crisis = Alloc.allocate(ideas: [i], account: 100_000, maxHeat: 0.5, regime: regime(0.25, .crisis))
        #expect(crisis.caveat.contains("Sized ×0.25"))
    }

    @Test func excludesNetNegativeAfterCostSetups() {
        // Same thin geometry, two cost regimes. A crypto flip (~70bps round-trip) that's +EV on GROSS
        // but net-negative after costs must NOT be deployed (mirrors the boards' cost gate)…
        let crypto = idea("X-USD", price: 100, stop: 99, target: 101.5, conviction: 0.6)
        #expect(Alloc.allocate(ideas: [crypto], account: 100_000, maxHeat: 0.5).positions.isEmpty)
        // …while the same setup on a low-cost large-cap (13bps) clears and funds.
        let equity = idea("AAPL", price: 100, stop: 99, target: 101.5, conviction: 0.6)
        #expect(!Alloc.allocate(ideas: [equity], account: 100_000, maxHeat: 0.5).positions.isEmpty)
    }

    @Test func excludesNonBuyAndNonPositiveEVAndInvalidInputs() {
        let sell = idea("SELL", price: 100, stop: 110, target: 80, conviction: 0.9, action: .sell)
        let noEV = idea("FLAT", price: 100, stop: 99, target: 100.5, conviction: 0.0)   // tiny reward, EV ≤ 0
        #expect(Alloc.allocate(ideas: [sell, noEV], account: 10_000).positions.isEmpty)
        // Invalid account/heat → empty plan, never a crash.
        #expect(Alloc.allocate(ideas: [idea("X", price: 100, stop: 90, target: 130, conviction: 0.8)],
                               account: 0).positions.isEmpty)
        #expect(Alloc.allocate(ideas: [], account: 10_000).positions.isEmpty)
    }

    // MARK: - ALLOC_BACKLOG #2: suggestAdd (marginal allocation against the live book)

    @Test func suggestAddSizesAgainstAnEmptyBookAtHalfKellyCappedByHeadroom() {
        // AAPL 100/90/130 conviction 0.9 → payoff 3, p 0.557, edge Kelly halfKelly ≈0.2047,
        // suggestedFraction capped at the 20% per-position ceiling. Empty book (0% heat),
        // default maxHeat 0.10 → the 10% heat headroom binds (tighter than the 20% cap).
        let candidate = idea("AAPL", price: 100, stop: 90, target: 130, conviction: 0.9)
        let s = Alloc.suggestAdd(idea: candidate, openTrades: [], holdings: [], candidateReturns: [],
                                 account: 10_000)!
        #expect(s.approved)
        #expect(abs(s.heatBefore) < 1e-9)
        #expect(abs(s.heatHeadroom - 0.10) < 1e-9)
        #expect(abs(s.riskFraction - 0.10) < 1e-9)          // headroom (0.10) < suggestedFraction (0.20) → headroom binds
        #expect(s.shares == 100)
        #expect(abs(s.dollarsAtRisk - 1000) < 1e-9)         // 100 shares × $10 risk/share
        #expect(s.nearestCorrelation == nil)                // no holdings supplied
    }

    @Test func suggestAddIsCappedByRemainingHeatHeadroomOnANearlyFullBook() {
        // Book already at 9.5% heat ($95k of open risk on a $1M account); default maxHeat 0.10
        // leaves only 0.5% headroom, which binds far below the 20% per-position cap.
        let candidate = idea("AAPL", price: 100, stop: 90, target: 130, conviction: 0.9)
        let openTrades: [(shares: Double, entry: Double, stop: Double)] = [(shares: 950, entry: 100, stop: 0)]
        let s = Alloc.suggestAdd(idea: candidate, openTrades: openTrades, holdings: [], candidateReturns: [],
                                 account: 1_000_000)!
        #expect(s.approved)
        #expect(abs(s.heatBefore - 0.095) < 1e-9)
        #expect(abs(s.heatHeadroom - 0.005) < 1e-9)
        #expect(abs(s.riskFraction - 0.005) < 1e-9)
        #expect(s.shares == 500)
        #expect(abs(s.dollarsAtRisk - 5000) < 1e-9)
        #expect(s.reason.localizedCaseInsensitiveContains("headroom"))
    }

    @Test func suggestAddBlocksAHighlyCorrelatedCandidateRegardlessOfEdge() {
        // Candidate returns identical to an already-held name → correlation 1.0, ≥ the 0.80
        // default threshold → concentration block, even though the idea itself has positive EV.
        let candidate = idea("ETH-USD", price: 100, stop: 90, target: 130, conviction: 0.9)
        let series = [0.01, 0.02, -0.01, 0.03, -0.02]
        let s = Alloc.suggestAdd(idea: candidate, openTrades: [], holdings: [(symbol: "BTC-USD", returns: series)],
                                 candidateReturns: series, account: 10_000)!
        #expect(!s.approved)
        #expect(s.riskFraction == 0)
        #expect(s.shares == 0)
        #expect(s.nearestCorrelation != nil && abs(s.nearestCorrelation! - 1.0) < 1e-9)
        #expect(s.reason.contains("BTC-USD"))
    }

    @Test func suggestAddReturnsNilForUndefinedRiskOrInvalidAccount() {
        // No stop → undefined risk → nil (constructed directly since the `idea()` fixture
        // helper requires non-optional stop/target).
        let noStop = StockSageIdea(symbol: "MSFT", market: "TEST", price: 100,
                                   advice: TradeAdvice(action: .buy, conviction: 0.7, regime: .bullTrend,
                                                       rationale: [], stopPrice: nil, targetPrice: 130,
                                                       suggestedWeight: 0, caveat: "x"), spark: [])
        #expect(Alloc.suggestAdd(idea: noStop, openTrades: [], holdings: [], candidateReturns: [],
                                 account: 10_000) == nil)
        let clean = idea("AAPL", price: 100, stop: 90, target: 130, conviction: 0.9)
        #expect(Alloc.suggestAdd(idea: clean, openTrades: [], holdings: [], candidateReturns: [], account: 0) == nil)
        #expect(Alloc.suggestAdd(idea: clean, openTrades: [], holdings: [], candidateReturns: [], account: -100) == nil)
    }

    // MARK: - ALLOC_BACKLOG #5: rebalanceToEdge (EV-weighted whole-book reweight)

    private func trade(_ p: RebalancePlan, _ sym: String) -> RebalanceTrade? { p.trades.first { $0.symbol == sym } }

    @Test func rebalanceToEdgeTrimsNegativeGrowsPositiveAndCapsChurnIntoNewIdeas() {
        // AAPL held, conviction 0 buy at a near-flat 100/90/101 → evR = 0.35·0.1 − 0.65 = −0.615
        // (negative, trimmed). MSFT held, conviction 1.0 at 200/180/260 → p 0.58, rewardR 3 →
        // evR = 0.58·3 − 0.42 = 1.32 (positive, kept). NVDA is a brand-new idea (not held),
        // conviction 0.5 at 50/45/65 → p 0.465, rewardR 3 → evR = 0.465·3 − 0.535 = 0.86.
        // Raw new-share = 0.86 / (1.32+0.86) ≈ 0.394 > the default 10% maxHeat cap, so it engages:
        // closed-form scale pins MSFT/NVDA to an exact 90%/10% split of the $8,000 book (python-verified).
        let aapl = idea("AAPL", price: 100, stop: 90, target: 101, conviction: 0.0)
        let msft = idea("MSFT", price: 200, stop: 180, target: 260, conviction: 1.0)
        let nvda = idea("NVDA", price: 50, stop: 45, target: 65, conviction: 0.5)
        let r = Alloc.rebalanceToEdge(holdings: [("AAPL", 4000), ("MSFT", 4000)], ideas: [aapl, msft, nvda])
        #expect(r != nil)
        guard let r else { return }
        #expect(abs(trade(r.plan, "AAPL")!.targetWeight - 0.0) < 1e-9)
        #expect(abs(trade(r.plan, "MSFT")!.targetWeight - 0.9) < 1e-9)
        #expect(abs(trade(r.plan, "NVDA")!.targetWeight - 0.1) < 1e-9)
        #expect(abs(trade(r.plan, "AAPL")!.deltaValue - (-4000)) < 1e-6)
        #expect(abs(trade(r.plan, "MSFT")!.deltaValue - 3200) < 1e-6)
        #expect(abs(trade(r.plan, "NVDA")!.deltaValue - 800) < 1e-6)
        #expect(r.excludedSymbols.isEmpty)
        #expect(r.note.contains("capped"))
    }

    @Test func rebalanceToEdgeDoesNotCapWhenNewSharesAlreadyUnderMaxHeat() {
        // Same three ideas as above but maxHeat raised to 0.50 (well above the raw ~39.4% new
        // share) → no cap engages; weights pass straight through the plain evR-proportional split.
        let aapl = idea("AAPL", price: 100, stop: 90, target: 101, conviction: 0.0)
        let msft = idea("MSFT", price: 200, stop: 180, target: 260, conviction: 1.0)
        let nvda = idea("NVDA", price: 50, stop: 45, target: 65, conviction: 0.5)
        let r = Alloc.rebalanceToEdge(holdings: [("AAPL", 4000), ("MSFT", 4000)], ideas: [aapl, msft, nvda], maxHeat: 0.50)
        #expect(r != nil)
        guard let r else { return }
        #expect(abs(trade(r.plan, "MSFT")!.targetWeight - 0.6055045871559633) < 1e-9)
        #expect(abs(trade(r.plan, "NVDA")!.targetWeight - 0.39449541284403666) < 1e-9)
        #expect(!r.note.contains("capped"))
    }

    @Test func rebalanceToEdgeIsBalancedWhenTheSoleHeldNameIsAlreadyAtTarget() {
        // A single fully-fundable holding normalizes to weight 1.0 — since it's already the only
        // position (current weight 1.0 too), drift is exactly 0, under any band.
        let only = idea("AAPL", price: 100, stop: 90, target: 140, conviction: 0.7)
        let r = Alloc.rebalanceToEdge(holdings: [("AAPL", 5000)], ideas: [only])!
        #expect(r.plan.isBalanced)
        #expect(r.plan.trades.isEmpty)
    }

    @Test func rebalanceToEdgeExcludesACorrelationBlockedNewIdeaWithANote() {
        // NVDA's spark is AAPL's spark scaled by 0.5 → identical % daily moves → correlation 1.0,
        // ≥ the 0.80 default threshold → NVDA is excluded even though its own EV is positive.
        // MSFT (held, uncorrelated-by-construction, positive EV) keeps the plan non-nil.
        let aaplSpark = [100.0, 102, 101, 103, 102, 104, 103, 105]
        let nvdaSpark = aaplSpark.map { $0 * 0.5 }
        let aapl = idea("AAPL", price: 100, stop: 90, target: 101, conviction: 0.0, action: .hold, spark: aaplSpark)
        let msft = idea("MSFT", price: 200, stop: 180, target: 260, conviction: 1.0)
        let nvda = idea("NVDA", price: 50, stop: 45, target: 65, conviction: 0.5, spark: nvdaSpark)
        let r = Alloc.rebalanceToEdge(holdings: [("AAPL", 4000), ("MSFT", 4000)], ideas: [aapl, msft, nvda])
        #expect(r != nil)
        guard let r else { return }
        #expect(r.excludedSymbols == ["NVDA"])
        #expect(trade(r.plan, "NVDA") == nil)                       // never entered the plan at all
        #expect(abs(trade(r.plan, "MSFT")!.targetWeight - 1.0) < 1e-9)   // sole surviving positive-edge name
        #expect(abs(trade(r.plan, "AAPL")!.targetWeight - 0.0) < 1e-9)   // .hold → not buy-family → trimmed
        #expect(r.note.contains("NVDA"))
        #expect(r.note.localizedCaseInsensitiveContains("correlation"))
    }

    @Test func rebalanceToEdgeSizesOnlyWhenNoReturnSeriesIsSupplied() {
        // Identical setup to the correlation-block test, but both sparks are empty → ClusterCheck
        // has nothing to compare, so the gate no-ops and NVDA is sized in normally (size-only).
        let aapl = idea("AAPL", price: 100, stop: 90, target: 101, conviction: 0.0, action: .hold)
        let msft = idea("MSFT", price: 200, stop: 180, target: 260, conviction: 1.0)
        let nvda = idea("NVDA", price: 50, stop: 45, target: 65, conviction: 0.5)
        let r = Alloc.rebalanceToEdge(holdings: [("AAPL", 4000), ("MSFT", 4000)], ideas: [aapl, msft, nvda])!
        #expect(r.excludedSymbols.isEmpty)
        #expect(trade(r.plan, "NVDA") != nil)
    }

    @Test func rebalanceToEdgeTrimsAHeldSymbolThatHasNoIdeaAtAll() {
        // GOOG is held but never appears in `ideas` at all (not merely a negative-EV one) — still
        // absent from targets, still trimmed to 0, exactly like a held name with a flat/negative idea.
        let xyz = idea("XYZ", price: 100, stop: 90, target: 160, conviction: 1.0)
        let r = Alloc.rebalanceToEdge(holdings: [("XYZ", 4000), ("GOOG", 4000)], ideas: [xyz])!
        #expect(abs(trade(r.plan, "XYZ")!.targetWeight - 1.0) < 1e-9)
        #expect(abs(trade(r.plan, "GOOG")!.targetWeight - 0.0) < 1e-9)
        #expect(trade(r.plan, "GOOG")!.deltaValue < 0)
    }

    @Test func rebalanceToEdgeReturnsNilWhenNoPositiveEdgeAnywhere() {
        let aapl = idea("AAPL", price: 100, stop: 90, target: 101, conviction: 0.0)          // negative evR
        let msft = idea("MSFT", price: 200, stop: 180, target: 260, conviction: 1.0, action: .sell) // not buy-family
        #expect(Alloc.rebalanceToEdge(holdings: [("AAPL", 4000), ("MSFT", 4000)], ideas: [aapl, msft]) == nil)
    }

    @Test func rebalanceToEdgeReturnsNilWhenNothingIsInvested() {
        let aapl = idea("AAPL", price: 100, stop: 90, target: 140, conviction: 0.7)
        #expect(Alloc.rebalanceToEdge(holdings: [], ideas: [aapl]) == nil)
        #expect(Alloc.rebalanceToEdge(holdings: [("AAPL", 0)], ideas: [aapl]) == nil)
    }

    // MARK: - 2026-07-01 adversarial-review fixes

    @Test func rebalanceToEdgeCapsConcentrationWhenEnoughFundedNamesExistToAbsorbIt() {
        // python-verified: DOM (conviction 1.0, 100/90/400 → evR 16.98) held alongside 5 similar
        // small ideas (conviction 0.5, 100/95/110 → evR 0.395 each) — DOM's raw share is ~89.6% of
        // the book, five funded names total is enough for the 20% (StockSageKelly.maxFraction) cap
        // to be genuinely achievable: DOM capped to exactly 0.20, the 0.696 excess spread evenly
        // across the five small names (each starting at ~2.08%) lands them all at exactly 0.16.
        let dom = idea("DOM", price: 100, stop: 90, target: 400, conviction: 1.0)
        let smalls = (1...5).map { idea("S\($0)", price: 100, stop: 95, target: 110, conviction: 0.5) }
        let r = Alloc.rebalanceToEdge(holdings: [("DOM", 1000)], ideas: [dom] + smalls, maxHeat: 1.0)!
        #expect(abs(trade(r.plan, "DOM")!.targetWeight - 0.20) < 1e-6)
        for i in 1...5 { #expect(abs(trade(r.plan, "S\(i)")!.targetWeight - 0.16) < 1e-6) }
        let sumWeights = (["DOM"] + (1...5).map { "S\($0)" }).reduce(0.0) { $0 + trade(r.plan, $1)!.targetWeight }
        #expect(abs(sumWeights - 1.0) < 1e-6)
        #expect(r.note.contains("capped at"))
        #expect(!r.note.contains("CONCENTRATION WARNING"))   // genuinely capped, not the unavoidable fallback
    }

    @Test func rebalanceToEdgeWarnsRatherThanSilentlyFailingWhenConcentrationIsUnavoidable() {
        // A sole fundable name (matching rebalanceToEdgeIsBalancedWhenTheSoleHeldNameIsAlreadyAtTarget's
        // setup): capping would be silently UNDONE by StockSageRebalance.plan's own renormalization
        // (dividing the sole capped value by itself always yields 1.0 again), so this must NOT claim
        // "capped" — it must leave the weight at its honest 1.0 and say so loudly instead.
        let only = idea("AAPL", price: 100, stop: 90, target: 140, conviction: 0.7)
        let r = Alloc.rebalanceToEdge(holdings: [("AAPL", 5000)], ideas: [only])!
        // AAPL is already 100% of a 100%-AAPL book → zero drift → no trade row to inspect at all
        // (matches rebalanceToEdgeIsBalancedWhenTheSoleHeldNameIsAlreadyAtTarget's own pattern);
        // assert the honesty note instead, which fires regardless of whether a trade is emitted.
        #expect(r.plan.isBalanced)
        #expect(r.plan.trades.isEmpty)
        #expect(r.note.contains("CONCENTRATION WARNING"))
        #expect(r.note.localizedCaseInsensitiveContains("too few fundable names"))
        #expect(!r.note.contains("were capped at"))   // never claims a cap that didn't actually hold
    }

    @Test func rebalanceToEdgeDeweightsAMutuallyCorrelatedCliqueOfBrandNewIdeas() {
        // 2026-07-01 fix: the existing correlation gate only checked new-vs-HELD; three brand-new,
        // mutually 1.0-correlated ideas (identical % daily moves) previously passed completely
        // unchecked against EACH OTHER. With nothing held, they should now be de-weighted as a
        // clique (StockSageCorrelationCluster's own de-weight-by-cluster-size treatment), not
        // simply split by evR alone.
        let baseSpark = [100.0, 102, 101, 103, 102, 104, 103, 105]
        let a = idea("AAA", price: 100, stop: 90, target: 130, conviction: 0.8, spark: baseSpark)
        let b = idea("BBB", price: 100, stop: 90, target: 130, conviction: 0.8, spark: baseSpark.map { $0 * 0.5 })
        let c = idea("CCC", price: 100, stop: 90, target: 130, conviction: 0.8, spark: baseSpark.map { $0 * 2.0 })
        // A held, unrelated 4th name gives the churn-cap something to compare the new pool against,
        // and gives correlationAdjustedWeights room to matter (its own guard needs >=3 symbols).
        let held = idea("HELD", price: 100, stop: 90, target: 101, conviction: 0.0)   // negative evR, trimmed
        let r = Alloc.rebalanceToEdge(holdings: [("HELD", 1000)], ideas: [held, a, b, c], maxHeat: 1.0)!
        // All three should still be present (de-weighted, not excluded outright — a lesser but
        // real remedy than the existing held-vs-new exclusion gate).
        #expect(trade(r.plan, "AAA") != nil)
        #expect(trade(r.plan, "BBB") != nil)
        #expect(trade(r.plan, "CCC") != nil)
        #expect(r.excludedSymbols.isEmpty)   // de-weighted, not hard-excluded
    }

    @Test func positionOrderIsATotalOrderOverTheDocumentedChain() {
        func pos(_ symbol: String, risk: Double, dollars: Double, notional: Double) -> AllocatedPosition {
            AllocatedPosition(symbol: symbol, riskFraction: risk, shares: 1,
                              dollarsAtRisk: dollars, notional: notional, halfKelly: 0.1, evR: 1.0)
        }
        typealias CA = StockSageCapitalAllocator
        // 1. riskFraction desc dominates everything.
        #expect(CA.positionOrder(pos("ZZZ", risk: 0.03, dollars: 1, notional: 1), pos("AAA", risk: 0.02, dollars: 999, notional: 999)))
        // 2. symbol asc breaks a risk tie ("BTC" < "btc" raw compare — case pairs don't tie).
        #expect(CA.positionOrder(pos("AAA", risk: 0.02, dollars: 1, notional: 1), pos("BBB", risk: 0.02, dollars: 999, notional: 999)))
        #expect(CA.positionOrder(pos("BTC", risk: 0.02, dollars: 1, notional: 1), pos("btc", risk: 0.02, dollars: 999, notional: 999)))
        // 3. NEW: duplicate symbol + equal risk → dollarsAtRisk desc decides (was unspecified).
        #expect(CA.positionOrder(pos("AAA", risk: 0.02, dollars: 995, notional: 9900), pos("AAA", risk: 0.02, dollars: 990, notional: 9950)))
        #expect(!CA.positionOrder(pos("AAA", risk: 0.02, dollars: 990, notional: 9950), pos("AAA", risk: 0.02, dollars: 995, notional: 9900)))
        // 4. NEW: …then notional desc.
        #expect(CA.positionOrder(pos("AAA", risk: 0.02, dollars: 995, notional: 9950), pos("AAA", risk: 0.02, dollars: 995, notional: 9900)))
        // 5. Strict-weak-ordering sanity: fully equal rows are incomparable in BOTH directions.
        let x = pos("AAA", risk: 0.02, dollars: 995, notional: 9950)
        #expect(!CA.positionOrder(x, x))
    }

    // ── F3 wave-B (2026-07-16): FX-correct sizing + USD-normalized heat ledger ──────────
    // Hand-derived off the existing python-verified fixture math (conviction 0.5, 100/90/130
    // → p 0.465, payoff 3, halfKelly 0.1433333; cost gate clears easily: p* ≈ 0.26 ≪ 0.465).

    @Test func fxMapSizesSRAtTheStatedFractionAndNormalizesHeatToUSD() {
        // $10k account, maxHeat 0.50 (no scaling; requested 2×0.14333 = 0.28667 < cap).
        // AAPL (USD): budget 1433.33/10 → 143 shares, $1430 at risk (the pinned math).
        // 2222.SR with SAR→USD = 1/3.75: account 37,500 SAR → budget 5,375 SAR/10 →
        // 537 shares, 5,370 SAR at risk = $1,432 — the stated 14.33% fraction, not 1/3.75 of it.
        // Heat ledger must be USD: (1430 + 5370/3.75)/10000 = 0.28620.
        let a = Alloc.allocate(ideas: [idea("AAPL", price: 100, stop: 90, target: 130, conviction: 0.5),
                                       idea("2222.SR", price: 100, stop: 90, target: 130, conviction: 0.5)],
                               account: 10_000, maxHeat: 0.50, fxRatesToUSD: ["SAR": 1.0 / 3.75])
        #expect(a.positions.count == 2)
        let sr = a.positions.first { $0.symbol == "2222.SR" }
        let us = a.positions.first { $0.symbol == "AAPL" }
        #expect(sr?.shares == 537)
        #expect(abs((sr?.dollarsAtRisk ?? 0) - 5_370) < 1e-9)     // raw SAR — displays convert
        #expect(us?.shares == 143)
        #expect(abs((us?.dollarsAtRisk ?? 0) - 1_430) < 1e-9)
        #expect(abs(a.totalHeat - 0.28620) < 1e-9)                // USD-normalized, hand-derived
        #expect(a.totalHeat <= a.maxHeat + 1e-9)
        // Definitional identity: heat re-derived from the returned positions' native at-risk
        // × each symbol's rawQuoteUnitToUSD (×1 for USD) must equal the reported totalHeat.
        let rederived = a.positions.reduce(0.0) { acc, p in
            acc + p.dollarsAtRisk * (StockSagePositionSizer.rawQuoteUnitToUSD(symbol: p.symbol,
                                                                              fxRatesToUSD: ["SAR": 1.0 / 3.75]) ?? 1)
        } / 10_000
        #expect(abs(a.totalHeat - rederived) < 1e-12)
    }

    @Test func emptyMapKeepsAllocateByteIdenticalIncludingTheOldMixedSRBehavior() {
        let ideas = [idea("AAPL", price: 100, stop: 90, target: 130, conviction: 0.5),
                     idea("2222.SR", price: 100, stop: 90, target: 130, conviction: 0.5)]
        let bare = Alloc.allocate(ideas: ideas, account: 10_000, maxHeat: 0.50)
        let empt = Alloc.allocate(ideas: ideas, account: 10_000, maxHeat: 0.50, fxRatesToUSD: [:])
        #expect(bare == empt)
        // Prior (currency-mixed) behavior preserved by default: .SR sizes like a USD name.
        #expect(bare.positions.first { $0.symbol == "2222.SR" }?.shares == 143)
    }
}
