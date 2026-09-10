import SwiftUI

struct StockSageResearchModesPanel: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject var research = StockSageHorizonResearch.shared
    struct Presentation {
        var horizon: StockSageHorizonResearch.Horizon = .week
        var search = ""
        var buysOnly = false
        var selected: String?
    }
    @Binding var presentation: Presentation
    private var selected: String? {
        get { presentation.selected }
        nonmutating set { presentation.selected = newValue }
    }
    private var search: String {
        get { presentation.search }
        nonmutating set { presentation.search = newValue }
    }
    private var buysOnly: Bool {
        get { presentation.buysOnly }
        nonmutating set { presentation.buysOnly = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Research horizon", selection: $presentation.horizon) {
                ForEach(StockSageHorizonResearch.Horizon.allCases) { value in Text(value.rawValue).tag(value) }
            }.pickerStyle(.segmented)
                .onChange(of: presentation.horizon) { _, _ in selected = nil; search = ""; buysOnly = false }
            Text("First \(StockSageHorizonResearch.scanLimit) active US listings alphabetically — not a best-stock ranking. Research only; no orders.")
                .font(.callout).foregroundStyle(.secondary)
            manual(presentation.horizon)
            if let running = research.running, running != presentation.horizon {
                Self.runningScanControls(running: running,
                    show: { presentation.horizon = running }, stop: { research.stop() })
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
        let box = GroupBox {
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
                    Self.filters(search: $presentation.search, buysOnly: $presentation.buysOnly)
                        // Spec: clear the selection when it is filtered OUT, not on every keystroke.
                        .onChange(of: rows.map(\.ticker)) { _, visible in
                            if let selected, !visible.contains(selected) { self.selected = nil }
                        }
                    Text("\(rows.count) shown · select a stock for evidence and price levels")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !rows.isEmpty {
                    #if os(macOS)
                    Table(rows, selection: $presentation.selected) {
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
                        TableColumn("Daily close") { item in
                            Text(Self.price(scan.results[item.ticker]?.levels?.entry)).monospacedDigit()
                                .accessibilityLabel(scan.results[item.ticker]?.levels.map { "Daily close reference \(Self.price($0.entry))" } ?? "Daily close reference not available")
                        }.width(min: 72, ideal: 92, max: 110)
                        TableColumn("Scenario stop") { item in
                            Text(Self.price(scan.results[item.ticker]?.levels?.stop)).monospacedDigit()
                                .accessibilityLabel(scan.results[item.ticker]?.levels.map { "Scenario stop \(Self.price($0.stop))" } ?? "Scenario stop not available")
                        }.width(min: 72, ideal: 92, max: 110)
                        TableColumn("Scenario target") { item in
                            Text(Self.price(scan.results[item.ticker]?.levels?.target)).monospacedDigit()
                                .accessibilityLabel(scan.results[item.ticker]?.levels.map { "Scenario target \(Self.price($0.target))" } ?? "Scenario target not available")
                        }.width(min: 72, ideal: 92, max: 110)
                    }.frame(minHeight: 360)
                    #else
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { item in
                            Button {
                                selected = item.ticker
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.ticker).font(.headline)
                                        Text(item.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(Self.resultLabel(item.ticker, research: research, scan: scan, horizon: horizon))
                                        .font(.callout)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(minHeight: 44).contentShape(Rectangle()).padding(.vertical, 8)
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                    #endif
                }
                Divider()

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
        // Presented only while the selection is a currently visible row; dismissal clears it.
        let presented = Binding<Bool>(
            get: { selected.map { symbol in rows.contains { $0.ticker == symbol } } ?? false },
            set: { if !$0 { selected = nil } })
        #if os(macOS)
        // `.inspector` splits the trailing column at the EXACT position it is applied — nesting
        // it (or its host) inside another ScrollView's content means the split point scrolls
        // with that content instead of pinning to the detail column (pixel-verified 2026-09-10:
        // the panel is the caller's only child now, so this ScrollView is this page's own root,
        // not nested inside a page-level one — see MarketsView.desktopWorkspace's `.research`
        // branch, which renders this panel directly rather than wrapping it again).
        return ScrollView { box.padding(28).frame(maxWidth: 1200, alignment: .leading) }
            .frame(maxWidth: .infinity, alignment: .top)
            .inspector(isPresented: presented) { detailPresentation(rows: rows, scan: scan) }
        #else
        // Not `.inspector` here: inside this scroll content its UIKit host ignored its layout offset
        // on iPhone (pixel-verified 2026-09-10, it overdrew the coverage text). The spec's compact
        // detail is a sheet — sheets present as an overlay regardless of scroll position, so this
        // placement (unlike `.inspector` above) is unaffected by the page's own ScrollView.
        return box.sheet(isPresented: presented) { detailPresentation(rows: rows, scan: scan) }
        #endif
    }

    @ViewBuilder private func detailPresentation(rows: [StockSageHorizonResearch.Listing],
                                                 scan: StockSageHorizonResearch.Scan) -> some View {
        if let selected, let item = rows.first(where: { $0.ticker == selected }) {
            let detail = ScrollView {
                Self.resultDetail(item, result: scan.results[selected]).padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Close details", systemImage: "xmark") { self.selected = nil }
                }
            }
            #if os(macOS)
            detail.inspectorColumnWidth(min: 300, ideal: 360, max: 450)
            #else
            NavigationStack { detail.navigationTitle(item.ticker).navigationBarTitleDisplayMode(.inline) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            #endif
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
            Toggle("Buy / Strong Buy only", isOn: buysOnly)
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
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
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                        GridRow { Text("Daily close"); Text(price(levels.entry)).monospacedDigit() }
                        GridRow { Text("Scenario stop"); Text(price(levels.stop)).monospacedDigit() }
                        GridRow { Text("Scenario target"); Text(price(levels.target)).monospacedDigit() }
                    }.font(.callout)
                    Text("Scenarios, not executable orders or forecasts.").font(.caption).foregroundStyle(.secondary)
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


    private static func price(_ value: Double?) -> String { value.map { "$" + StockSageCurrency.adaptivePrice($0) } ?? "—" }
    private static func isBuy(_ action: TradeAdvice.Action?) -> Bool { action == .buy || action == .strongBuy }
}
