import Foundation
import CoreFoundation

// MARK: - StockSageLocalModelServer
//
// Owner request (2026-09-06): "okay" to a LOCAL-SERVER backend for the Catalysts tab's optional
// explanation paragraph, alongside the existing on-device FoundationModels path
// (StockSageCatalystNarrator). This file is the client for that server — an OpenAI-compatible
// HTTP endpoint, which covers both Ollama's native `/api/chat` (what the owner actually smoke-
// tested: Ollama 0.33.3, qwen3.8, loopback 127.0.0.1:11434) and a generic OpenAI-compatible
// server such as LM Studio (port 1234) through the same `complete(_:isOllama:...)` call.
//
// LOOPBACK BY DEFAULT, LAN IS A DELIBERATE STEP DOWN: `defaultURL` is 127.0.0.1 — nothing here
// ever guesses a LAN address. If a viewer points this at a LAN address anyway, the idea's
// facts (symbol, price, stop, target) leave this device over the network in plaintext, and a
// plain-http LAN call on iOS/macOS additionally needs the ATS local-networking allowance, which
// this build does NOT set (App Transport Security blocks a non-loopback plain-http request by
// default) — `isLoopback(_:)` exists so the view can warn about exactly this before a viewer
// points the field at anything but 127.0.0.1/localhost/a Tailscale address. No API key: a local
// server needs none, and none is ever sent.
//
// Mac-in-practice: iOS has no way to reach a server running on the same physical Mac except over
// the LAN (there is no loopback between a phone and its host machine), so this backend is, in
// practice, a macOS-build feature today — the code compiles and runs identically on iOS, the
// network path just isn't loopback there.
enum StockSageLocalModelServer {
    /// Facts go only to the configured endpoint, never to a redirect target; no shared cookies.
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    typealias NoRedirect = StockSageHTTP.NoRedirect

    // MARK: Backend selection

    /// Which explanation backend the Catalysts tab's "Explain" button should try, in order.
    /// Persisted as a raw String (`backendKey`) so it round-trips through `@AppStorage` on the
    /// view side and `UserDefaults` on this side without a second source of truth.
    enum Backend: String, CaseIterable, Sendable {
        case auto, onDeviceOnly, localServerOnly, off

        nonisolated var title: String {
            switch self {
            case .auto:            return "Auto (local server, then on-device)"
            case .onDeviceOnly:    return "On-device only"
            case .localServerOnly: return "Local server only"
            case .off:             return "Off"
            }
        }
    }

    /// `UserDefaults` keys — shared verbatim with the view's own `@AppStorage` property wrappers
    /// so both sides read/write the exact same three settings.
    static let backendKey = "catalystNarratorBackend"
    static let urlKey = "localModelServerURL"
    static let modelKey = "localModelServerModel"

    /// Written with each in-app mutation: A→B→A must not revive an old request.
    static let revisionKey = "stocksage.modelSettings.revision"
    static func settingsRevision(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: revisionKey)
    }
    @discardableResult static func setSetting(_ value: String, for key: String,
                                             defaults: UserDefaults = .standard) -> Bool {
        guard [backendKey, urlKey, modelKey].contains(key), defaults.string(forKey: key) != value else { return false }
        defaults.set(UUID().uuidString, forKey: revisionKey)
        defaults.set(value, forKey: key)
        return true
    }

    static let defaultURL = "http://127.0.0.1:11434"
    static let defaultModel = "qwen3.8"
    // Stable inventory key supports LM Studio JIT reload; an lms --identifier alias does not.
    nonisolated static let lmStudioURL = "http://127.0.0.1:1234"
    nonisolated static let lmStudioModel = "qwen3.5-9b"
    nonisolated static let maximumResponseBytes = 1_048_576

    /// Qwen3.5's installed NFC + byte-level BPE tokenizer cannot emit more tokens than
    /// normalized UTF-8 bytes. The verified two-string-message non-thinking template has
    /// fewer than 128 framing bytes. This is a sufficient bound, not an exact token count.
    // ponytail: conservative bound can reject a tokenizable prompt; use a supported tokenizer
    // endpoint if LM Studio exposes one, never guess bytes/4 or silently drop mandatory facts.
    nonisolated static func promptFits(system: String, user: String, outputTokens: Int) -> Bool {
        guard (1..<4096).contains(outputTokens) else { return false }
        let budget = 4096 - outputTokens - 128
        let systemBytes = system.precomposedStringWithCanonicalMapping.utf8.count
        guard systemBytes <= budget else { return false }
        return user.precomposedStringWithCanonicalMapping.utf8.count <= budget - systemBytes
    }

    // MARK: Config

    struct Config: Sendable, Equatable {
        let baseURL: URL
        let model: String
        nonisolated var isLMStudio9B: Bool {
            model == StockSageLocalModelServer.lmStudioModel && StockSageLocalModelServer.isLoopback(baseURL)
                && baseURL.port == 1234 && ["", "/"].contains(baseURL.path)
        }
    }

    /// Validates and normalizes the two raw settings strings into a `Config`, or `nil` when
    /// either is unusable. Trims whitespace from both; the URL must parse with an http/https
    /// scheme and a non-empty host (so "ftp://x" and a bare "x" both fail); a trailing slash on
    /// the URL is stripped so `baseURL.absoluteString` + "/api/tags" never doubles up. The model
    /// must be non-empty after trimming.
    nonisolated static func config(url: String, model: String) -> Config? {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty, trimmedModel.utf8.count <= 512 else { return nil }
        var trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmedURL.hasSuffix("/") { trimmedURL.removeLast() }
        guard let parsed = URL(string: trimmedURL),
              let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parsed.host, !host.isEmpty,
              parsed.user == nil, parsed.password == nil, parsed.query == nil, parsed.fragment == nil else { return nil }
        return Config(baseURL: parsed, model: trimmedModel)
    }

    /// True for 127.0.0.1 / localhost / ::1 (bracketed or not) — the addresses that never leave
    /// this device. Anything else (a LAN IP, a hostname, a Tailscale address) is NOT loopback,
    /// which is exactly what the view's network-safety warning keys off of.
    nonisolated static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    // MARK: Probe

    struct Probe: Sendable, Equatable {
        let reachable: Bool
        let isOllama: Bool
        let models: [String]
        let hasModel: Bool
        /// One-line human status, ready to render as-is — e.g. "Reachable · Ollama · model
        /// qwen3.8 present" or "Unreachable: <error>".
        let detail: String
    }

    /// Ollama tags a locally-served model "name:latest" (e.g. "qwen3.8:latest") while a viewer
    /// types the bare name; strip the suffix on both sides before comparing so either spelling
    /// matches.
    private nonisolated static func stripLatestSuffix(_ s: String) -> String {
        s.hasSuffix(":latest") ? String(s.dropLast(":latest".count)) : s
    }

    private static func requestFailure(_ c: Config, stillValid: @MainActor () -> Bool,
                                      externalAllowed: @MainActor () -> Bool) -> CompletionFailure? {
        if Task.isCancelled { return .init(diagnostic: .init(category: .cancelled)) }
        if !stillValid() { return .init(diagnostic: .init(category: .obsoleteRequest)) }
        guard config(url: c.baseURL.absoluteString, model: c.model) == c else {
            return .init(diagnostic: .init(category: .invalidConfig))
        }
        if !isLoopback(c.baseURL), !externalAllowed() {
            return .init(diagnostic: .init(category: .policyDenied))
        }
        return nil
    }

    private static func fetchJSONObject(_ url: URL,
        transport: ((URLRequest) async throws -> (Data, URLResponse))?) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        do {
            let (data, response): (Data, URLResponse)
            if let transport { (data, response) = try await transport(request) }
            else { (data, response) = try await StockSageHTTP.data(for: request, session: session, maximumBytes: 262_144) }
            guard data.count <= 262_144, let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    /// 1) Ollama's `/api/tags` ; on failure 2) an OpenAI-compatible `/v1/models`. Never throws —
    /// an unreachable server, a malformed body, or a timeout all come back as
    /// `reachable: false`, never as a thrown error the caller has to handle.
    static func probe(_ c: Config, stillValid: @MainActor () -> Bool = { true },
                      externalAllowed: @MainActor () -> Bool = { ToolPolicy.isExternalAllowed },
                      transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async -> Probe {
        func denied() -> Bool { requestFailure(c, stillValid: stillValid, externalAllowed: externalAllowed) != nil }
        let stopped = Probe(reachable: false, isOllama: false, models: [], hasModel: false,
                            detail: "Model check stopped: request cancelled, settings changed, or network access disabled.")
        guard !denied() else { return stopped }
        if let tags = await fetchJSONObject(c.baseURL.appendingPathComponent("api/tags"), transport: transport),
           let rawModels = tags["models"] as? [[String: Any]] {
            guard !denied() else { return stopped }
            let names = rawModels.compactMap { $0["name"] as? String }
            let hasModel = names.contains { stripLatestSuffix($0) == stripLatestSuffix(c.model) }
            let list = names.map(stripLatestSuffix)
            let detail = hasModel
                ? "Reachable · Ollama · model \(c.model) present"
                : "Reachable · Ollama · requested model not found. Check the model ID in Model settings."
            return Probe(reachable: true, isOllama: true, models: list, hasModel: hasModel, detail: detail)
        }
        guard !denied() else { return stopped }
        if let openAI = await fetchJSONObject(c.baseURL.appendingPathComponent("v1/models"), transport: transport),
           let rawData = openAI["data"] as? [[String: Any]] {
            guard !denied() else { return stopped }
            let ids = rawData.compactMap { $0["id"] as? String }
            let hasModel = ids.contains { stripLatestSuffix($0) == stripLatestSuffix(c.model) }
            let detail = hasModel
                ? "Reachable · OpenAI-compatible · model \(c.model) present"
                : "Reachable · OpenAI-compatible · requested model not found. Check the model ID in Model settings."
            return Probe(reachable: true, isOllama: false, models: ids, hasModel: hasModel, detail: detail)
        }
        return Probe(reachable: false, isOllama: false, models: [], hasModel: false,
                     detail: "Unreachable: check the model server and Model settings.")
    }

    // MARK: Chat

    /// Builds the POST request for one chat turn — Ollama's native `/api/chat` (with
    /// `"think": false`, matching the owner's smoke test: Ollama defaults qwen3.8 to emitting a
    /// `<think>` block first, which both wastes the 90 s budget and is not the paragraph we want)
    /// or an OpenAI-compatible `/v1/chat/completions`. Short explanations keep the 4k/90s
    /// defaults; conversational Chat supplies its own output budget and timeout. OpenAI-compatible
    /// servers receive an output limit only; the caller bounds input before sending it.
    nonisolated static func chatRequest(_ c: Config, system: String, user: String, isOllama: Bool,
                                        maxTokens: Int, contextTokens: Int = 4096,
                                        timeout: TimeInterval = 90) -> URLRequest {
        let path = isOllama ? "api/chat" : "v1/chat/completions"
        var request = URLRequest(url: c.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        let messages: [[String: String]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": user],
        ]
        var body: [String: Any] = ["model": c.model, "stream": false, "messages": messages]
        if isOllama {
            body["think"] = false
            body["options"] = ["temperature": 0.2, "num_predict": maxTokens, "num_ctx": contextTokens]
        } else {
            body["temperature"] = 0.2
            body["max_tokens"] = maxTokens
            if c.isLMStudio9B { body["ttl"] = 180 }
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Metadata is observational: unknown/invalid fields never change text acceptance.
    nonisolated enum Finish: String, Sendable { case absent, unknown, malformed, stop, tokenLimit, toolCall, filtered }
    nonisolated enum FailureCategory: String, Sendable {
        case invalidConfig, unavailable, modelMissing, unsupportedModel, nonHTTP, http, malformedJSON, responseShape, missingContent, emptyContent
        case timeout, cancelled, network, obsoleteRequest, policyDenied, responseTooLarge, contextBudget, incompleteOutput
    }
    nonisolated struct Diagnostic: Sendable, Equatable {
        var category: FailureCategory? = nil
        var httpStatus: Int? = nil
        var bodyBytes: Int? = nil
        var oversizedBody = false
        var textBytes: Int? = nil
        var finish: Finish = .absent
        var promptTokens: Int? = nil
        var completionTokens: Int? = nil
        var malformedUsage = false

        // Fixed keys/enums and capped integers only. Never interpolate server strings/errors.
        var summary: String {
            "server=\(category?.rawValue ?? "completed") status=\(httpStatus.map(String.init) ?? "unknown") body=\(bodyBytes.map(String.init) ?? "unknown") oversized=\(oversizedBody) text=\(textBytes.map(String.init) ?? "unknown") finish=\(finish.rawValue) prompt=\(promptTokens.map(String.init) ?? "unknown") completion=\(completionTokens.map(String.init) ?? "unknown") malformedUsage=\(malformedUsage)"
        }
    }
    nonisolated struct Completion: Sendable, Equatable {
        let text: String
        let diagnostic: Diagnostic
        var model: String? = nil
    }
    nonisolated struct CompletionFailure: Error, Sendable, Equatable {
        let diagnostic: Diagnostic
        var legacyError: ServerError {
            switch diagnostic.category {
            case .invalidConfig: return .invalidConfig
            case .modelMissing: return .modelMissing(diagnostic.summary)
            case .timeout, .cancelled, .network, .unavailable, .obsoleteRequest, .policyDenied: return .unreachable(diagnostic.summary)
            default: return .badResponse(diagnostic.summary)
            }
        }
    }
    typealias CompletionResult = Swift.Result<Completion, CompletionFailure>
    nonisolated static func boundedCount(_ value: Int) -> Int { min(max(value, 0), 16_777_216) }

    private nonisolated static func tokenCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= 16_777_216,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }

    nonisolated static func parseCompletion(_ data: Data, isOllama: Bool) -> CompletionResult {
        var diagnostic = Diagnostic(bodyBytes: boundedCount(data.count), oversizedBody: data.count > maximumResponseBytes)
        guard !diagnostic.oversizedBody else {
            diagnostic.category = .responseTooLarge
            return .failure(.init(diagnostic: diagnostic))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            diagnostic.category = .malformedJSON
            return .failure(.init(diagnostic: diagnostic))
        }
        guard let obj = json as? [String: Any] else {
            diagnostic.category = .responseShape
            return .failure(.init(diagnostic: diagnostic))
        }
        let choice = (obj["choices"] as? [[String: Any]])?.first
        let rawFinish = isOllama ? obj["done_reason"] : choice?["finish_reason"]
        if let rawFinish, !(rawFinish is NSNull) {
            if let finish = rawFinish as? String {
                switch finish {
                case "stop": diagnostic.finish = .stop
                case "length": diagnostic.finish = .tokenLimit
                case "tool_calls", "function_call": diagnostic.finish = .toolCall
                case "content_filter": diagnostic.finish = .filtered
                default: diagnostic.finish = .unknown
                }
            } else { diagnostic.finish = .malformed }
        }
        let usage = obj["usage"] as? [String: Any]
        let prompt = isOllama ? obj["prompt_eval_count"] : usage?["prompt_tokens"]
        let completion = isOllama ? obj["eval_count"] : usage?["completion_tokens"]
        diagnostic.promptTokens = tokenCount(prompt)
        diagnostic.completionTokens = tokenCount(completion)
        diagnostic.malformedUsage = (prompt != nil && !(prompt is NSNull) && diagnostic.promptTokens == nil)
            || (completion != nil && !(completion is NSNull) && diagnostic.completionTokens == nil)
            || (!isOllama && obj["usage"] != nil && !(obj["usage"] is NSNull) && usage == nil)
        let content = (isOllama ? obj["message"] as? [String: Any] : choice?["message"] as? [String: Any])?["content"] as? String
        guard let content else {
            diagnostic.category = .missingContent
            return .failure(.init(diagnostic: diagnostic))
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostic.textBytes = boundedCount(trimmed.utf8.count)
        guard !trimmed.isEmpty else {
            diagnostic.category = .emptyContent
            return .failure(.init(diagnostic: diagnostic))
        }
        let model = (obj["model"] as? String).flatMap { !$0.isEmpty && $0.utf8.count <= 512 ? $0 : nil }
        return .success(.init(text: trimmed, diagnostic: diagnostic, model: model))
    }

    /// Compatibility wrapper: exactly the existing trimmed content, regardless of metadata.
    nonisolated static func parseChatResponse(_ data: Data, isOllama: Bool) -> String? {
        try? parseCompletion(data, isOllama: isOllama).get().text
    }

    enum ServerError: Error, Equatable, Sendable {
        case invalidConfig
        case unreachable(String)
        case modelMissing(String)
        case badResponse(String)
    }

    nonisolated static func transportFailure(_ error: Error) -> CompletionFailure {
        let category: FailureCategory
        if error is CancellationError { category = .cancelled }
        else if let error = error as? URLError {
            switch error.code {
            case .cancelled: category = .cancelled
            case .timedOut: category = .timeout
            case .dataLengthExceedsMaximum: category = .responseTooLarge
            default: category = .network
            }
        } else { category = .network }
        return .init(diagnostic: .init(category: category, oversizedBody: category == .responseTooLarge))
    }

    /// Shared transport seam; injected transport is for deterministic offline tests only.
    static func completeDetailed(_ c: Config, isOllama: Bool, system: String, user: String,
                                 maxTokens: Int = 170, contextTokens: Int = 4096,
                                 timeout: TimeInterval = 90,
                                 stillValid: @MainActor () -> Bool = { true },
                                 externalAllowed: @MainActor () -> Bool = { ToolPolicy.isExternalAllowed },
                                 transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async -> CompletionResult {
        if let failure = requestFailure(c, stillValid: stillValid, externalAllowed: externalAllowed) {
            return .failure(failure)
        }
        if c.isLMStudio9B, !promptFits(system: system, user: user, outputTokens: maxTokens) {
            return .failure(.init(diagnostic: .init(category: .contextBudget)))
        }
        let request = chatRequest(c, system: system, user: user, isOllama: isOllama,
                                  maxTokens: maxTokens, contextTokens: contextTokens, timeout: timeout)
        do {
            let (data, response): (Data, URLResponse)
            if let transport { (data, response) = try await transport(request) }
            else { (data, response) = try await StockSageHTTP.data(for: request, session: session, maximumBytes: maximumResponseBytes) }
            if let failure = requestFailure(c, stillValid: stillValid, externalAllowed: externalAllowed) {
                return .failure(failure)
            }
            guard data.count <= maximumResponseBytes else {
                return .failure(.init(diagnostic: .init(category: .responseTooLarge,
                    bodyBytes: boundedCount(data.count), oversizedBody: true)))
            }
            guard let http = response as? HTTPURLResponse else {
                return .failure(.init(diagnostic: .init(category: .nonHTTP, bodyBytes: boundedCount(data.count),
                                                        oversizedBody: data.count > 1_048_576)))
            }
            guard (200..<300).contains(http.statusCode) else {
                // Preserve the legacy model-missing detection; never retain/emit the body.
                let missing = (String(data: data, encoding: .utf8) ?? "").lowercased().contains("not found")
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let code = (object?["error"] as? [String: Any])?["code"] as? String
                let category: FailureCategory = (missing || code == "model_not_found") ? .modelMissing
                    : (code == "unsupported_model" ? .unsupportedModel : .http)
                return .failure(.init(diagnostic: .init(category: category,
                    httpStatus: (100...599).contains(http.statusCode) ? http.statusCode : nil,
                    bodyBytes: boundedCount(data.count), oversizedBody: data.count > 1_048_576)))
            }
            switch parseCompletion(data, isOllama: isOllama) {
            case .success(let reply):
                // The new profile must not publish another model's answer under its selected ID.
                // Keep legacy metadata acceptance unchanged for existing servers.
                if c.isLMStudio9B, reply.model != c.model {
                    return .failure(.init(diagnostic: .init(category: .responseShape, httpStatus: http.statusCode)))
                }
                if c.isLMStudio9B, reply.diagnostic.finish != .stop {
                    var diagnostic = reply.diagnostic
                    diagnostic.category = .incompleteOutput
                    diagnostic.httpStatus = http.statusCode
                    return .failure(.init(diagnostic: diagnostic))
                }
                var diagnostic = reply.diagnostic
                diagnostic.httpStatus = http.statusCode
                return .success(.init(text: reply.text, diagnostic: diagnostic, model: reply.model))
            case .failure(let failure):
                var diagnostic = failure.diagnostic
                diagnostic.httpStatus = http.statusCode
                return .failure(.init(diagnostic: diagnostic))
            }
        } catch { return .failure(transportFailure(error)) }
    }

    static func complete(_ c: Config, isOllama: Bool, system: String, user: String,
                         maxTokens: Int = 170, contextTokens: Int = 4096,
                         timeout: TimeInterval = 90,
                         stillValid: @MainActor () -> Bool = { true }) async -> Swift.Result<String, ServerError> {
        await completeDetailed(c, isOllama: isOllama, system: system, user: user,
            maxTokens: maxTokens, contextTokens: contextTokens, timeout: timeout, stillValid: stillValid)
            .map(\.text).mapError(\.legacyError)
    }
}
