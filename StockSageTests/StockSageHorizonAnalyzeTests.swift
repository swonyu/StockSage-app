import Testing
import Foundation
@testable import StockSage

// The real horizon-research model path (2026-09-10).
//
// `analyze()` owns the evidence budget, the freshness gates and the verdict acceptance, and it
// previously had NO test: every existing horizon test injects a synthetic `analyze:` closure, so
// the production function was never executed. Both of its network calls now take the same
// optional transport seam `fetchUniverse` and `completeDetailed` already had, so the whole path
// runs offline here. No live network, no real model, no clock dependence beyond `Date()`.
@Suite("Horizon research — the real analyze() path")
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
                     allowed: @escaping @MainActor () -> Bool = { true },
                     model: @escaping (URLRequest) async throws -> (Data, URLResponse)
                     ) async -> Research.Result {
        let config = Server.config(url: Server.defaultURL, model: Server.defaultModel)!
        // Isolated defaults: never the real parent-app preference domain.
        let defaults = UserDefaults(suiteName: "stocksage.horizon.analyze.\(UUID().uuidString)")!
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        return await Research.analyze(
            listing, horizon: .week, store: store, config: config,
            isOllama: true, key: "fixture-key", allowed: allowed,
            historyTransport: { request in
                (history, HTTPURLResponse(url: request.url!, statusCode: historyStatus,
                                          httpVersion: nil, headerFields: nil)!)
            },
            modelTransport: model)
    }

    // MARK: The path runs, and what it sends is bounded

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
        #expect(!sentUser.isEmpty, "analyze() never reached the model")
        #expect(Server.promptFits(system: sentSystem, user: sentUser,
                                  outputTokens: Research.researchOutputTokens,
                                  contextTokens: Server.researchContextTokens),
                "analyze() sent a prompt that exceeds its own declared budget")
        #expect(result.model == Server.defaultModel)
        #expect(!result.facts.isEmpty)
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
    }

    @Test func aModelFailureYieldsNoOpinionAndSaysSo() async throws {
        let result = await run(model: { _ in throw URLError(.timedOut) })
        #expect(result.verdict == nil)
        #expect(result.note.localizedCaseInsensitiveContains("no verified opinion"))
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
    }

    // MARK: Gates that must stop the request before it ever reaches the model

    @Test func aNonUSDListingIsNeverAnalysed() async throws {
        var called = false
        let result = await run(listing: Self.listing(currency: "eur"),
                               model: { called = true; return Self.ok(Self.verdictPayload(), $0) })
        #expect(!called, "a non-USD listing reached the model")
        #expect(result.verdict == nil)
        #expect(result.note.localizedCaseInsensitiveContains("usd"))
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

