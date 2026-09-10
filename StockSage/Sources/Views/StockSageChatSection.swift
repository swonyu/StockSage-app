import SwiftUI

/// Shares Markets navigation and the existing local-server settings. No automatic inference on ticks.
struct StockSageChatSection: View {
    @ObservedObject var store: StockSageStore
    var openModelSettings: () -> Void
    #if os(macOS)
    @ObservedObject var chat: StockSageChatSession
    #else
    @StateObject private var chat = StockSageChatSession(historyURL: StockSageChatSession.localHistoryURL)
    #endif
    /// The unsent draft lives on the session, so leaving Chat cannot discard it.
    private var question: String { chat.draft }
    @State private var issue: String?
    @State private var request: Task<Void, Never>?
    @State private var opening: StockSageChat.Snapshot?
    @State private var confirmClear = false
    #if os(macOS)
    @FocusState private var questionFocused: Bool
    #endif
    @AppStorage(StockSageLocalModelServer.backendKey) private var backend = "auto"
    @AppStorage(StockSageLocalModelServer.urlKey) private var serverURL = StockSageLocalModelServer.defaultURL
    @AppStorage(StockSageLocalModelServer.modelKey) private var model = StockSageLocalModelServer.defaultModel

    private var settings: [String] { [backend, serverURL, model] }
    private var config: StockSageLocalModelServer.Config? {
        StockSageAIAssessments.configuration(backend: backend, url: serverURL, model: model)
    }

    var body: some View {
        chatLayout
            .task { refreshOpening() }
            .onChange(of: store.lastUpdated) { _, _ in refreshOpening() }
            .onChange(of: settings) { _, _ in cancel() }
            .onDisappear { cancel() }
            .confirmationDialog("Delete local Chat history?", isPresented: $confirmClear) {
                Button("Delete history", role: .destructive) { request?.cancel(); request = nil; chat.clear() }
            } message: { Text("Deletes this conversation, including unsaved turns and source snapshots. It cannot erase screenshots or server logs.") }
    }

    @ViewBuilder private var chatLayout: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        conversation.padding(24).frame(maxWidth: 860, alignment: .leading)
                            .frame(maxWidth: .infinity)
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .onChange(of: Self.latestTurnID(in: chat)) { _, newID in
                        // Follow new questions, not completion, cancellation or market updates.
                        guard newID != nil else { return }
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                    HStack {
                        Spacer()
                        Button("Latest reply", systemImage: "arrow.down") {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                        .controlSize(.small)
                        .disabled(chat.turns.isEmpty)
                        .help("Jump to the newest question and reply without sending a request.")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .frame(maxWidth: 860).frame(maxWidth: .infinity)
                }
            }
            Divider()
            composer.padding(20).frame(maxWidth: 860)
                .frame(maxWidth: .infinity).background(DS.Palette.bgTop)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        VStack(alignment: .leading, spacing: 16) { conversation; composer }.padding(16)
        #endif
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                #if os(iOS)
                Label("Chat", systemImage: "bubble.left.and.bubble.right.fill").font(.title2.bold())
                #else
                Label("Your conversation", systemImage: "bubble.left.and.bubble.right")
                    .font(.headline).foregroundStyle(.secondary)
                #endif
                Spacer()
                #if os(macOS)
                if config != nil { Button("Model settings", action: openModelSettings) }
                #else
                Button("Model settings", action: openModelSettings)
                #endif
                Button("Clear history", role: .destructive) { confirmClear = true }
                    .disabled(chat.turns.isEmpty && chat.storageError == nil)
            }
            Text("Your briefing first. Ask Qwen when you want to go deeper.").foregroundStyle(.secondary)

            if let opening {
                GroupBox("App briefing · no model call") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Captured \(opening.at.formatted(date: .abbreviated, time: .shortened)). A bounded watchlist/board selection, not the entire market.")
                            .font(.caption).foregroundStyle(.secondary)
                        if opening.facts.isEmpty { Text("No tracked quotes yet. General questions are still available.") }
                        ForEach(opening.facts.filter { $0.field == "observed price" }) { fact in Text(fact.text).font(.callout) }
                        Button("Refresh briefing from app data") { refreshOpening() }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !store.alerts.isEmpty {
                DisclosureGroup("Recent app events · \(min(store.alerts.count, 5)) shown") {
                    ForEach(Array(store.alerts.prefix(5))) { event in
                        Text("\(event.symbol) · \(event.kind.rawValue) · rules-based event, occurrence time unavailable")
                            .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text(store.alertsEnabled ? "No events recorded in the app log. This is not proof of no market changes."
                     : "Event logging is off. Chat does not enable alerts or background monitoring.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(chat.turns) { turn in
                #if os(macOS)
                let edit: (() -> Void)? = chat.pending == nil && question.isEmpty ? {
                    if Self.reuseQuestion(turn.question, question: $chat.draft, issue: $issue, pending: chat.pending != nil) {
                        questionFocused = true
                    }
                } : nil
                Self.turnContent(turn, pending: chat.pending == turn.id, editQuestion: edit)
                #else
                Self.turnContent(turn, pending: chat.pending == turn.id)
                #endif
            }
        }
    }

    /// Pure rendering keeps captured evidence separate from the live Chat session.
    @ViewBuilder static func turnContent(_ turn: StockSageChatSession.Turn, pending: Bool,
                                        editQuestion: (() -> Void)? = nil) -> some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Label("You", systemImage: "person.crop.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(turn.question).font(.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !pending {
                    Button("Edit question", systemImage: "square.and.pencil") { editQuestion?() }
                        .controlSize(.small)
                        .disabled(editQuestion == nil)
                        .help("Copies this question into the empty message box without sending or changing history. Finish or clear your draft, and wait for any current request to finish.")
                }
            }
            .padding(DS.Space.md)
            .frame(maxWidth: 620, alignment: .leading)
            .background(DS.Palette.accent.opacity(0.16), in: .rect(cornerRadius: DS.Radius.bubble))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                    .stroke(DS.Palette.accent.opacity(0.30), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Label("Qwen", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
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
                    Text(turn.answer).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DS.Space.md)
            .frame(maxWidth: 760, alignment: .leading)
            .background(DS.Palette.surface, in: .rect(cornerRadius: DS.Radius.bubble))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                    .stroke(DS.Palette.surfaceStroke, lineWidth: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox("Evidence and original snapshot") {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(turn.snapshot.facts.filter { turn.evidence.contains($0.id) }) { fact in
                        Text(fact.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                            .padding(8).background(.quaternary, in: .rect(cornerRadius: 8))
                    }
                    ForEach((turn.snapshot.sources ?? []).filter { turn.evidence.contains($0.id) }) { source in
                        sourceCard(source).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(selectedBenzingaRecords(in: turn)) { record in
                        StockSageBenzingaEvidenceView.recordContent(record)
                    }
                    DisclosureGroup("Original app snapshot · \(turn.snapshot.at.formatted(date: .abbreviated, time: .shortened))") {
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
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        #else
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(turn.question).font(.headline).textSelection(.enabled)
                Text(turn.notice).font(.caption).foregroundStyle(.secondary)
                if pending { ProgressView("Preparing sources / asking the local model…") }
                else { Text(turn.answer).textSelection(.enabled) }
                ForEach(turn.snapshot.facts.filter { turn.evidence.contains($0.id) }) { fact in
                    Text(fact.text).font(.callout).padding(8).background(.quaternary, in: .rect(cornerRadius: 8))
                }
                ForEach((turn.snapshot.sources ?? []).filter { turn.evidence.contains($0.id) }) { source in
                    sourceCard(source)
                }
                ForEach(selectedBenzingaRecords(in: turn)) { record in
                    StockSageBenzingaEvidenceView.recordContent(record)
                }
                DisclosureGroup("Original app snapshot · \(turn.snapshot.at.formatted(date: .abbreviated, time: .shortened))") {
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
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        #endif
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
        VStack(alignment: .leading, spacing: 8) {
            #if os(macOS)
            QuestionField(question: $chat.draft, issue: $issue)
                .focused($questionFocused)
            #else
            TextField("Ask about a ticker, evidence, risks, or how StockSage works…", text: $chat.draft, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Question for Qwen")
            #endif
            HStack {
                Button("Ask Qwen", systemImage: "arrow.up.circle.fill", action: send)
                    .disabled(chat.pending != nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || config == nil)
                    #if os(macOS)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send your question with Command-Return.")
                    #endif
                if chat.pending != nil {
                    Button("Cancel") {
                        cancel()
                        #if os(macOS)
                        questionFocused = true
                        #endif
                    }
                }
                Spacer()
                Text("\(question.count)/2000").font(.caption).foregroundStyle(.secondary)
                    #if os(macOS)
                    .accessibilityLabel("Question character count")
                    .accessibilityValue(Self.questionLengthDescription(question))
                    #endif
            }
            #if os(macOS)
            Self.composerWarnings(issue: issue, storageError: chat.storageError)
            #else
            if let issue = issue ?? chat.storageError { Text(issue).foregroundStyle(DS.Palette.warningSoft) }
            #endif
            #if os(macOS)
            if config == nil {
                Self.missingModelNotice(openModelSettings: openModelSettings)
            } else {
                DisclosureGroup("Privacy and model connection") { connectionNotice }
                    .font(.caption).foregroundStyle(.secondary)
            }
            #else
            connectionNotice
            #endif
        }
    }

    #if os(macOS)
    static let modelSetupGuidance = "Configure a local model in Model settings. Chat requires a server on this Mac."

    static func missingModelNotice(openModelSettings: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(modelSetupGuidance).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Model settings", systemImage: "gearshape", action: openModelSettings)
                .controlSize(.small)
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
            TextField("Ask about a ticker, evidence, risks, or how StockSage works…", text: editingBinding, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Question for Qwen")
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
        }
    }
    #endif

    private var connectionNotice: some View {
        #if os(macOS)
        let missing = Self.modelSetupGuidance
        #else
        let missing = "Chat requires the local server enabled in Catalysts → Explanation model. On iPhone, localhost is the phone, not your Mac; private HTTPS serving is not configured in this slice."
        #endif
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
                #if os(macOS)
                Link("Read attributed source", destination: link)
                    .accessibilityLabel(Self.sourceLinkLabel(source))
                #else
                Link("Read attributed source", destination: link)
                #endif
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func snapshot(for question: String, followUp: Bool) -> StockSageChat.Snapshot {
        let watchlist = followUp ? chat.turns.last?.snapshot.facts.map(\.subject) ?? store.userSymbols : store.userSymbols
        let symbols = StockSageChat.selectedSymbols(question: question, symbols: store.symbols, watchlist: watchlist)
        return StockSageChat.snapshot(symbols: symbols, ideas: store.ideas, earnings: store.catalystChain,
                                     sample: store.isSampleData, now: Date())
    }

    private func refreshOpening() { opening = snapshot(for: "", followUp: false) }
    private func cancel() { request?.cancel(); request = nil; chat.cancel() }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard StockSageChat.safeQuestion(text) else {
            issue = "Use 1–2000 characters without credentials or account identifiers. Nothing was saved or sent."
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
        request = Task {
            var enriched = facts
            if let ticker = researchTicker {
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
            let probe = await StockSageLocalModelServer.probe(config, stillValid: allowed)
            guard allowed() else {
                if chat.pending == id { chat.cancel() }
                return
            }
            guard probe.reachable && probe.hasModel else {
                chat.finish(id: id, text: nil, unavailable: probe.reachable
                    ? "The server is reachable, but the configured model was not found. Check its model ID in Model settings."
                    : "The model server could not be verified. Check that it is running, then use Test connection in Model settings.",
                    requestSnapshot: prepared.snapshot)
                return
            }
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
                // A cut-off prose answer is still worth reading, but the user must know it is
                // cut off rather than assume the model finished its thought.
                let text = StockSageLocalModelServer.rejectsTruncatedOutput(completion)
                    ? completion.text + "\n\n[This answer stopped at the reply length limit and is incomplete. Ask a narrower question for a complete one.]"
                    : completion.text
                chat.finish(id: id, text: text, requestSnapshot: prepared.snapshot)
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
    }
}

#if os(macOS)
/// Keep memory-only turns above the page switch when a local history save fails.
/// Window lifetime only; leaving Chat still cancels its request in ChatSection.
struct StockSageChatNavigation<Chat: View, Other: View>: View {
    let isChat: Bool
    @StateObject private var session: StockSageChatSession
    let chat: (StockSageChatSession) -> Chat
    let other: () -> Other
    init(isChat: Bool, historyURL: URL?,
         @ViewBuilder chat: @escaping (StockSageChatSession) -> Chat,
         @ViewBuilder other: @escaping () -> Other) {
        self.isChat = isChat
        _session = StateObject(wrappedValue: StockSageChatSession(historyURL: historyURL))
        self.chat = chat
        self.other = other
    }
    var body: some View {
        if isChat { chat(session) } else { other() }
    }
}
#endif
