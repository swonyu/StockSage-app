import Testing
import Foundation
import Synchronization
@testable import StockSage

// Pure-part tests for the local-server (Ollama / LM Studio) client behind the Catalysts tab's
// optional explanation paragraph (owner request 2026-09-06, build step: local-server backend).
// No live network calls here — `probe(_:)`/`complete(_:)` need a real server and are exercised
// manually against the owner's running Ollama instance instead (see the commit body); every case
// below is the deterministic config/request/response machinery those two are built on.
@Suite("Local model server (config + request + response)")
struct StockSageLocalModelServerTests {

    typealias S = StockSageLocalModelServer

    @Test func equivalentSchemasProduceIdenticalWireRequests() throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        let schemas = [
            Data(#"{"type":"object","properties":{"risk":{"type":"string"},"reason":{"type":"string"}}}"#.utf8),
            Data(#"{"properties":{"reason":{"type":"string"},"risk":{"type":"string"}},"type":"object"}"#.utf8)
        ]
        let requests = schemas.map { S.chatRequest(config, system: "unchanged instructions",
            user: "unchanged facts", isOllama: false, maxTokens: 192, jsonSchema: $0) }
        let first = try #require(requests[0].httpBody)
        #expect(first == requests[1].httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        #expect(body["max_tokens"] as? Int == 192)
        #expect(body["response_format"] != nil)
    }

    private static func ok(_ object: [String: Any], _ request: URLRequest) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: object),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    @Test(arguments: [false, true]) @MainActor
    func totalDeadlineAndCancellationSettleBeforeAnUncooperativeTransport(cancel: Bool) async throws {
        let config = try #require(S.config(url: "http://127.0.0.1:8765", model: "fixture"))
        var instant = ContinuousClock.now
        var wire: CheckedContinuation<(Data, URLResponse), Error>?
        var timer: CheckedContinuation<Void, Error>?
        var settled = false
        let events = Mutex<[S.ModelAttemptEvent]>([])
        let task = Task { @MainActor in
            let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "u", timeout: 10,
                transport: { _ in try await withCheckedThrowingContinuation { wire = $0 } },
                clock: { instant }, sleepUntil: { _ in try await withCheckedThrowingContinuation { timer = $0 } },
                attemptObserver: { event in events.withLock { $0.append(event) } })
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
        let captured = events.withLock { $0 }
        #expect(captured.count == 2)
        if captured.count == 2 {
            #expect(captured[0].stage == .started && captured[1].stage == .finished)
            #expect(captured[0].callID == captured[1].callID)
            #expect(captured[1].category == (cancel ? .cancelled : .timeout))
        }
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
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
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
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
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

    @Test @MainActor func lmStudioResearchRejectsRepetitiveJunkBeforeLengthRetry() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        let schema = Data(#"{"type":"object"}"#.utf8)
        let junk = String(repeating: "Buy ", count: 8_000)
        var calls = 0
        let events = Mutex<[S.ModelAttemptEvent]>([])
        let result = await S.completeDetailed(config, isOllama: false, system: "instructions", user: "facts",
            maxTokens: 192, jsonSchema: schema, transport: { request in
                calls += 1
                return try Self.ok(["model": config.model,
                    "choices": [["message": ["content": junk], "finish_reason": "length"]]], request)
            }, phase: "research", attemptObserver: { event in events.withLock { $0.append(event) } })
        guard case .failure(let failure) = result else {
            Issue.record("repetitive research output was accepted"); return
        }
        #expect(calls == 1, "obvious cyclic junk must not spend the length-recovery retry")
        #expect(failure.diagnostic.category == .degenerateOutput)
        #expect(failure.diagnostic.degenerateReason == .repeatedTokenSequence)
        #expect(failure.diagnostic.outputLimitRetries == 0)
        #expect(failure.diagnostic.summary.contains("degenerate=repeatedTokenSequence"))
        let captured = events.withLock { $0 }
        let event = try #require(captured.first)
        #expect(captured.count == 2 && event.ordinal == 0 && event.phase == "research")
        #expect(captured.map(\.stage) == [.started, .finished])
        #expect(event.stage == .started && event.endedAt == nil)
        if captured.count == 2 {
            let terminal = captured[1]
            #expect(terminal.finish == .tokenLimit && terminal.category == .degenerateOutput)
            #expect(terminal.body?.utf8.count ?? 0 <= S.observerPayloadBytes)
            #expect(terminal.bodyTruncated && (terminal.responseBytes ?? 0) > S.observerPayloadBytes)
            #expect(terminal.system.utf8.count <= S.observerPayloadBytes && terminal.user == "facts")
            #expect(terminal.schema != nil && terminal.schemaBytes == schema.count && !terminal.schemaTruncated)
            #expect(terminal.contextTokens == 4_096 && terminal.temperature == 0.2)
            #expect(event.callID == terminal.callID && terminal.endedAt != nil)
        }
    }

    @Test func legitimateRepeatedTermsAreNotClassifiedAsDegenerate() {
        let text = "The report repeats Buy when describing both the bullish Buy case and the cautious Buy case; each use refers to a different context and evidence record."
        #expect(S.degenerateOutputReason(in: text) == nil)
        let structured = "{\"risk\": \"" + String(repeating: "F1 ", count: 32) + "\"}"
        #expect(S.degenerateOutputReason(in: structured) == nil)
    }

    @Test @MainActor func lmStudioWithoutSchemaLeavesRepeatedChatTextAccepted() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        let inventory: [String: Any] = ["models": [[
            "key": config.model, "type": "llm", "format": "mlx", "architecture": "qwen3_5",
            "params_string": "9B", "quantization": ["bits_per_weight": 6],
            "loaded_instances": [["id": config.model, "config": ["context_length": 16_384]]]
        ]]]
        let text = String(repeating: "Buy ", count: 128)
        var calls = 0
        let events = Mutex<[S.ModelAttemptEvent]>([])
        let result = await S.completeDetailed(config, isOllama: false, system: "chat", user: "question",
            transport: { request in
                if request.url?.path == "/api/v1/models" { return try Self.ok(inventory, request) }
                calls += 1
                return try Self.ok(["model": config.model,
                    "choices": [["message": ["content": text], "finish_reason": "stop"]]], request)
            }, attemptObserver: { event in events.withLock { $0.append(event) } })
        let completion = try #require(try? result.get())
        #expect(completion.text == text.trimmingCharacters(in: .whitespacesAndNewlines) && completion.diagnostic.category == nil)
        #expect(calls == 1)
        let captured = events.withLock { $0 }
        #expect(captured.count == 2)
        if captured.count == 2 {
            #expect(captured.map(\.stage) == [.started, .finished])
            #expect(captured[0].callID == captured[1].callID)
            #expect(captured.allSatisfy { $0.schema == nil && !$0.schemaTruncated })
        }
    }

    @Test @MainActor func structuredRepeatedTailStillGetsUsefulLengthRetry() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        let schema = Data(#"{"type":"object"}"#.utf8)
        let inventory: [String: Any] = ["models": [[
            "key": config.model, "type": "llm", "format": "mlx", "architecture": "qwen3_5",
            "params_string": "9B", "quantization": ["bits_per_weight": 6],
            "loaded_instances": [["id": config.model, "config": ["context_length": 16_384]]]
        ]]]
        let tail = #"{"risk":""# + String(repeating: "F1 ", count: 64) + #""}"#
        let complete = #"{"evidence":["F1"],"action":"Buy","reason":"Support holds.","risk":"The setup can reverse."}"#
        var calls = 0
        var maxTokens: [Int] = []
        let events = Mutex<[S.ModelAttemptEvent]>([])
        let result = await S.completeDetailed(config, isOllama: false, system: "instructions", user: "facts",
            maxTokens: 192, jsonSchema: schema, transport: { request in
                if request.url?.path == "/api/v1/models" { return try Self.ok(inventory, request) }
                calls += 1
                let body = try #require(request.httpBody)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                maxTokens.append(try #require(object["max_tokens"] as? Int))
                let content = calls == 1 ? tail : complete
                let finish = calls == 1 ? "length" : "stop"
                return try Self.ok(["model": config.model,
                    "choices": [["message": ["content": content], "finish_reason": finish]]], request)
            }, phase: "research", attemptObserver: { event in events.withLock { $0.append(event) } })
        let completion = try #require(try? result.get())
        #expect(completion.text == complete && calls == 2 && maxTokens == [192, 384])
        let captured = events.withLock { $0 }
        #expect(captured.count == 4)
        if captured.count == 4 {
            #expect(captured.map(\.stage) == [.started, .finished, .started, .finished])
            #expect(captured[0].callID == captured[1].callID && captured[2].callID == captured[3].callID)
            #expect(captured[0].callID != captured[2].callID)
            #expect(captured[1].category == nil && captured[1].finish == .tokenLimit)
        }
    }

    @Test @MainActor func observerPayloadCapDoesNotExpandSplitUTF8() async throws {
        let config = try #require(S.config(url: S.defaultURL, model: S.defaultModel))
        let system = String(repeating: "a", count: S.observerPayloadBytes - 1) + "é"
        let events = Mutex<[S.ModelAttemptEvent]>([])
        _ = await S.completeDetailed(config, isOllama: true, system: system, user: "question",
            contextTokens: 32_768,
            transport: { request in
                try Self.ok(["model": config.model, "message": ["content": "ok"], "done_reason": "stop"], request)
            }, attemptObserver: { event in events.withLock { $0.append(event) } })
        let event = try #require(events.withLock { $0.first })
        #expect(event.systemBytes == system.utf8.count)
        #expect(event.systemTruncated)
        #expect(event.system.utf8.count <= S.observerPayloadBytes)
    }

    @Test @MainActor func observerBodyMarksExactCapInvalidUTF8AsTruncated() async throws {
        let config = try #require(S.config(url: S.defaultURL, model: S.defaultModel))
        let events = Mutex<[S.ModelAttemptEvent]>([])
        _ = await S.completeDetailed(config, isOllama: true, system: "chat", user: "question",
            transport: { request in
                (Data(repeating: 0xFF, count: S.observerPayloadBytes),
                 HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, attemptObserver: { event in events.withLock { $0.append(event) } })
        let captured = events.withLock { $0 }
        #expect(captured.count == 2)
        if captured.count == 2 {
            #expect(captured[1].bodyTruncated)
            #expect(captured[1].responseBytes == S.observerPayloadBytes)
            #expect(captured[1].body?.utf8.count ?? 0 <= S.observerPayloadBytes)
        }
    }

    @Test @MainActor func lmStudioResearchStillRetriesUsefulTruncation() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        let schema = Data(#"{"type":"object"}"#.utf8)
        let complete = #"{"evidence":["F1"],"action":"Buy","reason":"The setup has support.","risk":"The setup can reverse."}"#
        let inventory: [String: Any] = ["models": [[
            "key": config.model, "type": "llm", "format": "mlx", "architecture": "qwen3_5",
            "params_string": "9B", "quantization": ["bits_per_weight": 6],
            "loaded_instances": [["id": config.model, "config": ["context_length": 16_384]]]
        ]]]
        var calls = 0
        var maxTokens: [Int] = []
        let events = Mutex<[S.ModelAttemptEvent]>([])
        let result = await S.completeDetailed(config, isOllama: false, system: "instructions", user: "facts",
            maxTokens: 192, jsonSchema: schema, transport: { request in
                if request.url?.path == "/api/v1/models" {
                    return try Self.ok(inventory, request)
                }
                calls += 1
                let body = try #require(request.httpBody)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                maxTokens.append(try #require(object["max_tokens"] as? Int))
                let content = calls == 1 ? "A useful answer with distinct facts and a pending conclusion." : complete
                let finish = calls == 1 ? "length" : "stop"
                return try Self.ok(["model": config.model,
                    "choices": [["message": ["content": content], "finish_reason": finish]]], request)
            }, phase: "initial", attemptObserver: { event in events.withLock { $0.append(event) } })
        let completion = try #require(try? result.get())
        #expect(calls == 2)
        #expect(maxTokens == [192, 384])
        #expect(completion.text == complete)
        #expect(completion.diagnostic.outputLimitRetries == 1)
        let captured = events.withLock { $0 }
        #expect(captured.count == 4)
        guard captured.count == 4 else { return }
        #expect(captured.map(\.ordinal) == [0, 0, 1, 1])
        #expect(captured.map(\.stage) == [.started, .finished, .started, .finished])
        #expect(captured.map(\.outputLimit) == [192, 192, 384, 384])
        #expect(captured.map(\.finish) == [.absent, .tokenLimit, .absent, .stop])
        #expect(captured.allSatisfy { $0.category == nil && $0.schema != nil && !$0.schemaTruncated && $0.phase == "initial" })
        #expect(captured[0].callID == captured[1].callID && captured[2].callID == captured[3].callID)
        #expect(captured[0].callID != captured[2].callID)
    }

    @Test @MainActor func genericChatKeepsItsTruncatedPartialOutput() async throws {
        let config = try #require(S.config(url: S.defaultURL, model: S.defaultModel))
        let text = String(repeating: "Buy ", count: 32)
        let events = Mutex<[S.ModelAttemptEvent]>([])
        let result = await S.completeDetailed(config, isOllama: true, system: "chat", user: "question",
            jsonSchema: Data(#"{"type":"object"}"#.utf8), transport: { request in
                try Self.ok(["model": config.model, "message": ["content": text], "done_reason": "length"], request)
            }, attemptObserver: { event in events.withLock { $0.append(event) } })
        let completion = try #require(try? result.get())
        #expect(completion.text == text.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(completion.diagnostic.category == nil)
        #expect(S.rejectsTruncatedOutput(completion))
        let event = try #require(events.withLock { $0 }.first)
        #expect(event.schema == nil && !event.schemaTruncated)
    }

    @Test @MainActor func observerCapturesTransportFailureWithoutRequestSecrets() async throws {
        let config = try #require(S.config(url: S.defaultURL, model: S.defaultModel))
        let events = Mutex<[S.ModelAttemptEvent]>([])
        let result = await S.completeDetailed(config, isOllama: true,
            system: "system secret should remain bounded", user: "user secret should remain bounded",
            transport: { _ in
                throw URLError(.timedOut)
            }, phase: "transport", attemptObserver: { event in events.withLock { $0.append(event) } })
        guard case .failure(let failure) = result else {
            Issue.record("expected transport failure"); return
        }
        #expect(failure.diagnostic.category == .timeout)
        let captured = events.withLock { $0 }
        let event = try #require(captured.first)
        #expect(captured.count == 2 && event.stage == .started)
        if captured.count == 2 {
            let terminal = captured[1]
            #expect(terminal.category == .timeout && terminal.finish == .absent)
            #expect(terminal.statusCode == nil && terminal.body == nil && terminal.responseBytes == nil)
            #expect(terminal.phase == "transport" && terminal.ordinal == 0)
            #expect(terminal.system.utf8.count <= S.observerPayloadBytes && terminal.user.utf8.count <= S.observerPayloadBytes)
            #expect(event.callID == terminal.callID && terminal.endedAt != nil)
        }
    }

    @Test @MainActor func observerFinishesAResponseRejectedByContextVerification() async throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.lmStudioModel))
        let events = Mutex<[S.ModelAttemptEvent]>([])
        let result = await S.completeDetailed(config, isOllama: false, system: "instructions", user: "facts",
            transport: { request in
                if request.url?.path == "/api/v1/models" {
                    return try Self.ok(["models": []], request)
                }
                return try Self.ok(["model": config.model,
                    "choices": [["message": ["content": "A complete answer."], "finish_reason": "stop"]]], request)
            }, attemptObserver: { event in events.withLock { $0.append(event) } })
        guard case .failure(let failure) = result else {
            Issue.record("missing context verification should fail"); return
        }
        #expect(failure.diagnostic.category == .contextBudget)
        let captured = events.withLock { $0 }
        #expect(captured.count == 2)
        guard captured.count == 2 else { return }
        #expect(captured[0].stage == .started && captured[1].stage == .finished)
        #expect(captured[0].callID == captured[1].callID)
        #expect(captured[1].category == .contextBudget && captured[1].body != nil)
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
