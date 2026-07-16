import Foundation

// MARK: - Capital allocator (half-Kelly, edge-weighted, heat-capped)
//
// Turns a board of ranked ideas into a concrete "how much in each" plan by COMPOSING three
// already-tested engines — StockSageExpectedValue (fundability + edge), StockSageKelly (the
// per-idea fraction), and StockSagePositionSizer (whole shares). No new financial math.
// Total open heat is HARD-CAPPED: the edge-weighted half-Kelly fractions are scaled down
// uniformly so Σ risk ≤ maxHeat, and the whole-share floor keeps REALIZED heat ≤ the cap.
// Pure + deterministic. Honest: half-Kelly off ESTIMATED edges (conviction is NOT a
// probability); the per-position risk is the loss at the stop — a correlated gap can lose more.

struct AllocatedPosition: Sendable, Equatable, Identifiable {
    let symbol: String
    let riskFraction: Double   // account fraction at risk after heat-scaling
    let shares: Int            // whole shares (floored — never over-risk)
    let dollarsAtRisk: Double  // shares × |entry − stop|
    let notional: Double       // shares × entry
    let halfKelly: Double      // raw half-Kelly fraction pre-scale (transparency)
    let evR: Double            // the expected value in R that earned the weight
    var id: String { symbol }
}

struct CapitalAllocation: Sendable, Equatable {
    let positions: [AllocatedPosition]   // desc by riskFraction, tie-break asc symbol
    let totalHeat: Double                // Σ USD-normalized dollarsAtRisk ÷ account — ≤ maxHeat (F3 wave-B: per-position native×rawQuoteUnitToUSD; ×1 when no tracked rate)
    let requestedHeat: Double            // Σ of the fundable weights AFTER the correlation haircut, BEFORE heat-scaling
    let scaleApplied: Double             // ≤1 when the cap bound; 1 otherwise
    let account: Double
    let maxHeat: Double
    let caveat: String
    /// F5 (2026-07-09): how many ideas cleared EVERY qualitative gate (buy-family, positive EV,
    /// clears cost-after-frictions, positive weight) BEFORE the whole-share floor — i.e. were
    /// genuinely fundable in principle. 0 means there was nothing to deploy at all (the pre-F5
    /// silent-empty case). > 0 while `positions.isEmpty` means every one of them floored to 0
    /// shares at THIS account size — a DIFFERENT, more honest-to-disclose reason for an empty
    /// plan than "nothing qualified", which the view can now name instead of just vanishing.
    let fundableCandidateCount: Int
}

enum StockSageCapitalAllocator {
    nonisolated static let caveat = "Allocations are HALF-Kelly off ESTIMATED edges (conviction is not a probability); total open heat is hard-capped and whole shares floor each position, so realized heat stays ≤ the cap. Each line sizes the loss at its stop — a correlated gap can lose more."

    /// Deploy capital across the buy-family, positive-EV ideas: weight by half-Kelly (which
    /// already encodes the edge — bigger win·payoff ⇒ bigger fraction), scale uniformly so the
    /// summed risk fits `maxHeat`, then floor to whole shares. Empty plan on invalid inputs or
    /// when nothing is fundable.
    // F3 wave-B (2026-07-16): `fxRatesToUSD` (ccy→USD) sizes non-USD names FX-correctly and
    // USD-normalizes the heat ledger (see step 4/5). Empty map (the default) keeps every
    // existing caller and the test-lock byte-identical — never guess a rate.
    nonisolated static func allocate(ideas: [StockSageIdea], account: Double, maxHeat: Double = 0.08,
                                     calibration: StockSageConvictionCalibration? = nil,
                                     regime: MarketRegime? = nil,
                                     fxRatesToUSD: [String: Double] = [:]) -> CapitalAllocation {
        let cap = Swift.min(Swift.max(0, maxHeat), 1)
        func empty() -> CapitalAllocation {
            CapitalAllocation(positions: [], totalHeat: 0, requestedHeat: 0, scaleApplied: 1,
                              account: account, maxHeat: cap, caveat: caveat, fundableCandidateCount: 0)
        }
        guard account > 0, cap > 0 else { return empty() }

        // Step 1+2: fund only buy-family ideas with a defined R and positive EV; the raw weight
        // IS half-Kelly (already a FRACTION in [0,0.5] — do NOT divide by account; it also
        // already encodes the edge, so no separate EV multiplier — that would double-count).
        struct Fundable { let symbol: String; let entry: Double; let stop: Double; let weight: Double; let halfKelly: Double; let evR: Double }
        var fundable: [Fundable] = []
        for idea in ideas {
            let a = idea.advice
            guard a.action == .buy || a.action == .strongBuy,
                  let stop = a.stopPrice, let target = a.targetPrice, idea.price > 0,
                  let ev = StockSageExpectedValue.ev(conviction: a.conviction, entry: idea.price, stop: stop, target: target, calibration: calibration),
                  ev.evR > 0 else { continue }
            // COST GATE: don't deploy real dollars into a setup that's net-negative after round-trip
            // frictions (spread+slippage+taker). The rank keys + best-bet already exclude these via
            // clearsCostAfterFrictions, but the allocator — which emits the ACTUAL shares — did not,
            // so a thin high-cost crypto flip the boards hid could still be funded. (Sizing still uses
            // gross Kelly here; net-payoff sizing is a separate change to keep the verified test math.)
            let costs = StockSageNetEdge.defaultCosts(forSymbol: idea.symbol)
            guard let ne = StockSageNetEdge.evaluate(entry: idea.price, stop: stop, target: target,
                                                     spreadBps: costs.spreadBps, slippageBps: costs.slippageBps,
                                                     takerFeeBps: costs.takerFeeBps, winProb: ev.winProbEstimate),
                  ne.clearsCost(estWinProb: ev.winProbEstimate) else { continue }
            let k = StockSageKelly.compute(winRate: ev.winProbEstimate, payoffRatio: ev.rewardR, accountSize: account)
            // Weight off suggestedFraction (= half-Kelly HARD-CAPPED at Kelly's 20% per-position
            // limit), NOT raw half-Kelly — so a lone idea under maxHeat can't sit at up to 50% risk.
            guard k.suggestedFraction > 0 else { continue }
            // Regime sizing bias: scale each position up in a strong bull (≤1.25×) / down in a
            // risk-off tape (≥0.25×), matching the per-card "Regime size" the owner sees — which the
            // DEPLOYED plan previously ignored. Re-capped at the Kelly per-position limit, so an
            // UP-bias can't lift a name ALREADY at the 0.20 cap (down-bias always applies fully): the
            // book scales down uniformly, but up-scaling is clipped at the cap — deliberately
            // conservative (it only ever under-deploys the top names, never over-risks). nil → unchanged.
            var weight = regime.map { StockSageRegime.adjustedWeight(base: k.suggestedFraction, bias: $0.sizingBias, cap: StockSageKelly.maxFraction) } ?? k.suggestedFraction
            // Vol-targeting (match the advisor card): shrink the DEPLOYED risk for high realized vol so
            // a ~70%-vol crypto/growth name isn't sized like a calm equity. nil vol ⇒ no shrink.
            if let v = idea.realizedVol { weight /= StockSageExpectedValue.cryptoRiskScaler(annualizedVol: v) }
            // Per-symbol vol regime brake (EDGE_RESEARCH #1, VIX-free): further reduces weight when
            // this name's realized vol is historically elevated vs. its own 12-month distribution.
            // Composes with cryptoRiskScaler (both apply); nil when history too short → no change.
            if let mult = idea.volRegime?.sizingMultiplier { weight *= mult }
            guard weight > 0 else { continue }
            fundable.append(Fundable(symbol: idea.symbol, entry: idea.price, stop: stop,
                                     weight: weight, halfKelly: k.halfKelly, evR: ev.evR))
        }
        guard !fundable.isEmpty else { return empty() }

        // Step 2.5 — CORRELATION-AWARE HEAT: a cluster of names that move together is ~1 bet, not N,
        // so down-weight cluster members (each /K) BEFORE heat-scaling. Otherwise a "diversified"
        // plan can be one concentrated bet wearing several tickers (Choueifaty 2013; HRP). Returns
        // come from each idea's sparkline; empty/short sparks → correlation 0 → no clique → no-op.
        let sparkBy = Dictionary(ideas.map { ($0.symbol, $0.spark) }, uniquingKeysWith: { a, _ in a })
        let rawWeights = fundable.map(\.weight)
        let fundReturns = fundable.map { StockSagePortfolioAnalytics.dailyReturns(sparkBy[$0.symbol] ?? []) }
        let adjWeights = StockSageCorrelationCluster.correlationAdjustedWeights(
            symbols: fundable.map(\.symbol), weights: rawWeights, returns: fundReturns)
        let deweightedForCorrelation = zip(rawWeights, adjWeights).contains { $0 - $1 > 1e-12 }
        if deweightedForCorrelation {
            fundable = zip(fundable, adjWeights).map { f, w in
                Fundable(symbol: f.symbol, entry: f.entry, stop: f.stop, weight: w, halfKelly: f.halfKelly, evR: f.evR)
            }
        }

        // Step 3: uniform proportional scaling pins Σ pre-floor heat to min(requested, cap) and
        // preserves the edge ranking.
        let requestedHeat = fundable.reduce(0) { $0 + $1.weight }
        let scaleApplied = requestedHeat > cap ? cap / requestedHeat : 1

        // Step 4: the sizer is the ONLY place dollars/shares are produced; it floors shares DOWN,
        // so realized dollarsAtRisk ≤ scaledFraction·account (in USD terms once normalized below)
        // ⇒ summed realized heat ≤ the cap. F3 wave-B: with a tracked FX rate the sizing runs in
        // the symbol's own currency (the F3 map overload — .SR was under-sized ~3.75× vs the
        // stated fraction), and the HEAT ledger converts each position's native dollarsAtRisk
        // back to USD (`rawQuoteUnitToUSD`; untracked/USD → ×1 = prior behavior). Fields on
        // AllocatedPosition stay RAW-NATIVE — every consumer already renders them through
        // `approxAmount(symbol:)` / converts via `majorUnitValue`×rate.
        var positions: [AllocatedPosition] = []
        var usdAtRisk = 0.0
        for f in fundable {
            let scaled = f.weight * scaleApplied
            guard let ps = StockSagePositionSizer.size(account: account, riskFraction: scaled,
                                                       entry: f.entry, stop: f.stop,
                                                       symbol: f.symbol, fxRatesToUSD: fxRatesToUSD),
                  ps.shares > 0 else { continue }
            let rawUnit = StockSagePositionSizer.rawQuoteUnitToUSD(symbol: f.symbol, fxRatesToUSD: fxRatesToUSD) ?? 1
            usdAtRisk += ps.dollarsAtRisk * rawUnit
            positions.append(AllocatedPosition(symbol: f.symbol, riskFraction: scaled, shares: ps.shares,
                                               dollarsAtRisk: ps.dollarsAtRisk, notional: ps.notional,
                                               halfKelly: f.halfKelly, evR: f.evR))
        }

        // Step 5: realized heat (USD-normalized) + deterministic order (desc risk, tie-break asc symbol).
        let totalHeat = usdAtRisk / account
        let sorted = positions.sorted(by: positionOrder)
        var finalCaveat = caveat
        if deweightedForCorrelation { finalCaveat += " A correlated cluster was de-weighted to count as ~one bet, not several." }
        if let regime, abs(regime.sizingBias - 1) > 0.01 {
            finalCaveat += String(format: " Sized ×%.2f for the %@ regime.", regime.sizingBias, regime.state.rawValue)
        }
        return CapitalAllocation(positions: sorted, totalHeat: totalHeat, requestedHeat: requestedHeat,
                                 scaleApplied: scaleApplied, account: account, maxHeat: cap, caveat: finalCaveat,
                                 fundableCandidateCount: fundable.count)
    }

    /// #8 (BUGHUNT_NEWENGINES): the position sort is a TOTAL order, not just (risk desc, symbol
    /// asc). `Array.sorted(by:)` is not guaranteed stable, so two rows tying on BOTH keys
    /// (duplicate symbols at equal half-Kelly — the allocator does not dedup symbols) previously
    /// had unspecified relative order, defeating this file's "Pure + deterministic" contract.
    /// Chain: riskFraction desc → symbol asc (raw `<`: "BTC" < "btc", case pairs never tie —
    /// deliberate, keeps every pre-existing distinct-symbol order byte-identical) →
    /// dollarsAtRisk desc → notional desc. Exposed (not private) so the test can pin the chain.
    nonisolated static func positionOrder(_ a: AllocatedPosition, _ b: AllocatedPosition) -> Bool {
        if a.riskFraction != b.riskFraction { return a.riskFraction > b.riskFraction }
        if a.symbol != b.symbol { return a.symbol < b.symbol }
        if a.dollarsAtRisk != b.dollarsAtRisk { return a.dollarsAtRisk > b.dollarsAtRisk }
        return a.notional > b.notional
    }

    /// Marginal sizing for ONE new idea against the LIVE book — "I have an idea + an open
    /// book, how much do I add?" Heat-headroom capped (never pushes total open risk past
    /// `maxHeat`) and correlation-gated (refuses a name that's really doubling down on a
    /// held one). Composes the same half-Kelly + heat + cluster-check engines as `allocate`,
    /// just for a single candidate against an already-open book instead of a fresh deploy.
    nonisolated static func suggestAdd(
        idea: StockSageIdea,
        openTrades: [(shares: Double, entry: Double, stop: Double)],
        holdings: [(symbol: String, returns: [Double])],
        candidateReturns: [Double],
        account: Double,
        maxHeat: Double = 0.10,
        correlationThreshold: Double = 0.80,
        calibration: StockSageConvictionCalibration? = nil
    ) -> AddSuggestion? {
        guard account > 0 else { return nil }
        let a = idea.advice
        guard let stop = a.stopPrice, let target = a.targetPrice, idea.price > 0,
              let ev = StockSageExpectedValue.ev(conviction: a.conviction, entry: idea.price, stop: stop,
                                                 target: target, calibration: calibration) else { return nil }

        let cap = Swift.min(Swift.max(0, maxHeat), 1)
        let heat = StockSagePortfolioHeat.compute(openTrades: openTrades, accountSize: account)
        let heatBefore = heat?.heatPct ?? 0
        let headroom = Swift.max(0, cap - heatBefore)
        let cluster = StockSageClusterCheck.check(candidate: idea.symbol, candidateReturns: candidateReturns,
                                                   holdings: holdings, threshold: correlationThreshold)

        func blocked(_ reason: String) -> AddSuggestion {
            AddSuggestion(symbol: idea.symbol, approved: false, riskFraction: 0, shares: 0, dollarsAtRisk: 0,
                         heatBefore: heatBefore, heatHeadroom: headroom,
                         nearestCorrelation: cluster?.nearest?.correlation, reason: reason, caveat: caveat)
        }

        // Concentration gate FIRST — a correlated name is a bad add regardless of edge.
        if let cluster, cluster.isConcentrating { return blocked(cluster.note) }
        guard ev.evR > 0 else { return blocked("No positive edge for \(idea.symbol) at the current stop/target.") }

        let k = StockSageKelly.compute(winRate: ev.winProbEstimate, payoffRatio: ev.rewardR, accountSize: account)
        // Same per-position cap `allocate` uses (suggestedFraction, not raw halfKelly), further
        // capped by whatever heat headroom remains — never pushes total book risk past maxHeat.
        let suggested = Swift.min(k.suggestedFraction, headroom)
        guard suggested > 0,
              let ps = StockSagePositionSizer.size(account: account, riskFraction: suggested, entry: idea.price, stop: stop),
              ps.shares > 0 else {
            return blocked(headroom <= 0
                ? "No heat headroom left — the book is already at \(Int((heatBefore * 100).rounded()))% open risk."
                : "Position size rounds to zero shares at this account size.")
        }
        let reason = suggested < k.suggestedFraction
            ? "Capped by remaining heat headroom (\(Int((headroom * 100).rounded()))% left of the \(Int((cap * 100).rounded()))% cap)."
            : "Half-Kelly sized off the estimated edge (evR \(String(format: "%.2f", ev.evR)))."
        return AddSuggestion(symbol: idea.symbol, approved: true, riskFraction: suggested, shares: ps.shares,
                             dollarsAtRisk: ps.dollarsAtRisk, heatBefore: heatBefore, heatHeadroom: headroom,
                             nearestCorrelation: cluster?.nearest?.correlation, reason: reason, caveat: caveat)
    }

    /// EV-weighted whole-book reweight — "which names deserve MORE of the book right now, given
    /// today's edge?" Unlike an equal-risk (risk-parity) reweight, targets here are each symbol's
    /// positive, buy-family `StockSageExpectedValue.ev(for:).evR`, normalized across the union of
    /// currently-held symbols and candidate `ideas`. A held symbol with no current positive-EV buy
    /// idea gets edge 0 — i.e. it's simply absent from `targets`, which `StockSageRebalance.plan`
    /// already treats as "trim to 0" (reused verbatim, band and all — no new drift/band math here).
    /// A brand-new (not currently held) idea is correlation-gated against the OTHER held names'
    /// return series (derived from each idea's own `spark`, exactly like `allocate`'s cluster
    /// de-weighting) via the existing `StockSageClusterCheck`; a match ≥ `correlationThreshold`
    /// excludes that idea entirely (composed only when a return series is available — too little
    /// spark history silently skips the gate, i.e. size-only, matching `ClusterCheck.check`'s own
    /// nil behavior). A mutually-correlated CLIQUE within the new-idea pool itself (2026-07-01 fix
    /// — the held-vs-new gate above never checked new-vs-new) is separately DE-WEIGHTED (not
    /// excluded) via `StockSageCorrelationCluster.correlationAdjustedWeights`, mirroring `allocate`'s
    /// own Step 2.5. Because `StockSageRebalance.plan` always renormalizes whatever `targets` it's
    /// given up to 100% (there is no "hold cash" residual in that model), a combined new-idea target
    /// share can only be capped at `maxHeat` of the reweighted total when there is an existing
    /// held-edge pool to absorb the remaining share — the closed-form single-pass scale below is
    /// skipped when nothing fundable is currently held (nothing to cap against). A per-position
    /// concentration ceiling (2026-07-01 fix — `StockSageKelly.maxFraction`, the same 20% cap every
    /// other sizing tool in this engine enforces) is applied to the FINAL combined targets when
    /// enough funded names exist to redistribute the excess under it; when they don't (e.g. a sole
    /// fundable name — capping it would be silently undone by `Rebalance.plan`'s own renormalization,
    /// since dividing a lone value by itself is always 1.0), the plan is left at its honest,
    /// concentrated weights with a loud caveat instead of a false sense of safety. nil when nothing is
    /// invested or no symbol anywhere has positive edge (mirrors `Rebalance.plan`'s own "nothing to
    /// do" nil — reused, not reimplemented). Honest: evR is a rules-based ESTIMATE that decays as
    /// price moves; these are reweight TARGETS, not fills, and — exactly like the underlying
    /// `Rebalance.plan` — ignore spread/slippage/tax/min-lot.
    nonisolated static func rebalanceToEdge(
        holdings: [(symbol: String, value: Double)],
        ideas: [StockSageIdea],
        band: Double = 0.03,
        maxHeat: Double = 0.10,
        correlationThreshold: Double = 0.80,
        calibration: StockSageConvictionCalibration? = nil
    ) -> EdgeRebalancePlan? {
        let heldSymbols = Set(holdings.filter { $0.value > 0 }.map { $0.symbol.uppercased() })
        let ideaBySymbol = Dictionary(ideas.map { ($0.symbol.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })

        // Positive, buy-family edge only (mirrors `allocate`'s own gate) — a held name whose idea
        // has gone flat/negative, or has none at all, is simply never added to `targets`.
        func rawWeight(_ idea: StockSageIdea) -> Double? {
            let a = idea.advice
            guard a.action == .buy || a.action == .strongBuy, idea.price > 0,
                  let ev = StockSageExpectedValue.ev(for: idea, calibration: calibration), ev.evR > 0 else { return nil }
            return ev.evR
        }

        // Correlation baseline for gating NEW entrants: every currently-held symbol's own idea (if
        // any) supplies its return series — a held name doesn't need to be independently fundable to
        // serve as the "you already own this exposure" baseline. Sorted for deterministic output.
        let heldReturnSeries: [(symbol: String, returns: [Double])] = heldSymbols.sorted().compactMap { sym in
            guard let idea = ideaBySymbol[sym] else { return nil }
            let r = StockSagePortfolioAnalytics.dailyReturns(idea.spark)
            return r.count >= 2 ? (symbol: idea.symbol, returns: r) : nil
        }

        var heldWeights: [String: Double] = [:]
        var newWeights: [String: Double] = [:]
        var excludedSymbols: [String] = []
        var excludedNotes: [String] = []
        for idea in ideas {
            guard let w = rawWeight(idea) else { continue }
            if heldSymbols.contains(idea.symbol.uppercased()) {
                heldWeights[idea.symbol] = w
            } else {
                let candidateReturns = StockSagePortfolioAnalytics.dailyReturns(idea.spark)
                if let cluster = StockSageClusterCheck.check(candidate: idea.symbol, candidateReturns: candidateReturns,
                                                              holdings: heldReturnSeries, threshold: correlationThreshold),
                   cluster.isConcentrating {
                    excludedSymbols.append(idea.symbol)
                    excludedNotes.append(cluster.note)
                    continue
                }
                newWeights[idea.symbol] = w
            }
        }

        // 2026-07-01 adversarial-review fix: the gate above only checks each NEW candidate against
        // currently-HELD names — two or three brand-new, mutually-correlated ideas (e.g. BTC-USD +
        // ETH-USD added to a near-empty book) previously passed completely unchecked against EACH
        // OTHER. De-weight a correlated clique WITHIN the new pool itself, mirroring `allocate`'s own
        // Step 2.5 (StockSageCorrelationCluster.correlationAdjustedWeights — the same de-weight-by-
        // cluster-size, not full-exclusion, treatment). No-op when fewer than 3 new symbols or return
        // series are too short/absent (the primitive's own guard), matching this file's established
        // "too little data → size-only, never a hard failure" convention.
        if newWeights.count >= 3 {
            let newSymbols = newWeights.keys.sorted()
            let newReturns = newSymbols.map { StockSagePortfolioAnalytics.dailyReturns(ideaBySymbol[$0.uppercased()]?.spark ?? []) }
            let adjusted = StockSageCorrelationCluster.correlationAdjustedWeights(
                symbols: newSymbols, weights: newSymbols.map { newWeights[$0]! }, returns: newReturns)
            for (symbol, weight) in zip(newSymbols, adjusted) { newWeights[symbol] = weight }
        }

        // Closed-form single-pass churn cap: solve for the scale factor on the NEW pool such that,
        // after `Rebalance.plan` renormalizes targets to sum 1, the new pool's combined share is
        // exactly `cap` — Σnew·scale / (Σheld + Σnew·scale) = cap ⟹ scale = cap/(1−cap) · Σheld/Σnew.
        let heldRaw = heldWeights.values.reduce(0, +)
        let newRaw = newWeights.values.reduce(0, +)
        let cap = Swift.min(Swift.max(0, maxHeat), 1)
        var cappedNew = false
        if heldRaw > 0, newRaw > 0, cap < 1, newRaw / (heldRaw + newRaw) > cap {
            let scale = (cap / (1 - cap)) * heldRaw / newRaw
            newWeights = newWeights.mapValues { $0 * scale }
            cappedNew = true
        }

        var targets = heldWeights
        for (symbol, weight) in newWeights { targets[symbol] = weight }

        // 2026-07-01 adversarial-review fix: unlike EVERY other sizing tool in this engine
        // (StockSageAdvisor.maxWeight, StockSageCapitalAllocator.allocate's Kelly cap,
        // StockSagePyramid's riskCap), rebalanceToEdge had NO per-position concentration ceiling —
        // because `StockSageRebalance.plan` always renormalizes `targets` to sum to 1 with no cash
        // residual, a sole (or dominant) positive-EV name could be recommended at up to 100% of the
        // book. Attempt to cap each target's NORMALIZED share at `StockSageKelly.maxFraction`,
        // redistributing the clipped excess proportionally among names still under the cap
        // (iterative — a redistribution pass can itself push another name over the cap, so repeat
        // until stable). CRITICALLY: when there's only ONE funded name (or every funded name is
        // simultaneously pinned at/above the cap with nothing left to redistribute into), the
        // capped shares no longer sum to 1 — and because `Rebalance.plan` unconditionally
        // renormalizes whatever `targets` it receives BACK to summing 1, silently feeding it those
        // partial shares would get the cap invisibly UNDONE by that renormalization, giving a false
        // sense of safety. In that unfixable case, leave `targets` at its uncapped values (no
        // silent, ineffective attempt) and surface a LOUD, explicit caveat instead — the caller must
        // know this recommendation implies full/near-full concentration because nothing else is
        // fundable to diversify into, not be told a cap was applied when it structurally could not be.
        var concentrationCapped = false
        var concentrationUnavoidable = false
        let targetsSum = targets.values.reduce(0, +)
        if targetsSum > 0 {
            var shares = targets.mapValues { $0 / targetsSum }
            let posCap = StockSageKelly.maxFraction
            var anyOverCap = false
            for _ in 0..<shares.count {
                let overCap = shares.filter { $0.value > posCap }
                guard !overCap.isEmpty else { break }
                anyOverCap = true
                var excess = 0.0
                for (symbol, share) in overCap { excess += share - posCap; shares[symbol] = posCap }
                let underCapKeys = shares.keys.filter { shares[$0]! < posCap }
                let underCapTotal = underCapKeys.reduce(0) { $0 + shares[$1]! }
                guard underCapTotal > 0 else { break }   // nothing left to redistribute into
                for symbol in underCapKeys { shares[symbol]! += excess * (shares[symbol]! / underCapTotal) }
            }
            if anyOverCap {
                let redistributedSum = shares.values.reduce(0, +)
                if abs(redistributedSum - 1.0) < 1e-9 {
                    targets = shares   // fully absorbed — Rebalance.plan's renormalization is a no-op here
                    concentrationCapped = true
                } else {
                    concentrationUnavoidable = true   // capping would be silently undone by renormalization — don't pretend
                }
            }
        }

        guard let plan = StockSageRebalance.plan(holdings: holdings, targets: targets, band: band) else { return nil }

        var note = "Targets are each name's positive, buy-family EV estimate (evR), normalized across the held book + new ideas — this chases EDGE, not equal risk. A held name with no current positive-EV idea is trimmed toward the exit. evR decays as price moves; these are reweight targets, not fills, and ignore spread/slippage/tax/min-lot."
        if cappedNew {
            note += String(format: " New-idea entries were capped at a combined %.0f%% of the reweighted book this pass to limit one-shot churn into unproven names.", cap * 100)
        }
        if concentrationCapped {
            note += String(format: " One or more targets were capped at %.0f%% of the book (the same per-position ceiling Kelly sizing uses elsewhere) and the excess redistributed.", StockSageKelly.maxFraction * 100)
        }
        if concentrationUnavoidable {
            note += String(format: " ⚠ CONCENTRATION WARNING: this book has too few fundable names to keep any single position under the usual %.0f%% ceiling — at least one target here exceeds it. Size cautiously; do not treat this as a diversified plan.", StockSageKelly.maxFraction * 100)
        }
        if !excludedNotes.isEmpty {
            note += " Excluded (correlation-blocked): " + excludedNotes.joined(separator: " ")
        }
        return EdgeRebalancePlan(plan: plan, excludedSymbols: excludedSymbols.sorted(), note: note)
    }
}

struct AddSuggestion: Sendable, Equatable {
    let symbol: String
    let approved: Bool
    let riskFraction: Double      // suggested heat to add (0 if blocked)
    let shares: Int
    let dollarsAtRisk: Double
    let heatBefore: Double        // current portfolio heat (fraction, 0–1)
    let heatHeadroom: Double      // maxHeat - heatBefore, floored at 0
    let nearestCorrelation: Double?
    let reason: String            // why this size / why blocked
    let caveat: String
}

/// Result of `StockSageCapitalAllocator.rebalanceToEdge` — the underlying `RebalancePlan` (reused
/// verbatim, same `trades`/`isBalanced`) plus the transparency the edge-weighting adds: which
/// brand-new ideas were excluded for concentration, and why.
struct EdgeRebalancePlan: Sendable, Equatable {
    let plan: RebalancePlan
    let excludedSymbols: [String]   // new ideas excluded for correlation-blocking (asc by symbol)
    let note: String
}
