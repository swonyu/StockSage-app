import Testing
import Foundation
@testable import StockSage

// The real horizon-research model path (2026-09-10).
//
// `analyze()` owns the evidence budget, the freshness gates and the verdict acceptance, and it
// previously had NO test: every existing horizon test injects a synthetic `analyze:` closure, so
// the production function was never executed.
//
// WHY ALL FOUR SEAMS ARE INJECTED, not just the two transports: `StockSageBenzingaClient.shared`
// and `StockSageNewsService` are singletons that consult the real web gate and the real
// credentials. MEASURED 2026-09-10 on this machine — with only the transports injected, a run of
// this suite came back with `isExternalAllowed=true`, a non-empty Massive key, and seven Benzinga
// pages "answered". It was issuing real requests against the owner's PAID account on every run.
// Injecting the evidence closures makes that structurally impossible rather than relying on a
// process-global gate that another suite can reopen mid-test.
//
// So: no live network, no real model, no paid request, no dependence on any mutable global.
@Suite("Horizon research — the real analyze() path", .serialized)
@MainActor
struct StockSageHorizonAnalyzeTests {

    typealias Research = StockSageHorizonResearch
    typealias Server = StockSageLocalModelServer

    // MARK: Fixtures

    /// A Massive daily-aggregate payload with enough completed prior-day bars to pass the
    /// 30-bar / four-day-recency gate. Prices trend gently so indicators are well defined.
    private static func historyPayload(bars: Int = 90, endingDaysAgo: Int = 1) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let lastDay = calendar.date(byAdding: .day, value: -endingDaysAgo,
                                    to: calendar.startOfDay(for: Date()))!
        var rows: [[String: Any]] = []
        for index in 0..<bars {
            let day = calendar.date(byAdding: .day, value: -(bars - 1 - index), to: lastDay)!
            // Midday New York so the bar lands unambiguously inside its own session date.
            let stamp = calendar.date(byAdding: .hour, value: 13, to: day)!
            let close = 40.0 + Double(index) * 0.10
            rows.append(["t": Int(stamp.timeIntervalSince1970 * 1_000),
                         "o": close - 0.20, "h": close + 0.35, "l": close - 0.40,
                         "c": close, "v": 1_500_000 + Double(index) * 1_000])
        }
        return try! JSONSerialization.data(withJSONObject: [
            "status": "OK", "ticker": "ACME", "adjusted": true,
            "resultsCount": rows.count, "results": rows,
        ])
    }

    private static func listing(_ ticker: String = "ACME", currency: String? = "usd") -> Research.Listing {
        Research.Listing(ticker: ticker, name: "ACME Corporation", market: "stocks", locale: "us",
                         active: true, type: "CS", currency_name: currency,
                         primary_exchange: "XNAS")
    }

    private static func ok(_ data: Data, _ request: URLRequest) -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    /// A well-formed four-key verdict citing the first offered fact.
    private static func verdictPayload(action: String = "Hold") -> Data {
        let json = #"{"evidence":["F1"],"action":"\#(action)","reason":"qualitative case","risk":"qualitative counter-case"}"#
        return try! JSONSerialization.data(withJSONObject: [
            "model": Server.defaultModel,
            "message": ["content": json],
            "done_reason": "stop",
        ])
    }

    private func run(listing: Research.Listing = StockSageHorizonAnalyzeTests.listing(),
                     history: Data = StockSageHorizonAnalyzeTests.historyPayload(),
                     historyStatus: Int = 200,
                     isOllama: Bool = true,
                     allowed: @escaping @MainActor () -> Bool = { true },
                     model: @escaping (URLRequest) async throws -> (Data, URLResponse)
                     ) async -> Research.Result {
        let config = Server.config(url: isOllama ? Server.defaultURL : Server.lmStudioURL,
                                   model: isOllama ? Server.defaultModel : Server.lmStudioModel)!
        // Isolated defaults: never the real parent-app preference domain.
        let suiteName = "stocksage.horizon.analyze.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create an isolated defaults suite"); return .init(note: "unavailable")
        }
        // The repo's convention: never leave a persistent domain behind on disk.
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        return await Research.analyze(
            listing, horizon: .week, store: store, config: config,
            isOllama: isOllama, key: "fixture-key", allowed: allowed,
            historyTransport: { request in
                (history, HTTPURLResponse(url: request.url!, statusCode: historyStatus,
                                          httpVersion: nil, headerFields: nil)!)
            },
            modelTransport: model,
            // Synthetic evidence: no client, no credential, no request.
            benzingaSnapshot: { symbol, at in
                StockSageBenzinga.Snapshot(symbol: symbol, capturedAt: at,
                                           credentialGeneration: nil, pages: [])
            },
            newsObservation: { _, _, _ in StockSageNewsService.Observation(attempts: []) },
            evidenceIsCurrent: { _ in true })
    }

    // MARK: The path runs, and what it sends is bounded

    @Test func lmStudioResearchConstrainsTheRequiredAnswerShape() async throws {
        var dispatched = false
        _ = await run(isOllama: false, model: { request in
            dispatched = true
            let object = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let format = try #require(object["response_format"] as? [String: Any])
            #expect(format["type"] as? String == "json_schema")
            let specification = try #require(format["json_schema"] as? [String: Any])
            let schema = try #require(specification["schema"] as? [String: Any])
            #expect(Set(schema["required"] as? [String] ?? []) == ["evidence", "action", "reason", "risk"])
            #expect(schema["additionalProperties"] as? Bool == false)
            let properties = try #require(schema["properties"] as? [String: Any])
            let evidence = try #require(properties["evidence"] as? [String: Any])
            let items = try #require(evidence["items"] as? [String: Any])
            let ids = try #require(items["enum"] as? [String])
            #expect(ids.first == "F1" && !ids.contains("W1"))
            let reason = try #require(properties["reason"] as? [String: Any])
            #expect(reason["type"] as? String == "string")
            #expect(reason["minLength"] as? Int == 1)
            #expect(reason["maxLength"] as? Int == 600)
            #expect(reason["pattern"] == nil) // Swift validates numeral scripts and offered F/W references.
            let messages = try #require(object["messages"] as? [[String: String]])
            #expect(messages.contains { $0["role"] == "system" && ($0["content"]?.contains("ANY script") ?? false) })
            throw URLError(.cancelled) // No inventory or real network needed for this request-boundary test.
        })
        #expect(dispatched)
    }

    @Test func missingEvidenceIsRepairedWithoutChangingTheOpinion() async throws {
        var calls = 0
        let draft = #"{"action":"Hold","reason":"qualitative case","risk":"qualitative counter-case"}"#
        let result = await run(model: { request in
            calls += 1
            if calls == 1 {
                return Self.ok(try JSONSerialization.data(withJSONObject: ["model": Server.defaultModel,
                    "message": ["content": draft], "done_reason": "stop"]), request)
            }
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: String]])
            #expect(messages.last?["content"]?.contains("Copy action, reason and risk EXACTLY") == true)
            return Self.ok(Self.verdictPayload(), request)
        })
        #expect(calls == 2)
        #expect(result.verdict?.action == .hold)
        #expect(result.referenceClose != nil, "A valid daily close is independent of the opinion or its scenario levels")
        #expect(result.verdict?.reason == "qualitative case")
    }

    @Test(arguments: ["changed action", "changed prose", "numeric claim", "cancelled"])
    func recoveryCannotLaunderAnInvalidOrObsoleteOpinion(_ scenario: String) async throws {
        var calls = 0, allowed = true
        let reason = scenario == "numeric claim" ? "Expected profit 999%" : "qualitative case"
        let draft = try JSONSerialization.data(withJSONObject: ["action": "Hold", "reason": reason,
                                                               "risk": "qualitative counter-case"])
        let result = await run(allowed: { allowed }, model: { request in
            calls += 1
            if calls == 1 {
                if scenario == "cancelled" { allowed = false }
                return Self.ok(try JSONSerialization.data(withJSONObject: ["model": Server.defaultModel,
                    "message": ["content": String(decoding: draft, as: UTF8.self)], "done_reason": "stop"]), request)
            }
            let repaired = try JSONSerialization.data(withJSONObject: ["evidence": ["F1"],
                "action": scenario == "changed action" ? "Buy" : "Hold",
                "reason": scenario == "changed prose" ? "rewritten case" : "qualitative case",
                "risk": "qualitative counter-case"])
            return Self.ok(try JSONSerialization.data(withJSONObject: ["model": Server.defaultModel,
                "message": ["content": String(decoding: repaired, as: UTF8.self)], "done_reason": "stop"]), request)
        })
        #expect(result.verdict == nil)
        #expect(calls == ((scenario == "numeric claim" || scenario == "cancelled") ? 1 : 2))
        if scenario != "cancelled" {
            #expect(result.referenceClose != nil, "Rejected opinions must not erase the observed daily close")
        }
    }

    @Test func theRealPathProducesAResultAndNeverSendsAnOversizedPrompt() async throws {
        var sentSystem = "", sentUser = ""
        let result = await run(model: { request in
            let body = try #require(request.httpBody)
            let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(object["messages"] as? [[String: String]])
            sentSystem = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
            sentUser = messages.first(where: { $0["role"] == "user" })?["content"] ?? ""
            // The declared window must be the research one, not the interactive 4k default.
            let options = object["options"] as? [String: Any]
            #expect(options?["num_ctx"] as? Int == Server.researchContextTokens)
            return Self.ok(Self.verdictPayload(), request)
        })
        // An oversized prompt is rejected at the seam, so a budget failure also surfaces here.
        #expect(!sentUser.isEmpty, "analyze() never reached the model")
        // Note what this does and does not prove: `completeDetailed` already gates dispatch on
        // exactly this predicate with exactly these arguments, so it cannot fail independently
        // once the prompt arrived. It pins the invariant, not the packing. The packing is covered
        // by `bothResearchCallersFitAFullTwelveKilobyteEvidenceSet`.
        #expect(Server.promptFits(system: sentSystem, user: sentUser,
                                  outputTokens: Research.researchOutputTokens,
                                  contextTokens: Server.researchContextTokens))
        #expect(result.model == Server.defaultModel)
        #expect(!result.facts.isEmpty)
        #expect(result.validationOutcome == .validated)
        #expect(result.validationFailure == nil)
    }

    // The horizon facts define the requested holding period and the reference entry. They are
    // mandatory and must reach the model even when optional evidence has to be trimmed.
    @Test func theRequestedHorizonAlwaysReachesTheModel() async throws {
        var sentUser = ""
        _ = await run(model: { request in
            let object = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
            let messages = object?["messages"] as? [[String: String]]
            sentUser = messages?.first(where: { $0["role"] == "user" })?["content"] ?? ""
            return Self.ok(Self.verdictPayload(), request)
        })
        #expect(sentUser.contains(Research.Horizon.week.rawValue))
        #expect(sentUser.localizedCaseInsensitiveContains("Research only"))
    }

    // MARK: Honest failure, never a fabricated opinion

    @Test func aTruncatedVerdictIsRefusedRatherThanPublished() async throws {
        let truncated = try! JSONSerialization.data(withJSONObject: [
            "model": Server.defaultModel,
            "message": ["content": #"{"evidence":["F1"],"action":"Buy","reason":"cut off mid"#],
            "done_reason": "length",
        ])
        let result = await run(model: { Self.ok(truncated, $0) })
        #expect(result.verdict == nil, "a truncated answer became a published opinion")
        #expect(result.note.localizedCaseInsensitiveContains("output limit"))
        #expect(result.validationOutcome == .unknown)
        #expect(result.validationFailure == nil)
    }

    @Test func aModelFailureYieldsNoOpinionAndSaysSo() async throws {
        let result = await run(model: { _ in throw URLError(.timedOut) })
        #expect(result.verdict == nil)
        #expect(result.note.localizedCaseInsensitiveContains("no verified opinion"))
        #expect(result.validationOutcome == .unknown)
        #expect(result.validationFailure == nil)
    }

    @Test func anInvalidNumericClaimIsMarkedRejectedWithTheValidatorReason() async throws {
        let invalid = try! JSONSerialization.data(withJSONObject: [
            "model": Server.defaultModel,
            "message": ["content": #"{"evidence":["F1"],"action":"Hold","reason":"Expected profit 999%","risk":"The setup can reverse."}"#],
            "done_reason": "stop",
        ])
        let result = await run(model: { Self.ok(invalid, $0) })
        #expect(result.verdict == nil)
        #expect(result.validationOutcome == .rejected)
        #expect(result.validationFailure == StockSageAIAssessment.ValidationFailure.foreignNumber.rawValue)
    }

    @Test func anUnparseableAnswerYieldsNoOpinion() async throws {
        let garbage = try! JSONSerialization.data(withJSONObject: [
            "model": Server.defaultModel,
            "message": ["content": "I think you should buy it."],
            "done_reason": "stop",
        ])
        let result = await run(model: { Self.ok(garbage, $0) })
        #expect(result.verdict == nil)
        #expect(result.note.localizedCaseInsensitiveContains("no verified opinion"))
        #expect(result.validationOutcome == .rejected)
        #expect(result.validationFailure == StockSageAIAssessment.ValidationFailure.malformedJSON.rawValue)
    }

    // MARK: Gates that must stop the request before it ever reaches the model

    @Test func aNonUSDListingIsNeverAnalysed() async throws {
        var called = false
        let result = await run(listing: Self.listing(currency: "eur"),
                               model: { called = true; return Self.ok(Self.verdictPayload(), $0) })
        #expect(!called, "a non-USD listing reached the model")
        #expect(result.verdict == nil)
        #expect(result.note.localizedCaseInsensitiveContains("usd"))
        #expect(result.validationOutcome == .unknown)
        #expect(result.validationFailure == nil)
    }

    @Test func anUnsupportedTickerIsNeverAnalysed() async throws {
        var called = false
        let result = await run(listing: Self.listing("not a ticker"),
                               model: { called = true; return Self.ok(Self.verdictPayload(), $0) })
        #expect(!called)
        #expect(result.verdict == nil)
    }

    // Stale or missing history must not be turned into an opinion: this is the look-ahead and
    // freshness boundary, and it has to fail closed.
    @Test func staleOrMissingHistoryIsRefusedBeforeTheModel() async throws {
        var called = false
        // Bars that stop well over four days ago.
        let stale = Self.historyPayload(bars: 90, endingDaysAgo: 30)
        let staleResult = await run(history: stale,
                                    model: { called = true; return Self.ok(Self.verdictPayload(), $0) })
        #expect(!called, "stale history reached the model")
        #expect(staleResult.verdict == nil)

        called = false
        let shortResult = await run(history: Self.historyPayload(bars: 5),
                                    model: { called = true; return Self.ok(Self.verdictPayload(), $0) })
        #expect(!called, "a too-short history reached the model")
        #expect(shortResult.verdict == nil)

        called = false
        let httpFailure = await run(historyStatus: 500,
                                    model: { called = true; return Self.ok(Self.verdictPayload(), $0) })
        #expect(!called, "a failed history request reached the model")
        #expect(httpFailure.verdict == nil)
        #expect(httpFailure.note.localizedCaseInsensitiveContains("history"))
    }

    // A revoked permission or a changed setting mid-flight must abandon the request, not
    // publish an opinion formed under the old conditions.
    @Test func revokedPermissionStopsTheRequest() async throws {
        var called = false
        let result = await run(allowed: { false },
                               model: { called = true; return Self.ok(Self.verdictPayload(), $0) })
        #expect(!called, "a disallowed request reached the model")
        #expect(result.verdict == nil)
    }

    // MARK: Research only — this path must never create an order or a position

    @Test func aBuyVerdictProducesResearchLevelsAndNoOrder() async throws {
        let result = await run(model: { Self.ok(Self.verdictPayload(action: "Buy"), $0) })
        let verdict = try #require(result.verdict)
        #expect(verdict.action.rawValue == "Buy")
        // Levels are reference research output, explicitly not an order.
        #expect(result.note.localizedCaseInsensitiveContains("no order"))
        #expect(result.note.localizedCaseInsensitiveContains("unvalidated"))
    }
}
