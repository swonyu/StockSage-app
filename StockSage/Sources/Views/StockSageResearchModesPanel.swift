import SwiftUI

struct StockSageResearchModesPanel: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject var research = StockSageHorizonResearch.shared
    @ObservedObject private var sameDay = StockSageSameDayResearch.shared
    enum ResultFilter: String, CaseIterable {
        case all = "All checks"
        case topBuys = "Strict comparison picks"
        case buys = "Buy / Strong Buy"
        case hold = "Hold"
        case avoid = "Avoid"
        case incomplete = "Incomplete"
        case unchecked = "Not checked"
    }
    struct Presentation {
        var horizon: StockSageHorizonResearch.Horizon
        var search = ""
        var selected: String?
        #if os(macOS)
        var filter: ResultFilter = .all
        #else
        var filter: ResultFilter = .topBuys
        #endif
        init(horizon: StockSageHorizonResearch.Horizon? = nil) {
            self.horizon = horizon ?? (StockSageStore.isRunningTests ? .week : Self.restore(from: .standard))
        }
        static func restore(from defaults: UserDefaults) -> StockSageHorizonResearch.Horizon {
            defaults.string(forKey: "stocksage.research.horizon") == "fortnight" ? .fortnight : .week
        }
        static func save(_ horizon: StockSageHorizonResearch.Horizon, to defaults: UserDefaults) {
            defaults.set(horizon == .week ? "week" : "fortnight", forKey: "stocksage.research.horizon")
        }
    }
    @Binding var presentation: Presentation
    var showHorizon: ((StockSageHorizonResearch.Horizon) -> Void)? = nil
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

    private func freshness(_ scan: StockSageHorizonResearch.Scan) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { tick in
            VStack(alignment: .leading, spacing: 4) {
                if scan.retainsEarlierResults {
                    Label("Earlier results retained · latest attempt did not refresh them", systemImage: "exclamationmark.clock")
                        .foregroundStyle(.orange).font(.callout.weight(.semibold))
                }
                if let requested = scan.at {
                    Text("Displayed run requested: \(requested.formatted(date: .abbreviated, time: .standard)) · \(StockSageResearchFreshness.age(requested, at: tick.date))")
                }
                if let last = scan.lastAttemptAt {
                    Text("Latest attempt: \(last.formatted(date: .abbreviated, time: .standard))")
                }
                if let finished = scan.attemptFinishedAt, scan.completedAt == nil || scan.retainsEarlierResults {
                    Text("Latest attempt ended: \(finished.formatted(date: .abbreviated, time: .standard))")
                }
                if let completed = scan.completedAt {
                    Text("Displayed run completed: \(completed.formatted(date: .abbreviated, time: .standard)) · \(StockSageResearchFreshness.age(completed, at: tick.date))")
                }
                if let latest = scan.results.values.map(\.at).max() {
                    if let earliest = scan.results.values.map(\.at).min(), earliest < latest {
                        Text("Earliest result: \(earliest.formatted(date: .abbreviated, time: .standard)) · \(StockSageResearchFreshness.age(earliest, at: tick.date))")
                        Text("Results have different capture times. Completing this run does not refresh earlier checks.")
                    }
                    Text("Latest result: \(latest.formatted(date: .abbreviated, time: .standard)) · \(StockSageResearchFreshness.age(latest, at: tick.date))")
                }
                if let news = scan.results.values.compactMap(\.newsCheckedAt).max() {
                    Text("Latest news check: \(news.formatted(date: .abbreviated, time: .standard)) · \(StockSageResearchFreshness.age(news, at: tick.date)). Check status and publication dates in each result.")
                }
                if let previous = scan.previousCompletedAt, let requested = scan.at, !scan.retainsEarlierResults {
                    Text("Previous run completed \(StockSageResearchFreshness.age(previous, at: requested)) when this run began.")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        manual(presentation.horizon)
        .onChange(of: presentation.horizon) { _, horizon in
            selected = nil; search = ""
            #if os(macOS)
            presentation.filter = .all
            #endif
        }
    }

    private var visibleListings: [StockSageHorizonResearch.Listing] {
        let scan = research.scans[presentation.horizon] ?? .init()
        return Self.filteredListings(scan, search: search, filter: presentation.filter)
    }

    static func filteredListings(_ scan: StockSageHorizonResearch.Scan, search: String,
                                 filter: ResultFilter = .topBuys) -> [StockSageHorizonResearch.Listing] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (filter == .topBuys ? scan.topBuys : scan.listings).filter { item in
            guard query.isEmpty || item.ticker.localizedCaseInsensitiveContains(query)
                || item.name.localizedCaseInsensitiveContains(query) else { return false }
            let result = scan.results[item.ticker]
            switch filter {
            case .all, .topBuys: return true
            case .buys: return isBuy(result?.verdict?.action)
            case .hold: return result?.verdict?.action == .hold
            case .avoid: return result?.verdict?.action == .avoid
            case .incomplete: return result != nil && result?.verdict == nil
            case .unchecked: return result == nil
            }
        }
    }

    var detailPresented: Binding<Bool> {
        Binding(get: { selected.map { symbol in visibleListings.contains { $0.ticker == symbol } } ?? false },
                set: { if !$0 { selected = nil } })
    }

    func openRankedDetail(_ symbol: String) {
        guard research.scans[presentation.horizon]?.listings.contains(where: { $0.ticker == symbol }) == true else { return }
        presentation.filter = .all
        search = ""
        selected = symbol
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

    private func manual(_ horizon: StockSageHorizonResearch.Horizon) -> some View {
        let scan = research.scans[horizon] ?? .init()
        let rows = visibleListings
        let isRunning = research.isRunning(horizon)
        let remaining = research.remainingListings(horizon).count
        // A blocked preflight can have no request date or listings but still has useful status.
        // Suppress only the untouched model's repeated "Press Run" instruction.
        let isUntouched = !isRunning && scan.at == nil && scan.listings.isEmpty
            && scan.results.isEmpty && scan.selection == nil
            && scan.status == StockSageHorizonResearch.Scan().status
        let controls = VStack(alignment: .leading, spacing: 12) {
            Self.manualControls(horizon: horizon, hasRun: scan.at != nil, running: isRunning ? horizon : research.running,
                run: { if research.start(horizon, store: store) { selected = nil } }, stop: { research.stop() })
                .disabled(sameDay.isRunning)
            if scan.needsSaving && research.running == nil {
                Button("Retry save", systemImage: "square.and.arrow.down") { research.retrySave(horizon) }
                    .help("Save the same completed research and dates without another model request.")
            }
            #if os(macOS)
            if research.canResumeBoth {
                Button("Resume both horizons", systemImage: "rectangle.split.2x1") {
                    if research.resumeRemainingBoth(store: store) {
                        selected = nil; search = ""; presentation.filter = .all
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(research.running != nil || sameDay.isRunning)
                .accessibilityIdentifier("research.resumeBoth")
                .help("Preserve completed checks. Retain or complete each stock’s 1–7 check before its pending 7–14 check, carrying its usable prior opinion as historical context.")
            }
            #endif
            if remaining > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Resume \(remaining) remaining", systemImage: "play.fill") {
                        if research.resumeRemaining(horizon, store: store) {
                            selected = nil; search = ""; presentation.filter = .all
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sameDay.isRunning)
                    .accessibilityIdentifier("research.resume")
                    Text("Original checked results keep their captured dates. Remaining listings receive fresh evidence; the resumed run contains different capture times.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !research.incompleteListings(horizon).isEmpty {
                Button("Retry \(research.incompleteListings(horizon).count) incomplete", systemImage: "arrow.clockwise") {
                    if research.retryIncomplete(horizon, store: store) {
                        selected = nil; search = ""; presentation.filter = .topBuys
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sameDay.isRunning)
                .accessibilityIdentifier("research.retryIncomplete")
                .help("Refresh only incomplete checks, retain the other opinions, then compare the entire eligible pool again.")
            }
            if research.canRetryTopFive(horizon) {
                Button("Retry strict comparison", systemImage: "arrow.clockwise") {
                    if research.retryTopFive(horizon, store: store) {
                        selected = nil; search = ""; presentation.filter = .topBuys
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sameDay.isRunning)
                .accessibilityIdentifier("research.retryTopFive")
                .help("Retry the strict model comparison using the original checks. The saved deterministic Top 5 does not change; no new stock scan.")
            }
            if let running = research.running, running != horizon {
                Self.runningScanControls(running: running,
                    show: { if let showHorizon { showHorizon(running) } else { presentation.horizon = running } },
                    stop: { research.stop() })
            }
            #if os(macOS)
            HStack(spacing: 12) {
                bothHorizonsButton
                StockSageResearchHistoryButton(store: store)
            }
            #else
            bothHorizonsButton
            StockSageResearchHistoryButton(store: store)
            #endif
            #if os(macOS)
            scanSummary(scan, isRunning: isRunning)
            #else
            if !isUntouched { scanSummary(scan, isRunning: isRunning) }
            #endif
        }
        // Table, search and inspector share the same visible-row projection.
        .onChange(of: rows.map(\.ticker)) { _, visible in
            if let selected, !visible.contains(selected) { self.selected = nil }
        }
        let resultsHeader = VStack(alignment: .leading, spacing: 8) {
            #if os(macOS)
            HStack {
                Text(presentation.filter == .topBuys ? "Strict comparison picks" : "Research results")
                    .font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(rows.count) shown").font(.caption).foregroundStyle(.secondary)
            }
            if presentation.filter == .topBuys {
                if scan.qualificationPolicyVersion == 1 {
                Text("Strict screen v1: a cited recent news or public insider filing; close above SMA20 and positive horizon return; recent volume at least 1.5× its preceding average; observed stop/target with at least 2:1 reward/risk and bounded ATR distances; a fresh outside-window earnings date. These are unvalidated screening assumptions, not proven return probabilities. Unqualified opinions remain in All checks.")
            } else if !scan.listings.isEmpty {
                Text("This saved run predates the strict screen. Run fresh research to apply it; original opinions and rankings remain unchanged.")
            }
            Text(StockSageHorizonResearch.topBuyRankingNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).help(StockSageHorizonResearch.topBuyRankingNote)
            }
            resultFilters
            #else
            Text(presentation.filter == .topBuys ? "Strict comparison picks" : "Research results")
                .font(.headline).accessibilityAddTraits(.isHeader)
            Text(StockSageHorizonResearch.topBuyRankingNote)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            resultFilters
            Text("\(rows.count) shown · select a stock for evidence and scenario price levels")
                .font(.caption).foregroundStyle(.secondary)
            #endif
        }
        let content = VStack(alignment: .leading, spacing: 20) {
            controls
            if !isRunning, let ranked = scan.rankedTopFive(horizon: horizon, now: Date()) {
                if let clock = scan.rankingScoredAt {
                    Text("Ranking captured \(clock.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                StockSageTopFiveRankingSection(result: ranked, openDetails: openRankedDetail)
            } else if !isRunning, scan.completedAt != nil {
                Label(scan.deterministicRankingStatus, systemImage: "clock.arrow.circlepath")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !scan.listings.isEmpty {
                Divider()
                resultsHeader
            }
            if rows.isEmpty {
                emptyResults(scan, isRunning: isRunning)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else {
                #if os(macOS)
                // The primary ranked five stays above the optional full evidence table.
                // The table keeps its own bounded scroll range for up to 1,500 checks.
                resultsTable(rows, scan: scan, horizon: horizon).frame(height: 360)
                #else
                phoneResults(rows, scan: scan, horizon: horizon)
                #endif
            }
            Divider()
            researchFooter(scan)
        }.frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        return ScrollView { content.padding(24) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #else
        // The phone workspace owns the single page scroll view.
        return content
            .tint(DS.Palette.accentText)
            .sheet(isPresented: detailPresented) { selectedDetail }
        #endif
    }

    private var bothHorizonsButton: some View {
        Button("Research both horizons", systemImage: "rectangle.split.2x1") {
            if research.start(StockSageHorizonResearch.Horizon.allCases, store: store) { selected = nil }
        }
        .disabled(research.running != nil || sameDay.isRunning)
        .help("Gather fresh evidence once per stock. Assess 1–7 days first, then 7–14 days with the matching prior opinion when available. Each horizon has separate results and qualification checks. Both completed runs are saved. No orders.")
    }

    private func scanSummary(_ scan: StockSageHorizonResearch.Scan, isRunning: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Self.scanStatus(scan.status, isRunning: isRunning)
            #if os(macOS)
            if research.runningHorizons.count > 1 {
                ForEach(StockSageHorizonResearch.Horizon.allCases) { horizon in
                    if let paired = research.scans[horizon], !paired.listings.isEmpty {
                        Text("\(horizon.rawValue): \(paired.results.count)/\(paired.listings.count) checks finished")
                            .font(.caption).monospacedDigit()
                    }
                }
                Text("Each stock retains or completes its 1–7 check before its 7–14 check. Counts include incomplete opinions.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
            if let selection = scan.selection {
                Text(selection.summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isRunning, !research.activeSymbols.isEmpty {
                Text("\(research.activeDescription) · daily history, news and AI assessment").font(.caption).monospaced()
                    .help(research.activeSymbols.sorted().joined(separator: ", "))
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel("\(research.activeSymbols.sorted().joined(separator: ", ")) research in progress")
            } else if isRunning, !scan.listings.isEmpty, scan.results.count == scan.listings.count {
                Text("Comparing completed research").font(.caption)
                ProgressView().progressViewStyle(.linear).accessibilityLabel("Strict comparison in progress")
            }
            if !scan.listings.isEmpty {
                Self.scanProgress(checked: scan.results.count, total: scan.listings.count,
                    buys: scan.results.values.filter { Self.isBuy($0.verdict?.action) }.count,
                    incomplete: scan.results.values.filter { $0.verdict == nil }.count,
                    qualified: scan.qualificationPolicyVersion == 1 ? scan.listings.filter { scan.isEligible($0.ticker) }.count : nil)
            }
            DisclosureGroup("Run dates & evidence freshness") { freshness(scan).padding(.top, 6) }
                .font(.caption)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceAlt, in: .rect(cornerRadius: 10))
    }

    private func emptyResults(_ scan: StockSageHorizonResearch.Scan, isRunning: Bool) -> some View {
        let empty = Self.emptyState(for: scan, isRunning: isRunning, search: search, filter: presentation.filter)
        return ContentUnavailableView {
            Label(empty.title, systemImage: scan.listings.isEmpty ? "doc.text.magnifyingglass" : "line.3.horizontal.decrease.circle")
        } description: {
            Text(empty.detail).frame(maxWidth: 380)
        } actions: {
            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Clear search") { search = ""; selected = nil }
            } else if isRunning {
                ProgressView().controlSize(.small).accessibilityLabel("Research scan in progress")
            }
            if presentation.filter != .all {
                Button("Show all checks") { presentation.filter = .all; search = ""; selected = nil }
            }
        }
    }

    private func researchFooter(_ scan: StockSageHorizonResearch.Scan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
            Text("All checks preserve the scan’s original activity order. Strict comparison picks are selected separately after every listing has been checked.")
            Text("The scan universe is selected by observed traded dollars (volume × VWAP) from Massive’s dated US market summary, highest activity first. The pool combines Nasdaq-listed common stocks with S&P 500 reported constituents on supported US listing exchanges, capped at 1,500 unique tickers. S&P membership is retrieved for each manual run from datasets/DataHub, sourced from Wikipedia; it has no official effective date. Each run retains that source, retrieval time and hash. Only active US-listed common stocks with confirmed USD currency qualify; no ETFs, other listing types or OTC securities. Missing observations are not filled alphabetically. Available model workers research this selected list concurrently.")
            Text(StockSageHorizonResearch.topBuyRankingNote)
            if let ranking = scan.ranking {
                Text("\(ranking.candidateSymbols.count) eligible candidates compared in \(ranking.rounds.count) rounds. \(ranking.method).")
                Text("\(ranking.rounds.reduce(0) { $0 + $1.omittedCitedFacts.values.reduce(0, +) }) cited-record omissions across comparison rounds. Cases, risks, capture dates and coverage were retained whole; full captured research remains in each selected stock’s details.")
            }
            Text("Each horizon has its own evidence window and scenario. Strict scenarios use recent lows and prior resistance highs; older runs retain their original ATR scenarios. Model opinions and screening rules are unvalidated.")
            if let selection = scan.selection {
                Text("\(selection.directoryCount) active US directory entries considered. Selection requested \(selection.requestedAt.formatted(date: .abbreviated, time: .shortened)). \(selection.summary)")
            }
            Text("Completed runs are saved for 7- or 14-trading-day review. Active scans finish while the app is open. A new run replaces this horizon’s visible results. No paper positions or real orders are created.")
            Text("Completed checks are kept after relaunch. Resume checks only the remaining listings from an interrupted run and retains the original results with their captured dates. Retry strict comparison compares the original evidence again; it does not refresh prices or news or change the saved deterministic Top 5. Retry incomplete refreshes only failed checks before comparing the entire eligible pool. Saved prediction receipts retain their original review records.")
            Text("Reference prices are completed split-adjusted daily closes, not current executable quotes. Neither horizon has an independently validated profitable strategy.")
            if let at = scan.at { Text("Run requested \(at.formatted(date: .abbreviated, time: .shortened))") }
            let incomplete = scan.listings.filter { scan.results[$0.ticker] != nil && scan.results[$0.ticker]?.verdict == nil }
            if !incomplete.isEmpty {
                DisclosureGroup("Incomplete checks (\(incomplete.count))") {
                    ForEach(incomplete) { item in
                        if let result = scan.results[item.ticker] {
                            let note = Self.notePresentation(result.note)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.ticker).fontWeight(.semibold)
                                Text(note.explanation)
                                if let diagnostics = note.diagnostics {
                                    Text(verbatim: diagnostics).font(.caption.monospaced())
                                }
                            }.fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }

    @ViewBuilder private var resultFilters: some View {
        let field = Self.searchField(search: $presentation.search, filter: presentation.filter)
        let choices = Picker("Show", selection: $presentation.filter) {
            ForEach(ResultFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        let picker = choices.pickerStyle(.menu)
            .accessibilityLabel("Research result filter")
            .accessibilityIdentifier("research.filter")
            .help("Incomplete: checked without a verified opinion. Not checked: includes queued listings.")
        let regular = ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { field.frame(minWidth: 200); picker.fixedSize() }
            VStack(alignment: .leading, spacing: DS.Space.sm) { field; picker }
        }.controlSize(.large)
        #if os(iOS)
        if dynamicTypeSize.isAccessibilitySize {
            // UIKit's selected-value menu button can clip a multiline title. Keep the
            // full selection in wrapping SwiftUI text and the native menu label short.
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                field
                Text(presentation.filter.rawValue)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("research.filter.selection")
                Menu {
                    choices.pickerStyle(.inline)
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease")
                }
                .accessibilityLabel("Research result filter")
                .accessibilityValue(presentation.filter.rawValue)
                .accessibilityIdentifier("research.filter")
                .help("Incomplete: checked without a verified opinion. Not checked: includes queued listings.")
            }.controlSize(.large)
        } else {
            regular
        }
        #else
        regular
        #endif
    }

    #if os(macOS)
    private func resultsTable(_ rows: [StockSageHorizonResearch.Listing], scan: StockSageHorizonResearch.Scan,
                              horizon: StockSageHorizonResearch.Horizon) -> some View {
        StockSageResearchTable(rows: rows, selection: $presentation.selected) { item, column in
            AnyView(resultCell(item, column: column, scan: scan, horizon: horizon))
        }
    }

    @ViewBuilder private func resultCell(_ item: StockSageHorizonResearch.Listing, column: Int,
                                        scan: StockSageHorizonResearch.Scan,
                                        horizon: StockSageHorizonResearch.Horizon) -> some View {
        switch column {
        case 0:
            VStack(alignment: .leading, spacing: 4) {
                Text(item.ticker).fontWeight(.semibold)
                Text(item.name).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            }.help("\(item.name) · \(item.type ?? "instrument type unconfirmed")\n\(scan.selection?.detail(for: item.ticker) ?? "Selection activity not recorded.")")
        case 1:
            Text(Self.resultLabel(item.ticker, research: research, scan: scan, horizon: horizon))
                .foregroundStyle(Self.isBuy(scan.results[item.ticker]?.verdict?.action) ? DS.Palette.successSoft : .secondary)
                .help(scan.results[item.ticker]?.note ?? "This listing has not been checked.")
        case 2:
            Text(Self.coverageSummary(scan.results[item.ticker]?.coverage ?? []))
                .font(.caption).foregroundStyle(.secondary)
                .help(scan.results[item.ticker]?.coverage.map(\.detail).joined(separator: "\n") ?? "Coverage not captured")
        case 3:
            let result = scan.results[item.ticker]
            VStack(alignment: .leading, spacing: 3) {
                Text("Entry \(Self.price(result?.levels?.entry))").monospacedDigit().lineLimit(1)
                    .accessibilityLabel("Buy entry reference \(Self.price(result?.levels?.entry))")
                if let close = result?.referenceClose {
                    Text("Close \(Self.price(close.value)) · \(close.at.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityLabel("Daily close reference \(Self.price(close.value)), \(close.at.formatted(date: .abbreviated, time: .omitted))")
                } else {
                    Text("Close —").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Daily close reference not available")
                }
            }.help(result?.levels.map {
                "Buy entry reference from \($0.at.formatted(date: .abbreviated, time: .omitted)); a captured scenario, not a live quote or executable order. \($0.basis)"
            } ?? "No valid buy-entry scenario is available. The dated daily close is a separate reference; select the stock for the evidence and reason.")
        case 4:
            Text(Self.price(scan.results[item.ticker]?.levels?.stop)).monospacedDigit()
                .accessibilityLabel("Scenario stop \(Self.price(scan.results[item.ticker]?.levels?.stop))")
                .help(scan.results[item.ticker]?.levels?.basis ?? "No calculated scenario. Select the stock for the evidence and reason.")
        default:
            Text(Self.price(scan.results[item.ticker]?.levels?.target)).monospacedDigit()
                .accessibilityLabel("Scenario target \(Self.price(scan.results[item.ticker]?.levels?.target))")
                .help(scan.results[item.ticker]?.levels?.basis ?? "No calculated scenario. Select the stock for the evidence and reason.")
        }
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
                        Text(Self.coverageSummary(scan.results[item.ticker]?.coverage ?? []))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                    .accessibilityIdentifier("research.result.\(item.ticker)")
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
                    Self.resultDetail(item, result: scan.results[selected], change: scan.changes[selected])
                        #if os(macOS)
                        .id("\(presentation.horizon.rawValue)-\(selected)")
                        #endif
                }.padding(20)
            }
            #if os(macOS)
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        Text("Captured research").font(.headline)
                        Spacer()
                        Button("Close details", systemImage: "xmark.circle.fill") { self.selected = nil }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .help("Close details")
                    }
                    .padding(16)
                }
                .environment(\.colorScheme, .dark)
                .foregroundStyle(DS.Palette.textPrimary)
            #else
            NavigationStack {
                detail.background(DS.Palette.bgTop)
                    .navigationTitle(item.ticker).navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(DS.Palette.bgTop, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Close details", systemImage: "xmark") { self.selected = nil }
                        }
                    }
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

    static func scanProgress(checked: Int, total: Int, buys: Int, incomplete: Int, qualified: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ProgressView(value: Double(checked), total: Double(max(1, total))) {
                Text("\(checked)/\(total) checks finished, including incomplete")
                    .fixedSize(horizontal: false, vertical: true)
            }.accessibilityValue("\(checked) of \(total) checks finished, including \(incomplete) incomplete opinions")
            if let qualified {
                Text("\(qualified) passed the strict screen").fontWeight(.semibold)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.lg) {
                    Text("\(buys) Buy / Strong Buy found").fixedSize()
                    Text("\(incomplete) incomplete").fixedSize()
                    Text("\(max(0, total - checked)) not checked").fixedSize()
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("\(buys) Buy / Strong Buy found")
                    Text("\(incomplete) incomplete")
                    Text("\(max(0, total - checked)) not checked")
                }
            }
        }.font(.caption).monospacedDigit()
            .help("Checks finished includes incomplete opinions; it does not mean every answer passed validation.")
    }

    static func manualControls(horizon: StockSageHorizonResearch.Horizon, hasRun: Bool,
                               running: StockSageHorizonResearch.Horizon?,
                               run: @escaping () -> Void, stop: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            adaptiveActionRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text(horizon.rawValue).font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    #if os(macOS)
                    Text("Top 5 per horizon · up to \(StockSageHorizonResearch.scanLimit) Nasdaq + S&P 500 stocks · manual research")
                        .font(.caption).foregroundStyle(.secondary)
                    #else
                    Text("Top 5 ranked stocks · qualification shown separately")
                        .font(.caption).foregroundStyle(.secondary)
                    #endif
                }
            } actions: {
                if running == horizon {
                    Button("Stop scan", systemImage: "stop.fill", action: stop)
                        .accessibilityLabel("Stop \(horizon.rawValue) research scan")
                        .help("Stop this horizon’s research scan. Collected results remain available.")
                } else {
                    Button(hasRun ? "Run again" : "Run \(StockSageHorizonResearch.scanLimit)-stock scan", systemImage: "play.fill", action: run)
                        .buttonStyle(.borderedProminent).tint(DS.Palette.accent)
                        #if os(macOS)
                        .buttonBorderShape(.capsule)
                        #endif
                        .controlSize(.large)
                        .accessibilityLabel("Run \(horizon.rawValue) research scan")
                        .disabled(running != nil)
                        .help("Research once; no orders. A new run replaces this horizon’s visible results. Completed runs stay in saved research.")
                }
            }
            #if os(iOS)
            Text("One-time research across up to \(StockSageHorizonResearch.scanLimit) unique Nasdaq + S&P 500 common stocks. Completed runs are saved for 7- or 14-trading-day review. Active scans finish while the app is open.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
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

    /// Called only when the selected filter has no visible rows.
    static func emptyState(for scan: StockSageHorizonResearch.Scan, isRunning: Bool, search: String = "",
                           filter: ResultFilter = .topBuys) -> (title: String, detail: String) {
        if filter != .topBuys, !scan.listings.isEmpty {
            return ("No matching checks", "No checks match \(filter.rawValue) and the current search. Show all checks to see the collected and queued listings.")
        }
        if !scan.topBuys.isEmpty, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ("No matching strict picks", "This search includes only the strict model comparison picks. The deterministic Top 5 above is separate. Clear the search to see the strict shortlist.")
        }
        if !scan.listings.isEmpty {
            if isRunning {
                if scan.isComparing {
                    return ("Comparing strict picks", "All checks are complete. The model is comparing every eligible Buy / Strong Buy using the captured evidence. Progress is shown above.")
                }
                return ("Strict picks after the full scan", "Every listing is checked before the model compares the eligible Buy / Strong Buy research. All checks remain available while this runs.")
            }
            if let failure = scan.rankingFailure {
                return ("Strict comparison unavailable", failure + " Collected checks remain available. The deterministic ranking is separate; no strict picks were substituted.")
            }
            if scan.results.count < scan.listings.count {
                return ("Scan stopped before comparison", "Strict comparison needs the complete scan. Collected checks remain available; run again to finish research and compare candidates.")
            }
            if scan.qualificationPolicyVersion == 1 {
                return ("No stocks passed the strict screen", "The checks are complete. No Buy / Strong Buy met every requirement for this horizon. All checks retain the original opinions, insider evidence and exclusion reasons; no picks were forced.")
            }
            return ("No Buy / Strong Buy results", "The completed checks contain no eligible Buy / Strong Buy opinions. See all checks and coverage for the collected evidence and any incomplete opinions.")
        }
        if isRunning {
            return ("Waiting for scan results", "The current status is shown above.")
        }
        if scan.at != nil {
            return ("No results collected", "See the scan status above for details. You can run again when ready; no orders were created.")
        }
        return ("Your research starts here", filter == .topBuys
            ? "Run this horizon for the deterministic Top 5 and a separate strict comparison of eligible Buy / Strong Buy opinions. Research is unvalidated; these are not forecasts."
            : "Run this horizon to see every check, including Hold and Avoid. Select Strict comparison picks for the separate model shortlist. Research is unvalidated.")
    }

    static func resultLabel(_ symbol: String, research: StockSageHorizonResearch,
                            scan: StockSageHorizonResearch.Scan,
                            horizon: StockSageHorizonResearch.Horizon) -> String {
        if let result = scan.results[symbol] { return result.verdict?.action.rawValue ?? "Incomplete" }
        if research.isRunning(horizon), research.activeSymbols.contains(symbol) { return "Checking…" }
        return research.isRunning(horizon) && !research.activeSymbols.isEmpty ? "Queued" : "Not checked"
    }

    static func searchField(search: Binding<String>, filter: ResultFilter = .topBuys) -> some View {
        TextField(filter == .topBuys ? "Find in strict comparison picks" : "Find a symbol or company", text: search)
            .textFieldStyle(.roundedBorder)
            #if os(iOS)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            #endif
            .accessibilityLabel(filter == .topBuys ? "Search strict comparison picks by symbol or company" : "Filter research by symbol or company")
            .accessibilityIdentifier("research.search")
            .help(filter == .topBuys ? "Search narrows only the strict model comparison picks. The deterministic Top 5 above is separate." : "Search the selected checks by symbol or company.")
            .controlSize(.large)
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
                              result: StockSageHorizonResearch.Result?, change: String? = nil) -> some View {
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
                TimelineView(.periodic(from: .now, by: 30)) { tick in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Research checked: \(result.at.formatted(date: .abbreviated, time: .standard)) · \(StockSageResearchFreshness.age(result.at, at: tick.date))")
                        if let checked = result.newsCheckedAt {
                            Text("News checked: \(checked.formatted(date: .abbreviated, time: .standard)) · \(StockSageResearchFreshness.age(checked, at: tick.date))")
                        } else { Text("News check time unavailable for this result") }
                        if let published = result.newestNewsAt {
                            Text("Newest retained article: \(published.formatted(date: .abbreviated, time: .standard)) · \(StockSageResearchFreshness.age(published, at: tick.date))")
                        } else { Text("No usable article retained; this is not proof of no news") }
                        if let summary = result.newsCheckSummary { Text(summary) }
                        if let change { Text("Since previous run: " + change) }
                    }.font(.caption).foregroundStyle(.secondary)
                }

                if let verdict = result.verdict {
                    Text(verdict.action.rawValue).font(.title3.weight(.semibold))
                        .foregroundStyle(isBuy(verdict.action) ? DS.Palette.successSoft : .primary)
                    Text(verdict.reason).font(.body).lineSpacing(3)
                    Text("Risk: \(verdict.risk)").foregroundStyle(.secondary)
                }
                if let priorNote = result.priorAssessmentNote {
                    Label(priorNote, systemImage: "clock.arrow.circlepath")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let prior = result.priorAssessment {
                    DisclosureGroup("Prior 1–7 assessment · " + prior.action) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Saved earlier model opinion. Its delivery status is recorded above. It is separate from the current evidence and does not transfer its qualification to 7–14 days.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: prior.reason).font(.callout)
                            Text("Prior risk: " + prior.risk).font(.callout)
                            Text("Captured: \(prior.sourceCaptureAt.formatted(date: .abbreviated, time: .standard))")
                            Text("Original run requested: \(prior.sourceScanAt.formatted(date: .abbreviated, time: .standard))")
                            Text("Model: " + prior.model)
                            if let report = prior.qualityReport {
                                let quality = StockSageResearchQualityPresentation.assessed(report, captured: nil)
                                Text("Prior quality: " + quality.badge).font(.callout.weight(.semibold))
                                Text(quality.explanation)
                                ForEach(Array(quality.findingDescriptions.enumerated()), id: \.offset) { _, finding in
                                    Text(finding)
                                }
                                if !quality.uncitedInsiderIDs.isEmpty {
                                    Text("Uncited prior insider references: " + quality.uncitedInsiderIDs.joined(separator: ", "))
                                }
                            } else { Text("Prior evidence checks were not recorded.") }
                            Text(prior.strictQualified.map { $0 ? "Prior strict screen: passed" : "Prior strict screen: did not pass" }
                                ?? "Prior strict screen: not recorded")
                                .font(.callout.weight(.semibold))
                            ForEach(Array(prior.strictFailureReasons.enumerated()), id: \.offset) { _, reason in
                                Text(reason)
                            }
                            if let id = prior.diagnosticID {
                                Text("Prior diagnostic reference: " + id.uuidString).font(.caption.monospaced())
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let qualification = result.qualification {
                    Text(qualification.isQualified ? "Passed strict screen" : "Did not pass strict screen")
                        .font(.headline)
                    ForEach(Array(qualification.reasons.enumerated()), id: \.offset) { _, reason in
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let close = result.referenceClose {
                    Text("Daily close: \(price(close.value)) · \(close.at.formatted(date: .abbreviated, time: .omitted)) · USD · Massive split-adjusted history")
                        .font(.callout).monospacedDigit()
                }
                if let levels = result.levels {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                        #if os(macOS)
                        GridRow { Text("Buy entry reference"); Text(price(levels.entry)).monospacedDigit() }
                        #endif
                        GridRow { Text("Scenario stop"); Text(price(levels.stop)).monospacedDigit() }
                        GridRow { Text("Scenario target"); Text(price(levels.target)).monospacedDigit() }
                    }.font(.callout)
                    #if os(macOS)
                    Text("Price references dated \(levels.at.formatted(date: .abbreviated, time: .omitted)). Scenarios, not executable orders or forecasts.")
                        .font(.caption).foregroundStyle(.secondary)
                    #else
                    Text("Scenarios, not executable orders or forecasts.").font(.caption).foregroundStyle(.secondary)
                    #endif
                    Text(levels.basis).font(.caption).foregroundStyle(.secondary)
                } else if isBuy(result.verdict?.action) {
                    Text("No valid entry/stop/target scenario could be calculated. Do not treat this opinion as an order plan.")
                        .font(.callout).foregroundStyle(DS.Palette.warningSoft)
                }
                if !result.coverage.isEmpty || result.evidenceReceipt != nil || result.diagnosticID != nil {
                    DisclosureGroup("Evidence coverage · " + Self.coverageSummary(result.coverage)) {
                        ForEach(Array(result.coverage.enumerated()), id: \.offset) { _, item in
                            Text(item.detail).font(.callout)
                        }
                        if let receipt = result.evidenceReceipt {
                            Text("\(receipt.offeredKeys.count) facts in the prepared prompt · \(receipt.citedKeys.count) cited · \(receipt.missingOrUnknownRequiredKeys.count) required facts missing or unknown")
                                .font(.callout).monospacedDigit()
                            Text("\(receipt.omittedKeys.count) optional records omitted to fit the prompt; \(receipt.prePromptOmittedRecordCount) provider records omitted before fitting.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let id = result.diagnosticID {
                            Text(result.diagnosticsComplete == true
                                ? "Local diagnostic receipt recorded. Older diagnostics expire under the storage limit."
                                : "Local diagnostic receipt was not fully saved. Saved research evidence is separate.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Diagnostic reference: " + id.uuidString).font(.caption.monospaced())
                        }
                        Text("Coverage records checks, not predictive quality. The exact facts below show the prepared evidence. Diagnostics record whether a model request began.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                #if os(macOS)
                if let short = result.shortInterest {
                    DisclosureGroup("Short interest and short volume · display only") {
                        ForEach(short.lines, id: \.self) { Text($0).font(.callout) }
                        Text("Shown for context only. Not sent to the model and not used by the strict screen or ranking.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                #endif
                if !result.facts.isEmpty {
                    DisclosureGroup("Evidence captured \(result.at.formatted(date: .abbreviated, time: .shortened))") {
                        Text("Model: \(result.model.isEmpty ? "no verified model answer" : result.model) · References: \(result.verdict?.evidence.joined(separator: ", ") ?? "none")")
                        ForEach(Array(result.facts.enumerated()), id: \.offset) { index, fact in
                            if fact.hasPrefix("Massive/Benzinga sample;") {
                                DisclosureGroup("F\(index + 1): Offered Benzinga evidence") {
                                    Text(verbatim: fact).font(.callout).fixedSize(horizontal: false, vertical: true)
                                }
                            } else { Text("F\(index + 1): \(fact)").font(.callout) }
                        }
                        if !(result.evidenceReceipt.map { $0.offeredKeys.contains(where: { $0.hasPrefix("benzinga.record.") }) }
                            ?? result.facts.contains(where: { $0.hasPrefix("Massive/Benzinga sample;") })) {
                            Text("Benzinga record details were not included in these model facts. Check the captured source statuses above.").font(.callout).foregroundStyle(.secondary)
                        }
                    }.font(.caption)
                }
            } else { Text("This listing has not been checked. No opinion or price levels are assumed.") }
        }
        #if os(macOS)
        .disclosureGroupStyle(ResearchDetailDisclosureStyle())
        #endif
        .textSelection(.enabled).accessibilityElement(children: .contain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    #if os(macOS)
    /// A native List row otherwise renders these nested disclosures as inert headings.
    private struct ResearchDetailDisclosureStyle: DisclosureGroupStyle {
        func makeBody(configuration: Configuration) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Button { configuration.isExpanded.toggle() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).accessibilityHidden(true)
                        configuration.label
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
                if configuration.isExpanded { configuration.content.padding(.leading, 16) }
            }
        }
    }
    #endif

    static func coverageSummary(_ coverage: [StockSageHorizonResearch.EvidenceCoverage]) -> String {
        guard !coverage.isEmpty else { return "Not captured" }
        let answered = coverage.filter { $0.state == .answered }.count
        let partial = coverage.filter { $0.state == .partial }.count
        let unavailable = coverage.count - answered - partial
        return "\(answered) answered" + (partial > 0 ? " · \(partial) partial" : "")
            + (unavailable > 0 ? " · \(unavailable) gaps" : "")
    }

    private static func price(_ value: Double?) -> String { value.map { "$" + StockSageCurrency.adaptivePrice($0, grouped: true) } ?? "—" }
    private static func isBuy(_ action: TradeAdvice.Action?) -> Bool { action == .buy || action == .strongBuy }
}
