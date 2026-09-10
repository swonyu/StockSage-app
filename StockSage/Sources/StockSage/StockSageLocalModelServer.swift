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

    /// Context window declared by the EVIDENCE-HEAVY callers (paper research, horizon research,
    /// AI assessment, Catalyst explanations). Conversational Chat keeps the owner's 4,096
    /// interactive target, which its own prompt budget already fits inside.
    ///
    /// Why this is not 4,096: those callers compile up to 12,000 UTF-8 bytes of facts, and
    /// `chatRequest` sends `contextTokens` to Ollama verbatim as `num_ctx`. Declaring 4,096 while
    /// sending 12,000 bytes meant the server silently truncated evidence — mandatory execution
    /// facts, cash constraints and risk disclosures could fall off the end with nothing reported.
    /// 16,384 leaves every one of those callers' existing 12,000-byte budgets fitting whole.
    ///
    /// Measured 2026-09-10 (receipts in `StockSage-harness-20260910.opus/`): LM Studio auto-fits
    /// this model to a 262,144 runtime window regardless of the requested value, and accepted a
    /// single 24,206-byte prompt as 11,015 units, so 16,384 is well inside the served capacity.
    /// This is a REQUEST target, not a claim about the model's maximum or the server's allocation.
    nonisolated static let researchContextTokens = 16_384
    // Stable inventory key supports LM Studio JIT reload; an lms --identifier alias does not.
    nonisolated static let lmStudioURL = "http://127.0.0.1:1234"
    nonisolated static let lmStudioModel = "qwen3.5-9b"
    nonisolated static let maximumResponseBytes = 1_048_576

    /// Qwen3.5's installed NFC + byte-level BPE tokenizer cannot emit more tokens than
    /// normalized UTF-8 bytes. The verified two-string-message non-thinking template has
    /// fewer than 128 framing bytes. This is a sufficient bound, not an exact token count.
    ///
    /// MEASURED CONSERVATISM (2026-09-10, qwen3.5-9b via LM Studio, receipts in
    /// `StockSage-harness-20260910.opus/context-budget-calibration.json`): the real ratio is
    /// 1.21 bytes/unit for dense numeric tables, 2.0 for JSON facts, 4.0 for English news and
    /// 5.5 for Arabic news. So this bound is nearly tight for tables and costs Arabic evidence
    /// about 5.5x of its allowance. It is kept because it is SOUND — the installed LM Studio
    /// build exposes no tokenizer endpoint (`/v1/tokenize` and `/api/v0/tokenize` both return
    /// an "Unexpected endpoint" body), so there is nothing exact to ask. Callers must therefore
    /// pack to `maximumUserBytes` and DISCLOSE what they dropped, never silently truncate.
    // ponytail: swap for a real count if a tokenizer endpoint ships; never guess bytes/4.
    nonisolated static func promptFits(system: String, user: String, outputTokens: Int,
                                       contextTokens: Int = 4096) -> Bool {
        guard let budget = promptBudget(outputTokens: outputTokens, contextTokens: contextTokens) else {
            return false
        }
        let systemBytes = system.precomposedStringWithCanonicalMapping.utf8.count
        guard systemBytes <= budget else { return false }
        return user.precomposedStringWithCanonicalMapping.utf8.count <= budget - systemBytes
    }

    /// Total normalized-UTF-8 byte budget for system + user together, or nil when the caller's
    /// output/context request is itself unusable.
    private nonisolated static func promptBudget(outputTokens: Int, contextTokens: Int) -> Int? {
        guard (1..<1_048_576).contains(contextTokens), (1..<contextTokens).contains(outputTokens) else {
            return nil
        }
        let budget = contextTokens - outputTokens - 128
        return budget > 0 ? budget : nil
    }

    /// How many UTF-8 bytes of `user` content actually fit alongside this `system` string.
    /// Callers pack evidence to THIS number instead of a hardcoded constant, so an over-large
    /// fact set becomes a disclosed partial answer rather than a rejected whole request.
    nonisolated static func maximumUserBytes(system: String, outputTokens: Int,
                                             contextTokens: Int = 4096) -> Int {
        guard let budget = promptBudget(outputTokens: outputTokens, contextTokens: contextTokens) else {
            return 0
        }
        return max(0, budget - system.precomposedStringWithCanonicalMapping.utf8.count)
    }

    /// Result of fitting an evidence set to the real budget.
    /// `omitted > 0` is a fact the caller MUST disclose — silently shortening evidence and then
    /// presenting a confident answer is exactly the failure this whole seam exists to prevent.
    nonisolated struct FittedPrompt: Sendable, Equatable {
        let optionalKept: Int
        let omitted: Int
        let userBytes: Int
        var isComplete: Bool { omitted == 0 }
    }

    /// Drop whole OPTIONAL records from the end, one at a time, until the assembled prompt fits.
    /// Mandatory content is never dropped: if the prompt does not fit with zero optional records,
    /// this returns nil and the caller must report a context-budget limit rather than send a
    /// prompt with a risk disclosure or a cash constraint quietly removed.
    ///
    /// `assemble` receives the number of optional records to include and returns the exact
    /// (system, user) pair that would be sent, so the measurement is of the real strings —
    /// no estimate of template overhead, no guessing at per-fact prefixes.
    nonisolated static func fit(optionalCount: Int, outputTokens: Int, contextTokens: Int = 4096,
                                assemble: (Int) -> (system: String, user: String)) -> FittedPrompt? {
        guard optionalCount >= 0 else { return nil }
        var keep = optionalCount
        while true {
            let (system, user) = assemble(keep)
            if promptFits(system: system, user: user, outputTokens: outputTokens,
                          contextTokens: contextTokens) {
                return FittedPrompt(optionalKept: keep, omitted: optionalCount - keep,
                                    userBytes: user.precomposedStringWithCanonicalMapping.utf8.count)
            }
            guard keep > 0 else { return nil }
            keep -= 1
        }
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
        /// Wall-clock milliseconds this request spent at the transport, success or failure.
        /// Callers use it to show elapsed time and to explain a slow turn instead of a spinner
        /// with no information. It is a measured duration, never an estimate.
        var elapsedMilliseconds: Int? = nil

        // Fixed keys/enums and capped integers only. Never interpolate server strings/errors.
        var summary: String {
            "server=\(category?.rawValue ?? "completed") status=\(httpStatus.map(String.init) ?? "unknown") body=\(bodyBytes.map(String.init) ?? "unknown") oversized=\(oversizedBody) text=\(textBytes.map(String.init) ?? "unknown") finish=\(finish.rawValue) prompt=\(promptTokens.map(String.init) ?? "unknown") completion=\(completionTokens.map(String.init) ?? "unknown") malformedUsage=\(malformedUsage) elapsedMs=\(elapsedMilliseconds.map(String.init) ?? "unknown")"
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

    /// The distinct causes a caller must be able to tell apart when a model turn fails.
    /// Every caller renders its own wording, but the CLASSIFICATION lives here so no surface
    /// re-collapses eighteen diagnostic categories into "check the connection" — which is wrong
    /// guidance whenever the server was reached and answered.
    nonisolated enum FailureCause: String, Sendable, CaseIterable {
        case cancelled          // the user or a newer request stopped this one
        case settingsChanged    // model settings moved under a running request
        case networkDenied      // non-loopback access is turned off by policy
        case badSettings        // URL or model ID unusable
        case modelMissing       // server running, requested model absent
        case timedOut           // no answer within the caller's deadline
        case unreachable        // no usable connection to the server
        case serverRejected     // reached and answered, with a non-2xx status
        case tooLarge           // response exceeded what this app will read
        case contextBudget      // prompt did not fit the declared window
        case unfinished         // stopped before completing its answer
        case emptyAnswer        // finished, but said nothing
        case unreadable         // malformed body, or an answer from a different model
        case unknown

        /// True when the server was reached and responded. Callers must NOT tell the user to
        /// check their connection in these cases.
        var serverAnswered: Bool {
            switch self {
            case .serverRejected, .tooLarge, .unfinished, .emptyAnswer, .unreadable, .modelMissing:
                return true
            default:
                return false
            }
        }
    }

    nonisolated static func cause(for diagnostic: Diagnostic) -> FailureCause {
        switch diagnostic.category {
        case .cancelled:                        return .cancelled
        case .obsoleteRequest:                  return .settingsChanged
        case .policyDenied:                     return .networkDenied
        case .invalidConfig:                    return .badSettings
        case .modelMissing, .unsupportedModel:  return .modelMissing
        case .timeout:                          return .timedOut
        case .unavailable, .network, .nonHTTP:  return .unreachable
        case .http:                             return .serverRejected
        case .responseTooLarge:                 return .tooLarge
        case .contextBudget:                    return .contextBudget
        case .incompleteOutput:                 return .unfinished
        case .emptyContent, .missingContent:    return .emptyAnswer
        case .malformedJSON, .responseShape:    return .unreadable
        case .none:                             return .unknown
        }
    }

    /// True when a completion stopped because it hit the output limit rather than finishing.
    ///
    /// Callers that publish a FINANCIAL VERDICT must refuse such an answer: measured 2026-09-10,
    /// the frozen `holdout_01_loss` case came back with finish_reason "length", a P/L cut off
    /// mid-sentence, and a headline figure its own truncated working contradicted. A cut-off
    /// number is not a shorter answer, it is a different one.
    ///
    /// Callers that publish PROSE (conversational Chat) should instead keep the text and tell the
    /// user it was cut off — discarding a long, useful, merely-unfinished reply helps nobody.
    nonisolated static func rejectsTruncatedOutput(_ completion: Completion) -> Bool {
        completion.diagnostic.finish == .tokenLimit
    }

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
        // The budget applies to EVERY backend, not only the LM Studio profile. Before this, the
        // shipped Ollama default dispatched any size of prompt and let the server truncate it
        // silently, so a caller that packed 12,000 bytes into a 4,096-unit window was never told.
        if !promptFits(system: system, user: user, outputTokens: maxTokens, contextTokens: contextTokens) {
            return .failure(.init(diagnostic: .init(category: .contextBudget)))
        }
        let request = chatRequest(c, system: system, user: user, isOllama: isOllama,
                                  maxTokens: maxTokens, contextTokens: contextTokens, timeout: timeout)
        let started = DispatchTime.now()
        func elapsedMilliseconds() -> Int {
            Int((DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000)
        }
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
                // No backend may publish another model's answer under the selected ID. Ollama
                // serves a model as "name:latest" while a viewer types the bare name, so both
                // sides are compared with the suffix stripped. A server that reports no model at
                // all stays acceptable off the strict profile — absent metadata is not a mismatch.
                let identityMismatch = reply.model.map {
                    stripLatestSuffix($0) != stripLatestSuffix(c.model)
                } ?? c.isLMStudio9B
                if identityMismatch {
                    return .failure(.init(diagnostic: .init(category: .responseShape,
                                                            httpStatus: http.statusCode,
                                                            elapsedMilliseconds: elapsedMilliseconds())))
                }
                // Truncation stays OBSERVATIONAL here, as this seam has always documented:
                // `finish` is reported, never used to reject text outside the strict profile.
                // That contract is deliberate and correct — a truncated Chat answer is still
                // worth showing, while a truncated financial verdict is not. The decision
                // therefore belongs to each caller, and lives in `rejectsTruncatedOutput` /
                // `StockSageAIAssessment.validate`, not here.
                if c.isLMStudio9B, reply.diagnostic.finish != .stop {
                    var diagnostic = reply.diagnostic
                    diagnostic.category = .incompleteOutput
                    diagnostic.httpStatus = http.statusCode
                    diagnostic.elapsedMilliseconds = elapsedMilliseconds()
                    return .failure(.init(diagnostic: diagnostic))
                }
                var diagnostic = reply.diagnostic
                diagnostic.httpStatus = http.statusCode
                diagnostic.elapsedMilliseconds = elapsedMilliseconds()
                return .success(.init(text: reply.text, diagnostic: diagnostic, model: reply.model))
            case .failure(let failure):
                var diagnostic = failure.diagnostic
                diagnostic.httpStatus = http.statusCode
                diagnostic.elapsedMilliseconds = elapsedMilliseconds()
                return .failure(.init(diagnostic: diagnostic))
            }
        } catch {
            var failure = transportFailure(error)
            var diagnostic = failure.diagnostic
            diagnostic.elapsedMilliseconds = elapsedMilliseconds()
            failure = .init(diagnostic: diagnostic)
            return .failure(failure)
        }
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
