import Foundation
import Testing
@testable import StockSage

@Suite("Frozen prospective research evaluation", .serialized) @MainActor
struct StockSageResearchEvaluationTests {
    typealias E = StockSageResearchEvaluation
    typealias H = StockSageResearchHistory
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var config: StockSageLocalModelServer.Config {
        .init(baseURL: URL(string: "http://127.0.0.1:18080")!, model: StockSageLocalModelServer.gemmaModel)
    }
    private var contract: E.Contract {
        .init(id: UUID(), frozenAt: date("2026-08-19T10:00:00Z"), model: config.model,
            endpointProfile: .runPodGemma, promptVersion: 1, schemaVersion: 1, rankingVersion: 3,
            qualificationPolicyVersion: 1, benchmark: "SPY", roundTripCostBPS: 25,
            minimumWindows: 20, calendarBasis: H.benchmarkCalendarBasis, profileVersion: 1, packetVersion: 2,
            temperature: 0.2, topP: nil, seed: nil, contextTokens: 16_384, initialOutputTokens: 192, maxOutputTokens: 384)
    }
    private func run(at started: Date) async throws -> H.Run {
        typealias A = StockSageAIAssessment
        var result = StockSageResearchHistoryTests().qualifiedResult("AAA", at: started.addingTimeInterval(1), qualified: true)
        result.model = config.model
        let previous = try #require(result.evidenceReceipt)
        let facts = zip(previous.offeredKeys, result.facts).map {
            A.EvidenceFact(key: $0.0, text: $0.1, required: true, availability: .available)
        }
        let packet = A.EvidencePacket(facts: facts, prePromptOmittedRecordCount: 0)
        result.evidenceReceipt = .init(symbol: "AAA", requiredKeys: previous.requiredKeys,
            missingOrUnknownRequiredKeys: previous.missingOrUnknownRequiredKeys, offeredKeys: previous.offeredKeys,
            omittedKeys: previous.omittedKeys, prePromptOmittedRecordCount: previous.prePromptOmittedRecordCount,
            citedKeys: previous.citedKeys, packetVersion: packet.version, classCounts: packet.classCounts, packetDigest: packet.digest)
        result.inferenceProfile = .init(config: config, isOllama: false, packet: packet,
            outputTokens: 192, diagnostic: .init(finish: .stop))
        var scan = StockSageHorizonResearch.Scan()
        scan.at = started; scan.qualificationPolicyVersion = 1
        scan.listings = [.init(ticker: "AAA", name: "Synthetic company", market: "stocks", locale: "us", active: true,
            type: "CS", currency_name: "usd", primary_exchange: "XNAS")]
        scan.results = ["AAA": result]
        let receipt = try await StockSageResearchRanking.rank(scan: scan, horizon: .fortnight, config: config,
            isOllama: false, allowed: { true }, completion: { _, _, _ in
                .success(.init(text: "{\"symbols\":[\"AAA\"]}", diagnostic: .init(finish: .stop), model: config.model))
            }).get()
        scan.ranking = .init(version: receipt.version, method: receipt.method, horizon: receipt.horizon,
            candidateSymbols: receipt.candidateSymbols, symbols: receipt.symbols, model: receipt.model,
            at: started.addingTimeInterval(2), rounds: receipt.rounds)
        let run = H.snapshot(startedAt: started, completedAt: started.addingTimeInterval(3), horizon: .fortnight, scan: scan)
        try #require(run.predictions.count == 1 && H().record(run), "The evaluator fixture must pass the real saved-research contract")
        return run
    }
    private func observation(symbol: String, run: H.Run, gain: Double = 0.1,
        adjusted: Bool = true, omitMiddle: Bool = false) throws -> H.Observation {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        var day = try #require(H.benchmarkDay(after: run.completedAt))
        let end = calendar.startOfDay(for: try #require(H.targetClose(for: run)))
        var dates: [Date] = []
        while day <= end {
            if StockSageMarketHours.nasdaqDay(at: day)?.trading == true { dates.append(day) }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        if omitMiddle { dates.remove(at: 2) }
        var closes = Array(repeating: 100.0, count: dates.count); closes[closes.count - 1] = 100 * (1 + gain)
        return .init(history: .init(symbol: symbol, dates: dates, opens: Array(repeating: 100, count: dates.count),
            highs: closes.map { max(101, $0) }, lows: closes.map { min(99, $0) }, closes: closes,
            volumes: Array(repeating: 1000, count: dates.count), priceSource: .massiveDaily),
            splitAdjusted: adjusted, provider: E.provider, fetchedAt: date("2026-10-20T12:00:00Z"))
    }

    @Test func exactAdjustedPairAppliesDisclosedCostsAndRejectsMissingBenchmarkDates() async throws {
        let run = try await run(at: date("2026-08-20T13:00:00Z"))
        let prediction = try #require(run.predictions.first), policy = contract
        let stock = try observation(symbol: "AAA", run: run, gain: 0.1)
        let benchmark = try observation(symbol: "SPY", run: run, gain: 0.04)
        let pair = try #require(E.paired(run: run, prediction: prediction, contract: policy,
            stock: stock, benchmark: benchmark, now: date("2026-10-20T12:00:00Z")))
        #expect(abs(try #require(pair.netReturn(costBPS: 25)) - 0.0975) < 1e-12)
        #expect(abs(try #require(pair.netBenchmarkReturn(costBPS: 25)) - 0.0375) < 1e-12)
        #expect(pair.stock.map(\.date) == pair.benchmark.map(\.date) && pair.stock.count == 14)
        for invalid in [try observation(symbol: "SPY", run: run, omitMiddle: true),
                        try observation(symbol: "SPY", run: run, adjusted: false),
                        try observation(symbol: "OTHER", run: run)] {
            #expect(E.paired(run: run, prediction: prediction, contract: policy, stock: stock,
                benchmark: invalid, now: date("2026-10-20T12:00:00Z")) == nil)
        }
    }

    @Test func prospectiveSelectionReportsSameDateOverlapAndDoesNotUseOldCounts() async throws {
        let store = E()
        try #require(store.freeze(config: config, costBPS: 25, at: contract.frozenAt))
        let study = try #require(store.studies.first)
        let before = try await run(at: date("2026-08-18T13:00:00Z"))
        let first = try await run(at: date("2026-08-20T13:00:00Z"))
        let sameDate = try await run(at: date("2026-08-20T14:00:00Z"))
        let overlap = try await run(at: date("2026-08-21T13:00:00Z"))
        let next = try await run(at: date("2026-09-11T13:00:00Z"))
        let summary = try #require(store.summary(studyID: study.id, runs: [next, overlap, sameDate, first, before],
            now: date("2026-10-20T12:00:00Z")).first { $0.horizon == .fortnight })
        #expect(summary.eligibleRuns == 4 && summary.excludedRuns == 1)
        #expect(summary.sameDateRuns == 1 && summary.overlappingRuns == 1 && summary.selectedWindows == 2)
        #expect(summary.uncheckedWindows == 2 && summary.measuredWindows == 0 && summary.meanExcessReturn == nil)
        #expect(summary.readiness.contains("Not enough evidence") && !summary.readiness.contains("independent"))
    }

    @Test func frozenStudyPersistsAndCancelCannotCommitItsAwaitedPricePair() async throws {
        let suite = "stocksage.evaluation.\(UUID())"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("evaluation.json"), store = E(storageURL: url, defaults: defaults)
        try #require(store.freeze(config: config, costBPS: 25, at: contract.frozenAt))
        let frozen = try #require(store.studies.first)
        #expect(E(storageURL: url, defaults: defaults).studies.first?.contract == frozen.contract)
        let run = try await run(at: date("2026-08-20T13:00:00Z"))
        var allowed = true, calls = 0
        await store.check(studyID: frozen.id, runs: [run], clock: { self.date("2026-10-20T12:00:00Z") },
            allowed: { allowed }, fetch: { symbol, _, _ in
                calls += 1; allowed = false
                return try? self.observation(symbol: symbol, run: run)
            })
        #expect(calls == 1 && store.studies.first?.reviews.isEmpty == true)
        #expect(E(storageURL: url, defaults: defaults).studies.first == frozen)
    }
    @Test func changedInferenceSettingsAreExcludedWithoutWeakeningSavedRunValidation() async throws {
        let store = E(), original = try await run(at: date("2026-08-20T13:00:00Z"))
        try #require(store.freeze(config: config, costBPS: 25, at: contract.frozenAt))
        let id = try #require(store.studies.first?.id)
        for (key, value) in [("temperature", 0.4), ("contextTokens", 8192.0), ("initialOutputTokens", 256.0),
                             ("maxOutputTokens", 512.0), ("topP", 0.9), ("seed", 42.0)] {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            var predictions = try #require(object["predictions"] as? [[String: Any]])
            var profile = try #require(predictions[0]["inferenceProfile"] as? [String: Any])
            profile[key] = value; predictions[0]["inferenceProfile"] = profile; object["predictions"] = predictions
            let changed = try JSONDecoder().decode(H.Run.self, from: JSONSerialization.data(withJSONObject: object))
            try #require(H.valid(changed), "Changed settings should remain structurally valid saved research")
            let summary = try #require(store.summary(studyID: id, runs: [changed], now: date("2026-10-20T12:00:00Z"))
                .first { $0.horizon == .fortnight })
            #expect(summary.excludedRuns == 1 && summary.selectedWindows == 0)
        }
    }

    @Test func unavailableBenchmarkIsRetriedAndOnlyCompletePairsContributeToMeans() async throws {
        let store = E(), run = try await run(at: date("2026-08-20T13:00:00Z"))
        try #require(store.freeze(config: config, costBPS: 25, at: contract.frozenAt))
        let id = try #require(store.studies.first?.id)
        var missing = true, calls = 0
        let fetch: @MainActor (String, Date, Date) async -> H.Observation? = { symbol, _, _ in
            calls += 1
            return try? self.observation(symbol: symbol, run: run, gain: symbol == "SPY" ? 0.04 : 0.1,
                omitMiddle: symbol == "SPY" && missing)
        }
        let clock: @MainActor () -> Date = { self.date("2026-10-20T12:00:00Z") }
        await store.check(studyID: id, runs: [run], clock: clock, allowed: { true }, fetch: fetch)
        let failed = try #require(store.summary(studyID: id, runs: [run], now: clock()).first { $0.horizon == .fortnight })
        #expect(failed.unavailableWindows == 1 && failed.measuredWindows == 0 && failed.meanNetReturn == nil)
        missing = false
        await store.check(studyID: id, runs: [run], clock: clock, allowed: { true }, fetch: fetch)
        let measured = try #require(store.summary(studyID: id, runs: [run], now: clock()).first { $0.horizon == .fortnight })
        #expect(measured.measuredWindows == 1 && measured.measuredPredictions == 1 && measured.unavailableWindows == 0)
        #expect(abs(try #require(measured.meanNetReturn) - 0.0975) < 1e-12)
        #expect(abs(try #require(measured.meanBenchmarkNetReturn) - 0.0375) < 1e-12)
        #expect(abs(try #require(measured.meanExcessReturn) - 0.06) < 1e-12)
        #expect(measured.readiness.contains("Not enough evidence"))
        // Saved measurements survive history-list removal and do not cause repeat fetches.
        await store.check(studyID: id, runs: [], clock: clock, allowed: { true }, fetch: fetch)
        #expect(calls == 4)
        #expect(store.summary(studyID: id, runs: [], now: clock()).first { $0.horizon == .fortnight }?.measuredWindows == 1)
    }

    @Test func corruptSavedPairIsRejectedWithoutArrayTrapOrOverwrite() async throws {
        let suite = "stocksage.evaluation.corruption.\(UUID())"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("evaluation.json"), store = E(storageURL: url, defaults: defaults)
        let run = try await run(at: date("2026-08-20T13:00:00Z"))
        try #require(store.freeze(config: config, costBPS: 25, at: contract.frozenAt))
        let id = try #require(store.studies.first?.id)
        await store.check(studyID: id, runs: [run], clock: { self.date("2026-10-20T12:00:00Z") },
            allowed: { true }, fetch: { symbol, _, _ in try? self.observation(symbol: symbol, run: run) })
        try #require(E(storageURL: url, defaults: defaults).studies.first?.reviews.first?.attempts.first?.pair != nil)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var studies = try #require(object["studies"] as? [[String: Any]])
        var reviews = try #require(studies[0]["reviews"] as? [[String: Any]])
        var attempts = try #require(reviews[0]["attempts"] as? [[String: Any]])
        var pair = try #require(attempts[0]["pair"] as? [String: Any]); pair["stock"] = []
        let unsafe = try JSONDecoder().decode(E.Pair.self, from: JSONSerialization.data(withJSONObject: pair))
        #expect(unsafe.stockReturn == nil && unsafe.netReturn(costBPS: 25) == nil)
        attempts[0]["pair"] = pair; reviews[0]["attempts"] = attempts; studies[0]["reviews"] = reviews; object["studies"] = studies
        let corrupt = try JSONSerialization.data(withJSONObject: object); try corrupt.write(to: url, options: .atomic)
        let restored = E(storageURL: url, defaults: defaults)
        #expect(restored.studies.isEmpty && restored.lastError != nil)
        #expect(!restored.freeze(config: config, costBPS: 25, at: contract.frozenAt))
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test func calendarBeyondVerifiedYearRemainsExplicitlyUnavailable() async throws {
        let store = E(), captured = try await run(at: date("2026-08-20T13:00:00Z"))
        try #require(store.freeze(config: config, costBPS: 25, at: contract.frozenAt))
        // A long interrupted original run can finish later; its next fourteen sessions cross the sourced calendar boundary.
        let boundary = H.Run(id: captured.id, startedAt: captured.startedAt, completedAt: date("2026-12-21T13:00:00Z"),
            horizon: captured.horizon, predictions: captured.predictions, coverage: captured.coverage,
            measurementPolicy: captured.measurementPolicy, ranking: captured.ranking, outcomePolicy: captured.outcomePolicy)
        try #require(H.valid(boundary))
        let id = try #require(store.studies.first?.id)
        let summary = try #require(store.summary(studyID: id, runs: [boundary], now: date("2027-02-01T12:00:00Z"))
            .first { $0.horizon == .fortnight })
        #expect(summary.calendarUnavailableRuns == 1 && summary.selectedWindows == 0 && summary.meanNetReturn == nil)
        #expect(summary.readiness.contains("beyond the verified 2026 calendar"))
        var calls = 0
        await store.check(studyID: id, runs: [boundary], clock: { self.date("2027-02-01T12:00:00Z") },
            allowed: { true }, fetch: { _, _, _ in calls += 1; return nil })
        #expect(calls == 0)
    }

    @Test func invalidFreezeAndUnsafeEndpointNeverCreateAStudy() throws {
        let store = E()
        for cost in [Double.nan, Double.infinity, -1, 1001] {
            #expect(!store.freeze(config: config, costBPS: cost, at: contract.frozenAt))
        }
        let generic = StockSageLocalModelServer.Config(baseURL: URL(string: "https://invalid.example/?key=not-a-real-key")!, model: config.model)
        #expect(!store.freeze(config: generic, costBPS: 25, at: contract.frozenAt))
        #expect(store.studies.isEmpty)
        try #require(store.freeze(config: config, costBPS: 0, at: contract.frozenAt))
        let text = try #require(String(data: JSONEncoder().encode(store.studies), encoding: .utf8))
        #expect(!text.contains("127.0.0.1") && !text.contains("18080") && !text.contains("not-a-real-key"))
    }
    @Test func finiteWindowReturnsDoNotOverflowWhileAveraging() async throws {
        let store = E()
        let first = try await run(at: date("2026-08-20T13:00:00Z"))
        let next = try await run(at: date("2026-09-11T13:00:00Z"))
        try #require(store.freeze(config: config, costBPS: 25, at: contract.frozenAt))
        let id = try #require(store.studies.first?.id)
        await store.check(studyID: id, runs: [first, next], clock: { self.date("2026-10-20T12:00:00Z") },
            allowed: { true }, fetch: { symbol, from, _ in
                let run = from == H.benchmarkDay(after: first.completedAt) ? first : next
                guard let observed = try? self.observation(symbol: symbol, run: run) else { return nil }
                let dates = observed.history.dates, count = dates.count
                let close = symbol == "SPY" ? 1.0 : 1e308
                return .init(history: .init(symbol: symbol, dates: dates, opens: Array(repeating: 1, count: count),
                    highs: Array(repeating: close, count: count), lows: Array(repeating: 1, count: count),
                    closes: Array(repeating: close, count: count), volumes: Array(repeating: 1000, count: count),
                    priceSource: .massiveDaily), splitAdjusted: true, provider: E.provider, fetchedAt: observed.fetchedAt)
            })
        let summary = try #require(store.summary(studyID: id, runs: [first, next], now: date("2026-10-20T12:00:00Z"))
            .first { $0.horizon == .fortnight })
        #expect(summary.measuredWindows == 2 && summary.meanNetReturn == 1e308 && summary.meanExcessReturn == 1e308)
        #expect(summary.meanNetReturn?.isFinite == true)
    }
}
