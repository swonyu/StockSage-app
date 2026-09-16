import Testing
import Foundation
@testable import StockSage

// Pure-part tests for the local-server (Ollama / LM Studio) client behind the Catalysts tab's
// optional explanation paragraph (owner request 2026-09-06, build step: local-server backend).
// No live network calls: probe/completion checks use injected transports and synthetic inventory.
@Suite("Local model server (config + request + response)")
struct StockSageLocalModelServerTests {

    typealias S = StockSageLocalModelServer

    // Not private: reused by StockSageManagedModelLifecycleTests.swift and other managed-profile
    // tests (Qwen removal Step 4) so every Gemma inventory fixture in the test target shares one
    // definition instead of drifting.
    static func gemmaInventory(context: Int = 16_384) -> [String: Any] {
        ["models": [["type": "llm", "key": "google/gemma-4-31b-qat", "format": "gguf",
            "architecture": "gemma4", "params_string": "31B",
            "quantization": ["name": "Q4_0", "bits_per_weight": 4],
            "loaded_instances": [["id": "google/gemma-4-31b-qat",
                "config": ["context_length": context, "parallel": 1]]]]]]
    }

    @Test func gemmaManagedProfileRequiresItsCanonicalLocalIdentity() throws {
        #expect(S.gemmaModel == "google/gemma-4-31b-qat")
        for url in [S.lmStudioURL, "http://localhost:1234", "http://[::1]:1234"] {
            let config = try #require(S.config(url: url, model: S.gemmaModel))
            #expect(config.isLMStudioGemma && config.isManagedLMStudio && !config.isLMStudio9B)
        }
        for (url, model) in [("http://fixture.invalid:1234", S.gemmaModel),
                             ("http://127.0.0.1:11434", S.gemmaModel),
                             ("http://127.0.0.1:1234/proxy", S.gemmaModel),
                             (S.lmStudioURL, "stocksage-gemma4-31b-qat-benchmark"),
                             (S.lmStudioURL, "other-model")] {
            let config = try #require(S.config(url: url, model: model))
            #expect(!config.isLMStudioGemma && !config.isManagedLMStudio)
        }
        let qwen = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        #expect(qwen.isLMStudio9B && qwen.isManagedLMStudio && !qwen.isLMStudioGemma)
    }

    @Test(arguments: ["valid", "format", "architecture", "size", "quantization", "bits", "unloaded", "alias", "duplicate"])
    @MainActor func gemmaInventoryRequiresExactVariantAndUniqueCanonicalContext(scenario: String) async throws {
        var row = try #require((Self.gemmaInventory()["models"] as? [[String: Any]])?.first)
        switch scenario {
        case "format": row["format"] = "mlx"
        case "architecture": row["architecture"] = "qwen3_5"
        case "size": row["params_string"] = "4B"
        case "quantization": row["quantization"] = ["name": "Q4_K_M", "bits_per_weight": 4]
        case "bits": row["quantization"] = ["name": "Q4_0", "bits_per_weight": 6]
        case "unloaded": row["loaded_instances"] = [[String: Any]]()
        case "alias": row["loaded_instances"] = [["id": "benchmark-alias", "config": ["context_length": 16_384, "parallel": 1]]]
        case "duplicate":
            let instances = try #require(row["loaded_instances"] as? [[String: Any]])
            row["loaded_instances"] = instances + instances
        default: break
        }
        let inventory: [String: Any] = ["models": [row]]
        let probe = try #require(S.managedInventory(inventory, modelKey: S.gemmaModel))
        let compatible = !["format", "architecture", "size", "quantization", "bits"].contains(scenario)
        #expect(probe.hasModel == compatible && !probe.canDownload && !probe.isOllama)
        #expect(probe.researchParallelism == 1)
        #expect(S.verifiedContext(inventory, model: S.gemmaModel) == (scenario == "valid" ? 16_384 : nil))
        let config = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: inventory), as: UTF8.self)
        var calls = 0
        let observed = await S.probe(config, transport: { request in
            calls += 1
            #expect(request.httpMethod == "GET" && request.url?.path == "/api/v1/models")
            return StockSageModelDownloadTests.response(request, json)
        })
        #expect(calls == 1 && observed == probe)
    }

    @Test(arguments: ["valid", "missing-finish", "missing-model", "wrong-model", "short-context", "ambiguous-context"])
    @MainActor func gemmaCompletionRequiresConfirmedIdentityFinishAndServingContext(scenario: String) async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        var choice: [String: Any] = ["message": ["content": "Complete fixture"], "finish_reason": "stop"]
        if scenario == "missing-finish" { choice.removeValue(forKey: "finish_reason") }
        var reply: [String: Any] = ["model": config.model, "choices": [choice]]
        if scenario == "missing-model" { reply.removeValue(forKey: "model") }
        if scenario == "wrong-model" { reply["model"] = "other-model" }
        var inventory = Self.gemmaInventory(context: scenario == "short-context" ? 8192 : 16_384)
        if scenario == "ambiguous-context" {
            var rows = try #require(inventory["models"] as? [[String: Any]])
            let instances = try #require(rows[0]["loaded_instances"] as? [[String: Any]])
            rows[0]["loaded_instances"] = instances + instances
            inventory["models"] = rows
        }
        let replyJSON = String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
        let inventoryJSON = String(decoding: try JSONSerialization.data(withJSONObject: inventory), as: UTF8.self)
        var posts = 0
        let result = await S.completeDetailed(config, isOllama: false, system: "s", user: "u",
            maxTokens: 192, contextTokens: 16_384, transport: { request in
                if request.httpMethod == "GET" {
                    #expect(request.url?.path == "/api/v1/models")
                    return StockSageModelDownloadTests.response(request, inventoryJSON)
                }
                posts += 1
                return StockSageModelDownloadTests.response(request, replyJSON)
            })
        #expect(posts == 1)
        if scenario == "valid" {
            let completion = try result.get()
            #expect(completion.model == config.model && completion.text == "Complete fixture")
        } else if case .failure(let failure) = result {
            let expected: S.FailureCategory = scenario == "missing-finish" ? .incompleteOutput
                : scenario.contains("context") ? .contextBudget : .responseShape
            #expect(failure.diagnostic.category == expected)
        } else { Issue.record("Gemma accepted unverified completion: \(scenario)") }
    }

    @Test @MainActor func gemmaLengthRetryKeepsTheOriginalDeadline() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        let schema = Data(#"{ "type":"object", "properties":{"symbols":{"type":"array","items":{"type":"string"}}} }"#.utf8)
        var instant = ContinuousClock.now
        var outputs: [Int] = []
        let result = await S.completeDetailed(config, isOllama: false, system: "original system", user: "original facts",
            maxTokens: 192, contextTokens: 16_384, timeout: 90, jsonSchema: schema, transport: { request in
                #expect(request.httpMethod == "POST", "An overdue reply cannot trigger context verification")
                let body = try #require(request.httpBody)
                #expect(body.range(of: schema) != nil)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                outputs.append(try #require(json["max_tokens"] as? Int))
                #expect(json["messages"] as? [[String: String]] == [
                    ["role": "system", "content": "original system"], ["role": "user", "content": "original facts"]])
                instant = instant.advanced(by: .seconds(outputs.count == 1 ? 60 : 31))
                let finish = outputs.count == 1 ? "length" : "stop"
                return StockSageModelDownloadTests.response(request,
                    #"{"model":"\#(config.model)","choices":[{"message":{"content":"fixture"},"finish_reason":"\#(finish)"}]}"#)
            }, clock: { instant })
        #expect(outputs == [192, 384])
        if case .failure(let failure) = result {
            #expect(failure.diagnostic.category == .timeout && failure.diagnostic.outputLimitRetries == 1)
        } else { Issue.record("The Gemma retry renewed the original deadline") }
    }

    @Test @MainActor func attemptObserverKeepsBoundedUTF8PromptsAndExactReplyBytes() async throws {
        let config = try #require(S.config(url: "http://127.0.0.1:9876", model: "fixture"))
        let events = ModelAttemptRecorder()
        let system = "x" + String(repeating: "🚀", count: 6001)
        let user = String(repeating: "é", count: 12_001)
        let body = try JSONSerialization.data(withJSONObject: ["model": "fixture",
            "choices": [["message": ["content": String(repeating: "🚀", count: 7000)], "finish_reason": "stop"]]])
        let result = await S.completeDetailed(config, isOllama: false, system: system, user: user,
            contextTokens: 100_000, jsonSchema: Data(#"{"unused":"not-sent"}"#.utf8), phase: "assessment",
            attemptObserver: { await events.append($0) }, transport: { request in
                (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["X-Private-Fixture": "header-must-not-be-recorded"])!)
            })
        let values = await events.snapshot()
        try #require(values.count == 2)
        let start = values[0], finish = values[1]
        #expect(start.stage == .started && finish.stage == .finished)
        #expect(start.callID == finish.callID && start.ordinal == 1 && finish.ordinal == 1)
        #expect(!start.transportStarted && finish.transportStarted)
        #expect(start.phase == "assessment" && finish.phase == "assessment")
        let endedAt = try #require(finish.endedAt)
        #expect(start.endedAt == nil && endedAt >= start.startedAt)
        let completion = try result.get()
        #expect(start.diagnostic == nil && finish.diagnostic == completion.diagnostic)
        #expect(finish.requestedModel == "fixture" && finish.returnedModel == "fixture")
        #expect(finish.outputLimit == 170 && finish.contextTokens == 100_000 && finish.temperature == 0.2)
        #expect(finish.system == "x" + String(repeating: "🚀", count: 5999))
        #expect(finish.user == String(repeating: "é", count: 12_000))
        #expect(finish.systemBytes == system.utf8.count && finish.userBytes == user.utf8.count)
        #expect(finish.systemTruncated && finish.userTruncated)
        #expect(finish.schema == nil && finish.schemaBytes == nil && !finish.schemaTruncated)
        #expect(start.responseBody == nil && finish.responseBody == body.prefix(24_000))
        #expect(finish.responseBodyBytes == body.count && finish.responseBodyTruncated)
        #expect(finish.httpStatus == 200)
        let encoded = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode([S.ModelAttemptEvent].self, from: encoded)
        #expect(decoded == values)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("127.0.0.1") && !text.contains("/v1/chat/completions") && !text.contains("header-must-not-be-recorded"))
        #expect(!text.contains("not-sent"))
    }

    @Test(arguments: ["qwen3.5-9b", "google/gemma-4-31b-qat"])
    @MainActor func attemptObserverSeparatesLengthRetryAndKeepsTheAppliedSchema(model: String) async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: model))
        let events = ModelAttemptRecorder()
        let schema = Data(#"{"type":"object","properties":{"action":{"type":"string"}}}"#.utf8)
        let inventory = model == S.gemmaModel
            ? String(decoding: try JSONSerialization.data(withJSONObject: Self.gemmaInventory()), as: UTF8.self)
            : StockSageModelDownloadTests.installed.replacingOccurrences(of: "\"loaded_instances\":[]",
                with: #""loaded_instances":[{"id":"qwen3.5-9b","config":{"context_length":16384}}]"#)
        var posts = 0
        let result = await S.completeDetailed(config, isOllama: false, system: "original system", user: "original facts",
            maxTokens: 192, contextTokens: 16_384, jsonSchema: schema, phase: "ranking",
            attemptObserver: { await events.append($0) }, transport: { request in
                if request.httpMethod == "GET" { return StockSageModelDownloadTests.response(request, inventory) }
                posts += 1
                #expect(request.httpBody?.range(of: schema) != nil, "Both initial and length-retry requests preserve the supplied schema")
                let finish = posts == 1 ? "length" : "stop"
                return StockSageModelDownloadTests.response(request,
                    #"{"model":"\#(model)","choices":[{"message":{"content":"fixture"},"finish_reason":"\#(finish)"}],"usage":{"prompt_tokens":42,"completion_tokens":12}}"#)
            })
        let values = await events.snapshot()
        try #require(values.count == 4)
        #expect(posts == 2 && values.map(\.stage) == [.started, .finished, .started, .finished])
        #expect(values.map(\.ordinal) == [1, 1, 2, 2] && Set(values.map(\.callID)).count == 2)
        #expect(values[0].callID == values[1].callID && values[2].callID == values[3].callID)
        #expect(values.map(\.outputLimit) == [192, 192, 384, 384])
        #expect(values.allSatisfy { $0.system == "original system" && $0.user == "original facts" && $0.phase == "ranking" })
        let recordedSchema = try #require(values[0].schema)
        let canonical = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: schema), options: [.sortedKeys])
        #expect(Data(recordedSchema.utf8) == canonical && values[0].schemaBytes == canonical.count)
        #expect(!values[0].schemaTruncated)
        #expect(values[1].diagnostic?.finish == .tokenLimit && values[1].diagnostic?.outputLimitRetries == 0)
        #expect(values[3].diagnostic?.finish == .stop && values[3].diagnostic?.outputLimitRetries == 1)
        let completion = try result.get()
        #expect(values[3].diagnostic == completion.diagnostic)
    }

    @Test(arguments: ["http", "malformed", "nonUTF8", "model", "context", "finish", "revoked", "nonHTTP", "oversized"])
    @MainActor func attemptObserverRetainsRejectedReplyWithoutChangingAcceptance(scenario: String) async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        let events = ModelAttemptRecorder()
        let normal = Data(#"{"model":"\#(S.gemmaModel)","choices":[{"message":{"content":"fixture"},"finish_reason":"stop"}]}"#.utf8)
        let data: Data
        let category: S.FailureCategory
        switch scenario {
        case "http": data = Data(#"{"error":"rejected fixture"}"#.utf8); category = .http
        case "malformed": data = Data("unfinished {".utf8); category = .malformedJSON
        case "nonUTF8": data = Data([0xFF, 0xFE, 0x81, 0x00]); category = .malformedJSON
        case "model": data = Data(String(decoding: normal, as: UTF8.self).replacingOccurrences(of: S.gemmaModel, with: "other-model").utf8); category = .responseShape
        case "context": data = normal; category = .contextBudget
        case "finish": data = Data(String(decoding: normal, as: UTF8.self).replacingOccurrences(of: "\"stop\"", with: "\"tool_calls\"").utf8); category = .incompleteOutput
        case "revoked": data = normal; category = .obsoleteRequest
        case "nonHTTP": data = normal; category = .nonHTTP
        default: data = Data(repeating: 0xFF, count: S.maximumResponseBytes + 1); category = .responseTooLarge
        }
        var valid = true
        var posts = 0
        let result = await S.completeDetailed(config, isOllama: false, system: "s", user: "u",
            attemptObserver: { await events.append($0) }, stillValid: { valid }, transport: { request in
                if request.httpMethod == "GET" { return StockSageModelDownloadTests.response(request, #"{"models":[]}"#) }
                posts += 1
                if scenario == "revoked" { valid = false }
                if scenario == "nonHTTP" { return (data, URLResponse(url: request.url!, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil)) }
                return (data, HTTPURLResponse(url: request.url!, statusCode: scenario == "http" ? 400 : 200, httpVersion: nil, headerFields: nil)!)
            })
        let values = await events.snapshot()
        try #require(values.count == 2)
        let finish = values[1]
        #expect(posts == 1 && finish.stage == .finished && finish.transportStarted)
        #expect(finish.responseBody == data.prefix(24_000) && finish.responseBodyBytes == data.count)
        #expect(finish.responseBodyTruncated == (data.count > 24_000))
        #expect(finish.httpStatus == (scenario == "nonHTTP" ? nil : scenario == "http" ? 400 : 200))
        if case .failure(let failure) = result {
            #expect(failure.diagnostic.category == category && finish.diagnostic == failure.diagnostic)
        } else { Issue.record("Diagnostic recording changed rejection into success") }
        if scenario == "model" { #expect(finish.returnedModel == "other-model") }
    }

    @Test(arguments: ["budget", "obsolete", "policy", "timeout"])
    @MainActor func attemptObserverDoesNotInventPostsForPreflightRejection(scenario: String) async throws {
        let config = try #require(S.config(url: scenario == "policy" ? "http://fixture.invalid:1234" : "http://127.0.0.1:8765", model: "fixture"))
        let events = ModelAttemptRecorder()
        var calls = 0
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: scenario == "budget" ? String(repeating: "x", count: 5000) : "u",
            timeout: scenario == "timeout" ? 0 : 90, attemptObserver: { await events.append($0) },
            stillValid: { scenario != "obsolete" }, externalAllowed: { scenario != "policy" }, transport: { request in
                calls += 1
                return StockSageModelDownloadTests.response(request, #"{"message":{"content":"fixture"}}"#)
            })
        let values = await events.snapshot()
        #expect(values.isEmpty && calls == 0 && (try? result.get()) == nil)
    }

    @Test(arguments: ["cancelled", "deadline", "obsolete"])
    @MainActor func suspendedAttemptReceiptCannotDispatchAfterRevocation(scenario: String) async throws {
        let config = try #require(S.config(url: "http://127.0.0.1:8765", model: "fixture"))
        let gate = ModelAttemptGate()
        var instant = ContinuousClock.now
        var valid = true
        var posts = 0
        var settled = false
        let task = Task { @MainActor in
            let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "u", timeout: 10,
                attemptObserver: { await gate.observe($0) }, stillValid: { valid }, transport: { request in
                    posts += 1
                    return StockSageModelDownloadTests.response(request, #"{"message":{"content":"fixture"}}"#)
                }, clock: { instant })
            settled = true
            return result
        }
        var entered = false
        for _ in 0..<2000 {
            entered = await gate.isWaiting
            if entered || settled { break }
            await Task.yield()
        }
        guard entered else {
            task.cancel()
            await gate.release()
            _ = await task.value
            Issue.record("No dispatch-preparation receipt was observed")
            return
        }
        #expect(posts == 0 && !settled)
        if scenario == "cancelled" { task.cancel() }
        if scenario == "deadline" { instant = instant.advanced(by: .seconds(10)) }
        if scenario == "obsolete" { valid = false }
        await gate.release()
        let result = await task.value
        let values = await gate.snapshot()
        try #require(values.count == 2)
        #expect(posts == 0 && !values[1].transportStarted && values[1].responseBody == nil)
        let expected: S.FailureCategory = scenario == "cancelled" ? .cancelled : scenario == "deadline" ? .timeout : .obsoleteRequest
        if case .failure(let failure) = result {
            #expect(failure.diagnostic.category == expected && values[1].diagnostic == failure.diagnostic)
        } else { Issue.record("A suspended receipt bypassed the existing request guards") }
    }

    @Test(arguments: ["cancelled", "deadline", "obsolete"])
    @MainActor func terminalReceiptCannotPublishAnAcceptedReplyAfterRevocation(scenario: String) async throws {
        let config = try #require(S.config(url: "http://127.0.0.1:8765", model: "fixture"))
        let gate = ModelAttemptGate(stage: .finished)
        var instant = ContinuousClock.now
        var valid = true
        var posts = 0
        var settled = false
        let task = Task { @MainActor in
            let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "u", timeout: 10,
                attemptObserver: { await gate.observe($0) }, stillValid: { valid }, transport: { request in
                    posts += 1
                    return StockSageModelDownloadTests.response(request, #"{"model":"fixture","message":{"content":"fixture"}}"#)
                }, clock: { instant })
            settled = true
            return result
        }
        var entered = false
        for _ in 0..<2000 {
            entered = await gate.isWaiting
            if entered || settled { break }
            await Task.yield()
        }
        guard entered else {
            task.cancel()
            await gate.release()
            _ = await task.value
            Issue.record("No terminal receipt was observed")
            return
        }
        #expect(posts == 1 && !settled)
        if scenario == "cancelled" { task.cancel() }
        if scenario == "deadline" { instant = instant.advanced(by: .seconds(10)) }
        if scenario == "obsolete" { valid = false }
        await gate.release()
        let result = await task.value
        let values = await gate.snapshot()
        try #require(values.count == 2)
        #expect(values[1].transportStarted && values[1].responseBody != nil)
        #expect(values[1].diagnostic?.category == nil, "The immutable POST receipt precedes publication revocation")
        let expected: S.FailureCategory = scenario == "cancelled" ? .cancelled : scenario == "deadline" ? .timeout : .obsoleteRequest
        if case .failure(let failure) = result { #expect(failure.diagnostic.category == expected) }
        else { Issue.record("A reply was published after its final receipt suspended past revocation") }
    }

    @Test @MainActor func overdueReplyBytesRemainAvailableInTheSingleTimeoutReceipt() async throws {
        let config = try #require(S.config(url: "http://127.0.0.1:8765", model: "fixture"))
        let events = ModelAttemptRecorder()
        let body = Data(#"{"model":"fixture","message":{"content":"overdue"}}"#.utf8)
        var instant = ContinuousClock.now
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "u", timeout: 10,
            attemptObserver: { await events.append($0) }, transport: { request in
                instant = instant.advanced(by: .seconds(10))
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, clock: { instant })
        let values = await events.snapshot()
        try #require(values.count == 2)
        #expect(values[1].transportStarted && values[1].responseBody == body && values[1].httpStatus == 200)
        #expect(values[1].returnedModel == "fixture" && values[1].diagnostic?.category == .timeout)
        if case .failure(let failure) = result { #expect(failure.diagnostic.category == .timeout) }
        else { Issue.record("The overdue body must remain rejected") }
    }

    @Test(arguments: ["1", "2", "4", "8", "9", "64", "2.0", "0", "-1", "2.5", "true", "false", "\"8\"", "null", "1e300"])
    @MainActor func researchCapacityUsesOnlySafeIntegralSelectedInstanceMetadata(parallel: String) async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        let json = StockSageModelDownloadTests.installed.replacingOccurrences(of: "\"loaded_instances\":[]",
            with: #""loaded_instances":[{"id":"qwen3.5-9b","config":{"context_length":262144,"parallel":\#(parallel)}}]"#)
        var requests = 0
        let probe = await S.probe(config, transport: { request in
            requests += 1
            #expect(request.httpMethod == "GET" && request.url?.path == "/api/v1/models")
            return StockSageModelDownloadTests.response(request, json)
        })
        let expected = ["1": 1, "2": 2, "4": 4, "8": 8, "9": 8, "64": 8, "2.0": 2][parallel] ?? 1
        #expect(probe.researchParallelism == expected)
        #expect(requests == 1 && probe.reachable && probe.hasModel && !probe.canDownload && !probe.isOllama)
    }

    @Test(arguments: ["missing", "unloaded", "sibling", "duplicate", "malformed", "incompatible", "mixed-variant", "compatible-copies"])
    @MainActor func researchCapacityKeepsAmbiguousOrIncompatibleInstancesSerial(scenario: String) async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        let inventory = try #require(JSONSerialization.jsonObject(with: Data(StockSageModelDownloadTests.installed.utf8)) as? [String: Any])
        let empty = try #require((inventory["models"] as? [[String: Any]])?.first)
        var selected = empty
        let instance: [String: Any] = ["id": config.model, "config": ["context_length": 262144, "parallel": 8]]
        selected["loaded_instances"] = [instance]
        switch scenario {
        case "missing": selected["loaded_instances"] = [["id": config.model, "config": ["context_length": 262144]]]
        case "unloaded": selected["loaded_instances"] = [[String: Any]]()
        case "sibling": selected["loaded_instances"] = [["id": "another-instance", "config": ["context_length": 262144, "parallel": 8]]]
        case "duplicate": selected["loaded_instances"] = [instance, instance]
        case "malformed": selected["loaded_instances"] = "unverified"
        case "incompatible": selected["quantization"] = ["bits_per_weight": 4]
        default: break
        }
        var rows = [selected]
        if scenario == "mixed-variant" {
            var wrongVariant = empty
            wrongVariant["quantization"] = ["bits_per_weight": 4]
            rows.append(wrongVariant)
        } else if scenario == "compatible-copies" { rows.insert(empty, at: 0) }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["models": rows]), as: UTF8.self)
        let probe = await S.probe(config, transport: { request in
            #expect(request.httpMethod == "GET" && request.url?.path == "/api/v1/models")
            return StockSageModelDownloadTests.response(request, json)
        })
        #expect(probe.researchParallelism == (scenario == "compatible-copies" ? 8 : 1))
        #expect(probe.hasModel == !["incompatible", "mixed-variant"].contains(scenario))
    }

    @Test @MainActor func researchCapacityCannotEscapeProbeIdentityOrAccessChecks() async throws {
        let native = StockSageModelDownloadTests.installed.replacingOccurrences(of: "\"loaded_instances\":[]",
            with: #""loaded_instances":[{"id":"qwen3.5-9b","config":{"context_length":262144,"parallel":8}}]"#)
        let strict = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        var valid = true
        let revoked = await S.probe(strict, stillValid: { valid }, transport: { request in
            valid = false
            return StockSageModelDownloadTests.response(request, native)
        })
        #expect(!revoked.hasModel && revoked.researchParallelism == 1)
        for config in [S.config(url: S.lmStudioURL, model: "another-model")!,
                       S.config(url: "http://127.0.0.1:11434", model: S.lmStudioModel)!] {
            let other = await S.probe(config, transport: { request in
                #expect(request.url?.path == "/api/tags")
                return StockSageModelDownloadTests.response(request, #"{"models":[{"name":"\#(config.model)","parallel":8}]}"#)
            })
            #expect(other.isOllama && other.hasModel && other.researchParallelism == 1)
        }
        let remote = try #require(S.config(url: "http://fixture.invalid:1234", model: S.lmStudioModel))
        var remoteRequests = 0
        let denied = await S.probe(remote, externalAllowed: { false }, transport: { request in
            remoteRequests += 1
            return StockSageModelDownloadTests.response(request, native)
        })
        #expect(remoteRequests == 0 && !denied.reachable && denied.researchParallelism == 1)
    }

    @Test(arguments: [false, true]) @MainActor
    func totalDeadlineAndCancellationSettleBeforeAnUncooperativeTransport(cancel: Bool) async throws {
        let config = try #require(S.config(url: "http://127.0.0.1:8765", model: "fixture"))
        let events = ModelAttemptRecorder()
        var instant = ContinuousClock.now
        var wire: CheckedContinuation<(Data, URLResponse), Error>?
        var timer: CheckedContinuation<Void, Error>?
        var settled = false
        let task = Task { @MainActor in
            let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "u", timeout: 10,
                attemptObserver: { await events.append($0) },
                transport: { _ in try await withCheckedThrowingContinuation { wire = $0 } },
                clock: { instant }, sleepUntil: { _ in try await withCheckedThrowingContinuation { timer = $0 } })
            settled = true
            return result
        }
        defer {
            task.cancel()
            wire?.resume(throwing: CancellationError()); wire = nil
            timer?.resume(throwing: CancellationError()); timer = nil
        }
        for _ in 0..<2000 where wire == nil || timer == nil { await Task.yield() }
        try #require(wire != nil && timer != nil)
        if cancel { task.cancel() }
        else { instant = instant.advanced(by: .seconds(10)); timer?.resume(); timer = nil }
        for _ in 0..<2000 where !settled { await Task.yield() }
        try #require(settled, "Caller must finish without releasing the transport")
        let result = await task.value
        if case .failure(let failure) = result {
            #expect(failure.diagnostic.category == (cancel ? .cancelled : .timeout))
        } else { Issue.record("Expected a deadline/cancellation failure") }
        #expect(wire != nil)
        let values = await events.snapshot()
        try #require(values.count == 2)
        #expect(values[0].stage == .started && values[1].stage == .finished)
        #expect(values[0].callID == values[1].callID && values[1].transportStarted)
        #expect(values[1].diagnostic?.category == (cancel ? .cancelled : .timeout))
        #expect(values[1].responseBody == nil)
        wire?.resume(returning: (Data(#"{"message":{"content":"late reply"}}"#.utf8),
            HTTPURLResponse(url: config.baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)); wire = nil
        for _ in 0..<100 { await Task.yield() }
        let afterLateReply = await events.snapshot()
        #expect(afterLateReply == values, "Late bytes cannot overwrite a recorded timeout or create another terminal event")
    }

    @Test(arguments: [false, true]) @MainActor func resultAfterDeadlineCannotBeatADelayedTimer(throwsError: Bool) async throws {
        let start = ContinuousClock.now
        var instant = start
        let pending = S.Pending<Int>()
        let result: Result<Int, Error>
        do {
            result = .success(try await pending.run(deadline: start.advanced(by: .seconds(1)), now: { instant }) {
                instant = start.advanced(by: .seconds(1))
                if throwsError { throw URLError(.cannotConnectToHost) }
                return 7
            })
        } catch { result = .failure(error) }
        if case .failure(let error) = result { #expect((error as? URLError)?.code == .timedOut) }
        else { Issue.record("An overdue result was accepted") }
    }

    @Test @MainActor func lmStudioProfileBoundsTheEntirePromptBeforeDispatch() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        // Output and both messages must fit together, including non-thinking chat framing.
        for (system, user, output) in [(String(repeating: "a", count: 2000), String(repeating: "b", count: 2000), 170),
                                      ("instructions", String(repeating: "ش", count: 2000), 170),
                                      ("instructions", "facts", 4096)] {
            var calls = 0
            let result = await S.completeDetailed(config, isOllama: false, system: system, user: user,
                maxTokens: output, transport: { request in
                    calls += 1
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
            #expect(calls == 0)
            #expect((try? result.get()) == nil)
        }
    }

    @Test @MainActor func lmStudioProfileDoesNotAcceptTruncatedOrUnconfirmedFinish() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        for finish in ["length", "tool_calls", "unknown", ""] {
            let result = await S.completeDetailed(config, isOllama: false, system: "instructions", user: "facts", transport: { request in
                let data = try JSONSerialization.data(withJSONObject: ["model": config.model,
                    "choices": [["message": ["content": "A complete-looking sentence."], "finish_reason": finish]]])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            if case .success = result { Issue.record("New profile accepted unfinished content: \(finish)") }
        }
    }

    @Test func lmStudioStableProfileRequestsIdleUnloadWithoutOllamaOptions() throws {
        let config = try #require(S.config(url: "http://127.0.0.1:1234", model: "qwen3.5-9b"))
        let req = S.chatRequest(config, system: "instructions", user: "facts", isOllama: false, maxTokens: 16)
        let data = try #require(req.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(req.url?.absoluteString == "http://127.0.0.1:1234/v1/chat/completions")
        #expect(body["model"] as? String == "qwen3.5-9b")
        #expect(body["ttl"] as? Int == 180)
        #expect(body["think"] == nil && body["options"] == nil)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test @MainActor func lmStudioProfileRejectsAnAnswerFromAnotherModel() async throws {
        let config = try #require(S.config(url: "http://127.0.0.1:1234", model: "qwen3.5-9b"))
        let result = await S.completeDetailed(config, isOllama: false, system: "facts only", user: "fixture", transport: { request in
            let data = Data(#"{"model":"different-model","choices":[{"message":{"content":"positive"},"finish_reason":"stop"}]}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        if case .success = result { Issue.record("Wrong model response was accepted under the configured 9B identity") }
    }

    @Test @MainActor func responseReaderCapsActualBytesNotJustContentLength() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelBodyProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for path in ["small", "chunked", "understated", "declared"] {
            let request = URLRequest(url: URL(string: "https://fixture.invalid/\(path)")!)
            do {
                let (data, _) = try await StockSageHTTP.data(for: request, session: session, maximumBytes: 1024)
                #expect(path == "small" && data.count == 512, "Oversized body accepted: \(path)")
            } catch {
                #expect(path != "small")
                #expect((error as? URLError)?.code == .dataLengthExceedsMaximum)
            }
        }
    }

    @Test func sharedConfigRejectsCredentialBearingURLs() {
        for url in ["http://owner:fixture@127.0.0.1:8765", "http://127.0.0.1:8765?key=fixture",
                    "http://127.0.0.1:8765#fixture"] {
            #expect(S.config(url: url, model: "fixture") == nil)
        }
    }

    @Test @MainActor func redirectsCannotForwardModelFactsToAnotherEndpoint() throws {
        let session = URLSession(configuration: .ephemeral)
        let url = URL(string: "http://127.0.0.1:8765/v1/chat/completions")!
        let task = session.dataTask(with: url) // Never resumed; no network request.
        defer { task.cancel(); session.invalidateAndCancel() }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil))
        var called = false
        S.NoRedirect().urlSession(session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://example.com/collect")!)) { request in
                called = true
                #expect(request == nil)
            }
        #expect(called)
    }

    // MARK: config(url:model:)

    @Test("a trailing slash is stripped from the base URL; the model is kept as-is")
    func configStripsTrailingSlash() {
        let c = S.config(url: "http://127.0.0.1:11434/", model: "qwen3.8")
        #expect(c?.baseURL.absoluteString == "http://127.0.0.1:11434")
        #expect(c?.model == "qwen3.8")
    }

    @Test("a non-http(s) scheme is rejected")
    func configRejectsNonHTTPScheme() {
        #expect(S.config(url: "ftp://x", model: "m") == nil)
    }

    @Test("an empty model is rejected even with a valid URL")
    func configRejectsEmptyModel() {
        #expect(S.config(url: "http://127.0.0.1:11434", model: "") == nil)
        #expect(S.config(url: "http://127.0.0.1:11434", model: "   ") == nil)
    }

    // MARK: isLoopback (n=4)

    @Test("isLoopback is true for 127.0.0.1, localhost, [::1]; false for a LAN address")
    func isLoopbackClassifiesFourHosts() {
        #expect(S.isLoopback(URL(string: "http://127.0.0.1:11434")!))
        #expect(S.isLoopback(URL(string: "http://localhost:11434")!))
        #expect(S.isLoopback(URL(string: "http://[::1]:11434")!))
        #expect(!S.isLoopback(URL(string: "http://192.168.1.20:11434")!))
    }

    // MARK: chatRequest — Ollama

    @Test("chatRequest (Ollama) posts to /api/chat with think:false and the 4k context window")
    func chatRequestOllamaShape() throws {
        let c = S.config(url: "http://127.0.0.1:11434", model: "qwen3.8")!
        let req = S.chatRequest(c, system: "SYS", user: "USR", isOllama: true, maxTokens: 170)
        #expect(req.url?.path == "/api/chat")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(req.timeoutInterval == 90)

        let body = try #require(req.httpBody)
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(obj["model"] as? String == "qwen3.8")
        #expect(obj["stream"] as? Bool == false)
        #expect(obj["think"] as? Bool == false)
        let options = try #require(obj["options"] as? [String: Any])
        #expect(options["num_predict"] as? Int == 170)
        #expect(options["temperature"] as? Double == 0.2)
        #expect(options["num_ctx"] as? Int == 4096)
        let messages = try #require(obj["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"] == "SYS")
        #expect(messages[1]["role"] == "user")
        #expect(messages[1]["content"] == "USR")
    }

    // MARK: chatRequest — OpenAI-compatible

    @Test(arguments: ["qwen3.5-9b", "google/gemma-4-31b-qat"])
    func chatRequestPreservesSuppliedSchemaBytesAndEscaping(model: String) throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: model))
        let schema = Data(#"""
        { "type":"object", "properties":{
            "zeta":{"type":"string","description":"quote: \"; slash: \\; café 🚀"},
            "alpha":{"type":"array","items":{"enum":["F2","F1"]}}
        }, "required":["zeta","alpha"], "additionalProperties":false }
        """#.utf8)
        let system = "Keep \"quotes\", \\slashes and Unicode 🚀 unchanged."
        let user = "Fact text containing } and \"schema\": is data.\nNext fact."
        let request = S.chatRequest(config, system: system, user: user, isOllama: false,
            maxTokens: 192, jsonSchema: schema)
        let body = try #require(request.httpBody)
        #expect(body.range(of: schema) != nil, "Serialization must not reorder or rewrite the supplied schema")
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        if model == S.gemmaModel { #expect(object["reasoning_effort"] as? String == "none") }
        else { #expect(object["reasoning_effort"] == nil) }
        #expect(object["model"] as? String == model && object["temperature"] as? Double == 0.2)
        let messages = try #require(object["messages"] as? [[String: String]])
        #expect(messages == [["role":"system", "content":system], ["role":"user", "content":user]])
        let format = try #require(object["response_format"] as? [String: Any])
        let definition = try #require(format["json_schema"] as? [String: Any])
        #expect(definition["strict"] as? Bool == true && definition["name"] as? String == "assessment")
        #expect(try JSONSerialization.data(withJSONObject: definition["schema"] as Any, options: .sortedKeys)
            == JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: schema), options: .sortedKeys))
    }

    @Test func schemaEmbeddingNormalizesEncodingAndKeepsBackendGates() throws {
        let managed = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        let other = try #require(S.config(url: "http://127.0.0.1:1234", model: "other-model"))
        let text = #"{"type":"object","properties":{"symbols":{"type":"array","items":{"type":"string"}}}}"#
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        let encodings: [String.Encoding] = [.utf16, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian]
        let wide = try encodings.map { try #require(text.data(using: $0)) }
        for schema in [Data(text.utf8), bom] + wide {
            let request = S.chatRequest(managed, system: "s", user: "u", isOllama: false, maxTokens: 192, jsonSchema: schema)
            let body = try #require(request.httpBody)
            let parsed = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let format = try #require(parsed["response_format"] as? [String: Any])
            let definition = try #require(format["json_schema"] as? [String: Any])
            #expect(try JSONSerialization.data(withJSONObject: definition["schema"] as Any, options: .sortedKeys)
                == JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: Data(text.utf8)), options: .sortedKeys))
        }
        for (config, ollama, schema) in [(managed, true, Data(text.utf8)),
                                        (other, false, Data(text.utf8)),
                                        (managed, false, Data(#"{},"model":"unexpected""#.utf8))] {
            let request = S.chatRequest(config, system: "s", user: "u", isOllama: ollama, maxTokens: 192, jsonSchema: schema)
            let body = try #require(request.httpBody)
            let parsed = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(parsed["response_format"] == nil && parsed["model"] as? String == config.model)
        }
    }

    @Test("chatRequest (OpenAI-compatible) posts to /v1/chat/completions with max_tokens, no think key")
    func chatRequestOpenAIShape() throws {
        let c = S.config(url: "http://127.0.0.1:1234", model: "local-model")!
        let req = S.chatRequest(c, system: "SYS", user: "USR", isOllama: false, maxTokens: 170)
        #expect(req.url?.path == "/v1/chat/completions")

        let body = try #require(req.httpBody)
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(obj["max_tokens"] as? Int == 170)
        #expect(obj["think"] == nil)
        let messages = try #require(obj["messages"] as? [[String: String]])
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"] == "SYS")
        #expect(messages[1]["role"] == "user")
        #expect(messages[1]["content"] == "USR")
    }

    // MARK: parseChatResponse

    @Test("Conversational Chat sends its own context, output and timeout budgets")
    func conversationalChatBudgets() throws {
        let c = S.config(url: "http://127.0.0.1:8765", model: "qwen")!
        for ollama in [true, false] {
            let request = S.chatRequest(c, system: StockSageChat.instructions, user: "history",
                isOllama: ollama, maxTokens: StockSageChat.outputTokens,
                contextTokens: StockSageChat.contextTokens, timeout: StockSageChat.requestTimeout)
            #expect(request.timeoutInterval == 300)
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["response_format"] == nil, "Free-form Chat must not receive an assessment schema")
            if ollama {
                let options = try #require(json["options"] as? [String: Any])
                // Assert the caller's value is FORWARDED VERBATIM rather than matching a literal:
                // that is the property that matters, and the literal rotted when Chat's context
                // was raised on 2026-09-11. On Ollama this becomes the server's real window, so a
                // caller asking for more than it sends would be silently truncated server-side.
                #expect(options["num_ctx"] as? Int == StockSageChat.contextTokens
                        && options["num_predict"] as? Int == StockSageChat.outputTokens)
            } else {
                #expect(json["max_tokens"] as? Int == 512 && json["options"] == nil)
            }
        }
    }

    @Test("parseChatResponse reads Ollama's message.content, trimmed")
    func parseChatResponseOllama() {
        let data = Data(#"{"message":{"role":"assistant","content":" hi "}}"#.utf8)
        #expect(S.parseChatResponse(data, isOllama: true) == "hi")
    }

    @Test("parseChatResponse reads OpenAI's choices[0].message.content")
    func parseChatResponseOpenAI() {
        let data = Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)
        #expect(S.parseChatResponse(data, isOllama: false) == "ok")
    }

    @Test("parseChatResponse returns nil for garbage or empty content")
    func parseChatResponseRejectsGarbageAndEmpty() {
        #expect(S.parseChatResponse(Data("not json".utf8), isOllama: true) == nil)
        #expect(S.parseChatResponse(Data(#"{"message":{"content":""}}"#.utf8), isOllama: true) == nil)
        #expect(S.parseChatResponse(Data(#"{"message":{"content":"   "}}"#.utf8), isOllama: true) == nil)
        #expect(S.parseChatResponse(Data(#"{"choices":[]}"#.utf8), isOllama: false) == nil)
    }
}

private actor ModelAttemptRecorder {
    private var values: [StockSageLocalModelServer.ModelAttemptEvent] = []
    func append(_ value: StockSageLocalModelServer.ModelAttemptEvent) { values.append(value) }
    func snapshot() -> [StockSageLocalModelServer.ModelAttemptEvent] { values }
}

private actor ModelAttemptGate {
    private let stage: StockSageLocalModelServer.ModelAttemptEvent.Stage
    private var values: [StockSageLocalModelServer.ModelAttemptEvent] = []
    private var continuation: CheckedContinuation<Void, Never>?
    init(stage: StockSageLocalModelServer.ModelAttemptEvent.Stage = .started) { self.stage = stage }
    var isWaiting: Bool { continuation != nil }
    func observe(_ event: StockSageLocalModelServer.ModelAttemptEvent) async {
        values.append(event)
        if event.stage == stage { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
    func snapshot() -> [StockSageLocalModelServer.ModelAttemptEvent] { values }
}

/// URLProtocol provides actual URLSession bytes without network, credentials or a server.
private nonisolated final class ModelBodyProtocol: URLProtocol, @unchecked Sendable {
    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func startLoading() {
        let url = request.url!
        let path = url.lastPathComponent
        let headers = path == "declared" ? ["Content-Length": "2048"]
            : path == "understated" ? ["Content-Length": "512"] : [:]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for _ in 0..<(path == "small" ? 1 : 4) { client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 512)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    nonisolated override func stopLoading() {}
}
