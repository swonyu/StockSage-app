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
    /// `priceAsOf` (Round-H, defaulted nil — existing callers/tests byte-unchanged): the price
    /// bar's own date (`idea.priceAsOf`), independent of `isSample` — a live-but-cache-served
    /// scan has `isSample == false` yet can still carry a prior-UTC-day price. Mirrors the
    /// board card's `Self.cardIsStale`/detail sheet's `utcDayKey` staleness check so the ONE
    /// artifact that gets pasted into a broker can't present a stale close as a live quote.
    // F3 wave-A (2026-07-16): `fxRatesToUSD` (ccy→USD) makes the share count FX-correct for
    // non-USD names (.SR was under-sized ~3.75× vs the stated risk%); empty map (the default)
    // keeps every existing caller byte-identical — never guess a rate.
    nonisolated static func build(idea: StockSageIdea, ev: ExpectedValue?,
                                  account: Double?, riskFraction: Double?,
                                  daysToEarnings: Int? = nil, isSample: Bool = false,
                                  positions: [PortfolioPosition] = [],
                                  priceAsOf: Date? = nil,
                                  fxRatesToUSD: [String: Double] = [:],
                                  // A3 (2026-07-16): the card's own pixels show "Analysis over 4h old"
                                  // (cardIsStale's analysis axis); the caller passes that same bool so
                                  // the copied plan carries it too. Defaulted false ⇒ callers/tests
                                  // that don't pass it are byte-unchanged (like isSample/priceAsOf).
                                  analysisStale: Bool = false) -> String {
        let a = idea.advice
        let entry = idea.price
        let rf = Swift.max(0, riskFraction ?? 0)
        // Capture resolvedNetRR BEFORE the ?? gross collapse so rrIsNet can be set accurately:
        // pass true ONLY when netRR actually resolved (non-nil), never for the ?? gross fallback
        // which must stay labeled gross to avoid mislabeling a gross value as "Net reward:risk".
        let resolvedNetRR: Double? = {
            guard let s = a.stopPrice, let t = a.targetPrice else { return nil }
            return StockSageNetEdge.netRR(symbol: idea.symbol, entry: entry, stop: s, target: t)
        }()
        let rr: Double? = {
            guard let s = a.stopPrice, let t = a.targetPrice else { return nil }
            let risk = abs(entry - s)
            guard risk > 0 else { return nil }
            let gross = abs(t - entry) / risk
            // Gate on NET reward:risk (after asset-class round-trip costs) — same source of truth as
            // the on-screen gate, so the copied plan can't disagree. Falls back to gross.
            // (No financing threading here: `idea` reaching `build` always came from
            // `bestOpportunity`, which is buy-family only — financing would always be 0.)
            return resolvedNetRR ?? gross
        }()
        // F04-parity (2nd-read hunt, 2026-07-08): was `rf > 0 ? rf : 0.01` — a blank risk % silently
        // evaluated the gate at a fabricated 1%, printing a "Clear to trade"/etc. verdict the user
        // never asked for. Honest-nil: no gate at all when risk % wasn't supplied.
        let gate: TradeGateVerdict? = {
            guard rf > 0 else { return nil }
            return StockSageTradeGate.evaluate(hasStop: a.stopPrice != nil, rewardToRisk: rr, riskFraction: rf,
                                               daysToEarnings: daysToEarnings, rrIsNet: resolvedNetRR != nil)
        }()

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
            if isSample {
                blocked = "⚠ SAMPLE DATA — illustrative prices, NOT live quotes. Re-price before any order.\n" + blocked
            }
            if let priceAsOf, StockSageScanChunking.utcDayKey(priceAsOf) != StockSageScanChunking.utcDayKey(Date()) {
                blocked = "⚠ PRICE NOT LIVE — as of \(fmtDate(priceAsOf)); re-price before any order.\n" + blocked
            }
            if analysisStale {
                blocked = "⚠ ANALYSIS OVER 4H OLD — re-scan before ordering.\n" + blocked
            }
            return blocked
        }

        var lines = ["Today's plan — estimates, not advice. Size with a stop; risk control > signal."]
        // The copied plan is the one artifact pasted into a broker — it MUST carry the
        // SAMPLE-data warning the on-screen banner shows, so a seed price isn't acted on as real.
        if isSample {
            lines.insert("⚠ SAMPLE DATA — illustrative prices, NOT live quotes. Re-price before any order.", at: 0)
        }
        // Round-H: independent of isSample — a live scan (isSample == false) served off the
        // same-UTC-day cache can still carry a prior-trading-day price bar. Same utcDayKey
        // mismatch the board card/detail sheet already flag; nil priceAsOf ⇒ unknown, never a
        // false warning.
        if let priceAsOf, StockSageScanChunking.utcDayKey(priceAsOf) != StockSageScanChunking.utcDayKey(Date()) {
            lines.insert("⚠ PRICE NOT LIVE — as of \(fmtDate(priceAsOf)); re-price before any order.", at: 0)
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

        if let s = a.stopPrice {
            var size = ""
            if let acct = account, acct > 0, rf > 0,
               let ps = StockSagePositionSizer.size(account: acct, riskFraction: rf, entry: entry, stop: s,
                                                    symbol: idea.symbol, fxRatesToUSD: fxRatesToUSD) {
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
        let laneInputs: [StockSageIdea] = {
            if case .fastestCompounding = mode { return Array(lane.prefix(maxCount)) }
            return lane
        }()
        let holdingsBySymbol = StockSagePortfolio.holdingBySymbol(in: positions)
        let historyBySymbol = StockSageJournal.historyBySymbol(in: journalTrades)
        var out: [TodayActionPlan] = []
        for idea in laneInputs {
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
            let netV = StockSageExpectedValue.netVelocity(for: idea, holds: holds, calibration: calibration)
            out.append(TodayActionPlan(symbol: idea.symbol, velocity: v, netVelocityRank: netV, entry: entry, stop: stop, target: target,
                                       shares: shares, dollarsAtRisk: dollarsAtRisk, gate: snap.gate,
                                       isCrypto: idea.symbol.uppercased().hasSuffix("-USD"),
                                       netCostFloorFlag: floorFlag, isLowConviction: lowConviction,
                                       heldShares: heldShares, closedTradeCount: closedTradeCount,
                                       priceAsOf: idea.priceAsOf,
                                       action: idea.advice.action, regime: idea.advice.regime,
                                       daysToEarnings: daysToEarnings,
                                       scaledRiskFraction: scaledRiskFraction,
                                       regimeBias: marketRegime?.sizingBias))
        }
        if case .equityExecutableFirst = mode {
            out.sort { a, b in
                let aKey = executablePriorityKey(for: a)
                let bKey = executablePriorityKey(for: b)
                if aKey != bKey { return aKey < bKey }
                return a.symbol < b.symbol
            }
            if out.count > maxCount { return Array(out.prefix(maxCount)) }
        }
        return out
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
                                        mode: RankedMode = .fastestCompounding) -> String {
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
            var line = "#\(i + 1). \(p.symbol)\(p.isCrypto ? " (24/7 crypto)" : "")"
                + " — \(String(format: "%+.3fR/day gross", p.velocity))"
                + " | entry \(fmt(p.entry)) stop \(fmt(p.stop)) target \(fmt(p.target))"
            if let sh = p.shares, let dr = p.dollarsAtRisk {
                line += " | \(sh) sh (\(StockSageCurrency.approxAmount(dr, symbol: p.symbol)) at risk)"   // wave-2 #1: currency-correct
                // F-review export-parity fix (2026-07-10, wave-7 rule): mirrors row(_:_:)'s visible
                // unfundableSuffix (MarketsTodayActionsCard.swift) — the on-screen row already
                // discloses a floored-to-0 setup; the export must too, or it reads as placeable.
                if sh == 0 { line += " — below the 1-share minimum at your account size" }
            }
            // Round-H: same cache-stale price flag as build() — independent of isSample.
            if let priceAsOf = p.priceAsOf,
               StockSageScanChunking.utcDayKey(priceAsOf) != StockSageScanChunking.utcDayKey(Date()) {
                line += " | ⚠ PRICE NOT LIVE — as of \(fmtDate(priceAsOf))"
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

    /// Round-H: same relative-date wording the detail sheet's "not live" cue uses
    /// (MarketsView.swift ~5408), so the copied plan and the on-screen sheet agree.
    private nonisolated static func fmtDate(_ d: Date) -> String { d.formatted(.relative(presentation: .named)) }

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
    /// Round-H: the price bar's own date (`idea.priceAsOf`) carried through so `copyAllText`
    /// can flag a cache-stale price independent of `isSample` — same rationale as `build`'s
    /// `priceAsOf` param. nil ⇒ unknown, never a false warning.
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
    nonisolated var id: String { symbol }
}
