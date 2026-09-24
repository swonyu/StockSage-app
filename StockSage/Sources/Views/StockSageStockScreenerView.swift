#if os(macOS)
import SwiftUI

struct StockSageStockScreenerView: View {
    @ObservedObject private var screener: StockSageStockScreener
    @State private var minimumCap = "50"
    @State private var maximumCap = "300"
    @State private var maximumPE = ""
    @State private var minimumROA = ""
    @State private var maximumDebt = ""
    @State private var search = ""
    @State private var includeOther = false
    @State private var sort: StockSageStockScreener.Sort = .marketCap
    @State private var ascending = true
    @State private var page = 0
    @State private var qualityRow: StockSageStockScreener.Row?
    @State private var newsReloadRevision = 0

    init(store: StockSageStore, screener: StockSageStockScreener = .shared) { self.screener = screener }

    private var filters: StockSageStockScreener.Filters? {
        func optional(_ text: String) -> Double? { Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let low = optional(minimumCap),
              maximumCap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || optional(maximumCap) != nil,
              maximumPE.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || optional(maximumPE) != nil,
              minimumROA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || optional(minimumROA) != nil,
              maximumDebt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || optional(maximumDebt) != nil else { return nil }
        let value = StockSageStockScreener.Filters(minimumCap: low * 1_000_000, maximumCap: optional(maximumCap).map { $0 * 1_000_000 },
            maximumPE: optional(maximumPE), minimumROA: optional(minimumROA).map { $0 / 100 },
            maximumDebtEquity: optional(maximumDebt))
        return value.isValid ? value : nil
    }
    private var visibleRows: [StockSageStockScreener.Row] {
        guard let filters else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = (screener.snapshot?.rows ?? []).filter {
            (includeOther || filters.classify($0).status == .matched)
                && (query.isEmpty || $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query))
        }
        return StockSageStockScreener.sorted(rows, by: sort, ascending: ascending)
    }
    private var filterIdentity: String { [minimumCap, maximumCap, maximumPE, minimumROA, maximumDebt, search, String(includeOther), sort.rawValue, String(ascending)].joined(separator: "|") }
    // News follows every financial/search match, regardless of table sort, pagination or excluded rows.
    private var newsSelection: [StockSageStockScreener.Row] {
        StockSageScreenerNews.matchingRows(screener.snapshot?.rows ?? [], filters: filters, search: search)
    }
    private var newsFilterIdentity: [String] { [minimumCap, maximumCap, maximumPE, minimumROA, maximumDebt, search] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                filterControls
                if let snapshot = screener.snapshot {
                    coverage(snapshot)
                    StockSageScreenerNewsView(rows: newsSelection, selectionID: newsFilterIdentity + [String(newsReloadRevision)],
                        ratiosAt: snapshot.retrievedAt, isReloading: screener.isLoading)
                    results
                } else {
                    ContentUnavailableView("Load a daily company screen", systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Market cap and company-quality filters use dated provider ratios. No research or model assessment starts here."))
                }
            }.padding(24).frame(maxWidth: 1200, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Palette.bgTop)
        .onChange(of: filterIdentity) { _, _ in page = 0 }
        .onChange(of: screener.snapshot?.retrievedAt) { _, _ in page = 0 }
        .sheet(item: $qualityRow) { row in
            CompanyQualitySheet(row: row, screener: screener)
                .presentationSizing(.fitted)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Stock screener", systemImage: "line.3.horizontal.decrease.circle").font(.title.weight(.semibold))
            Text("Explore company size and reported financial quality. These editable filters are separate from the Micro cap and Large cap same-day qualification rules.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(screener.snapshot == nil ? "Load daily ratios" : "Reload daily ratios") {
                    newsReloadRevision += 1
                    Task { await screener.load() }
                }
                    .buttonStyle(.borderedProminent).disabled(screener.isBusy)
                    .accessibilityIdentifier("screener.load")
                if screener.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { screener.cancel() }.accessibilityIdentifier("screener.cancel")
                }
            }
            Text(screener.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("screener.status")
        }
    }

    private var filterControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Keep the heading in the content: the native GroupBox label crashes CUA traversal.
                Text("Your filters").font(.headline).accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
                    Text("Size presets").font(.subheadline.weight(.medium))
                    Button("Micro cap · $50–300M") { minimumCap = "50"; maximumCap = "300" }
                        .accessibilityIdentifier("screener.preset.microcap")
                    Button("Large cap · $10B+") { minimumCap = "10000"; maximumCap = "" }
                        .accessibilityIdentifier("screener.preset.largecap")
                }.buttonStyle(.bordered)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 12) {
                    field("Minimum cap · USD millions", text: $minimumCap, id: "screener.minimumCap")
                    field("Maximum cap · USD millions · optional", text: $maximumCap, id: "screener.maximumCap")
                    field("P/E ceiling · optional", text: $maximumPE, id: "screener.maximumPE")
                    field("ROA minimum · % · optional", text: $minimumROA, id: "screener.minimumROA")
                    field("Debt/equity ceiling · optional", text: $maximumDebt, id: "screener.maximumDebt")
                }
                DisclosureGroup("How the filters treat missing and dated values") {
                    Text("A blank maximum cap has no upper ceiling. Size presets keep your quality filters. Blank quality filters are disabled. P/E requires positive earnings; ROA is shown as a percentage; debt/equity is a multiple. Missing values never become zero. Ratios more than seven calendar days old cannot match. ROCE and ROIC are available only where supported in Company quality; they are not bulk filters.")
                        .font(.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }.font(.callout)
                if filters == nil {
                    Label("Enter finite numbers, a nonnegative cap range in ascending order, positive P/E and nonnegative debt/equity.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                TextField("Search symbol or company", text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("screener.search")
                Toggle("Show excluded and unavailable listings", isOn: $includeOther)
                    .accessibilityIdentifier("screener.includeOther")
                HStack {
                    Picker("Sort", selection: $sort) {
                        ForEach(StockSageStockScreener.Sort.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(maxWidth: 280)
                    Toggle("Ascending", isOn: $ascending)
                    Spacer(minLength: 0)
                }
            }.padding(6)
        }
    }

    private func field(_ title: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).labelsHidden().textFieldStyle(.roundedBorder).accessibilityIdentifier(id)
        }
    }

    private func coverage(_ snapshot: StockSageStockScreener.Snapshot) -> some View {
        let matches = filters.map { filter in snapshot.rows.filter { filter.classify($0).status == .matched }.count } ?? 0
        let missing = filters.map { filter in snapshot.rows.filter { filter.classify($0).status == .unavailable }.count } ?? snapshot.rows.count
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(matches) matches · \(snapshot.rows.count - matches - missing) excluded · \(missing) unavailable")
                .font(.headline).accessibilityIdentifier("screener.coverage")
            Text("Captured \(snapshot.retrievedAt.formatted(date: .abbreviated, time: .standard)) · Daily snapshots, not live prices.")
                .font(.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Coverage and source records") {
            Text("Latest daily snapshots, not historical-as-of fundamentals. Coverage is limited to active US USD common shares on Nasdaq plus supported reported S&P 500 members; this is not the entire market.")
                .font(.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let membership = snapshot.membership {
                Text("S&P membership: DataHub/Wikipedia-derived reported list, \(membership.reportedCount) symbols, retrieved \(membership.retrievedAt.formatted(date: .abbreviated, time: .standard)). No official effective date. Source SHA-256 \(membership.sha256).")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Link("Massive ratio documentation", destination: URL(string: "https://massive.com/docs/rest/stocks/fundamentals/ratios")!)
                Link("Reported S&P membership", destination: URL(string: StockSageSP500Constituents.sourceURL)!)
            }.font(.caption)
            }.font(.callout)
        }
    }

    private var results: some View {
        let rows = visibleRows
        let lastPage = max(0, (rows.count - 1) / StockSageStockScreener.pageSize)
        let current = min(page, lastPage)
        let start = current * StockSageStockScreener.pageSize
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(rows.count) listings in this view").font(.headline)
                Spacer()
                Button("Previous") { page = max(0, current - 1) }.disabled(current == 0)
                Text("Page \(current + 1) of \(lastPage + 1)").monospacedDigit()
                Button("Next") { page = current + 1 }.disabled(current >= lastPage)
            }
            if rows.isEmpty {
                Text(filters == nil ? "Correct the filters to display rows." : "No listings match this view. Clear search or show excluded and unavailable listings to inspect the reasons.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(rows.dropFirst(start).prefix(StockSageStockScreener.pageSize))) { row in
                    resultRow(row)
                }
            }
            Text("Screener and Company quality snapshots remain in memory only. Reloading replaces this screen; closing the app clears it. Existing saved research is separate. Company-quality ratios are descriptive and do not establish a same-day entry, liquidity, an executable stop or future performance.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resultRow(_ row: StockSageStockScreener.Row) -> some View {
        let match = filters?.classify(row)
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.symbol).font(.headline).textSelection(.enabled)
                        Text(row.name).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(match?.status.rawValue ?? "Unavailable").font(.caption.bold())
                    Button("Company quality") { qualityRow = row }
                        .disabled(screener.isBusy).accessibilityIdentifier("screener.quality.\(row.symbol)")
                }
                Text("Ratio date: \(row.date ?? "unavailable") · Market cap: \(row.marketCap.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(0))) } ?? "unavailable")")
                    .font(.callout).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(["price_to_earnings", "return_on_assets", "debt_to_equity"], id: \.self) { key in
                        let metric = row.metrics.first { $0.key == key }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(metric?.label ?? (key == "price_to_earnings" ? "P/E" : key == "return_on_assets" ? "ROA" : "Debt/equity")).font(.caption).foregroundStyle(.secondary)
                            Text(metric?.displayValue ?? "Unavailable").font(.callout).monospacedDigit()
                        }
                    }
                }
                if let match, !match.reasons.isEmpty {
                    Text(match.reasons.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("screener.row.\(row.symbol)")
    }
}

private struct CompanyQualitySheet: View {
    let row: StockSageStockScreener.Row
    @ObservedObject var screener: StockSageStockScreener
    @Environment(\.dismiss) private var dismiss
    @State private var finished = false
    @State private var cancelled = false
    @State private var operation = UUID()
    @State private var snapshot: StockSageFundamentals.Snapshot?
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Company quality · \(row.symbol)").font(.title2.weight(.semibold))
                    Text(row.name).font(.callout).foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                Button("Done") { cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("screener.quality.done")
            }
            if !finished && !cancelled {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Loading company quality for \(row.symbol)…").font(.callout)
                    Spacer()
                    Button("Cancel") { cancel() }.accessibilityIdentifier("screener.quality.cancel")
                }
            } else {
                Text(cancelled ? "Company quality cancelled. No new detail was published." : status)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("screener.quality.status")
            }
            ScrollView {
                if finished, !cancelled, let snapshot {
                    StockSageFundamentalsView(snapshot: snapshot, initiallyExpanded: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxHeight: .infinity)
            Text("This detail stays in memory until StockSage closes. It does not save a research run or start a model. Closing stops an unfinished request.")
                .font(.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(minWidth: 520, idealWidth: 740, minHeight: 480, idealHeight: 720)
        .background(DS.Palette.bgTop)
        .task {
            guard !cancelled, !Task.isCancelled else { return }
            let captured = await screener.companyQuality(for: row, operation: operation)
            guard !cancelled, !Task.isCancelled else { return }
            snapshot = captured
            status = screener.isBusy
                ? "Company quality did not start because another data request is running. Close this panel and retry when it finishes."
                : screener.status
            finished = true
        }
        .onDisappear { cancel() }
    }

    private func cancel() {
        cancelled = true
        screener.cancelCompanyQuality(operation: operation)
    }
}
#endif
