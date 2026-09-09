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
                Text("Paper sessions: normal 04:00–20:00 · early-close 04:00–17:00 New York · exchange holidays closed")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Same-day only · close-out begins at 19:55 normally, 16:55 on published early-close days")
                    .font(.caption).foregroundStyle(.secondary)
                if automation.hasLoadedBook {
                if automation.book.open.contains(where: { StockSagePaperAutomation.dayExitDue(openedAt: $0.openedAt, now: Date()) }) {
                    Text("Close-out required: awaiting fresh later prices. No overnight or closing fill is assumed.")
                        .font(.callout).foregroundStyle(DS.Palette.warningSoft)
                }
                HStack(spacing: 20) {
                    VStack(alignment: .leading) {
                        Text("Total paper cash").font(.caption)
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
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let at = context.date
                    let sales = automation.book.unsettledSales(at: at)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Settled available: \(automation.book.buyingCash(at: at).formatted(.currency(code: "USD"))) · Unsettled proceeds: \(automation.book.unsettledProceeds(at: at).formatted(.currency(code: "USD")))")
                        if automation.book.settledCash(at: at) < 0 {
                            Text("Legacy funding deficit: \((-automation.book.settledCash(at: at)).formatted(.currency(code: "USD"))). New entries wait for settlement; holdings and exits are retained.")
                                .foregroundStyle(DS.Palette.warningSoft)
                        }
                        if !sales.isEmpty {
                            DisclosureGroup("Scheduled paper settlements · \(sales.count)") {
                                ForEach(sales) { trade in
                                    if let closed = trade.closedAt, let date = StockSagePaperAutomation.settlementDate(forSaleAt: closed) {
                                        Text("\(trade.symbol): \(settlementDateLabel(date)) New York · \((trade.exitPrice! * trade.shares).formatted(.currency(code: "USD")))")
                                    } else {
                                        Text("\(trade.symbol): settlement calendar unavailable; proceeds remain unspendable.")
                                            .foregroundStyle(DS.Palette.warningSoft)
                                    }
                                }
                            }
                        }
                    }.font(.caption).foregroundStyle(.secondary)
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
                if let audit = automation.book.audit, !audit.archives.isEmpty {
                    Text("Older audit records preserved in \(audit.archives.count) verified archive chunks beside the account. Recent history is shown below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                } else {
                    Text("Paper balances and history unavailable: the saved account could not be verified. No new account balance is assumed.")
                        .font(.callout).foregroundStyle(DS.Palette.warningSoft)
                }
                if let error = automation.error { Text(error).foregroundStyle(DS.Palette.warningSoft).font(.callout) }
                DisclosureGroup("Simulation policy and limitations") {
                    Text("Same-day horizon only. Qwen receives completed minute bars from the latest hour, or explicitly labelled recent qualified trades when candles are unavailable. Individual trades are not candles or evidence of sufficient liquidity. Daily indicators are background, not intraday signals. New entries stop five minutes before the scheduled extended-session end and the timer requests exits independently of Qwen. If the app sleeps or fresh prices are missing, unresolved positions remain visible; overdue holdings block new buys and exits retry next open session. A same-day policy cannot guarantee a fill.")
                    Text("Separate $10,000 account. Full Massive US listed-market snapshots, excluding OTC. All supported fresh observations are screened, not individually analyzed by Qwen. Qwen reviews all paper holdings first, then up to \(StockSagePaperAutomation.discoveryLimit) affordable new candidates, least recently attempted first and daily dollar activity next. Research uses up to \(StockSagePaperAutomation.researchConcurrency) concurrent workers. Cycles start at least fifteen minutes apart and never overlap, so a longer cycle delays the next one. Missing/stale data and unsupported symbol formats are excluded. The feed can include ETFs; this is not a common-stock-only reference census. Your watchlist is unchanged.")
                    Text("Whole shares, long only, no margin, five positions maximum, and $2,000 maximum per new position. Buy/Strong Buy must cite an actual intraday observation to request an entry; daily background alone is insufficient. Sell/Reduce requests closing the entire simulated holding. Hold/Avoid creates no order. A completed scan is not a promise of a trade or profit.")
                    Text("Settled-cash simulation: purchases immediately reduce spending capacity; net sale proceeds wait until the scheduled T+1 settlement date. The calendar includes bank-only holidays and covers 2026 through January 2027; unknown dates keep proceeds unavailable. Release at New York midnight is a simulation convention, not confirmation of broker funds. Unexpected closures and settlement failures are not modeled. Total cash and equity still include unsettled receivables; historical fills are not rewritten.")
                    Text("Simulated fills require a qualified Massive SIP trade after the current attempt and no more than ten seconds old. The bounded tape check excludes average-price, prior-reference, corrected and unknown-condition trades. Each attempt expires after two minutes. A triggered stop retains its protective intent across expiry, price recovery, pause and restart until that holding closes; retries still need a later eligible observation. Ordinary model sell and target requests keep their existing expiry behavior. Costs assume 10 basis points per side; they do not measure spread, depth or extended-hours liquidity. A 2% stop and 4% target are simulation rules, not price forecasts.")
                    Text("Runs while this Mac is awake and StockSage is open. Published 2026 holidays and early closes are modeled; unsupported calendar years and stale or missing data block fills. Sleep, disconnects and missed research are never backfilled. Dividends, actual liquidity, broker minimum fees and corporate actions are not modeled; large price/basis changes pause the account for review. No real orders or real-journal records are created.")
                }.font(.caption).foregroundStyle(.secondary)
                if automation.hasLoadedBook, !automation.book.open.isEmpty {
                    DisclosureGroup("Paper positions") {
                        ForEach(automation.book.open) { trade in
                            Text("\(trade.symbol) · \(Int(trade.shares)) shares · entry \(trade.entry.formatted(.currency(code: "USD"))) · stop \(trade.stop.formatted(.currency(code: "USD")))")
                                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if automation.hasLoadedBook {
                DisclosureGroup("Research and decisions · latest \(min(100, automation.book.decisions.count))") {
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
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settlementDateLabel(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = TimeZone(identifier: "America/New_York")!
        return style.format(date)
    }
}
