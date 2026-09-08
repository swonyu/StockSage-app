import SwiftUI

struct StockSagePaperAutomationPanel: View {
    @ObservedObject private var automation = StockSagePaperAutomation.shared

    var body: some View {
        GroupBox("Qwen research and paper trading") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(automation.isRunning ? "Running · simulation only" : "Paused · simulation only",
                          systemImage: automation.isRunning ? "play.circle.fill" : "pause.circle")
                    Spacer()
                    if automation.isRunning {
                        Button("Pause automation") { automation.stop() }
                    } else {
                        Button("Start paper automation") { automation.start() }
                    }
                }
                Text(automation.status).font(.callout)
                Text("Paper sessions: pre-market, regular and after-hours · 04:00–20:00 New York time")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Same-day only · entries stop and closing requests begin at 19:55 New York")
                    .font(.caption).foregroundStyle(.secondary)
                if automation.book.open.contains(where: { StockSagePaperAutomation.dayExitDue(openedAt: $0.openedAt, now: Date()) }) {
                    Text("Close-out required: awaiting fresh later prices. No overnight or closing fill is assumed.")
                        .font(.callout).foregroundStyle(DS.Palette.warningSoft)
                }
                HStack(spacing: 20) {
                    VStack(alignment: .leading) {
                        Text("Paper cash").font(.caption)
                        Text(automation.book.cash, format: .currency(code: "USD")).monospacedDigit()
                    }
                    VStack(alignment: .leading) {
                        Text("Estimated liquidation value").font(.caption)
                        if let equity = automation.book.equity(quotes: automation.quotes, at: Date()) {
                            Text(equity, format: .currency(code: "USD")).monospacedDigit()
                            Text("Change from $10,000: \((equity - 10_000).formatted(.currency(code: "USD")))").font(.caption)
                        } else { Text("Fresh marks unavailable").font(.caption) }
                    }
                }
                Text("\(automation.book.open.count) paper positions · \(automation.book.pending.count) pending · \(automation.book.trades.filter { !$0.isOpen }.count) closed")
                    .font(.caption)
                if let scan = automation.book.decisions.last(where: { $0.action.hasPrefix("Market scan") }) {
                    Text("Market coverage · \(scan.at.formatted(date: .omitted, time: .shortened))").font(.caption.bold())
                    Text(scan.reason).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Full US market discovery begins on the next research cycle; your watchlist is not the scan limit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let decision = automation.book.decisions.last(where: { !$0.symbol.isEmpty }) {
                    Text("Latest decision: \(decision.symbol) · \(decision.action)").font(.callout.bold())
                    Text(decision.reason).font(.caption).foregroundStyle(.secondary)
                }
                if let cycle = automation.book.decisions.last(where: { $0.action == "Research complete" }) {
                    Text("Last cycle · \(cycle.at.formatted(date: .omitted, time: .shortened)) · \(cycle.reason)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if automation.isRunning, !automation.isResearching, StockSagePaperAutomation.entryWindowOpen(Date()), let last = automation.book.lastResearch {
                    Text("Next research due \(last.addingTimeInterval(StockSagePaperAutomation.interval).formatted(date: .omitted, time: .shortened)) · while awake, connected and in session")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = automation.error { Text(error).foregroundStyle(DS.Palette.warningSoft).font(.callout) }
                DisclosureGroup("Simulation policy and limitations") {
                    Text("Same-day horizon only. Qwen receives completed minute bars from the latest hour, or explicitly labelled recent qualified trades when candles are unavailable. Individual trades are not candles or evidence of sufficient liquidity. Daily indicators are background, not intraday signals. New entries stop at 19:55 New York and the timer requests exits independently of Qwen. If the app sleeps or fresh prices are missing, unresolved positions remain visible; overdue holdings block new buys and exits retry next open session. A same-day policy cannot guarantee a fill.")
                    Text("Separate $10,000 account. Full Massive US listed-market snapshots, excluding OTC. All supported fresh observations are screened, not individually analyzed by Qwen. Qwen reviews all paper holdings first, then up to \(StockSagePaperAutomation.discoveryLimit) affordable new candidates, least recently attempted first and daily dollar activity next. Research uses up to \(StockSagePaperAutomation.researchConcurrency) concurrent workers. Cycles start at least fifteen minutes apart and never overlap, so a longer cycle delays the next one. Missing/stale data and unsupported symbol formats are excluded. The feed can include ETFs; this is not a common-stock-only reference census. Your watchlist is unchanged.")
                    Text("Whole shares, long only, no margin, five positions maximum, and $2,000 maximum per new position. Buy/Strong Buy must cite an actual intraday observation to request an entry; daily background alone is insufficient. Sell/Reduce requests closing the entire simulated holding. Hold/Avoid creates no order. A completed scan is not a promise of a trade or profit.")
                    Text("Simulated fills require a Massive SIP observation after the decision, received within two minutes. When snapshots are stale or missing, a bounded tick-tape fallback checks trade conditions and actual participant time; average-price, prior-reference, corrected and unknown-condition trades are excluded. Costs assume 10 basis points per side; they do not measure spread, depth or extended-hours liquidity. A 2% stop and 4% target are simulation rules, not price forecasts. Exits use a subsequent observed price; gaps and missed crossings can worsen outcomes.")
                    Text("Runs while this Mac is awake and StockSage is open. Weekday session hours do not include a holiday calendar; stale or missing data blocks fills. Sleep, disconnects and missed research are never backfilled. Dividends, actual liquidity, broker minimum fees and corporate actions are not modeled; large price/basis changes pause the account for review. No real orders or real-journal records are created.")
                }.font(.caption).foregroundStyle(.secondary)
                if !automation.book.open.isEmpty {
                    DisclosureGroup("Paper positions") {
                        ForEach(automation.book.open) { trade in
                            Text("\(trade.symbol) · \(Int(trade.shares)) shares · entry \(trade.entry.formatted(.currency(code: "USD"))) · stop \(trade.stop.formatted(.currency(code: "USD")))")
                                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                DisclosureGroup("Research and decisions · latest 100") {
                    ForEach(Array(automation.book.decisions.suffix(100).reversed())) { decision in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(decision.symbol) \(decision.action) · \(decision.at.formatted(date: .abbreviated, time: .shortened))").font(.caption.bold())
                            Text(decision.reason).font(.callout)
                            if !decision.risk.isEmpty { Text("Risk: \(decision.risk)").font(.caption) }
                            if !decision.facts.isEmpty {
                                DisclosureGroup("Saved evidence and model") {
                                    Text("Model: \(decision.model.isEmpty ? "Simulation rules" : decision.model). References: \(decision.evidence.joined(separator: ", "))")
                                    ForEach(Array(decision.facts.enumerated()), id: \.offset) { index, fact in
                                        Text("F\(index + 1): \(fact)")
                                    }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
