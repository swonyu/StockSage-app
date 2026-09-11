import Foundation
import Testing
@testable import StockSage

@Suite("Qwen bounded diagnostics", .serialized)
@MainActor
struct StockSageQwenDiagnosticsTests {
    private typealias S = StockSageLocalModelServer
    private typealias A = StockSageAIAssessment
    private let facts = ["Observed price 2000.0 USD; exact value 1125.4624. Date 2026-11-04.", "Revenue 100 USD."]
    private let text = #"{"action":"Hold","reason":"Outlook uncertain (F1).","risk":"A loss remains possible.","evidence":["F1"]}"#
    private let config = S.Config(baseURL: URL(string: "http://127.0.0.1:8765")!, model: "fixture-model")

    private func body(_ text: String, ollama: Bool, finish: Any? = nil, usage: Any? = nil) throws -> Data {
        var object: [String: Any]
        if ollama {
            object = ["message": ["content": text]]
            object["done_reason"] = finish
            if let usage = usage as? [String: Any] { object.merge(usage) { _, new in new } }
        } else {
            var choice: [String: Any] = ["message": ["content": text]]
            choice["finish_reason"] = finish
            object = ["choices": [choice]]
            object["usage"] = usage
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func metadataNeverChangesReturnedTextOrVerdict() throws {
        let expected = A.Verdict(action: .hold, reason: "Outlook uncertain (F1).", risk: "A loss remains possible.", evidence: ["F1"])
        for ollama in [true, false] {
            let usage = ollama ? ["prompt_eval_count": 57, "eval_count": 24] : ["prompt_tokens": 57, "completion_tokens": 24]
            for (finish, classification): (Any?, S.Finish) in [(nil, .absent), (NSNull(), .absent), ("stop", .stop),
                ("length", .tokenLimit), ("tool_calls", .toolCall), ("content_filter", .filtered),
                ("https://private.invalid/SECRET", .unknown), (42, .malformed)] {
                let data = try body(" \n" + text + "\t ", ollama: ollama, finish: finish, usage: usage)
                let result = try S.parseCompletion(data, isOllama: ollama).get()
                #expect(result.text == text && S.parseChatResponse(data, isOllama: ollama) == text)
                #expect(result.diagnostic.finish == classification)
                #expect(result.diagnostic.promptTokens == 57 && result.diagnostic.completionTokens == 24)
                #expect(result.diagnostic.bodyBytes == data.count && result.diagnostic.textBytes == text.utf8.count)
                #expect(!result.diagnostic.malformedUsage)
                #expect(A.parse(result.text, facts: facts) == expected)
                #expect(!result.diagnostic.summary.contains("SECRET") && result.diagnostic.summary.utf8.count < 300)
            }
        }
    }

    @Test func malformedUsageIsDiscardedWithoutRejectingContent() throws {
        let invalid: [Any] = [true, -1, 1.5, "123", [1], ["secret": "fixture"], 16_777_217]
        for ollama in [true, false] {
            for value in invalid {
                let usage = ollama ? ["prompt_eval_count": value, "eval_count": value] : ["prompt_tokens": value, "completion_tokens": value]
                let reply = try S.parseCompletion(body(text, ollama: ollama, usage: usage), isOllama: ollama).get()
                #expect(reply.text == text)
                #expect(reply.diagnostic.promptTokens == nil && reply.diagnostic.completionTokens == nil)
                #expect(reply.diagnostic.malformedUsage)
            }
            let nulls: [String: Any] = ollama ? ["prompt_eval_count": NSNull(), "eval_count": NSNull()]
                : ["prompt_tokens": NSNull(), "completion_tokens": NSNull()]
            let reply = try S.parseCompletion(body(text, ollama: ollama, usage: nulls), isOllama: ollama).get()
            #expect(reply.diagnostic.promptTokens == nil && !reply.diagnostic.malformedUsage)
        }
        for usage: Any in [true, "SECRET", [1]] {
            let reply = try S.parseCompletion(body(text, ollama: false, usage: usage), isOllama: false).get()
            #expect(reply.diagnostic.malformedUsage && reply.text == text)
        }
    }

    @Test func malformedEmptyAndOversizedEnvelopesAreRejected() throws {
        for ollama in [true, false] {
            for (raw, expected): (String, S.FailureCategory) in [("not json", .malformedJSON), ("[]", .responseShape),
                ("{}", .missingContent), (#"{"choices":[]}"#, .missingContent)] {
                let data = Data(raw.utf8)
                guard case .failure(let failure) = S.parseCompletion(data, isOllama: ollama) else {
                    Issue.record("Malformed envelope accepted"); continue
                }
                #expect(failure.diagnostic.category == expected && S.parseChatResponse(data, isOllama: ollama) == nil)
            }
            guard case .failure(let empty) = S.parseCompletion(try body(" \n\t", ollama: ollama), isOllama: ollama) else {
                Issue.record("Empty reply accepted"); continue
            }
            #expect(empty.diagnostic.category == .emptyContent)
            // Resource cap is a transport contract, not a model/strategy output threshold.
            let large = String(repeating: "a", count: 1_048_577)
            let data = try body(large, ollama: ollama)
            guard case .failure(let failure) = S.parseCompletion(data, isOllama: ollama) else {
                Issue.record("Oversized response retained"); continue
            }
            #expect(failure.diagnostic.category == .responseTooLarge && failure.diagnostic.oversizedBody)
            #expect(S.parseChatResponse(data, isOllama: ollama) == nil)
        }
        #expect(S.boundedCount(Int.max) == 16_777_216 && S.boundedCount(-1) == 0)
    }

    @Test func wrongContentShapesNeverUseLaterChoices() {
        for raw in [#"{"choices":[{"message":{"content":null}}]}"#,
                    #"{"choices":[{"message":{"content":42}}]}"#,
                    #"{"choices":[{"message":{"content":["hello"]}}]}"#,
                    #"{"choices":[{}, {"message":{"content":"hello"}}]}"#,
                    #"{"choices":[{"message":{"content":"hello"}},42]}"#] {
            #expect(S.parseChatResponse(Data(raw.utf8), isOllama: false) == nil)
            guard case .failure(let failure) = S.parseCompletion(Data(raw.utf8), isOllama: false) else {
                Issue.record("Wrong content shape accepted"); continue
            }
            #expect(failure.diagnostic.category == .missingContent)
        }
        for raw in [#"{"message":{"content":null}}"#, #"{"message":{"content":42}}"#,
                    #"{"message":{"content":["hello"]}}"#] {
            #expect(S.parseChatResponse(Data(raw.utf8), isOllama: true) == nil)
        }
    }

    @Test func transportFailuresExposeOnlyAllowlistedMetadata() async throws {
        let cases: [(Error, S.FailureCategory)] = [
            (URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "SECRET https://private.invalid"]), .timeout),
            (URLError(.cancelled), .cancelled), (CancellationError(), .cancelled),
            (URLError(.cannotConnectToHost), .network),
            (NSError(domain: "SECRET", code: 42, userInfo: [NSLocalizedDescriptionKey: "SECRET"]), .network)]
        for (error, category) in cases {
            let result = await S.completeDetailed(config, isOllama: false, system: "SECRET", user: "SECRET",
                transport: { _ in throw error })
            guard case .failure(let failure) = result else { Issue.record("Transport error accepted"); continue }
            #expect(failure.diagnostic.category == category)
            #expect(!failure.diagnostic.summary.contains("SECRET") && !failure.diagnostic.summary.contains("https:"))
            #expect(!String(describing: failure.legacyError).contains("SECRET"))
        }
        let nonHTTP = await S.completeDetailed(config, isOllama: true, system: "", user: "", transport: { _ in
            (Data(), URLResponse(url: config.baseURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        })
        guard case .failure(let failure) = nonHTTP else { Issue.record("Non-HTTP accepted"); return }
        #expect(failure.diagnostic.category == .nonHTTP)
    }

    @Test func obsoleteCancelledOrRemoteOfflineRequestsNeverDispatchOrPublish() async throws {
        let data = try body(text, ollama: false)
        for boundary in ["before", "during"] {
            for reason in ["config", "cancel", "remote", "invalidURL"] {
                var valid = boundary != "before", allowed = boundary != "before", calls = 0
                let endpoint = reason == "remote" ? URL(string: "https://fixture.invalid")!
                    : reason == "invalidURL" ? URL(string: "http://user:fixture@127.0.0.1:8765")! : config.baseURL
                let c = S.Config(baseURL: endpoint, model: config.model)
                let task = Task { @MainActor in
                    if reason == "cancel", boundary == "before" { withUnsafeCurrentTask { $0?.cancel() } }
                    return await S.completeDetailed(c, isOllama: false, system: "private facts", user: "fixture",
                        stillValid: { reason != "config" || valid }, externalAllowed: { allowed },
                        transport: { _ in
                            calls += 1
                            await Task.yield()
                            valid = false; allowed = false
                            if reason == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
                            return (data, HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                        })
                }
                let result = await task.value
                #expect(calls == (boundary == "during" && reason != "invalidURL" ? 1 : 0), "Unexpected dispatch: \(boundary) \(reason)")
                #expect((try? result.get()) == nil, "Obsolete result published: \(boundary) \(reason)")
            }
        }
        let local = await S.completeDetailed(config, isOllama: false, system: "", user: "", externalAllowed: { false }, transport: { _ in
            (data, HTTPURLResponse(url: config.baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try local.get().text == text, "Actual loopback inference still works offline")
    }

    @Test func probeCannotContinueFallbackAfterRevocationOrAcceptOversizedBody() async throws {
        for boundary in ["before", "fallback", "publish", "oversized"] {
            var allowed = boundary != "before", calls = 0
            let remote = S.Config(baseURL: URL(string: "https://fixture.invalid")!, model: "fixture")
            let probe = await S.probe(remote, externalAllowed: { allowed }, transport: { request in
                calls += 1
                await Task.yield()
                if boundary != "oversized" { allowed = false }
                let data = boundary == "oversized" ? Data(repeating: 65, count: 262_145)
                    : Data(#"{"models":[{"name":"fixture"}]}"#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: boundary == "fallback" ? 404 : 200,
                                             httpVersion: nil, headerFields: nil)!)
            })
            #expect(!probe.reachable && !probe.hasModel && probe.models.isEmpty)
            #expect(calls == (boundary == "before" ? 0 : boundary == "oversized" ? 2 : 1))
        }
        for status in [200, 500] {
            let result = await S.completeDetailed(config, isOllama: false, system: "", user: "", transport: { request in
                (Data(repeating: 65, count: S.maximumResponseBytes + 1),
                 HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            #expect((try? result.get()) == nil)
            guard case .failure(let error) = result else { continue }
            #expect(error.diagnostic.category == .responseTooLarge && error.diagnostic.oversizedBody)
        }
    }

    @Test func realTransportSeamPreservesRequestAndStatus() async throws {
        for ollama in [true, false] {
            let data = try body(text, ollama: ollama, finish: "length")
            let result = await S.completeDetailed(config, isOllama: ollama, system: "system", user: "user",
                maxTokens: 240, contextTokens: 4096, timeout: 90, transport: { request in
                    #expect(request == S.chatRequest(config, system: "system", user: "user", isOllama: ollama, maxTokens: 240))
                    return (data, HTTPURLResponse(url: config.baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
            let reply = try result.get()
            #expect(reply.text == text && reply.diagnostic.httpStatus == 200 && reply.diagnostic.finish == .tokenLimit)
        }
        for (status, raw, expected): (Int, String, S.FailureCategory) in [
            (404, "model SECRET not found", .modelMissing), (401, "SECRET", .http),
            (404, #"{"error":{"code":"model_not_found","message":"SECRET"}}"#, .modelMissing),
            (400, #"{"error":{"code":"unsupported_model","message":"SECRET"}}"#, .unsupportedModel),
            (500, "SECRET", .http), (307, "SECRET", .http), (200, "SECRET", .malformedJSON)] {
            let result = await S.completeDetailed(config, isOllama: false, system: "", user: "", transport: { _ in
                (Data(raw.utf8), HTTPURLResponse(url: config.baseURL, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            guard case .failure(let failure) = result else { Issue.record("Failure accepted"); continue }
            #expect(failure.diagnostic.category == expected && failure.diagnostic.httpStatus == status)
            #expect(!failure.diagnostic.summary.contains("SECRET"))
        }
    }

    @Test func rejectionClassesPreserveEveryGuard() throws {
        let cases: [(String, A.ValidationFailure)] = [
            (String(repeating: "x", count: 4001), .oversizedText), ("Hold", .malformedJSON), ("[]", .schema),
            ("```json\n" + text + "\n```", .malformedJSON), (text + text, .malformedJSON),
            (text.replacingOccurrences(of: "\"action\":", with: "\"extra\":0,\"action\":"), .schema),
            (text.replacingOccurrences(of: "Hold", with: "Guaranteed Win"), .action),
            (text.replacingOccurrences(of: "\"evidence\":[\"F1\"]", with: "\"evidence\":true"), .fieldType),
            (text.replacingOccurrences(of: "[\"F1\"]", with: "[]"), .emptyEvidence),
            (text.replacingOccurrences(of: "[\"F1\"]", with: "[\"F1\",\"F1\"]"), .duplicateEvidence),
            (text.replacingOccurrences(of: "[\"F1\"]", with: "[\"F1\",\"F2\",\"F3\"]"), .tooManyEvidence),
            (text.replacingOccurrences(of: "F1", with: "F9999"), .unknownEvidence),
            (text.replacingOccurrences(of: "F1", with: "F01"), .unknownEvidence),
            (text.replacingOccurrences(of: "F1", with: "W1"), .unknownEvidence),
            (text.replacingOccurrences(of: "Outlook uncertain (F1).", with: " "), .emptyProse),
            (text.replacingOccurrences(of: "Outlook uncertain (F1).", with: String(repeating: "x", count: 601)), .oversizedProse),
            (text.replacingOccurrences(of: "(F1)", with: "[F1]"), .bracketContent),
            (text.replacingOccurrences(of: "(F1)", with: "<F1>"), .bracketContent),
            (text.replacingOccurrences(of: "(F1)", with: "٩٩"), .nonASCIINumber),
            (text.replacingOccurrences(of: "(F1)", with: "²"), .nonASCIINumber),
            (text.replacingOccurrences(of: "(F1)", with: "(F2)"), .unknownReference),
            (text.replacingOccurrences(of: "(F1)", with: "(W2)"), .unknownReference),
            (text.replacingOccurrences(of: "(F1)", with: "99999"), .foreignNumber),
            (text.replacingOccurrences(of: "(F1)", with: "2000.0"), .unboundNumber),
            (text.replacingOccurrences(of: "A loss remains possible.", with: "A loss of 2000.0 USD is possible."), .unboundNumber)]
        for (input, failure) in cases {
            #expect(A.validate(input, facts: facts) == .failure(failure))
            #expect(A.parse(input, facts: facts) == nil)
        }
        #expect(A.validate(text, facts: []) == .failure(.emptyFacts))
        for count in [-1, 4] { #expect(A.validate(text, facts: facts, leadCount: count) == .failure(.invalidLeadCount)) }
        for number in ["2000", "2,000", "2001", "1125", "1125.46", "FY26", "Nov 4", "Nov 5", "100"] {
            // Formatting fixes are explicitly NOT approved; even value-identical variants still reject.
            let input = text.replacingOccurrences(of: "(F1)", with: number)
            #expect(A.validate(input, facts: facts) == .failure(.foreignNumber))
            #expect(A.parse(input, facts: facts) == nil)
        }
    }

    // MARK: - Numeric tickers are identifiers, not unbound figures (2026-09-11)

    // Tadawul tickers ARE digits (2222.SR = Aramco), and `instructions` orders the model to name
    // the company only by its ticker — so every Saudi assessment used to fail `.unboundNumber` on
    // its own symbol, and the owner-facing reason pointed at the ticker as if it were a price.
    // These pins exist to prove the mask is narrow: it is anchored to THIS idea's full symbol,
    // it runs after the F/W loop and before BOTH number guards, and it disables nothing else.
    @Test func numericTickerIsAnIdentifierNotAnUnboundNumber() {
        // Hand-derived token sets, not read off the code: F1 -> {2222, 2026, 11, 04, 00}; F2 -> {32.10}.
        let saudiFacts = ["Symbol: 2222.SR. Market: Saudi Exchange. Assessment snapshot: 2026-11-04T00:00:00Z.",
                          "Observed quote: 32.10 SAR. Not a live fill quote."]
        func reply(_ reason: String, evidence: String = "[\"F1\"]") -> String {
            "{\"action\":\"Hold\",\"reason\":\"\(reason)\",\"risk\":\"A loss remains possible.\",\"evidence\":\(evidence)}"
        }
        let named = "2222.SR screens weak on the rules alone (F1)."
        let expected = A.Verdict(action: .hold, reason: named,
                                 risk: "A loss remains possible.", evidence: ["F1"])
        // Symbol supplied: the ticker is masked and the verdict publishes the ORIGINAL prose.
        #expect(A.validate(reply(named), facts: saudiFacts, symbol: "2222.SR") == .success(expected))
        #expect(A.parse(reply(named), facts: saudiFacts, symbol: "2222.SR") == expected)
        // Case-insensitive, literal match: a lower-cased ticker is the same identifier.
        #expect(A.parse(reply("2222.sr screens weak on the rules alone (F1)."),
                        facts: saudiFacts, symbol: "2222.SR") != nil)
        // Symbol nil reproduces today's behaviour byte-for-byte; every other call site relies on it.
        #expect(A.validate(reply(named), facts: saudiFacts) == .failure(.unboundNumber))
        // The bare stem is NOT masked: "2222" on its own is still an unbound number.
        #expect(A.validate(reply("2222 screens weak on the rules alone (F1)."),
                           facts: saudiFacts, symbol: "2222.SR") == .failure(.unboundNumber))
        // A DIFFERENT ticker is still foreign — 1120 is absent from F1's tokens, so the FIRST
        // guard fires. A `.unboundNumber` here would mean the mask landed after the foreign guard.
        #expect(A.validate(reply("1120.SR screens weak on the rules alone (F1)."),
                           facts: saudiFacts, symbol: "2222.SR") == .failure(.foreignNumber))
        // Masking the ticker must not let a genuine figure standing beside it through. This is the
        // assertion that proves the fix did not blanket-disable the fence.
        #expect(A.validate(reply("2222.SR trades at 32.10 (F1).", evidence: "[\"F1\",\"F2\"]"),
                           facts: saudiFacts, symbol: "2222.SR") == .failure(.unboundNumber))
        // A letter ticker changes nothing: the whole existing guard matrix stays put.
        #expect(A.validate(text, facts: facts, symbol: "ORCL") == A.validate(text, facts: facts))
    }

    @Test func acceptedVerdictsRetainAllFieldsAndEvidenceOrder() throws {
        for action in ["Strong Buy", "Buy", "Hold", "Avoid", "Reduce", "Sell"] {
            for evidence in [["F1"], ["F2", "F1"]] {
                let reason = "The observed quote alone is not an edge (F1); W1 is unverified."
                let risk = "A loss remains possible."
                let data = try JSONSerialization.data(withJSONObject: ["action": action, "reason": reason, "risk": risk, "evidence": evidence])
                let input = String(decoding: data, as: UTF8.self)
                let expected = A.Verdict(action: TradeAdvice.Action(rawValue: action)!, reason: reason, risk: risk, evidence: evidence)
                #expect(A.validate(input, facts: facts, leadCount: 1) == .success(expected))
                #expect(A.parse(input, facts: facts, leadCount: 1) == expected)
            }
        }
    }

    @Test func tokenLimitAndMalformedContentAreIndependent() throws {
        let badText = #"{"action":"Hold""#
        let reply = S.parseCompletion(try body(badText, ollama: false, finish: "length"), isOllama: false)
        let summary = StockSageAIAssessments.failureSummary(reply, facts: facts, leadCount: 0)
        #expect(summary.contains("validation=malformedJSON") && summary.contains("finish=tokenLimit"))
        #expect(!summary.contains(badText))
        let valid = S.parseCompletion(try body(text, ollama: false, finish: "length"), isOllama: false)
        #expect(StockSageAIAssessments.failureSummary(valid, facts: facts, leadCount: 0).contains("validation=accepted"))
    }
}
