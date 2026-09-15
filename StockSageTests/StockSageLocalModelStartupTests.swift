import Foundation
import Testing
@testable import StockSage

@Suite(.serialized) @MainActor struct StockSageLocalModelStartupTests {
    typealias S = StockSageLocalModelServer
    private func inventory(loaded: Bool, context: Int = 16_384) -> [String: Any] {
        ["models": [["key": "google/gemma-4-31b-qat", "type": "llm", "format": "gguf",
            "architecture": "gemma4", "params_string": "31B",
            "quantization": ["name": "Q4_0", "bits_per_weight": 4],
            "loaded_instances": loaded ? [["id": "google/gemma-4-31b-qat",
                "config": ["context_length": context, "parallel": 1]]] : []]]]
    }

    @Test func startupIsOptInAndOnlyUsesTheSelectedLocalGemma() throws {
        let name = "gemma-startup-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("localServerOnly", forKey: S.backendKey)
        defaults.set("http://127.0.0.1:1234", forKey: S.urlKey)
        defaults.set("google/gemma-4-31b-qat", forKey: S.modelKey)
        #expect(StockSageLocalModelStartup.startupConfig(defaults) == nil)
        defaults.set(true, forKey: StockSageLocalModelStartup.enabledKey)
        #expect(StockSageLocalModelStartup.startupConfig(defaults)?.isLMStudioGemma == true)
        for (key, value) in [(S.modelKey, "qwen3.5-9b"), (S.urlKey, "http://example.com:1234"), (S.backendKey, "off")] {
            let old = defaults.string(forKey: key)
            defaults.set(value, forKey: key)
            #expect(StockSageLocalModelStartup.startupConfig(defaults) == nil)
            defaults.set(old, forKey: key)
        }
    }

    @Test(arguments: [16_384, 32_768, 65_536])
    func loadsOnlyOnceThenVerifiesTheActualServingInstance(context: Int) async throws {
        let loader = StockSageLocalModelStartup()
        let c = try #require(S.config(url: "http://127.0.0.1:1234", model: "google/gemma-4-31b-qat"))
        var loaded = false, paths: [String] = []
        let transport: StockSageLocalModelStartup.Transport = { request in
            paths.append(request.url!.path)
            let object: [String: Any]
            if request.httpMethod == "POST" {
                let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                #expect(body["model"] as? String == c.model)
                #expect(Set(body.keys) == ["model", "echo_load_config"] && body["echo_load_config"] as? Bool == true,
                    "Loading must use the owner's saved model defaults without tuning overrides")
                loaded = true
                object = ["status": "loaded", "instance_id": c.model]
            } else { object = inventory(loaded: loaded, context: context) }
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let first = await loader.ensureLoaded(c, transport: transport)
        let second = await loader.ensureLoaded(c, transport: transport)
        #expect(first.hasModel && second.hasModel)
        #expect(first.servingContext == context && second.servingContext == context)
        #expect(paths.filter { $0 == "/api/v1/models/load" }.count == 1)
        #expect(loader.ready && !loader.isWorking)
    }

    @Test func disabledOrObsoleteSelectionNeverLoads() async throws {
        let c = try #require(S.config(url: "http://127.0.0.1:1234", model: "google/gemma-4-31b-qat"))
        let loader = StockSageLocalModelStartup()
        var calls = 0
        let result = await loader.ensureLoaded(c, stillValid: { false }, transport: { request in
            calls += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(!result.hasModel && calls == 0)
    }

    @Test(arguments: ["first-cancelled", "second-cancelled", "second-obsolete"])
    func sharedLoadReleasesCancelledCallersAndRechecksEachWaiter(interruption: String) async throws {
        let loader = StockSageLocalModelStartup()
        let c = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        var release: CheckedContinuation<Void, Never>?
        var loaded = false, secondAllowed = true
        var posts = 0
        var firstSettled = false, secondEntered = false, secondSettled = false
        let transport: StockSageLocalModelStartup.Transport = { request in
            let object: [String: Any]
            if request.httpMethod == "POST" {
                posts += 1
                if posts == 1 { await withCheckedContinuation { release = $0 } }
                else { Issue.record("Concurrent callers submitted a duplicate load") }
                loaded = true
                object = ["status": "loaded", "instance_id": c.model]
            } else { object = inventory(loaded: loaded) }
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!,
                statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let first = Task { @MainActor in
            let result = await loader.ensureLoaded(c, transport: transport)
            firstSettled = true
            return result
        }
        defer { first.cancel(); loader.cancel(); release?.resume(); release = nil }
        for _ in 0..<2000 where release == nil { await Task.yield() }
        try #require(release != nil, "The first caller must reach the held load POST")
        let second = Task { @MainActor in
            secondEntered = true
            let result = await loader.ensureLoaded(c, stillValid: { secondAllowed }, transport: transport)
            secondSettled = true
            return result
        }
        defer { second.cancel() }
        for _ in 0..<2000 where !secondEntered { await Task.yield() }
        #expect(secondEntered && posts == 1 && !firstSettled && !secondSettled)
        if interruption == "first-cancelled" { first.cancel() }
        else if interruption == "second-cancelled" { second.cancel() }
        else { secondAllowed = false }
        if interruption != "second-obsolete" {
            for _ in 0..<2000 {
                if interruption == "first-cancelled" ? firstSettled : secondSettled { break }
                await Task.yield()
            }
            #expect(interruption == "first-cancelled" ? firstSettled : secondSettled,
                "A cancelled caller must return while the shared transport is still held")
            #expect(interruption == "first-cancelled" ? !secondSettled : !firstSettled)
        }
        release?.resume(); release = nil
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult.hasModel == (interruption != "first-cancelled"))
        #expect(secondResult.hasModel == (interruption == "first-cancelled"))
        #expect(posts == 1 && loader.ready && !loader.isWorking)
    }

    @Test func confirmedLoadWithInsufficientContextCanBeRetriedAfterManualCorrection() async throws {
        let loader = StockSageLocalModelStartup()
        let c = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        var loaded = false, context = 8192, posts = 0
        let transport: StockSageLocalModelStartup.Transport = { request in
            let object: [String: Any]
            if request.httpMethod == "POST" {
                posts += 1; loaded = true
                object = ["status": "loaded", "instance_id": c.model]
            } else { object = inventory(loaded: loaded, context: context) }
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!,
                statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let insufficient = await loader.ensureLoaded(c, transport: transport)
        #expect(!insufficient.hasModel && posts == 1 && !loader.ready)
        #expect(!loader.cancel(), "A matching loaded acknowledgement resolves submission uncertainty even when readiness fails")
        // Simulate the owner unloading and correcting the existing LM Studio defaults.
        loaded = false; context = 32_768
        let corrected = await loader.ensureLoaded(c, transport: transport)
        #expect(corrected.hasModel && corrected.servingContext == context && posts == 2)
        #expect(loader.ready && !loader.isWorking)
    }

    @Test func lostLoadAcknowledgementRetainsOriginalQuitTargetAndCannotConfirmEmptyUnload() async throws {
        let loader = StockSageLocalModelStartup()
        let c = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        var posts = 0
        let failed = await loader.ensureLoaded(c, transport: { request in
            if request.httpMethod == "POST" {
                posts += 1
                throw URLError(.networkConnectionLost)
            }
            return (try JSONSerialization.data(withJSONObject: inventory(loaded: false)),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(!failed.hasModel && posts == 1)
        let target = try #require(loader.pendingConfig)
        #expect(target == c)
        let changed = try #require(S.config(url: "http://localhost:1234", model: S.gemmaModel))
        var contactedChangedServer = false
        let rejected = await loader.ensureLoaded(changed, transport: { _ in
            contactedChangedServer = true
            throw URLError(.cannotConnectToHost)
        })
        #expect(!rejected.hasModel && !contactedChangedServer && loader.pendingConfig == c)
        let uncertain = loader.cancel()
        #expect(uncertain && loader.pendingConfig == c)
        let unloaded = await S.unloadOnQuit(target, inferenceWasActive: uncertain, transport: { request in
            #expect(request.httpMethod == "GET", "Cleanup must not load a model when inventory is empty")
            return (try JSONSerialization.data(withJSONObject: inventory(loaded: false)),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(!unloaded, "A possibly accepted load must not be declared unloaded from an empty snapshot")
    }
}
