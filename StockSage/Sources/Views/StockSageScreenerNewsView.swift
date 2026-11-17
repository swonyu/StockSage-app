#if os(macOS)
import SwiftUI

/// Manual news for the complete financial/search match set. Display pagination never limits collection.
struct StockSageScreenerNewsView: View {
    let rows: [StockSageStockScreener.Row]
    let selectionID: [String]
    let ratiosAt: Date
    let isReloading: Bool
    @StateObject private var news: StockSageScreenerNews
    @State private var showingNews = false
    @State private var tab: Tab = .headlines
    @State private var page = 0
    @State private var loadTask: Task<Void, Never>?

    private enum Tab: String, CaseIterable { case headlines = "Headlines", coverage = "Coverage" }
    private struct Headline: Identifiable {
        let symbol: String
        let item: StockSageNewsService.NewsItem
        var id: String { symbol + "|" + item.id }
    }
    private let pageSize = 50

    init(rows: [StockSageStockScreener.Row], selectionID: [String], ratiosAt: Date,
         isReloading: Bool, news: StockSageScreenerNews = .init()) {
        self.rows = rows; self.selectionID = selectionID; self.ratiosAt = ratiosAt
        self.isReloading = isReloading
        _news = StateObject(wrappedValue: news)
    }

    private var coverageRows: [StockSageStockScreener.Row] { news.startedAt == nil ? rows : news.rows }
    private var processedCount: Int { news.rows.filter { news.observations[$0.symbol] != nil }.count }
    private var headlines: [Headline] {
        news.rows.flatMap { row in
            (news.observations[row.symbol]?.items ?? []).map { Headline(symbol: row.symbol, item: $0) }
        }.sorted {
            if $0.item.date != $1.item.date { return $0.item.date > $1.item.date }
            if $0.symbol != $1.symbol { return $0.symbol < $1.symbol }
            return $0.item.id < $1.item.id
        }
    }
    private var progressText: String {
        "\(processedCount) of \(coverageRows.count) matched symbols processed · \(headlines.count) captured excerpts"
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Keep headings inside unlabeled GroupBoxes for native accessibility traversal.
                HStack {
                    Text("Matched news").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Open matched news") { showingNews = true }
                        .accessibilityIdentifier("screener.news.open")
                    if news.isLoading { ProgressView().controlSize(.small) }
                }
                Text("News for all \(rows.count) matching symbols. These matches are not trade-qualified setups.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(progressText).font(.callout).monospacedDigit()
                    .accessibilityIdentifier("screener.news.progress")
                DisclosureGroup("News capture scope") {
                    Text("Nothing is fetched until you choose Load matched news. Every symbol matching your financial filters and search is included; pages limit display only. Table sorting and showing excluded listings do not change this set.")
                        .font(.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }.font(.callout)
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: selectionID) { _, _ in clear() }
        .onChange(of: ratiosAt) { _, _ in clear() }
        .onChange(of: isReloading) { _, loading in if loading { clear() } }
        .onDisappear { stopLoading() }
        .sheet(isPresented: $showingNews, onDismiss: { stopLoading() }) {
            newsSheet
        }
    }

    private func stopLoading() { loadTask?.cancel(); loadTask = nil; if news.isLoading { news.cancel() } }
    private func clear() { stopLoading(); news.clear(); page = 0 }

    private var newsSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Matched news").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { stopLoading(); showingNews = false }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("screener.news.done")
            }
            Text("Up to five excerpts per matched ticker from the previous seven days. Manual sample, not a live feed or complete news census.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Load matched news") {
                    loadTask?.cancel()
                    page = 0
                    let selected = rows
                    loadTask = Task {
                        guard !Task.isCancelled else { return }
                        await news.load(rows: selected)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(rows.isEmpty || isReloading || news.isLoading)
                .accessibilityIdentifier("screener.news.load")
                if news.isLoading {
                    ProgressView().controlSize(.small)
                    Button("Stop loading") { stopLoading() }.accessibilityIdentifier("screener.news.cancel")
                }
                if news.startedAt != nil {
                    Button("Clear") { clear() }.accessibilityIdentifier("screener.news.clear")
                }
            }
            Text(progressText).font(.callout).monospacedDigit().accessibilityIdentifier("screener.news.sheetProgress")
            Text(news.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("screener.news.status")
            Picker("News view", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("screener.news.tab")
            pagedContent
            Text("Closing stops an unfinished load. Captured results remain in memory until cleared or the app closes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(minWidth: 520, idealWidth: 840, minHeight: 660, idealHeight: 760)
        .background(DS.Palette.bgTop)
        .onChange(of: tab) { _, _ in page = 0 }
    }

    private var pagedContent: some View {
        let items = headlines
        let covered = coverageRows
        let count = tab == .headlines ? items.count : covered.count
        let last = max(0, (count - 1) / pageSize)
        let current = min(page, last)
        let start = current * pageSize
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(count == 0 ? "No rows" : "\(start + 1)–\(min(start + pageSize, count)) of \(count)").monospacedDigit()
                Spacer()
                Button("Previous") { page = max(0, current - 1) }.disabled(current == 0)
                    .accessibilityIdentifier("screener.news.previous")
                Text("Page \(current + 1) of \(last + 1)").monospacedDigit()
                Button("Next") { page = current + 1 }.disabled(current >= last)
                    .accessibilityIdentifier("screener.news.next")
            }.font(.callout)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    DisclosureGroup("Capture details and limits") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Financial screen captured \(ratiosAt.formatted(date: .abbreviated, time: .standard)). Changing its financial filters or search, or reloading ratios, clears this news capture.")
                            if let started = news.startedAt {
                                Text("Load started \(started.formatted(date: .abbreviated, time: .standard)). Individual provider check times appear in Coverage.")
                            }
                            Text("Every matched symbol is included; pages limit display only. Favorable and adverse stories are retained without a sentiment filter. Matches are not trade-qualified setups. No model assessment or trade starts here.")
                        }.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if count == 0 {
                        Text(tab == .headlines
                            ? "No usable excerpts are captured yet. Check Coverage for pending, unavailable and empty results; absence here does not mean no news."
                            : "No symbols match the current financial filters and search.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if tab == .headlines {
                        ForEach(Array(items.dropFirst(start).prefix(pageSize))) { headline in headlineRow(headline) }
                    } else {
                        ForEach(Array(covered.dropFirst(start).prefix(pageSize))) { row in coverageRow(row) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.frame(minHeight: 180)
        }.frame(maxHeight: .infinity)
    }

    private func headlineRow(_ headline: Headline) -> some View {
        let item = headline.item
        return GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Text(headline.symbol).font(.headline)
                Text(verbatim: item.title).font(.callout.bold()).fixedSize(horizontal: false, vertical: true)
                Text("Article date: \(item.date.formatted(date: .abbreviated, time: .standard)) · \(item.source)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let published = item.publicationTime {
                    Text("Provider publication timestamp: \(published)").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let updated = item.updatedTime {
                    Text("Provider update timestamp: \(updated)").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: item.snippet).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let insight = item.insight, !insight.isEmpty {
                    Text("Provider commentary: \(insight)").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let checked = news.observations[headline.symbol]?.latestCheckAt {
                    Text("Provider check: \(checked.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let link = item.link, link.scheme?.lowercased() == "https",
                   link.host != nil, link.user == nil, link.password == nil {
                    Link("Read source", destination: link).font(.callout)
                }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }.accessibilityIdentifier("screener.news.headline.\(headline.symbol)")
    }

    private func coverageRow(_ row: StockSageStockScreener.Row) -> some View {
        let observation = news.observations[row.symbol]
        return GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Text("\(row.symbol) · \(coverageLabel(observation))").font(.headline)
                Text(row.name).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(observation?.summary ?? (news.isLoading
                    ? "Pending or in progress; no provider check has been recorded yet."
                    : "Not checked in this capture. Load matched news to request a recent sample."))
                    .font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("screener.news.coverage.\(row.symbol)")
    }

    private func coverageLabel(_ observation: StockSageNewsService.Observation?) -> String {
        guard let observation else { return news.isLoading ? "Pending" : "Not checked" }
        if observation.withholdingReason != nil { return "Withheld" }
        if !observation.items.isEmpty { return "\(observation.items.count) \(observation.items.count == 1 ? "excerpt" : "excerpts")" }
        guard let last = observation.attempts.last else { return "Not checked" }
        switch last.status {
        case .answered: return "No usable excerpts"
        case .partial: return "Partial · no usable excerpts"
        case .unavailable: return "Unavailable"
        case .notChecked: return "Not checked"
        }
    }
}
#endif
