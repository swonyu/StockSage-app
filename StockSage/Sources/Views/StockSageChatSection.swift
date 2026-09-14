import SwiftUI

/// Shares Markets navigation and the existing local-server settings. No automatic inference on ticks.
struct StockSageChatSection: View {
    @ObservedObject var store: StockSageStore
    var openModelSettings: () -> Void
    @ObservedObject var chat: StockSageChatSession
    var feedNotice: AnyView? = nil
    /// The unsent draft lives on the session, so leaving Chat cannot discard it.
    private var question: String { chat.draft }
    @State private var issue: String?
    @State private var ownedRequestID: UUID?
    @State private var opening: StockSageChat.Snapshot?
    @State private var confirmClear = false
    @FocusState private var questionFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(StockSageLocalModelServer.backendKey) private var backend = "auto"
    @AppStorage(StockSageLocalModelServer.urlKey) private var serverURL = StockSageLocalModelServer.defaultURL
    @AppStorage(StockSageLocalModelServer.modelKey) private var model = StockSageLocalModelServer.defaultModel

    private var isWatchlistRequest: Bool { StockSageChat.watchlistSymbol(in: question) != nil }

    private var showLatestReply: Bool {
        #if os(iOS)
        !chat.turns.isEmpty && !questionFocused
        #else
        !chat.turns.isEmpty
        #endif
    }

    private var settings: [String] { [backend, serverURL, model] }
    private var config: StockSageLocalModelServer.Config? {
        StockSageAIAssessments.configuration(backend: backend, url: serverURL, model: model)
    }

    var body: some View {
        chatLayout
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if questionFocused {
                        Spacer()
                        Button("Done") { questionFocused = false }
                            .accessibilityLabel("Dismiss keyboard")
                    }
                }
            }
            #endif
            .task { refreshOpening() }
            .onChange(of: store.lastUpdated) { _, _ in refreshOpening() }
            .onChange(of: settings) { _, _ in cancel() }
            .onDisappear { cancel() }
            .confirmationDialog("Delete local Chat history?", isPresented: $confirmClear) {
                Button("Delete history", role: .destructive) { chat.clear() }
            } message: { Text("Deletes this conversation, including unsaved turns and source snapshots. It cannot erase screenshots or server logs.") }
    }

    private var contentPadding: CGFloat {
        #if os(macOS)
        24
        #else
        16
        #endif
    }

    private static var messageFont: Font {
        #if os(macOS)
        .system(size: 15)
        #else
        .body
        #endif
    }

    private var chatLayout: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        conversation.padding(contentPadding).frame(maxWidth: 840, alignment: .leading)
                            .frame(maxWidth: .infinity)
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    #if os(iOS)
                    .scrollDismissesKeyboard(.interactively)
                    #endif
                    .onChange(of: Self.latestTurnID(in: chat)) { _, newID in
                        // Follow new questions, not completion, cancellation or market updates.
                        guard newID != nil else { return }
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                    if showLatestReply {
                        HStack {
                            Spacer()
                            Button {
                                proxy.scrollTo("chat-bottom", anchor: .bottom)
                            } label: {
                                Label("Latest reply", systemImage: "arrow.down")
                                    #if os(iOS)
                                    .frame(minHeight: 44)
                                    #endif
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderless)
                            .help("Jump to the newest question and reply without sending a request.")
                        }
                        .padding(.horizontal, contentPadding)
                        #if os(macOS)
                        .padding(.vertical, 6)
                        #endif
                        .frame(maxWidth: 840).frame(maxWidth: .infinity)
                    }
                }
            }
            Divider()
            composer.padding(.horizontal, contentPadding).padding(.vertical, 16).frame(maxWidth: 840)
                .frame(maxWidth: .infinity).background(DS.Palette.bgTop)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let feedNotice {
                feedNotice
                Divider()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Chat").font(.largeTitle.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    #if os(macOS)
                    if config != nil { Button("Model settings", action: openModelSettings).tint(.secondary) }
                    Button("Clear history", role: .destructive) { confirmClear = true }
                        .disabled(chat.turns.isEmpty && chat.storageError == nil)
                    #else
                    Menu {
                        Button("Model settings", systemImage: "gearshape", action: openModelSettings)
                        Button("Clear history", systemImage: "trash", role: .destructive) { confirmClear = true }
                            .disabled(chat.turns.isEmpty && chat.storageError == nil)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Chat options")
                    #endif
                }
                .controlSize(.small)
                Text("Your briefing first. Ask Qwen when you want to go deeper.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            #if os(iOS)
            if config == nil {
                Self.missingModelNotice(openModelSettings: openModelSettings)
            } else {
                DisclosureGroup("Privacy and model connection") { connectionNotice }
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif

            if let opening {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("App briefing · no model call", systemImage: "text.alignleft")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button { refreshOpening() } label: {
                            Label("Refresh briefing from app data", systemImage: "arrow.clockwise")
                                #if os(iOS)
                                .frame(width: 44, height: 44)
                                #endif
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Refresh briefing from app data")
                    }
                    Text("Captured \(opening.at.formatted(date: .abbreviated, time: .shortened)). A bounded watchlist/board selection, not the entire market.")
                        .font(.caption).foregroundStyle(.secondary)
                    if opening.facts.isEmpty { Text("No tracked quotes yet. General questions are still available.") }
                    ForEach(opening.facts.filter { $0.field == "observed price" }) { fact in
                        Text(fact.text).font(.callout).lineSpacing(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(DS.Palette.surface.opacity(0.55), in: .rect(cornerRadius: DS.Radius.small))
            }
            let eventLog = Self.eventLog(enabled: store.alertsEnabled, count: store.alerts.count)
            if let shown = eventLog.shownCount {
                DisclosureGroup(Self.eventLogHeader(eventLog)) {
                    ForEach(Array(store.alerts.prefix(shown))) { event in
                        Text("\(event.symbol) · \(event.kind.rawValue) · rules-based event, occurrence time unavailable")
                            .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text(Self.eventLogHeader(eventLog)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(chat.turns) { turn in
                let edit: (() -> Void)? = chat.pending == nil && question.isEmpty ? {
                    if Self.reuseQuestion(turn.question, question: $chat.draft, issue: $issue, pending: chat.pending != nil) {
                        questionFocused = true
                    }
                } : nil
                Self.turnContent(turn, pending: chat.pending == turn.id, editQuestion: edit)
                    .padding(.top, 12)
            }
        }
    }

    /// Pure rendering keeps captured evidence separate from the live Chat session.
    @ViewBuilder static func turnContent(_ turn: StockSageChatSession.Turn, pending: Bool,
                                        editQuestion: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("You", systemImage: "person.crop.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if !pending {
                        Button { editQuestion?() } label: {
                            Label("Edit question", systemImage: "square.and.pencil")
                                #if os(iOS)
                                .frame(minHeight: 44)
                                #endif
                        }
                        .controlSize(.small).buttonStyle(.borderless)
                        .disabled(editQuestion == nil)
                        .help("Copies this question into the empty message box without sending or changing history. Finish or clear your draft, and wait for any current request to finish.")
                    }
                }
                Text(turn.question).font(messageFont).lineSpacing(4).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: 620, alignment: .leading)
            .background(DS.Palette.accent.opacity(0.10), in: .rect(cornerRadius: DS.Radius.bubble))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                    .stroke(DS.Palette.accent.opacity(0.17), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            VStack(alignment: .leading, spacing: 10) {
                Label(turn.isWatchlistAction == true ? "StockSage" : "Qwen",
                      systemImage: turn.isWatchlistAction == true ? "star" : "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if pending {
                    ProgressView {
                        Text(turn.notice).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .controlSize(.small)
                } else {
                    Text(turn.notice).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(turn.answer).font(messageFont).lineSpacing(5).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            if turn.isWatchlistAction != true {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    Label("Evidence", systemImage: "doc.text")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(turn.snapshot.facts.filter { turn.evidence.contains($0.id) }) { fact in
                            Text(fact.text).font(.callout).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach((turn.snapshot.sources ?? []).filter { turn.evidence.contains($0.id) }) { source in
                            sourceCard(source).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(selectedBenzingaRecords(in: turn)) { record in
                            StockSageBenzingaEvidenceView.recordContent(record)
                        }
                        Divider()
                        DisclosureGroup("Historical app snapshot · \(turn.snapshot.at.formatted(date: .abbreviated, time: .shortened))") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Historical snapshot, not current evidence. Model: \(turn.model)")
                                Text(turn.snapshot.context)
                                Text(turn.snapshot.researchStatus ?? "News and private group leads not retrieved for this question. Include a ticker to request them.")
                                ForEach(turn.snapshot.facts) { Text($0.text) }
                                ForEach(turn.snapshot.sources ?? []) { sourceCard($0) }
                                if let evidence = turn.snapshot.benzinga {
                                    StockSageBenzingaEvidenceView(capturedSnapshot: evidence)
                                }
                            }.font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    /// Match only cited IDs against the original capture; undated products stay typed records.
    static func selectedBenzingaRecords(in turn: StockSageChatSession.Turn) -> [StockSageBenzinga.Record] {
        let cited = Set(turn.evidence)
        var seen = Set<String>()
        return (turn.snapshot.benzinga?.pages.flatMap(\.records) ?? []).filter {
            cited.contains($0.id) && seen.insert($0.id).inserted
        }
    }

    private var composer: some View {
        #if os(iOS)
        let stackedControls = dynamicTypeSize.isAccessibilitySize
        #else
        let stackedControls = false
        #endif
        let controls = stackedControls
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout())
        return VStack(alignment: .leading, spacing: 8) {
            QuestionField(question: $chat.draft, issue: $issue)
                .focused($questionFocused)
                .font(Self.messageFont)
                .controlSize(.large)
            controls {
                Button(action: send) {
                    Label(isWatchlistRequest ? "Add to watchlist" : "Ask Qwen", systemImage: "arrow.up.circle.fill")
                        .fixedSize(horizontal: false, vertical: true)
                }
                    .disabled(chat.pending != nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (config == nil && !isWatchlistRequest))
                    .buttonStyle(.borderedProminent)
                    #if os(macOS)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send your question with Command-Return.")
                    #else
                    .controlSize(.large)
                    #endif
                if let pending = chat.pending {
                    Button {
                        chat.cancel(id: pending)
                        #if os(macOS)
                        questionFocused = true
                        #endif
                    } label: {
                        Text("Cancel")
                            #if os(iOS)
                            .frame(minHeight: 44)
                            #endif
                    }
                }
                if !stackedControls { Spacer() }
                Text("\(question.count)/2000").font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Question character count")
                    .accessibilityValue(Self.questionLengthDescription(question))
            }
            Self.composerWarnings(issue: issue, storageError: chat.storageError)
            #if os(macOS)
            if config == nil {
                Self.missingModelNotice(openModelSettings: openModelSettings)
            } else {
                DisclosureGroup("Privacy and model connection") { connectionNotice }
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif
        }
    }

    /// Which event-log branch Chat renders. Pure, so the precedence is testable without a view:
    /// the FLAG is tested BEFORE emptiness, matching `MarketsView.alertsPanel`. A log retained
    /// after the toggle went off stays visible but can never be labelled as a live one.
    /// `StockSageStore.alerts` is memory-only, so after a relaunch with the flag on this is
    /// `.onEmpty` — that means "nothing recorded this session", not "nothing happened".
    enum EventLog: Equatable {
        case off(retained: Int)
        case onEmpty
        case recorded(shown: Int)

        /// Rows the disclosure list shows, or nil when there is no list — only a caption.
        var shownCount: Int? {
            switch self {
            case .off(let retained): return retained == 0 ? nil : min(retained, 5)
            case .onEmpty: return nil
            case .recorded(let shown): return shown
            }
        }
    }

    static func eventLog(enabled: Bool, count: Int) -> EventLog {
        guard enabled else { return .off(retained: count) }
        return count == 0 ? .onEmpty : .recorded(shown: min(count, 5))
    }

    static func eventLogHeader(_ state: EventLog) -> String {
        switch state {
        case .off(let retained):
            return retained == 0
                ? "Event logging is off. Chat does not enable alerts or background monitoring."
                : "Event logging is off — \(retained) recorded before it was turned off, no longer updating"
        case .onEmpty:
            return "No events recorded in the app log. This is not proof of no market changes."
        case .recorded(let shown):
            return "Recent app events · \(shown) shown"
        }
    }

    /// Composer text wraps OUTSIDE the chat ScrollView. `chatLayout` makes `composer` a
    /// SIBLING of the scroll view, so its height sums into the NavigationSplitView's detail column
    /// instead of scrolling — the same route that made the app unusable in 3392d17.
    ///
    /// Measured in place, inside a real split view in a 1300x840 window, with the feed banners
    /// already capped:
    ///
    ///     chat page, no warning ....................... 223pt
    ///     + 63-char "enable a loopback model" issue ... 1095pt
    ///     + 95-char rejected-question issue ........... 1511pt
    ///     + 141-char storage-failure warning .......... 2135pt
    ///     + both warnings at once ..................... 3423pt
    ///     capped ................................ 279-335pt
    ///
    /// 2135pt lands on the original defect's 2185pt, and is invariant to window width, which is the
    /// fingerprint. Both states are ordinary: a rejected send, or a history file that cannot be
    /// written. Four lines clears the longest warning at the 900pt window floor while keeping a
    /// near-zero-width pass finite.
    static let composerLineLimit = 4

    #if os(macOS)
    static let modelSetupGuidance = "Qwen answers require a local server on this Mac, configured in Model settings. Watchlist commands work without a model."
    #else
    static let modelSetupGuidance = "Watchlist commands work without a model. Qwen requires a server in Model settings. On iPhone, localhost refers to this phone; a private Mac connection is not configured."
    #endif

    static func missingModelNotice(openModelSettings: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(modelSetupGuidance).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                #if os(macOS)
                .lineLimit(composerLineLimit)
                #endif
            Button("Model settings", systemImage: "gearshape", action: openModelSettings)
                #if os(macOS)
                .controlSize(.small)
                #else
                .buttonStyle(.bordered)
                .controlSize(.large)
                #endif
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    static func sourceLinkLabel(_ source: StockSageChat.Source) -> String {
        "Read \(source.subject) source · \(source.attribution)"
    }

    static func questionLengthDescription(_ question: String) -> String {
        "\(question.count) of 2,000 characters"
    }

    static func reuseQuestion(_ original: String, question: Binding<String>, issue: Binding<String?>, pending: Bool) -> Bool {
        guard !pending, question.wrappedValue.isEmpty else { return false }
        question.wrappedValue = original
        issue.wrappedValue = nil
        return true
    }

    static func latestTurnID(in chat: StockSageChatSession) -> UUID? {
        chat.turns.last?.id
    }

    struct QuestionField: View {
        @Binding var question: String
        @Binding var issue: String?

        var editingBinding: Binding<String> {
            Binding(get: { question }, set: { value in
                guard question != value else { return }
                issue = nil
                question = value
            })
        }

        var body: some View {
            TextField("Ask about a ticker, or say ‘add RKLB to my watchlist’…", text: editingBinding, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityLabel("Question or watchlist command")
        }
    }

    static func composerIssues(issue: String?, storageError: String?) -> [String] {
        [issue, storageError].compactMap { $0 }
    }

    static func composerWarnings(issue: String?, storageError: String?) -> some View {
        let warnings = composerIssues(issue: issue, storageError: storageError)
        return ForEach(warnings.indices, id: \.self) { index in
            Text(warnings[index]).foregroundStyle(DS.Palette.warningSoft)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(composerLineLimit)
        }
    }

    private var connectionNotice: some View {
        let missing = Self.modelSetupGuidance
        return Text(config == nil
                    ? missing
                    : "Uses your existing local Qwen server. Explicit ticker questions add selected news (Massive, when web access is enabled; EODHD disabled) and private WhatsApp export leads for the first selected ticker only. Only that ticker goes to news providers; group text stays local. No broker credentials, account identifiers, journal notes, live WhatsApp connection, training or cloud fallback. Do not paste secrets. The app attempts to save the latest 24 turns locally and exclude them from backup. Check any storage warning before closing Chat. Clear history removes this app's conversation.")
                    .font(.caption).foregroundStyle(.secondary)
    }

    private static func sourceCard(_ source: StockSageChat.Source) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(source.subject) · \(source.attribution) · \(source.publicationTime ?? StockSageNewsService.instant(source.date))").font(.caption.bold())
            if let updated = source.updatedTime { Text("Updated \(updated)").font(.caption).foregroundStyle(.secondary) }
            Text(source.warning).font(.caption).foregroundStyle(.secondary)
            Text(source.excerpt).font(.callout).textSelection(.enabled)
            if let link = source.link {
                Link("Read attributed source", destination: link)
                    .accessibilityLabel(Self.sourceLinkLabel(source))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func snapshot(for question: String, followUp: Bool) -> StockSageChat.Snapshot {
        let watchlist = followUp ? chat.followUpSymbols(watchlist: store.userSymbols) : store.userSymbols
        let symbols = StockSageChat.selectedSymbols(question: question, symbols: store.symbols, watchlist: watchlist)
        return StockSageChat.snapshot(symbols: symbols, ideas: store.ideas, earnings: store.catalystChain,
                                     sample: store.isSampleData, now: Date())
    }

    private func refreshOpening() { opening = snapshot(for: "", followUp: false) }
    private func cancel() {
        if let id = ownedRequestID { chat.cancel(id: id) }
        ownedRequestID = nil
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard StockSageChat.safeQuestion(text) else {
            issue = "Use 1–2000 characters without credentials or account identifiers. Nothing was saved or sent."
            return
        }
        if isWatchlistRequest {
            guard let id = chat.beginWatchlistAddition(question: text, store: store) else { return }
            ownedRequestID = id
            chat.draft = ""; issue = nil
            #if os(macOS)
            questionFocused = true
            #endif
            return
        }
        guard let config else { issue = "Enable a loopback local model in Catalysts → Explanation model."; return }
        let facts = snapshot(for: text, followUp: true)
        let history = chat.turns
        let researchTicker = StockSageChat.requestedSymbols(question: text, symbols: store.symbols).first?.symbol
        guard let id = chat.begin(question: text, snapshot: facts, model: config.model) else { return }
        let revision = StockSageLocalModelServer.settingsRevision()
        let active: @MainActor @Sendable () -> Bool = {
            !Task.isCancelled && chat.pending == id && StockSageAIAssessments.configuration == config
                && StockSageLocalModelServer.settingsRevision() == revision
        }
        chat.draft = ""; issue = nil
        #if os(macOS)
        questionFocused = true
        #endif
        ownedRequestID = id
        let request = Task {
            defer { if ownedRequestID == id { ownedRequestID = nil } }
            var enriched = facts
            if let ticker = researchTicker {
                chat.advance(id: id, to: .sources)
                let evidence = await StockSageBenzingaClient.shared.snapshot(for: ticker, now: facts.at)
                guard active(), StockSageBenzingaClient.shared.isCurrent(evidence) else {
                    if chat.pending == id { chat.cancel() }
                    return
                }
                // A missing product remains explicitly unchecked, never a nil-page refetch.
                let page = evidence.pages.first { $0.query.product == .news && $0.query.subject == ticker }
                    ?? StockSageBenzinga.Page(query: .init(product: .news, subject: ticker, from: nil, through: nil),
                        checkedAt: evidence.capturedAt, credentialGeneration: evidence.credentialGeneration,
                        status: .notChecked, records: [], excludedCount: 0, hasMore: false)
                let news = await StockSageNewsService.observation(for: ticker, limit: 3, now: facts.at, benzingaPage: page)
                guard active(), StockSageBenzingaClient.shared.isCurrent(evidence) else {
                    if chat.pending == id { chat.cancel() }
                    return
                }
                let withNews = StockSageChat.addingResearch(to: facts, symbol: ticker, observation: news,
                    leads: StockSageResearchLeads.load(symbol: ticker, now: facts.at), webAllowed: ToolPolicy.isExternalAllowed)
                enriched = StockSageChat.addingBenzinga(to: withNews, evidence: evidence)
                guard chat.attachResearch(id: id, snapshot: enriched) else { return }
            }
            guard let prepared = StockSageChat.request(question: text, snapshot: enriched, history: history) else {
                chat.finish(id: id, text: nil, unavailable: "This context is too large for the local request. Ask a shorter question or use fewer tickers. Source snapshots remain available.")
                return
            }
            let includesNews = enriched.sources?.contains { $0.id.contains(".news.") } == true
            let capturedBenzinga = enriched.benzinga
            let allowed: @MainActor @Sendable () -> Bool = {
                active() && (!includesNews || ToolPolicy.isExternalAllowed)
                    && (capturedBenzinga.map { StockSageBenzingaClient.shared.isCurrent($0) } ?? true)
            }
            guard allowed() else {
                if chat.pending == id { chat.cancel() }
                return
            }
            chat.advance(id: id, to: .checkingModel)
            let probe = await StockSageLocalModelServer.prepare(config, stillValid: allowed)
            guard allowed() else {
                if chat.pending == id { chat.cancel() }
                return
            }
            guard probe.reachable && probe.hasModel else {
                chat.finish(id: id, text: nil, unavailable: probe.detail,
                    requestSnapshot: prepared.snapshot)
                return
            }
            chat.advance(id: id, to: .generating)
            let result = await StockSageLocalModelServer.completeDetailed(config, isOllama: probe.isOllama,
                system: StockSageChat.instructions, user: prepared.prompt, maxTokens: StockSageChat.outputTokens,
                contextTokens: StockSageChat.contextTokens, timeout: StockSageChat.requestTimeout, stillValid: allowed)
            guard allowed() else {
                // Identity ownership makes clear/cancel/newer requests immune to late completions.
                if chat.pending == id { chat.cancel() }
                return
            }
            switch result {
            case .success(let completion):
                // A cut-off prose answer is still worth reading, but the user must know it is cut
                // off. The note goes in the NOTICE, never appended to the text: `finish` parses
                // that text as strict JSON, so appending anything makes a complete, valid reply
                // unparseable and silently drops its evidence cards.
                chat.finish(id: id, text: completion.text, requestSnapshot: prepared.snapshot,
                            truncated: StockSageLocalModelServer.rejectsTruncatedOutput(completion))
            case .failure(let failure):
                // Chat was the only caller still on the legacy `complete()` wrapper, which folds
                // eighteen diagnostic categories into four and was then discarded entirely — a
                // stopped server, a misspelled model ID and a five-minute timeout all produced
                // one identical sentence. The Catalysts tab already discriminated its failures.
                chat.finish(id: id, text: nil,
                            unavailable: StockSageChat.unavailableMessage(for: failure.diagnostic),
                            requestSnapshot: prepared.snapshot)
            }
        }
        chat.attachTask(request, id: id)
    }
}

#if os(macOS)
/// Keep memory-only turns above the page switch when a local history save fails.
/// The App owns the conversation across windows; each section owns only its request ID.
struct StockSageChatNavigation<Chat: View, Other: View>: View {
    let isChat: Bool
    let session: StockSageChatSession
    let chat: (StockSageChatSession) -> Chat
    let other: () -> Other
    init(isChat: Bool, session: StockSageChatSession,
         @ViewBuilder chat: @escaping (StockSageChatSession) -> Chat,
         @ViewBuilder other: @escaping () -> Other) {
        self.isChat = isChat
        self.session = session
        self.chat = chat
        self.other = other
    }
    var body: some View {
        if isChat { chat(session) } else { other() }
    }
}
#endif
