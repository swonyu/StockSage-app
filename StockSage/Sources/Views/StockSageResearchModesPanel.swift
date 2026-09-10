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
                Self.runningScanControls(running: running,
                    show: { mode = running.rawValue }, stop: { research.stop() })
            }
        }
    }

    private func manual(_ horizon: StockSageHorizonResearch.Horizon) -> some View {
        let scan = research.scans[horizon] ?? .init()
        let rows = scan.listings.filter { item in
            (search.isEmpty || item.ticker.localizedCaseInsensitiveContains(search) || item.name.localizedCaseInsensitiveContains(search))
                && (!buysOnly || Self.isBuy(scan.results[item.ticker]?.verdict?.action))
        }
        let isRunning = research.running == horizon
        let buys = scan.results.values.filter { Self.isBuy($0.verdict?.action) }.count
        let incomplete = scan.results.values.filter { $0.verdict == nil }.count
        return GroupBox {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Self.manualControls(horizon: horizon, hasRun: scan.at != nil, running: research.running,
                    run: { selected = nil; research.start(horizon, store: store) }, stop: { research.stop() })
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Self.scanStatus(scan.status, isRunning: isRunning)
                    if isRunning, let symbol = research.activeSymbol {
                        Text("\(symbol) · daily history, news and Qwen").font(.caption).monospaced()
                        ProgressView().progressViewStyle(.linear).accessibilityLabel("\(symbol) research in progress")
                    }
                    if !scan.listings.isEmpty {
                        HStack(spacing: DS.Space.lg) {
                            Text("\(scan.results.count)/\(scan.listings.count) checked")
                            Text("\(buys) Buy / Strong Buy")
                            Text("\(incomplete) incomplete").foregroundStyle(incomplete > 0 ? DS.Palette.warningSoft : .secondary)
                        }.font(.caption).monospacedDigit()
                    }
                }.padding(DS.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: DS.Radius.small))
                if rows.isEmpty {
                    let empty = Self.emptyState(for: scan, isRunning: isRunning)
                    ContentUnavailableView {
                        Label(empty.title, systemImage: scan.listings.isEmpty ? "doc.text.magnifyingglass" : "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(empty.detail)
                    } actions: {
                        if !scan.listings.isEmpty {
                            Button("Clear filters") { search = ""; buysOnly = false; selected = nil }
                        } else if isRunning {
                            ProgressView().controlSize(.small).accessibilityLabel("Research scan in progress")
                        }
                    }.frame(maxWidth: .infinity, minHeight: 180)
                }
                if !scan.listings.isEmpty {
                    Self.filters(search: $search, buysOnly: $buysOnly)
                    Text("\(rows.count) shown · select a stock for evidence and price levels")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !rows.isEmpty {
                    Table(rows, selection: $selected) {
                        TableColumn("Stock") { item in
                            VStack(alignment: .leading) {
                                Text(item.ticker).fontWeight(.semibold)
                                Text(item.name).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                            }.help("\(item.name) · \(item.type ?? "instrument type unconfirmed")")
                        }.width(min: 100, ideal: 160)
                        TableColumn("Check / opinion") { item in
                            Text(Self.resultLabel(item.ticker, research: research, scan: scan, horizon: horizon))
                                .foregroundStyle(Self.isBuy(scan.results[item.ticker]?.verdict?.action) ? DS.Palette.success : .secondary)
                                .help(scan.results[item.ticker]?.note ?? "This listing has not been checked.")
                        }.width(min: 100, ideal: 130)
                        TableColumn("Entry ref.") { item in
                            Text(Self.price(scan.results[item.ticker]?.levels?.entry)).monospacedDigit()
                                .accessibilityLabel(scan.results[item.ticker]?.levels.map { "Entry reference \(Self.price($0.entry))" } ?? "Entry reference not available")
                        }.width(min: 72, ideal: 92, max: 110)
                        TableColumn("Stop-loss") { item in
                            Text(Self.price(scan.results[item.ticker]?.levels?.stop)).monospacedDigit()
                                .accessibilityLabel(scan.results[item.ticker]?.levels.map { "Stop-loss \(Self.price($0.stop))" } ?? "Stop-loss not available")
                        }.width(min: 72, ideal: 92, max: 110)
                        TableColumn("Target") { item in
                            Text(Self.price(scan.results[item.ticker]?.levels?.target)).monospacedDigit()
                                .accessibilityLabel(scan.results[item.ticker]?.levels.map { "Target \(Self.price($0.target))" } ?? "Target not available")
                        }.width(min: 72, ideal: 92, max: 110)
                    }.frame(height: 320)
                }
                if let selected, let item = rows.first(where: { $0.ticker == selected }) {
                    Divider()
                    Self.resultDetail(item, result: scan.results[selected])
                }
                Divider()
                Text(StockSagePaperAutomationPanel.monitoringLabel(running: automation.isRunning, at: Date())
                    + " · Day trading is controlled separately.").font(.caption).foregroundStyle(.secondary)
                Text("Reference prices, not executable orders. Stops and targets are scenarios, not forecasts.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Coverage & price assumptions") {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("First \(StockSageHorizonResearch.scanLimit) active US listings in Massive’s alphabetical directory, including ETFs and other listed stock-market instruments; no OTC. This is a size limit, not a best-stock ranking or the S&P 500. One manual worker checks them in order.")
                        Text("Results stay in this app session. A new run replaces this horizon’s results; quitting clears them. No paper positions or real orders are created.")
                        Text("Reference prices are completed split-adjusted daily closes, not current executable quotes. Neither horizon has an independently validated profitable strategy.")
                        if let at = scan.at { Text("Run requested \(at.formatted(date: .abbreviated, time: .shortened))") }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(DS.Space.xs)
        }
    }

    static func scanStatus(_ status: String, isRunning: Bool) -> some View {
        Label(status, systemImage: isRunning ? "arrow.triangle.2.circlepath" : "info.circle")
            .font(.callout).accessibilityLabel("Scan status: \(status)")
            .fixedSize(horizontal: false, vertical: true)
    }

    static func manualControls(horizon: StockSageHorizonResearch.Horizon, hasRun: Bool,
                               running: StockSageHorizonResearch.Horizon?,
                               run: @escaping () -> Void, stop: @escaping () -> Void) -> some View {
        adaptiveActionRow {
            VStack(alignment: .leading, spacing: 4) {
                Text(horizon.rawValue).font(.headline)
                Text("Research only · up to \(StockSageHorizonResearch.scanLimit) US listings · one-time scan")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } actions: {
            if running == horizon {
                Button("Stop scan", systemImage: "stop.fill", action: stop)
                    .accessibilityLabel("Stop \(horizon.rawValue) research scan")
                    .help("Stop this research scan. Day trading is controlled separately.")
            } else {
                Button(hasRun ? "Run again" : "Run \(StockSageHorizonResearch.scanLimit)-stock scan", systemImage: "play.fill", action: run)
                    .buttonStyle(.borderedProminent).tint(DS.Palette.accent)
                    .accessibilityLabel("Run \(horizon.rawValue) research scan")
                    .disabled(running != nil)
                    .help("Research once; no orders. A new run replaces this horizon’s temporary results.")
            }
        }
    }

    static func runningScanControls(running: StockSageHorizonResearch.Horizon,
                                   show: @escaping () -> Void, stop: @escaping () -> Void) -> some View {
        adaptiveActionRow {
            Text("\(running.rawValue) scan is still running. Switching tabs does not stop it.").font(.caption)
        } actions: {
            Button("Show scan", action: show)
                .accessibilityLabel("Show \(running.rawValue) research scan")
            Button("Stop scan", action: stop)
                .accessibilityLabel("Stop \(running.rawValue) research scan")
        }
    }

    private static func adaptiveActionRow<Content: View, Actions: View>(
        @ViewBuilder _ content: () -> Content, @ViewBuilder actions: () -> Actions
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                content().fixedSize()
                Spacer(minLength: DS.Space.sm)
                HStack(spacing: DS.Space.sm, content: actions).fixedSize()
            }
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                content().fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.sm, content: actions).fixedSize()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Called only when no rows are visible; a filter is not a failed scan.
    static func emptyState(for scan: StockSageHorizonResearch.Scan, isRunning: Bool) -> (title: String, detail: String) {
        if !scan.listings.isEmpty {
            return ("No matching stocks", "Change your search or clear the Buy / Strong Buy filter. Unchecked stocks and incomplete opinions stay available in the full list.")
        }
        if isRunning {
            return ("Waiting for scan results", "The current status is shown above.")
        }
        if scan.at != nil {
            return ("No results collected", "See the scan status above for details. You can run again when ready; no orders were created.")
        }
        return ("Your research starts here", "Choose Run \(StockSageHorizonResearch.scanLimit)-stock scan to check daily history, news and Qwen opinions once. Select a result to see its evidence and any entry, stop-loss and target levels.")
    }

    static func resultLabel(_ symbol: String, research: StockSageHorizonResearch,
                            scan: StockSageHorizonResearch.Scan,
                            horizon: StockSageHorizonResearch.Horizon) -> String {
        if research.running == horizon, research.activeSymbol == symbol { return "Checking…" }
        if let result = scan.results[symbol] { return result.verdict?.action.rawValue ?? "Incomplete" }
        return research.running == horizon && research.activeSymbol != nil ? "Queued" : "Not checked"
    }

    static func filters(search: Binding<String>, buysOnly: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            TextField("Find a symbol or company", text: search).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter research by symbol or company")
            Toggle("Buy / Strong Buy only", isOn: buysOnly).toggleStyle(.checkbox)
        }
    }

    static func resultDetail(_ item: StockSageHorizonResearch.Listing,
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
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func level(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(price(value)).font(.headline).monospacedDigit()
        }
    }
    private static func price(_ value: Double?) -> String { value.map { "$" + StockSageCurrency.adaptivePrice($0) } ?? "—" }
    private static func isBuy(_ action: TradeAdvice.Action?) -> Bool { action == .buy || action == .strongBuy }
}
#endif
