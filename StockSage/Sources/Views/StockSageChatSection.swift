import SwiftUI

/// Shares Markets navigation and the existing local-server settings. No automatic inference on ticks.
struct StockSageChatSection: View {
    @ObservedObject var store: StockSageStore
    var openModelSettings: () -> Void
    @StateObject private var chat = StockSageChatSession(historyURL: StockSageChatSession.localHistoryURL)
    @State private var question = ""
    @State private var issue: String?
    @State private var request: Task<Void, Never>?
    @State private var opening: StockSageChat.Snapshot?
    @State private var confirmClear = false
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
            } message: { Text("Deletes this app's saved conversation and source snapshots. It cannot erase screenshots or server logs.") }
    }

    @ViewBuilder private var chatLayout: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    conversation.padding(24).frame(maxWidth: 860, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .onChange(of: chat.pending) { _, _ in
                    // Only a send/completion moves the transcript, never market ticks.
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
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
                Button("Model settings", action: openModelSettings)
                Button("Clear history", role: .destructive) { confirmClear = true }
                    .disabled(chat.turns.isEmpty && chat.storageError == nil)
            }
            Text("Your briefing first. Ask Qwen when you want to go deeper.").foregroundStyle(.secondary)
            #if os(macOS)
            StockSageResearchModesPanel(store: store)
            #endif
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
                Self.turnContent(turn, pending: chat.pending == turn.id)
            }
        }
    }

    /// Pure rendering keeps captured evidence separate from the live Chat session.
    @ViewBuilder static func turnContent(_ turn: StockSageChatSession.Turn, pending: Bool) -> some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Label("You", systemImage: "person.crop.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(turn.question).font(.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
                Text(turn.notice).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if pending {
                    ProgressView("Preparing sources / asking the local model…")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
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
                    DisclosureGroup("Original app snapshot · \(turn.snapshot.at.formatted(date: .abbreviated, time: .shortened))") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Historical snapshot, not current evidence. Model: \(turn.model)")
                            Text(turn.snapshot.context)
                            Text(turn.snapshot.researchStatus ?? "News and private group leads not retrieved for this question. Include a ticker to request them.")
                            ForEach(turn.snapshot.facts) { Text($0.text) }
                            ForEach(turn.snapshot.sources ?? []) { sourceCard($0) }
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
                DisclosureGroup("Original app snapshot · \(turn.snapshot.at.formatted(date: .abbreviated, time: .shortened))") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Historical snapshot, not current evidence. Model: \(turn.model)")
                        Text(turn.snapshot.context)
                        Text(turn.snapshot.researchStatus ?? "News and private group leads not retrieved for this question. Include a ticker to request them.")
                        ForEach(turn.snapshot.facts) { Text($0.text) }
                        ForEach(turn.snapshot.sources ?? []) { sourceCard($0) }
                    }.font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        #endif
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask about a ticker, evidence, risks, or how StockSage works…", text: $question, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Question for Qwen")
            HStack {
                Button("Ask Qwen", systemImage: "arrow.up.circle.fill", action: send)
                    .disabled(chat.pending != nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || config == nil)
                    #if os(macOS)
                    .keyboardShortcut(.return, modifiers: .command)
                    #endif
                if chat.pending != nil { Button("Cancel") { cancel() } }
                Spacer()
                Text("\(question.count)/2000").font(.caption).foregroundStyle(.secondary)
            }
            if let issue = issue ?? chat.storageError { Text(issue).foregroundStyle(DS.Palette.warningSoft) }
            #if os(macOS)
            if config == nil {
                connectionNotice
            } else {
                DisclosureGroup("Privacy and model connection") { connectionNotice }
                    .font(.caption).foregroundStyle(.secondary)
            }
            #else
            connectionNotice
            #endif
        }
    }

    private var connectionNotice: some View {
        Text(config == nil
                    ? "Chat requires the local server enabled in Catalysts → Explanation model. On iPhone, localhost is the phone, not your Mac; private HTTPS serving is not configured in this slice."
                    : "Uses your existing local Qwen server. Explicit ticker questions add selected news (Massive, when web access is enabled; EODHD disabled) and private WhatsApp export leads for the first selected ticker only. Only that ticker goes to news providers; group text stays local. No broker credentials, account identifiers, journal notes, live WhatsApp connection, training or cloud fallback. Do not paste secrets. Last 24 turns saved locally, excluded from backup; Clear history deletes this app's copy.")
                    .font(.caption).foregroundStyle(.secondary)
    }

    private static func sourceCard(_ source: StockSageChat.Source) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(source.subject) · \(source.attribution) · \(source.publicationTime ?? StockSageNewsService.instant(source.date))").font(.caption.bold())
            Text(source.warning).font(.caption).foregroundStyle(.secondary)
            Text(source.excerpt).font(.callout).textSelection(.enabled)
            if let link = source.link { Link("Read attributed source", destination: link) }
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
        question = ""; issue = nil
        request = Task {
            var enriched = facts
            if let ticker = researchTicker {
                let news = await StockSageNewsService.observation(for: ticker, limit: 3, now: facts.at)
                guard active() else {
                    if chat.pending == id { chat.cancel() }
                    return
                }
                enriched = StockSageChat.addingResearch(to: facts, symbol: ticker, observation: news,
                    leads: StockSageResearchLeads.load(symbol: ticker, now: facts.at), webAllowed: ToolPolicy.isExternalAllowed)
                guard chat.attachResearch(id: id, snapshot: enriched) else { return }
            }
            guard let prompt = StockSageChat.prompt(question: text, snapshot: enriched, history: history) else {
                chat.finish(id: id, text: nil, unavailable: "This context is too large for the local request. Ask a shorter question or use fewer tickers. Source snapshots remain available.")
                return
            }
            let includesNews = enriched.sources?.contains { $0.id.contains(".news.") } == true
            guard !includesNews || ToolPolicy.isExternalAllowed else { chat.cancel(); return }
            let allowed: @MainActor @Sendable () -> Bool = { active() && (!includesNews || ToolPolicy.isExternalAllowed) }
            let probe = await StockSageLocalModelServer.probe(config, stillValid: allowed)
            guard active(),
                  !includesNews || ToolPolicy.isExternalAllowed else {
                if chat.pending == id { chat.cancel() }
                return
            }
            guard probe.reachable && probe.hasModel else {
                chat.finish(id: id, text: nil, unavailable: probe.reachable
                    ? "The server is reachable, but the configured model was not found. Check its model ID in Model settings."
                    : "The model server could not be verified. Check that it is running, then use Test connection in Model settings.")
                return
            }
            let result = await StockSageLocalModelServer.complete(config, isOllama: probe.isOllama,
                system: StockSageChat.instructions, user: prompt, maxTokens: StockSageChat.outputTokens,
                contextTokens: StockSageChat.contextTokens, timeout: StockSageChat.requestTimeout, stillValid: allowed)
            guard active(),
                  !includesNews || ToolPolicy.isExternalAllowed else {
                // Identity ownership makes clear/cancel/newer requests immune to late completions.
                if chat.pending == id { chat.cancel() }
                return
            }
            switch result {
            case .success(let response): chat.finish(id: id, text: response)
            case .failure: chat.finish(id: id, text: nil, unavailable: "The model request failed or was interrupted. Your saved facts remain available. Check Model settings and retry; no answer was assumed.")
            }
        }
    }
}
