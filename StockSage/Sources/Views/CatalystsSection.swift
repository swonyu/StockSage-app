import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - CatalystsSection
//
// Owner request (2026-09-06): "a new tab that shows, for the same ideas as the Ideas tab, the
// key catalyst to watch and explains why" — build step C3-view. This file adds ZERO new
// catalyst priority/trading logic: it is display over the pure brief engine (StockSageCatalystWatch,
// build step C1) plus the optional on-device narrator (StockSageCatalystNarrator, build step
// C2). `ideas` is the SAME projected, ordered list the Ideas tab renders — this view never
// re-ranks it, it only asks "what could move each one next, and why".
//
// STANDALONE BY DESIGN: the orchestrator wires `MarketSection.catalysts` and constructs this
// view from MarketsView.swift in a later step — this file must compile (and does) with no
// change to that file.
struct CatalystsSection: View {
    let ideas: [StockSageIdea]
    @ObservedObject var store: StockSageStore
    let onSelect: (StockSageIdea) -> Void
    let ideasFilterMessage: String
    let onOpenIdeas: () -> Void

    enum Mode: String, CaseIterable {
        case cards, calendar
        var title: String {
            switch self {
            case .cards:    return "Cards"
            case .calendar: return "Calendar"
            }
        }
    }

    #if os(macOS)
    nonisolated enum Period: String, CaseIterable {
        case today, thisWeek, thisMonth
        nonisolated var title: String {
            switch self {
            case .today: return "Today"
            case .thisWeek: return "This Week"
            case .thisMonth: return "This Month"
            }
        }
    }
    #endif

    #if os(macOS)
    // Keep the existing preference key, but make the approved agenda the first-run Mac view.
    @AppStorage("marketsCatalystsMode") private var mode: Mode = .calendar
    @AppStorage("marketsCatalystsPeriod") private var period: Period = .thisWeek
    @AppStorage(StockSageLocalModelStartup.enabledKey) private var automaticModelStartup = false
    // Re-arms the one-shot UTC-boundary task after a boundary, wake or clock change. Each render
    // still captures a fresh Date below, so catalyst freshness never freezes at an old tick.
    @State private var periodClockRevision = 0
    @Environment(\.scenePhase) private var scenePhase
    #else
    @AppStorage("marketsCatalystsMode") private var mode: Mode = .cards
    #endif
    @State private var expanded: Set<String> = []
    @State private var narrations: [String: StockSageCatalystNarrator.Result] = [:]
    @State private var narrationEvidenceNotes: [String: [String]] = [:]
    @State private var narrationFacts: [String: [String]] = [:]
    @State private var narrationBaseFacts: [String: [String]] = [:]
    @State private var narrationBenzinga: [String: StockSageBenzinga.Snapshot] = [:]
    @State private var narrationSettings: [String: [String]] = [:]
    /// Why the LAST "Explain" press on each symbol stopped without publishing. A press that is
    /// superseded (settings changed), whose evidence capture aged out, or that lost external
    /// access mid-run publishes nothing — without this, the panel either kept showing the
    /// PREVIOUS paragraph as if it were current, or (with no previous paragraph) rendered nothing
    /// at all and the press looked like a dead button.
    @State private var narrationAborted: [String: String] = [:]
    @State private var narrating: Set<String> = []
    /// Which stage each in-flight explanation is at. The panel showed one unlabelled spinner
    /// across source collection, a model probe and a completion that can run for 90 seconds,
    /// so a stalled fetch and a running model looked identical. No percentage is invented:
    /// the remaining work is genuinely unknown, so the stage is named instead.
    @State private var narratingStage: [String: StockSageCatalystNarrator.Stage] = [:]
    /// The citable news/filing/insider sources fetched for the LAST "Explain" press on each
    /// symbol — kept so `narrationPanel` can render the numbered source list (and its count for
    /// `label(for:sourceCount:)`) alongside the paragraph it actually backed.
    @State private var narrationSources: [String: [StockSageCatalystNarrator.CitedSource]] = [:]
    @State private var narrationNews: [String: StockSageNewsService.Observation] = [:]
    /// The OUTCOME of the last filings check per symbol, not just its rows: a denied or failed
    /// fetch also yields zero filings, and this view must not print that as "nothing was filed".
    @State private var filingsOutcome: [String: StockSageDisclosureService.FilingsObservation] = [:]
    @State private var filingsLoading: Set<String> = []
    @State private var filingsFetched: Set<String> = []

    // MARK: - Explanation model settings (owner request 2026-09-06)

    @AppStorage("marketsCatalystsModelSettingsExpanded") private var modelSettingsExpanded = false
    @AppStorage(StockSageLocalModelServer.backendKey) private var backendRaw: String = "auto"
    @AppStorage(StockSageLocalModelServer.urlKey) private var serverURL: String = StockSageLocalModelServer.defaultURL
    @AppStorage(StockSageLocalModelServer.modelKey) private var serverModel: String = StockSageLocalModelServer.defaultModel
    @State private var probeState = ConnectionProbeState()
    private var probe: StockSageLocalModelServer.Probe? { probeState.current(for: explanationRequestSettings) }
    private var probing: Bool { probeState.isProbing(for: explanationRequestSettings) }

    /// Shared state transitions for manual and automatic connection checks.
    struct ConnectionProbeState {
        private var result: StockSageLocalModelServer.Probe?
        private var settings: [String]?
        private var requestID: UUID?
        private(set) var probing = false

        mutating func begin(settings: [String]) -> UUID {
            let id = UUID()
            result = nil
            self.settings = settings
            requestID = id
            probing = true
            return id
        }

        mutating func finish(_ result: StockSageLocalModelServer.Probe?, request: UUID,
                             currentSettings: [String], cancelled: Bool) {
            // A superseded completion owns neither the displayed result nor the spinner.
            guard requestID == request else { return }
            defer { requestID = nil; probing = false }
            self.result = !cancelled && settings == currentSettings ? result : nil
        }

        func current(for settings: [String]) -> StockSageLocalModelServer.Probe? {
            self.settings == settings ? result : nil
        }

        func isProbing(for settings: [String]) -> Bool { self.settings == settings && probing }
    }

    private var backendBinding: Binding<StockSageLocalModelServer.Backend> {
        Binding(get: { StockSageCatalystNarrator.selectedNarrationBackend(backendRaw) },
               set: { updateModelSetting($0.rawValue, key: StockSageLocalModelServer.backendKey) })
    }

    private func updateModelSetting(_ value: String, key: String) {
        if StockSageAIAssessments.shared.setModelSetting(value, for: key) {
            StockSagePaperAutomation.shared.cancelResearchForSettingsChange()
        }
    }

    /// Color for the combined status line: green once a probe has actually confirmed the model
    /// is present, amber otherwise (including "never probed yet") — never claims success it
    /// hasn't measured.
    private var probeStatusColor: Color {
        guard let probe else { return DS.Palette.textSecondary }
        return (probe.reachable && probe.hasModel) ? DS.Palette.successSoft : DS.Palette.warningSoft
    }

    /// Structured task identity: no delimiter collisions between URL/model settings.
    private var explanationSettings: [String] { [backendRaw, serverURL, serverModel] }
    /// The revision distinguishes A→B→A while a source fetch or probe is suspended.
    private var explanationRequestSettings: [String] {
        Self.narrationCacheSettings(explanationSettings, revision: StockSageLocalModelServer.settingsRevision())
    }

    /// [network-safety-warn-first], fix pass 2026-09-06 (review blocker): true whenever the
    /// PERSISTED server settings parse to a non-loopback host, independent of which backend is
    /// currently selected — so this goes true the moment a viewer types a LAN address into the
    /// field, exactly like the header warning always intended, and stays true across app
    /// restarts (it reads `@AppStorage`, not one-shot local state).
    private var isNonLoopbackConfig: Bool {
        #if os(iOS)
        return false // The phone explanation flow never uses a model server.
        #else
        guard let config = StockSageLocalModelServer.config(url: serverURL, model: serverModel) else { return false }
        return config.requiresExternalAccess
        #endif
    }

    /// True only when an "Explain" press (or the auto-probe) would ACTUALLY reach out to that
    /// non-loopback host — `.onDeviceOnly` never touches `StockSageLocalModelServer` at all, so a
    /// saved-but-unused LAN address must not scare a viewer who isn't using it. Both `.auto` and
    /// `.localServerOnly` probe the server as part of `explain(_:)`, so both count here.
    private var explainMayLeaveDevice: Bool {
        guard isNonLoopbackConfig else { return false }
        let backend = StockSageCatalystNarrator.selectedNarrationBackend(backendRaw)
        return backend == .auto || backend == .localServerOnly
    }

    private func testConnection() {
        guard !probing else { return }
        let settings = explanationRequestSettings
        let request = probeState.begin(settings: settings)
        let config = StockSageLocalModelServer.config(url: serverURL, model: serverModel)
        Task {
            let result = await StockSageCatalystNarrator.probeServer(config: config,
                stillValid: { settings == explanationRequestSettings })
            probeState.finish(result, request: request, currentSettings: explanationRequestSettings,
                              cancelled: Task.isCancelled)
        }
    }

    /// Auto-probes when the selected backend can actually use a server (`.auto`/`.localServerOnly`)
    /// — `.onDeviceOnly`/`.off` never need one, so this no-ops there rather than pinging a server
    /// nobody asked for.
    private func probeIfBackendNeedsServer() async {
        #if os(iOS)
        // Phone explanations use only the built-in model and captured records.
        probeState = .init()
        return
        #else
        guard !StockSageStore.isRunningTests, !Task.isCancelled else { return }
        let backend = StockSageCatalystNarrator.selectedNarrationBackend(backendRaw)
        guard backend == .auto || backend == .localServerOnly else {
            probeState = .init()
            return
        }
        let settings = explanationRequestSettings
        let request = probeState.begin(settings: settings)
        let config = StockSageLocalModelServer.config(url: serverURL, model: serverModel)
        let result = await StockSageCatalystNarrator.probeServer(config: config,
            stillValid: { settings == explanationRequestSettings })
        probeState.finish(result, request: request, currentSettings: explanationRequestSettings,
                          cancelled: Task.isCancelled)
        #endif
    }

    #if os(macOS)
    @ScaledMetric(relativeTo: .callout) private var metadataSize: CGFloat = 13
    #else
    @ScaledMetric(relativeTo: .caption) private var metadataSize: CGFloat = 12
    #endif
    #if os(macOS)
    @ScaledMetric(relativeTo: .callout) private var font11: CGFloat = 13
    @ScaledMetric(relativeTo: .callout) private var font11_5: CGFloat = 13
    #else
    @ScaledMetric(relativeTo: .caption2) private var font11: CGFloat = 11
    @ScaledMetric(relativeTo: .caption2) private var font11_5: CGFloat = 11.5
    #endif
    @ScaledMetric(relativeTo: .caption2) private var font12: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var font13: CGFloat = 13
    @ScaledMetric(relativeTo: .caption2) private var font15: CGFloat = 15

    var body: some View {
        // `now` and `briefs` computed ONCE per body (SWIFT_PITFALLS #11: no per-row recompute)
        // and the narrator availability read once too — it is a small, but non-zero, system
        // property read and up to ~450 rows must not each pay for it separately.
        let now = Date()
        let briefs = buildBriefs(now: now)
        let availability = StockSageCatalystNarrator.availability
        #if os(macOS)
        let entries = Self.periodEntries(
            StockSageCatalystWatch.calendar(briefs, now: now), period: period, now: now)
        #endif
        VStack(alignment: .leading, spacing: DS.Space.md) {
            #if os(macOS)
            headerCard(briefs: briefs, availability: availability, now: now, entries: entries)
            #else
            headerCard(briefs: briefs, availability: availability)
            #endif
            if !ideas.isEmpty {
                #if os(macOS)
                periodContent(briefs: briefs, entries: entries, now: now, availability: availability)
                #else
                switch mode {
                case .cards:
                    // LazyVStack, not VStack — up to ~450 briefs (see `buildBriefs`), and the
                    // Ideas tab this view mirrors already made this call (SWIFT_PITFALLS #10/#11;
                    // fix pass 2026-09-06). The parent MarketsView scroll container is what makes
                    // the laziness real; this view only needs to not defeat it.
                    LazyVStack(alignment: .leading, spacing: DS.Space.md) {
                        ForEach(briefs) { catalystCard($0, availability: availability) }
                    }
                case .calendar:
                    calendarBody(briefs: briefs, now: now)
                }
                #endif
            }
            // Events stay ahead of setup even when the saved disclosure is expanded.
            Divider()
            explanationModelSettings(availability: availability)
                .id("catalysts-model-settings")
        }
        .task(id: explanationRequestSettings) { await probeIfBackendNeedsServer() }
        #if os(macOS)
        .task(id: periodClockRevision) { await waitForNextUTCMidnight() }
        .onChange(of: scenePhase, initial: true) {
            if scenePhase == .active { periodClockRevision &+= 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSSystemClockDidChange)) { _ in
            periodClockRevision &+= 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            periodClockRevision &+= 1
        }
        #endif
        .onDisappear { probeState = .init() }
    }

    #if os(macOS)
    private func waitForNextUTCMidnight() async {
        guard !StockSageStore.isRunningTests, !Task.isCancelled else { return }
        let now = Date()
        let seconds = max(1, Self.periodInterval(.today, now: now).end.timeIntervalSince(now) + 0.1)
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        catch { return }
        guard !Task.isCancelled else { return }
        periodClockRevision &+= 1
    }
    #endif

    // MARK: - Data

    /// `store.earnings` is a COMPUTED property (re-derives the whole proximity dictionary from
    /// `earningsDates` on every read) and `store.catalysts` was scanned linearly per idea — both
    /// were paid once PER IDEA here (review minor (c), fix pass 2026-09-06). Hoisted to once per
    /// body: `earnings` is read once, and `catalysts` is indexed into a dictionary once, so up to
    /// ~450 ideas each do an O(1) lookup instead of an O(n) rescan / a full re-derive.
    private func buildBriefs(now: Date) -> [StockSageCatalystWatch.Brief] {
        let earnings = store.earnings
        let catalystsBySymbol = Dictionary(store.catalysts.map { ($0.symbol.uppercased(), $0) },
                                           uniquingKeysWith: { first, _ in first })
        return ideas.map { idea in
            let sym = idea.symbol.uppercased()
            // W1 (2026-09-06): the store's full chain record, when it has one — feeds the
            // confirmed-suffix / projected-date / notApplicable additions below. A symbol the
            // chain hasn't reached yet (nil) renders exactly as before W1.
            let record = store.catalystChain[sym]
            let isProjected = record?.status == .projected
            return StockSageCatalystWatch.brief(for: idea, inputs: .init(
                earnings: earnings[sym], earningsDate: store.earningsDates[sym],
                earningsCheckedAt: store.earningsCheckedAt[sym],
                volumeMove: catalystsBySymbol[sym], regime: store.regimeIsStale ? nil : store.regime, regimeGaugedAt: store.regimeGaugedAt,
                seasonality: store.seasonality[sym], now: now,
                catalystConfirmed: record?.confirmed,
                catalystSource: record?.source ?? "Source unavailable",
                catalystNotApplicable: record?.status == .notApplicable,
                catalystProjectedDate: isProjected ? record?.earningsDate : nil,
                catalystProjectionBasis: isProjected ? record?.projectionBasis : nil,
                catalystSourcesAsked: record?.sourcesAsked ?? [],
                companyEvents: (store.companyEventChecks[sym] ?? [:]).values.compactMap {
                    $0.outcome == .answered && $0.fresh(at: now) ? $0.event : nil
                }))
        }
    }

    // MARK: - Header card

    nonisolated static func ideasRecoveryState(visibleCount: Int, totalCount: Int, loading: Bool,
        filteredMessage: String) -> (message: String, action: String)? {
        guard visibleCount == 0 else { return nil }
        if totalCount > 0 { return (filteredMessage, "Open Rules screener") }
        return (loading ? "Rules scan in progress. Results will appear here as ideas become available."
            : "No ideas yet. Open Rules screener to choose and run a scan.", "Open Rules screener")
    }

    @ViewBuilder
    static func ideasRecovery(visibleCount: Int, totalCount: Int, loading: Bool,
        filteredMessage: String, error: String? = nil, openIdeas: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let state = ideasRecoveryState(visibleCount: visibleCount, totalCount: totalCount,
                                             loading: loading, filteredMessage: filteredMessage) {
                Text(state.message).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(state.action, action: openIdeas)
                    .help("Open Library → Rules screener without changing filters or starting a scan.")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func headerCard(briefs: [StockSageCatalystWatch.Brief],
                            availability: StockSageCatalystNarrator.Availability,
                            now: Date? = nil, entries: [StockSageCatalystWatch.CalendarEntry]? = nil) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                #if os(iOS)
                Text("Saved events & explanations")
                    .font(.system(size: font15, weight: .semibold)).foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text("Retained event context from saved research. Dates and source records may be old; this phone does not monitor or refresh market events.")
                    .font(.callout).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                #else
                Text("Catalysts to watch")
                    .font(.system(size: font15, weight: .semibold)).foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text("Events and dated evidence for your current Ideas, in ranked order.")
                    .font(.callout).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                #if os(macOS)
                if let now, let entries {
                    Picker("Catalyst period", selection: $period) {
                        ForEach(Period.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                    HStack {
                        Text("\(Self.periodRangeLabel(period, now: now)) · UTC · Mon–Sun")
                        Spacer()
                        Picker("View", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu).fixedSize()
                    }
                    .font(.system(size: font11, weight: .medium))
                    Text(Self.periodCountLabel(entries) + " · Current Ideas filters; recent coverage is limited.")
                        .font(.system(size: metadataSize)).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if period == .thisMonth {
                        Text("This Month filters retained observations; it is not a complete monthly event archive.")
                            .font(.system(size: metadataSize)).foregroundStyle(DS.Palette.warningSoft)
                    }
                }
                #else
                DSSegmentPicker(cases: Mode.allCases, selection: $mode) { $0.title }.frame(maxWidth: 260)
                    .accessibilityLabel("Catalyst view")
                #endif
                #if os(iOS)
                if ideas.isEmpty {
                    Text("No saved event context is available. Your recorded prices, holdings and journal remain available in Watchlist and Portfolio.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #else
                Self.ideasRecovery(visibleCount: ideas.count, totalCount: store.ideas.count,
                    loading: store.isLoadingIdeas, filteredMessage: ideasFilterMessage,
                    error: store.ideasError, openIdeas: onOpenIdeas)
                    .font(.system(size: font11_5))
                if let regime = store.regime {
                    let gaugedStr = store.regimeGaugedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "not yet"
                    Text("Regime: \(regime.state.rawValue) · sizing bias ×\(String(format: "%.2f", regime.sizingBias)) · gauged \(gaugedStr)")
                        .font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(regime.caveat + " " + store.regimeEvidenceText)
                    Text(store.regimeIsStale ? "Stale gauge — re-gauge before relying on it." : store.regimeEvidenceText)
                        .font(.system(size: metadataSize)).foregroundStyle(store.regimeIsStale ? DS.Palette.warningSoft : DS.Palette.textSecondary)
                }
                #endif
            }
            Divider()
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Label("Evidence status", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Group {
                    #if os(iOS)
                    Text("Saved research and AI explanations are unvalidated context. They do not establish current prices, verified events or a trade recommendation.")
                    #else
                    Text("AI badges are unvalidated; failed checks stay drafts. Rules actions, sizing and execution checks remain separate.")
                    #endif
                }
                    .font(.system(size: metadataSize)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
                // Honesty-floor label — always visible, never collapsible.
                Text(StockSageCatalystWatch.caveat)
                    .font(.system(size: font11_5)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if store.isSampleData {
                    Text("Sample data — nothing here is a real catalyst.")
                        .font(.system(size: font11_5)).foregroundStyle(DS.Palette.warningSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .unavailable(let reason) = availability {
                    Text(reason).font(.system(size: metadataSize)).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Label("Sources & privacy", systemImage: "network")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                // [network-safety-warn-first], fix pass 2026-09-06 (review blocker): this banner used
                // to live ONLY inside `explanationModelSettings`'s `DisclosureGroup`, which defaults
                // to collapsed — so it was invisible unless a viewer had already opened the settings
                // panel. Hoisted here, into the header's always-visible (never collapsible) section,
                // so it renders on first appearance of this tab — before the auto-probe below ever
                // fires and before any "Explain" press — regardless of whether the panel is expanded.
                #if os(iOS)
                Text("Explanations use the facts already shown here with Apple's on-device model when available. No market-data account, API key or model server is required. Opening a source link uses your browser.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #else
                if isNonLoopbackConfig { nonLoopbackWarning() }
                DisclosureGroup("Where checks and explanations send data") {
                    Text("When external access is enabled, daily checks send tracked US tickers to api.massive.com for ratings, guidance, filings and dividends. Explain sends its ticker to api.massive.com (hourly news), sec.gov (filings/insider trades) and the selected narrator. EODHD is disabled. Events are not trade signals; missing events do not establish absence. See Cards for coverage.")
                        .font(.system(size: metadataSize)).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: metadataSize))
                if !store.companyEventCacheSaved {
                    Text("Company-event cache could not be saved; checks may repeat after relaunch.")
                        .font(.system(size: metadataSize)).foregroundStyle(DS.Palette.warningSoft)
                }
                #endif
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    @ViewBuilder
    private func explanationModelSettings(availability: StockSageCatalystNarrator.Availability) -> some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 10) {
            Label("Apple Intelligence", systemImage: "sparkles").font(.headline)
            Toggle("On-device AI explanations", isOn: Binding(
                get: { backendRaw != "off" },
                set: { updateModelSetting($0 ? "onDeviceOnly" : "off", key: StockSageLocalModelServer.backendKey) }))
            Text("Free explanations using the model built into this device. No separate AI app, account, API key or manual model download.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(onDeviceStatusLine(availability))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The app's original facts and rules remain available when AI is unavailable. AI text can be wrong; calculations and source records stay separate.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        #else
        DisclosureGroup(isExpanded: $modelSettingsExpanded) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Picker("Backend", selection: backendBinding) {
                    ForEach(StockSageLocalModelServer.Backend.allCases, id: \.self) { backend in
                        Text(backend.title).tag(backend)
                    }
                }
                .pickerStyle(.menu)
                #if os(macOS)
                Button("Use RunPod GPU · Gemma 4 31B") {
                    updateModelSetting("localServerOnly", key: StockSageLocalModelServer.backendKey)
                    updateModelSetting(StockSageLocalModelServer.runPodURL, key: StockSageLocalModelServer.urlKey)
                    updateModelSetting(StockSageLocalModelServer.gemmaModel, key: StockSageLocalModelServer.modelKey)
                    automaticModelStartup = false
                }
                if StockSageLocalModelServer.config(url: serverURL, model: serverModel)?.isRunPodGemma == true {
                    Text("Gemma runs on the RunPod GPU through your private connection. Research gathers Massive data and saves results on this Mac. The GPU server and connection must be running; there is no on-device fallback.")
                        .font(.system(size: metadataSize)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Use LM Studio · Gemma 4 31B") {
                    updateModelSetting("localServerOnly", key: StockSageLocalModelServer.backendKey)
                    updateModelSetting(StockSageLocalModelServer.lmStudioURL, key: StockSageLocalModelServer.urlKey)
                    updateModelSetting(StockSageLocalModelServer.gemmaModel, key: StockSageLocalModelServer.modelKey)
                    automaticModelStartup = true
                    StockSageLocalModelStartup.shared.startFromSavedSettings()
                }
                if StockSageLocalModelServer.config(url: serverURL, model: serverModel)?.isLMStudioGemma == true {
                    Toggle("Load Gemma when StockSage opens", isOn: $automaticModelStartup)
                        .onChange(of: automaticModelStartup) {
                            if automaticModelStartup { StockSageLocalModelStartup.shared.startFromSavedSettings() }
                        }
                    Text(StockSageLocalModelStartup.shared.message ?? "Gemma loads automatically before AI use. Startup loading also opens LM Studio; enable its server auto-start setting.")
                        .font(.system(size: metadataSize)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Moved from the retired 9B download block (Qwen removal Step 5): this is the
                    // only disclosure of the quit-unload contract, and it applies to any managed
                    // local model, not just the one that used to render it.
                    Text("Quitting StockSage unloads the selected local model from memory; downloaded files stay on disk. Force Quit cannot run this cleanup.")
                        .font(.system(size: metadataSize)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                #endif
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server URL").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Server URL", text: Binding(get: { serverURL }, set: { updateModelSetting($0, key: StockSageLocalModelServer.urlKey) }))
                        .font(.system(.body, design: .monospaced)).autocorrectionDisabled()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Model", text: Binding(get: { serverModel }, set: { updateModelSetting($0, key: StockSageLocalModelServer.modelKey) }))
                        .font(.system(.body, design: .monospaced)).autocorrectionDisabled()
                }
                Button(probing ? "Testing…" : "Test connection") { testConnection() }
                    .buttonStyle(.bordered).touchHitArea().disabled(probing)
                    .font(.system(size: font11)).foregroundStyle(DS.Palette.accentText)
                Text("On-device: \(onDeviceStatusLine(availability)) Model server: \(probe?.detail ?? "not tested yet.")")
                    .font(.system(size: font11)).foregroundStyle(probeStatusColor)
                    .fixedSize(horizontal: false, vertical: true)
                // The full [network-safety-warn-first] warning now renders unconditionally in the
                // always-visible header above (see `isNonLoopbackConfig` there) — not duplicated
                // here so there is exactly one place this sentence can drift from the code that
                // gates it.
            }
            .padding(.top, DS.Space.xs)
        } label: {
            Text("Explanation model").font(.system(size: font11, weight: .medium)).foregroundStyle(DS.Palette.textSecondary)
        }
        #endif
    }

    /// [network-safety-warn-first]: the risk statement itself, in ONE place — rendered
    /// unconditionally in the header (see `isNonLoopbackConfig` above it) and, in `compact` form,
    /// inline on every card next to "Explain" (see `explainMayLeaveDevice`) so it is visible at
    /// the point of the actual action regardless of scroll position, not only in a header that
    /// can scroll off-screen. `compact` deliberately still names the concrete consequence ("leaves
    /// this device") rather than a bare icon — a warning nobody reads because it was shortened to
    /// meaninglessness is not a warning.
    @ViewBuilder
    private func nonLoopbackWarning(compact: Bool = false) -> some View {
        let cloud = StockSageLocalModelServer.config(url: serverURL, model: serverModel)?.isRunPodGemma == true
        Text(cloud ? "RunPod GPU: supplied research facts leave this Mac through your encrypted private connection." : compact
            ? "Not loopback — this will send the facts above over your network."
            : "Not loopback: the facts (symbol, price, stop, target) will leave this device "
                + "over your network. Prefer 127.0.0.1 or a Tailscale address. Plain-HTTP LAN "
                + "calls also need the local-networking allowance this build does not set.")
            .font(.system(size: metadataSize)).foregroundStyle(DS.Palette.warningSoft)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func onDeviceStatusLine(_ availability: StockSageCatalystNarrator.Availability) -> String {
        if case .unavailable(let reason) = availability { return reason }
        return "available."
    }

    // MARK: - Cards mode

    @ViewBuilder
    private func catalystCard(_ brief: StockSageCatalystWatch.Brief,
                              availability: StockSageCatalystNarrator.Availability) -> some View {
        let idea = brief.idea
        let primary = brief.primary
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            cardHeader(brief)
            whyBullets(primary.why)
            Text("Watch: \(primary.watch)")
                .font(.system(size: font11)).foregroundStyle(Color.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if !brief.secondary.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.xs) {
                        ForEach(brief.secondary) { secondaryChip($0) }
                    }
                }
            }
            if let caveat = primary.caveat {
                Text(caveat).font(.system(size: font11)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Source: \(primary.source)")
                .font(.system(size: metadataSize)).foregroundStyle(DS.Palette.textSecondary)
            if let url = primary.sourceURL {
                Link("Read source record", destination: url).font(.system(size: font11)).touchHitArea()
            }
            companyFeedCoverage(idea.symbol)
            cardButtons(brief, availability: availability)
            if expanded.contains(idea.symbol) { filingsPanel(idea.symbol) }
            narrationPanel(brief)
        }
        .padding(DS.Space.lg)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    /// Row 1 (symbol/action/price/weight) + row 2 (kind icon/headline/date) — one tappable
    /// header that also opens the detail sheet, grouped as one accessibility container.
    @ViewBuilder
    private func cardHeader(_ brief: StockSageCatalystWatch.Brief) -> some View {
        let idea = brief.idea
        let primary = brief.primary
        let content = VStack(alignment: .leading, spacing: DS.Space.xxs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.xs) {
                    Text(idea.symbol).font(.system(size: font13, weight: .bold, design: .rounded)).foregroundStyle(.white).fixedSize()
                    actionCapsule(idea).fixedSize()
                    Text(StockSageCurrency.adaptivePrice(idea.price)).font(.system(size: font11)).monospacedDigit().fixedSize()
                    Spacer()
                    Self.weightDot(primary.weight)
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack {
                        Text(idea.symbol).font(.system(size: font13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        Spacer()
                        Self.weightDot(primary.weight)
                    }
                    actionCapsule(idea)
                    Text(StockSageCurrency.adaptivePrice(idea.price)).font(.system(size: font11)).monospacedDigit()
                }
            }
            HStack(alignment: .top, spacing: DS.Space.xs) {
                Image(systemName: rowIconName(for: brief)).font(.system(size: font11)).foregroundStyle(DS.Palette.accentText)
                Text(primary.headline).font(.system(size: font12, weight: .semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = primary.date {
                    Text(StockSageCatalystWatch.dateStr(date))
                        .font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
        #if os(macOS)
        Button { onSelect(idea) } label: { content.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel("\(idea.symbol): \(primary.headline)")
            .accessibilityHint("Open stock details")
        #else
        content.contentShape(Rectangle())
            .onTapGesture { onSelect(idea) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(idea.symbol): \(primary.headline)")
        #endif
    }

    @ViewBuilder
    private func whyBullets(_ why: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(why.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .top, spacing: 6) {
                    // Fixed-size decorative bullet (mirrors the idea detail sheet's "Why" list) —
                    // accessibilityHidden since the row-level label below already speaks the text.
                    Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.secondary)
                        .padding(.top, 5).accessibilityHidden(true)
                    Text(bullet).font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Why: \(why.joined(separator: ". "))")
    }

    @ViewBuilder
    private func secondaryChip(_ item: StockSageCatalystWatch.Item) -> some View {
        // `.help` alone is hover-only — invisible on iPhone, where a demoted RVOL move (or
        // regime/seasonality item) would otherwise show its "unvalidated"/caveat text nowhere
        // (fix pass 2026-09-06). The caveat renders below the chip so it's visible on every
        // platform, not only under a mouse cursor.
        VStack(alignment: .leading, spacing: 2) {
            Text(item.headline)
                .font(.system(size: metadataSize)).foregroundStyle(DS.Palette.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(Capsule().stroke(DS.Palette.surfaceStroke, lineWidth: 1))
            if let caveat = item.caveat {
                Text(caveat).font(.system(size: metadataSize)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            if let url = item.sourceURL {
                Link("Read \(item.source)", destination: url).font(.system(size: metadataSize)).touchHitArea()
            }
        }
        .help(item.why.joined(separator: " "))
    }

    @ViewBuilder
    private func companyFeedCoverage(_ symbol: String) -> some View {
        if StockSageMassive.covers(symbol) {
            let records = store.companyEventChecks[symbol.uppercased()] ?? [:]
            let now = Date()
            let checked = records.values.filter { $0.outcome == .answered && $0.fresh(at: now) }.count
            DisclosureGroup("Company feeds: \(checked)/5 current checks") {
                ForEach(StockSageMassiveEvents.Feed.allCases, id: \.rawValue) { feed in
                    Text(StockSageMassiveEvents.statusLine(feed, observation: records[feed], now: now))
                        .font(.system(size: metadataSize)).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: metadataSize)).foregroundStyle(DS.Palette.textSecondary)
        }
    }

    @ViewBuilder
    private func cardButtons(_ brief: StockSageCatalystWatch.Brief,
                             availability: StockSageCatalystNarrator.Availability) -> some View {
        let idea = brief.idea
        let explainShown = StockSageCatalystNarrator.explainAvailable(
            backend: StockSageCatalystNarrator.selectedNarrationBackend(backendRaw), onDevice: availability, probe: probe)
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.md) {
                #if os(macOS)
                Button("Details") { onSelect(idea) }
                    .buttonStyle(.plain).touchHitArea()
                if StockSageMassive.covers(idea.symbol) {
                    Button(expanded.contains(idea.symbol) ? "Hide filings" : "Filings") { toggleFilings(idea.symbol) }
                        .buttonStyle(.plain).touchHitArea()
                }
                #endif
                if explainShown {
                    Button("Explain") { explainOnDevice(brief) }
                        .buttonStyle(.plain).touchHitArea()
                        .disabled(narrating.contains(idea.symbol))
                }
            }
            .font(.system(size: font11)).foregroundStyle(DS.Palette.accentText)
            // [network-safety-warn-first], fix pass 2026-09-06 (review blocker): the header's
            // warning scrolls off-screen together with the rest of the header on any card list
            // long enough to scroll (up to ~450 briefs) — restated here, right next to the actual
            // "Explain" button, so the risk is visible at the point of the action regardless of
            // scroll position. `explainMayLeaveDevice` already excludes `.onDeviceOnly` (which
            // never contacts the server), so this never appears next to a press that stays local.
            if explainShown && explainMayLeaveDevice {
                nonLoopbackWarning(compact: true)
            }
        }
    }

    @ViewBuilder
    private func filingsPanel(_ symbol: String) -> some View {
        if filingsLoading.contains(symbol) {
            ProgressView().controlSize(.small)
        } else if let observation = filingsOutcome[symbol] {
            // The FAILED branch is tested FIRST on purpose: a denied or never-completed fetch
            // returns the same zero rows as a company that filed nothing, so ordering the
            // empty-list branch ahead of it would print a negative finding for a check that did
            // not run. "SEC EDGAR" names the direct submissions feed, distinct from the
            // "Massive/SEC 8-K" line `companyFeedCoverage` renders over a different window.
            if case .unavailable(let failure) = observation.outcome {
                Text("SEC EDGAR 8-K: unavailable at \(StockSageCatalystWatch.dateStr(observation.checkedAt)), "
                     + "not an empty result. " + failure.message)
                    .font(.system(size: font11)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else if observation.filings.isEmpty {
                Text("No 8-K found in the window we looked at — that is not evidence that nothing was filed.")
                    .font(.system(size: font11)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(observation.filings.prefix(5)) { filing in
                        let when = StockSageDisclosureService.publicFor(filing)
                            ?? filing.filingDate.formatted(date: .abbreviated, time: .omitted)
                        Text("8-K · \(filing.itemDescriptions.joined(separator: ", ")) · \(when)")
                            .font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func narrationPanel(_ brief: StockSageCatalystWatch.Brief) -> some View {
        let symbol = brief.idea.symbol
        // Outside the `narrations[symbol]` binding on purpose: a press that aborted before it ever
        // published must say so even when there is no previous paragraph to annotate.
        if !narrating.contains(symbol), let abortReason = narrationAborted[symbol] {
            Text(abortReason)
                .font(.system(size: font11, weight: .semibold)).foregroundStyle(DS.Palette.warningSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        if narrating.contains(symbol) {
            ProgressView(narratingStage[symbol]?.label ?? StockSageCatalystNarrator.Stage.sources.label)
                .controlSize(.small)
        } else if let result = narrations[symbol] {
            let sources = narrationSources[symbol] ?? []
            let refreshReason = Self.narrationRefreshReason(
                savedFacts: narrationBaseFacts[symbol], currentFacts: StockSageCatalystNarrator.facts(for: brief),
                savedSettings: narrationSettings[symbol],
                currentSettings: Self.narrationCacheSettings(explanationSettings,
                    revision: StockSageLocalModelServer.settingsRevision()))
            if let refreshReason {
                Text("Previous explanation — not current. " + refreshReason)
                    .font(.system(size: font11, weight: .semibold)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch result {
            case .text(let text, let source), .unverified(let text, let source, _):
                VStack(alignment: .leading, spacing: 3) {
                    if case .unverified(_, _, let reason) = result {
                        Text("Unverified draft — \(reason)")
                            .font(.system(size: font11, weight: .semibold)).foregroundStyle(DS.Palette.warningSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(verbatim: text).font(.system(size: font11_5)).foregroundStyle(DS.Palette.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Group {
                        #if os(iOS)
                        Text(StockSageCatalystNarrator.label(for: source)
                             + " Based on the saved facts below; no new market sources were retrieved.")
                        #else
                        Text(StockSageCatalystNarrator.label(for: source)
                             + " Numbered news/SEC sources: \(sources.count). Benzinga products are shown separately.")
                        #endif
                    }
                        .font(.system(size: metadataSize)).foregroundStyle(DS.Palette.warningSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .unavailable(let msg):
                Text(msg).font(.system(size: font11)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let facts = narrationFacts[symbol] {
                DisclosureGroup("Original supplied facts for this explanation") {
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                        Text(verbatim: fact).font(.system(size: metadataSize)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
            }
            if let notes = narrationEvidenceNotes[symbol] {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    Text(note).font(.system(size: metadataSize)).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let news = narrationNews[symbol] {
                Text(news.summary).font(.system(size: metadataSize)).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let checkedAt = news.attempts.last?.checkedAt, !news.items.isEmpty {
                    DisclosureGroup("Local headline sentiment · optional") {
                        ForEach(news.items) { item in
                            StockSageLocalSentimentView(evidence: .init(item: item, symbol: symbol, checkedAt: checkedAt),
                                evidenceCurrent: refreshReason == nil && ToolPolicy.isExternalAllowed)
                        }
                    }
                    .font(.system(size: metadataSize))
                }
            }
            if let evidence = narrationBenzinga[symbol] {
                StockSageBenzingaEvidenceView(capturedSnapshot: evidence)
            }
            if !sources.isEmpty { Self.sourceList(sources) }
        }
    }

    /// Cache identity only; request admission retains its independent revision guard.
    nonisolated static func narrationCacheSettings(_ settings: [String], revision: String?) -> [String] {
        settings + [revision ?? ""]
    }

    /// Shared display decision, separate from SwiftUI state so lifecycle changes are testable.
    nonisolated static func narrationRefreshReason(savedFacts: [String]?, currentFacts: [String],
                                                   savedSettings: [String]?, currentSettings: [String]) -> String? {
        guard savedFacts == currentFacts else {
            return "Facts changed since this explanation. Tap Explain to refresh it."
        }
        guard savedSettings == currentSettings else {
            return "Model settings changed since this explanation. Tap Explain with your chosen settings to refresh it."
        }
        return nil
    }

    /// Why an in-flight "Explain" stopped before it published anything — pure, so both branches
    /// are pinnable without a running app. A superseded press is the viewer's own doing and says
    /// so; every other abort (the evidence capture aged out, external access was turned off) must
    /// NOT be reported as a settings change it wasn't. Neither branch claims the paragraph below
    /// is gone: it is retained on purpose, so the copy names it as the PREVIOUS one.
    nonisolated static func narrationAbortReason(settingsChanged: Bool) -> String {
        if settingsChanged {
            return "Explanation stopped — model settings changed while it was running. "
                + "Any explanation shown below is the PREVIOUS one. Tap Explain to run it with the current settings."
        }
        return "Explanation stopped before it finished — the cited sources or external access changed while it was "
            + "running. Any explanation shown below is the PREVIOUS one. Tap Explain to try again."
    }

    /// The numbered "[n] title · date · link" list the paragraph above may have cited — one row
    /// per source, in the SAME order `facts(for:sources:)` numbered them, so "[2]" in the text
    /// always matches the 2nd row here. A source with no link renders its title/date only (never
    /// a dead tap target).
    @ViewBuilder
    static func sourceList(_ sources: [StockSageCatalystNarrator.CitedSource]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(sources.enumerated()), id: \.offset) { i, source in
                let dateStr = StockSageCatalystNarrator.sourceDate(source) + (source.publicationTime == nil ? " UTC" : "")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 4) {
                        Text("[\(i + 1)]")
                        if let link = source.link {
                            Link(destination: link) {
                                Text("\(source.title) · \(dateStr)")
                            }.buttonStyle(.plain)
                        } else {
                            Text("\(source.title) · \(dateStr)")
                        }
                    }
                    Text(source.source)
                    if let updated = source.updatedTime { Text("Updated \(updated)") }
                    if !source.snippet.isEmpty { Text(source.snippet) }
                    if let insight = source.insight { Text("Provider sentiment: \(insight)") }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(StockSageNewsService.caveat).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption).foregroundStyle(DS.Palette.textSecondary)
    }

    // MARK: - Cards mode: row actions

    private func toggleFilings(_ symbol: String) {
        if expanded.contains(symbol) {
            expanded.remove(symbol)
            return
        }
        expanded.insert(symbol)
        guard !filingsFetched.contains(symbol) else { return }
        filingsLoading.insert(symbol)
        Task {
            defer { filingsLoading.remove(symbol) }
            let observation = await StockSageDisclosureService.recentFilingsObservation(
                for: symbol, forms: ["8-K"], limit: 5)
            guard !Task.isCancelled else { return }
            // Always publish the outcome — INCLUDING the policy denial, which is why the button
            // used to do nothing at all. Only an ANSWERED check is cached: an unavailable one
            // leaves `filingsFetched` alone so the next expand retries, instead of freezing a
            // failure into a permanent "nothing was filed".
            filingsOutcome[symbol] = observation
            if case .answered = observation.outcome { filingsFetched.insert(symbol) }
        }
    }

    private func explainOnDevice(_ brief: StockSageCatalystWatch.Brief) {
        let symbol = brief.idea.symbol
        guard !narrating.contains(symbol) else { return }
        narrating.insert(symbol)
        narrationAborted[symbol] = nil
        narratingStage[symbol] = .sources
        let facts = StockSageCatalystNarrator.facts(for: brief)
        let settings = Self.narrationCacheSettings(explanationSettings,
            revision: StockSageLocalModelServer.settingsRevision())
        let requestSettings = explanationRequestSettings
        Task {
            defer { narrating.remove(symbol); narratingStage[symbol] = nil }
            let active: @MainActor () -> Bool = {
                !Task.isCancelled && requestSettings == explanationRequestSettings
            }
            // Every bare return below abandons a press the viewer made. Record WHY, so the panel
            // can say the paragraph on screen is the previous one — or that there is none — rather
            // than leaving an abandoned press looking like a finished, current explanation.
            let markAborted: @MainActor () -> Void = {
                guard !Task.isCancelled else { return }
                narrationAborted[symbol] = Self.narrationAbortReason(
                    settingsChanged: requestSettings != explanationRequestSettings)
            }
            #if os(iOS)
            let notes = ["Saved app records only. No current event, news or filing check was performed; missing records do not prove an event's absence."]
            let suppliedFacts = StockSageCatalystNarrator.facts(for: brief, evidenceNotes: notes)
            guard active(), !suppliedFacts.isEmpty else { markAborted(); return }
            narratingStage[symbol] = .explaining
            let result = await StockSageCatalystNarrator.explain(brief,
                evidenceNotes: notes, stillValid: active)
            guard active() else { markAborted(); return }
            narrationBaseFacts[symbol] = facts
            narrationFacts[symbol] = suppliedFacts
            narrationEvidenceNotes[symbol] = notes
            narrationSettings[symbol] = settings
            narrationSources[symbol] = []
            narrationNews[symbol] = nil
            narrationBenzinga[symbol] = nil
            narrations[symbol] = result
            #else
            guard let (sources, news, evidence, evidenceNotes) = await Self.citedSources(for: symbol, stillValid: active) else {
                markAborted(); return
            }
            // Freeze both the source capture and settings across probe/inference/publication.
            let allowed: @MainActor () -> Bool = {
                active() && StockSageBenzingaClient.shared.isCurrent(evidence)
                    && (sources.isEmpty || ToolPolicy.isExternalAllowed)
            }
            guard allowed() else { markAborted(); return }
            let suppliedFacts = StockSageCatalystNarrator.facts(for: brief, sources: sources, benzinga: evidence, evidenceNotes: evidenceNotes)
            narratingStage[symbol] = .explaining
            let result = await StockSageCatalystNarrator.explain(brief, sources: sources, benzinga: evidence, evidenceNotes: evidenceNotes, stillValid: allowed)
            guard allowed() else { markAborted(); return }
            // Publish the response and its ORIGINAL context together, after the last await.
            // Retain prior snapshots; never publish a cancelled generation for new settings.
            narrationBaseFacts[symbol] = facts
            narrationFacts[symbol] = suppliedFacts
            narrationEvidenceNotes[symbol] = evidenceNotes
            narrationBenzinga[symbol] = evidence
            narrationSettings[symbol] = settings
            narrationSources[symbol] = sources
            narrationNews[symbol] = news
            narrations[symbol] = result
            #endif
        }
    }

    /// One product capture alongside existing SEC lookups; news fallback receives that capture's
    /// page, including empty/failed/unchecked outcomes, rather than fetching it independently.
    private static func citedSources(for symbol: String, stillValid: @MainActor () -> Bool) async
        -> ([StockSageCatalystNarrator.CitedSource], StockSageNewsService.Observation, StockSageBenzinga.Snapshot, [String])? {
        guard stillValid() else { return nil }
        let now = Date()
        async let evidenceTask = StockSageBenzingaClient.shared.snapshot(for: symbol, now: now)
        async let filingTask = StockSageDisclosureService.recentFilingsObservation(for: symbol, forms: ["8-K"], limit: 1)
        async let insiderTask = StockSageInsider.recentActivity(for: symbol)
        let (evidence, filings, insider) = await (evidenceTask, filingTask, insiderTask)
        guard stillValid(), StockSageBenzingaClient.shared.isCurrent(evidence) else { return nil }
        let page = evidence.pages.first { $0.query.product == .news && $0.query.subject == symbol }
            ?? StockSageBenzinga.Page(query: .init(product: .news, subject: symbol, from: nil, through: nil),
                checkedAt: evidence.capturedAt, credentialGeneration: evidence.credentialGeneration,
                status: .notChecked, records: [], excludedCount: 0, hasMore: false)
        let news = await StockSageNewsService.observation(for: symbol, now: now, benzingaPage: page)
        guard stillValid(), StockSageBenzingaClient.shared.isCurrent(evidence) else { return nil }
        guard ToolPolicy.isExternalAllowed else {
            var withheld = news
            withheld.withholdingReason = .policyDenied
            return ([], withheld, evidence, ["SEC evidence withheld because external access is disabled."])
        }
        var sources: [StockSageCatalystNarrator.CitedSource] = news.items.map { .init(news: $0) }
        var evidenceNotes = [StockSageCatalystNarrator.filingCoverage(filings)]
        if let filing = filings.filings.first {
            let title = filing.itemDescriptions.isEmpty ? "8-K filed" : filing.itemDescriptions.joined(separator: ", ")
            sources.append(.init(date: filing.filingDate, source: "SEC 8-K", title: title, snippet: "", link: filing.documentURL))
        }
        if let insider {
            evidenceNotes.append(insider.coverageDescription)
            // Publication date is separate from the trade date; an undated filing remains
            // unavailable for a dated citation, rather than borrowing the transaction clock.
            let citable = insider.discretionary.filter { $0.filingDate != nil && $0.documentURL != nil }
            for t in citable.prefix(3) {
                let verb = t.code == .openMarketPurchase ? "reported P purchase" : "reported S sale"
                let title = "\(t.insiderName): \(verb), \(t.shares) shares"
                sources.append(.init(date: t.filingDate!, source: "SEC Form 4", title: title,
                                     snippet: t.evidenceDescription, link: t.documentURL))
            }
            evidenceNotes.append("SEC Form 4 citation selection: \(min(3, citable.count)) of \(insider.discretionary.count) returned P/S rows shown. Omitted rows include the three-citation cap and unavailable filing dates/links; inspect the full filings before interpreting this subset.")
        } else {
            evidenceNotes.append("SEC Form 4 review unavailable or incomplete; no insider-activity absence or net-value conclusion is supported.")
        }
        return (sources, news, evidence, evidenceNotes)
    }

    /// `.extreme` needs the idea's actual high/low direction, which the pure, testable
    /// `iconName(for:)` (keyed only on `Kind`) can't see — resolved here, in the view, from
    /// `idea.recentExtreme`. Switches rather than `==` (mirrors `StockSageCatalystWatch`'s own
    /// note): `SparkSeries.Extreme`'s synthesized `Equatable` is MainActor-isolated.
    private func rowIconName(for brief: StockSageCatalystWatch.Brief) -> String {
        if brief.primary.kind == .extreme, let extreme = brief.idea.recentExtreme {
            switch extreme {
            case .atLow: return "arrow.down.right.circle"
            default:     return "arrow.up.right.circle"
            }
        }
        return Self.iconName(for: brief.primary.kind)
    }

    #if os(macOS)
    // MARK: - macOS period-first navigation

    @ViewBuilder
    private func periodContent(briefs: [StockSageCatalystWatch.Brief],
                               entries: [StockSageCatalystWatch.CalendarEntry], now: Date,
                               availability: StockSageCatalystNarrator.Availability) -> some View {
        let matching = Self.matchingBriefs(briefs, entries: entries)
        let matchingIDs = Set(matching.map(\.id))
        let entriesBySymbol = Dictionary(grouping: entries) { $0.idea.symbol }

        if entries.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("No dated events found for \(Self.periodRangeLabel(period, now: now)) in the available records.")
                    .font(.system(size: font12, weight: .semibold))
                Text("Undated context and checked-empty coverage remain available below when present; absence here does not prove no catalyst occurred.")
                    .font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(DS.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.surfaceStroke, lineWidth: 1))
        }

        switch mode {
        case .cards:
            LazyVStack(alignment: .leading, spacing: DS.Space.md) {
                ForEach(matching) { brief in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            Text("Matches \(period.title)")
                                .font(.system(size: metadataSize, weight: .medium)).foregroundStyle(DS.Palette.warningSoft)
                            ForEach(entriesBySymbol[brief.idea.symbol] ?? []) {
                                calendarRow($0, now: now)
                            }
                        }
                        .padding(DS.Space.md)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Palette.surface))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.surfaceStroke, lineWidth: 1))
                        DisclosureGroup("Full stock context — all dates") {
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                Text("Explain uses the unchanged full stock brief below, not the period-match row.")
                                    .font(.system(size: metadataSize)).foregroundStyle(DS.Palette.textSecondary)
                                catalystCard(brief, availability: availability)
                            }
                            .padding(.top, DS.Space.xs)
                        }
                    }
                }
            }
        case .calendar:
            ForEach(Self.periodDayGroups(entries)) { group in
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(StockSageCatalystWatch.dateStr(group.day))
                        .font(.system(size: font12, weight: .semibold))
                    if !group.scheduled.isEmpty {
                        Text("Scheduled / estimated").font(.system(size: metadataSize, weight: .medium))
                            .foregroundStyle(DS.Palette.warningSoft)
                        ForEach(group.scheduled) { calendarRow($0, now: now) }
                    }
                    if !group.reported.isEmpty {
                        Text("Reported").font(.system(size: metadataSize, weight: .medium))
                            .foregroundStyle(DS.Palette.textSecondary)
                        ForEach(group.reported) { calendarRow($0, now: now) }
                    }
                }
                .padding(DS.Space.lg)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.surfaceStroke, lineWidth: 1))
            }
            if !matching.isEmpty {
                Text("Choose Cards from View for each matching stock's unchanged full context and optional explanation.")
                    .font(.system(size: metadataSize)).foregroundStyle(DS.Palette.textSecondary)
            }
        }

        let disclosedIDs = mode == .cards ? matchingIDs : Set<String>()
        let undated = Self.briefsWithUndatedContext(briefs, excluding: disclosedIDs)
        if !undated.isEmpty {
            DisclosureGroup("Undated context") {
                LazyVStack(alignment: .leading, spacing: DS.Space.md) {
                    ForEach(undated) { catalystCard($0, availability: availability) }
                }.padding(.top, DS.Space.xs)
            }
        }
        let coverage = Self.briefsNeedingCoverage(briefs, excluding: disclosedIDs.union(undated.map(\.id)))
        if !coverage.isEmpty {
            DisclosureGroup("Other dates / coverage") {
                LazyVStack(alignment: .leading, spacing: DS.Space.md) {
                    ForEach(coverage) { catalystCard($0, availability: availability) }
                }.padding(.top, DS.Space.xs)
            }
        }
    }
    #endif

    // MARK: - Calendar mode

    @ViewBuilder
    private func calendarBody(briefs: [StockSageCatalystWatch.Brief], now: Date) -> some View {
        let entries = StockSageCatalystWatch.calendar(briefs, now: now)
        if !Self.hasDatedCatalysts(entries) {
            // A5 (2026-09-06): no longer promises "top 30" — `refreshEarningsForTracked` (T4)
            // sweeps every TRACKED symbol daily, not just the top-ranked board names, so a
            // dated calendar row can appear for anything tracked, not only the board's leaders.
            Group {
                #if os(iOS)
                Text("No dated events are available in the saved records. This is not evidence that no event occurred; no current event check was performed.")
                #else
                Text("No dated catalysts yet — catalyst checks cover every tracked symbol, refreshed "
                    + "daily; a symbol not yet checked shows as unchecked.")
                #endif
            }
                .font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(StockSageCatalystWatch.Bucket.allCases, id: \.self) { bucket in
                let rows = entries.filter { $0.bucket == bucket }
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(bucket.title).font(.system(size: font12, weight: .semibold)).foregroundStyle(.white)
                        // Same eager-render concern as cards mode (up to ~450 rows combined
                        // across buckets) — LazyVStack here too (fix pass 2026-09-06).
                        LazyVStack(alignment: .leading, spacing: DS.Space.xs) {
                            ForEach(rows) { calendarRow($0, now: now) }
                        }
                    }
                    .padding(DS.Space.lg)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.surfaceStroke, lineWidth: 1))
                }
            }
        }
    }

    private func calendarRow(_ entry: StockSageCatalystWatch.CalendarEntry, now: Date? = nil) -> some View {
        CalendarRow(entry: entry, now: now, onSelect: onSelect)
    }

    /// The actual calendar row, independently renderable without starting the section's model probe.
    struct CalendarRow: View {
        let entry: StockSageCatalystWatch.CalendarEntry
        let now: Date?
        let onSelect: (StockSageIdea) -> Void
        #if os(macOS)
        @ScaledMetric(relativeTo: .callout) private var metadataSize: CGFloat = 13
        #else
        @ScaledMetric(relativeTo: .caption) private var metadataSize: CGFloat = 12
        #endif
        #if os(macOS)
        @ScaledMetric(relativeTo: .callout) private var font11: CGFloat = 13
        #else
        @ScaledMetric(relativeTo: .caption2) private var font11: CGFloat = 11
        #endif
        @ScaledMetric(relativeTo: .caption2) private var font12: CGFloat = 12

        var body: some View {
            // A5: a dated "none known as of <date>" record (`isNegativeRecord`) is not a catalyst —
            // it renders dimmer and swaps the headline sentence for a small "No known catalyst" tag
            // (the date column already carries the same `checkedAt` date, so repeating "as of <date>"
            // in the headline too would be redundant) so it reads as a checked-and-empty record at a
            // glance, never mistaken for a real event. Both pieces are pure static helpers keyed
            // ONLY on the engine's flag (CatalystsSectionTests), never re-derived from `headline`.
            let badge = CatalystsSection.negativeRecordBadge(isNegativeRecord: entry.isNegativeRecord)
            let rowColor = CatalystsSection.calendarRowColor(isNegativeRecord: entry.isNegativeRecord)
            let content = HStack(alignment: .top, spacing: DS.Space.xs) {
                Text(entry.item.date.map(StockSageCatalystWatch.dateStr) ?? "—")
                    .font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
                    .frame(minWidth: 64, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.xs) {
                        Text(entry.idea.symbol).font(.system(size: font12, weight: .bold, design: .rounded)).foregroundStyle(rowColor)
                        if let badge {
                            Text(badge).font(.system(size: metadataSize, weight: .medium)).foregroundStyle(DS.Palette.textSecondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .overlay(Capsule().stroke(DS.Palette.surfaceStroke, lineWidth: 1))
                        } else {
                            Text(CatalystsSection.cardHeadline(entry.item, displayNow: now))
                                .font(.system(size: font11)).foregroundStyle(rowColor)
                        }
                    }
                    if let firstWhy = entry.item.why.first {
                        Text(firstWhy).font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary).lineLimit(2)
                    }
                    // Cross-platform since 2026-09-12. The `entry.item.date != nil` guard is NOT
                    // cosmetic: the iOS bucket list includes `.undated` ("No date on file"), and for a
                    // dateless entry `eventStatus` falls through every guard and returns
                    // "Scheduled / estimated" — a schedule claim about an item with no date. macOS was
                    // protected by `periodEntries`' own `guard let date`, which this path has not got.
                    if let now, !entry.isNegativeRecord, entry.item.date != nil {
                        Text(CatalystsSection.eventStatus(entry, now: now))
                            .font(.system(size: metadataSize, weight: .medium)).foregroundStyle(DS.Palette.warningSoft)
                        Text("Source: \(entry.item.source)")
                            .font(.system(size: metadataSize)).foregroundStyle(DS.Palette.textSecondary)
                    }
                    // Honesty floor: the RVOL detector is "unvalidated" and regime/seasonality carry
                    // their own caveats — the primary card already shows this (line ~165); the
                    // calendar row was the one path that dropped it (fix pass 2026-09-06). Stays
                    // `warningSoft` (never raw `danger`) so caveats remain readable alongside
                    // the neutral secondary text used for negative records.
                    if let caveat = entry.item.caveat {
                        Text(caveat).font(.system(size: metadataSize)).foregroundStyle(DS.Palette.warningSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                CatalystsSection.weightDot(entry.item.weight)
            }
            #if os(macOS)
            if let now {
                VStack(alignment: .leading, spacing: 2) {
                    Button { onSelect(entry.idea) } label: { content.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(CatalystsSection.periodAccessibilityLabel(entry, now: now))
                        .accessibilityHint("Open stock details")
                    if let url = entry.item.sourceURL {
                        Link("Read source record", destination: url).font(.system(size: metadataSize))
                    }
                }
            } else {
                Button { onSelect(entry.idea) } label: { content.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(entry.idea.symbol), \(entry.bucket.title), \(entry.item.headline), source: \(entry.item.source). \(entry.item.caveat ?? "")")
                    .accessibilityHint("Open stock details")
            }
            #else
            Button { onSelect(entry.idea) } label: {
                content.touchHitArea().contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.idea.symbol), \(entry.bucket.title), \(entry.item.headline), source: \(entry.item.source). \(entry.item.caveat ?? "")")
            .accessibilityHint("Open stock details")
            #endif
        }
    }

    // MARK: - Shared small pieces

    @ViewBuilder
    private static func weightDot(_ weight: StockSageCatalystWatch.Weight) -> some View {
        let pair: (color: Color, label: String) = {
            switch weight {
            case .high:   return (DS.Palette.dangerSoft, "high")
            case .medium: return (DS.Palette.warningSoft, "medium")
            case .low:    return (DS.Palette.textSecondary, "low")
            }
        }()
        Circle().fill(pair.color).frame(width: 7, height: 7)
            .accessibilityLabel("\(pair.label) priority")
    }

    @ViewBuilder
    private func actionCapsule(_ idea: StockSageIdea) -> some View {
        StockSageAIBadge(idea: idea, store: store)
    }

    // MARK: - Pure helpers (nonisolated, unit-tested — CatalystsSectionTests)

    // CROSS-PLATFORM (2026-09-12). These five were inside the `#if os(macOS)` below, so iOS
    // rendered `item.headline` verbatim for a past-dated event: an earnings bar at now-45,000s
    // showed "Earnings in ~0 days" under the "Today" heading, present tense, for a report that had
    // already happened. `StockSageCatalystWatch` admits any date with
    // `timeIntervalSince(now) >= -86_400`, so a report 0-24h past that fell on an earlier UTC
    // civil day lands here. None of them touches AppKit or `Period`, so nothing else moves.
    nonisolated static var catalystCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private nonisolated static func isReported(_ kind: StockSageCatalystWatch.Kind) -> Bool {
        [.filing8K, .ratingChange, .guidanceChange, .insiderTrade].contains(kind)
    }

    private nonisolated static func isPastDay(_ date: Date, now: Date) -> Bool {
        catalystCalendar.startOfDay(for: date) < catalystCalendar.startOfDay(for: now)
    }

    nonisolated static func eventStatus(_ entry: StockSageCatalystWatch.CalendarEntry,
                                        now: Date) -> String {
        if isReported(entry.item.kind) { return "Reported" }
        if entry.isProjected {
            return entry.item.date.map { isPastDay($0, now: now) } == true
                ? "Projected from history — not announced · Date passed — outcome unverified"
                : "Projected from history — not announced"
        }
        if entry.item.date.map({ isPastDay($0, now: now) }) == true {
            return "Date passed — outcome unverified"
        }
        return "Scheduled / estimated"
    }

    nonisolated static func periodHeadline(_ item: StockSageCatalystWatch.Item, now: Date) -> String {
        guard let date = item.date, isPastDay(date, now: now) else { return item.headline }
        if item.kind == .earnings { return "Earnings date" }
        if item.kind == .projectedEarnings { return "Projected earnings date" }
        return item.headline
    }

    #if os(macOS)
    nonisolated static func periodCountLabel(_ entries: [StockSageCatalystWatch.CalendarEntry]) -> String {
        let projected = entries.filter(\.isProjected).count
        return "\(entries.count - projected) provider-dated · \(projected) projected (not announced)"
    }

    nonisolated struct PeriodDayGroup: Identifiable {
        let day: Date
        var scheduled: [StockSageCatalystWatch.CalendarEntry]
        var reported: [StockSageCatalystWatch.CalendarEntry]
        nonisolated var id: Date { day }
    }

    nonisolated static func periodInterval(_ period: Period, now: Date) -> DateInterval {
        let calendar = catalystCalendar
        switch period {
        case .today: return calendar.dateInterval(of: .day, for: now)!
        case .thisWeek: return calendar.dateInterval(of: .weekOfYear, for: now)!
        case .thisMonth: return calendar.dateInterval(of: .month, for: now)!
        }
    }

    nonisolated static func contains(_ date: Date, in period: Period, now: Date) -> Bool {
        let day = catalystCalendar.startOfDay(for: date)
        let interval = periodInterval(period, now: now)
        return interval.start <= day && day < interval.end
    }

    nonisolated static func periodRangeLabel(_ period: Period, now: Date) -> String {
        let interval = periodInterval(period, now: now)
        guard period != .today else { return StockSageCatalystWatch.dateStr(interval.start) }
        let last = catalystCalendar.date(byAdding: .day, value: -1, to: interval.end)!
        return "\(StockSageCatalystWatch.dateStr(interval.start)) – \(StockSageCatalystWatch.dateStr(last))"
    }

    /// Real dated events only; checked-empty and undated records remain separate disclosures.
    nonisolated static func periodEntries(_ entries: [StockSageCatalystWatch.CalendarEntry],
                                          period: Period, now: Date)
        -> [StockSageCatalystWatch.CalendarEntry] {
        let calendar = catalystCalendar
        let today = calendar.startOfDay(for: now)
        return entries.filter {
            guard let date = $0.item.date else { return false }
            return !$0.isNegativeRecord && $0.item.kind != .none && contains(date, in: period, now: now)
        }.sorted {
            let lhs = calendar.startOfDay(for: $0.item.date!)
            let rhs = calendar.startOfDay(for: $1.item.date!)
            let lhsUpcoming = lhs >= today, rhsUpcoming = rhs >= today
            if lhsUpcoming != rhsUpcoming { return lhsUpcoming }
            if lhs != rhs { return lhsUpcoming ? lhs < rhs : lhs > rhs }
            if $0.idea.symbol != $1.idea.symbol { return $0.idea.symbol < $1.idea.symbol }
            return $0.item.id < $1.item.id
        }
    }

    nonisolated static func matchingBriefs(_ briefs: [StockSageCatalystWatch.Brief],
                                           entries: [StockSageCatalystWatch.CalendarEntry])
        -> [StockSageCatalystWatch.Brief] {
        let ids = Set(entries.map { $0.idea.symbol })
        return briefs.filter { ids.contains($0.idea.symbol) }
    }

    nonisolated static func briefsWithUndatedContext(_ briefs: [StockSageCatalystWatch.Brief],
                                                     excluding ids: Set<String>)
        -> [StockSageCatalystWatch.Brief] {
        briefs.filter { brief in
            !ids.contains(brief.id) && brief.all.contains { $0.date == nil && $0.kind != .none }
        }
    }

    nonisolated static func briefsNeedingCoverage(_ briefs: [StockSageCatalystWatch.Brief],
                                                  excluding ids: Set<String>)
        -> [StockSageCatalystWatch.Brief] {
        // A dated catalyst outside this period can still have failed/unchecked company feeds.
        // Keep every otherwise omitted full card, not only the engine's .none fallback.
        briefs.filter { !ids.contains($0.id) }
    }

    nonisolated static func periodDayGroups(_ entries: [StockSageCatalystWatch.CalendarEntry])
        -> [PeriodDayGroup] {
        var groups: [PeriodDayGroup] = []
        for entry in entries {
            guard let date = entry.item.date else { continue }
            let day = catalystCalendar.startOfDay(for: date)
            if groups.last?.day != day { groups.append(.init(day: day, scheduled: [], reported: [])) }
            if isReported(entry.item.kind) { groups[groups.count - 1].reported.append(entry) }
            else { groups[groups.count - 1].scheduled.append(entry) }
        }
        return groups
    }

    private nonisolated static func periodAccessibilityLabel(
        _ entry: StockSageCatalystWatch.CalendarEntry, now: Date) -> String {
        [entry.idea.symbol, entry.item.date.map(StockSageCatalystWatch.dateStr) ?? "No date",
         eventStatus(entry, now: now), periodHeadline(entry.item, now: now),
         "Source: \(entry.item.source)", entry.item.caveat].compactMap { $0 }.joined(separator: ". ")
    }
    #endif

    nonisolated static func cardHeadline(_ item: StockSageCatalystWatch.Item,
                                         displayNow: Date?) -> String {
        // The `#if os(macOS)` that used to wrap this was the whole iOS defect: `periodHeadline`
        // is pure and now cross-platform, so iOS printed the raw present-tense headline for an
        // event whose date had already passed.
        if let displayNow { return periodHeadline(item, now: displayNow) }
        return item.headline
    }

    /// One icon per `Kind` (all six cases) — the `.extreme` up/down split needs the idea's own
    /// high/low direction, which lives one level up in `rowIconName(for:)`, so this returns the
    /// "up" glyph as `.extreme`'s single deterministic answer.
    nonisolated static func iconName(for kind: StockSageCatalystWatch.Kind) -> String {
        switch kind {
        case .earnings:    return "calendar.badge.exclamationmark"
        case .volumeMove:  return "bolt.horizontal.circle.fill"
        case .extreme:     return "arrow.up.right.circle"
        case .regime:      return "gauge.with.needle"
        case .seasonality: return "calendar"
        case .none:        return "questionmark.circle"
        case .projectedEarnings: return "calendar.badge.clock"
        case .filing8K: return "doc.text.magnifyingglass"
        case .ratingChange: return "person.text.rectangle"
        case .guidanceChange: return "text.bubble"
        case .exDividend: return "calendar.badge.plus"
        case .insiderTrade: return "person.crop.circle.badge.clock"
        }
    }

    /// The action-capsule fill per `TradeAdvice.Action`. Values are `DS.Palette`'s
    /// successSoft/warningSoft/dangerSoft, copied as literals rather than referenced — under
    /// this module's default MainActor isolation `DS.Palette`'s statics are MainActor-isolated,
    /// which a `nonisolated` (unit-testable without a running app, per the build spec) function
    /// cannot read synchronously. Keep byte-identical to `DS.Palette` if that palette ever moves
    /// (`CatalystsSectionTests` pins both sides so a drift fails loudly).
    nonisolated static func actionFill(for action: TradeAdvice.Action) -> Color {
        switch action {
        case .buy, .strongBuy: return Color(red: 0.45, green: 0.85, blue: 0.55)   // DS.Palette.successSoft
        case .hold:             return Color(red: 1.0,  green: 0.72, blue: 0.35) // DS.Palette.warningSoft
        case .avoid:            return Color.white.opacity(0.22)
        case .reduce, .sell:    return Color(red: 1.0,  green: 0.50, blue: 0.50) // DS.Palette.dangerSoft
        }
    }

    /// Whether the calendar has at least one REAL dated catalyst — major fix 2026-09-06. A dated
    /// "none known as of <date>" negative record (`isNegativeRecord`) also carries a non-nil
    /// `item.date` (checkedAt, not an event), so the old `entries.contains { $0.item.date != nil
    /// }` check was satisfied by the very first symbol checked-and-empty: the honest "No dated
    /// catalysts yet" empty state disappeared the moment ONE tracked symbol had been swept, even
    /// though zero real catalysts existed — the screen then looked populated while every visible
    /// row was a negative record.
    nonisolated static func hasDatedCatalysts(_ entries: [StockSageCatalystWatch.CalendarEntry]) -> Bool {
        entries.contains { $0.item.date != nil && !$0.isNegativeRecord }
    }

    /// A5: the calendar row's "No known catalyst" tag, sourced ONLY from the engine's
    /// `isNegativeRecord` flag (never re-parsed from `headline`, which stays free to reword
    /// without this tag silently going stale). nil for a real catalyst row — nothing to tag.
    nonisolated static func negativeRecordBadge(isNegativeRecord: Bool) -> String? {
        isNegativeRecord ? "No known catalyst" : nil
    }

    /// A5: dims a negative-record calendar row so it reads as a checked-and-empty record, never
    /// mistaken for a real catalyst at a glance. Use the shared immutable text tokens so
    /// palette changes remain consistent. Never `DS.Palette.danger`/`.dangerSoft` — an empty catalyst record is neutral
    /// information, not a warning, so a danger tint would misrepresent it as one.
    nonisolated static func calendarRowColor(isNegativeRecord: Bool) -> Color {
        isNegativeRecord ? DS.Palette.textSecondary : DS.Palette.textPrimary
    }
}
