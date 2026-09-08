import Foundation

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

    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

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

    static let defaultURL = "http://127.0.0.1:11434"
    static let defaultModel = "qwen3.8"

    // MARK: Config

    struct Config: Sendable, Equatable {
        let baseURL: URL
        let model: String
    }

    /// Validates and normalizes the two raw settings strings into a `Config`, or `nil` when
    /// either is unusable. Trims whitespace from both; the URL must parse with an http/https
    /// scheme and a non-empty host (so "ftp://x" and a bare "x" both fail); a trailing slash on
    /// the URL is stripped so `baseURL.absoluteString` + "/api/tags" never doubles up. The model
    /// must be non-empty after trimming.
    nonisolated static func config(url: String, model: String) -> Config? {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return nil }
        var trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmedURL.hasSuffix("/") { trimmedURL.removeLast() }
        guard let parsed = URL(string: trimmedURL),
              let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parsed.host, !host.isEmpty else { return nil }
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

    private static func fetchJSONObject(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    /// 1) Ollama's `/api/tags` ; on failure 2) an OpenAI-compatible `/v1/models`. Never throws —
    /// an unreachable server, a malformed body, or a timeout all come back as
    /// `reachable: false`, never as a thrown error the caller has to handle.
    static func probe(_ c: Config) async -> Probe {
        if let tags = await fetchJSONObject(c.baseURL.appendingPathComponent("api/tags")),
           let rawModels = tags["models"] as? [[String: Any]] {
            let names = rawModels.compactMap { $0["name"] as? String }
            let hasModel = names.contains { stripLatestSuffix($0) == stripLatestSuffix(c.model) }
            let list = names.map(stripLatestSuffix)
            let detail = hasModel
                ? "Reachable · Ollama · model \(c.model) present"
                : "Reachable · Ollama · model \(c.model) NOT found (have: \(list.isEmpty ? "none" : list.joined(separator: ", ")))"
            return Probe(reachable: true, isOllama: true, models: list, hasModel: hasModel, detail: detail)
        }
        if let openAI = await fetchJSONObject(c.baseURL.appendingPathComponent("v1/models")),
           let rawData = openAI["data"] as? [[String: Any]] {
            let ids = rawData.compactMap { $0["id"] as? String }
            let hasModel = ids.contains { stripLatestSuffix($0) == stripLatestSuffix(c.model) }
            let detail = hasModel
                ? "Reachable · OpenAI-compatible · model \(c.model) present"
                : "Reachable · OpenAI-compatible · model \(c.model) NOT found (have: \(ids.isEmpty ? "none" : ids.joined(separator: ", ")))"
            return Probe(reachable: true, isOllama: false, models: ids, hasModel: hasModel, detail: detail)
        }
        return Probe(reachable: false, isOllama: false, models: [], hasModel: false,
                     detail: "Unreachable: could not reach \(c.baseURL.absoluteString)")
    }

    // MARK: Chat

    /// Builds the POST request for one chat turn — Ollama's native `/api/chat` (with
    /// `"think": false`, matching the owner's smoke test: Ollama defaults qwen3.8 to emitting a
    /// `<think>` block first, which both wastes the 90 s budget and is not the paragraph we want)
    /// or an OpenAI-compatible `/v1/chat/completions`. Short explanations keep the 4k/90s
    /// defaults; conversational Chat supplies its larger context and timeout. OpenAI-compatible
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
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Ollama's shape is `{"message":{"content":...}}`; OpenAI's is
    /// `{"choices":[{"message":{"content":...}}]}`. `nil` on any shape mismatch (including
    /// garbage that isn't even JSON) or a content string that's empty once trimmed.
    nonisolated static func parseChatResponse(_ data: Data, isOllama: Bool) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let content: String?
        if isOllama {
            content = (obj["message"] as? [String: Any])?["content"] as? String
        } else {
            let firstChoice = (obj["choices"] as? [[String: Any]])?.first
            content = (firstChoice?["message"] as? [String: Any])?["content"] as? String
        }
        guard let content else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    enum ServerError: Error, Equatable, Sendable {
        case invalidConfig
        case unreachable(String)
        case modelMissing(String)
        case badResponse(String)
    }

    /// One chat turn against the local server. Ephemeral/no redirects, never throws — every failure
    /// mode (a dropped connection, a non-2xx status, a body that doesn't parse) comes back as a
    /// `.failure(ServerError)` the caller renders as a human sentence.
    static func complete(_ c: Config, isOllama: Bool, system: String, user: String,
                         maxTokens: Int = 170, contextTokens: Int = 4096,
                         timeout: TimeInterval = 90) async -> Swift.Result<String, ServerError> {
        let request = chatRequest(c, system: system, user: user, isOllama: isOllama,
                                  maxTokens: maxTokens, contextTokens: contextTokens, timeout: timeout)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.badResponse("No HTTP response from the server"))
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                if bodyText.lowercased().contains("not found") {
                    return .failure(.modelMissing("Server reports model \(c.model) not found (HTTP \(http.statusCode))"))
                }
                return .failure(.badResponse("HTTP \(http.statusCode)"))
            }
            guard let text = parseChatResponse(data, isOllama: isOllama) else {
                return .failure(.badResponse("Could not parse a response from the server"))
            }
            return .success(text)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }
}
