import SwiftUI
import AppKit   // NSPasteboard for "Copy all N"

/// FASTMONEY_BACKLOG #4 — "Today's ranked action list": the top-N fast-lane setups (by
/// velocity, i.e. EV/day) collapsed to one row each — symbol, velocity, the concrete order
/// (entry/stop/target), the SIZE (shares + $ at risk, when an account/risk% are set), and the
/// pre-trade GATE verdict — so the owner doesn't have to open N detail sheets to decide "do I
/// take #1 or #2 today?" Pure display over `StockSageTodayPlan.rankedActions(...)`, which
/// composes only already-tested engines (`StockSageExpectedValue.fastLane`/`velocity`,
/// `StockSagePositionSizer.size`, `StockSageTradeGate.evaluate`) — no new signal, no new
/// ranking math. A blocked gate strikes the row through and badges "DO NOT TRADE" so a bad
/// setup can't be taken — or copied — clean.
struct MarketsTodayActionsCard: View {
    let plans: [TodayActionPlan]
    /// True when the on-screen prices are the seed/sample set, not live quotes — carried into
    /// the copied plan (same honesty rule as `StockSageTodayPlan.build`'s `isSample`).
    let isSampleData: Bool
    /// Called with the tapped row's symbol; the caller resolves it to a `StockSageIdea` (e.g.
    /// `store.ideas.first { $0.symbol == symbol }`) and opens its detail sheet.
    let onSelectSymbol: (String) -> Void
    /// F8 (2026-07-09): the global "Do this now" CTA's own pick (bestOpportunity: highest gross
    /// EV), passed in ONLY so this card can disclose it when it names a DIFFERENT symbol than
    /// this list's own #1 row (rankedActions: fastest EV/day, equities-first) — two different
    /// lenses that can legitimately disagree with no cross-reference before this. Copy-only:
    /// nil (default) renders nothing, matching every other call site unaware of this parameter.
    var globalBestSymbol: String? = nil
    /// FASTMONEY (owner, 2026-07-17): one-tap journal prefill for a row — the caller resolves
    /// the symbol to its idea and runs the SAME prefill path as the detail sheet's "Log trade"
    /// (side-correct stop/target, conviction recorded, jumps to the Portfolio journal form).
    /// Logged real fills are the dataset that feeds calibration and execution-cost measurement.
    /// nil (default) renders no quick-log affordance, keeping other call sites unchanged.
    var onLogFill: ((String) -> Void)? = nil
    @ObservedObject private var paperStore = StockSagePaperTradeStore.shared
    @State private var executableOnly = false

    @ScaledMetric(relativeTo: .caption2) private var font8: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var font9: CGFloat = 9

    /// ALERT-FMT-1: thin alias onto the single shared formatter (`StockSageCurrency.adaptivePrice`,
    /// pure, tested there) — keeps call sites below unchanged in shape.
    private func adaptivePrice(_ v: Double) -> String { StockSageCurrency.adaptivePrice(v) }

    /// Share-count formatter matching `MarketsView.numString` / `StockSageTodayPlan.numShares` —
    /// %.0f, not `String(Int(d))` (`Int(Double)` traps past `Int.max`).
    private func numShares(_ d: Double) -> String {
        d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.2f", d)
    }

    var body: some View {
        // Matches fastLaneStrip's own "≥2 to be worth a board" threshold — a single ranked
        // action isn't a ranked LIST, and bestOpportunityCard already covers the lone-idea case.
        if plans.count >= 2 {
            let shownPlans = executableOnly ? plans.filter(isExecutableNow(_:)) : plans
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "list.number").font(.system(size: 11)).foregroundStyle(DS.Palette.accent)
                    Text("Today's plan — executable equities first").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    Spacer()
                    Toggle("Executable now only", isOn: $executableOnly)
                        .toggleStyle(.switch)
                        .font(.system(size: font8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text("Top \(shownPlans.count) setups, sized and gated — equities before 24/7 crypto, gate-clear before blocked, then fastest; do #1 first, unless it's blocked.")
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Within those buckets, faster NET EV/day (est. costs deducted; gross when net is unavailable) ranks first — unlike the Fast lane above, which ranks by growth rate (log-growth at ½-Kelly), so the two cards can order the same names differently.")
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                // F8 (2026-07-09; referent fixed D1 2026-07-16): cross-reference the OTHER direction
                // — this list's own #1 vs the highest-gross-EV crown pick (a different lens). This
                // card renders on the Ideas tab, where that crown is the "Best opportunity" card
                // above (the "Do this now" CTA is hidden on Ideas), so name THAT card, not the CTA.
                // Copy-only; renders nothing when either is nil or they agree.
                if let globalBestSymbol, let first = shownPlans.first?.symbol, globalBestSymbol != first {
                    Text("The Best opportunity card leads with \(globalBestSymbol) instead — different lens (highest gross EV, not fastest net EV/day).")
                        .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if executableOnly {
                    Text("Executable now includes only rows that currently clear or caution on the pre-trade gate and are fundable (≥1 share) at your account size.")
                        .font(.system(size: 8)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                if shownPlans.isEmpty {
                    // F04-parity (C1 wave): with no risk % every gate is honestly nil — "lower
                    // risk %" would misdiagnose unevaluated rows as risk-blocked.
                    Text(plans.allSatisfy { $0.gate == nil }
                         ? "Enter a risk % to evaluate the pre-trade gate — no rows can be classified executable yet."
                         : "No executable rows at current risk settings. Lower risk %, or keep blocked rows visible.")
                        .font(.system(size: font9, weight: .medium)).foregroundStyle(DS.Palette.warningSoft)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(shownPlans.enumerated()), id: \.element.id) { i, plan in
                        row(i + 1, plan)
                    }
                }

                // C7c (2026-07-09): panels sit BELOW the rows — the ranked setups are the card's
                // load-bearing content; the execution/paper commentary describes them and was
                // pushing #1 below the fold as the panels grew.
                executionRecommendationPanel(shownPlans)
                paperOutcomePanel

                HStack(spacing: 6) {
                    Spacer()
                    Button {
                        let text = StockSageTodayPlan.copyAllText(shownPlans, isSample: isSampleData, mode: .equityExecutableFirst)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Label("Copy all \(shownPlans.count)", systemImage: "doc.on.doc").font(.system(size: font9, weight: .medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(DS.Palette.accent).disabled(shownPlans.isEmpty)
                    .help("Copy the ranked plan — entry/stop/target, size, and each gate verdict — to the clipboard. Estimates, not advice.")
                }
                if let weekly = weeklyExecutedVsBlockedMetric {
                    Text(weekly)
                        .font(.system(size: font8))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("A discipline checklist, not a profit signal — clearing the gate means the trade isn't obviously reckless, not that it wins.")
                    .font(.system(size: font9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.sm).frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.accent.opacity(0.25), lineWidth: 1))
        }
    }

    @ViewBuilder
    private func executionRecommendationPanel(_ shownPlans: [TodayActionPlan]) -> some View {
        // 2026-07-09 review fix: pick the first NON-BLOCKED row but caption it with its REAL
        // rank — the old panel hard-coded "#1", so when row #1 was blocked the advice for the
        // row displayed as #2/#3 was attached to the wrong (blocked) row number.
        let pickIndex: Int? = shownPlans.firstIndex(where: { $0.gate?.decision != .blocked })
            ?? (shownPlans.isEmpty ? nil : 0)
        if let idx = pickIndex {
            let plan = shownPlans[idx]
            let rank = idx + 1
            let urgentEvent = (plan.daysToEarnings ?? Int.max) <= 3
            // C1 wave (2026-07-09): the order-type + timing guidance is US-EQUITY retail research
            // (near-close entry, overnight premia) — a 24/7 crypto pick has no close and no
            // session, so it gets neither the equity order text nor the session timing note.
            let timing = plan.isCrypto ? nil : StockSageExecutionTiming.sessionNote(action: plan.action, regime: plan.regime, symbol: plan.symbol)   // wave-2 #6: US-gated microstructure
            let blocked = plan.gate?.decision == .blocked
            let color: Color = blocked ? DS.Palette.dangerSoft : (urgentEvent ? DS.Palette.warningSoft : DS.Palette.successSoft)
            // F04-consistency (nilrisk-fixture QA, 2026-07-09): an UNEVALUATED gate (no risk %
            // set) must be named, not advised over — the panel was recommending execution
            // mechanics "for #1" on a trade whose gate never ran.
            let gateUnevaluated = plan.gate == nil
            let headline: String = {
                if blocked { return "Execution recommendation: blocked setup for #\(rank)." }
                if gateUnevaluated { return "Execution notes for #\(rank) — gate not evaluated yet." }
                if urgentEvent { return "Execution recommendation: event-near setup, urgency-aware." }
                return "Execution recommendation for #\(rank) — order type is a trade-off."
            }()
            // 2026-07-09 review fix: the old non-urgent default prescribed "patient limit …
            // for uninformed execution" — but the indexed order-type research (research/INDEX
            // 2026-07-03) says the ~10bps limit-order saving holds for PATIENT/UNINFORMED
            // entries and SIGN-FLIPS to marketable when the trade is informed/urgent, which is
            // the leg that applies to conviction-directional ideas. Present the trade-off
            // honestly instead of prescribing the leg the research says flips here.
            let orderText: String = {
                if blocked { return "Do not place this order until the gate clears." }
                if gateUnevaluated {
                    return "Enter a risk % to run the pre-trade gate BEFORE placing any order — the order-type and timing notes below apply only to a setup the gate has cleared."
                }
                if urgentEvent {
                    return "If you still take it, a marketable near-close execution can be justified by event urgency; otherwise skip the trade."
                }
                if plan.isCrypto {
                    return "24/7 crypto — the equity near-close guidance does not apply; use a limit order and size for round-the-clock volatility. Estimates, not advice."
                }
                return "Order TYPE: a patient limit is ~10 bps cheaper than marketable when you are NOT chasing the move; acting urgently on a fresh conviction signal favors a marketable order (avoids chase/adverse-selection cost). See the timing note for WHEN in the session to enter. Estimates, not advice."
            }()
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
                Text("#\(rank) \(plan.symbol): \(orderText)")
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let timing {
                    Text("Timing note: \(timing)")
                        .font(.system(size: 8)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(color.opacity(0.35), lineWidth: 1))
        }
    }

    private func isExecutableNow(_ plan: TodayActionPlan) -> Bool {
        guard let decision = plan.gate?.decision else { return false }
        // C1 wave: a row the sizer resolves to 0 shares ("0 sh (≈$0 at risk)") is unfundable
        // at the current account/risk — gate-clear or not, it cannot be executed now.
        // shares == nil (no account entered) stays eligible; only a computed 0 excludes.
        if let sh = plan.shares, sh == 0 { return false }
        return decision != .blocked
    }

    @ViewBuilder
    private var paperOutcomePanel: some View {
        let (planned, realized, measured) = paperTodayStats

        if measured > 0 {
            let delta = realized - planned
            let color: Color = delta >= 0 ? DS.Palette.successSoft : DS.Palette.warningSoft
            VStack(alignment: .leading, spacing: 2) {
                Text("Paper today: realized (net) vs planned (gross target)")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
                Text(String(format: "%d close%@ today: planned %+.2fR gross vs realized %+.2fR net (Δ %+.2fR vs the full-target plan — mostly exit shortfall on stops/early exits, plus costs)",
                            measured, measured == 1 ? "" : "s", planned, realized, delta))
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let fwd = paperStore.forwardStats {
                    Text(String(format: "Forward paper deflated Sharpe (DSR) %.0f%% (%d closed) — %@",
                                fwd.deflated.dsr * 100, fwd.closed,
                                fwd.passesForwardBar ? "passes bar" : "below bar"))
                        .font(.system(size: 8)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .help(StockSageDeflatedSharpe.caveat)
                    // Audit 2026-07-12 #2: forwardStats is CLOSED-ONLY, which is selection-biased —
                    // stops resolve before targets, so early closes over-represent losers (the exact
                    // bias the Portfolio scoreboard fixes). Disclose the resolved fraction + the
                    // over-states-the-loss caveat so this DSR isn't read as an honest forward verdict.
                    let openCount = paperStore.trades.count - fwd.closed
                    if openCount > 0 {
                        Text(String(format: "…on the %d closed of %d — stops resolve before targets, so this closed-only read OVER-STATES the loss (%d still open, unmarked here). See the Portfolio → Forward scoreboard for the full-book bound.",
                                    fwd.closed, paperStore.trades.count, openCount))
                            .font(.system(size: 8)).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(color.opacity(0.35), lineWidth: 1))
        }
    }

    private var paperTodayStats: (planned: Double, realized: Double, measured: Int) {
        let nowDay = Int(Date().timeIntervalSince1970 / 86_400)
        let closedToday = paperStore.trades.filter {
            guard !$0.isOpen, let closedAt = $0.closedAt else { return false }
            return Int(closedAt.timeIntervalSince1970 / 86_400) == nowDay
        }
        var planned = 0.0
        var realized = 0.0
        var measured = 0
        for t in closedToday {
            guard let rr = t.realizedR else { continue }
            let risk = abs(t.entry - t.stop)
            guard risk > 0, let target = t.target else { continue }
            let plannedR: Double = t.side == .long ? (target - t.entry) / risk : (t.entry - target) / risk
            planned += plannedR
            realized += rr
            measured += 1
        }
        return (planned, realized, measured)
    }

    private var weeklyExecutedVsBlockedMetric: String? {
        let recent = paperStore.trades.filter {
            guard let closedAt = $0.closedAt else { return false }
            return closedAt >= Date().addingTimeInterval(-7 * 86_400)
        }
        let executed = recent.compactMap(\.realizedR)
        let executedCount = executed.count
        let executedTotal = executed.reduce(0, +)
        let blocked = plans.filter { $0.gate?.decision == .blocked }
        guard executedCount > 0 || !blocked.isEmpty else { return nil }
        let blockedPotential = blocked.reduce(0.0) { $0 + $1.velocity * 5.0 }
        // 2026-07-09 review fix: the old "▲ improving / ▼ deteriorating (Δ)" verdict subtracted
        // unit-incompatible quantities — average NET realized R PER TRADE minus a SUM of GROSS
        // velocity R PER WEEK over currently-blocked rows — so one decent blocked row flipped the
        // label to "deteriorating" on a week that realized +1.5R. The two facts stay (correctly
        // labeled gross/net); the fabricated comparison goes.
        // C1 wave: say PAPER (these are paper trades — the store's own contract) and never
        // assert idle blocked rows when none exist (the clause invented a population).
        let base = String(format: "7d paper execution: %d closed, realized %+.2fR net.", executedCount, executedTotal)
        guard !blocked.isEmpty else { return executedCount > 0 ? base : nil }
        return base + String(format: " Currently blocked rows idle ≈%+.2fR/week gross velocity (proxy — not comparable to realized net).",
                             blockedPotential)
    }

    /// FASTMONEY (owner, 2026-07-17): pair the open-sheet row with a sibling "Log" quick action.
    /// Sibling, not nested — a Button inside another Button's label doesn't reliably receive
    /// clicks on macOS, so the row is an HStack of two independent buttons.
    @ViewBuilder
    private func row(_ rank: Int, _ plan: TodayActionPlan) -> some View {
        if let onLogFill {
            HStack(spacing: 6) {
                rowOpenButton(rank, plan)
                logFillButton(plan, onLogFill: onLogFill)
            }
        } else {
            rowOpenButton(rank, plan)
        }
    }

    private func logFillButton(_ plan: TodayActionPlan, onLogFill: @escaping (String) -> Void) -> some View {
        Button { onLogFill(plan.symbol) } label: {
            VStack(spacing: 2) {
                Image(systemName: "square.and.pencil").font(.system(size: 12))
                Text("Log").font(.system(size: font8, weight: .semibold))
            }
            .foregroundStyle(DS.Palette.accent)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(DS.Bezel.cardFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Prefill the journal's add-trade form (Portfolio section) with this plan, including the planned entry — enter the fill you actually get and it feeds your calibration and execution-cost (slippage) measurement. Recording a decision, not endorsing it.")
        .accessibilityLabel("Log trade for \(plan.symbol) — prefills the journal form in the Portfolio section")
    }

    @ViewBuilder
    private func rowOpenButton(_ rank: Int, _ plan: TodayActionPlan) -> some View {
        let blocked = plan.gate?.decision == .blocked
        // D1 (rotation-3 triage): same utcDayKey staleness check `copyAllText` already gates
        // its "⚠ PRICE NOT LIVE" line on — nil priceAsOf ⇒ unknown, renders nothing.
        let staleAsOf = MarketsView.staleAsOfPrice(plan.priceAsOf, now: Date())
        Button { onSelectSymbol(plan.symbol) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DS.Space.sm) {
                    Text("#\(rank)").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .leading)
                    Text(plan.symbol).font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .strikethrough(blocked, color: DS.Palette.dangerSoft)
                    if plan.isCrypto {
                        Text("24/7").font(.system(size: font8)).foregroundStyle(DS.Palette.warningSoft)
                    }
                    Text(String(format: "%+.3fR/day gross", plan.velocity)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.Palette.successSoft)
                    // Same de-rank flags the main ideas/velocity boards already show — fastLane()
                    // demotes but does not EXCLUDE below-floor/low-conviction ideas, so a row here
                    // can legitimately be one; never hide the reason it ranked where it did.
                    if plan.netCostFloorFlag.isDeranked {
                        Text("below net-cost floor").font(.system(size: font8)).foregroundStyle(DS.Palette.warningSoft)
                    }
                    if plan.isLowConviction {
                        Text("low conviction").font(.system(size: font8)).foregroundStyle(DS.Palette.warningSoft)
                    }
                    Spacer(minLength: 0)
                    gateBadge(plan.gate)
                }
                HStack(spacing: DS.Space.sm) {
                    // .fixedSize so a money figure wraps instead of silently truncating under
                    // Dynamic Type / narrow width — a dropped Target price or $-at-risk on a
                    // money row is an honesty failure (audit L2-02, 2026-07-07).
                    Text("Entry \(adaptivePrice(plan.entry)) · Stop \(adaptivePrice(plan.stop)) · Target \(adaptivePrice(plan.target))")
                        .font(.system(size: font9)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let sh = plan.shares, let dr = plan.dollarsAtRisk {
                        // TODAY-PARITY: "· holds N sh" appended when a position is already held —
                        // acting on this row without that context silently stacks new risk on an
                        // existing position (the ideas board's Held chip exists for exactly this).
                        // One short suffix max (compact-row discipline) — closedTradeCount is
                        // lower-value here and carried only in the a11y label below.
                        let heldSuffix = plan.heldShares.map { " · holds \(numShares($0)) sh" } ?? ""
                        // F1/F3 (2026-07-09): a row that floors to 0 shares can still hold a #1
                        // slot here — say so, matching StockSagePositionSizer.summaryLine's same
                        // disclosure on the idea card / CTA / sheet. No demotion, display-only.
                        let unfundableSuffix = sh == 0 ? " — below 1-share minimum at your account size" : ""
                        // Audit 2026-07-12 (wave-2 #1): dollarsAtRisk is in the symbol's OWN currency
                        // (SAR for 2222.SR, pence for .L), so a hardcoded "$" mislabeled it ~3.75×/100×.
                        // approxAmount renders the true currency (+ the pence ÷100) — same fix as the
                        // idea-card "At risk" / Size-it-now line.
                        Text("· \(sh) sh (\(StockSageCurrency.approxAmount(dr, symbol: plan.symbol)) at risk)\(heldSuffix)\(unfundableSuffix)")
                            .font(.system(size: font9)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("· set account to size").font(.system(size: font9)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                // D1 (rotation-3 triage): the Entry/Stop/Target + size above are a placeable
                // order — flag a stale (prior-UTC-day) price the same way the detail sheet's
                // DEG-03 cue and this same file's `copyAllText` export already do. Spoken form
                // folded into the a11y label below (accessibilityHidden here, same pattern as
                // MarketsView's own staleAsOf line).
                if let staleAsOf {
                    Text("⚠︎ Price as of \(staleAsOf.formatted(.relative(presentation: .named))) — not live; re-price before ordering.")
                        .font(.system(size: font8)).foregroundStyle(DS.Palette.warningSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
                if blocked, let gate = plan.gate {
                    Text("DO NOT TRADE — \(gate.checks.first(where: { $0.level == .fail })?.label ?? "gate failed")")
                        .font(.system(size: font8, weight: .semibold)).foregroundStyle(DS.Palette.dangerSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Caution: show the first warn reason as a visible secondary line for sighted users
                // (the a11y label already carries this, but sighted users had no way to see the reason
                // without a tooltip). lineLimit(1) keeps the row tight; '+N more' if several warns.
                if let gate = plan.gate, gate.decision == .caution {
                    let warns = gate.checks.filter { $0.level == .warn }
                    if let first = warns.first {
                        let more = warns.count > 1 ? " +\(warns.count - 1) more" : ""
                        Text("⚠ \(first.label)\(more)")
                            .font(.system(size: font8)).foregroundStyle(DS.Palette.warningSoft)
                            .lineLimit(1)
                    }
                }
                if let scaled = plan.scaledRiskFraction {
                    let scaledPct = scaled * 100
                    let biasText = plan.regimeBias.map { String(format: " (regime ×%.2f)", $0) } ?? ""
                    Text(String(format: "Conviction-scaled risk: %.2f%%%@ — scales size, not odds; the share count above uses the base risk %%.", scaledPct, biasText))
                        .font(.system(size: font8)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help({
                            var text = StockSageConvictionScaler.caveat
                            text += String(format: " Scaled risk shown: %.2f%%.", scaledPct)
                            // C7b: three per-name risk numbers can now coexist on one screen —
                            // say how they relate instead of leaving the reader to reconcile.
                            text += " How this relates: the share count on this row uses your flat base risk %; this line is the conviction/regime scaling of that base for THIS single trade; the Deploy-capital card's Risk column is the PORTFOLIO-level allocation (half-Kelly + heat cap) — act on that when deploying the whole book; this line sizes THIS single trade."
                            return text
                        }())
                }
            }
            .padding(.horizontal, DS.Space.sm).padding(.vertical, 6)
            .background(DS.Bezel.cardFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(LuxPressStyle())
        .accessibilityLabel({
            // TODAY-A11Y-02: mirror the visible "%+.3fR/day gross" label (~89) — the spoken
            // label dropped "gross", which is the honesty-floor's required net/gross qualifier.
            var label = "Number \(rank): \(plan.symbol), \(String(format: "%+.3f", plan.velocity)) R per day gross"
            if plan.isCrypto { label += ", 24/7 crypto" }
            if plan.netCostFloorFlag.isDeranked { label += ", below net-cost floor" }
            if plan.isLowConviction { label += ", low conviction" }
            // The actionable order + size — VoiceOver otherwise hears the verdict but never
            // the entry/stop/target/size the row exists to convey (audit L2-01, 2026-07-07).
            label += ". Entry \(adaptivePrice(plan.entry)), stop \(adaptivePrice(plan.stop)), target \(adaptivePrice(plan.target))"
            if let sh = plan.shares, let dr = plan.dollarsAtRisk {
                label += ", \(sh) shares, about \(StockSageCurrency.approxAmount(dr, symbol: plan.symbol)) at risk"   // wave-2 #1: currency-correct
                // F1/F3 a11y parity with the visible row's unfundableSuffix above.
                if sh == 0 { label += ", below the 1-share minimum at this account size" }
            }
            // TODAY-PARITY a11y: the compact visible row only ever shows "holds N sh" (one
            // suffix max); VoiceOver carries the full held/journal context, matching the ideas
            // board's own a11y phrasing (MarketsView ideaCard label builder).
            if let held = plan.heldShares { label += ", you hold \(numShares(held)) shares" }
            if let closed = plan.closedTradeCount { label += ", \(closed) closed trades in your journal" }
            // D1 (rotation-3 triage): spoken counterpart of the visible staleAsOf line above.
            // F-review fix (2026-07-10, S5): no trailing period — every successor clause below
            // prepends its own ". " separator (mirrors the crown-divergence hasSuffix(".") fix
            // at MarketsView.swift ~4772); a trailing period here doubled up into "..".
            if let staleAsOf {
                label += ". Price as of \(staleAsOf.formatted(.relative(presentation: .named))) — not live; re-price before ordering"
            }
            // F04-parity: nil gate ⇒ risk % wasn't supplied — mirror the sheet chip's a11y wording
            // ("Pre-trade gate: risk percent not set", MarketsView.swift ~5993) instead of forcing
            // a verdict sentence with no verdict to report.
            if let gate = plan.gate {
                label += ". \(gate.decision.rawValue)."
                // TODAY-A11Y-01: mirror the visible "DO NOT TRADE — {reason}" line (~120) — the
                // bare "Do not trade." spoke no reason while caution rows below DO speak theirs.
                if blocked {
                    let failLabel = gate.checks.first(where: { $0.level == .fail })?.label ?? "gate failed"
                    label += " Do not trade — \(failLabel)."
                }
                if gate.decision == .caution,
                   let warn = gate.checks.first(where: { $0.level == .warn }) {
                    // C1 wave: the visible line appends "+N more" when several warns fired —
                    // VoiceOver must not report exactly one caution when the gate raised several.
                    let warnCount = gate.checks.filter { $0.level == .warn }.count
                    let extra = warnCount > 1 ? ", plus \(warnCount - 1) more" : ""
                    label += " Caution: \(warn.label)\(extra)."
                }
            } else {
                label += ". Pre-trade gate: risk percent not set."
            }
            // Wave-7 a11y parity (TODAY-A11Y-02 precedent): the visible conviction-scaled risk
            // line must be spoken too — VoiceOver users otherwise size from the flat base
            // risk% alone and never hear the caveat the sighted row carries.
            if let scaled = plan.scaledRiskFraction {
                let biasStr = plan.regimeBias.map { String(format: ", regime times %.2f", $0) } ?? ""
                label += " Conviction-scaled risk \(String(format: "%.2f", scaled * 100)) percent\(biasStr) — scales size, not odds; the share count uses the base risk percent."
            }
            label += " Tap for the plan."
            return label
        }())
    }

    @ViewBuilder
    private func gateBadge(_ gate: TradeGateVerdict?) -> some View {
        // F04-parity: nil ⇒ gate not evaluated (no real risk % supplied) — the neutral "set risk %"
        // badge mirrors the sheet's pinned-bar chip (MarketsView.swift ~5986-5993) instead of
        // fabricating a CLEAR/CAUTION/BLOCKED verdict from a silently-defaulted risk fraction.
        if let gate {
            let color: Color = gate.decision == .clear ? DS.Palette.successSoft
                : (gate.decision == .caution ? DS.Palette.warningSoft : DS.Palette.dangerSoft)
            let label = gate.decision == .clear ? "CLEAR" : (gate.decision == .caution ? "CAUTION" : "BLOCKED")
            // Build a .help string from the warn/fail check labels so sighted users can hover-reveal
            // the gate reason without opening the detail sheet.
            let reasonLabels = gate.checks.filter { $0.level == .warn || $0.level == .fail }.map(\.label)
            let helpText: String = {
                if reasonLabels.isEmpty { return "\(label) gate verdict." }
                return "\(label): \(reasonLabels.joined(separator: " · "))"
            }()
            Text(label)
                .font(.system(size: font8, weight: .bold)).foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
                .help(helpText)
        } else {
            Text("SET RISK %")
                .font(.system(size: font8, weight: .bold)).foregroundStyle(DS.Palette.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(DS.Palette.textSecondary.opacity(0.15), in: Capsule())
                .help("Enter risk % to see the pre-trade gate verdict.")
        }
    }
}
