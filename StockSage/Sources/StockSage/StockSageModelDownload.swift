import Foundation
import Observation

/// The weights and transfer belong to LM Studio. StockSage owns only a small receipt and
/// status polling. No shell, model deletion, load request, or arbitrary catalog selection.
@Observable @MainActor final class StockSageModelDownload {
    static let shared = StockSageModelDownload()
    static let source = "https://huggingface.co/mlx-community/Qwen3.5-9B-6bit"
    static let receiptKey = "stocksage.modelDownload.receipt"
    typealias Server = StockSageLocalModelServer
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    private(set) var message = "Missing models download the current Qwen3.5 9B MLX 6-bit release (about 8.2 GB)."
    private(set) var fraction: Double?
    private(set) var isWorking = false
    private(set) var ready = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    private static let session = URLSession(configuration: .ephemeral, delegate: StockSageHTTP.NoRedirect(), delegateQueue: nil)

    private struct Receipt: Codable {
        var server: String
        var job: String?
        // requested = acceptance uncertain; failed = an explicit server failure permits retry.
        var phase: String
    }
    private struct Job: Decodable {
        var job_id: String?
        var status: String
        var total_size_bytes: Double?
        var downloaded_bytes: Double?

        var progress: Double? {
            guard let total = total_size_bytes, let done = downloaded_bytes,
                  total.isFinite, done.isFinite, total > 0, done >= 0, done <= total else { return nil }
            return done / total
        }
    }
    private enum DownloadError: Error { case rejected(Int), malformed, stopped }

    private static func validJobID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    func stopChecking() { worker?.cancel() } // The native transfer may continue in LM Studio.

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func save(_ receipt: Receipt?) {
        if let receipt, let data = try? JSONEncoder().encode(receipt) { defaults.set(data, forKey: Self.receiptKey) }
        else { defaults.removeObject(forKey: Self.receiptKey) }
    }

    /// Resume an existing job; retry=true only permits another POST after a confirmed failure.
    /// One manager serves all callers. Cancelling research never cancels another caller's download.
    func start(_ config: Server.Config, retry: Bool = false,
               transport: Transport? = nil, allowed: (@MainActor () -> Bool)? = nil,
               sleep: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }) {
        #if os(macOS)
        guard config.isLMStudio9B, worker == nil else { return }
        let revision = Server.settingsRevision(defaults)
        let policyRevision = AppSettings.policyRevision(defaults: defaults)
        let active: @MainActor () -> Bool = allowed ?? { [defaults] in
            let backend = StockSageCatalystNarrator.selectedBackend(defaults.string(forKey: Server.backendKey))
            return !Server.isShuttingDown && ToolPolicy.isExternalAllowed && Server.settingsRevision(defaults) == revision
                && AppSettings.policyRevision(defaults: defaults) == policyRevision
                && (backend == .auto || backend == .localServerOnly)
                && Server.config(url: defaults.string(forKey: Server.urlKey) ?? Server.defaultURL,
                                 model: defaults.string(forKey: Server.modelKey) ?? Server.defaultModel) == config
        }
        guard active() else {
            message = "Download not started. Select the LM Studio 9B profile and enable Web access with Offline Mode off."
            return
        }
        isWorking = true; ready = false; fraction = nil
        message = "Checking downloaded models in LM Studio…"
        worker = Task { [self] in
            defer { worker = nil; isWorking = false }
            await run(config, retry: retry, transport: transport, active: active, sleep: sleep)
        }
        #else
        message = "Download the model in StockSage on your Mac. This iPhone does not download or replace Mac models."
        #endif
    }

    private func request(_ request: URLRequest, transport: Transport?, active: @MainActor () -> Bool,
                         retainSubmissionReceipt: Bool = false) async throws -> Data {
        guard active(), !Task.isCancelled else { throw DownloadError.stopped }
        let (data, response) = try await Server.Pending<(Data, URLResponse)>().run(
            deadline: ContinuousClock.now.advanced(by: .seconds(15))) {
                if let transport { return try await transport(request) }
                return try await StockSageHTTP.data(for: request, session: Self.session, maximumBytes: 262_144)
            }
        guard retainSubmissionReceipt || (active() && !Task.isCancelled) else { throw DownloadError.stopped }
        guard data.count <= 262_144, let response = response as? HTTPURLResponse else { throw DownloadError.malformed }
        guard (200..<300).contains(response.statusCode) else { throw DownloadError.rejected(response.statusCode) }
        return data
    }

    private func run(_ config: Server.Config, retry: Bool, transport: Transport?,
                     active: @MainActor () -> Bool, sleep: () async throws -> Void) async {
        var receipt: Receipt?
        var posting = false
        do {
            let inventoryURL = config.baseURL.appendingPathComponent("api/v1/models")
            let data = try await request(URLRequest(url: inventoryURL), transport: transport, active: active)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let inventory = Server.managedInventory(json) else { throw DownloadError.malformed }
            if inventory.hasModel { save(nil); ready = true; message = inventory.detail; return }
            guard inventory.canDownload else { message = inventory.detail; return }
            if let saved = defaults.data(forKey: Self.receiptKey) {
                receipt = try JSONDecoder().decode(Receipt.self, from: saved)
                guard receipt?.server == config.baseURL.absoluteString else {
                    message = "A download belongs to another server address. Check that job in LM Studio before changing its address back."
                    return
                }
                if receipt?.phase == "failed", retry { receipt = nil }
                else if receipt?.phase == "failed" {
                    message = "The download failed. Check LM Studio, then use Download / check current model to retry."
                    return
                }
                else if receipt?.job == nil {
                    message = "The earlier download's acceptance is unknown. Check LM Studio Downloads; StockSage will not submit a duplicate."
                    return
                }
            }
            var job: Job
            if let id = receipt?.job {
                job = Job(job_id: id, status: "downloading")
            } else {
                receipt = Receipt(server: config.baseURL.absoluteString, phase: "requested")
                save(receipt) // Record uncertainty BEFORE submitting, including across restart.
                var req = URLRequest(url: config.baseURL.appendingPathComponent("api/v1/models/download"))
                req.httpMethod = "POST"; req.timeoutInterval = 15
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["model": Self.source])
                message = "Requesting the current Qwen3.5 9B MLX 6-bit release…"
                posting = true
                job = try JSONDecoder().decode(Job.self, from: await request(req, transport: transport, active: active,
                    retainSubmissionReceipt: true))
                posting = false
                // The native job belongs to the manager even if the initiating settings were
                // changed while POST was suspended. Record it without activating anything.
                if let id = job.job_id, Self.validJobID(id) {
                    receipt?.job = id; receipt?.phase = "tracking"; save(receipt)
                }
            }
            while true {
                guard active(), !Task.isCancelled else { throw DownloadError.stopped }
                fraction = job.progress
                if ["completed", "already_downloaded"].contains(job.status) {
                    let data = try await request(URLRequest(url: inventoryURL), transport: transport, active: active)
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    guard let json, Server.managedInventory(json)?.hasModel == true else {
                        message = "Download reported complete, but the 9B MLX 6-bit inventory is not verified. Check LM Studio, then check again."
                        return
                    }
                    save(nil); ready = true; fraction = 1
                    message = "Qwen3.5 9B MLX 6-bit is downloaded. Retry research with current data; inference quality has not been tested by this download."
                    return
                }
                if job.status == "failed" {
                    receipt?.phase = "failed"; save(receipt)
                    message = "LM Studio reported a failed download. Check storage and connection, then Retry download. Your other models were kept."
                    return
                }
                guard ["downloading", "paused"].contains(job.status), let id = job.job_id,
                      Self.validJobID(id) else {
                    throw DownloadError.malformed
                }
                receipt?.job = id; receipt?.phase = "tracking"; save(receipt)
                if job.status == "paused" {
                    message = "Download paused in LM Studio. Resume it there, then Check download here."
                    return
                }
                message = "Downloading Qwen3.5 9B MLX 6-bit in LM Studio"
                    + (fraction.map { " · \(Int($0 * 100))%" } ?? " · size not yet reported")
                    + ". You can keep using StockSage."
                try await sleep()
                let req = URLRequest(url: config.baseURL.appendingPathComponent("api/v1/models/download/status").appendingPathComponent(id))
                let next = try JSONDecoder().decode(Job.self, from: await request(req, transport: transport, active: active))
                guard next.job_id == id else { throw DownloadError.malformed }
                job = next
            }
        } catch DownloadError.stopped {
            message = "Stopped checking because settings or network access changed. An accepted download may continue in LM Studio; pause or cancel it there."
        } catch DownloadError.rejected(let status) {
            if posting, (400..<500).contains(status) { receipt?.phase = "failed"; save(receipt) }
            message = "LM Studio rejected the model request (HTTP \(status)). Check its server, authentication, model-download support and Downloads panel, then retry."
        } catch {
            message = "Could not verify the download. Open LM Studio Downloads to check it; Check download resumes a known job without starting a duplicate."
        }
    }
}
