import Testing
import Foundation
@testable import StockSage

// Pure-part tests for the local-server (Ollama / LM Studio) client behind the Catalysts tab's
// optional explanation paragraph (owner request 2026-09-06, build step: local-server backend).
// No live network calls here — `probe(_:)`/`complete(_:)` need a real server and are exercised
// manually against the owner's running Ollama instance instead (see the commit body); every case
// below is the deterministic config/request/response machinery those two are built on.
@Suite("Local model server (config + request + response)")
struct StockSageLocalModelServerTests {

    typealias S = StockSageLocalModelServer

    @Test(arguments: [false, true]) @MainActor
    func totalDeadlineAndCancellationSettleBeforeAnUncooperativeTransport(cancel: Bool) async throws {
        let config = try #require(S.config(url: "http://127.0.0.1:8765", model: "fixture"))
        var instant = ContinuousClock.now
        var wire: CheckedContinuation<(Data, URLResponse), Error>?
        var timer: CheckedContinuation<Void, Error>?
        var settled = false
        let task = Task { @MainActor in
            let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "u", timeout: 10,
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
