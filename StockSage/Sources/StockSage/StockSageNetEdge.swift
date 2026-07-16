import Foundation

// MARK: - Cost-aware R:R (net edge after frictions)
//
// Gross reward:risk flatters every trade — it ignores the spread you cross twice, slippage,
// and commission. On a wide 4:1 setup the costs barely register; on a thin, high-turnover
// flip they can eat the entire edge. This nets them out: round-trip cost shrinks the reward
// AND widens the risk, so the NET R:R is what you actually trade. Pure + deterministic.
// Honest: the cost inputs are ESTIMATES — your real spread/slippage will differ.

struct NetEdge: Sendable, Equatable {
    let grossRR: Double
    let netRR: Double               // after round-trip costs (can be ≤0 if costs exceed the target)
    let costPerShare: Double
    let costAsPctOfReward: Double    // round-trip cost ÷ gross reward (0–1+)
    let netExpectancyR: Double?      // per 1R of gross risk, if a win probability was supplied
    /// The win rate you must BEAT to be positive-EV AFTER costs: p* = 1/(1+netRR). It turns
    /// the cost model into a single falsifiable bar — if your honest hit rate is below this,
    /// the setup loses money no matter how good the gross R:R looks. nil when netRR ≤ 0 (no
    /// win rate profits — costs exceed the target).
    let breakEvenWinRate: Double?
    let verdict: String
    nonisolated var costErodesEdge: Bool { netRR < 1 || costAsPctOfReward > 0.33 }
    /// Does an estimated win probability clear the after-cost break-even bar? Strictly beats
    /// it; false when the setup is unprofitable at any win rate (breakEvenWinRate nil).
    nonisolated func clearsCost(estWinProb: Double) -> Bool {
        guard let p = breakEvenWinRate else { return false }
        return estWinProb > p
    }
}

enum StockSageNetEdge {
    /// A LABELED, asset-class default cost assumption — crypto and thin foreign listings
    /// carry far wider spreads than US large-caps or FX majors. Estimates, not quotes.
    struct CostAssumption: Sendable, Equatable {
        let spreadBps: Double
        let slippageBps: Double
        let assetClass: String
        /// Round-trip taker/exchange fee (both fills), bps of entry. Dominant on crypto; ~0 on
        /// commission-free equity brokers. Defaulted so existing constructions stay valid.
        let takerFeeBps: Double
        /// F2 (OWNER-SIGNED 2026-07-10, "Ship F2 (per-order minimums)" — TRIAGE fastest-dollar
        /// UPDATE section): flat per-order commission MINIMUM in account currency, ONE side.
        /// Dominates small intl orders (IBKR tiered intl ≈ €1.30/order minimum — 26 bps one-way
        /// on a €500 XETRA order; RESEARCH_2026-07-03_current_era_costs.md §2, BankerOnWheels
        /// 2025, CONFIRMED 2/3; band-bottom, increase-only — the 18f1590 EM-tier discipline).
        /// 0 for US large-cap/index/FX/crypto: zero-commission era / percentage-fee venues —
        /// a deliberate no-op, not an omission. Only bites when `evaluate` is given an
        /// `orderNotional` (sized surfaces); bps-only callers are byte-identical.
        /// APPROXIMATION (review-noted): applied in the symbol's QUOTE currency while the
        /// citation is EUR — SAR/INR-quoted names understate the euro-equivalent minimum.
        /// Direction stays increase-only (never more permissive than pre-F2), consistent
        /// with the band-bottom discipline; an FX-aware minimum would be a future revision.
        let perOrderMinimum: Double
        nonisolated var roundTripBps: Double { spreadBps + slippageBps + takerFeeBps }
        nonisolated init(spreadBps: Double, slippageBps: Double, assetClass: String,
                         takerFeeBps: Double = 0, perOrderMinimum: Double = 0) {
            self.spreadBps = spreadBps; self.slippageBps = slippageBps
            self.assetClass = assetClass; self.takerFeeBps = takerFeeBps
            self.perOrderMinimum = perOrderMinimum
        }
    }

    /// Genuinely-EM suffixes only (RESEARCH_2026-07-03_current_era_costs.md §2's 60–100+bps
    /// band). Deliberately EXCLUDES .KS/.TW — MSCI labels Korea/Taiwan EM, but the universe's
    /// holdings there (005930.KS, 2330.TW) trade at developed-grade microstructure, and
    /// deliberately excludes every developed-market suffix (.L .DE .PA .AS .MC .MI .ST .SW .SI
    /// .T .HK .AX .TO) — those stay on the liquid intl default, which §2 ratifies as accurate.
    private nonisolated static let emSuffixes: [String] = [".NS", ".BO", ".SS", ".SA", ".MX", ".AE", ".QA", ".CA", ".JO"]

    /// Pick a sensible round-trip cost estimate from the symbol's asset class (suffix).
    /// Crypto widest, FX majors tightest; foreign single-listings wider than US large-caps.
    nonisolated static func defaultCosts(forSymbol symbol: String) -> CostAssumption {
        let s = symbol.uppercased()
        if s.hasSuffix("-USD") { return CostAssumption(spreadBps: 30, slippageBps: 20, assetClass: "crypto", takerFeeBps: 20) } // 70bps incl. ~0.1%/fill taker
        if s.hasSuffix("=X")   { return CostAssumption(spreadBps: 4,  slippageBps: 3,  assetClass: "FX") }          // 7bps
        if s.hasPrefix("^")    { return CostAssumption(spreadBps: 5,  slippageBps: 3,  assetClass: "index") }       // 8bps
        if s.hasSuffix(".SR")  {
            // Tadawul re-tier (2026-07-09; owner lifted the cost-table gate: "nothing is owner
            // gated i allow u"). Numbers from RESEARCH_2026-07-03_current_era_costs.md §2
            // (3/3-verified): Saudi fees alone ~12–18 bps/side → 24–36 bps RT BEFORE spread, so
            // the flat intl 30 was DANGEROUS-direction on the app's own Saudi-first core (the
            // gate passed losers). 60 bps = the bottom of the research's 60–100 EM band:
            // fees ≈30 (takerFeeBps) + the intl default's spread/slippage 20+10.
            return CostAssumption(spreadBps: 20, slippageBps: 10, assetClass: "intl (Tadawul)", takerFeeBps: 30, perOrderMinimum: 1.30)   // 60bps + F2 per-order min (IBKR tiered intl, research §2)
        }
        if emSuffixes.contains(where: s.hasSuffix) {
            // EM re-tier (2026-07-09; owner lifted the cost-table gate). 60bps = the BOTTOM of
            // RESEARCH_2026-07-03_current_era_costs.md §2's 60–100+bps small/illiquid/EM band
            // (per-order minimums alone 52–120bps RT, CONFIRMED 2/3): spread 20 + slippage 10
            // (same as the intl default below) + fees 30. UNLIKE .SR's fee leg (Tadawul-
            // measured, 24–36bps RT, 3/3), this 30 is a band-derived ESTIMATE, not a
            // per-market measurement — band bottom, not midpoint, is the largest increase the
            // evidence generically supports. See `emSuffixes` doc for the exclusion rationale.
            return CostAssumption(spreadBps: 20, slippageBps: 10, assetClass: "intl (EM)", takerFeeBps: 30, perOrderMinimum: 1.30)  // 60bps + F2 per-order min (IBKR tiered intl, research §2)
        }
        if s.contains(".")     { return CostAssumption(spreadBps: 20, slippageBps: 10, assetClass: "intl", perOrderMinimum: 1.30) }        // 30bps + F2 per-order min (IBKR tiered intl, research §2)
        return CostAssumption(spreadBps: 8, slippageBps: 5, assetClass: "US large-cap")                             // 13bps
    }

    /// Net reward:risk for a symbol using its asset-class default round-trip costs — ONE source of
    /// truth so the on-screen trade gate and the copied broker plan can't disagree on go/no-go. nil
    /// when the gross setup is degenerate (then callers fall back to gross). netRR is independent of
    /// winProb, so callers needing only the ratio can omit it. `annualFinancingRate`/`holdDays`
    /// default to 0 (byte-identical to before they existed) — a short-side caller should pass
    /// `StockSageExpectedValue.financingCostInputs(for:)`'s output so this convenience wrapper
    /// can't disagree with the ranking-driving `netEVR`/`netVelocity` figures for the same idea.
    nonisolated static func netRR(symbol: String, entry: Double, stop: Double, target: Double,
                                  annualFinancingRate: Double = 0, holdDays: Double = 0,
                                  winProb: Double? = nil) -> Double? {
        let c = defaultCosts(forSymbol: symbol)
        return evaluate(entry: entry, stop: stop, target: target,
                        spreadBps: c.spreadBps, slippageBps: c.slippageBps,
                        takerFeeBps: c.takerFeeBps,
                        annualFinancingRate: annualFinancingRate, holdDays: holdDays,
                        winProb: winProb)?.netRR
    }

    /// Conservative retail-honest annualized borrow/margin-cost ESTIMATE for a general-collateral
    /// short — a floor, not a promise (a genuinely hard-to-borrow name runs far higher). A cash
    /// long owns the shares outright and pays nothing here; a short is definitionally a margin
    /// transaction and pays this every day it's held, regardless of leverage. Chosen as a
    /// middle ground between the narrow stock-loan fee alone (~0.3-1%/yr for easy-to-borrows,
    /// too optimistic — ignores the margin-account requirement itself) and a full retail margin
    /// rate (5-8%/yr, broker-specific). Evidence + magnitude check:
    /// RESEARCH_2026-07-02_week_horizon_velocity.md ("overnight positions carry structurally
    /// higher costs... margin requirements are higher overnight, and stock-borrow fees are
    /// typically charged only on short positions held overnight").
    nonisolated static let defaultShortBorrowRate = 0.03   // 3%/year

    /// Net reward:risk after round-trip frictions. Works for longs and shorts (uses absolute
    /// distances). `spreadBps`/`slippageBps` are round-trip, in bps of entry price;
    /// `commissionPerShare` is absolute. `annualFinancingRate`/`holdDays` (both default 0 — a
    /// same-day/cash-long position pays nothing, byte-identical to prior behavior) add the
    /// overnight borrow/margin leg — callers holding a SHORT position pass `defaultShortBorrowRate` and the
    /// idea's expected hold days so the net figure honestly reflects the cost of holding it.
    /// nil if the gross setup is degenerate.
    nonisolated static func evaluate(entry: Double, stop: Double, target: Double,
                                     spreadBps: Double = 0, slippageBps: Double = 0,
                                     commissionPerShare: Double = 0, takerFeeBps: Double = 0,
                                     annualFinancingRate: Double = 0, holdDays: Double = 0,
                                     winProb: Double? = nil,
                                     perOrderMinimum: Double = 0, orderNotional: Double? = nil) -> NetEdge? {
        let grossReward = abs(target - entry)
        let grossRisk = abs(entry - stop)
        guard grossReward > 0, grossRisk > 0, entry > 0 else { return nil }

        // Financing leg: rate·calendarDays/365 (calendar-day basis by design; see the map entry).
        let financingCost = entry * Swift.max(0, annualFinancingRate) * Swift.max(0, holdDays) / 365
        // F2 (owner-signed 2026-07-10): flat per-order commission minimums dominate small intl
        // orders (see CostAssumption.perOrderMinimum for the research citation). Applied ONLY
        // when the caller knows the order size — nil `orderNotional` keeps every existing call
        // site byte-identical. Increase-only by construction: the round-trip commission per
        // share becomes max(commissionPerShare, 2·perOrderMinimum/shares) — both sides' order
        // minimums spread across the order's shares; it can never LOWER a cost.
        let effectiveCommission: Double = {
            let base = Swift.max(0, commissionPerShare)
            guard perOrderMinimum > 0, let notional = orderNotional, notional > 0 else { return base }
            let shares = notional / entry
            guard shares.isFinite, shares > 0 else { return base }
            return Swift.max(base, 2 * perOrderMinimum / shares)
        }()
        let cost = Swift.max(0, spreadBps + slippageBps + takerFeeBps) / 10_000 * entry
            + effectiveCommission + financingCost
        let grossRR = grossReward / grossRisk
        // Net figures (netRR/netExpectancyR/breakEvenWinRate) are derived from the SAME 50:1
        // ceiling StockSageExpectedValue.ev() already applies to rewardR — a hair-thin stop
        // (risk → 0) otherwise makes grossRR unbounded, which blows netRR/netExpectancyR up ~20x
        // past the properly-capped gross figure and collapses breakEvenWinRate toward 0, making
        // the net-cost gate (clearsCost) toothless for exactly the degenerate setups it exists to
        // catch. `grossRR` itself stays the true UNCAPPED ratio (still useful for display).
        let cappedGrossReward = Swift.min(grossRR, 50) * grossRisk
        let netReward = cappedGrossReward - cost
        let netRisk = grossRisk + cost
        let netRR = netReward / netRisk
        let costPct = cost / grossReward

        let netExpR: Double? = winProb.map { p in
            let pp = Swift.min(1, Swift.max(0, p))
            return (pp * netReward - (1 - pp) * netRisk) / grossRisk
        }

        let verdict: String
        if netRR <= 0 { verdict = "Costs exceed the target — don't take this." }
        else if netRR < 1 { verdict = "After costs R:R < 1 — skip." }
        else if costPct > 0.33 { verdict = "Costs eat \(Int((costPct * 100).rounded()))% of the target — thin." }
        else { verdict = "Costs take \(Int((costPct * 100).rounded()))% of the target — acceptable." }

        // The win rate that just breaks even after costs (nil if no win rate can profit).
        let breakEven: Double? = netRR > 0 ? 1 / (1 + netRR) : nil

        return NetEdge(grossRR: grossRR, netRR: netRR, costPerShare: cost,
                       costAsPctOfReward: costPct, netExpectancyR: netExpR,
                       breakEvenWinRate: breakEven, verdict: verdict)
    }
}

// MARK: - Tier-aware crypto round-trip cost estimate (CRYPTO_RISK #1)
//
// The flat crypto default above (70bps) treats BTC and a microcap alt identically. This richer
// estimate tiers by liquidity and itemizes the legs (half-spread crossed twice + slippage +
// taker fee on BOTH fills — the advisor's stop/target are crossing events, not resting limits).
// NEW ACCESSOR ONLY: `defaultCosts` is deliberately UNTOUCHED (byte-identical production
// ranking/gating — re-pointing it is a future owner-reviewed change; see the wave-2 plan's
// REJECTED register). Every band is a LABELED ESTIMATE midpoint, never a venue quote.
extension StockSageNetEdge {
    enum CryptoLiquidityTier: String, Sendable, CaseIterable {
        case majorBTCETH, large, mid, thin
    }

    struct CryptoCostEstimate: Sendable, Equatable {
        let tier: CryptoLiquidityTier
        let halfSpreadBps: Double        // one crossing; paid twice per round trip
        let slippageBps: Double          // round-trip
        let takerFeeBpsPerSide: Double   // per fill; paid twice per round trip
        let estimateLowBps: Double       // band edges — surfaced so no UI can show a false point
        let estimateHighBps: Double
        let assetClass: String           // always "crypto"
        let isEstimate: Bool             // always true
        nonisolated var roundTripBps: Double { 2 * halfSpreadBps + slippageBps + 2 * takerFeeBpsPerSide }
        nonisolated var disclaimer: String { "ESTIMATE only — your venue/tier/size differ; not a quote and not a promise." }
        /// Bridge into the existing `evaluate()` seam. CostAssumption's spread/slippage/taker are
        /// ROUND-TRIP by convention (see `defaultCosts`' 70bps comment), so: spread = 2·half,
        /// taker = 2·perSide.
        nonisolated var asCostAssumption: CostAssumption {
            CostAssumption(spreadBps: 2 * halfSpreadBps, slippageBps: slippageBps,
                           assetClass: assetClass, takerFeeBps: 2 * takerFeeBpsPerSide)
        }
    }

    /// Liquidity tier from the symbol + (optional) average daily dollar volume. Honesty floor:
    /// an UNKNOWN alt (advDollar nil) is `.mid`, never assumed deep. Reuses the liquidity
    /// engine's existing floors (thinBelow 2M / deepAbove 50M) — no new magic numbers.
    nonisolated static func cryptoTier(forSymbol symbol: String, advDollar: Double?) -> CryptoLiquidityTier {
        let s = symbol.uppercased()
        if s == "BTC-USD" || s == "ETH-USD" { return .majorBTCETH }
        guard let adv = advDollar else { return .mid }
        if adv < StockSageLiquidity.thinBelow { return .thin }
        if adv >= StockSageLiquidity.deepAbove { return .large }
        return .mid
    }

    /// The tier's labeled estimate bands (midpoint anchors hand-derived in the wave-2 plan;
    /// see /tmp/derive_cryptocost.swift): major 37.5bps RT (21–54), large 60 (34–86),
    /// mid 125 (70–180), thin 300 (160–440).
    nonisolated static func cryptoCosts(forSymbol symbol: String, advDollar: Double?) -> CryptoCostEstimate {
        switch cryptoTier(forSymbol: symbol, advDollar: advDollar) {
        case .majorBTCETH:
            return CryptoCostEstimate(tier: .majorBTCETH, halfSpreadBps: 2, slippageBps: 5.5,
                                      takerFeeBpsPerSide: 14, estimateLowBps: 21, estimateHighBps: 54,
                                      assetClass: "crypto", isEstimate: true)
        case .large:
            return CryptoCostEstimate(tier: .large, halfSpreadBps: 5.5, slippageBps: 14,
                                      takerFeeBpsPerSide: 17.5, estimateLowBps: 34, estimateHighBps: 86,
                                      assetClass: "crypto", isEstimate: true)
        case .mid:
            return CryptoCostEstimate(tier: .mid, halfSpreadBps: 17.5, slippageBps: 40,
                                      takerFeeBpsPerSide: 25, estimateLowBps: 70, estimateHighBps: 180,
                                      assetClass: "crypto", isEstimate: true)
        case .thin:
            return CryptoCostEstimate(tier: .thin, halfSpreadBps: 55, slippageBps: 130,
                                      takerFeeBpsPerSide: 30, estimateLowBps: 160, estimateHighBps: 440,
                                      assetClass: "crypto", isEstimate: true)
        }
    }

    /// DISPLAY-ONLY label for the round-trip cost line: a single point ("~13bps est. US
    /// large-cap") everywhere EXCEPT crypto, where a flat point is dishonest (BTC and a thin alt
    /// share one 70bps default) — crypto gets the tier-aware LOW–HIGH band this file already
    /// computes ("~160–440bps est. crypto"). Does not change `defaultCosts`, `roundTripBps`, or
    /// any value feeding the gate/ranking math — those still read `defaultCosts(forSymbol:)`
    /// untouched. Pure; nil `advDollar` still yields a band (honesty floor: unknown liquidity
    /// tiers to `.mid`, per `cryptoTier`, never to "no band").
    nonisolated static func costsDisplayLabel(forSymbol symbol: String, advDollar: Double?) -> String {
        let costs = defaultCosts(forSymbol: symbol)
        guard costs.assetClass == "crypto" else {
            return "~\(Int(costs.roundTripBps))bps est. \(costs.assetClass)"
        }
        let band = cryptoCosts(forSymbol: symbol, advDollar: advDollar)
        return "~\(Int(band.estimateLowBps))–\(Int(band.estimateHighBps))bps est. crypto"
    }

    /// Honesty disclosure for the crypto band-vs-priced mismatch (audit 2026-07-12, finding #1).
    /// The displayed net R:R / verdict are computed by `evaluate()` at the FLAT `defaultCosts` (70bps
    /// crypto) — deliberately, so the sheet's net can never disagree with the ranking net (the
    /// 2026-07-02 rank-consistency contract; re-pointing `defaultCosts` is a separate owner-reviewed
    /// change). But `costsDisplayLabel` shows the honest tier BAND. When the band's LOW exceeds the
    /// flat cost actually priced (the thin tier: 160 > 70), the net below is OPTIMISTIC relative to the
    /// band the header states — a real 160–440bps deduction would push net R:R lower, plausibly through
    /// the "skip" verdict. This suffix discloses that so the label and the number can't be read as one
    /// cost assumption. Empty when the flat priced cost is within/above the band low (mid/large/BTC-ETH,
    /// where the priced 70bps is not below what the user is told) → non-crypto and safe-tier byte-identical.
    nonisolated static func costsDisplayNote(forSymbol symbol: String, advDollar: Double?) -> String {
        let costs = defaultCosts(forSymbol: symbol)
        guard costs.assetClass == "crypto" else { return "" }
        let band = cryptoCosts(forSymbol: symbol, advDollar: advDollar)
        guard band.estimateLowBps > costs.roundTripBps else { return "" }
        return " — net below is priced at the ~\(Int(costs.roundTripBps))bps floor, so it is OPTIMISTIC vs this band; your real thin-alt cost is higher"
    }

    /// Standalone-sentence form of `costsDisplayNote` for the itemized ledger (a full caption row,
    /// not an inline suffix). nil (no row) unless the crypto band's low exceeds the flat priced cost.
    nonisolated static func costsOptimismSentence(forSymbol symbol: String, advDollar: Double?) -> String? {
        let costs = defaultCosts(forSymbol: symbol)
        guard costs.assetClass == "crypto" else { return nil }
        let band = cryptoCosts(forSymbol: symbol, advDollar: advDollar)
        guard band.estimateLowBps > costs.roundTripBps else { return nil }
        return "Net above is priced at the ~\(Int(costs.roundTripBps))bps crypto floor — OPTIMISTIC vs the ~\(Int(band.estimateLowBps))–\(Int(band.estimateHighBps))bps this thin alt really costs; your true net is lower."
    }
}
