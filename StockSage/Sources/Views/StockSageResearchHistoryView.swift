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
                Text("Ready for review").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
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
                StockSageResearchHistoryButton(store: store, history: history)
                Text("Open Saved research to check due results. Outcomes are fetched only when you request a check.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
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
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(horizon.title).font(.headline).accessibilityAddTraits(.isHeader)
                if let run {
                    Text("Completed \(run.completedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout).foregroundStyle(.secondary)
                    if run.completedAt > now {
                        Text("The completion time is ahead of this device’s clock.")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if run.predictions.isEmpty {
                        Text("No Buy or Strong Buy picks qualified in the latest completed run.")
                            .font(.callout)
                    } else {
                        ForEach(Array(run.predictions.enumerated()), id: \.element.id) { index, prediction in
                            Button { selectedRun = run } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(index + 1). \(prediction.symbol) · \(prediction.action)")
                                        .font(.headline).foregroundStyle(DS.Palette.accentText)
                                    Text(prediction.name).font(.callout)
                                    Text(prediction.reason).font(.callout).foregroundStyle(.secondary).lineLimit(2)
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
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("home.research.\(horizon.rawValue)")
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct StockSageResearchHistoryButton: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject var history = StockSageResearchHistory.shared
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            Label("Saved research (\(history.runs.count))", systemImage: "clock.arrow.circlepath")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("research.saved")
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
                        Text("Original picks stay unchanged. Review after 7 or 14 trading sessions.")
                            .font(.callout)
                        DisclosureGroup("How outcome checks work") {
                            Text("Review dates count future Nasdaq session closes, including holidays and early closes. Checks become available after the target New York date ends.")
                            Text("Compare the next trading date’s opening price with the review close, on the same split-adjusted basis. Movement before completion cannot count as success. This is a forward price benchmark, not realized trading profit.")
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

    static func status(for run: StockSageResearchHistory.Run, now: Date = Date()) -> String {
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
                        Text(StockSageResearchHistoryView.status(for: run))
                        Text("\(run.coverage.checked) listings checked · \(run.coverage.incomplete) incomplete opinions · \(run.coverage.buyCount) Buy / Strong Buy")
                            .font(.callout).foregroundStyle(.secondary)
                        if let selection = run.coverage.selection {
                            Text("\(selection.partialSession ? "Partial-session activity" : "Dated activity") · \(selection.session)\(selection.fallback ? " · fallback session" : "")")
                                .font(.callout).foregroundStyle(selection.partialSession || selection.fallback ? Color.orange : .secondary)
                            Text("\(selection.returnedCount) observations · \(selection.eligibleCount) eligible · \(selection.directoryCount) directory listings. Captured \(selection.requestedAt.formatted(date: .abbreviated, time: .shortened)).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Saved order: Strong Buy before Buy, then the original dated activity order. These are unvalidated research opinions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
                if run.predictions.isEmpty {
                    Text("No Buy or Strong Buy results qualified in this completed run.")
                }
                ForEach(Array(run.predictions.enumerated()), id: \.element.id) { index, prediction in
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(prediction.name).font(.headline)
                            Text(prediction.action).foregroundStyle(DS.Palette.accent).fontWeight(.semibold)
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
                                outcome(receipt)
                            } else {
                                outcome(StockSageResearchHistory.availability(for: run, now: Date()))
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

    @ViewBuilder private func outcome(_ evaluation: StockSageResearchHistory.Evaluation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let change = evaluation.priceReturn, let direction = evaluation.direction {
                Text(direction == .flat ? "Flat · unchanged" :
                    "\(direction == .rose ? "Rose" : "Fell") · \(change.formatted(.percent.precision(.fractionLength(2))))")
                    .font(.title3.weight(.semibold))
                Text(direction == .flat ? "No directional support" :
                    (evaluation.buyDirectionSupported == true ? "Buy direction supported" : "Buy direction not supported"))
                    .font(.callout)
                if let baseline = evaluation.comparisonReferencePrice, let target = evaluation.targetPrice {
                    Text("Benchmark open → review close: \(price(baseline)) → \(price(target))")
                        .font(.callout).monospacedDigit()
                    if let day = evaluation.comparisonReferenceDate {
                        Text("Next trading-day open: \(StockSageResearchHistoryView.sessionDateLabel(day))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
