import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// One shared load for launch and AI-use callers. LM Studio owns weights and load defaults.
@Observable @MainActor final class StockSageLocalModelStartup {
    typealias S = StockSageLocalModelServer
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    static let shared = StockSageLocalModelStartup()
    static let enabledKey = "stocksage.model.autoLoadOnLaunch"
    private(set) var message: String?
    private(set) var isWorking = false
    private(set) var ready = false
    @ObservationIgnored private var worker: Task<S.Probe, Never>?
    @ObservationIgnored private var launching: Task<Void, Never>?
    @ObservationIgnored private var activeConfig: S.Config?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var loadMayBePending = false
    var pendingConfig: S.Config? { worker != nil || loadMayBePending ? activeConfig : nil }

    private static func selectedLocalConfig(_ defaults: UserDefaults) -> S.Config? {
        let backend = StockSageCatalystNarrator.selectedBackend(defaults.string(forKey: S.backendKey))
        guard backend == .auto || backend == .localServerOnly,
              let config = S.config(url: defaults.string(forKey: S.urlKey) ?? S.defaultURL,
                                    model: defaults.string(forKey: S.modelKey) ?? S.defaultModel),
              config.supportsLocalUnload else { return nil }
        return config
    }

    /// Uncertain submissions retain their original server; successful default use must also
    /// remain eligible for the same local-only cleanup as an explicitly saved configuration.
    func quitConfig(defaults: UserDefaults = .standard) -> S.Config? {
        pendingConfig ?? Self.selectedLocalConfig(defaults)
    }

    static func startupConfig(_ defaults: UserDefaults = .standard) -> S.Config? {
        guard defaults.bool(forKey: enabledKey), let config = selectedLocalConfig(defaults),
              config.isLMStudioGemma else { return nil }
        return config
    }

    /// Explicit recovery prepares the selected local model only. It neither enables launch
    /// loading nor replays the research/chat action that failed.
    @discardableResult func retryFromSavedSettings(defaults: UserDefaults = .standard,
                                                   transport: Transport? = nil) async -> S.Probe? {
        guard !S.isShuttingDown, !Task.isCancelled,
              let config = Self.selectedLocalConfig(defaults), config.isLMStudioGemma else { return nil }
        let revision = S.settingsRevision(defaults)
        #if os(macOS)
        if transport == nil, !StockSageStore.isRunningTests {
            let options = NSWorkspace.OpenConfiguration()
            options.activates = false
            _ = try? await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/Applications/LM Studio.app"), configuration: options)
        }
        #endif
        return await ensureLoaded(config, stillValid: {
            S.settingsRevision(defaults) == revision && Self.selectedLocalConfig(defaults) == config
        }, transport: transport)
    }

    func startFromSavedSettings() {
        #if os(macOS)
        guard !StockSageStore.isRunningTests, launching == nil, !S.isShuttingDown,
              let config = Self.startupConfig() else { return }
        let revision = S.settingsRevision()
        message = "Starting Gemma 4 31B…"
        launching = Task {
            defer { launching = nil }
            let options = NSWorkspace.OpenConfiguration()
            options.activates = false
            _ = try? await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/Applications/LM Studio.app"), configuration: options)
            guard !Task.isCancelled else { return }
            _ = await ensureLoaded(config, stillValid: {
                S.settingsRevision() == revision && Self.startupConfig() == config
            })
        }
        #endif
    }

    /// A cancelled accepted load can finish in the server. Quit must not confirm an empty
    /// inventory as successful unloading while that submission remains uncertain.
    @discardableResult func cancel() -> Bool {
        let pending = loadMayBePending
        launching?.cancel(); worker?.cancel(); session?.invalidateAndCancel()
        return pending
    }

    func ensureLoaded(_ config: S.Config, stillValid: @escaping @MainActor () -> Bool = { true },
                      transport: Transport? = nil) async -> S.Probe {
        func failed(_ text: String) -> S.Probe {
            S.Probe(reachable: false, isOllama: false, models: [], hasModel: false, detail: text)
        }
        func wait(for worker: Task<S.Probe, Never>) async -> S.Probe {
            do {
                let result = try await S.Pending<S.Probe>().run { await worker.value }
                guard !Task.isCancelled, stillValid() else { throw CancellationError() }
                return result
            } catch { return failed("Gemma loading stopped for this request.") }
        }
        guard config.isLMStudioGemma, !S.isShuttingDown, !Task.isCancelled, stillValid() else {
            return failed("Gemma loading stopped: the selected model or app state changed.")
        }
        if let worker {
            guard activeConfig == config else { return failed("Another model load is still finishing.") }
            return await wait(for: worker)
        }
        guard !loadMayBePending || activeConfig == config else {
            return failed("The earlier Gemma load is unconfirmed at its original server. Check LM Studio before changing servers.")
        }
        let revision = S.settingsRevision()
        activeConfig = config; isWorking = true; ready = false
        message = "Loading Gemma 4 31B in LM Studio…"
        let worker = Task { [self] in
            defer {
                self.worker = nil; isWorking = false
                if !loadMayBePending { activeConfig = nil }
            }
            let client = URLSession(configuration: .ephemeral, delegate: S.NoRedirect(), delegateQueue: nil)
            session = client
            defer { client.invalidateAndCancel(); session = nil }
            @MainActor func active() throws {
                guard !Task.isCancelled, !S.isShuttingDown, S.settingsRevision() == revision else { throw CancellationError() }
            }
            do {
                let result = try await S.Pending<S.Probe>().run(deadline: .now.advanced(by: .seconds(120))) { [self] in
                    @MainActor func json(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
                        try active()
                        var req = URLRequest(url: config.baseURL.appendingPathComponent(path))
                        req.timeoutInterval = body == nil ? 2.5 : 110
                        if let body {
                            req.httpMethod = "POST"
                            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            req.httpBody = try JSONSerialization.data(withJSONObject: body)
                            self.loadMayBePending = true
                        }
                        let (data, response): (Data, URLResponse)
                        if let transport { (data, response) = try await transport(req) }
                        else { (data, response) = try await StockSageHTTP.data(for: req, session: client, maximumBytes: 262_144) }
                        try active()
                        if let http = response as? HTTPURLResponse, (400..<500).contains(http.statusCode), body != nil {
                            self.loadMayBePending = false // explicit rejection, not a lost acknowledgement
                        }
                        guard data.count <= 262_144, let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            throw URLError(.badServerResponse)
                        }
                        return object
                    }
                    @MainActor func readyProbe(_ inventory: [String: Any], models: [String]) -> S.Probe? {
                        guard let context = S.verifiedContext(inventory, model: config.model),
                              context >= S.researchContextTokens else { return nil }
                        return S.Probe(reachable: true, isOllama: false, models: models,
                            hasModel: true, detail: "Gemma 4 31B ready · \(context / 1024)K context · one worker.",
                            servingContext: context)
                    }
                    var inventory: [String: Any]?
                    // NSWorkspace can return before the API opens (measured 0.1s vs 6s).
                    // Retry read-only readiness within the shared deadline; never retry a load POST.
                    for attempt in 0..<30 {
                        do { inventory = try await json("api/v1/models"); break }
                        catch {
                            try active()
                            if transport != nil || attempt == 29 { throw error }
                            try await Task.sleep(for: .milliseconds(500))
                        }
                    }
                    guard let inventory, let probe = S.managedInventory(inventory, modelKey: config.model),
                          probe.hasModel, let rows = inventory["models"] as? [[String: Any]] else {
                        return failed("Gemma 4 31B QAT Q4_0 is unavailable. Check LM Studio My Models.")
                    }
                    if let ready = readyProbe(inventory, models: probe.models) {
                        self.loadMayBePending = false
                        return ready
                    }
                    for row in rows where row["type"] as? String == "llm" {
                        guard let instances = row["loaded_instances"] as? [[String: Any]], instances.isEmpty else {
                            return failed("A model is already loaded with a different configuration. Check LM Studio before loading Gemma; existing models were kept.")
                        }
                    }
                    guard !self.loadMayBePending else {
                        return failed("The earlier Gemma load is unconfirmed. Check LM Studio before retrying; no duplicate load was submitted.")
                    }
                    let reply = try await json("api/v1/models/load", body: ["model": config.model, "echo_load_config": true])
                    guard reply["status"] as? String == "loaded", reply["instance_id"] as? String == config.model else {
                        return failed("Gemma load was not confirmed. Check LM Studio before retrying.")
                    }
                    self.loadMayBePending = false
                    guard let ready = readyProbe(try await json("api/v1/models"), models: probe.models) else {
                        return failed("Gemma is loaded but research readiness was not verified. Check that its existing profile provides at least 16K context and one worker in LM Studio.")
                    }
                    return ready
                }
                ready = result.hasModel; message = result.detail
                return result
            } catch {
                let result = failed("Gemma could not finish loading. Check LM Studio’s server and model status, then retry. " + (loadMayBePending ? "The last load may still be finishing." : ""))
                ready = false; message = result.detail
                return result
            }
        }
        self.worker = worker
        return await wait(for: worker)
    }
}
