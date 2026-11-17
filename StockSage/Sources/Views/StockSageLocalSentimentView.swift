import SwiftUI

/// One explicit headline check. No background scan, persisted opinion or trading input.
struct StockSageLocalSentimentView: View {
    let evidence: StockSageLocalSentiment.Evidence
    let evidenceCurrent: Bool
    @AppStorage(StockSageLocalModelServer.backendKey) private var backend = "auto"
    @AppStorage(StockSageLocalModelServer.urlKey) private var serverURL = StockSageLocalModelServer.defaultURL
    @AppStorage(StockSageLocalModelServer.modelKey) private var model = StockSageLocalModelServer.defaultModel
    @AppStorage(StockSageLocalModelServer.revisionKey) private var revision = ""
    @State private var requestID: UUID?
    @State private var result: StockSageLocalSentiment.Result?

    private var settings: [String] { [backend, serverURL, model, revision] }
    private var config: StockSageLocalModelServer.Config? {
        guard ["auto", "localServerOnly"].contains(backend),
              let config = StockSageLocalModelServer.config(url: serverURL, model: model),
              StockSageLocalModelServer.isLoopback(config.baseURL) else { return nil }
        return config
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: evidence.excerpt).textSelection(.enabled)
                HStack {
                    if requestID != nil {
                        ProgressView().controlSize(.small)
                        Text("Checking headline…")
                        Button("Cancel") { requestID = nil; result = .unavailable(.cancelled) }
                    } else {
                        Button(result == nil ? "Check headline sentiment" : "Check again") { requestID = UUID(); result = nil }
                            .disabled(config == nil || !evidenceCurrent || !evidence.valid(at: context.date))
                    }
                }
                if !evidenceCurrent || !evidence.valid(at: context.date) {
                    Text("Headline evidence is no longer current. Tap Explain to refresh the sources.")
                } else if config == nil {
                    Text("Choose a local server in Explanation model settings first. iPhone loopback does not connect to your Mac.")
                } else if let result {
                    switch result {
                    case .available(let record):
                        Text("Local sentiment: \(record.label.rawValue.capitalized) · \(record.model)")
                            .fontWeight(.medium)
                        Text("Headline only · \(record.evidence.item.source) · checked \(record.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                        Text("FinGPT-style interpretation; can be wrong, including when an article contains instructions. Not a trade signal or confidence score.")
                    case .unavailable(let failure):
                        Text(failure.message)
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: requestID) {
            guard let id = requestID, let capturedConfig = config else { return }
            let captured = evidence
            let reply = await StockSageLocalSentiment.classify(captured, config: capturedConfig,
                stillValid: { requestID == id && evidenceCurrent && captured == evidence && config == capturedConfig })
            guard !Task.isCancelled, requestID == id else { return }
            result = reply
            requestID = nil
        }
        .onChange(of: settings) { _, _ in invalidate() }
        .onChange(of: evidence) { _, _ in invalidate() }
        .onChange(of: evidenceCurrent) { _, _ in invalidate() }
    }

    private func invalidate() {
        requestID = nil
        result = .unavailable(.obsolete)
    }
}
