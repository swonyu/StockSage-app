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

    /// Opt-in synthetic model benchmark. Every provider/model call stays injected here.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STOCKSAGE_THROUGHPUT_DIR"] != nil))
    func syntheticThroughputPayloadExportAndValidation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["STOCKSAGE_THROUGHPUT_DIR"] else { return }
        try #require(path.hasPrefix("/"), "Use an absolute task scratch directory")
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let mode = environment["STOCKSAGE_THROUGHPUT_MODE"] ?? "export"
        try #require(["export", "validate", "validate-four-workers"].contains(mode))
        struct Request: Codable {
            let id, symbol, horizon, url: String
            let body: Data; let facts: [String]; let inputUTF8Bytes: Int
        }
        struct Manifest: Codable {
            let version: Int; let synthetic: Bool; let source, generatedAt, model: String
            let outputTokens, contextTokens: Int; let requests: [Request]
        }
        // Data fields are standard base64. Extra Python timing/usage fields are ignored.
        struct Response: Decodable {
            let trial, id: String; let parallelism, httpStatus: Int
            let body, inventory: Data; let elapsedSeconds: Double
        }
        let manifestURL = directory.appendingPathComponent("requests.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()
        if mode != "export" {
            let bytes = try Data(contentsOf: manifestURL)
            let manifest = try decoder.decode(Manifest.self, from: bytes)
            try #require(manifest.version == 1 && manifest.synthetic && manifest.requests.count == 16)
            try #require(manifest.model == Server.lmStudioModel && manifest.outputTokens == Research.researchOutputTokens
                         && manifest.contextTokens == Server.researchContextTokens)
            try #require(Set(manifest.requests.map(\.id)).count == 16)
            let requests = Dictionary(uniqueKeysWithValues: manifest.requests.map { ($0.id, $0) })
            var responses: [Response] = []
            for batch in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("batches"), includingPropertiesForKeys: nil) {
                let replyURL = batch.appendingPathComponent("responses.json")
                guard FileManager.default.fileExists(atPath: replyURL.path) else { continue }
                try #require(Data(contentsOf: batch.appendingPathComponent("requests.json")) == bytes,
                             "A batch must use this exact exported corpus")
                responses += try decoder.decode([Response].self, from: Data(contentsOf: replyURL))
            }
            try #require(Set(responses.map(\.parallelism)) == Set(mode == "validate-four-workers" ? [4] : [1, 2, 4, 8]))
            for (_, trial) in Dictionary(grouping: responses, by: \.trial) {
                try #require(trial.count == 16 && Set(trial.map(\.id)) == Set(requests.keys)
                             && Set(trial.map(\.parallelism)).count == 1)
            }
            var failures: [String] = []
            for response in responses {
                do {
                    let request = try #require(requests[response.id])
                    try #require((200..<300).contains(response.httpStatus) && response.body.count <= Server.maximumResponseBytes
                                 && response.inventory.count <= 262_144 && response.elapsedSeconds.isFinite && response.elapsedSeconds > 0)
                    let completion = try Server.parseCompletion(response.body, isOllama: false).get()
                    try #require(completion.model == Server.lmStudioModel && completion.diagnostic.finish == .stop
                                 && Server.financialOutputRejection(completion) == nil)
                    _ = try StockSageAIAssessment.validate(completion.text, facts: request.facts).get()
                    let inventory = try #require(JSONSerialization.jsonObject(with: response.inventory) as? [String: Any])
                    try #require((Server.verifiedContext(inventory, model: Server.lmStudioModel) ?? 0) >= manifest.contextTokens)
                    try #require((Server.managedInventory(inventory)?.researchParallelism ?? 1) >= response.parallelism)
                } catch { failures.append(response.trial + "/" + response.id + ": " + String(describing: error)) }
            }
            try encoder.encode(failures).write(to: directory.appendingPathComponent("validation-errors.json"), options: .atomic)
            #expect(failures.isEmpty, "All timed responses must pass the unchanged Swift acceptance checks")
            print("THROUGHPUT_VALIDATED \(responses.count - failures.count)/\(responses.count) raw completions")
            return
        }
        let cases = ["Synthetic customer orders improved, but delivery timing and margins remain uncertain.",
                     "Synthetic demand softened and inventory rose; a recovery has not been confirmed.",
                     "Synthetic results were mixed and management kept its outlook unchanged.",
                     "Synthetic expansion may support sales, while funding and execution remain risks."]
        let inventory = StockSageModelDownloadTests.installed.replacingOccurrences(of: "\"loaded_instances\":[]",
            with: #""loaded_instances":[{"id":"qwen3.5-9b","config":{"context_length":262144,"parallel":1}}]"#)
        var requests: [Request] = []
        for (index, suffix) in Array("ABCDEFGHIJKLMNOP").enumerated() {
            let symbol = "ACME" + String(suffix)
            let horizon: Research.Horizon = index.isMultiple(of: 2) ? .week : .fortnight
            var posts: [(URL, Data)] = []
            let result = await run(listing: Self.listing(symbol),
                history: Self.historyPayload(ticker: symbol, baseClose: 30 + Double(index) * 7),
                isOllama: false, horizon: horizon, news: { at in
                    .init(attempts: [.init(provider: .benzinga, checkedAt: at, status: .answered, items: (0..<3).map { offset in
                        .init(date: at.addingTimeInterval(-Double(offset + 1) * 3600), title: "Synthetic news for " + symbol,
                              snippet: cases[(index + offset) % cases.count], link: nil, sentiment: nil, source: "Synthetic benchmark provider")
                    })])
                }, next: { _, at in
                    if index.isMultiple(of: 3) { return .unavailable }
                    return .answered(.init(date: at.addingTimeInterval(Double(3 + index % 10) * 86_400), confirmed: index.isMultiple(of: 2)))
                }, model: { request in
                    if request.httpMethod == "POST" {
                        posts.append((try #require(request.url), try #require(request.httpBody)))
                        let content = #"{"evidence":["F1"],"action":"Hold","reason":"Synthetic supporting case.","risk":"Synthetic uncertainty remains."}"#
                        return Self.ok(try JSONSerialization.data(withJSONObject: ["model": Server.lmStudioModel,
                            "choices": [["message": ["content": content], "finish_reason": "stop"]]]), request)
                    }
                    try #require(request.httpMethod == "GET" && request.url?.path == "/api/v1/models")
                    return Self.ok(Data(inventory.utf8), request)
                })
            try #require(result.verdict != nil && posts.count == 1)
            let (url, body) = posts[0]
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(object["messages"] as? [[String: String]])
            try #require(object["max_tokens"] as? Int == 192 && object["model"] as? String == Server.lmStudioModel)
            try #require(messages.first?["content"] == horizon.instructions
                         && messages.last?["content"] == StockSageAIAssessment.prompt(facts: result.facts))
            try #require(object["response_format"] != nil && result.facts.count > 10)
            requests.append(.init(id: symbol + (horizon == .week ? ".week" : ".fortnight"), symbol: symbol,
                horizon: horizon.rawValue, url: url.absoluteString, body: body, facts: result.facts,
                inputUTF8Bytes: messages.reduce(0) { $0 + ($1["content"] ?? "").precomposedStringWithCanonicalMapping.utf8.count }))
        }
        let manifest = Manifest(version: 1, synthetic: true,
            source: "\(#fileID): injected gather/assess; pair with native gate source receipt. Sixteen model requests, not a full-scan benchmark.",
            generatedAt: Date().ISO8601Format(), model: Server.lmStudioModel, outputTokens: Research.researchOutputTokens,
            contextTokens: Server.researchContextTokens, requests: requests)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        print("THROUGHPUT_EXPORTED \(requests.count) synthetic research requests; normalized input bytes \(requests.map(\.inputUTF8Bytes))")
    }

    // MARK: Fixtures

    /// A Massive daily-aggregate payload through the latest ended session.
    /// Prices trend gently so indicators are well defined.
    private static func historyPayload(ticker: String = "ACME", baseClose: Double = 40,
                                       bars: Int = 90, endingDaysAgo: Int = 1) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        var lastDay = calendar.date(byAdding: .day, value: -endingDaysAgo,
                                   to: calendar.startOfDay(for: Date()))!
        // A normal successful fixture ends at a real completed session, including when
        // this suite runs on Monday or after a market holiday. The stale fixture stays stale.
        if endingDaysAgo == 1, let completed = StockSageMarketHours.latestCompletedDailySession(at: Date()) {
            lastDay = completed
        }
        var rows: [[String: Any]] = []
        for index in 0..<bars {
            let day = calendar.date(byAdding: .day, value: -(bars - 1 - index), to: lastDay)!
            // Midday New York so the bar lands unambiguously inside its own session date.
            let stamp = calendar.date(byAdding: .hour, value: 13, to: day)!
            let close = baseClose + Double(index) * 0.10
            rows.append(["t": Int(stamp.timeIntervalSince1970 * 1_000),
                         "o": close - 0.20, "h": close + 0.35, "l": close - 0.40,
                         "c": close, "v": 1_500_000 + Double(index) * 1_000])
        }
        return try! JSONSerialization.data(withJSONObject: [
            "status": "OK", "ticker": ticker, "adjusted": true,
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
            "model": StockSageModelHarnessTests.ollamaFixtureModel,
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
                     insider: ((String, Date) async -> StockSageMassiveEvents.Observation)? = nil,
                     earningsReceipt: ((String, Date) async -> StockSageMassiveEarnings.Observation)? = nil,
                     next: @escaping (String, Date) async -> StockSageCatalystChain.Answer<StockSageMassiveEarnings.Row?> = { _, _ in .unavailable },
                     filings: @escaping (String, Date) async -> StockSageDisclosureService.FilingsObservation = { _, at in .init(checkedAt: at, outcome: .unavailable(.unreachable), filings: []) },
                     model: @escaping (URLRequest) async throws -> (Data, URLResponse)
                     ) async -> Research.Result {
        let config = Server.config(url: isOllama ? StockSageModelHarnessTests.ollamaFixtureURL : Server.lmStudioURL,
                                   model: isOllama ? StockSageModelHarnessTests.ollamaFixtureModel : Server.lmStudioModel)!
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
            }, filingsObservation: filings, insiderObservation: insider,
            evidenceIsCurrent: { _ in true })
    }

    @Test func insufficientHistoryReportsActualBarCountWithoutRequestingModel() async {
        let result = await run(history: Self.historyPayload(bars: 18), model: {
            Issue.record("Insufficient history must not reach the model")
            return Self.ok(Self.verdictPayload(), $0)
        })
        #expect(result.verdict == nil && result.note.contains("18 daily bars") && result.note.contains("at least 30"))
    }

    @Test func oneCaptureSuppliesTwoDistinctHorizonsAndRejectsChangedOwnershipOrClock() async throws {
        let name = "stocksage.research.capture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        var historyCalls = 0, newsCalls = 0, earningsCalls = 0, filingsCalls = 0, snapshotCalls = 0, insiderCalls = 0
        let gathered = await Research.gather(Self.listing(), store: store, key: "fixture", allowed: { true },
            historyTransport: { historyCalls += 1; return Self.ok(Self.historyPayload(), $0) },
            benzingaSnapshot: { symbol, at in snapshotCalls += 1; return .init(symbol: symbol, capturedAt: at, credentialGeneration: nil, pages: []) },
            newsObservation: { _, _, _ in newsCalls += 1; return .init(attempts: []) },
            nextEarnings: { _, at in earningsCalls += 1; return .init(outcome: .answered(nil), checkedAt: at, recordedAt: at) },
            filingsObservation: { _, at in filingsCalls += 1; return .init(checkedAt: at, outcome: .answered, filings: []) },
            insiderObservation: { symbol, at in
                insiderCalls += 1
                return .init(symbol: symbol, feed: .insider, checkedAt: at, outcome: .answered, event: nil)
            },
            evidenceIsCurrent: { _ in true })
        guard case .captured(let capture) = gathered else { Issue.record("Expected isolated capture"); return }
        #expect(historyCalls == 1 && newsCalls == 1 && earningsCalls == 1 && filingsCalls == 1 && snapshotCalls == 1)
        #expect(capture.nextEarnings?.checkedAt != nil)
        let config = try #require(Server.config(url: StockSageModelHarnessTests.ollamaFixtureURL, model: StockSageModelHarnessTests.ollamaFixtureModel))
        var prompts: [String] = [], results: [Research.Result] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = StockSageResearchDiagnostics(directory: directory)
        for horizon in Research.Horizon.allCases {
            results.append(await Research.assess(capture, horizon: horizon, config: config, isOllama: true, allowed: { true },
                modelTransport: { request in prompts.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self)); return Self.ok(Self.verdictPayload(), request) },
                evidenceIsCurrent: { _ in true }, diagnostics: diagnostics))
        }
        #expect(prompts.count == 2 && prompts[0].contains("1–7 trading days") && prompts[1].contains("7–14 trading days"))
        #expect(results.allSatisfy { $0.verdict != nil && $0.at == capture.at && $0.referenceClose?.at == capture.referenceClose.at })
        #expect(results[0].coverage == results[1].coverage && historyCalls == 1 && insiderCalls == 1)
        #expect(Set(results.compactMap(\.diagnosticID)).count == 2)
        for (index, result) in results.enumerated() {
            let receipt = try #require(result.evidenceReceipt)
            #expect(receipt.symbol == "ACME" && receipt.offeredKeys.count == result.facts.count)
            #expect(receipt.requiredKeys.contains("quote") && receipt.requiredKeys.contains("nextEarnings")
                    && receipt.requiredKeys.contains("sec.status") && !receipt.requiredKeys.contains("earnings"))
            #expect(receipt.missingOrUnknownRequiredKeys.contains("nextEarnings"))
            #expect(receipt.requiredKeys.contains("nextEarnings.window"))
            #expect(receipt.missingOrUnknownRequiredKeys.contains("nextEarnings.window"))
            #expect(result.facts.contains(StockSageMassiveEarnings.Window(observation: capture.nextEarnings,
                asOf: capture.context.asOf, horizon: index == 0 ? .week : .fortnight).fact))
            #expect(receipt.citedKeys.count == result.verdict?.evidence.count)
            let id = try #require(result.diagnosticID)
            let entries = await diagnostics.entries(for: id)
            #expect(result.diagnosticsComplete == true && entries.last?.outcome?.state == .accepted)
            #expect(entries.allSatisfy { $0.context.symbol == "ACME" && $0.context.horizon == (index == 0 ? 7 : 14) })
            #expect(entries.compactMap(\.attempt).map(\.stage) == [.started, .finished])
        }
        // The production preparation path retains an accepted Buy while excluding it from
        // the stricter shortlist when the typed capture has unknown earnings/no catalyst.
        let strictAnalysis = Research.preparedAnalysis(gathered, config: config, isOllama: true,
            allowed: { true }, modelTransport: { request in
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                #expect(body.contains("Strict qualification v1") && body.contains("Be selective"))
                return Self.ok(Self.verdictPayload(action: "Buy"), request)
            }, evidenceIsCurrent: { _ in true }, qualify: true)
        let strict = await strictAnalysis(.fortnight)
        let qualified = try #require(strict.qualification)
        #expect(strict.verdict?.action == .buy && strict.levels != nil && !qualified.isQualified)
        #expect(strict.evidenceReceipt?.requiredKeys.contains("research.qualification.v1") == true)
        #expect(StockSageResearchQualification.valid(qualified, symbol: "ACME", horizon: Research.Horizon.fortnight.rawValue,
            at: strict.at, citedKeys: strict.evidenceReceipt?.citedKeys ?? []))
        let rejected = await Research.assess(capture, horizon: .week, config: config, isOllama: true,
            allowed: { true }, modelTransport: { request in
                Self.ok(try JSONSerialization.data(withJSONObject: ["model": StockSageModelHarnessTests.ollamaFixtureModel,
                    "message": ["content": "invalid research answer"], "done": true, "done_reason": "stop"]), request)
            }, evidenceIsCurrent: { _ in true }, diagnostics: diagnostics)
        let rejectedID = try #require(rejected.diagnosticID)
        let rejectedEntries = await diagnostics.entries(for: rejectedID)
        #expect(rejected.verdict == nil && rejected.evidenceReceipt != nil && !rejected.facts.isEmpty)
        #expect(rejectedEntries.last?.outcome?.state == .rejected)
        #expect(rejectedEntries.compactMap(\.attempt).last?.responseBody != nil)
        let staleOwner = await Research.assess(capture, horizon: .fortnight, config: config, isOllama: true, allowed: { true },
            modelTransport: { Issue.record("Obsolete evidence cannot reach the model"); return Self.ok(Self.verdictPayload(), $0) }, evidenceIsCurrent: { _ in false })
        #expect(staleOwner.verdict == nil)
        #expect(!capture.isFresh(at: capture.at.addingTimeInterval(301)))
        #expect(!capture.isFresh(at: capture.at.addingTimeInterval(-1)))
        #expect(!capture.isFresh(at: capture.context.asOf.addingTimeInterval(-0.001)))
    }

    @Test func preparedAnalysesKeepTwoRealCapturesIsolatedAcrossInterleavedHorizons() async throws {
        let name = "stocksage.research.prepared-captures.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let config = try #require(Server.config(url: StockSageModelHarnessTests.ollamaFixtureURL, model: StockSageModelHarnessTests.ollamaFixtureModel))
        var providerCalls: [String: Int] = [:]
        var prompts: [String: String] = [:]
        var held: [String: CheckedContinuation<Void, Never>] = [:]
        var tasks: [Task<Research.Result, Never>] = []
        var activeModels = 0, maximumActiveModels = 0
        defer {
            tasks.forEach { $0.cancel() }
            for continuation in held.values { continuation.resume() }
            held.removeAll()
        }

        func gather(_ symbol: String, baseClose: Double) async throws -> (Research.Gathered, Research.Capture) {
            let gathered = await Research.gather(Self.listing(symbol), store: store, key: "fixture", allowed: { true },
                companyObservations: [:], historyTransport: { request in
                    providerCalls[symbol + ".history", default: 0] += 1
                    #expect(request.url?.path.contains("/\(symbol)/") == true)
                    return Self.ok(Self.historyPayload(ticker: symbol, baseClose: baseClose), request)
                }, benzingaSnapshot: { ticker, at in
                    #expect(ticker == symbol)
                    providerCalls[symbol + ".benzinga", default: 0] += 1
                    return .init(symbol: ticker, capturedAt: at, credentialGeneration: nil, pages: [])
                }, newsObservation: { ticker, _, _ in
                    #expect(ticker == symbol)
                    providerCalls[symbol + ".news", default: 0] += 1
                    return .init(attempts: [])
                }, nextEarnings: { ticker, at in
                    #expect(ticker == symbol)
                    providerCalls[symbol + ".earnings", default: 0] += 1
                    return .init(outcome: .answered(nil), checkedAt: at, recordedAt: at)
                }, filingsObservation: { ticker, at in
                    #expect(ticker == symbol)
                    providerCalls[symbol + ".filings", default: 0] += 1
                    return .init(checkedAt: at, outcome: .answered, filings: [])
                }, evidenceIsCurrent: { _ in true }, selectionFact: "Immutable source marker for \(symbol)")
            guard case .captured(let capture) = gathered else {
                Issue.record("Expected a real isolated capture for \(symbol)")
                throw URLError(.cannotParseResponse)
            }
            return (gathered, capture)
        }

        func prepared(_ gathered: Research.Gathered, symbol: String) -> Research.Analysis {
            Research.preparedAnalysis(gathered, config: config, isOllama: true, allowed: { true },
                modelTransport: { request in
                    let data = try #require(request.httpBody)
                    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let messages = try #require(object["messages"] as? [[String: String]])
                    let system = try #require(messages.first { $0["role"] == "system" }?["content"])
                    let user = try #require(messages.first { $0["role"] == "user" }?["content"])
                    let horizon = try #require(Research.Horizon.allCases.first {
                        user.contains("Requested holding horizon: \($0.rawValue).")
                    })
                    #expect(system.contains("for a \(horizon.rawValue) holding horizon"))
                    #expect(user.contains("Symbol: \(symbol)."))
                    #expect(user.contains("Immutable source marker for \(symbol)"))
                    let other = symbol == "ACME" ? "BETA" : "ACME"
                    #expect(!user.contains("Symbol: \(other).") && !user.contains("Immutable source marker for \(other)"))
                    let key = symbol + "." + horizon.id
                    #expect(prompts[key] == nil, "Each captured symbol/horizon must reach the model once")
                    prompts[key] = user
                    activeModels += 1
                    maximumActiveModels = max(maximumActiveModels, activeModels)
                    defer { activeModels -= 1 }
                    await withCheckedContinuation { held[key] = $0 }
                    return Self.ok(Self.verdictPayload(), request)
                }, evidenceIsCurrent: { _ in true })
        }

        func waitFor(_ symbol: String, _ horizon: Research.Horizon) async throws {
            let key = symbol + "." + horizon.id
            for _ in 0..<100 where held[key] == nil { try await Task.sleep(for: .milliseconds(5)) }
            try #require(held[key] != nil, "Expected the injected model request for \(key)")
        }
        func release(_ symbol: String, _ horizon: Research.Horizon) throws {
            let removed = held.removeValue(forKey: symbol + "." + horizon.id)
            let continuation = try #require(removed)
            continuation.resume()
        }

        let (gatheredA, captureA) = try await gather("ACME", baseClose: 40)
        let analysisA = prepared(gatheredA, symbol: "ACME")
        let aWeek = Task { await analysisA(.week) }; tasks.append(aWeek)
        try await waitFor("ACME", .week)
        // The producer gathers B while A's model request is still in flight.
        let (gatheredB, captureB) = try await gather("BETA", baseClose: 140)
        let analysisB = prepared(gatheredB, symbol: "BETA")
        let bWeek = Task { await analysisB(.week) }; tasks.append(bWeek)
        try await waitFor("BETA", .week)
        #expect(activeModels == 2)

        try release("BETA", .week)
        let bFirst = await bWeek.value
        let bFortnight = Task { await analysisB(.fortnight) }; tasks.append(bFortnight)
        try await waitFor("BETA", .fortnight)
        try release("ACME", .week)
        let aFirst = await aWeek.value
        let aFortnight = Task { await analysisA(.fortnight) }; tasks.append(aFortnight)
        try await waitFor("ACME", .fortnight)
        try release("ACME", .fortnight)
        try release("BETA", .fortnight)
        let aSecond = await aFortnight.value, bSecond = await bFortnight.value

        for (symbol, capture, results) in [("ACME", captureA, [aFirst, aSecond]), ("BETA", captureB, [bFirst, bSecond])] {
            for stage in ["history", "benzinga", "news", "earnings", "filings"] {
                #expect(providerCalls[symbol + "." + stage] == 1)
            }
            for (result, horizon) in zip(results, Research.Horizon.allCases) {
                #expect(result.verdict != nil && result.at == capture.at)
                #expect(result.referenceClose?.value == capture.referenceClose.value && result.referenceClose?.at == capture.referenceClose.at)
                #expect(result.coverage == capture.coverage)
                #expect(result.facts.contains("Immutable source marker for \(symbol)"))
                #expect(result.facts.contains { $0.contains("Requested holding horizon: \(horizon.rawValue).") })
            }
        }
        #expect(captureA.referenceClose.value != captureB.referenceClose.value)
        #expect(prompts.count == 4 && maximumActiveModels == 2 && activeModels == 0)
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

    @Test func researchCollectsInsiderEvidenceWithoutABoardObservation() async throws {
        var symbols: [String] = []
        let result = await run(insider: { symbol, at in
            symbols.append(symbol)
            let events = (1...3).map { index in
                StockSageMassiveEvents.Event(id: "same-accession", symbol: symbol, feed: .insider, date: at,
                    headline: "Form 4 sale filed", details: ["Insider \(index) sold \(index) shares.", "Reported under a Rule 10b5-1 plan."], link: nil)
            }
            return .init(symbol: symbol, feed: .insider, checkedAt: at, outcome: .answered, event: events[0],
                insiderEvents: events, insiderOmittedRecordCount: 2)
        }, model: { Self.ok(Self.verdictPayload(), $0) })
        #expect(symbols == ["ACME"] && result.verdict != nil)
        #expect(result.facts.filter { $0.contains("Form 4 sale filed") }.count == 3)
        #expect(result.coverage.first { $0.source == "Massive/SEC Form 4" }?.state == .answered)
        #expect(result.facts.contains { $0.contains("3 retained") && $0.contains("2 omitted") })
    }

    @Test func stoppedResearchCannotCollectInsiderEvidenceOrPublishALateObservation() async {
        var calls = 0, modelCalls = 0
        let blocked = await run(allowed: { false }, insider: { symbol, at in
            calls += 1
            return .init(symbol: symbol, feed: .insider, checkedAt: at, outcome: .answered, event: nil)
        }, model: { modelCalls += 1; return Self.ok(Self.verdictPayload(), $0) })
        #expect(blocked.verdict == nil && calls == 0 && modelCalls == 0)
        var active = true
        let stopped = await run(allowed: { active }, insider: { symbol, at in
            calls += 1; active = false
            return .init(symbol: symbol, feed: .insider, checkedAt: at, outcome: .answered, event: nil)
        }, model: { modelCalls += 1; return Self.ok(Self.verdictPayload(), $0) })
        #expect(stopped.verdict == nil && calls == 1 && modelCalls == 0)
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
                return Self.ok(try JSONSerialization.data(withJSONObject: ["model": StockSageModelHarnessTests.ollamaFixtureModel,
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
                return Self.ok(try JSONSerialization.data(withJSONObject: ["model": StockSageModelHarnessTests.ollamaFixtureModel,
                    "message": ["content": String(decoding: draft, as: UTF8.self)], "done_reason": "stop"]), request)
            }
            let repaired = try JSONSerialization.data(withJSONObject: ["evidence": ["F1"],
                "action": scenario == "changed action" ? "Buy" : "Hold",
                "reason": scenario == "changed prose" ? "rewritten case" : "qualitative case",
                "risk": "qualitative counter-case"])
            return Self.ok(try JSONSerialization.data(withJSONObject: ["model": StockSageModelHarnessTests.ollamaFixtureModel,
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
        #expect(result.model == StockSageModelHarnessTests.ollamaFixtureModel)
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

    @Test func aDistantEarningsDateCannotBecomeAnImminentReport() async throws {
        let content = #"{"evidence":["F1"],"action":"Buy","reason":"Demand supports the case.","risk":"Earnings gap risk exists as the next report is in two weeks."}"#
        let payload = try JSONSerialization.data(withJSONObject: ["model": StockSageModelHarnessTests.ollamaFixtureModel,
            "message": ["content": content], "done_reason": "stop"])
        let result = await run(horizon: .fortnight, next: { _, at in
            .answered(.init(date: at.addingTimeInterval(60 * 86_400), confirmed: true))
        }, model: { Self.ok(payload, $0) })
        #expect(result.verdict == nil, "A date beyond the holding window became an imminent earnings claim")
        #expect(result.facts.contains { $0.hasPrefix("Earnings holding-window check: ") })
    }

    @Test func aTruncatedVerdictIsRefusedRatherThanPublished() async throws {
        let truncated = try! JSONSerialization.data(withJSONObject: [
            "model": StockSageModelHarnessTests.ollamaFixtureModel,
            "message": ["content": #"{"evidence":["F1"],"action":"Buy","reason":"cut off mid"#],
            "done_reason": "length",
        ])
        let result = await run(model: { Self.ok(truncated, $0) })
        #expect(result.verdict == nil, "a truncated answer became a published opinion")
        #expect(result.note.localizedCaseInsensitiveContains("output limit"))
    }

    @Test func nearContextResearchReservesTheSameEvidenceOutputRetryBeforeFitting() async throws {
        // Exercise analyze(), its provider capture, whole-record fitter and native strict
        // completion path. The managed fixture avoids dependence on the global web setting;
        // both managed LM Studio and RunPod use the same strict output-retry contract.
        let baseSnippet = "Synthetic boundary disclosure."
        var snippet = baseSnippet
        func news(_ at: Date) -> StockSageNewsService.Observation {
            .init(attempts: [.init(provider: .massive, checkedAt: at, status: .answered, items: [
                .init(date: at, title: "Synthetic boundary source", snippet: snippet, link: nil,
                    sentiment: nil, source: "Synthetic provider", articleIdentity: "boundary-source")
            ])])
        }
        func reply(_ request: URLRequest, truncated: Bool = false) throws -> (Data, URLResponse) {
            if request.httpMethod == "GET" {
                #expect(request.url?.path == "/api/v1/models")
                let inventory = StockSageModelDownloadTests.installed.replacingOccurrences(of: "\"loaded_instances\":[]",
                    with: #""loaded_instances":[{"id":"qwen3.5-9b","config":{"context_length":16384}}]"#)
                return Self.ok(Data(inventory.utf8), request)
            }
            let content = truncated ? #"{"reason":"Unfinished"#
                : #"{"reason":"The evidence is mixed.","risk":"Price direction remains uncertain.","evidence":["F1"],"action":"Hold"}"#
            return Self.ok(try JSONSerialization.data(withJSONObject: ["model": Server.lmStudioModel,
                "choices": [["message": ["content": content], "finish_reason": truncated ? "length" : "stop"]]]), request)
        }
        var calibrationMessages: [[String: String]] = []
        let calibration = await run(isOllama: false, news: news, model: { request in
            if request.httpMethod == "POST" {
                let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                calibrationMessages = try #require(body["messages"] as? [[String: String]])
            }
            return try reply(request)
        })
        try #require(calibration.verdict != nil)
        let system = try #require(calibrationMessages.first { $0["role"] == "system" }?["content"])
        let originalUser = try #require(calibrationMessages.first { $0["role"] == "user" }?["content"])
        let firstBudget = Server.maximumUserBytes(system: system, outputTokens: 192, contextTokens: 16384)
        let retryBudget = Server.maximumUserBytes(system: system, outputTokens: 384, contextTokens: 16384)
        let target = (firstBudget + retryBudget) / 2
        try #require(originalUser.components(separatedBy: baseSnippet).count == 2 && target > originalUser.utf8.count)
        snippet += String(repeating: "x", count: target - originalUser.utf8.count)
        let unreserved = originalUser.replacingOccurrences(of: baseSnippet, with: snippet)
        #expect(Server.promptFits(system: system, user: unreserved, outputTokens: 192, contextTokens: 16384))
        #expect(!Server.promptFits(system: system, user: unreserved, outputTokens: 384, contextTokens: 16384))

        var bodies: [[String: Any]] = []
        let result = await run(isOllama: false, news: news, model: { request in
            if request.httpMethod == "POST" {
                bodies.append(try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]))
            }
            return try reply(request, truncated: request.httpMethod == "POST" && bodies.count == 1)
        })
        #expect(bodies.compactMap { $0["max_tokens"] as? Int } == [192, 384],
                "The initial evidence fit must reserve the existing same-evidence retry")
        try #require(bodies.count == 2)
        #expect(result.verdict != nil && result.verdict?.action == .hold)
        bodies[0].removeValue(forKey: "max_tokens"); bodies[1].removeValue(forKey: "max_tokens")
        #expect(try JSONSerialization.data(withJSONObject: bodies[0], options: [.sortedKeys])
            == JSONSerialization.data(withJSONObject: bodies[1], options: [.sortedKeys]),
            "Retry must preserve the exact messages and response schema")
        let originalReceipt = try #require(calibration.evidenceReceipt)
        let receipt = try #require(result.evidenceReceipt)
        #expect(receipt.requiredKeys == originalReceipt.requiredKeys)
        #expect(Set(receipt.requiredKeys).isSubset(of: Set(receipt.offeredKeys)))
        #expect(!receipt.omittedKeys.isEmpty && Set(receipt.omittedKeys).isDisjoint(with: Set(receipt.requiredKeys)))
        #expect(Set(receipt.omittedKeys).isSubset(of: Set(originalReceipt.offeredKeys)))
        #expect(Set(receipt.offeredKeys).isDisjoint(with: Set(receipt.omittedKeys)))
        #expect(receipt.offeredKeys.count == result.facts.count
            && receipt.omittedKeys.count == calibration.facts.count - result.facts.count)
        #expect(result.facts.contains { $0.hasPrefix("Earnings holding-window check:") })
        #expect(result.note.contains("optional evidence records were omitted"))
    }

    @Test func aModelFailureYieldsNoOpinionAndSaysSo() async throws {
        let result = await run(model: { _ in throw URLError(.timedOut) })
        #expect(result.verdict == nil)
        #expect(result.note.localizedCaseInsensitiveContains("no verified opinion"))
    }

    @Test func anUnparseableAnswerYieldsNoOpinion() async throws {
        let garbage = try! JSONSerialization.data(withJSONObject: [
            "model": StockSageModelHarnessTests.ollamaFixtureModel,
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
