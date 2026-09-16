import Foundation
import Testing
@testable import StockSage

@Suite(.serialized) @MainActor struct StockSageRunPodGemmaTests {
    typealias S = StockSageLocalModelServer
    private var config: S.Config { S.config(url: S.runPodURL, model: S.gemmaModel)! }
    private func response(_ request: URLRequest, _ object: [String: Any], status: Int = 200) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: object),
         HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    private func properties(context: Any = 16384, slots: Any = 4) -> [String: Any] {
        ["default_generation_settings": ["n_ctx": context], "total_slots": slots, "is_sleeping": false]
    }
    private var inventory: [String: Any] { ["data": [["id": S.gemmaModel]]] }

    @Test func exactTunnelProfileKeepsGemmaSchemaAndLocalLifecycleSeparate() async throws {
        #expect(config.isRunPodGemma && config.requiresExternalAccess && config.requiresStrictOutput)
        #expect(!config.isManagedLMStudio && !config.isLMStudioGemma)
        #expect(config.isRunPodEndpoint && !config.supportsLocalUnload)
        // Literal, not S.defaultURL: this is the only assertion that 11434 is in
        // supportsLocalUnload's allow-list. Once Qwen removal Step 7 flips defaultURL to
        // lmStudioURL, using the constant here would silently test the same URL twice.
        for url in [S.lmStudioURL, "http://127.0.0.1:11434"] {
            #expect(S.config(url: url, model: S.gemmaModel)?.supportsLocalUnload == true)
        }
        for url in ["http://example.com:1234", S.lmStudioURL + "/v1", S.runPodURL] {
            #expect(S.config(url: url, model: S.gemmaModel)?.supportsLocalUnload == false)
        }
        for (url, model) in [(S.runPodURL, "stocksage-gemma4-31b-qat-benchmark"),
                             (S.lmStudioURL, S.gemmaModel), (S.runPodURL + "/v1", S.gemmaModel),
                             ("https://127.0.0.1:18080", S.gemmaModel), ("http://example.com:18080", S.gemmaModel)] {
            #expect(S.config(url: url, model: model)?.isRunPodGemma == false)
        }
        let schema = try #require(StockSageAIAssessment.responseSchema(facts: ["Retained fact."]))
        let request = S.chatRequest(config, system: "instructions", user: "F1: Retained fact.",
            isOllama: false, maxTokens: 192, jsonSchema: schema)
        let bytes = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(request.url?.absoluteString == S.runPodURL + "/v1/chat/completions")
        #expect(body["model"] as? String == S.gemmaModel && body["reasoning_effort"] as? String == "none")
        #expect(body["ttl"] == nil && body["options"] == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(bytes.range(of: schema) != nil, "The native ordered schema must be embedded unchanged")
        var unloadCalls = 0
        let unloaded = await S.unloadOnQuit(config, transport: { request in
            unloadCalls += 1; return try response(request, [:])
        })
        #expect(!unloaded && unloadCalls == 0, "Quitting never calls LM Studio or remote model lifecycle endpoints")
    }

    @Test(arguments: [1, 2, 4, 8])
    func readinessUsesOnlyRemoteModelAndActualSlotProperties(slots: Int) async throws {
        var paths: [String] = []
        let probe = await S.probe(config, externalAllowed: { true }, transport: { request in
            #expect(request.url?.port == 18080 && request.httpMethod == "GET")
            paths.append(request.url!.path)
            return try response(request, request.url?.path == "/v1/models" ? inventory : properties(slots: slots))
        })
        #expect(paths == ["/v1/models", "/props"])
        #expect(probe.reachable && probe.hasModel && !probe.isOllama && !probe.canDownload)
        #expect(probe.servingContext == 16384 && probe.researchParallelism == slots)
    }

    @Test func unknownCapacityStaysSerialAndUnverifiedContextNeverBecomesReady() async throws {
        for slots in [NSNull(), true, 0, 3, 16, 2.5, "4"] as [Any] {
            let probe = await S.probe(config, externalAllowed: { true }, transport: { request in
                try response(request, request.url?.path == "/v1/models" ? inventory : properties(slots: slots))
            })
            #expect(probe.hasModel && probe.servingContext == 16384 && probe.researchParallelism == 1)
        }
        for context in [NSNull(), true, 8192, 16384.5, -1] as [Any] {
            let probe = await S.probe(config, externalAllowed: { true }, transport: { request in
                try response(request, request.url?.path == "/v1/models" ? inventory : properties(context: context))
            })
            #expect(!probe.hasModel && probe.servingContext == nil && probe.researchParallelism == 1)
        }
        for inventory in [["data": [["id": "other"]]], ["data": [["id": S.gemmaModel], ["id": S.gemmaModel]]]] as [[String: Any]] {
            var calls = 0
            let probe = await S.probe(config, externalAllowed: { true }, transport: { request in
                calls += 1; return try response(request, inventory)
            })
            #expect(!probe.hasModel && calls == 1, "Unknown/ambiguous identity cannot use another server's capacity")
        }
    }

    @Test func tunnelHonorsExternalPolicyBeforeEveryNetworkBoundary() async throws {
        var calls = 0
        let transport: (URLRequest) async throws -> (Data, URLResponse) = { request in
            calls += 1; return try response(request, inventory)
        }
        let probe = await S.probe(config, externalAllowed: { false }, transport: transport)
        let completion = await S.completeDetailed(config, isOllama: false, system: "s", user: "u",
            externalAllowed: { false }, transport: transport)
        #expect(!probe.reachable && calls == 0)
        if case .failure(let failure) = completion { #expect(failure.diagnostic.category == .policyDenied) }
        else { Issue.record("SSH loopback bypassed external-data policy") }
        var allowed = true
        let changed = await S.probe(config, externalAllowed: { allowed }, transport: { request in
            calls += 1; allowed = false; return try response(request, inventory)
        })
        #expect(!changed.hasModel && calls == 1, "Policy changes between models and props stop the second GET")
        let wrongProtocol = await S.completeDetailed(config, isOllama: true, system: "s", user: "u",
            externalAllowed: { true }, transport: transport)
        if case .failure(let failure) = wrongProtocol { #expect(failure.diagnostic.category == .invalidConfig) }
        else { Issue.record("RunPod profile attempted an Ollama request") }
        #expect(calls == 1)
    }

    @Test func aliasesAndEndpointTyposCannotTurnTheTunnelIntoLocalOnlyTraffic() async throws {
        for (url, model) in [(S.runPodURL, "stocksage-gemma4-31b-qat-benchmark"),
                             (S.runPodURL, "gemma-typo"), (S.runPodURL + "/v1", S.gemmaModel),
                             ("https://127.0.0.1:18080", S.gemmaModel)] {
            let candidate = try #require(S.config(url: url, model: model))
            #expect(candidate.isRunPodEndpoint && candidate.requiresExternalAccess && !candidate.supportsLocalUnload)
            var calls = 0
            let transport: (URLRequest) async throws -> (Data, URLResponse) = { request in
                calls += 1; return try response(request, [:])
            }
            let probe = await S.probe(candidate, externalAllowed: { false }, transport: transport)
            let output = await S.completeDetailed(candidate, isOllama: false, system: "s", user: "facts",
                externalAllowed: { false }, transport: transport)
            #expect(!probe.reachable && calls == 0)
            if case .failure(let failure) = output { #expect(failure.diagnostic.category == .policyDenied) }
            else { Issue.record("A model alias or endpoint typo bypassed external-data policy") }
        }
    }

    @Test(arguments: [192, 384])
    func truncatedReplyRetriesTheSameEvidenceThenVerifiesRemoteContext(outputLimit: Int) async throws {
        let schema = try #require(StockSageAIAssessment.responseSchema(facts: ["Retained fact."]))
        var bodies: [[String: Any]] = [], paths: [String] = []
        let completion = await S.completeDetailed(config, isOllama: false, system: "instructions", user: "F1: Retained fact.",
            maxTokens: outputLimit, contextTokens: 16384, jsonSchema: schema, externalAllowed: { true }, transport: { request in
                paths.append(request.url!.path)
                #expect(request.url?.port == 18080)
                if request.httpMethod == "GET" { return try response(request, properties()) }
                let bytes = try #require(request.httpBody)
                #expect(bytes.range(of: schema) != nil)
                bodies.append(try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any]))
                return try response(request, ["model": S.gemmaModel, "choices": [[
                    "message": ["content": bodies.count == 1 ? "" : "Complete answer."],
                    "finish_reason": bodies.count == 1 ? "length" : "stop"]]])
            })
        let answer = try completion.get()
        #expect(answer.text == "Complete answer." && answer.model == S.gemmaModel && answer.diagnostic.outputLimitRetries == 1)
        #expect(paths == ["/v1/chat/completions", "/v1/chat/completions", "/props"])
        try #require(bodies.count == 2)
        #expect(bodies[0]["max_tokens"] as? Int == outputLimit && bodies[1]["max_tokens"] as? Int == outputLimit * 2)
        bodies[0].removeValue(forKey: "max_tokens"); bodies[1].removeValue(forKey: "max_tokens")
        #expect(try JSONSerialization.data(withJSONObject: bodies[0], options: .sortedKeys)
            == JSONSerialization.data(withJSONObject: bodies[1], options: .sortedKeys))
    }

    @Test(arguments: ["missing-model", "wrong-model", "model-suffix", "missing-finish", "tool-call", "repeated-length", "short-context", "sleeping", "missing-props", "policy-changed", "policy-during-props"])
    func strictFailuresNeverPublishOrFallBackToTheMac(scenario: String) async throws {
        var allowed = true, paths: [String] = []
        let completion = await S.completeDetailed(config, isOllama: false, system: "instructions", user: "facts",
            maxTokens: 192, contextTokens: 16384, externalAllowed: { allowed }, transport: { request in
                #expect(request.url?.port == 18080)
                paths.append(request.url!.path)
                if request.httpMethod == "GET" {
                    var props = properties(context: scenario == "short-context" ? 8192 : 16384)
                    if scenario == "sleeping" { props["is_sleeping"] = true }
                    if scenario == "policy-during-props" { allowed = false }
                    return try response(request, props, status: scenario == "missing-props" ? 404 : 200)
                }
                var choice: [String: Any] = ["message": ["content": "Complete-looking answer."]]
                if scenario != "missing-finish" {
                    choice["finish_reason"] = scenario == "repeated-length" ? "length" : scenario == "tool-call" ? "tool_calls" : "stop"
                }
                var value: [String: Any] = ["choices": [choice]]
                if scenario != "missing-model" {
                    value["model"] = scenario == "wrong-model" ? "other-model" : S.gemmaModel + (scenario == "model-suffix" ? ":latest" : "")
                }
                if scenario == "policy-changed" { allowed = false }
                return try response(request, value)
            })
        if case .success = completion { Issue.record("RunPod accepted invalid output: \(scenario)") }
        #expect(paths.allSatisfy { ["/v1/chat/completions", "/props"].contains($0) })
        #expect(paths.filter { $0 == "/v1/chat/completions" }.count == (scenario == "repeated-length" ? 2 : 1))
        if scenario == "policy-changed" { #expect(paths == ["/v1/chat/completions"]) }
    }
}
