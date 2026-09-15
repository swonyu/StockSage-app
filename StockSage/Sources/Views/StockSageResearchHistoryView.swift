import SwiftUI

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
                Text("\(summary.evaluatedPredictions) outcomes checked · \(summary.rosePredictions) rose · \(summary.fellPredictions) fell · \(summary.flatPredictions) flat")
                    .font(.callout).monospacedDigit()
                    .accessibilityIdentifier("home.research.outcomes")
                Text("Direction only; no market comparison. Saved predictions can overlap, so these counts are not independent trades or a win rate.")
                    .font(.caption).foregroundStyle(.secondary)
                #if os(iOS)
                StockSageResearchHistoryButton(store: store, history: history)
                #endif
                Text("Open Saved research to check due results. Outcomes are fetched only when you request a check.")
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
                if run.predictions.isEmpty {
                    Text(run.rankingFailure.map { "Top five comparison unavailable. " + $0 }
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
                                    run.evaluations[prediction.symbol] ?? StockSageResearchHistory.availability(for: run, now: now)))
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
    static let directionOnlyDisclosure = "Price direction only. No market comparison is made; a rise does not establish outperformance, a profitable trade, or predictive skill."

    private var accessReason: String? {
        if StockSageStore.isRunningTests { return "Outcome checks are disabled in test fixtures." }
        if let reason = ToolPolicy.webToolsDisabledReason() { return reason }
        if store.isSampleData { return "Leave sample data to check dated market prices." }
        if !StockSageMassive.isConfigured { return "Configure Massive in Settings to check outcomes." }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Original picks stay unchanged. New runs measure 7 or 14 full trading sessions from the next trading date’s open.")
                            .font(.callout)
                        DisclosureGroup("How outcome checks work") {
                            Text("Review dates use the verified Nasdaq calendar, including holidays and early closes. Checks become available after the target New York date ends. Older runs retain their original schedule, shown in each saved run.")
                            Text("Compare the next trading date’s opening price with the review close, on the same split-adjusted basis. Movement before completion cannot count as success. This is a forward price benchmark, not realized trading profit.")
                            Text(Self.directionOnlyDisclosure)
                        }
                        .font(.callout).foregroundStyle(.secondary)
                        if let error = history.lastError {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        if let reason = accessReason {
                            Text(reason).font(.callout).foregroundStyle(.secondary)
                        }
                        Button {
                            checkRequest += 1
                        } label: {
                            Label(history.isChecking ? "Checking dated prices…" : "Check due results",
                                  systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                        }
                        .disabled(history.isChecking || accessReason != nil || history.runs.isEmpty)
                        .accessibilityIdentifier("research.history.check")
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
                            description: Text("Complete a Research run. Its original top five Buy / Strong Buy results and evidence are saved automatically."))
                    }
                } else {
                    Section("Completed runs") {
                        ForEach(history.runs) { run in
                            let reviewed = run.evaluations.values.filter { $0.state == .evaluated }.count
                            NavigationLink {
                                StockSageResearchHistoryDetail(history: history, runID: run.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(run.horizon.title).font(.headline)
                                    Text(run.completedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Text("\(run.predictions.count) saved \(run.predictions.count == 1 ? "pick" : "picks") · \(reviewed) \(reviewed == 1 ? "outcome" : "outcomes") available")
                                        .font(.callout)
                                    Text(Self.status(for: run)).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                            .accessibilityIdentifier("research.history.run.\(run.id)")
                        }
                    }
                }
            }
            .navigationTitle("Saved research")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(DS.Palette.accent)
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 680)
        #endif
        .task(id: checkRequest) {
            guard checkRequest > 0, accessReason == nil else { return }
            let key = StockSageMassive.apiKey
            let revision = StockSageMassive.credentialRevision()
            let allowed: @MainActor () -> Bool = {
                !StockSageStore.isRunningTests && ToolPolicy.isExternalAllowed && !store.isSampleData
                    && StockSageMassive.apiKey == key && StockSageMassive.credentialRevision() == revision
            }
            await history.checkDue(allowed: allowed) { prediction, run in
                await StockSageHorizonResearch.fetchReviewObservation(prediction: prediction, run: run,
                    key: key, allowed: allowed)
            }
        }
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

    static func outcomeSummary(_ evaluation: StockSageResearchHistory.Evaluation) -> String {
        if evaluation.state == .evaluated, let change = evaluation.priceReturn, let direction = evaluation.direction {
            let label = direction == .flat ? "Flat" : (direction == .rose ? "Rose" : "Fell")
            return label + " · " + change.formatted(.percent.precision(.fractionLength(2)))
                + (evaluation.targetCloseAt.map { " · " + sessionDateLabel($0) } ?? "")
        }
        switch evaluation.state {
        case .due: return "Ready for review"
        case .notDue: return "Awaiting review date"
        case .dataUnavailable, .evaluated: return "Outcome unavailable"
        }
    }

    static func status(for run: StockSageResearchHistory.Run, now: Date = Date()) -> String {
        if run.rankingFailure != nil { return "Comparison unavailable · no ranked picks to review" }
        let availability = StockSageResearchHistory.availability(for: run, now: now)
        guard let date = StockSageResearchHistory.reviewAvailableAt(for: run) else { return availability.note }
        let dateLabel = date.formatted(date: .abbreviated, time: .shortened)
        return availability.state == .notDue ? "Review available after \(dateLabel)" : "Review available since \(dateLabel)"
    }
}

struct StockSageResearchHistoryDetail: View {
    @ObservedObject var history: StockSageResearchHistory
    let runID: UUID

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
                        Text(StockSageResearchHistory.measurementDescription(for: run))
                            .font(.callout).foregroundStyle(.secondary)
                        Text("\(run.coverage.checked) listings checked · \(run.coverage.incomplete) incomplete opinions · \(run.coverage.buyCount) Buy / Strong Buy")
                            .font(.callout).foregroundStyle(.secondary)
                        if let ranking = run.ranking {
                            Text("\(ranking.model) compared \(ranking.candidateSymbols.count) eligible candidates in \(ranking.rounds.count) rounds. \(ranking.method)")
                                .font(.callout).foregroundStyle(.secondary)
                            Text("\(ranking.rounds.reduce(0) { $0 + $1.omittedCitedFacts.values.reduce(0, +) }) cited-record omissions across comparison rounds; original cases, risks and coverage stayed whole.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let failure = run.rankingFailure {
                            Text("Top five comparison unavailable. " + failure)
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
                    }.padding(.vertical, 6)
                }
                if run.predictions.isEmpty {
                    Text(run.rankingFailure == nil ? "No Buy or Strong Buy results qualified in this completed run." : "No ranked picks were saved because comparison was unavailable.")
                }
                ForEach(Array(run.predictions.enumerated()), id: \.element.id) { index, prediction in
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(prediction.name).font(.headline)
                            Text(prediction.action).foregroundStyle(DS.Palette.accentText).fontWeight(.semibold)
                            Text(prediction.reason)
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
                        }.padding(.vertical, 6)
                        DisclosureGroup("Original evidence and model") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Model: \(prediction.model.isEmpty ? "Not recorded" : prediction.model)")
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
        } else {
            ContentUnavailableView("Research unavailable", systemImage: "doc.text.magnifyingglass")
        }
    }

    @ViewBuilder private func outcome(_ evaluation: StockSageResearchHistory.Evaluation,
                                     run: StockSageResearchHistory.Run) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let change = evaluation.priceReturn, let direction = evaluation.direction {
                Text(direction == .flat ? "Flat · unchanged" :
                    "\(direction == .rose ? "Rose" : "Fell") · \(change.formatted(.percent.precision(.fractionLength(2))))")
                    .font(.title3.weight(.semibold))
                Text(direction == .flat ? "No directional support" :
                    (evaluation.buyDirectionSupported == true ? "Buy direction supported" : "Buy direction not supported"))
                    .font(.callout)
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
            } else {
                Text(evaluation.state == .notDue ? "Not due yet" :
                    (evaluation.state == .due ? "Ready to check" : "Outcome unavailable"))
                    .font(.headline)
            }
            if let close = evaluation.targetCloseAt {
                Text("Review session: \(StockSageResearchHistoryView.sessionDateLabel(close))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(evaluation.note).font(.caption).foregroundStyle(.secondary)
            if let provider = evaluation.provider, let fetched = evaluation.fetchedAt {
                Text("\(provider) · retrieved \(fetched.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8)
    }

    private func price(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
}
