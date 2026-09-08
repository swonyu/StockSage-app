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
                if let error = automation.error { Text(error).foregroundStyle(DS.Palette.warningSoft).font(.callout) }
                DisclosureGroup("Simulation policy and limitations") {
                    Text("Separate $10,000 account. Qwen researches up to four US watchlist or held stocks every fifteen minutes, rotating through the list. Whole shares, long only, no margin, five positions maximum, and $2,000 maximum per new position. Buy/Strong Buy can open; Sell/Reduce closes the entire simulated holding. Hold/Avoid creates no order.")
                    Text("Simulated fills require a Massive SIP observation after the decision, received within two minutes. Costs assume 10 basis points per side. A 2% stop and 4% target are simulation rules, not price forecasts. Exits use a subsequent observed price; gaps and missed crossings can worsen outcomes.")
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
                DisclosureGroup("Research and decisions · latest twelve") {
                    ForEach(Array(automation.book.decisions.suffix(12).reversed())) { decision in
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
