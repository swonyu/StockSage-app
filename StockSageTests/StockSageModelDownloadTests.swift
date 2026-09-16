import Foundation
import Testing
@testable import StockSage

@Suite("Managed model download") @MainActor
struct StockSageModelDownloadTests {
    typealias S = StockSageLocalModelServer

    static let installed = #"{"models":[{"type":"llm","key":"qwen3.5-9b","publisher":"mlx-community","architecture":"qwen3_5","params_string":"9B","format":"mlx","quantization":{"name":"6bit","bits_per_weight":6},"loaded_instances":[]}]}"#

    static func response(_ request: URLRequest, _ json: String, status: Int = 200) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    #if os(macOS)
    @Test func oneDownloadUsesCurrent6BitSourceAndRequiresInventoryConfirmation() async throws {
        let domain = "StockSageModelDownloadTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = StockSageModelDownload(defaults: defaults)
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        var calls: [URLRequest] = []
        var downloaded = false
        var fractions: [Double?] = []
        let transport: StockSageModelDownload.Transport = { request in
            calls.append(request)
            switch request.url!.path {
            case "/api/v1/models": return Self.response(request, downloaded ? Self.installed : #"{"models":[]}"#)
            case "/api/v1/models/download":
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                #expect(body == ["model": "https://huggingface.co/mlx-community/Qwen3.5-9B-6bit"])
                return Self.response(request, #"{"job_id":"job_1","status":"downloading","total_size_bytes":100,"downloaded_bytes":20}"#)
            default:
                #expect(request.url!.path == "/api/v1/models/download/status/job_1")
                downloaded = true
                return Self.response(request, #"{"job_id":"job_1","status":"completed","total_size_bytes":100,"downloaded_bytes":100}"#)
            }
        }
        manager.start(config, transport: transport, allowed: { true }, sleep: { fractions.append(manager.fraction) })
        manager.start(config, transport: transport, allowed: { true })
        for _ in 0..<4000 where manager.isWorking { await Task.yield() }
        #expect(!manager.isWorking && manager.ready)
        #expect(fractions == [0.2])
        #expect(calls.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(calls.filter { $0.url!.path == "/api/v1/models" }.count == 2)
        #expect(defaults.data(forKey: StockSageModelDownload.receiptKey) == nil)
    }

    @Test(arguments: ["denied", "present", "malformed", "unauthorized", "custom"])
    func unsuccessfulChecksNeverRequestWeights(scenario: String) async throws {
        let domain = "StockSageModelDownloadTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = StockSageModelDownload(defaults: defaults)
        let config = try #require(S.config(url: S.lmStudioURL, model: scenario == "custom" ? "custom-model" : S.lmStudioModel))
        var calls = 0
        manager.start(config, transport: { request in
            calls += 1
            #expect(request.httpMethod == "GET")
            return Self.response(request, scenario == "present" ? Self.installed : #"{}"#, status: scenario == "unauthorized" ? 401 : 200)
        }, allowed: { scenario != "denied" })
        for _ in 0..<4000 where manager.isWorking { await Task.yield() }
        #expect(!manager.isWorking)
        #expect(calls == (["denied", "custom"].contains(scenario) ? 0 : 1))
        #expect(manager.ready == (scenario == "present"))
    }

    @Test(arguments: [false, true])
    func restartRetainsKnownJobAndUnknownSubmissionWithoutDuplicatePOST(accepted: Bool) async throws {
        let domain = "StockSageModelDownloadTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        var posts = 0
        var checks = 0
        var active = true
        let wire: StockSageModelDownload.Transport = { request in
            if request.httpMethod == "POST" {
                posts += 1
                if !accepted { throw URLError(.timedOut) }
                active = false // Receipt must survive settings revocation while POST was in flight.
                return Self.response(request, #"{"job_id":"job_saved","status":"downloading"}"#)
            }
            if request.url!.path.contains("/status/") {
                checks += 1
                return Self.response(request, #"{"job_id":"job_saved","status":"paused"}"#)
            }
            return Self.response(request, #"{"models":[]}"#)
        }
        let first = StockSageModelDownload(defaults: defaults)
        first.start(config, transport: wire, allowed: { active }, sleep: {})
        for _ in 0..<4000 where first.isWorking { await Task.yield() }
        #expect(!first.isWorking && !first.ready)
        active = true
        let second = StockSageModelDownload(defaults: defaults)
        second.start(config, retry: true, transport: wire, allowed: { active }, sleep: {})
        for _ in 0..<4000 where second.isWorking { await Task.yield() }
        #expect(!second.isWorking && !second.ready)
        #expect(posts == 1)
        #expect(checks == (accepted ? 1 : 0))
    }

    @Test func completionWithoutCompatibleInventoryCannotClaimReady() async throws {
        let domain = "StockSageModelDownloadTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = StockSageModelDownload(defaults: defaults)
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        manager.start(config, transport: { request in
            Self.response(request, request.httpMethod == "POST" ? #"{"status":"already_downloaded"}"# : #"{"models":[]}"#)
        }, allowed: { true }, sleep: {})
        for _ in 0..<4000 where manager.isWorking { await Task.yield() }
        #expect(!manager.ready && !manager.isWorking)
        #expect(manager.message.contains("not verified"))
    }
    #endif
}
