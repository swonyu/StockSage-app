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

    @Test(arguments: [false, true])
    func compatibleCopiesResolveTheLoadedInstanceRegardlessOfOrder(reverse: Bool) async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        let inventory = try JSONSerialization.jsonObject(with: Data(Self.installed.utf8)) as! [String: Any]
        let empty = (inventory["models"] as! [[String: Any]])[0]
        var loaded = empty
        loaded["loaded_instances"] = [["id": config.model, "config": ["context_length": 71680]]]
        var other = empty
        other["key"] = "other"
        other["loaded_instances"] = [["id": "other_instance"]]
        let rows = (reverse ? [loaded, empty] : [empty, loaded]) + [other]
        let object: [String: Any] = ["models": rows]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let probe = await S.probe(config, transport: { request in
            #expect(request.httpMethod == "GET" && request.url!.path == "/api/v1/models")
            return Self.response(request, json)
        })
        #expect(probe.hasModel && !probe.canDownload)
        #expect(S.verifiedContext(object, model: config.model) == 71680)
        var posts = 0
        let stopped = await S.unloadOnQuit(config, transport: { request in
            if request.httpMethod == "POST" {
                posts += 1
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                #expect(body == ["instance_id": config.model])
                return Self.response(request, #"{"instance_id":"qwen3.5-9b"}"#)
            }
            let current = posts == 0 ? rows : [empty, empty, other]
            return Self.response(request, String(decoding: try JSONSerialization.data(withJSONObject: ["models": current]), as: UTF8.self))
        })
        #expect(stopped && posts == 1)
    }

    @Test(arguments: ["variant", "duplicate-instance", "malformed", "custom"])
    func ambiguousCopiesNeverConfirmContextOrUnload(scenario: String) async throws {
        let inventory = try JSONSerialization.jsonObject(with: Data(Self.installed.utf8)) as! [String: Any]
        var first = (inventory["models"] as! [[String: Any]])[0]
        let model = scenario == "custom" ? "custom" : S.lmStudioModel
        first["key"] = model
        first["loaded_instances"] = [["id": model, "config": ["context_length": 71680]]]
        var second = first
        if scenario == "variant" { second["quantization"] = ["bits_per_weight": 4] }
        if scenario == "malformed" { second["loaded_instances"] = "invalid" }
        let object: [String: Any] = ["models": [first, second]]
        #expect(S.verifiedContext(object, model: model) == nil)
        if scenario == "variant" {
            #expect(S.managedInventory(object)?.hasModel == false)
            #expect(S.managedInventory(object)?.canDownload == false)
        }
        let config = try #require(S.config(url: S.lmStudioURL, model: model))
        let stopped = await S.unloadOnQuit(config, transport: { request in
            #expect(request.httpMethod == "GET")
            return Self.response(request, String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        })
        #expect(!stopped)
    }

    @Test func unloadedNativeInventoryIsPresentWithoutLoadingOrDownloading() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        var paths: [String] = []
        let probe = await S.probe(config, transport: { request in
            paths.append(request.url!.path)
            #expect(request.httpMethod == "GET")
            return Self.response(request, request.url!.path == "/api/v1/models" ? Self.installed : #"{"data":[]}"#)
        })
        #expect(probe.reachable && probe.hasModel)
        #expect(paths == ["/api/v1/models"])
    }

    @Test(arguments: ["complete", "empty", "repeated", "settings", "deadline", "tight", "secondDeadline", "secondHTTP", "secondModel", "secondContext"])
    func outputLimitRecoveryIsBoundedAndUsesTheSameEvidence(scenario: String) async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        var instant = ContinuousClock.now
        var active = true
        var posts = 0
        let context = scenario == "tight" ? 500 : 4096
        let schema = StockSageAIAssessment.responseSchema(facts: ["same facts"])
        let result = await S.completeDetailed(config, isOllama: false, system: "same instructions", user: "same facts",
            maxTokens: 192, contextTokens: context, timeout: 10, jsonSchema: schema, stillValid: { active }, transport: { request in
                if request.httpMethod == "POST" {
                    posts += 1
                    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                    let format = try #require(body["response_format"] as? [String: Any])
                    let sent = try #require(format["json_schema"] as? [String: Any])
                    let actual = try JSONSerialization.data(withJSONObject: sent["schema"]!, options: .sortedKeys)
                    let expected = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: schema!), options: .sortedKeys)
                    #expect(actual == expected)
                    #expect(body["max_tokens"] as? Int == (posts == 1 ? 192 : 384))
                    #expect(body["messages"] as? [[String: String]] == [
                        ["role": "system", "content": "same instructions"], ["role": "user", "content": "same facts"]])
                    if scenario == "settings" { active = false }
                    if scenario == "deadline" { instant = instant.advanced(by: .seconds(11)) }
                    if scenario == "secondDeadline" { instant = instant.advanced(by: .seconds(posts == 1 ? 8 : 3)) }
                    if scenario == "secondHTTP", posts == 2 { return Self.response(request, "{}", status: 503) }
                    let finish = posts == 2 && scenario != "repeated" ? "stop" : "length"
                    let text = scenario == "empty" && posts == 1 ? "" : "fixture"
                    let model = scenario == "secondModel" && posts == 2 ? "wrong-model" : "qwen3.5-9b"
                    return Self.response(request, #"{"model":"\#(model)","choices":[{"message":{"content":"\#(text)"},"finish_reason":"\#(finish)"}]}"#)
                }
                return Self.response(request, Self.installed.replacingOccurrences(of: "\"loaded_instances\":[]",
                    with: #""loaded_instances":[{"id":"qwen3.5-9b","config":{"context_length":\#(scenario == "secondContext" ? 512 : 4096)}}]"#))
            }, clock: { instant })
        #expect(posts == (["settings", "deadline", "tight"].contains(scenario) ? 1 : 2))
        switch result {
        case .success(let reply):
            #expect(["complete", "empty"].contains(scenario) && reply.text == "fixture")
            #expect(reply.diagnostic.outputLimitRetries == 1)
        case .failure(let failure):
            #expect(!["complete", "empty"].contains(scenario))
            #expect(failure.diagnostic.outputLimitRetries == posts - 1)
            if scenario == "secondDeadline" { #expect(failure.diagnostic.category == .timeout) }
        }
    }

    @Test func nativeAbsenceIsNotInferredFromMalformedOrIncompatibleInventory() throws {
        for json in [#"{}"#, #"{"models":[{}]}"#, #"{"models":[{"key":"","type":"llm"}]}"#,
                     #"{"models":[{"key":"other","type":"unknown"}]}"#] {
            #expect(S.managedInventory(try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]) == nil)
        }
        for json in [Self.installed.replacingOccurrences(of: "\"mlx\"", with: "\"gguf\""),
                     Self.installed.replacingOccurrences(of: "\"bits_per_weight\":6", with: "\"bits_per_weight\":4"),
                     Self.installed.replacingOccurrences(of: "\"9B\"", with: "\"27B\"")] {
            let probe = try #require(S.managedInventory(JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]))
            #expect(!probe.hasModel && !probe.canDownload)
        }
        #expect(S.managedInventory(["models": [[String: Any]]()])?.canDownload == true)
    }

    @Test(arguments: [false, true])
    func quitUnloadsOnlySelectedModelAndVerifiesItIsGone(ollama: Bool) async throws {
        let config = try #require(S.config(url: ollama ? S.defaultURL : S.lmStudioURL, model: S.lmStudioModel))
        var unloaded = false
        var posts = 0
        let result = await S.unloadOnQuit(config, transport: { request in
            if request.httpMethod == "POST" {
                posts += 1; unloaded = true
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                if ollama {
                    #expect(request.url!.path == "/api/generate")
                    #expect(body["model"] as? String == config.model && body["keep_alive"] as? Int == 0)
                    #expect(body["prompt"] as? String == "")
                } else {
                    #expect(request.url!.path == "/api/v1/models/unload")
                    #expect(body["instance_id"] as? String == "owned_instance")
                }
                return Self.response(request, #"{"instance_id":"owned_instance","done":true}"#)
            }
            if ollama {
                return Self.response(request, unloaded ? #"{"models":[{"name":"other"}]}"# : #"{"models":[{"name":"qwen3.5-9b:latest"},{"name":"other"}]}"#)
            }
            let ids = unloaded ? "[]" : #"[{"id":"owned_instance"}]"#
            return Self.response(request, #"{"models":[{"key":"qwen3.5-9b","type":"llm","loaded_instances":\#(ids)},{"key":"other","type":"llm","loaded_instances":[{"id":"other_instance"}]}]}"#)
        })
        #expect(result && posts == 1)
    }

    @Test(arguments: ["http://192.168.1.5:1234", "http://127.0.0.1:8888"])
    func quitCannotControlRemoteOrUnknownRuntime(url: String) async throws {
        let config = try #require(S.config(url: url, model: S.lmStudioModel))
        var calls = 0
        let result = await S.unloadOnQuit(config, transport: { request in calls += 1; return Self.response(request, #"{}"#) })
        #expect(!result && calls == 0)
    }

    @Test func quitFailureIsNotReportedAsUnloaded() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        let result = await S.unloadOnQuit(config, transport: { request in Self.response(request, #"{}"#, status: 401) })
        #expect(!result)
    }

    @Test func quitWithUnresolvedJITDoesNotTreatEmptyInventoryAsConfirmedUnload() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        #expect(await S.unloadOnQuit(config, inferenceWasActive: true, transport: { request in
            Self.response(request, Self.installed)
        }) == false)
    }

    @Test(arguments: ["adequate", "small", "missing", "sibling", "ambiguous", "deadline", "cancelled"])
    func bufferedAnswerRequiresServingContextWithinOriginalDeadline(scenario: String) async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        var instant = ContinuousClock.now
        var active = true
        let result = await S.completeDetailed(config, isOllama: false, system: "facts", user: "fixture",
            contextTokens: 32768, stillValid: { active }, transport: { request in
                if request.httpMethod == "POST" {
                    return Self.response(request, #"{"model":"qwen3.5-9b","choices":[{"message":{"content":"Buffered fixture answer"},"finish_reason":"stop"}]}"#)
                }
                if scenario == "deadline" { instant = instant.advanced(by: .seconds(91)) }
                if scenario == "cancelled" { active = false }
                let id = scenario == "sibling" ? "another_instance" : config.model
                let size = scenario == "small" ? 4096 : 32768
                let one = #"{"id":"\#(id)","config":{"context_length":\#(size)}}"#
                let instances = scenario == "missing" ? "[]" : scenario == "ambiguous" ? "[\(one),\(one)]" : "[\(one)]"
                return Self.response(request, Self.installed.replacingOccurrences(of: "\"loaded_instances\":[]", with: "\"loaded_instances\":\(instances)"))
            }, clock: { instant })
        if scenario == "adequate" { #expect(try result.get().text == "Buffered fixture answer") }
        else {
            guard case .failure(let failure) = result else { Issue.record("Unverified answer escaped"); return }
            #expect(failure.diagnostic.category == (scenario == "deadline" ? .timeout : scenario == "cancelled" ? .obsoleteRequest : .contextBudget))
        }
    }

    @Test func contextVerificationCannotExtendTheTotalDeadline() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        var instant = ContinuousClock.now
        var wire: CheckedContinuation<(Data, URLResponse), Error>?
        var timers: [CheckedContinuation<Void, Error>] = []
        var settled = false
        let task = Task { @MainActor in
            let result = await S.completeDetailed(config, isOllama: false, system: "s", user: "u", timeout: 10,
                transport: { request in
                    if request.httpMethod == "POST" {
                        return Self.response(request, #"{"model":"qwen3.5-9b","choices":[{"message":{"content":"fixture"},"finish_reason":"stop"}]}"#)
                    }
                    return try await withCheckedThrowingContinuation { wire = $0 }
                }, clock: { instant }, sleepUntil: { _ in
                    try await withCheckedThrowingContinuation { timers.append($0) }
                })
            settled = true
            return result
        }
        defer {
            task.cancel(); wire?.resume(throwing: CancellationError())
            for timer in timers { timer.resume(throwing: CancellationError()) }
        }
        for _ in 0..<2000 where wire == nil { await Task.yield() }
        try #require(wire != nil)
        instant = instant.advanced(by: .seconds(10))
        // Fire the original caller clock, without releasing the stalled inventory transport.
        for _ in 0..<2000 where timers.count < 2 { await Task.yield() }
        for timer in timers { timer.resume() }; timers.removeAll()
        for _ in 0..<2000 where !settled { await Task.yield() }
        try #require(settled, "Context verification must share the caller deadline")
        guard case .failure(let failure) = await task.value else { Issue.record("Expected timeout"); return }
        #expect(failure.diagnostic.category == .timeout && wire != nil)
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
