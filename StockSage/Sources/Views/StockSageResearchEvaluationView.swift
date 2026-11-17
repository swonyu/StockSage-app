import Foundation
import SwiftUI

/// Explicit, prospective comparisons of saved research. Opening this view does not freeze
/// a contract, request prices, or run a model. Live quote ticks do not rebuild the summaries.
struct StockSageResearchEvaluationView: View {
    let store: StockSageStore
    @ObservedObject var history: StockSageResearchHistory
    @ObservedObject var evaluation: StockSageResearchEvaluation
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StockSageLocalModelServer.backendKey) private var backend = "auto"
    @AppStorage(StockSageLocalModelServer.urlKey) private var serverURL = StockSageLocalModelServer.defaultURL
    @AppStorage(StockSageLocalModelServer.modelKey) private var model = StockSageLocalModelServer.defaultModel
    @State private var costText = ""
    @State private var path: [UUID] = []
    private let configuration: (@MainActor () -> StockSageLocalModelServer.Config?)?

    init(store: StockSageStore, history: StockSageResearchHistory, evaluation: StockSageResearchEvaluation,
         configuration: (@MainActor () -> StockSageLocalModelServer.Config?)? = nil) {
        self.store = store; self.history = history; self.evaluation = evaluation
        self.configuration = configuration
    }

    private var selectedConfiguration: StockSageLocalModelServer.Config? {
        if let configuration { return configuration() }
        return StockSageAIAssessments.configuration(backend: backend, url: serverURL, model: model)
    }

    private var setupReason: String? {
        guard let config = selectedConfiguration, config.requiresStrictOutput else {
            return "Select a Gemma explanation profile in Library → Events & model setup → Explanation model before starting a study."
        }
        return nil
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Future picks, one frozen setup", systemImage: "chart.bar.xaxis")
                            .font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text("Freeze a setup now, then compare future saved picks with SPY. Earlier research is excluded; opening this page does not start a study or check prices.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text(StockSageResearchEvaluation.disclosure)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 6)
                }
                if let error = evaluation.lastError {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                Section("Start a prospective study") {
                    if let config = selectedConfiguration {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Current explanation model").font(.caption).foregroundStyle(.secondary)
                            Text(config.model).font(.headline).fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 4)
                    }
                    if let reason = setupReason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Modeled round-trip cost (basis points)").font(.subheadline.weight(.semibold))
                        TextField("Required, e.g. 25", text: $costText)
                            .textFieldStyle(.roundedBorder).decimalKeyboardOnIOS()
                            .accessibilityLabel("Modeled round-trip cost in basis points")
                            .accessibilityIdentifier("research.evaluation.cost")
                            .onSubmit(startStudy)
                            #if os(iOS)
                            .frame(minHeight: 44)
                            #endif
                        Text("Enter an assumption from 0 to 1,000 basis points, including 0 if intended. The same buy-and-sell cost is applied to the picks and to SPY; dividends are excluded.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(action: startStudy) {
                        Label("Start prospective study", systemImage: "plus")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(setupReason != nil || StockSageInput.nonNegativeAmount(costText) == nil || evaluation.isChecking)
                    .accessibilityIdentifier("research.evaluation.start")
                }
                Section("Frozen studies") {
                    if evaluation.studies.isEmpty {
                        ContentUnavailableView("No frozen studies", systemImage: "calendar.badge.clock",
                            description: Text("No studies yet. A study will start collecting matching future research after you freeze its setup."))
                    }
                    ForEach(evaluation.studies.sorted { $0.contract.frozenAt > $1.contract.frozenAt }) { study in
                        NavigationLink(value: study.id) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(study.contract.model).font(.headline).fixedSize(horizontal: false, vertical: true)
                                Text(study.contract.frozenAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.callout).foregroundStyle(.secondary)
                                Text("SPY comparison · \(Self.costLabel(study.contract.roundTripCostBPS)) round-trip cost")
                                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 10)
                        }
                        .accessibilityIdentifier("research.evaluation.study.\(study.id)")
                    }
                }
            }
            .navigationTitle("Prospective evaluation")
            .navigationDestination(for: UUID.self) { id in
                StudyDetail(store: store, history: history, evaluation: evaluation, studyID: id)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(DS.Palette.accent)
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 800)
        #endif
    }

    private func startStudy() {
        guard setupReason == nil, !evaluation.isChecking,
              let config = selectedConfiguration, let cost = StockSageInput.nonNegativeAmount(costText) else { return }
        let previous = Set(evaluation.studies.map(\.id))
        guard evaluation.freeze(config: config, costBPS: cost) else { return }
        costText = ""
        if let created = evaluation.studies.first(where: { !previous.contains($0.id) }) { path.append(created.id) }
    }

    private static func costLabel(_ value: Double) -> String { String(format: "%.2f bps", value) }

    private static func profileLabel(_ profile: StockSageAIAssessment.InferenceProfile.EndpointProfile) -> String {
        switch profile {
        case .runPodGemma: "Gemma via RunPod"
        case .lmStudioGemma: "Gemma via LM Studio"
        case .ollama: "Ollama"
        case .generic: "Other model profile"
        }
    }

    private struct StudyDetail: View {
        let store: StockSageStore
        @ObservedObject var history: StockSageResearchHistory
        @ObservedObject var evaluation: StockSageResearchEvaluation
        let studyID: UUID
        @State private var checkRequest = 0

        var body: some View {
            Group {
                if let study = evaluation.studies.first(where: { $0.id == studyID }) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        List {
                            Section {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(study.contract.model).font(.title3.weight(.semibold))
                                    Text("Frozen \(study.contract.frozenAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.callout).foregroundStyle(.secondary)
                                    Text(StockSageResearchEvaluation.disclosure)
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 6)
                                DisclosureGroup("Frozen setup and comparison rules") {
                                    Text("\(profileLabel(study.contract.endpointProfile)) · prompt \(study.contract.promptVersion) · schema \(study.contract.schemaVersion)")
                                    Text("Saved records identify a model name and endpoint profile cohort, not the exact server or model-weight files.")
                                    Text("Prospective ordering uses recorded device timestamps; capture timing is not independently authenticated.")
                                    Text("Ranking \(study.contract.rankingVersion) · qualification policy \(study.contract.qualificationPolicyVersion)")
                                    Text("Inference profile \(study.contract.profileVersion) · evidence packet \(study.contract.packetVersion) · temperature \(study.contract.temperature.formatted())")
                                    Text("Context: \(study.contract.contextTokens) tokens · initial output: \(study.contract.initialOutputTokens) · retry limit: \(study.contract.maxOutputTokens)")
                                    Text("Top-p: \(study.contract.topP.map { $0.formatted() } ?? "unspecified") · seed: \(study.contract.seed.map { String($0) } ?? "unspecified")")
                                    Text("\(study.contract.benchmark) benchmark · \(costLabel(study.contract.roundTripCostBPS)) modeled round-trip cost applied to both legs.")
                                    Text("Each comparison begins at the next session’s open and ends at the seventh or fourteenth settled-session close. It uses the full horizon even when a separate saved stop/target scenario ended earlier.")
                                    Text("Picks are equally weighted within each window, then complete windows are averaged. These are price comparisons, not simulated portfolio returns, compounding, drawdown, or trade P&L.")
                                    Text("\(study.contract.minimumWindows) complete nonoverlapping windows per horizon is a descriptive sample threshold, not proof of predictive skill.")
                                    Text(study.contract.calendarBasis)
                                    Text(StockSageResearchEvaluation.provider)
                                }
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            Section("Price checks") {
                                CheckControls(store: store, evaluation: evaluation, request: $checkRequest)
                            }
                            ForEach(evaluation.summary(studyID: studyID, runs: history.runs, now: context.date), id: \.horizon) { summary in
                                Section { HorizonSummaryCard(summary: summary) }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Study unavailable", systemImage: "doc.questionmark",
                        description: Text(evaluation.lastError ?? "The saved study could not be found."))
                }
            }
            .navigationTitle("Study results")
            .task(id: checkRequest) {
                guard checkRequest > 0, StockSageResearchEvaluation.accessReason(store: store) == nil else { return }
                await evaluation.checkSaved(studyID: studyID, history: history, store: store)
            }
        }
    }

    /// Isolate the only live-store observation: prices changing on the main board must not
    /// recompute every saved-study summary. Policy/sample availability still updates promptly.
    private struct CheckControls: View {
        @ObservedObject var store: StockSageStore
        @ObservedObject var evaluation: StockSageResearchEvaluation
        @Binding var request: Int
        @AppStorage(AppSettings.Keys.policyRevision) private var policyRevision = ""
        @AppStorage("stocksage.massive.credentialRevision") private var credentialRevision = ""

        var body: some View {
            let reason = StockSageResearchEvaluation.accessReason(store: store)
            VStack(alignment: .leading, spacing: 10) {
                if let error = evaluation.lastError { Text(error).foregroundStyle(.orange) }
                if let reason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                Button { request += 1 } label: {
                    Label(evaluation.isChecking ? "Checking saved prices…" : "Check saved prices", systemImage: "arrow.clockwise")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(evaluation.isChecking || reason != nil)
                .accessibilityIdentifier("research.evaluation.check")
            }
        }
    }

    struct HorizonSummaryCard: View {
        let summary: StockSageResearchEvaluation.HorizonSummary
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text(summary.horizon.title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(summary.readiness).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("research.evaluation.readiness.\(summary.horizon.rawValue)")
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(summary.measuredWindows) of \(summary.selectedWindows) selected windows measured")
                        .font(.subheadline.weight(.semibold))
                    Text("\(summary.measuredPredictions) of \(summary.expectedPredictions) selected picks measured")
                        .font(.callout)
                    Text("Waiting: \(summary.waitingWindows) · Not checked: \(summary.uncheckedWindows) · Data unavailable: \(summary.unavailableWindows)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                Divider()
                LazyVGrid(columns: typeSize.isAccessibilitySize
                    ? [GridItem(.flexible(), alignment: .leading)]
                    : [GridItem(.adaptive(minimum: 160), alignment: .leading)],
                    alignment: .leading, spacing: 12) {
                    metrics
                }
                Text("Mean net price returns across complete windows; excess is the picks minus SPY. Incomplete windows stay in the counts above.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Selection and exclusions") {
                    Text("Eligible saved runs: \(summary.eligibleRuns) · Outside the frozen contract: \(summary.excludedRuns)")
                    Text("Same-session runs omitted: \(summary.sameDateRuns) · Overlapping windows omitted: \(summary.overlappingRuns)")
                    Text("Calendar unavailable: \(summary.calendarUnavailableRuns)")
                }
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("research.evaluation.summary.\(summary.horizon.rawValue)")
        }

        @ViewBuilder private var metrics: some View {
            metric("Picks, net", value: summary.meanNetReturn)
            metric("SPY, net", value: summary.meanBenchmarkNetReturn)
            metric("Excess vs SPY", value: summary.meanExcessReturn)
        }

        private func metric(_ title: String, value: Double?) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(percentDescription(value))
                    .font(.title2.weight(.semibold)).monospacedDigit()
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(DS.Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: DS.Radius.small))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.small)
                .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
            .accessibilityElement(children: .combine)
        }

        private func percentDescription(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "Not measured" }
            let percent = value * 100
            guard percent.isFinite else { return "Out of display range" }
            return String(format: "%+.2f%%", percent)
        }
    }
}
