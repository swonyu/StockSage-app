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
        var lastDay = calendar.date(byAdding: .day, value: -endingDaysAgo,
                                   to: calendar.startOfDay(for: Date()))!
        // A normal successful fixture ends at a real completed session, including when
        // this suite runs on Monday or after a market holiday. The stale fixture stays stale.
        if endingDaysAgo == 1 {
            for _ in 0..<8 {
                if StockSageMarketHours.nasdaqDay(at: lastDay)?.trading == true { break }
                lastDay = calendar.date(byAdding: .day, value: -1, to: lastDay)!
            }
        }
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
                     horizon: Research.Horizon = .week,
                     allowed: @escaping @MainActor () -> Bool = { true },
                     supplemental: ((String, Date) async -> StockSageBenzinga.Snapshot)? = nil,
                     news: @escaping (Date) -> StockSageNewsService.Observation = { _ in .init(attempts: []) },
                     company: [StockSageMassiveEvents.Feed: StockSageMassiveEvents.Observation] = [:],
                     earningsReceipt: ((String, Date) async -> StockSageMassiveEarnings.Observation)? = nil,
                     next: @escaping (String, Date) async -> StockSageCatalystChain.Answer<StockSageMassiveEarnings.Row?> = { _, _ in .unavailable },
                     filings: @escaping (String, Date) async -> StockSageDisclosureService.FilingsObservation = { _, at in .init(checkedAt: at, outcome: .unavailable(.unreachable), filings: []) },
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
            listing, horizon: horizon, store: store, config: config,
            isOllama: isOllama, key: "fixture-key", allowed: allowed, companyObservations: company,
            historyTransport: { request in
                (history, HTTPURLResponse(url: request.url!, statusCode: historyStatus,
                                          httpVersion: nil, headerFields: nil)!)
            },
            modelTransport: model,
            // Synthetic evidence: no client, no credential, no request.
            benzingaSnapshot: { symbol, at in
                if let supplemental { return await supplemental(symbol, at) }
                return StockSageBenzinga.Snapshot(symbol: symbol, capturedAt: at,
                                           credentialGeneration: nil, pages: [])
            },
            newsObservation: { _, at, _ in news(at) },
            nextEarnings: { symbol, at in
                if let earningsReceipt { return await earningsReceipt(symbol, at) }
                switch await next(symbol, at) {
                case .answered(let row): return .init(outcome: .answered(row), checkedAt: at, recordedAt: at)
                case .unavailable: return .init(outcome: .unavailable, checkedAt: at, recordedAt: at)
                }
            }, filingsObservation: filings,
            evidenceIsCurrent: { _ in true })
    }

    @Test func oneCaptureSuppliesTwoDistinctHorizonsAndRejectsChangedOwnershipOrClock() async throws {
        let name = "stocksage.research.capture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        var historyCalls = 0, newsCalls = 0, earningsCalls = 0, filingsCalls = 0, snapshotCalls = 0
        let gathered = await Research.gather(Self.listing(), store: store, key: "fixture", allowed: { true },
            historyTransport: { historyCalls += 1; return Self.ok(Self.historyPayload(), $0) },
            benzingaSnapshot: { symbol, at in snapshotCalls += 1; return .init(symbol: symbol, capturedAt: at, credentialGeneration: nil, pages: []) },
            newsObservation: { _, _, _ in newsCalls += 1; return .init(attempts: []) },
            nextEarnings: { _, at in earningsCalls += 1; return .init(outcome: .answered(nil), checkedAt: at, recordedAt: at) },
            filingsObservation: { _, at in filingsCalls += 1; return .init(checkedAt: at, outcome: .answered, filings: []) },
            evidenceIsCurrent: { _ in true })
        guard case .captured(let capture) = gathered else { Issue.record("Expected isolated capture"); return }
        #expect(historyCalls == 1 && newsCalls == 1 && earningsCalls == 1 && filingsCalls == 1 && snapshotCalls == 1)
        let config = try #require(Server.config(url: Server.defaultURL, model: Server.defaultModel))
        var prompts: [String] = [], results: [Research.Result] = []
        for horizon in Research.Horizon.allCases {
            results.append(await Research.assess(capture, horizon: horizon, config: config, isOllama: true, allowed: { true },
                modelTransport: { request in prompts.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self)); return Self.ok(Self.verdictPayload(), request) },
                evidenceIsCurrent: { _ in true }))
        }
        #expect(prompts.count == 2 && prompts[0].contains("1–7 trading days") && prompts[1].contains("7–14 trading days"))
        #expect(results.allSatisfy { $0.verdict != nil && $0.at == capture.at && $0.referenceClose?.at == capture.referenceClose.at })
        #expect(results[0].coverage == results[1].coverage && historyCalls == 1)
        let staleOwner = await Research.assess(capture, horizon: .fortnight, config: config, isOllama: true, allowed: { true },
            modelTransport: { Issue.record("Obsolete evidence cannot reach the model"); return Self.ok(Self.verdictPayload(), $0) }, evidenceIsCurrent: { _ in false })
        #expect(staleOwner.verdict == nil)
        #expect(!capture.isFresh(at: capture.at.addingTimeInterval(301)))
        #expect(!capture.isFresh(at: capture.at.addingTimeInterval(-1)))
        #expect(!capture.isFresh(at: capture.context.asOf.addingTimeInterval(-0.001)))
    }

    @Test(arguments: [false, true]) func companyFallbackDistinguishesFreshFromStaleDuringThrottle(stale: Bool) async throws {
        var calls = 0
        let result = await run(supplemental: { symbol, at in .init(symbol: symbol, capturedAt: at, credentialGeneration: nil, pages: [
            .init(query: .init(product: .news, subject: symbol, from: nil, through: nil), checkedAt: at, credentialGeneration: nil,
                status: .unavailable(.throttled), records: [], excludedCount: 0, hasMore: false)]) },
            company: [.insider: .init(symbol: "ACME", feed: .insider,
                checkedAt: Date().addingTimeInterval(stale ? -172_800 : -1), outcome: .answered, event: nil)],
            model: { calls += 1; return Self.ok(Self.verdictPayload(), $0) })
        #expect(calls == (stale ? 0 : 1))
        #expect((result.verdict == nil) == stale)
    }

    @Test func coverageKeepsMixedNewsPartialAndUniqueCompanyFamilies() async throws {
        let at = Date().addingTimeInterval(-1)
        let result = await run(news: { _ in .init(attempts: [
            .init(provider: .benzinga, checkedAt: at, status: .answered),
            .init(provider: .massive, checkedAt: at.addingTimeInterval(0.1), status: .unavailable(.transport))]) },
            company: [.insider: .init(symbol: "ACME", feed: .insider, checkedAt: at, outcome: .answered, event: nil)],
            model: { Self.ok(Self.verdictPayload(), $0) })
        let news = try #require(result.coverage.first { $0.source == "Recent news" })
        #expect(news.state == .partial && news.checkedAt == at)
        #expect(result.coverage.filter { $0.source == "Massive/SEC Form 4" }.count == 1)
        #expect(result.coverage.first { $0.source == "Massive/SEC Form 4" }?.state == .answered)
        #expect(result.coverage.first { $0.source == "Massive dividends" }?.state == .unchecked)
    }

    @Test func suppressedEarningsDoesNotInventANewProviderCheck() async throws {
        let origin = Date().addingTimeInterval(-30)
        let result = await run(earningsReceipt: { _, at in .init(outcome: .notRequested, checkedAt: nil, recordedAt: at,
            notRequestedReason: .priorAuthenticationRejection(checkedAt: origin)) }, model: { Self.ok(Self.verdictPayload(), $0) })
        let coverage = try #require(result.coverage.first { $0.source == "Next earnings" })
        #expect(coverage.state == .unchecked && coverage.checkedAt == nil)
        #expect(result.facts.contains { $0.contains("not requested") && $0.contains(origin.ISO8601Format()) })
    }

    @Test func historicalLiquidityAndGapsStayIndependentOnOverflow() {
        func history(closes: [Double], opens: [Double], volumes: [Double]) -> StockSagePriceHistory {
            .init(symbol: "ACME", dates: [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 200), Date(timeIntervalSince1970: 300)],
                opens: opens, highs: opens, lows: closes, closes: closes, volumes: volumes, priceSource: .massiveDaily)
        }
        let ordinary = Research.historicalFacts(history(closes: [100,100,100], opens: [100,200,50], volumes: [10,10,10]))
        #expect(ordinary.contains { $0.contains("1000.0 USD") })
        #expect(ordinary.contains { $0.contains("mean absolute 75.0%") && $0.contains("largest absolute 100.0%") })
        let overflow = Research.historicalFacts(history(closes: [100,100,100], opens: [100,200,50], volumes: [.greatestFiniteMagnitude,10,10]))
        #expect(overflow.count == 1 && overflow[0].hasPrefix("Historical open-to-prior-close gaps"))
        let gapOverflow = Research.historicalFacts(history(closes: [.leastNonzeroMagnitude,100,100], opens: [100,.greatestFiniteMagnitude,50], volumes: [10,10,10]))
        #expect(gapOverflow.count == 1 && gapOverflow[0].hasPrefix("Historical average daily dollar volume"))
    }

    @Test func independentEarningsAndSECChecksKeepDatesAndDoNotClaimDocumentContents() async throws {
        let future = Date().addingTimeInterval(7 * 86_400)
        var earningsCalls = 0, filingsCalls = 0
        let result = await run(next: { symbol, _ in
            earningsCalls += 1; #expect(symbol == "ACME")
            return .answered(.init(date: future, confirmed: false))
        }, filings: { symbol, at in
            filingsCalls += 1; #expect(symbol == "ACME")
            return .init(checkedAt: at, outcome: .answered,
                filings: [.init(accessionNumber: "0000000001-26-000001", form: "8-K", filingDate: at.addingTimeInterval(-86_400),
                    acceptedAt: at.addingTimeInterval(-82_000), items: ["2.02"], documentURL: nil)])
        }, model: { Self.ok(Self.verdictPayload(), $0) })
        #expect(earningsCalls == 1 && filingsCalls == 1 && result.verdict != nil)
        let facts = result.facts.joined(separator: "\n")
        #expect(facts.contains(future.ISO8601Format()) && facts.contains("projected, not announced"))
        #expect(facts.contains("0000000001-26-000001") && facts.contains("not retrieved filing documents"))
        #expect(result.coverage.first { $0.source == "Next earnings" }?.state == .answered)
        #expect(result.coverage.first { $0.source == "SEC submissions metadata" }?.state == .answered)
    }

    @Test func providerEmptyIsAnsweredAndRevocationStopsLaterDependencies() async throws {
        var allowed = true, filingsCalls = 0, modelCalls = 0
        _ = await run(allowed: { allowed }, next: { _, _ in allowed = false; return .answered(nil) },
            filings: { _, at in filingsCalls += 1; return .init(checkedAt: at, outcome: .answered, filings: []) },
            model: { modelCalls += 1; return Self.ok(Self.verdictPayload(), $0) })
        #expect(filingsCalls == 0 && modelCalls == 0)
        let empty = await run(next: { _, _ in .answered(nil) }, filings: { _, at in .init(checkedAt: at, outcome: .answered, filings: []) },
            model: { Self.ok(Self.verdictPayload(), $0) })
        #expect(empty.verdict != nil)
        #expect(empty.facts.contains { $0.contains("no scheduled date in the queried") })
        #expect(empty.coverage.first { $0.source == "Next earnings" }?.state == .answered)
        #expect(empty.coverage.first { $0.source == "SEC submissions metadata" }?.state == .answered)
    }

    @Test func acceptedSECFilingCanCarryTheNextBusinessDate() async throws {
        let result = await run(filings: { _, at in .init(checkedAt: at, outcome: .answered,
            filings: [.init(accessionNumber: "PUBLIC-TODAY", form: "8-K", filingDate: at.addingTimeInterval(86_400),
                acceptedAt: at.addingTimeInterval(-60), items: [], documentURL: nil)]) },
            model: { Self.ok(Self.verdictPayload(), $0) })
        #expect(result.facts.joined().contains("PUBLIC-TODAY"))
    }

    @Test func throttlingMixedWithSuppressedAuthenticationDoesNotRequestAnOpinion() async throws {
        var calls = 0
        let result = await run(supplemental: { symbol, at in
            .init(symbol: symbol, capturedAt: at, credentialGeneration: nil, pages: [
                .init(query: .init(product: .news, subject: symbol, from: nil, through: nil), checkedAt: at,
                    credentialGeneration: nil, status: .unavailable(.throttled), records: [], excludedCount: 0, hasMore: false),
                .init(query: .init(product: .consensusRatings, subject: symbol, from: nil, through: nil), checkedAt: at,
                    credentialGeneration: nil, status: .unavailable(.priorAuthenticationRejection(subject: "OTHER", checkedAt: at.addingTimeInterval(-30))),
                    records: [], excludedCount: 0, hasMore: false)])
        }, model: { calls += 1; return Self.ok(Self.verdictPayload(), $0) })
        #expect(calls == 0 && result.verdict == nil)
    }

    @Test func staleSECCaptureCannotContributeMetadataAndSECReturnRechecksPermission() async throws {
        let result = await run(filings: { _, at in .init(checkedAt: at.addingTimeInterval(-400), outcome: .answered,
            filings: [.init(accessionNumber: "STALE-IDENTITY", form: "8-K", filingDate: at.addingTimeInterval(-500), acceptedAt: nil, items: [], documentURL: nil)]) },
            model: { Self.ok(Self.verdictPayload(), $0) })
        #expect(!result.facts.joined().contains("STALE-IDENTITY"))
        #expect(result.coverage.first { $0.source == "SEC submissions metadata" }?.state == .stale)
        var allowed = true, calls = 0
        _ = await run(allowed: { allowed }, filings: { _, at in allowed = false; return .init(checkedAt: at, outcome: .answered, filings: []) },
            model: { calls += 1; return Self.ok(Self.verdictPayload(), $0) })
        #expect(calls == 0)
    }

    @Test func researchDisclosesForwardEarningsSECAndDatedLiquidityAndGaps() async throws {
        let result = await run(model: { Self.ok(Self.verdictPayload(), $0) })
        let facts = result.facts.joined(separator: "\n")
        #expect(facts.contains("Next earnings"))
        #expect(facts.contains("SEC submissions metadata"))
        #expect(facts.contains("Historical average daily dollar volume"))
        #expect(facts.contains("Historical open-to-prior-close gaps"))
        #expect(facts.contains("Full filings were not retrieved"))
    }

    @Test func supplementalUnsupportedSymbolCannotReceiveAnOpinion() async throws {
        var root = try #require(try JSONSerialization.jsonObject(with: Self.historyPayload()) as? [String: Any])
        root["ticker"] = "ACME.A"
        var calls = 0
        let result = await run(listing: Self.listing("ACME.A"), history: try JSONSerialization.data(withJSONObject: root), model: {
            calls += 1
            return Self.ok(Self.verdictPayload(), $0)
        })
        #expect(calls == 0 && result.verdict == nil)
        #expect(result.referenceClose != nil)
        #expect(result.note.contains("supplemental evidence"))
    }

    @Test func entirelyThrottledSupplementalEvidenceDoesNotSpendAModelRequest() async throws {
        var calls = 0
        let result = await run(supplemental: { symbol, at in
            .init(symbol: symbol, capturedAt: at, credentialGeneration: nil,
                pages: [.init(query: .init(product: .news, subject: symbol, from: nil, through: nil), checkedAt: at,
                    credentialGeneration: nil, status: .unavailable(.throttled), records: [], excludedCount: 0, hasMore: false)])
        }, model: {
            calls += 1
            return Self.ok(Self.verdictPayload(), $0)
        })
        #expect(calls == 0 && result.verdict == nil)
        #expect(result.note.localizedCaseInsensitiveContains("throttl"))
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
            let pattern = try #require(reason["pattern"] as? String)
            #expect("Qualitative case".range(of: pattern, options: .regularExpression) != nil)
            #expect("Gains of 50%".range(of: pattern, options: .regularExpression) == nil)
            throw URLError(.cancelled) // No inventory or real network needed for this request-boundary test.
        })
        #expect(dispatched)
    }

    @Test func missingEvidenceIsRepairedWithoutChangingTheOpinion() async throws {
        var calls = 0
        let draft = #"{"action":"Hold","reason":"qualitative case","risk":"qualitative counter-case"}"#
        let result = await run(model: { request in
            calls += 1
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: String]])
            let system = try #require(messages.first(where: { $0["role"] == "system" })?["content"])
            #expect(system.contains("multi-session"), "The repair must retain the holding-horizon constraint")
            #expect(system.contains("same-session day-trading"))
            #expect(system.contains("beyond 14 trading days"))
            if calls == 1 {
                return Self.ok(try JSONSerialization.data(withJSONObject: ["model": Server.defaultModel,
                    "message": ["content": draft], "done_reason": "stop"]), request)
            }
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
    }

    // The horizon facts define the requested holding period and the reference entry. They are
    // mandatory and must reach the model even when optional evidence has to be trimmed.
    @Test(arguments: Research.Horizon.allCases, [true, false])
    func theRequestedHorizonAlwaysReachesTheModel(horizon: Research.Horizon, isOllama: Bool) async throws {
        var sentSystem = "", sentUser = ""
        _ = await run(isOllama: isOllama, horizon: horizon, model: { request in
            let object = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try #require(object["messages"] as? [[String: String]])
            sentSystem = try #require(messages.first(where: { $0["role"] == "system" })?["content"])
            sentUser = try #require(messages.first(where: { $0["role"] == "user" })?["content"])
            throw URLError(.cancelled) // Observe the real dispatch without a model or provider request.
        })
        #expect(sentSystem.contains("for a \(horizon.rawValue) holding horizon"))
        #expect(sentSystem.contains("multi-session"))
        #expect(sentSystem.contains("Do not propose intraday or same-session day-trading strategies"))
        #expect(sentSystem.contains("beyond 14 trading days"))
        #expect(sentSystem.contains("historical windows are background evidence"))
        #expect(sentUser.contains(horizon.rawValue))
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
