import SwiftUI

struct StockSageResearchModesPanel: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject var research = StockSageHorizonResearch.shared
    enum ResultFilter: String, CaseIterable {
        case all = "All checks", buys = "Buy / Strong Buy", incomplete = "Incomplete", unchecked = "Not checked"
    }
    struct Presentation {
        var horizon: StockSageHorizonResearch.Horizon = .week
        var search = ""
        var filter: ResultFilter = .all
        var selected: String?
    }
    @Binding var presentation: Presentation
    #if os(macOS)
    @State private var showsCoverage = false
    #else
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif
    private var selected: String? {
        get { presentation.selected }
        nonmutating set { presentation.selected = newValue }
    }
    private var search: String {
        get { presentation.search }
        nonmutating set { presentation.search = newValue }
    }

    var body: some View {
        manual(presentation.horizon)
    }

    private var visibleListings: [StockSageHorizonResearch.Listing] {
        let scan = research.scans[presentation.horizon] ?? .init()
        return Self.filteredListings(scan, search: search, filter: presentation.filter)
    }

    static func filteredListings(_ scan: StockSageHorizonResearch.Scan, search: String,
                                 filter: ResultFilter) -> [StockSageHorizonResearch.Listing] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return scan.listings.filter { item in
            guard query.isEmpty || item.ticker.localizedCaseInsensitiveContains(query)
                    || item.name.localizedCaseInsensitiveContains(query) else { return false }
            let result = scan.results[item.ticker]
            switch filter {
            case .all: return true
            case .buys: return isBuy(result?.verdict?.action)
            case .incomplete: return result != nil && result?.verdict == nil
            case .unchecked: return result == nil
            }
        }
    }

    var detailPresented: Binding<Bool> {
        Binding(get: { selected.map { symbol in visibleListings.contains { $0.ticker == symbol } } ?? false },
                set: { if !$0 { selected = nil } })
    }

    var selectedDetail: some View {
        ObservedDetail(research: research, panel: self)
    }

    /// The window owns presentation; this consumer observes arriving results without
    /// rebuilding the entire market workspace or capturing a permanently unchecked snapshot.
    private struct ObservedDetail: View {
        @ObservedObject var research: StockSageHorizonResearch
        let panel: StockSageResearchModesPanel

        var body: some View {
            panel.detailPresentation(rows: panel.visibleListings,
                scan: research.scans[panel.presentation.horizon] ?? .init())
        }
    }

    private var horizonControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                #if os(iOS)
                if dynamicTypeSize.isAccessibilitySize {
                    horizonPicker.pickerStyle(.menu)
                        .frame(minHeight: 44)
                } else {
                    horizonPicker.pickerStyle(.segmented).labelsHidden()
                }
                #else
                horizonPicker.pickerStyle(.segmented).labelsHidden()
                #endif
            }
            .controlSize(.large)
            .onChange(of: presentation.horizon) { _, _ in selected = nil; search = ""; presentation.filter = .all }
            #if os(iOS)
            Text("Up to \(StockSageHorizonResearch.scanLimit) US listings selected by recent trading activity, then researched for your chosen horizon. Research only; no orders.")
                .font(.callout).foregroundStyle(.secondary)
            #endif
            if let running = research.running, running != presentation.horizon {
                Self.runningScanControls(running: running,
                    show: { presentation.horizon = running }, stop: { research.stop() })
            }
        }
    }

    private var horizonPicker: some View {
        Picker("Research horizon", selection: $presentation.horizon) {
            ForEach(StockSageHorizonResearch.Horizon.allCases) { value in Text(value.rawValue).tag(value) }
        }
    }


    private func manual(_ horizon: StockSageHorizonResearch.Horizon) -> some View {
        let scan = research.scans[horizon] ?? .init()
        let rows = visibleListings
        let isRunning = research.running == horizon
        let controls = VStack(alignment: .leading, spacing: 16) {
            Self.manualControls(horizon: horizon, hasRun: scan.at != nil, running: research.running,
                run: { selected = nil; research.start(horizon, store: store) }, stop: { research.stop() })
            horizonControls
            scanSummary(scan, isRunning: isRunning)
        }
        // Selection belongs to the workspace, even while filters leave no rows to render.
        .onChange(of: rows.map(\.ticker)) { _, visible in
            if let selected, !visible.contains(selected) { self.selected = nil }
        }
        let resultsHeader = VStack(alignment: .leading, spacing: 8) {
            Self.filters(search: $presentation.search, filter: $presentation.filter)
            Text("\(rows.count) shown · select a stock for evidence and price levels")
                .font(.caption).foregroundStyle(.secondary)
        }
        #if os(macOS)
        // The window owns the inspector. The table owns its scrolling, with no enclosing card.
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView { controls.padding(24) }
                .frame(height: scan.listings.isEmpty ? 220 : 300)
            Divider()
            if !scan.listings.isEmpty { resultsHeader.padding(.horizontal, 24).padding(.vertical, 12) }
            if rows.isEmpty {
                emptyResults(scan, isRunning: isRunning)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsTable(rows, scan: scan, horizon: horizon)
            }
            Divider()
            researchFooter(scan).padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #else
        // The phone workspace owns scrolling, just as the Mac workspace owns its table.
        return VStack(alignment: .leading, spacing: 0) {
            controls.padding(.bottom, 24)
            Divider()
            if !scan.listings.isEmpty {
                resultsHeader.padding(.vertical, 16)
                Divider()
            }
            if rows.isEmpty {
                emptyResults(scan, isRunning: isRunning)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                phoneResults(rows, scan: scan, horizon: horizon)
            }
            if rows.isEmpty { Divider() }
            researchFooter(scan).padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(DS.Palette.accentText)
        .sheet(isPresented: detailPresented) { selectedDetail }
        #endif
    }

    private func scanSummary(_ scan: StockSageHorizonResearch.Scan, isRunning: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Self.scanStatus(scan.status, isRunning: isRunning)
            if let selection = scan.selection {
                Text(selection.summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isRunning, let symbol = research.activeSymbol {
                Text("\(symbol) · daily history, news and Qwen").font(.caption).monospaced()
                ProgressView().progressViewStyle(.linear).accessibilityLabel("\(symbol) research in progress")
            }
            if !scan.listings.isEmpty {
                Self.scanProgress(checked: scan.results.count, total: scan.listings.count,
                    buys: scan.results.values.filter { Self.isBuy($0.verdict?.action) }.count,
                    incomplete: scan.results.values.filter { $0.verdict == nil }.count)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceAlt, in: .rect(cornerRadius: 10))
    }

    private func emptyResults(_ scan: StockSageHorizonResearch.Scan, isRunning: Bool) -> some View {
        let empty = Self.emptyState(for: scan, isRunning: isRunning)
        return ContentUnavailableView {
            Label(empty.title, systemImage: scan.listings.isEmpty ? "doc.text.magnifyingglass" : "line.3.horizontal.decrease.circle")
        } description: {
            Text(empty.detail).frame(maxWidth: 380)
        } actions: {
            if !scan.listings.isEmpty {
                Button("Clear filters") { search = ""; presentation.filter = .all; selected = nil }
            } else if isRunning {
                ProgressView().controlSize(.small).accessibilityLabel("Research scan in progress")
            }
        }
    }

    private func researchFooter(_ scan: StockSageHorizonResearch.Scan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Temporary results · quitting clears them; a new run replaces this horizon’s results.")
            if !scan.listings.isEmpty {
                Text("USD references, not executable orders. Stop and Target are scenarios, not forecasts. A dash means no calculated value; select a stock for the reason.")
            }
            #if os(macOS)
            Button("Coverage & price assumptions", systemImage: "info.circle") { showsCoverage = true }
                .buttonStyle(.borderless)
                .popover(isPresented: $showsCoverage) {
                    ScrollView { coverageDetails(scan).padding(20) }
                        .frame(width: 360, height: 340)
                }
            #else
            DisclosureGroup("Coverage & price assumptions") { coverageDetails(scan) }
            #endif
        }.font(.caption).foregroundStyle(.secondary)
    }

    private func coverageDetails(_ scan: StockSageHorizonResearch.Scan) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Ranked by observed traded dollars (volume × VWAP) from Massive’s dated US market summary, highest activity first. This is an activity-based popularity proxy, not social sentiment, a Buy ranking or the S&P 500. Confirmed USD listings, including ETFs and share classes; no OTC. Missing observations are not filled alphabetically. One manual worker researches the selected list in order.")
            if let selection = scan.selection {
                Text("\(selection.directoryCount) active US directory entries considered. Selection requested \(selection.requestedAt.formatted(date: .abbreviated, time: .shortened)). \(selection.summary)")
            }
            Text("Results stay in this app session. A new run replaces this horizon’s results; quitting clears them. No paper positions or real orders are created.")
            Text("Reference prices are completed split-adjusted daily closes, not current executable quotes. Neither horizon has an independently validated profitable strategy.")
            if let at = scan.at { Text("Run requested \(at.formatted(date: .abbreviated, time: .shortened))") }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }

    #if os(macOS)
    private func resultsTable(_ rows: [StockSageHorizonResearch.Listing], scan: StockSageHorizonResearch.Scan,
                              horizon: StockSageHorizonResearch.Horizon) -> some View {
        Table(rows, selection: $presentation.selected) {
            TableColumn("Stock") { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.ticker).fontWeight(.semibold)
                    Text(item.name).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                }.help("\(item.name) · \(item.type ?? "instrument type unconfirmed")\n\(scan.selection?.detail(for: item.ticker) ?? "Selection activity not recorded.")")
            }.width(min: 80, ideal: 160, max: 300)
            TableColumn("Opinion") { item in
                Text(Self.resultLabel(item.ticker, research: research, scan: scan, horizon: horizon))
                    .foregroundStyle(Self.isBuy(scan.results[item.ticker]?.verdict?.action) ? DS.Palette.successSoft : .secondary)
                    .help(scan.results[item.ticker]?.note ?? "This listing has not been checked.")
            }.width(min: 90, ideal: 120, max: 200)
            TableColumn("Daily close") { item in
                Text(Self.price(scan.results[item.ticker]?.referenceClose?.value)).monospacedDigit()
                    .accessibilityLabel(scan.results[item.ticker]?.referenceClose.map { "Daily close reference \(Self.price($0.value)), \($0.at.formatted(date: .abbreviated, time: .omitted))" } ?? "Daily close reference not available")
            }.width(min: 72, ideal: 92, max: 110)
        }.tableStyle(.inset(alternatesRowBackgrounds: true))
            .environment(\.defaultMinListRowHeight, 48)
    }
    #else
    private func phoneResults(_ rows: [StockSageHorizonResearch.Listing], scan: StockSageHorizonResearch.Scan,
                              horizon: StockSageHorizonResearch.Horizon) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(rows) { item in
                let opinion = Text(Self.resultLabel(item.ticker, research: research, scan: scan, horizon: horizon))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Self.isBuy(scan.results[item.ticker]?.verdict?.action) ? DS.Palette.successSoft : .secondary)
                let close = Text("Daily close \(Self.price(scan.results[item.ticker]?.referenceClose?.value))")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel(scan.results[item.ticker]?.referenceClose.map { "Daily close reference \(Self.price($0.value)), \($0.at.formatted(date: .abbreviated, time: .omitted))" } ?? "Daily close reference not available")
                Button {
                    selected = item.ticker
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.ticker).font(.headline)
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                        Text(item.name).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                opinion.fixedSize()
                                Spacer(minLength: 0)
                                close.fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 6) { opinion; close }
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.vertical, 16).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Show research evidence and price levels")
                Divider()
            }
        }
    }
    #endif

    @ViewBuilder private func detailPresentation(rows: [StockSageHorizonResearch.Listing],
                                                 scan: StockSageHorizonResearch.Scan) -> some View {
        if let selected, let item = rows.first(where: { $0.ticker == selected }) {
            let detail = ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let activity = scan.selection?.detail(for: selected) {
                        Text(activity).font(.caption).foregroundStyle(.secondary)
                    }
                    Self.resultDetail(item, result: scan.results[selected])
                }.padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Close details", systemImage: "xmark") { self.selected = nil }
                }
            }
            #if os(macOS)
            detail.inspectorColumnWidth(min: 300, ideal: 360, max: 450)
            #else
            NavigationStack {
                detail.background(DS.Palette.bgTop)
                    .navigationTitle(item.ticker).navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(DS.Palette.bgTop, for: .navigationBar)
            }
                .tint(DS.Palette.accentText)
                .preferredColorScheme(.dark)
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

    static func scanProgress(checked: Int, total: Int, buys: Int, incomplete: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ProgressView(value: Double(checked), total: Double(max(1, total))) {
                Text("\(checked)/\(total) checks finished, including incomplete")
                    .fixedSize(horizontal: false, vertical: true)
            }.accessibilityValue("\(checked) of \(total) checks finished, including \(incomplete) incomplete opinions")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.lg) {
                    Text("\(buys) Buy / Strong Buy").fixedSize()
                    Text("\(incomplete) incomplete").fixedSize()
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("\(buys) Buy / Strong Buy")
                    Text("\(incomplete) incomplete")
                }
            }
        }.font(.caption).monospacedDigit()
            .help("Checks finished includes incomplete opinions; it does not mean every answer passed validation.")
    }

    static func manualControls(horizon: StockSageHorizonResearch.Horizon, hasRun: Bool,
                               running: StockSageHorizonResearch.Horizon?,
                               run: @escaping () -> Void, stop: @escaping () -> Void) -> some View {
        adaptiveActionRow {
            VStack(alignment: .leading, spacing: 4) {
                Text("Market research").font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
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
                    .controlSize(.large)
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
                #if os(iOS)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.sm, content: actions).fixedSize()
                    VStack(alignment: .leading, spacing: DS.Space.sm, content: actions)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #else
                HStack(spacing: DS.Space.sm, content: actions).fixedSize()
                #endif
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
        .buttonStyle(.bordered)
        .controlSize(.large)
        #endif
    }

    /// Called only when no rows are visible; a filter is not a failed scan.
    static func emptyState(for scan: StockSageHorizonResearch.Scan, isRunning: Bool) -> (title: String, detail: String) {
        if !scan.listings.isEmpty {
            return ("No matching stocks", "Change your search or choose All checks. Incomplete means checked without a verified opinion; Not checked includes queued listings.")
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

    static func filters(search: Binding<String>, filter: Binding<ResultFilter>) -> some View {
        let field = TextField("Find a symbol or company", text: search).textFieldStyle(.roundedBorder)
            #if os(iOS)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            #endif
            .accessibilityLabel("Filter research by symbol or company")
        let picker = Picker("Show", selection: filter) {
            ForEach(ResultFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu).accessibilityLabel("Research result filter")
        .help("Incomplete: checked without a verified opinion. Not checked: includes queued listings.")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { field.frame(minWidth: 200); picker.fixedSize() }
            VStack(alignment: .leading, spacing: DS.Space.sm) { field; picker }
        }.controlSize(.large)
    }

    static func notePresentation(_ note: String) -> (explanation: String, diagnostics: String?) {
        // Only separate the receipt emitted by failureSummary; unfamiliar notes remain intact.
        guard note.hasPrefix("No verified opinion.") else { return (note, nil) }
        let boundary: String.Index
        if let validation = note.range(of: "validation="),
           note[..<validation.lowerBound].last?.isWhitespace == true,
           note[validation.lowerBound...].contains(" server=") {
            boundary = validation.lowerBound
        } else if let server = note.range(of: "\nserver=") {
            let category = String(note[server.upperBound...].prefix { !$0.isWhitespace })
            guard category == "completed" || StockSageLocalModelServer.FailureCategory(rawValue: category) != nil,
                  note[server.upperBound...].contains(" status=") else { return (note, nil) }
            boundary = note.index(after: server.lowerBound)
        } else { return (note, nil) }
        var explanation = String(note[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        var diagnostics = String(note[boundary...])
        // Horizon research appends this human-facing context warning after the receipt.
        if let warning = diagnostics.range(of: #"\s+[0-9]+ of [0-9]+ optional evidence records were omitted to fit the context budget\.$"#,
                                            options: .regularExpression) {
            explanation += "\n" + diagnostics[warning].trimmingCharacters(in: .whitespacesAndNewlines)
            diagnostics = String(diagnostics[..<warning.lowerBound])
        }
        return (explanation, diagnostics)
    }

    static func resultDetail(_ item: StockSageHorizonResearch.Listing,
                              result: StockSageHorizonResearch.Result?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.ticker).font(.title.weight(.bold))
                Text(item.name).font(.callout)
                Text("Type: \(item.type ?? "unconfirmed") · \(item.primary_exchange ?? "exchange unconfirmed")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if let result {
                let note = notePresentation(result.note)
                Text(note.explanation).font(.callout)
                if let diagnostics = note.diagnostics {
                    DisclosureGroup("Technical details") {
                        Text(verbatim: diagnostics).font(.caption.monospaced())
                            .fixedSize(horizontal: false, vertical: true)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if let verdict = result.verdict {
                    Text(verdict.action.rawValue).font(.title3.weight(.semibold))
                        .foregroundStyle(isBuy(verdict.action) ? DS.Palette.successSoft : .primary)
                    Text(verdict.reason).font(.body).lineSpacing(3)
                    Text("Risk: \(verdict.risk)").foregroundStyle(.secondary)
                }
                if let close = result.referenceClose {
                    Text("Daily close: \(price(close.value)) · \(close.at.formatted(date: .abbreviated, time: .omitted)) · USD · Massive split-adjusted history")
                        .font(.callout).monospacedDigit()
                }
                if let levels = result.levels {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                        GridRow { Text("Scenario stop"); Text(price(levels.stop)).monospacedDigit() }
                        GridRow { Text("Scenario target"); Text(price(levels.target)).monospacedDigit() }
                    }.font(.callout)
                    Text("Scenarios, not executable orders or forecasts.").font(.caption).foregroundStyle(.secondary)
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
        }.textSelection(.enabled).accessibilityElement(children: .contain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }


    private static func price(_ value: Double?) -> String { value.map { "$" + StockSageCurrency.adaptivePrice($0) } ?? "—" }
    private static func isBuy(_ action: TradeAdvice.Action?) -> Bool { action == .buy || action == .strongBuy }
}
