import Foundation

// MARK: - Today's plan
//
// Composes the already-tested pieces — the best positive-EV opportunity, its pre-trade
// GATE verdict, and the position SIZE — into one copyable, ordered checklist: "here's
// the single best thing to do right now, whether the gate clears it, and exactly how
// big." Pure builder over verified engines. Honesty: estimates, not advice; clearing
// the gate isn't a win, it's "not obviously reckless."

enum StockSageTodayPlan {
    enum RankedMode: Sendable {
        case fastestCompounding
        case equityExecutableFirst
    }
    /// Build the plan text for one idea (typically the best opportunity). Returns a
    /// multi-line checklist. `account`/`riskFraction` add the concrete share size when set.
    /// `positions` (TODAY-PARITY, defaulted `[]` — existing callers/tests byte-unchanged) adds
    /// held-position context via `StockSagePortfolio.holding(for:in:)` — the same "you already
    /// hold N sh" awareness the ranked list (`rankedActions`) and the ideas board's Held chip
    /// already carry. Display-only: never affects the gate, size, or EV math.
    /// `priceAsOf` overrides the idea's own price timestamp when explicitly supplied.
    /// Missing/future/older-than-60s quotes export a draft status, never a ticket.
    // F3 wave-A (2026-07-16): `fxRatesToUSD` (ccy→USD) makes the share count FX-correct for
    // non-USD names. Missing foreign FX blocks a sized order plan, never guesses 1:1.
    nonisolated static func build(idea: StockSageIdea, ev: ExpectedValue?,
                                  account: Double?, riskFraction: Double?,
                                  daysToEarnings: Int? = nil, isSample: Bool = false,
                                  positions: [PortfolioPosition] = [],
                                  priceAsOf: Date? = nil,
                                  fxRatesToUSD: [String: Double] = [:],
                                  // A3 (2026-07-16): the card's own pixels show "Analysis over 4h old"
                                  // (cardIsStale's analysis axis); the caller passes that same bool so
                                  // a quote-verified copied plan carries the analysis warning too.
                                  analysisStale: Bool = false,
                                  calibration: StockSageConvictionCalibration? = nil,
                                  now: Date = Date()) -> String {
        let a = idea.advice
        let entry = idea.price
        let draft = StockSageTradePlan.draftOnlyStatus(symbol: idea.symbol,
            priceAsOf: priceAsOf ?? idea.priceAsOf, isSample: isSample, now: now)
        let earnings = daysToEarnings.map {
            [idea.symbol.uppercased(): EarningsProximity(daysUntil: $0, severity: StockSageEarnings.severity(daysUntil: $0))]
        } ?? [:]
        let snapshot = StockSageDecisionSnapshotBuilder.build(idea: idea, calibration: calibration,
            earnings: earnings, account: account, riskFraction: riskFraction, fxRatesToUSD: fxRatesToUSD)
        let gate = snapshot.gate

        // EXPORT-W4-1 parity (blocked-fixture QA, 2026-07-09): the detail sheet's copy
        // auto-skips a BLOCKED setup ("a blocked idea is never exported as an actionable
        // order checklist") — this builder, feeding the best-opp card/CTA "Copy today's
        // plan", exported a full ticket with the verdict buried mid-list. Same rule now:
        // blocked ⇒ a status report, never entry/stop/size lines.
        if let gate, gate.decision == .blocked {
            let failLabels = gate.checks.filter { $0.level == .fail }.map(\.label)
            let warnLabels = gate.checks.filter { $0.level == .warn }.map(\.label)
            var blocked = "Copy plan skipped — \(idea.symbol) is currently BLOCKED by the pre-trade gate."
            if !failLabels.isEmpty { blocked += "\nFAIL: " + failLabels.joined(separator: "; ") }
            if !warnLabels.isEmpty { blocked += "\nWARN: " + warnLabels.joined(separator: "; ") }
            blocked += "\nNo order plan exported. Fix the gate failures, then copy again."
            if let draft { blocked = draft + "\n" + blocked }
            if analysisStale {
                blocked = "⚠ ANALYSIS OVER 4H OLD — re-scan before ordering.\n" + blocked
            }
            return blocked
        }
        if let draft { return draft }

        var lines = ["Today's plan — estimates, not advice. Size with a stop; risk control > signal."]
        if let nbbo = idea.nbbo, nbbo.costConditionVerified, nbbo.spreadBps(at: Date()) != nil {
            lines.append("Costs: " + StockSageNetEdge.costsDisplayLabel(forSymbol: idea.symbol, advDollar: nil, nbbo: nbbo))
        }
        // A3: the analysis (advice/EV) can be >4h stale even when the price bar is today's — the
        // card shows this; the exported plan must too. Caller passes the same cardIsStale bool.
        if analysisStale {
            lines.insert("⚠ ANALYSIS OVER 4H OLD — re-scan before ordering.", at: 0)
        }
        var n = 1
        lines.append("\(n). Best bet: \(idea.symbol) (\(a.action.rawValue))"
            + (ev.map { String(format: " — est. EV %+.2fR (gross)", $0.evR) } ?? "")); n += 1

        if let gate {
            let gateExtra = (gate.fails > 0 || gate.warns > 0) ? " (\(gate.fails) fail, \(gate.warns) warn)" : ""
            lines.append("\(n). Gate: \(gate.decision.rawValue)\(gateExtra)")
        } else {
            lines.append("\(n). Pre-trade gate: not evaluated — enter risk % to see the verdict.")
        }
        n += 1
        if let net = snapshot.netEdge, let netR = net.netExpectancyR {
            lines.append(String(format: "Net R:R %.2f:1; estimated net expectancy %+.2fR.",
                                net.netRR, netR))
        }
        if let note = snapshot.costSizeNote { lines.append(note) }

        if let s = a.stopPrice {
            var size = ""
            if let ps = snapshot.positionSize {
                // Audit 2026-07-12 (wave-2 #1): currency-correct at-risk (native currency + pence ÷100).
                size = " — \(ps.shares) shares \(StockSageCurrency.approxAmount(ps.dollarsAtRisk, symbol: idea.symbol)) at risk (\(Int(ps.pctOfAccount.rounded()))% of acct)"
                // F-review export-parity fix (2026-07-10, wave-7 rule): the on-screen row already
                // discloses this (StockSagePositionSizer.summaryLine, MarketsTodayActionsCard's
                // unfundableSuffix) — a copied plan silent on it reads as a placeable order.
                if ps.shares == 0 { size += " — below the 1-share minimum at your account size" }
            }
            // TODAY-PARITY: pasted into a broker without knowing you already hold the name
            // silently stacks new risk on an existing position — same rationale as the ranked
            // list's "holds N sh" suffix (rankedActions/copyAllText above).
            if let held = StockSagePortfolio.holding(for: idea.symbol, in: positions) {
                size += " | holds \(numShares(held.shares)) sh"
            }
            lines.append("\(n). Entry ~\(fmt(entry)), stop \(fmt(s))"
                + (a.targetPrice.map { ", target \(fmt($0))" } ?? "") + size); n += 1
        } else {
            lines.append("\(n). No stop defined — DO NOT enter until you set one (risk is undefined)."); n += 1
        }

        lines.append("\(n). Rule: risk small per trade, always a stop, never chase. The gate and EV are estimates, not a forecast.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Ranked action list (FASTMONEY_BACKLOG #4)
    //
    // "Do I take #1 or #2 today?" — collapses the fast lane's top-N by velocity into one
    // glance: the number (velocity), the concrete order (entry/stop/target), the SIZE
    // (PositionSizer, same flat per-trade risk% every other card uses), and the pre-trade
    // GATE verdict (TradeGate, same net-RR source of truth `build` already uses). Pure
    // composition over already-tested engines — fastLane() supplies the order and the
    // positive-EV filter, so this adds no new signal or ranking math.

    /// Top-`max` ranked "what do I do today" plans, ordered exactly as `StockSageExpectedValue.
    /// fastLane` ranks them (fastest compounding, positive-EV only). `account`/`riskFraction`
    /// add the concrete share size when set (nil/0 ⇒ no size, matching `build`'s own fallback).
    /// `calibration`/`earnings` are optional pass-throughs to the same-named engines so the
    /// gate and the number can't disagree with the rest of the board; both default to "none",
    /// i.e. the uncalibrated linear prior and no earnings demotion.
    /// `positions`/`journalTrades` (TODAY-PARITY, defaulted `[]` — existing callers/tests
    /// byte-unchanged) populate each plan's optional `heldShares`/`closedTradeCount` via the
    /// SAME batch helpers the ideas board uses (`StockSagePortfolio.holdingBySymbol` /
    /// `StockSageJournal.historyBySymbol`) — display-only, no effect on ranking/sizing/gate.
    nonisolated static func rankedActions(_ ideas: [StockSageIdea], account: Double?, riskFraction: Double?,
                                         holds: VelocityHoldDays = .defaults,
                                         calibration: StockSageConvictionCalibration? = nil,
                                         marketRegime: MarketRegime? = nil,
                                         earnings: [String: EarningsProximity] = [:],
                                         liquidity: [String: LiquidityProfile] = [:],
                                         positions: [PortfolioPosition] = [],
                                         journalTrades: [TradeRecord] = [],
                                         mode: RankedMode = .fastestCompounding,
                                         max: Int = 3,
                                         fxRatesToUSD: [String: Double] = [:]) -> [TodayActionPlan] {
        let rf = Swift.max(0, riskFraction ?? 0)
        let maxCount = Swift.max(0, max)
        let lane = StockSageExpectedValue.fastLane(ideas, holds: holds, calibration: calibration, earnings: earnings, liquidity: liquidity)
        let holdingsBySymbol = StockSagePortfolio.holdingBySymbol(in: positions)
        let historyBySymbol = StockSageJournal.historyBySymbol(in: journalTrades)
        var out: [TodayActionPlan] = []
        var fastKeys: [Double] = []
        for idea in lane {
            // fastLane() already guarantees a defined stop+target (it requires `ev(for:)` != nil,
            // which itself requires both) — re-guarded here so this composer never force-unwraps
            // an assumption about another engine's internals.
            guard let stop = idea.advice.stopPrice, let target = idea.advice.targetPrice,
                  let v = StockSageExpectedValue.velocity(for: idea, holds: holds, calibration: calibration)
            else { continue }
            let entry = idea.price
            let snap = StockSageDecisionSnapshotBuilder.build(
                idea: idea,
                holds: holds,
                calibration: calibration,
                earnings: earnings,
                liquidity: liquidity,
                account: account,
                riskFraction: riskFraction,
                fxRatesToUSD: fxRatesToUSD
            )
            var shares: Int? = nil
            var dollarsAtRisk: Double? = nil
            if rf > 0, let ps = snap.positionSize {
                shares = ps.shares
                dollarsAtRisk = ps.dollarsAtRisk
            }
            let scaledRiskFraction: Double? = rf > 0
                ? StockSageConvictionScaler.scaledRiskFraction(
                    base: rf,
                    conviction: idea.advice.conviction,
                    regimeBias: marketRegime?.sizingBias ?? 1.0)
                : nil
            // fastLane() ranks by a demotion-adjusted key (velocityRankKey) but does NOT filter
            // out below-floor/low-conviction ideas — they just sink in the ordering. So a row in
            // this top-N list CAN still be one of them; surface the SAME flags the main ideas
            // board already shows (netCostFloorFlag/isLowConviction) so the reason a plan ranked
            // where it did — or a caution about trusting it — is never hidden here.
            let floorFlag = snap.floorFlag
            let lowConviction = snap.rankReasons.contains(.lowConviction)
            let heldShares = holdingsBySymbol[idea.symbol.uppercased()]?.shares
            let closedTradeCount = historyBySymbol[idea.symbol.uppercased()]?.count
            let daysToEarnings = earnings[idea.symbol.uppercased()]?.daysUntil
            let netV = snap.netVelocity
            let sizedKey = StockSageExpectedValue.velocityRankKey(for: idea, holds: holds,
                calibration: calibration, netEVOverride: snap.netEVR) ?? -.infinity
            fastKeys.append(sizedKey
                - StockSageExpectedValue.earningsRankPenalty(for: idea, earnings: earnings)
                - StockSageExpectedValue.liquidityRankPenalty(for: idea, liquidity: liquidity))
            out.append(TodayActionPlan(symbol: idea.symbol, velocity: v, netVelocityRank: netV, entry: entry, stop: stop, target: target,
                                       shares: shares, dollarsAtRisk: dollarsAtRisk, gate: snap.gate,
                                       isCrypto: idea.symbol.uppercased().hasSuffix("-USD"),
                                       netCostFloorFlag: floorFlag, isLowConviction: lowConviction,
                                       heldShares: heldShares, closedTradeCount: closedTradeCount,
                                       priceAsOf: idea.priceAsOf,
                                       action: idea.advice.action, regime: idea.advice.regime,
                                       daysToEarnings: daysToEarnings,
                                       scaledRiskFraction: scaledRiskFraction,
                                       regimeBias: marketRegime?.sizingBias,
                                       costSizeNote: snap.costSizeNote))
        }
        if case .equityExecutableFirst = mode {
            out.sort { a, b in
                let aKey = executablePriorityKey(for: a)
                let bKey = executablePriorityKey(for: b)
                if aKey != bKey { return aKey < bKey }
                return a.symbol < b.symbol
            }
            return Array(out.prefix(maxCount))
        }
        // Truncate only AFTER applying sized costs; otherwise an expensive one-share
        // ticket can occupy the only slot before a cost-clearing candidate is examined.
        return zip(out, fastKeys).enumerated().sorted { a, b in
            a.element.1 == b.element.1 ? a.offset < b.offset : a.element.1 > b.element.1
        }.prefix(maxCount).map { $0.element.0 }
    }

    private nonisolated static func executablePriorityKey(for plan: TodayActionPlan)
    -> (Int, Int, Int, Int, Int, Double) {
        let equityBucket = plan.isCrypto ? 1 : 0
        let gateBucket: Int = {
            switch plan.gate?.decision {
            case .clear: return 0
            case .caution: return 1
            case nil: return 2
            case .blocked: return 3
            }
        }()
        let floorBucket = plan.netCostFloorFlag.isDeranked ? 1 : 0
        let convictionBucket = plan.isLowConviction ? 1 : 0
        let earningsBucket: Int = {
            guard let days = plan.daysToEarnings else { return 0 }
            return days <= 3 ? 1 : 0
        }()
        // Higher velocity still matters once executable filters tie — NET velocity since the
        // owner-signed F6 ruling (2026-07-10; the audit's verified finding was that net was
        // computed and discarded here). Gross fallback when net is unavailable (nil-contract).
        return (equityBucket, gateBucket, floorBucket, convictionBucket, earningsBucket, -(plan.netVelocityRank ?? plan.velocity))
    }

    /// "Copy all N" clipboard text for a ranked list — one line per plan (symbol, velocity,
    /// entry/stop/target, size, gate), with the same honesty caveats `build`'s single-idea
    /// text carries. A blocked gate is called out explicitly so it can't be copied clean.
    /// `mode` (2026-07-09 review fix) keeps the exported header truthful about the ORDER: the
    /// production card sorts `.equityExecutableFirst` (equities before 24/7 crypto, gate-clear
    /// before blocked, THEN growth rate) — exporting that list under a "by velocity" header
    /// misdescribed the ranking. Defaulted so existing callers/tests stay source-compatible.
    nonisolated static func copyAllText(_ plans: [TodayActionPlan], isSample: Bool = false,
                                        mode: RankedMode = .fastestCompounding,
                                        now: Date = Date()) -> String {
        let orderDesc: String = {
            switch mode {
            case .fastestCompounding:    return "by velocity (EV/day)"
            case .equityExecutableFirst: return "executable equities first (equity before 24/7 crypto, gate-clear before blocked), then fastest net EV/day (est. costs deducted; gross when net is unavailable)"
            }
        }()
        var lines = ["Today's ranked actions — top \(plans.count), \(orderDesc). Estimates, not advice; a per-trade risk cap always applies."]
        if isSample {
            lines.insert("⚠ SAMPLE DATA — illustrative prices, NOT live quotes. Re-price before any order.", at: 0)
        }
        for (i, p) in plans.enumerated() {
            let draft = StockSageTradePlan.draftOnlyStatus(symbol: p.symbol,
                priceAsOf: p.priceAsOf, isSample: isSample, now: now)
            if let draft { lines.append("#\(i + 1). " + draft) }
            if let gate = p.gate, gate.decision == .blocked {
                let failures = gate.checks.filter { $0.level == .fail }.map(\.label).joined(separator: "; ")
                lines.append("#\(i + 1). \(p.symbol) — BLOCKED — DO NOT TRADE. FAIL: \(failures). No order plan exported.")
                continue
            }
            if draft != nil { continue }
            var line = "#\(i + 1). \(p.symbol)\(p.isCrypto ? " (24/7 crypto)" : "")"
                + " — \(String(format: "%+.3fR/day gross", p.velocity))"
                + " | entry \(fmt(p.entry)) stop \(fmt(p.stop)) target \(fmt(p.target))"
            if let net = p.netVelocityRank { line += String(format: " | %+.3fR/day net", net) }
            if let note = p.costSizeNote { line += " | " + note }
            if let sh = p.shares, let dr = p.dollarsAtRisk {
                line += " | \(sh) sh (\(StockSageCurrency.approxAmount(dr, symbol: p.symbol)) at risk)"   // wave-2 #1: currency-correct
                // F-review export-parity fix (2026-07-10, wave-7 rule): mirrors row(_:_:)'s visible
                // unfundableSuffix (MarketsTodayActionsCard.swift) — the on-screen row already
                // discloses a floored-to-0 setup; the export must too, or it reads as placeable.
                if sh == 0 { line += " — below the 1-share minimum at your account size" }
            }
            // Wave-7 export parity: the on-screen row shows a conviction/regime-scaled risk
            // line — the export must carry the same size-discipline fact, or a pasted plan
            // silently reverts to the flat base risk% the user did NOT see on screen.
            if let scaled = p.scaledRiskFraction {
                let bias = p.regimeBias.map { String(format: " (regime ×%.2f)", $0) } ?? ""
                // 2026-07-09 review fix: the sh count above is sized at the FLAT base risk% —
                // say so, or the line carries two contradictory size prescriptions and the
                // reader can't tell which one the printed share count obeys.
                line += String(format: " | conviction-scaled risk %.2f%%%@ — scales size, not odds; sh count above uses the base risk%%", scaled * 100, bias)
            }
            // EXPORT-01 precedent: the exported checklist carries the same doubling-hazard
            // context the on-screen row does — acting on this line without knowing you already
            // hold the name silently stacks new risk on an existing position.
            if let held = p.heldShares { line += " | holds \(numShares(held)) sh" }
            // F04-parity: mirror MarketsView.swift's sheet copy-plan wording VERBATIM (~5064-5065)
            // instead of fabricating a verdict from an unsupplied risk % — all export/board/sheet
            // surfaces must agree on the exact same honest phrasing.
            if let gate = p.gate {
                line += " | \(gate.decision.rawValue)" + (gate.decision == .blocked ? " — DO NOT TRADE" : "")
                let failures = gate.checks.filter { $0.level == .fail }.map(\.label)
                if !failures.isEmpty { line += " | FAIL: " + failures.joined(separator: "; ") }
            } else {
                line += " | Pre-trade gate: not evaluated — enter risk % to see the verdict."
            }
            if p.netCostFloorFlag.isDeranked { line += " | ⚠ below net-cost floor" }
            if p.isLowConviction { line += " | ⚠ low conviction" }
            lines.append(line)
        }
        lines.append("Rule: risk small per trade, always a stop, never chase. A blocked gate means don't take it, however good the velocity looks.")
        return lines.joined(separator: "\n")
    }

    /// ALERT-FMT-1: thin alias onto the single shared formatter (`StockSageCurrency.adaptivePrice`,
    /// pure, tested there) — keeps call sites below unchanged in shape.
    private nonisolated static func fmt(_ v: Double) -> String { StockSageCurrency.adaptivePrice(v) }

    /// Share-count formatter matching `MarketsView.numString` — %.0f, not `String(Int(d))`,
    /// because `Int(Double)` TRAPS past `Int.max` and a persisted pathological share count
    /// would crash on export the same way it would crash the board's own render.
    private nonisolated static func numShares(_ d: Double) -> String {
        d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.2f", d)
    }
}

/// One row of `StockSageTodayPlan.rankedActions` — a ranked, sized, gated action for today.
/// `shares`/`dollarsAtRisk` are nil exactly when no account/riskFraction was supplied (mirrors
/// `build`'s own size fallback); `stop`/`target` are always defined because `fastLane()` only
/// ever includes ideas with both (it requires a non-nil `ev(for:)`, which itself requires both).
struct TodayActionPlan: Sendable, Equatable, Identifiable {
    let symbol: String
    let velocity: Double   // EV per day (R), the fastLane ranking number
    /// NET EV/day (est. costs deducted) — the `.equityExecutableFirst` final tiebreak since the
    /// OWNER-SIGNED F6 ruling (2026-07-10, "Ship F6 (net-first crowning)" —
    /// plans/TRIAGE_2026-07-09_fastest_dollar_audit.md UPDATE section): the audit verified net
    /// velocity was computed per row and discarded while the crown used the raw number.
    /// nil (cost/hold inputs unavailable) ⇒ the ordering key falls back to gross `velocity` —
    /// nil-contract: a net figure is never fabricated.
    var netVelocityRank: Double? = nil
    let entry: Double
    let stop: Double
    let target: Double
    let shares: Int?
    let dollarsAtRisk: Double?
    /// nil ⇒ gate not evaluated — no real risk % was supplied (mirrors
    /// StockSageDecisionSnapshot.gate's honest-nil; F04-parity, 2nd-read hunt 2026-07-08). Never a
    /// fabricated CLEAR/CAUTION/BLOCKED verdict conjured from a silent `?? 0.01` default.
    let gate: TradeGateVerdict?
    let isCrypto: Bool     // symbol.hasSuffix("-USD") — the existing crypto predicate, shown upfront
    /// Same de-rank flag the main ideas/velocity boards already show (`StockSageExpectedValue.
    /// netCostFloorFlag`) — `fastLane()` demotes but does NOT exclude below-floor ideas from its
    /// ordering, so a plan in this list can legitimately be one. Defaulted `.clears` so any other
    /// construction site (tests) stays valid without threading it through.
    var netCostFloorFlag: StockSageExpectedValue.NetCostFloorFlag = .clears
    /// Same low-conviction demotion the rank-key math already applies internally
    /// (`StockSageExpectedValue.isLowConviction`) — again demoted, not excluded, from `fastLane()`.
    var isLowConviction: Bool = false
    /// TODAY-PARITY: shares already held of this symbol, aggregated across lots
    /// (`StockSagePortfolio.holdingBySymbol`) — the same held-position awareness the ideas board's
    /// "Held · N sh" chip already shows. DISPLAY-ONLY: never feeds ranking, sizing, or the gate.
    /// nil when `rankedActions` wasn't given `positions` (existing callers/tests unaffected).
    var heldShares: Double? = nil
    /// TODAY-PARITY: closed-trade count for this symbol from the journal
    /// (`StockSageJournal.historyBySymbol`) — same display-only awareness as `heldShares`.
    /// nil when `rankedActions` wasn't given `journalTrades`.
    var closedTradeCount: Int? = nil
    /// The price's own timestamp, rechecked at export time. nil ⇒ draft only.
    var priceAsOf: Date? = nil
    /// Execution-timing input carried from the ranked idea (display-only for recommendations).
    var action: TradeAdvice.Action = .hold
    /// Execution-timing input carried from the ranked idea (display-only for recommendations).
    var regime: TradeAdvice.Regime = .range
    /// Days until the next earnings event for this symbol, when available (display-only).
    var daysToEarnings: Int? = nil
    /// Conviction/regime-scaled per-trade risk fraction (display-only). nil when no base
    /// risk fraction was supplied by the caller.
    var scaledRiskFraction: Double? = nil
    /// Regime sizing bias used in scaled-risk computation (display-only). nil when no
    /// market regime is available.
    var regimeBias: Double? = nil
    var costSizeNote: String? = nil
    nonisolated var id: String { symbol }
}
