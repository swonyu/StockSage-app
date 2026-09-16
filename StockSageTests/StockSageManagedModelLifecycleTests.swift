import Foundation
import Testing
@testable import StockSage

// Real behavioral lifecycle tests for the managed LM Studio profile, moved off
// StockSageModelDownloadTests.swift and re-pointed from the 9B/Qwen managed fixture onto a
// hand-derived Gemma one (Qwen removal Step 4; StockSageLocalModelServerTests.gemmaInventory is
// the shared fixture shape, derived from the Step 0 LM Studio capture, not copied from the
// shipped code's own emission). These are not about downloading (Gemma has no verified download
// source — see StockSageModelDownloadTests.swift, which stays on the 9B fixture and is deleted
// whole in Step 5), they are about probing, unloading and context verification against whatever
// model is actually the managed profile.
//
// managedInventory(_:modelKey:) defaults to lmStudioModel (Qwen) -- every bare call below passes
// modelKey: S.gemmaModel explicitly, or it would silently keep checking the retired identity.
@Suite("Managed model lifecycle (Gemma)") @MainActor
struct StockSageManagedModelLifecycleTests {
    typealias S = StockSageLocalModelServer

    static let installed = #"{"models":[{"type":"llm","key":"google/gemma-4-31b-qat","format":"gguf","architecture":"gemma4","params_string":"31B","quantization":{"name":"Q4_0","bits_per_weight":4},"loaded_instances":[]}]}"#

    static func response(_ request: URLRequest, _ json: String, status: Int = 200) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    @Test(arguments: [false, true])
    func compatibleCopiesResolveTheLoadedInstanceRegardlessOfOrder(reverse: Bool) async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        let inventory = try JSONSerialization.jsonObject(with: Data(Self.installed.utf8)) as! [String: Any]
        let empty = (inventory["models"] as! [[String: Any]])[0]
        var loaded = empty
        loaded["loaded_instances"] = [["id": config.model, "config": ["context_length": 71680, "parallel": 1]]]
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
                return Self.response(request, #"{"instance_id":"\#(S.gemmaModel)"}"#)
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
        let model = scenario == "custom" ? "custom" : S.gemmaModel
        first["key"] = model
        first["loaded_instances"] = [["id": model, "config": ["context_length": 71680, "parallel": 1]]]
        var second = first
        // Different quantization bit count from the fixture's real 4, so two same-keyed rows
        // disagree (ambiguous), same shape as the original Qwen "variant" scenario.
        if scenario == "variant" { second["quantization"] = ["bits_per_weight": 8] }
        if scenario == "malformed" { second["loaded_instances"] = "invalid" }
        let object: [String: Any] = ["models": [first, second]]
        #expect(S.verifiedContext(object, model: model) == nil)
        if scenario == "variant" {
            #expect(S.managedInventory(object, modelKey: S.gemmaModel)?.hasModel == false)
            #expect(S.managedInventory(object, modelKey: S.gemmaModel)?.canDownload == false)
        }
        let config = try #require(S.config(url: S.lmStudioURL, model: model))
        let stopped = await S.unloadOnQuit(config, transport: { request in
            #expect(request.httpMethod == "GET")
            return Self.response(request, String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        })
        #expect(!stopped)
    }

    @Test func unloadedNativeInventoryIsPresentWithoutLoadingOrDownloading() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
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
        let config = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
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
                    let model = scenario == "secondModel" && posts == 2 ? "wrong-model" : S.gemmaModel
                    return Self.response(request, #"{"model":"\#(model)","choices":[{"message":{"content":"\#(text)"},"finish_reason":"\#(finish)"}]}"#)
                }
                return Self.response(request, Self.installed.replacingOccurrences(of: "\"loaded_instances\":[]",
                    with: #""loaded_instances":[{"id":"\#(S.gemmaModel)","config":{"context_length":\#(scenario == "secondContext" ? 512 : 4096),"parallel":1}}]"#))
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
            #expect(S.managedInventory(try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any], modelKey: S.gemmaModel) == nil)
        }
        for json in [Self.installed.replacingOccurrences(of: "\"gguf\"", with: "\"mlx\""),
                     Self.installed.replacingOccurrences(of: "\"bits_per_weight\":4", with: "\"bits_per_weight\":8"),
                     Self.installed.replacingOccurrences(of: "\"31B\"", with: "\"27B\"")] {
            let probe = try #require(S.managedInventory(JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any], modelKey: S.gemmaModel))
            #expect(!probe.hasModel && !probe.canDownload)
        }
        // Gemma has no download mechanism (no verified download source exists): unlike the
        // retired 9B profile, canDownload must stay false even with an empty inventory. This is
        // the real Gemma behavior, not a weakened copy of the 9B assertion it replaces.
        #expect(S.managedInventory(["models": [[String: Any]]()], modelKey: S.gemmaModel)?.canDownload == false)
    }

    @Test(arguments: [false, true])
    func quitUnloadsOnlySelectedModelAndVerifiesItIsGone(ollama: Bool) async throws {
        // Literal, not S.defaultURL: this test is about Ollama-vs-LM-Studio unload branching by
        // port, not about whatever the shipped default happens to be (Qwen removal Step 7 flips it).
        let config = try #require(S.config(url: ollama ? "http://127.0.0.1:11434" : S.lmStudioURL, model: S.gemmaModel))
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
                return Self.response(request, unloaded ? #"{"models":[{"name":"other"}]}"# : #"{"models":[{"name":"\#(config.model):latest"},{"name":"other"}]}"#)
            }
            let ids = unloaded ? "[]" : #"[{"id":"owned_instance"}]"#
            return Self.response(request, #"{"models":[{"key":"\#(S.gemmaModel)","type":"llm","loaded_instances":\#(ids)},{"key":"other","type":"llm","loaded_instances":[{"id":"other_instance"}]}]}"#)
        })
        #expect(result && posts == 1)
    }

    @Test(arguments: ["http://192.168.1.5:1234", "http://127.0.0.1:8888"])
    func quitCannotControlRemoteOrUnknownRuntime(url: String) async throws {
        let config = try #require(S.config(url: url, model: S.gemmaModel))
        var calls = 0
        let result = await S.unloadOnQuit(config, transport: { request in calls += 1; return Self.response(request, #"{}"#) })
        #expect(!result && calls == 0)
    }

    @Test func quitFailureIsNotReportedAsUnloaded() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        let result = await S.unloadOnQuit(config, transport: { request in Self.response(request, #"{}"#, status: 401) })
        #expect(!result)
    }

    @Test func quitWithUnresolvedJITDoesNotTreatEmptyInventoryAsConfirmedUnload() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        #expect(await S.unloadOnQuit(config, inferenceWasActive: true, transport: { request in
            Self.response(request, Self.installed)
        }) == false)
    }

    @Test(arguments: ["adequate", "small", "missing", "sibling", "ambiguous", "deadline", "cancelled"])
    func bufferedAnswerRequiresServingContextWithinOriginalDeadline(scenario: String) async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        var instant = ContinuousClock.now
        var active = true
        let result = await S.completeDetailed(config, isOllama: false, system: "facts", user: "fixture",
            contextTokens: 32768, stillValid: { active }, transport: { request in
                if request.httpMethod == "POST" {
                    return Self.response(request, #"{"model":"\#(S.gemmaModel)","choices":[{"message":{"content":"Buffered fixture answer"},"finish_reason":"stop"}]}"#)
                }
                if scenario == "deadline" { instant = instant.advanced(by: .seconds(91)) }
                if scenario == "cancelled" { active = false }
                let id = scenario == "sibling" ? "another_instance" : config.model
                let size = scenario == "small" ? 4096 : 32768
                let one = #"{"id":"\#(id)","config":{"context_length":\#(size),"parallel":1}}"#
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
        let config = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        var instant = ContinuousClock.now
        var wire: CheckedContinuation<(Data, URLResponse), Error>?
        var timers: [CheckedContinuation<Void, Error>] = []
        var settled = false
        let task = Task { @MainActor in
            let result = await S.completeDetailed(config, isOllama: false, system: "s", user: "u", timeout: 10,
                transport: { request in
                    if request.httpMethod == "POST" {
                        return Self.response(request, #"{"model":"\#(S.gemmaModel)","choices":[{"message":{"content":"fixture"},"finish_reason":"stop"}]}"#)
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
}
