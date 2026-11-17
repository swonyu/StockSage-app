import SwiftUI
import UniformTypeIdentifiers

struct StockSageResearchHomeSummary: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject var history: StockSageResearchHistory
    let now: Date
    let openResearch: (StockSageResearchHistory.Horizon) -> Void
    @State private var selectedRun: StockSageResearchHistory.Run?

    var body: some View {
        let summary = StockSageResearchHistory.homeSummary(history.runs, now: now)
        #if os(macOS)
        let columns = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]
        #else
        let columns = [GridItem(.adaptive(minimum: 290), spacing: 18)]
        #endif
        VStack(alignment: .leading, spacing: 24) {
            if let error = history.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 10) {
                #if os(macOS)
                HStack(alignment: .firstTextBaseline) {
                    Label("Ready for review", systemImage: "clock.arrow.circlepath")
                        .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 16)
                    StockSageResearchHistoryButton(store: store, history: history)
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                }
                .padding(.bottom, 6)
                #else
                Text("Ready for review").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                #endif
                if summary.readyPredictions > 0 {
                    Text("\(summary.readyPredictions) saved \(summary.readyPredictions == 1 ? "prediction is" : "predictions are") ready to check.")
                        .font(.headline)
                    ForEach(summary.ready.prefix(3)) { run in
                        Button { selectedRun = run } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(run.horizon.title).fontWeight(.semibold)
                                Text("Completed \(run.completedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.callout).foregroundStyle(.secondary)
                                let count = StockSageResearchHistory.pendingPredictions(in: run).count
                                Text("\(count) \(count == 1 ? "prediction" : "predictions") awaiting a price check")
                                    .font(.callout)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("home.review.\(run.id)")
                    }
                    if summary.ready.count > 3 {
                        Text("\(summary.ready.count - 3) more completed runs in Saved research.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No predictions ready to check.").font(.headline)
                }
                if let next = summary.nextReviewAt {
                    Text("\(summary.waitingPredictions) awaiting a review date. Next review available after \(next.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if summary.unavailablePredictions > 0 {
                    Text("Review dates could not be verified for \(summary.unavailablePredictions) saved \(summary.unavailablePredictions == 1 ? "prediction" : "predictions"). Open Saved research for details.")
                        .font(.callout).foregroundStyle(.orange)
                }
                Text("\(summary.evaluatedPredictions) outcomes recorded · \(summary.targetHits) target hit · \(summary.stopHits) stop hit · \(summary.horizonCloses) horizon close")
                    .font(.callout).monospacedDigit()
                    .accessibilityIdentifier("home.research.outcomes")
                if summary.rosePredictions + summary.fellPredictions + summary.flatPredictions > 0 {
                    Text("Earlier endpoint-only checks · \(summary.rosePredictions) rose · \(summary.fellPredictions) fell · \(summary.flatPredictions) flat")
                        .font(.callout).monospacedDigit()
                        .accessibilityIdentifier("home.research.legacy.outcomes")
                }
                Text("These counts cover the strict comparison picks. They are not a win rate: saved predictions can overlap, and still-active or unavailable predictions are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
                #if os(iOS)
                StockSageResearchHistoryButton(store: store, history: history)
                #endif
                Text("Open Saved research to review all saved opinions or just the strict comparison picks. Opening the app does not fetch or change outcomes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #if os(macOS)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Bezel.cardFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
                .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
            #endif
            #if os(iOS)
            Divider()
            #endif
            VStack(alignment: .leading, spacing: 14) {
                Text("Latest completed research").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(summary.completedToday == 0 ? "No completed runs today (ET)." :
                    "\(summary.completedToday) \(summary.completedToday == 1 ? "run completed" : "runs completed") today (ET).")
                    .font(.callout).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(StockSageResearchHistory.Horizon.allCases, id: \.self) { horizon in
                        horizonSection(horizon, run: summary.latest.first { $0.horizon == horizon })
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                Text("Saved, unvalidated opinions in their original order. These are not live recommendations; open Research for a new scan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .tint(DS.Palette.accent)
        .sheet(item: $selectedRun) { run in
            NavigationStack {
                StockSageResearchHistoryDetail(history: history, runID: run.id)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedRun = nil } }
                    }
            }
            .tint(DS.Palette.accent).preferredColorScheme(.dark)
            #if os(macOS)
            .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 680)
            #endif
        }
    }

    private func horizonSection(_ horizon: StockSageResearchHistory.Horizon,
                                run: StockSageResearchHistory.Run?) -> some View {
        let content = VStack(alignment: .leading, spacing: 12) {
            Text(horizon.title).font(.headline).accessibilityAddTraits(.isHeader)
            if let run {
                Text("Completed \(run.completedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout).foregroundStyle(.secondary)
                if run.completedAt > now {
                    Text("The completion time is ahead of this device’s clock.")
                        .font(.callout).foregroundStyle(.orange)
                }
                Text(run.ranking == nil && run.rankingFailure == nil && !run.predictions.isEmpty
                    ? "Legacy saved shortlist" : "Strict comparison picks")
                    .font(.callout.weight(.semibold))
                if run.predictions.isEmpty {
                    Text(run.rankingFailure.map { "Strict comparison unavailable. " + $0 }
                         ?? "No Buy or Strong Buy picks qualified in the latest completed run.")
                        .font(.callout)
                } else {
                    ForEach(Array(run.predictions.enumerated()), id: \.element.id) { index, prediction in
                        Button { selectedRun = run } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1). \(prediction.symbol) · \(prediction.action)")
                                    .font(.headline).foregroundStyle(DS.Palette.accentText)
                                Text(prediction.name).font(.callout)
                                Text(prediction.reason).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                Text(StockSageResearchHistoryView.outcomeSummary(
                                    run.evaluations[prediction.symbol] ?? StockSageResearchHistory.availability(for: run, now: now),
                                    run: run))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("home.pick.\(run.id).\(prediction.symbol)")
                        if index < run.predictions.count - 1 { Divider() }
                    }
                }
                Text("\(run.coverage.checked) listings checked · \(run.coverage.incomplete) incomplete opinions")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No completed research for this horizon yet.").font(.callout).foregroundStyle(.secondary)
            }
            Button { openResearch(horizon) } label: {
                Label("Research \(horizon == .week ? "1–7" : "7–14") days", systemImage: "doc.text.magnifyingglass")
                    #if os(iOS)
                    .frame(minHeight: 44)
                    #endif
            }
            .accessibilityIdentifier("home.research.\(horizon.rawValue)")
            #if os(macOS)
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
            #endif
        }.frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        return content.padding(20)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(DS.Bezel.cardFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
                .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
        #else
        return GroupBox { content.padding(8) }
        #endif
    }
}

struct StockSageResearchHistoryButton: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject var history = StockSageResearchHistory.shared
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            Label("Saved research (\(history.runs.count))", systemImage: "clock.arrow.circlepath")
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
        }
        .accessibilityIdentifier("research.saved")
        #if os(macOS)
        .controlSize(.large)
        #endif
        .sheet(isPresented: $presented) {
            StockSageResearchHistoryView(store: store, history: history)
        }
    }
}

struct StockSageResearchHistoryView: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject var history: StockSageResearchHistory
    @Environment(\.dismiss) private var dismiss
    @State private var checkRequest = 0
    @State private var checkAllOpinions = false
    @State private var interruptedArchives: [StockSageResearchHistory.InterruptedArchive]?
    @State private var showEvaluation = false
    @State private var filter = StockSageResearchReviewFilter()
    static let directionOnlyDisclosure = "Price direction only. No market comparison is made; a rise does not establish outperformance, a profitable trade, or predictive skill."

    @ViewBuilder private var filterControls: some View {
        Section {
            DisclosureGroup("Filters\(filter.isActive ? " · on" : "")") {
                Picker("Horizon", selection: $filter.horizon) {
                    Text("Any").tag(StockSageResearchHistory.Horizon?.none)
                    ForEach(StockSageResearchHistory.Horizon.allCases, id: \.self) { horizon in
                        Text(horizon.title).tag(StockSageResearchHistory.Horizon?.some(horizon))
                    }
                }
                Picker("Action", selection: $filter.action) {
                    Text("Any").tag(StockSageResearchReviewFilter.Action.any)
                    Text("Buy").tag(StockSageResearchReviewFilter.Action.buy)
                    Text("Strong Buy").tag(StockSageResearchReviewFilter.Action.strongBuy)
                }
                Picker("Evidence checks", selection: $filter.quality) {
                    Text("Any").tag(StockSageResearchReviewFilter.Quality.any)
                    Text("Passed").tag(StockSageResearchReviewFilter.Quality.verified)
                    Text("Flagged").tag(StockSageResearchReviewFilter.Quality.unverified)
                    Text("Evidence unavailable").tag(StockSageResearchReviewFilter.Quality.evidenceUnavailable)
                    Text("Not assessed").tag(StockSageResearchReviewFilter.Quality.notAssessed)
                }
                // Three options, not two: "not known" is a separate answer from "none found".
                Picker("Insider activity", selection: $filter.insider) {
                    Text("Any").tag(StockSageResearchReviewFilter.Insider.any)
                    Text("Activity recorded").tag(StockSageResearchReviewFilter.Insider.recordedActivity)
                    Text("No qualifying rows in window").tag(StockSageResearchReviewFilter.Insider.noQualifyingRows)
                    Text("Not known").tag(StockSageResearchReviewFilter.Insider.notKnown)
                }
                Picker("Outcome", selection: $filter.outcome) {
                    Text("Any").tag(StockSageResearchReviewFilter.Outcome.any)
                    Text("Active").tag(StockSageResearchReviewFilter.Outcome.active)
                    Text("Settled").tag(StockSageResearchReviewFilter.Outcome.terminal)
                }
                if filter.isActive { Button("Clear filters") { filter = .init() } }
            }
            .accessibilityIdentifier("research.history.filters")
        }
    }

    private var accessReason: String? {
        if StockSageStore.isRunningTests { return "Outcome checks are disabled in test fixtures." }
        if let reason = ToolPolicy.webToolsDisabledReason() { return reason }
        if store.isSampleData { return "Leave sample data to check dated market prices." }
        if let reason = StockSageMassive.credentialAccessBlocker() { return reason }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Every opinion, preserved", systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(DS.Palette.textPrimary)
                            .font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text({
                            #if os(iOS)
                            "Saved reports are read-only on this iPhone. Their original dates, model, evidence and recorded outcomes are preserved. They are historical records, not fresh recommendations."
                            #else
                            "Original opinions and evidence stay unchanged. Review every accepted opinion against later prices, including stocks outside the Top 5. Failed and incomplete checks remain in their original run."
                            #endif
                        }())
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("research.history.provenance")
                        #if os(iOS)
                        Text("New model research, outcome checks and prospective evaluations remain on Mac. Mac records do not automatically sync to this iPhone.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("research.history.readOnly")
                        #endif
                        if let error = history.lastError {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        if let summary = history.lastCheckSummary {
                            Text(summary).font(.callout).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }
                if history.runs.isEmpty {
                    if history.lastError != nil {
                        ContentUnavailableView("Saved research unavailable", systemImage: "exclamationmark.triangle",
                            description: Text("Existing saved data is preserved. Resolve the storage error above before saving another run."))
                    } else {
                        ContentUnavailableView("No saved research yet", systemImage: "doc.text.magnifyingglass",
                            description: Text({
                                #if os(iOS)
                                "There are no saved reports in this iPhone's local records. Reports on your Mac remain on that device."
                                #else
                                "Complete a Research run to save its deterministic Top 5, original checks and separate strict comparison. Outcome reviews retain the original evidence."
                                #endif
                            }()))
                    }
                } else {
                    filterControls
                    let visible = history.runs.filter {
                        filter.matches($0, archivedSearchMatch: history.matchesSearch(filter.query, in: $0))
                    }
                    if visible.isEmpty {
                        // Never a bare empty list: say that the filters excluded everything, and
                        // offer the way back. An empty surface would read as "no saved research".
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("No saved research matches this search or these filters.", systemImage: "line.3.horizontal.decrease.circle")
                                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                                Text("\(history.runs.count) saved \(history.runs.count == 1 ? "run is" : "runs are") hidden. Clearing the filters shows them again; nothing has been deleted.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Clear filters") { filter = .init() }.buttonStyle(.bordered)
                            }.padding(.vertical, 12)
                        }
                    }
                    Section("Completed runs") {
                        ForEach(visible) { run in
                            let reviewed = run.evaluations.values.filter { $0.state == .evaluated }.count
                            let matching = filter.matchingPredictions(in: run).count
                            NavigationLink {
                                StockSageResearchHistoryDetail(history: history, runID: run.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(run.horizon.title).font(.title3.weight(.semibold))
                                        Text(run.completedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Text("\(run.deterministicRanking?.ranked.count ?? 0) ranked · \(run.predictions.count) strict picks · \(reviewed) outcomes recorded")
                                        .font(.callout).monospacedDigit()
                                    if filter.isActive, matching < run.predictions.count {
                                        Text("\(matching) of \(run.predictions.count) match the filters")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(Self.status(for: run)).font(.caption).foregroundStyle(.secondary)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 10)
                            }
                            .accessibilityIdentifier("research.history.run.\(run.id)")
                        }
                    }
                }
                if let interruptedArchives, !interruptedArchives.isEmpty {
                    Section("Earlier interrupted captures") {
                        ForEach(interruptedArchives) { archive in
                            NavigationLink {
                                StockSageInterruptedResearchDetail(history: history, archive: archive)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(archive.horizon.title).font(.headline)
                                    Text(archive.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    Text("\(archive.checkedCount) of \(archive.selectedCount) checks preserved · incomplete capture")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 6)
                            }
                        }
                    }
                }
                Section("Outcome reviews") {
                    DisclosureGroup("How outcome checks work") {
                        Text("Sessions use the verified Nasdaq calendar, including holidays and early closes. Only New York dates that have wholly ended are examined, so each split-adjusted daily aggregate is settled. Older runs retain their original endpoint-only schedule, shown in each saved run.")
                        Text("Daily bars cannot establish intraday order or an actual fill. New runs check opening gaps first; if the open is between the levels and a daily bar reaches both, the conservative stop-first rule applies. Older runs retain their recorded policy. This is a measured research scenario, not realized trading profit.")
                        Text(Self.directionOnlyDisclosure)
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("research.history.method")
                    #if os(macOS)
                    VStack(alignment: .leading, spacing: 14) {
                        if let reason = accessReason {
                            Text(reason).font(.callout).foregroundStyle(.secondary)
                        }
                        Button {
                            checkAllOpinions = true
                            checkRequest += 1
                        } label: {
                            Label(history.isChecking ? "Checking settled sessions…" : "Review all saved opinions",
                                  systemImage: "chart.xyaxis.line")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(history.isChecking || accessReason != nil || history.runs.isEmpty)
                        .accessibilityIdentifier("research.history.checkAllOpinions")
                        Text("Each press reviews up to \(StockSageResearchHistory.maximumChecksPerRequest) due opinions and continues with the least recently checked next time. No scheduled checks. Open a completed run to inspect each result.")
                            .font(.callout).foregroundStyle(DS.Palette.textSecondary)
                        Button {
                            checkAllOpinions = false
                            checkRequest += 1
                        } label: {
                            Label("Review strict comparison picks",
                                  systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(history.isChecking || accessReason != nil || history.runs.isEmpty)
                        .accessibilityIdentifier("research.history.check")
                    }.padding(.vertical, 6)
                    #endif
                }
                #if os(macOS)
                Section("Prospective model evaluation") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Separate studies compare future saved picks with SPY using a frozen setup and explicit modeled costs.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { showEvaluation = true } label: {
                            Label("Open prospective evaluations", systemImage: "chart.bar.xaxis")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("research.history.evaluation")
                    }.padding(.vertical, 6)
                }
                #endif
            }
            .navigationTitle("Saved research")
            .searchable(text: $filter.query, prompt: "Saved symbol or company")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(DS.Palette.accent)
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 680)
        #endif
        #if os(macOS)
        .sheet(isPresented: $showEvaluation) {
            StockSageResearchEvaluationView(store: store, history: history, evaluation: .shared)
        }
        .task(id: checkRequest) {
            guard checkRequest > 0, accessReason == nil else { return }
            // Explicit outcome review; opening or foregrounding never starts this request.
            await StockSageHorizonResearch.checkSavedOutcomes(history: history, store: store,
                includeAllOpinions: checkAllOpinions)
        }
        #endif
        .task { interruptedArchives = history.interruptedArchives() }
    }

    static func sessionDateLabel(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "America/New_York")!
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date) + " ET"
    }

    static func terminalLabel(_ kind: StockSageResearchHistory.Evaluation.TerminalKind) -> String {
        switch kind {
        case .targetHit: return "Target hit"
        case .stopHit: return "Stop hit"
        case .horizonClose: return "Horizon close"
        }
    }

    static func outcomeSummary(_ evaluation: StockSageResearchHistory.Evaluation,
                               run: StockSageResearchHistory.Run? = nil) -> String {
        if evaluation.state == .evaluated, let kind = evaluation.terminalKind, let change = evaluation.priceReturn {
            return terminalLabel(kind) + " · " + change.formatted(.percent.precision(.fractionLength(2)))
                + (evaluation.terminalAt.map { " · " + sessionDateLabel($0) } ?? "")
        }
        if evaluation.state == .evaluated, let change = evaluation.priceReturn, let direction = evaluation.direction {
            let label = direction == .flat ? "Flat" : (direction == .rose ? "Rose" : "Fell")
            return label + " · " + change.formatted(.percent.precision(.fractionLength(2)))
                + (evaluation.targetCloseAt.map { " · " + sessionDateLabel($0) } ?? "")
        }
        switch evaluation.state {
        case .due, .notDue:
            // A daily-policy prediction is simply active until a level or the horizon resolves it.
            if run?.usesDailyBarFirstHit == true { return "Active" }
            return evaluation.state == .due ? "Ready for review" : "Awaiting review date"
        case .dataUnavailable: return "Data unavailable"
        case .evaluated: return "Outcome unavailable"
        }
    }

    static func status(for run: StockSageResearchHistory.Run, now: Date = Date()) -> String {
        if run.rankingFailure != nil {
            return "Strict comparison unavailable · no strict picks for outcome review"
                + (run.deterministicRanking == nil ? "" : ". Deterministic Top 5 retained.")
        }
        let availability = StockSageResearchHistory.availability(for: run, now: now)
        guard let date = StockSageResearchHistory.checkAvailableAt(for: run) else { return availability.note }
        let dateLabel = date.formatted(date: .abbreviated, time: .shortened)
        if run.usesDailyBarFirstHit {
            return availability.state == .notDue ? "Monitoring starts after \(dateLabel)" : "Settled-session checks available since \(dateLabel)"
        }
        return availability.state == .notDue ? "Review available after \(dateLabel)" : "Review available since \(dateLabel)"
    }
}

struct StockSageResearchHistoryDetail: View {
    @ObservedObject var history: StockSageResearchHistory
    let runID: UUID
    @State private var exportDocument: StockSageResearchReportDocument?
    @State private var showExporter = false
    @State private var exportError: String?
    @State private var fullChecks: StockSageResearchHistory.FullChecksAvailability?
    @State private var opinionOutcomes: [String: StockSageResearchHistory.OpinionOutcome]?
    @State private var checkQuery = ""
    @State private var showFullChecks = false

    var body: some View {
        if let run = history.runs.first(where: { $0.id == runID }) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Completed", value: run.completedAt.formatted(date: .abbreviated, time: .shortened))
                        if run.retainedFromRunID != nil {
                            Text("Incomplete checks were researched again. Earlier completed opinions retain their captured evidence and dates. " + (run.ranking == nil ? "The updated pool has no completed shortlist." : "The entire updated eligible pool was compared for this shortlist."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if run.originalRunID != nil {
                            Text("Comparison retried using checks captured in the scan started \(run.startedAt.formatted(date: .abbreviated, time: .shortened)). Prices and evidence were not refreshed. The original attempt is retained; this review window starts from the later comparison.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Text(StockSageResearchHistoryView.status(for: run))
                            .font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(StockSageResearchHistory.measurementDescription(for: run))
                            .font(.callout).foregroundStyle(.secondary)
                        Text("\(run.coverage.checked) listings checked · \(run.coverage.incomplete) incomplete opinions · \(run.coverage.buyCount) Buy / Strong Buy")
                            .font(.callout).foregroundStyle(.secondary)
                        if let qualified = run.coverage.qualifiedBuyCount {
                            Text("\(qualified) passed the strict comparison screen").font(.caption)
                        }
                        if let ranking = run.ranking {
                            Text("\(ranking.model) compared \(ranking.candidateSymbols.count) eligible candidates in \(ranking.rounds.count) rounds. \(ranking.method)")
                                .font(.callout).foregroundStyle(.secondary)
                            Text("\(ranking.rounds.reduce(0) { $0 + $1.omittedCitedFacts.values.reduce(0, +) }) cited-record omissions across comparison rounds; original cases, risks and coverage stayed whole.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let failure = run.rankingFailure {
                            Text("Strict comparison unavailable. " + failure)
                                .font(.callout).foregroundStyle(.secondary)
                        } else if !run.predictions.isEmpty {
                            Text("Legacy shortlist: Strong Buy before Buy, with activity-order ties. This saved ordering has not been changed.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let selection = run.coverage.selection {
                            Text("\(selection.partialSession ? "Partial-session activity" : "Dated activity") · \(selection.session)\(selection.fallback ? " · fallback session" : "")")
                                .font(.callout).foregroundStyle(selection.partialSession || selection.fallback ? Color.orange : .secondary)
                            Text("\(selection.returnedCount) observations · \(selection.eligibleCount) eligible · \(selection.directoryCount) directory listings. Captured \(selection.requestedAt.formatted(date: .abbreviated, time: .shortened)).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Saved opinions and their ordering are unvalidated research, not forecasts.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            do {
                                let original = history.fullChecks(runID: run.id)
                                fullChecks = original
                                let outcomes = history.opinionOutcomes(runID: run.id)
                                if original.checks != nil, outcomes == nil { throw CocoaError(.fileReadCorruptFile) }
                                exportDocument = try .init(data: StockSageResearchExport.data(for: run,
                                    fullChecks: original, opinionOutcomes: outcomes))
                                exportError = nil
                                showExporter = true
                            } catch { exportError = "Research could not be exported: \(error.localizedDescription)" }
                        } label: {
                            Label("Export saved research", systemImage: "square.and.arrow.up")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("research.history.export")
                        Text("JSON includes original full checks, the saved shortlist and subsequent opinion outcomes when available. Missing records are explicitly identified. This is dated research, not live recommendations.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let exportError { Text(exportError).font(.callout).foregroundStyle(.orange) }
                    }.padding(.vertical, 6)
                }
                Section("Saved deterministic Top 5") {
                    if let ranked = run.deterministicRanking {
                        if let clock = run.rankingScoredAt {
                            Text("Scored \(clock.formatted(date: .abbreviated, time: .standard)); ordering and failed gates are frozen.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        StockSageTopFiveRankingSection(result: ranked)
                    } else {
                        Text("This older run did not record its deterministic Top 5. Its original checks and strict comparison remain unchanged.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Ranked rows can fail qualification. Full-list price reviews below remain separate from the strict comparison shortlist.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Original full checks") {
                    if let fullChecks {
                        Text(fullChecks.message).font(.callout)
                            .foregroundStyle(fullChecks.state == .corrupt ? Color.orange : .secondary)
                        if let checks = fullChecks.checks {
                            let accepted = checks.checks.filter(\.hasAcceptedOpinion).count
                            Text("\(checks.checks.count) saved checks · \(accepted) accepted opinions")
                                .font(.callout).monospacedDigit()
                            if let opinionOutcomes {
                                Text("\(opinionOutcomes.values.filter { $0.horizonReturn.state == .evaluated }.count) full-horizon returns recorded")
                                    .font(.callout).monospacedDigit()
                            } else {
                                Text("Saved outcome records are unavailable. Original research is preserved.")
                                    .font(.callout).foregroundStyle(.orange)
                            }
                            Text("Price movement is measured from the next trading-date open after this run completed. Hold and Avoid receive no directional win label. Captured long scenarios, where available, are shown separately.")
                                .font(.caption).foregroundStyle(.secondary)
                            TextField("Find a saved symbol or company", text: $checkQuery)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("research.history.checkSearch")
                                .onChange(of: checkQuery) { _, query in
                                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { showFullChecks = true }
                                }
                            let query = checkQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                            let visibleChecks = checks.checks.filter {
                                query.isEmpty || $0.listing.ticker.localizedCaseInsensitiveContains(query)
                                    || $0.listing.name.localizedCaseInsensitiveContains(query)
                            }
                            if visibleChecks.isEmpty { Text("No original checks match this search.").foregroundStyle(.secondary) }
                            DisclosureGroup(query.isEmpty ? "Inspect all \(checks.checks.count) original checks"
                                : "\(visibleChecks.count) of \(checks.checks.count) original checks", isExpanded: $showFullChecks) {
                                ForEach(visibleChecks, id: \.listing.ticker) { check in
                                    DisclosureGroup("\(check.listing.ticker) · \(check.verdict?.action ?? "Incomplete opinion")") {
                                        opinionReview(check, run: run)
                                        StockSageResearchModesPanel.resultDetail(check.listing, result: check.result)
                                            .padding(.vertical, 8)
                                    }
                                }
                            }
                            .accessibilityIdentifier("research.history.fullChecks")
                        }
                    } else { Text("Loading original checks…").foregroundStyle(.secondary) }
                    Text(StockSageResearchHistory.fullChecksRetentionPolicy).font(.caption).foregroundStyle(.secondary)
                }
                if run.predictions.isEmpty {
                    Text(run.rankingFailure == nil ? "No Buy or Strong Buy results qualified in this completed run." : "No strict comparison picks were saved because comparison was unavailable.")
                }
                Section {
                    Text("Strict comparison outcomes").font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("These saved scenarios are separate from the deterministic Top 5. A failed comparison does not erase the ranked five or their evidence.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(run.predictions.enumerated()), id: \.element.id) { index, prediction in
                    Section {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(prediction.name).font(.title3.weight(.semibold))
                                Text(prediction.action).font(.headline).foregroundStyle(DS.Palette.accentText)
                            }
                            Text(prediction.reason).fixedSize(horizontal: false, vertical: true)
                            Label(prediction.risk, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.secondary)
                            if let price = prediction.referencePrice, let date = prediction.referenceDate {
                                Text("Original reference: \(price.formatted(.currency(code: "USD"))) · \(StockSageResearchHistoryView.sessionDateLabel(date))")
                                    .font(.callout)
                            } else {
                                Text("Original reference price was not recorded.").font(.callout)
                            }
                            if let receipt = run.evaluations[prediction.symbol],
                               receipt.state == .evaluated || receipt.state == .dataUnavailable {
                                outcome(receipt, run: run)
                            } else {
                                outcome(StockSageResearchHistory.availability(for: run, now: Date()), run: run)
                            }
                            if let progress = run.reviewProgress?[prediction.symbol] {
                                Text("Last checked \(progress.checkedAt.formatted(date: .abbreviated, time: .shortened)).")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let through = progress.verifiedThrough {
                                    Text("Settled sessions last verified through \(StockSageResearchHistoryView.sessionDateLabel(through)).")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.vertical, 6)
                        qualityBadge(prediction)
                        insiderActivity(prediction)
                        DisclosureGroup("Original evidence and model") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Model: \(prediction.model.isEmpty ? "Not recorded" : prediction.model)")
                                evidenceByClass(prediction)
                                if !prediction.note.isEmpty { Text(prediction.note) }
                                Text("Evidence references: \(prediction.evidence.joined(separator: ", "))")
                                ForEach(Array(prediction.facts.enumerated()), id: \.offset) { _, fact in Text(fact) }
                                if let levels = prediction.levels {
                                    Text("Original scenario · entry \(price(levels.entry)), stop \(price(levels.stop)), target \(price(levels.target))")
                                    Text(levels.basis)
                                }
                            }.font(.callout).textSelection(.enabled).padding(.vertical, 8)
                        }
                    } header: {
                        Text("\(index + 1). \(prediction.symbol)")
                    }
                }
                if let error = history.lastError { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle(run.horizon.title)
            .task(id: history.opinionReviewRevision) {
                fullChecks = history.fullChecks(runID: runID)
                opinionOutcomes = history.opinionOutcomes(runID: runID)
            }
            .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json,
                          defaultFilename: "StockSage-\(run.horizon.rawValue)-\(run.id.uuidString)") { result in
                if case .failure(let error) = result,
                   (error as? CocoaError)?.code != .userCancelled {
                    exportError = "Research could not be exported: \(error.localizedDescription)"
                }
            }
        } else {
            ContentUnavailableView("Research unavailable", systemImage: "doc.text.magnifyingglass")
        }
    }

    @ViewBuilder private func opinionReview(_ check: StockSageResearchHistory.CompletedCheck,
                                           run: StockSageResearchHistory.Run) -> some View {
        if !check.hasAcceptedOpinion {
            Text("No accepted opinion to score. The original failure and evidence remain below.")
                .font(.callout).foregroundStyle(.secondary)
        } else if let receipt = opinionOutcomes?[check.listing.ticker] {
            Text("Full-horizon price movement").font(.headline)
            outcome(receipt.horizonReturn, run: run, showBuySupport: false)
            if let scenario = receipt.scenario {
                Text("Captured long scenario · qualification is separate").font(.headline)
                outcome(scenario, run: run, showBuySupport: false)
            }
            Text("Last reviewed \(receipt.checkedAt.formatted(date: .abbreviated, time: .shortened)).")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(opinionOutcomes == nil ? "Saved outcome records are unavailable. Original research is preserved." : "No price review recorded yet. Use Review all saved opinions in Saved research when settled sessions are available.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func outcome(_ evaluation: StockSageResearchHistory.Evaluation,
                                     run: StockSageResearchHistory.Run, showBuySupport: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let kind = evaluation.terminalKind, let change = evaluation.priceReturn {
                Text("\(StockSageResearchHistoryView.terminalLabel(kind)) · \(change.formatted(.percent.precision(.fractionLength(2))))")
                    .font(.title3.weight(.semibold))
                if let session = evaluation.terminalAt {
                    Text("Terminal session: \(StockSageResearchHistoryView.sessionDateLabel(session))")
                        .font(.callout)
                }
                if let outcomePrice = evaluation.outcomePrice {
                    Text("Observed outcome price: \(price(outcomePrice))")
                        .font(.callout).monospacedDigit()
                }
                if let entry = evaluation.adjustedEntry, let stop = evaluation.adjustedStop,
                   let target = evaluation.adjustedTarget {
                    Text("Adjusted scenario · entry \(price(entry)), stop \(price(stop)), target \(price(target))")
                        .font(.callout).monospacedDigit()
                    if let ratio = evaluation.adjustmentRatio, ratio != 1 {
                        Text("Captured levels rebased by \(ratio.formatted(.number.precision(.fractionLength(6)))) from the freshly adjusted reference close. The original saved scenario is unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let baseline = evaluation.comparisonReferencePrice,
                   let day = evaluation.comparisonReferenceDate {
                    Text("Measured from the next trading-day open \(price(baseline)) · \(StockSageResearchHistoryView.sessionDateLabel(day))")
                        .font(.callout).monospacedDigit()
                }
                if let bars = evaluation.dailyBars {
                    DisclosureGroup("Verified daily bars · \(bars.count) \(bars.count == 1 ? "session" : "sessions")") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Every session examined through the terminal one. A missing session is never replaced by an adjacent bar.")
                                .foregroundStyle(.secondary)
                            ForEach(bars, id: \.date) { bar in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(StockSageResearchHistoryView.sessionDateLabel(bar.date))
                                        .font(.subheadline.weight(.semibold))
                                    Text("O \(price(bar.open)) · H \(price(bar.high)) · L \(price(bar.low)) · C \(price(bar.close))")
                                        .monospacedDigit()
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityElement(children: .combine)
                                .padding(.vertical, 4)
                            }
                        }.font(.callout).padding(.vertical, 6)
                    }
                }
                Text(StockSageResearchHistoryView.directionOnlyDisclosure)
                    .font(.caption).foregroundStyle(.secondary)
            } else if let change = evaluation.priceReturn, let direction = evaluation.direction {
                Text(direction == .flat ? "Flat · unchanged" :
                    "\(direction == .rose ? "Rose" : "Fell") · \(change.formatted(.percent.precision(.fractionLength(2))))")
                    .font(.title3.weight(.semibold))
                if showBuySupport {
                    Text(direction == .flat ? "No directional support" :
                        (evaluation.buyDirectionSupported == true ? "Buy direction supported" : "Buy direction not supported"))
                        .font(.callout)
                }
                Text(StockSageResearchHistoryView.directionOnlyDisclosure)
                    .font(.caption).foregroundStyle(.secondary)
                if let baseline = evaluation.comparisonReferencePrice, let target = evaluation.targetPrice {
                    Text("Benchmark open → review close: \(price(baseline)) → \(price(target))")
                        .font(.callout).monospacedDigit()
                    if let day = evaluation.comparisonReferenceDate {
                        Text("Next trading-day open: \(StockSageResearchHistoryView.sessionDateLabel(day))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let path = evaluation.dailyCloses,
                   let best = path.max(by: { $0.price < $1.price }),
                   let worst = path.min(by: { $0.price < $1.price }) {
                    DisclosureGroup("Daily-close path · \(path.count) sessions") {
                        VStack(alignment: .leading, spacing: 8) {
                            if run.horizon == .fortnight,
                               let seventh = StockSageResearchHistory.seventhSessionClose(in: evaluation, for: run) {
                                Text("\(run.measurementPolicy == nil ? "Legacy seventh-close checkpoint" : "Seventh-session close"): \(price(seventh.price)) · \(StockSageResearchHistoryView.sessionDateLabel(seventh.date))")
                            }
                            Text("Highest daily close: \(price(best.price)) · \(StockSageResearchHistoryView.sessionDateLabel(best.date))")
                            Text("Lowest daily close: \(price(worst.price)) · \(StockSageResearchHistoryView.sessionDateLabel(worst.date))")
                            Text("All verified comparison sessions are included. Daily closes do not establish intraday target hits, stop fills, or execution prices.")
                                .foregroundStyle(.secondary)
                            ForEach(path, id: \.date) { item in
                                LabeledContent(StockSageResearchHistoryView.sessionDateLabel(item.date), value: price(item.price))
                            }
                        }.font(.callout).padding(.vertical, 6)
                    }
                } else {
                    Text("Complete daily-close path was not recorded or could not be verified; only the endpoint comparison is available.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if run.usesDailyBarFirstHit {
                Text(evaluation.state == .dataUnavailable ? "Data unavailable" : "Active")
                    .font(.headline)
            } else {
                Text(evaluation.state == .notDue ? "Not due yet" :
                    (evaluation.state == .due ? "Ready to check" : "Outcome unavailable"))
                    .font(.headline)
            }
            if let close = evaluation.targetCloseAt {
                Text(run.usesDailyBarFirstHit
                        ? "Scheduled horizon session: \(StockSageResearchHistoryView.sessionDateLabel(close))"
                        : "Review session: \(StockSageResearchHistoryView.sessionDateLabel(close))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(evaluation.note).font(.caption).foregroundStyle(.secondary)
            if let provider = evaluation.provider, let fetched = evaluation.fetchedAt {
                Text("\(provider) · retrieved \(fetched.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: DS.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small)
            .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    private func price(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }

    /// Shadow-mode evidence checks. A run with no recorded report reads as "not assessed" and is
    /// styled neutrally, because absent metadata is not a negative result.
    @ViewBuilder private func qualityBadge(_ prediction: StockSageResearchHistory.Prediction) -> some View {
        let state = StockSageResearchQualityPresentation.state(for: prediction)
        VStack(alignment: .leading, spacing: 4) {
            Text(state.badge)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(state.isNegative ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text(state.explanation).font(.caption).foregroundStyle(.secondary)
            ForEach(state.findingDescriptions, id: \.self) { finding in
                Text("• " + finding).font(.caption)
            }
            if !state.uncitedInsiderIDs.isEmpty {
                Text("Insider records offered but not cited: " + state.uncitedInsiderIDs.joined(separator: ", "))
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// Two different denominators, deliberately never summed: `captured` is the packet before
    /// prompt fitting, `offered` is what reached the model. Their difference is what fitting
    /// trimmed, which is worth showing rather than hiding.
    @ViewBuilder private func evidenceByClass(_ prediction: StockSageResearchHistory.Prediction) -> some View {
        let rows = StockSageResearchQualityPresentation.state(for: prediction).classCoverage
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Evidence by class — captured in the packet, then offered to the model")
                    .font(.caption.weight(.semibold))
                ForEach(rows, id: \.factClass) { row in
                    Text("\(row.factClass): captured \(row.captured.map(String.init) ?? "not recorded"), offered \(row.offered)"
                         + ((row.trimmed ?? 0) > 0 ? ", \(row.trimmed ?? 0) trimmed to fit the context budget" : ""))
                        .font(.caption)
                }
            }
        }
    }

    /// Deliberately NOT inside the collapsed "Original evidence and model" group: insider evidence
    /// is core content here, so it stays visible without a tap. The states it renders are distinct
    /// on purpose — a not-recorded archive and an unchecked source are gaps, not findings, and an
    /// answered empty query speaks only about the window it queried.
    @ViewBuilder private func insiderActivity(_ prediction: StockSageResearchHistory.Prediction) -> some View {
        let state = StockSageInsiderActivityPresentation.state(for: prediction)
        VStack(alignment: .leading, spacing: 6) {
            // The spoken summary rides on the HEADER, not on a combined element wrapping the whole
            // section. An explicit label on a `.combine` element REPLACES every child label
            // (the A11Y-01 contract note on the idea card), which hid every transaction row from
            // VoiceOver — owner name, role, both dates and the plan disclosure all became
            // unreadable, leaving only a count. Found by the presentation test, which could not
            // reveal a filer's name that was plainly visible on screen.
            Label("Insider activity", systemImage: "person.text.rectangle")
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel(state.accessibilityLabel)
            Text(state.headline)
                .font(.callout)
                .foregroundStyle(state.hasRecordedActivity ? .primary : .secondary)
            ForEach(Array(state.transactions.enumerated()), id: \.offset) { _, transaction in
                Text(StockSageInsiderActivityPresentation.row(for: transaction))
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

private struct StockSageInterruptedResearchDetail: View {
    @ObservedObject var history: StockSageResearchHistory
    let archive: StockSageResearchHistory.InterruptedArchive
    @State private var checkpoint: StockSageResearchHistory.InterruptedCheckpoint?
    @State private var document: StockSageResearchReportDocument?
    @State private var showExporter = false
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        List {
            Section("Preserved interrupted capture") {
                Text("Started \(archive.startedAt.formatted(date: .abbreviated, time: .shortened))")
                Text("\(archive.checkedCount) of \(archive.selectedCount) checks preserved. This is not a completed run; its outcome review is unavailable.")
                    .foregroundStyle(.secondary)
                Button("Export original capture") {
                    if let data = history.interruptedArchiveData(id: archive.id) {
                        document = .init(data: data)
                        showExporter = true
                    } else { error = "The original capture could not be read. No records were replaced." }
                }
                .disabled(checkpoint == nil)
                .accessibilityIdentifier("research.history.interrupted.export")
                if let error { Text(error).foregroundStyle(.orange) }
            }
            if let checkpoint {
                Section("Original checks") {
                    TextField("Find a symbol or company", text: $query).textFieldStyle(.roundedBorder)
                    let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    ForEach(checkpoint.completedChecks.checks.filter {
                        search.isEmpty || $0.listing.ticker.localizedCaseInsensitiveContains(search)
                            || $0.listing.name.localizedCaseInsensitiveContains(search)
                    }, id: \.listing.ticker) { check in
                        DisclosureGroup("\(check.listing.ticker) · \(check.verdict?.action ?? "Incomplete opinion")") {
                            StockSageResearchModesPanel.resultDetail(check.listing, result: check.result)
                        }
                    }
                }
            }
        }
        .navigationTitle(archive.horizon.title)
        .task(id: archive.id) {
            checkpoint = history.interruptedArchive(id: archive.id)
            if checkpoint == nil { error = "This archived capture is unavailable or failed integrity checks." }
        }
        .fileExporter(isPresented: $showExporter, document: document, contentType: .json,
                      defaultFilename: "StockSage-interrupted-\(archive.id)") { result in
            if case .failure(let failure) = result, (failure as? CocoaError)?.code != .userCancelled {
                error = "Export failed: \(failure.localizedDescription)"
            }
        }
    }
}

private struct StockSageResearchReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
