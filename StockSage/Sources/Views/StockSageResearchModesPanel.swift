#if os(macOS)
import SwiftUI

struct StockSageResearchModesPanel: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject private var research = StockSageHorizonResearch.shared
    @ObservedObject private var automation = StockSagePaperAutomation.shared
    @State private var mode = "Day trading"
    @State private var search = ""
    @State private var buysOnly = false
    @State private var selected: String?

    private var horizon: StockSageHorizonResearch.Horizon? { .init(rawValue: mode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Research & paper trading", systemImage: "chart.xyaxis.line").font(.title3.bold())
            Picker("Trading horizon", selection: $mode) {
                Text("Day trading").tag("Day trading")
                ForEach(StockSageHorizonResearch.Horizon.allCases) { value in Text(value.rawValue).tag(value.rawValue) }
            }.pickerStyle(.segmented)
                .onChange(of: mode) { _, _ in selected = nil; search = ""; buysOnly = false }
            if let horizon {
                manual(horizon)
            } else {
                Text("Continuous same-day simulation · up to 101 checks per cycle · runs until you pause it.")
                    .font(.callout).foregroundStyle(.secondary)
                StockSagePaperAutomationPanel()
            }
            if let running = research.running, running != horizon {
                HStack {
                    Text("\(running.rawValue) scan is still running. Switching tabs does not stop it.").font(.caption)
                    Spacer()
                    Button("Show scan") { mode = running.rawValue }
                    Button("Stop scan") { research.stop() }
                }
            }
        }
    }

    private func manual(_ horizon: StockSageHorizonResearch.Horizon) -> some View {
        let scan = research.scans[horizon] ?? .init()
        let rows = scan.listings.filter { item in
            (search.isEmpty || item.ticker.localizedCaseInsensitiveContains(search) || item.name.localizedCaseInsensitiveContains(search))
                && (!buysOnly || isBuy(scan.results[item.ticker]?.verdict?.action))
        }
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(horizon.rawValue) · research only").font(.headline)
                        Text("One full-US-market pass. No paper positions or real orders.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if research.running == horizon {
                        Button("Stop scan", systemImage: "stop.fill") { research.stop() }
                    } else {
                        Button(scan.at == nil ? "Run US-market scan" : "Run again", systemImage: "play.fill") {
                            selected = nil
                            research.start(horizon, store: store)
                        }.buttonStyle(.borderedProminent).disabled(research.running != nil)
                    }
                }
                Text(StockSagePaperAutomationPanel.monitoringLabel(running: automation.isRunning, at: Date())
                    + " · Day trading is controlled separately.").font(.caption).foregroundStyle(.secondary)
                Text(scan.status).font(.callout).accessibilityLabel("Scan status: \(scan.status)")
                if research.running == horizon, let symbol = research.activeSymbol {
                    Text("\(symbol) · checking daily history, news and Qwen…").font(.caption).monospaced()
                    ProgressView().progressViewStyle(.linear).accessibilityLabel("\(symbol) research in progress")
                }
                if let at = scan.at {
                    Text("Started \(at.formatted(date: .abbreviated, time: .shortened)) · \(scan.results.count)/\(scan.listings.count) listings checked")
                        .font(.caption).monospacedDigit()
                }
                Text("All active US listings returned by Massive, including ETFs and other listed stock-market instruments; no OTC. No watchlist, price or 101-name cap. One manual worker protects local-model capacity; thousands of checks can take hours. Results stay in this app session, including when you switch modes. A new run replaces this horizon’s results.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Find a symbol or company", text: $search).textFieldStyle(.roundedBorder)
                    Toggle("Buy / Strong Buy only", isOn: $buysOnly).toggleStyle(.checkbox)
                }
                Text("\(rows.count) listings shown · select a row for evidence and entry / stop / target details")
                    .font(.caption).foregroundStyle(.secondary)
                Table(rows, selection: $selected) {
                    TableColumn("Stock") { item in
                        VStack(alignment: .leading) {
                            Text(item.ticker).fontWeight(.semibold)
                            Text(item.name).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }.width(min: 100, ideal: 160)
                    TableColumn("Check / opinion") { item in
                        Text(resultLabel(item.ticker, scan: scan, horizon: horizon))
                            .foregroundStyle(isBuy(scan.results[item.ticker]?.verdict?.action) ? DS.Palette.success : .secondary)
                    }.width(min: 100, ideal: 130)
                    TableColumn("Entry ref.") { item in Text(price(scan.results[item.ticker]?.levels?.entry)).monospacedDigit() }.width(min: 72, ideal: 92, max: 110)
                    TableColumn("Stop-loss") { item in Text(price(scan.results[item.ticker]?.levels?.stop)).monospacedDigit() }.width(min: 72, ideal: 92, max: 110)
                    TableColumn("Target") { item in Text(price(scan.results[item.ticker]?.levels?.target)).monospacedDigit() }.width(min: 72, ideal: 92, max: 110)
                }.frame(height: 320)
                if let selected, let item = scan.listings.first(where: { $0.ticker == selected }) {
                    resultDetail(item, result: scan.results[selected])
                }
                Text("Reference prices are completed split-adjusted daily closes, not current executable quotes. Stops and targets are calculated scenarios, not forecasts. Neither horizon has an independently validated profitable strategy.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }
    }

    private func resultLabel(_ symbol: String, scan: StockSageHorizonResearch.Scan,
                             horizon: StockSageHorizonResearch.Horizon) -> String {
        if research.running == horizon, research.activeSymbol == symbol { return "Checking…" }
        if let result = scan.results[symbol] { return result.verdict?.action.rawValue ?? "Incomplete" }
        return research.running == horizon ? "Queued" : "Not checked"
    }

    private func resultDetail(_ item: StockSageHorizonResearch.Listing,
                              result: StockSageHorizonResearch.Result?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(item.ticker) · \(item.name)").font(.headline)
            Text("Type: \(item.type ?? "unconfirmed") · \(item.primary_exchange ?? "exchange unconfirmed")").font(.caption)
            if let result {
                Text(result.note).font(.callout)
                if let verdict = result.verdict {
                    Text("\(verdict.action.rawValue) · \(verdict.reason)")
                    Text("Risk: \(verdict.risk)").foregroundStyle(.secondary)
                }
                if let levels = result.levels {
                    HStack(spacing: 24) {
                        level("Entry reference", value: levels.entry)
                        level("Stop-loss", value: levels.stop)
                        level("Target", value: levels.target)
                    }
                    Text("Daily bar: \(levels.at.formatted(date: .abbreviated, time: .omitted)) · USD · Massive split-adjusted history").font(.caption)
                    Text(levels.basis).font(.caption).foregroundStyle(.secondary)
                } else if isBuy(result.verdict?.action) {
                    Text("No valid ATR-based entry/stop/target plan could be calculated. Do not treat this opinion as an order plan.")
                        .font(.callout).foregroundStyle(DS.Palette.warningSoft)
                }
                if !result.facts.isEmpty {
                    DisclosureGroup("Evidence captured \(result.at.formatted(date: .abbreviated, time: .shortened))") {
                        Text("Model: \(result.model.isEmpty ? "no verified model answer" : result.model) · References: \(result.verdict?.evidence.joined(separator: ", ") ?? "none")")
                        ForEach(Array(result.facts.enumerated()), id: \.offset) { index, fact in Text("F\(index + 1): \(fact)") }
                    }.font(.caption)
                }
            } else { Text("This listing has not been checked. No opinion or price levels are assumed.") }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func level(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(price(value)).font(.headline).monospacedDigit()
        }
    }
    private func price(_ value: Double?) -> String { value.map { "$" + StockSageCurrency.adaptivePrice($0) } ?? "—" }
    private func isBuy(_ action: TradeAdvice.Action?) -> Bool { action == .buy || action == .strongBuy }
}
#endif
