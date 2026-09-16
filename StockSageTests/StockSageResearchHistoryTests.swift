import Foundation
import Testing
@testable import StockSage

@Suite("Saved research predictions", .serialized)
@MainActor
struct StockSageResearchHistoryTests {
    typealias History = StockSageResearchHistory

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func qualifiedResult(_ symbol: String, at: Date, qualified: Bool) -> StockSageHorizonResearch.Result {
        typealias R = StockSageHorizonResearch
        var dates: [Date] = [], day = at.addingTimeInterval(-86_400)
        while dates.count < 70 {
            if StockSageMarketHours.nasdaqDay(at: day)?.trading == true { dates.append(day) }
            day = day.addingTimeInterval(-86_400)
        }
        dates.reverse()
        let closes = (0..<70).map { $0 < 50 ? 98.0 : 99 + Double($0 - 50) / 19 }
        var highs = closes.map { $0 + 1 }; highs[59] = 104
        let history = StockSagePriceHistory(symbol: symbol, dates: dates, opens: closes, highs: highs,
            lows: closes.map { $0 - 1 }, closes: closes,
            volumes: (0..<70).map { qualified && $0 >= 67 ? 200 : 100 }, priceSource: .massiveDaily)
        let idea = StockSageIdea(symbol: symbol, market: "NASDAQ", price: 100,
            advice: .init(action: .hold, conviction: 0, regime: .range, rationale: ["Fixture"],
                stopPrice: nil, targetPrice: nil, suggestedWeight: 0, caveat: "Synthetic fixture"), spark: [],
            generatedAt: at, priceAsOf: dates.last, priceSource: .massiveDaily)
        let event = StockSageMassiveEvents.Event(id: "filing", symbol: symbol, feed: .insider,
            date: at.addingTimeInterval(-60), headline: "Original public filing", details: ["Original interpretation retained"],
            link: nil, transactionIdentity: "transaction")
        let company: [StockSageMassiveEvents.Feed: StockSageMassiveEvents.Observation] = [.insider:
            .init(symbol: symbol, feed: .insider, checkedAt: at, outcome: .answered, event: event)]
        let context = StockSageAIAssessment.Context(idea: idea, earnings: nil, company: company, at: at, quotedInUSD: true)
        let facts = ["Original public filing and interpretation"]
        let capture = R.Capture(history: history, context: context, facts: facts, coverage: [], at: at,
            blockedByThrottle: false, evidencePacket: .init(facts: [.init(key: "feed.insider.event", text: facts[0],
                required: false, availability: .available)], prePromptOmittedRecordCount: 0),
            nextEarnings: .init(outcome: .answered(.init(date: date("2026-11-24T00:00:00Z"), confirmed: true)), checkedAt: at, recordedAt: at))
        let verdict = StockSageAIAssessment.Verdict(action: .buy, reason: "Original case", risk: "Original risk", evidence: ["F1"])
        let receipt = StockSageResearchQualification.prepare(capture, horizon: .fortnight)
            .receipt(verdict: verdict, citedKeys: ["feed.insider.event"])
        return .init(verdict: verdict, levels: receipt.levels, facts: facts, note: "Original capture", at: at, model: "fixture",
            referenceClose: (100, dates.last!), evidenceReceipt: context.coverage(offered: capture.evidencePacket!.facts, verdict: verdict),
            qualification: receipt)
    }

    private func strictFixture(failure: Bool = false, allExcluded: Bool = false) -> (History.Run, StockSageHorizonResearch.Scan) {
        var scan = StockSageHorizonResearch.Scan()
        let at = date("2026-09-15T13:00:00Z")
        scan.at = at.addingTimeInterval(-1); scan.qualificationPolicyVersion = 1
        for symbol in ["AAA", "BBB", "CCC"] {
            scan.listings.append(.init(ticker: symbol, name: symbol, market: "stocks", locale: "us", active: true,
                type: "CS", currency_name: "usd", primary_exchange: "XNAS"))
            scan.results[symbol] = symbol == "CCC" && failure ? .init(note: "Original failed check", at: at)
                : qualifiedResult(symbol, at: at, qualified: symbol == "AAA" && !allExcluded)
        }
        scan.rankingFailure = "Strict comparison pending."
        return (History.snapshot(startedAt: scan.at!, completedAt: at.addingTimeInterval(1), horizon: .fortnight, scan: scan), scan)
    }

    @Test func strictQualificationArchiveRetainsRawOpinionsAndBindsScope() throws {
        let (run, scan) = strictFixture()
        #expect(run.coverage.buyCount == 3 && run.coverage.qualifiedBuyCount == 1)
        let history = History()
        try #require(history.record(run))
        try #require(history.saveCompletedChecks(run, scan: scan))
        let restored = try #require(history.completedScan(horizon: .fortnight))
        #expect(restored.scan.qualificationPolicyVersion == 1 && restored.scan.isEligible("AAA"))
        #expect(!restored.scan.isEligible("BBB") && restored.scan.results["BBB"]?.verdict == scan.results["BBB"]?.verdict)
        let archive = try #require(History.captureChecks(scan: scan, horizon: .fortnight, startedAt: run.startedAt, completedAt: run.completedAt))
        let bytes = try JSONEncoder().encode(archive)
        let decoded = try History.decodeCapturedChecks(bytes, matching: run)
        #expect(decoded == archive && decoded.qualificationPolicyVersion == 1)
        let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for changed in ["symbol", "horizon", "capturedAt", "originalAction", "missing", "citations", "unoffered", "policy"] {
            var object = original
            var rows = object["checks"] as! [[String: Any]]
            var receipt = rows[0]["qualification"] as! [String: Any]
            switch changed {
            case "symbol": receipt["symbol"] = "OTHER"
            case "horizon": receipt["horizon"] = StockSageHorizonResearch.Horizon.week.rawValue
            case "capturedAt": receipt["capturedAt"] = run.startedAt.timeIntervalSinceReferenceDate
            case "originalAction": receipt["originalAction"] = "Strong Buy"
            case "citations": receipt["citedQualifyingKeys"] = []
            case "unoffered":
                var catalysts = receipt["candidateCatalysts"] as! [[String: Any]]
                var extra = catalysts[0]
                extra["identity"] = "unoffered"
                extra["key"] = "feed.insider.transaction.unoffered"
                catalysts.append(extra); receipt["candidateCatalysts"] = catalysts
            case "policy": object["qualificationPolicyVersion"] = 99
            default: break
            }
            rows[0]["qualification"] = changed == "missing" ? nil : receipt
            object["checks"] = rows
            let corrupt = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try History.decodeCapturedChecks(corrupt, matching: run) }
        }
    }

    @Test(arguments: [false, true]) func strictRankingSavesQualifiedOrEmptyPoolWithoutRelabelingBuys(empty: Bool) async throws {
        let (pending, original) = strictFixture(allExcluded: empty)
        var scan = original, requests = 0
        let outcome = await StockSageResearchRanking.rank(scan: scan, horizon: .fortnight,
            config: .init(baseURL: URL(string: "http://127.0.0.1:1234")!, model: "offline-fixture"), isOllama: false,
            allowed: { true }, completion: { _, _, _ in
                requests += 1
                return .success(.init(text: "{\"symbols\":[\"AAA\"]}", diagnostic: .init(finish: .stop), model: "offline-fixture"))
            })
        scan.ranking = try outcome.get(); scan.rankingFailure = nil
        let run = History.snapshot(startedAt: pending.startedAt, completedAt: Date(), horizon: .fortnight, scan: scan)
        #expect(requests == (empty ? 0 : 1) && run.ranking?.version == 3)
        #expect(run.coverage.buyCount == 3 && run.coverage.qualifiedBuyCount == (empty ? 0 : 1))
        #expect(run.predictions.map(\.symbol) == (empty ? [] : ["AAA"]))
        let history = History()
        #expect(history.record(run) && history.saveCompletedChecks(run, scan: scan))
        #expect(history.completedScan(horizon: .fortnight)?.scan.results["BBB"]?.verdict?.action == .buy)
    }

    @Test func strictAmendmentKeepsAcceptedQualificationsAndSourcePolicy() throws {
        let (source, scan) = strictFixture(failure: true)
        let history = History()
        try #require(history.record(source)); try #require(history.saveCompletedChecks(source, scan: scan))
        var revised = scan
        let began = source.completedAt.addingTimeInterval(1)
        revised.at = began; revised.retainedFromRunID = source.id
        revised.results["CCC"] = qualifiedResult("CCC", at: began.addingTimeInterval(1), qualified: true)
        let run = History.snapshot(startedAt: began, completedAt: began.addingTimeInterval(2), horizon: .fortnight, scan: revised)
        #expect(run.coverage.qualifiedBuyCount == 2)
        try #require(history.saveCompletedChecks(run, scan: revised)); try #require(history.record(run))
        let restored = try #require(history.completedScan(horizon: .fortnight))
        #expect(restored.scan.results["AAA"]?.qualification == scan.results["AAA"]?.qualification)
        #expect(history.runs.last == source)
        revised.qualificationPolicyVersion = nil
        let downgraded = History.snapshot(startedAt: began, completedAt: began.addingTimeInterval(2), horizon: .fortnight, scan: revised)
        #expect(!history.record(downgraded) && !history.saveCompletedChecks(downgraded, scan: revised))
    }

    @Test func legacyQualificationFieldsRemainAbsentFromDigestMaterial() throws {
        let (run, scan) = checkpointFixture(count: 8)
        let archive = try #require(History.captureChecks(scan: scan, horizon: .fortnight,
            startedAt: run.startedAt, completedAt: run.completedAt))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(archive)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["qualificationPolicyVersion"] == nil)
        #expect((object["checks"] as? [[String: Any]])?.allSatisfy { $0["qualification"] == nil } == true)
        let restored = try History.decodeCapturedChecks(bytes, matching: run)
        #expect(try encoder.encode(restored) == bytes)
        let runObject = try #require(JSONSerialization.jsonObject(with: encoder.encode(run)) as? [String: Any])
        #expect((runObject["coverage"] as? [String: Any])?["qualifiedBuyCount"] == nil)
    }

    private func run(id: UUID = UUID(), completed: String = "2026-09-14T21:00:00Z",
                     horizon: History.Horizon = .week, referencePrice: Double? = 200,
                     policy: History.MeasurementPolicy? = nil, levels: History.Levels? = nil,
                     outcomePolicy: History.OutcomePolicy? = nil) -> History.Run {
        .init(id: id, startedAt: date(completed).addingTimeInterval(-60), completedAt: date(completed),
              horizon: horizon, predictions: [.init(symbol: "ACME", name: "Acme", action: "Buy",
                reason: "Dated evidence supports the setup", risk: "Demand may weaken", evidence: ["F1"],
                facts: ["Original observed facts"], model: "fixture-model", note: "Unvalidated research",
                referencePrice: referencePrice,
                referenceDate: referencePrice == nil ? nil : date("2026-09-11T04:00:00Z"), levels: levels)],
              coverage: .init(requested: 1, checked: 1, incomplete: 0, buyCount: 1, selection: nil),
              measurementPolicy: policy, outcomePolicy: outcomePolicy)
    }

    private var fortnightDates: [String] {
        ["09-15", "09-16", "09-17", "09-18", "09-21", "09-22", "09-23", "09-24",
         "09-25", "09-28", "09-29", "09-30", "10-01", "10-02"].map { "2026-\($0)T04:00:00Z" }
    }

    private func pathObservation(dates: [String], closes: [Double]) -> History.Observation {
        .init(history: .init(symbol: "ACME", dates: dates.map { date($0) },
            opens: Array(repeating: 100, count: closes.count), highs: closes.map { max(100, $0) + 2 },
            lows: closes.map { min(100, $0) - 2 }, closes: closes,
            volumes: Array(repeating: 100, count: closes.count), priceSource: .massiveDaily),
            splitAdjusted: true, provider: "Fixture Massive daily", fetchedAt: date("2026-10-06T12:00:00Z"))
    }
    private func observation(baseline: Double = 100, target: Double = 110,
                             adjusted: Bool = true, fetched: String = "2026-09-24T12:00:00Z") -> History.Observation {
        let values = [baseline, target]
        return .init(history: .init(symbol: "ACME", dates: [date("2026-09-15T04:00:00Z"), date("2026-09-23T04:00:00Z")],
            opens: values, highs: [baseline + 5, target], lows: values, closes: [baseline + 5, target],
            volumes: [100, 100], priceSource: .massiveDaily),
            splitAdjusted: adjusted, provider: "Fixture Massive daily", fetchedAt: date(fetched))
    }

    @Test func savedSessionDatesUseNewYorkAcrossStandardAndDaylightTime() {
        let locale = Locale(identifier: "en_US_POSIX")
        let summer = date("2026-09-15T04:00:00Z")
        let winter = date("2026-01-06T05:00:00Z")
        #expect(StockSageResearchHistoryView.sessionDateLabel(summer, locale: locale) == "Sep 15, 2026 ET")
        #expect(StockSageResearchHistoryView.sessionDateLabel(winter, locale: locale) == "Jan 6, 2026 ET")

        // Demonstrate the failing interpretation without changing process-global timezone.
        let pacific = DateFormatter()
        pacific.locale = locale
        pacific.calendar = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        pacific.dateStyle = .medium
        pacific.timeStyle = .none
        #expect(pacific.string(from: summer) == "Sep 14, 2026")
        #expect(pacific.string(from: winter) == "Jan 5, 2026")
    }

    @Test func snapshotKeepsTheOriginalTopFiveAndCoverageWithoutLaterScanMutation() throws {
        var scan = StockSageHorizonResearch.Scan()
        scan.at = date("2026-09-14T20:59:00Z")
        for index in 0..<7 {
            let symbol = "ACME\(index)"
            scan.listings.append(.init(ticker: symbol, name: "Company \(index)", market: "stocks", locale: "us",
                active: true, type: "CS", currency_name: "usd", primary_exchange: "XNAS"))
            scan.results[symbol] = .init(verdict: .init(action: index == 6 ? .strongBuy : .buy,
                reason: "Original case", risk: "Original risk", evidence: ["F1"]),
                levels: .init(entry: 200, stop: 190, target: 220, at: date("2026-09-11T04:00:00Z"), basis: "Captured ATR scenario"),
                facts: ["Dated source fact"],
                note: "Unvalidated", at: date("2026-09-14T20:59:30Z"), model: "original-model",
                referenceClose: (value: 200, at: date("2026-09-11T04:00:00Z")))
        }
        let rankedSymbols = ["ACME5", "ACME3", "ACME6", "ACME1", "ACME4"]
        scan.ranking = StockSageResearchRanking.Receipt.fixture(scan: scan, symbols: rankedSymbols,
            horizon: .fortnight, at: date("2026-09-14T20:59:59Z"))
        let snapshot = History.snapshot(startedAt: try #require(scan.at), completedAt: date("2026-09-14T21:00:00Z"),
            horizon: .fortnight, scan: scan)
        #expect(snapshot.predictions.map(\.symbol) == rankedSymbols)
        #expect(snapshot.ranking == scan.ranking && snapshot.rankingFailure == nil)
        #expect(snapshot.coverage.requested == 7 && snapshot.coverage.checked == 7 && snapshot.coverage.buyCount == 7)
        #expect(snapshot.horizon == .fortnight && snapshot.predictions[0].model == "original-model")
        scan.results.removeAll()
        #expect(snapshot.predictions[0].facts == ["Dated source fact"] && snapshot.predictions.count == 5)
        #expect(snapshot.predictions[0].levels?.stop == 190 && snapshot.predictions[0].levels?.target == 220)
        let suite = "stocksage.research.ranking.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("history.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = History(storageURL: url, defaults: defaults)
        #expect(store.record(snapshot))
        let bytes = try Data(contentsOf: url)
        let reopened = History(storageURL: url, defaults: defaults)
        #expect(reopened.runs == [snapshot] && reopened.lastError == nil)
        #expect(try Data(contentsOf: url) == bytes, "Reading never reranks or rewrites original comparison evidence")

        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        let validRanking = try #require(encoded["ranking"] as? [String: Any])
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["version"] = 999 }, { $0["method"] = "activity-sort" },
            { $0["horizon"] = History.Horizon.week.title },
            { $0["symbols"] = Array(rankedSymbols.reversed()) },
            { $0["candidateSymbols"] = Array((0..<6).map { "ACME\($0)" }) },
            { $0["at"] = snapshot.startedAt.timeIntervalSinceReferenceDate - 1 },
            { $0["at"] = snapshot.completedAt.timeIntervalSinceReferenceDate + 1 },
            { $0["rounds"] = [] }
        ]
        for change in changes {
            var object = encoded
            var ranking = validRanking
            change(&ranking)
            object["ranking"] = ranking
            let malformed = try JSONDecoder().decode(History.Run.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(!History(storageURL: nil).record(malformed), "Malformed or mismatched comparisons cannot publish picks")
        }
        var failureAndSuccess = encoded
        failureAndSuccess["rankingFailure"] = "Comparison failed"
        let contradictory = try JSONDecoder().decode(History.Run.self,
            from: JSONSerialization.data(withJSONObject: failureAndSuccess))
        #expect(!History(storageURL: nil).record(contradictory))
    }

    @Test func completedRunWithNoQualifiedBuysIsStillSaved() {
        let store = History(storageURL: nil)
        let empty = History.Run(id: UUID(), startedAt: date("2026-09-14T20:59:00Z"),
            completedAt: date("2026-09-14T21:00:00Z"), horizon: .week, predictions: [],
            coverage: .init(requested: 5, checked: 5, incomplete: 2, buyCount: 0, selection: nil))
        #expect(store.record(empty) && store.runs == [empty])
    }

    @Test func missingComparisonCannotPublishPicksAndExplicitFailurePreservesCoverage() throws {
        var scan = StockSageHorizonResearch.Scan()
        scan.listings = [.init(ticker: "ACME", name: "Acme", market: "stocks", locale: "us",
            active: true, type: "CS", currency_name: "usd", primary_exchange: "XNAS")]
        scan.results["ACME"] = .init(verdict: .init(action: .buy, reason: "Case", risk: "Risk", evidence: ["F1"]),
            facts: ["Captured source fact"], note: "Unvalidated", model: "fixture")
        let store = History(storageURL: nil)
        let pending = History.snapshot(startedAt: date("2026-09-14T20:59:00Z"),
            completedAt: date("2026-09-14T21:00:00Z"), horizon: .week, scan: scan)
        #expect(pending.predictions.isEmpty && pending.ranking == nil && pending.rankingFailure == nil)
        #expect(!store.record(pending), "A pending comparison cannot be stored as a complete legacy shortlist")

        scan.rankingFailure = "The comparative model response was invalid."
        let failed = History.snapshot(startedAt: pending.startedAt, completedAt: pending.completedAt,
            horizon: .week, scan: scan)
        #expect(store.record(failed) && failed.predictions.isEmpty && failed.coverage.buyCount == 1)
        #expect(failed.coverage.checked == 1 && failed.coverage.incomplete == 0)
        #expect(failed.rankingFailure == scan.rankingFailure)
        #expect(try JSONDecoder().decode(History.Run.self, from: JSONEncoder().encode(failed)) == failed)
        let attemptedPicks = History.Run(id: UUID(), startedAt: failed.startedAt, completedAt: failed.completedAt,
            horizon: .week, predictions: run().predictions, coverage: failed.coverage,
            rankingFailure: failed.rankingFailure)
        #expect(!store.record(attemptedPicks), "A failed comparison cannot masquerade as published picks")
        let blankFailure = History.Run(id: UUID(), startedAt: failed.startedAt, completedAt: failed.completedAt,
            horizon: .week, predictions: [], coverage: failed.coverage, rankingFailure: " \n ")
        #expect(!store.record(blankFailure))
    }

    @Test func homeUsesTheLatestCompletedRunPerHorizonEvenWhenItHasNoPicks() {
        let older = run()
        let latest = History.Run(id: UUID(), startedAt: date("2026-09-15T20:59:00Z"),
            completedAt: date("2026-09-15T21:00:00Z"), horizon: .week, predictions: [],
            coverage: .init(requested: 5, checked: 5, incomplete: 2, buyCount: 0, selection: nil))
        let fortnight = run(completed: "2026-09-13T21:00:00Z", horizon: .fortnight)
        let history = History(storageURL: nil)
        // Insert the oldest last: persistence order is not completion order.
        #expect(history.record(latest) && history.record(fortnight) && history.record(older))
        let original = history.runs
        let summary = History.homeSummary(history.runs, now: date("2026-09-15T22:00:00Z"))
        #expect(summary.latest.map(\.id) == [latest.id, fortnight.id])
        #expect(summary.latest.first?.predictions.isEmpty == true, "Never backfill older bullish picks after a newer empty run")
        #expect(summary.completedToday == 1 && summary.readyPredictions == 0)
        #expect(summary.waitingPredictions == 2 && summary.nextReviewAt != nil)
        #expect(history.runs == original && !history.isChecking)
        let empty = History.homeSummary([], now: date("2026-09-15T22:00:00Z"))
        #expect(empty.latest.isEmpty && empty.ready.isEmpty && empty.nextReviewAt == nil)
    }

    @Test func homeReviewCountsSeparateDueRetriesCompletedAndUnverifiedDates() throws {
        let now = date("2026-09-24T13:00:00Z")
        let due = run()
        var retry = run()
        retry.evaluations["ACME"] = History.evaluate(retry.predictions[0], in: retry, observation: nil, now: now)
        var finished = run()
        finished.evaluations["ACME"] = History.evaluate(finished.predictions[0], in: finished, observation: observation(), now: now)
        try #require(finished.evaluations["ACME"]?.state == .evaluated)
        let waiting = run(horizon: .fortnight)
        let futureClock = run(completed: "2026-09-25T21:00:00Z")
        let summary = History.homeSummary([finished, retry, waiting, futureClock, due], now: now)
        #expect(Set(summary.ready.map(\.id)) == Set([due.id, retry.id]))
        #expect(summary.readyPredictions == 2 && summary.waitingPredictions == 1 && summary.unavailablePredictions == 1)
        #expect(summary.nextReviewAt == History.reviewAvailableAt(for: waiting))
        #expect(History.pendingPredictions(in: finished).isEmpty && History.pendingPredictions(in: retry).count == 1)
        let unknown = run(completed: "2026-12-23T22:00:00Z", horizon: .fortnight)
        let noCalendar = History.homeSummary([unknown], now: date("2026-12-31T22:00:00Z"))
        #expect(noCalendar.readyPredictions == 0 && noCalendar.unavailablePredictions == 1 && noCalendar.nextReviewAt == nil)
        // 00:30 UTC is still the prior New York day; a device's day boundary cannot mark old picks as new.
        let dayBoundary = History.homeSummary([due], now: date("2026-09-15T00:30:00Z"))
        #expect(dayBoundary.completedToday == 1)
        #expect(History.homeSummary([due], now: date("2026-09-15T04:00:00Z")).completedToday == 0)
    }

    @Test func newSnapshotsMeasureSevenOrFourteenFullSessionsFromTheNextDateOpen() {
        // The reference excludes completion's whole New York date. A completion before
        // today's close must not spend one of its seven/fourteen sessions before entry.
        for horizon in StockSageHorizonResearch.Horizon.allCases {
            let expected = date(horizon == .week ? "2026-09-23T20:00:00Z" : "2026-10-02T20:00:00Z")
            for clock in ["2026-09-14T08:00:00Z", "2026-09-14T19:59:59Z",
                          "2026-09-14T20:00:00Z", "2026-09-14T21:00:00Z"] {
                let completed = date(clock)
                let snapshot = History.snapshot(startedAt: completed.addingTimeInterval(-60),
                    completedAt: completed, horizon: horizon, scan: .init())
                #expect(History.benchmarkDay(after: completed) == date("2026-09-15T04:00:00Z"))
                #expect(History.availability(for: snapshot, now: date("2026-10-05T12:00:00Z")).targetCloseAt == expected,
                        "A new \(horizon.rawValue) run completed at \(clock) needs the whole forward window")
            }
        }
    }

    @Test func fullSessionPolicyHonorsHolidaysEarlyCloseDSTAndUnknownYear() {
        let cases: [(String, String?)] = [
            ("2026-09-04T18:00:00Z", "2026-09-16T20:00:00Z"), // Labor Day is excluded.
            ("2026-11-17T18:00:00Z", "2026-11-27T18:00:00Z"), // Thanksgiving, then an early close.
            ("2026-10-30T18:00:00Z", "2026-11-10T21:00:00Z"), // DST changes before the benchmark.
            ("2026-12-23T18:00:00Z", nil)
        ]
        for (completed, expected) in cases {
            let original = run(completed: completed, policy: .nextTradingDateSessions)
            #expect(History.targetClose(for: original) == expected.map { date($0) })
        }
    }

    @Test func legacyAndNewPoliciesRoundTripWithoutMovingAnObservedOutcome() throws {
        let suite = "stocksage.research.policy.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("history.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let legacy = run(completed: "2026-09-14T19:59:59Z")
        let current = run(completed: "2026-09-14T19:59:59Z", policy: .nextTradingDateSessions)
        let oldData = pathObservation(dates: [fortnightDates[0], fortnightDates[5]], closes: [105, 110])
        let oldReceipt = History.evaluate(legacy.predictions[0], in: legacy, observation: oldData,
                                         now: date("2026-10-06T13:00:00Z"))
        try #require(oldReceipt.state == .evaluated && oldReceipt.dailyCloses == nil)
        let history = History(storageURL: url, defaults: defaults)
        #expect(history.record(legacy) && history.record(current))
        #expect(history.recordEvaluation(oldReceipt, runID: legacy.id, symbol: "ACME"))
        let bytes = try Data(contentsOf: url)
        let reopened = History(storageURL: url, defaults: defaults)
        let savedLegacy = try #require(reopened.runs.first { $0.id == legacy.id })
        let savedCurrent = try #require(reopened.runs.first { $0.id == current.id })
        #expect(savedLegacy.measurementPolicy == nil && savedCurrent.measurementPolicy == .nextTradingDateSessions)
        #expect(savedLegacy.ranking == nil && savedLegacy.rankingFailure == nil)
        #expect(savedCurrent.ranking == nil && savedCurrent.rankingFailure == nil,
                "Existing predictions keep their captured order without a retroactive comparison")
        #expect(History.targetClose(for: savedLegacy) == date("2026-09-22T20:00:00Z"))
        #expect(History.targetClose(for: savedCurrent) == date("2026-09-23T20:00:00Z"))
        let reopenedBytes = try Data(contentsOf: url)
        #expect(savedLegacy.evaluations["ACME"] == oldReceipt && reopenedBytes == bytes)
        #expect(savedLegacy.predictions == legacy.predictions && savedCurrent.predictions == current.predictions)

        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        encoded["measurementPolicy"] = 999
        let unknownPolicy = try JSONSerialization.data(withJSONObject: encoded)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(History.Run.self, from: unknownPolicy) }
        // Optional fields absent in baseline files must remain absent, not be backfilled.
        var oldEncoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(oldReceipt)) as? [String: Any])
        oldEncoded.removeValue(forKey: "dailyCloses")
        #expect(try JSONDecoder().decode(History.Evaluation.self,
            from: JSONSerialization.data(withJSONObject: oldEncoded)) == oldReceipt)
    }

    @Test func completeDailyClosePathShowsWeekOneReversalWithoutCountingOutsideBars() throws {
        let original = run(horizon: .fortnight, policy: .nextTradingDateSessions)
        let closes: [Double] = [105, 110, 140, 120, 125, 128, 130, 125, 120, 110, 100, 95, 80, 90]
        let data = pathObservation(dates: ["2026-09-14T04:00:00Z"] + fortnightDates + ["2026-10-05T04:00:00Z"],
            closes: [500] + closes + [10])
        let result = History.evaluate(original.predictions[0], in: original, observation: data,
                                      now: date("2026-10-06T13:00:00Z"))
        try #require(result.state == .evaluated)
        #expect(result.direction == .fell && result.comparisonReferencePrice == 100 && result.targetPrice == 90)
        let path = try #require(result.dailyCloses)
        #expect(path.map(\.price) == closes && path.count == 14)
        #expect(path.map(\.price).max() == 140 && path.map(\.price).min() == 80)
        #expect(History.seventhSessionClose(in: result, for: original)
            == .init(date: date("2026-09-23T04:00:00Z"), price: 130))
        let store = History(storageURL: nil)
        #expect(store.record(original) && store.recordEvaluation(result, runID: original.id, symbol: "ACME"))
        #expect(store.runs[0].predictions == original.predictions)
    }

    @Test func missingInteriorSessionKeepsOnlyTheEndpointResult() throws {
        let original = run(horizon: .fortnight, policy: .nextTradingDateSessions)
        let dates = fortnightDates.enumerated().filter { $0.offset != 3 }.map(\.element)
        let result = History.evaluate(original.predictions[0], in: original,
            observation: pathObservation(dates: dates, closes: Array(repeating: 110, count: dates.count)),
            now: date("2026-10-06T13:00:00Z"))
        #expect(result.state == .evaluated && result.targetPrice == 110 && result.direction == .rose)
        #expect(result.dailyCloses == nil && History.seventhSessionClose(in: result, for: original) == nil)
        #expect(result.note.contains("intervening sessions are missing or unverified"))
    }

    @Test func invalidPathsAreRejectedAndRicherRetriesCannotRewriteObservedOutcomes() throws {
        let original = run(horizon: .fortnight, policy: .nextTradingDateSessions)
        let full = History.evaluate(original.predictions[0], in: original,
            observation: pathObservation(dates: fortnightDates, closes: Array(repeating: 110, count: 14)),
            now: date("2026-10-06T13:00:00Z"))
        let path = try #require(full.dailyCloses)
        let store = History(storageURL: nil)
        try #require(store.record(original))
        let invalid: [[History.DailyClose]] = [
            Array(path.dropFirst()), Array(path.dropLast()), [path[0]] + path,
            [path[1], path[0]] + Array(path.dropFirst(2)),
            [.init(date: path[0].date, price: .nan)] + Array(path.dropFirst()),
            Array(path.dropLast()) + [.init(date: path.last!.date, price: 120)],
            [.init(date: date("2026-09-14T04:00:00Z"), price: 110)] + Array(path.dropFirst())
        ]
        for badPath in invalid {
            var corrupt = full; corrupt.dailyCloses = badPath
            #expect(!store.recordEvaluation(corrupt, runID: original.id, symbol: "ACME"))
            #expect(store.runs[0].evaluations.isEmpty)
        }
        var endpointOnly = full; endpointOnly.dailyCloses = nil
        #expect(store.recordEvaluation(endpointOnly, runID: original.id, symbol: "ACME"))
        #expect(store.recordEvaluation(full, runID: original.id, symbol: "ACME"))
        #expect(store.runs[0].evaluations["ACME"] == endpointOnly)
    }

    @Test func homeCountsObservedDirectionsWithoutTreatingOverlappingPicksAsTrades() {
        let now = date("2026-09-24T13:00:00Z")
        let finished = [110.0, 90, 100].map { target in
            var record = run()
            record.evaluations["ACME"] = History.evaluate(record.predictions[0], in: record,
                observation: observation(target: target), now: now)
            return record
        }
        var unavailable = run()
        unavailable.evaluations["ACME"] = History.evaluate(unavailable.predictions[0], in: unavailable,
            observation: nil, now: now)
        let summary = History.homeSummary(finished + [unavailable, run()], now: now)
        #expect(summary.evaluatedPredictions == 3 && summary.rosePredictions == 1)
        #expect(summary.fellPredictions == 1 && summary.flatPredictions == 1 && summary.readyPredictions == 2)
    }

    @Test func completePathReloadsAndCorruptOptionalMetadataPreservesOriginalBytes() throws {
        let suite = "stocksage.research.path.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("history.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let original = run(horizon: .fortnight, policy: .nextTradingDateSessions)
        let receipt = History.evaluate(original.predictions[0], in: original,
            observation: pathObservation(dates: fortnightDates, closes: Array(repeating: 110, count: 14)),
            now: date("2026-10-06T13:00:00Z"))
        let history = History(storageURL: url, defaults: defaults)
        try #require(history.record(original) && history.recordEvaluation(receipt, runID: original.id, symbol: "ACME"))
        let reopened = History(storageURL: url, defaults: defaults)
        #expect(reopened.lastError == nil && reopened.runs[0].evaluations["ACME"] == receipt)
        let validBytes = try Data(contentsOf: url)
        var object = try #require(JSONSerialization.jsonObject(with: validBytes) as? [String: Any])
        var runs = try #require(object["runs"] as? [[String: Any]])
        var evaluations = try #require(runs[0]["evaluations"] as? [String: [String: Any]])
        var path = try #require(evaluations["ACME"]?["dailyCloses"] as? [[String: Any]])
        path.remove(at: 3)
        evaluations["ACME"]?["dailyCloses"] = path
        runs[0]["evaluations"] = evaluations; object["runs"] = runs
        let corruptBytes = try JSONSerialization.data(withJSONObject: object)
        try corruptBytes.write(to: url)
        let blocked = History(storageURL: url, defaults: defaults)
        #expect(blocked.lastError != nil && !blocked.record(run()))
        #expect(try Data(contentsOf: url) == corruptBytes)
        #expect(history.runs[0].evaluations["ACME"] == receipt, "An unreadable disk update must not mutate a last-good capture")
    }

    @Test func futureClosesRespectHolidaysEarlyCloseAndDST() {
        #expect(History.targetClose(after: date("2026-11-17T22:00:00Z"), horizon: .week)
                == date("2026-11-27T18:00:00Z"))
        #expect(History.targetClose(after: date("2026-11-17T22:00:00Z"), horizon: .fortnight)
                == date("2026-12-08T21:00:00Z"))
        #expect(History.targetClose(after: date("2026-10-28T21:00:00Z"), horizon: .week)
                == date("2026-11-06T21:00:00Z"))
        #expect(History.targetClose(after: date("2026-09-14T19:59:59Z"), horizon: .week)
                == date("2026-09-22T20:00:00Z"))
        #expect(History.targetClose(after: date("2026-09-14T20:00:00Z"), horizon: .week)
                == date("2026-09-23T20:00:00Z"))
        #expect(History.targetClose(after: date("2026-12-23T22:00:00Z"), horizon: .fortnight) == nil)
        #expect(History.targetClose(after: Date(timeIntervalSince1970: .nan), horizon: .week) == nil)
    }

    @Test func benchmarkSkipsCompletionDateAndRespectsHolidaysEarlyClosesAndDST() {
        #expect(History.benchmarkDay(after: date("2026-09-14T08:00:00Z")) == date("2026-09-15T04:00:00Z"))
        #expect(History.benchmarkDay(after: date("2026-09-14T21:00:00Z")) == date("2026-09-15T04:00:00Z"))
        #expect(History.benchmarkDay(after: date("2026-11-25T22:00:00Z")) == date("2026-11-27T05:00:00Z"))
        #expect(History.benchmarkDay(after: date("2026-11-27T15:00:00Z")) == date("2026-11-30T05:00:00Z"))
        #expect(History.benchmarkDay(after: date("2026-10-30T21:00:00Z")) == date("2026-11-02T05:00:00Z"))
        #expect(History.benchmarkDay(after: date("2026-03-06T22:00:00Z")) == date("2026-03-09T04:00:00Z"))
        #expect(History.benchmarkDay(after: date("2026-09-12T12:00:00Z")) == date("2026-09-14T04:00:00Z"))
        #expect(History.benchmarkDay(after: date("2026-12-31T22:00:00Z")) == nil)
        #expect(History.benchmarkDay(after: Date(timeIntervalSince1970: .nan)) == nil)
    }

    @Test func splitAdjustedComparisonRetainsOriginalReferenceAndSeparatesFlat() throws {
        let original = run()
        let evaluated = History.evaluate(original.predictions[0], in: original,
            observation: observation(), now: date("2026-09-24T13:00:00Z"))
        #expect(evaluated.state == .evaluated && evaluated.direction == .rose)
        #expect(abs(try #require(evaluated.priceReturn) - 0.10) < 0.000000001)
        #expect(evaluated.comparisonReferencePrice == 100 && evaluated.targetPrice == 110)
        #expect(evaluated.comparisonReferenceDate == date("2026-09-15T04:00:00Z"))
        #expect(evaluated.calendarBasis.contains("daily open"))
        #expect(original.predictions[0].referencePrice == 200)
        #expect(evaluated.buyDirectionSupported == true)
        let flat = History.evaluate(original.predictions[0], in: original,
            observation: observation(target: 100), now: date("2026-09-24T13:00:00Z"))
        #expect(flat.direction == .flat && flat.buyDirectionSupported == nil)
        let fell = History.evaluate(original.predictions[0], in: original,
            observation: observation(target: 90), now: date("2026-09-24T13:00:00Z"))
        #expect(fell.direction == .fell && fell.buyDirectionSupported == false)
    }

    @Test func gainsBeforePredictionCannotMakeAFallingForwardBenchmarkLookSupported() throws {
        let original = run(referencePrice: 100)
        let evaluated = History.evaluate(original.predictions[0], in: original,
            observation: observation(baseline: 120, target: 110), now: date("2026-09-24T13:00:00Z"))
        #expect(evaluated.state == .evaluated && evaluated.direction == .fell && evaluated.buyDirectionSupported == false)
        #expect(evaluated.comparisonReferencePrice == 120 && original.predictions[0].referencePrice == 100)
        #expect(abs(try #require(evaluated.priceReturn) - (110.0 / 120.0 - 1)) < 0.000000001)
        let withoutReference = run(referencePrice: nil)
        #expect(History.evaluate(withoutReference.predictions[0], in: withoutReference,
            observation: observation(), now: date("2026-09-24T13:00:00Z")).state == .evaluated)
    }

    @Test func originalAndCompletionDayBarsCannotSubstituteForTheNextTradingDay() {
        let original = run()
        let history = StockSagePriceHistory(symbol: "ACME",
            dates: [date("2026-09-11T04:00:00Z"), date("2026-09-14T04:00:00Z"), date("2026-09-23T04:00:00Z")],
            opens: [100, 100, 110], highs: [100, 100, 110], lows: [100, 100, 110], closes: [100, 100, 110],
            volumes: [100, 100, 100], priceSource: .massiveDaily)
        let receipt = History.evaluate(original.predictions[0], in: original,
            observation: .init(history: history, splitAdjusted: true, provider: "Fixture", fetchedAt: date("2026-09-24T12:00:00Z")),
            now: date("2026-09-24T13:00:00Z"))
        #expect(receipt.state == .dataUnavailable && receipt.priceReturn == nil)
    }

    @Test func earlyUnadjustedMissingAndMalformedDataCannotProduceEvaluation() {
        let original = run()
        #expect(History.availability(for: original, now: date("2026-09-23T19:59:59Z")).state == .notDue)
        #expect(History.availability(for: original, now: date("2026-09-23T20:00:00Z")).state == .notDue)
        #expect(History.reviewAvailableAt(for: original) == date("2026-09-24T04:00:00Z"))
        #expect(History.availability(for: original, now: date("2026-09-24T03:59:59Z")).state == .notDue)
        #expect(History.availability(for: original, now: date("2026-09-24T04:00:00Z")).state == .due)
        #expect(History.evaluate(original.predictions[0], in: original,
            observation: observation(fetched: "2026-09-23T20:01:00Z"),
            now: date("2026-09-23T20:02:00Z")).state == .notDue)
        #expect(History.evaluate(original.predictions[0], in: original,
            observation: observation(fetched: "2026-09-23T20:01:00Z"),
            now: date("2026-09-24T13:00:00Z")).state == .dataUnavailable)
        #expect(History.evaluate(original.predictions[0], in: original, observation: nil,
            now: date("2026-09-24T13:00:00Z")).state == .dataUnavailable)
        #expect(History.evaluate(original.predictions[0], in: original, observation: observation(adjusted: false),
            now: date("2026-09-24T13:00:00Z")).state == .dataUnavailable)
        #expect(History.evaluate(original.predictions[0], in: original, observation: observation(),
            now: date("2026-09-23T19:59:59Z")).state == .notDue)
        let missingBaseline = History.Observation(history: .init(symbol: "ACME", dates: [date("2026-09-23T04:00:00Z")],
            opens: [110], highs: [110], lows: [110], closes: [110], volumes: [100], priceSource: .massiveDaily),
            splitAdjusted: true, provider: "Fixture", fetchedAt: date("2026-09-24T12:00:00Z"))
        #expect(History.evaluate(original.predictions[0], in: original, observation: missingBaseline,
            now: date("2026-09-24T13:00:00Z")).state == .dataUnavailable)
        let wrongSymbol = History.Observation(history: .init(symbol: "WRONG", dates: observation().history.dates,
            opens: [100, 110], highs: [100, 110], lows: [100, 110], closes: [100, 110], volumes: [100, 100], priceSource: .massiveDaily),
            splitAdjusted: true, provider: "Fixture", fetchedAt: date("2026-09-24T12:00:00Z"))
        #expect(History.evaluate(original.predictions[0], in: original, observation: wrongSymbol,
            now: date("2026-09-24T13:00:00Z")).state == .dataUnavailable)
    }

    @Test func atomicPersistencePreservesOriginalAcrossReloadAndRejectsReplacement() throws {
        let suite = "stocksage.research.history.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("history.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = History(storageURL: url, defaults: defaults)
        let original = run()
        #expect(store.record(original))
        let evaluated = History.evaluate(original.predictions[0], in: original, observation: observation(),
            now: date("2026-09-24T13:00:00Z"))
        #expect(store.recordEvaluation(evaluated, runID: original.id, symbol: "ACME"))
        var wrongBenchmark = evaluated
        wrongBenchmark.comparisonReferenceDate = date("2026-09-16T04:00:00Z")
        #expect(!store.recordEvaluation(wrongBenchmark, runID: original.id, symbol: "ACME"))
        var partialDailyBar = evaluated
        partialDailyBar.fetchedAt = date("2026-09-23T20:01:00Z")
        #expect(!store.recordEvaluation(partialDailyBar, runID: original.id, symbol: "ACME"))
        let reopened = History(storageURL: url, defaults: defaults)
        #expect(reopened.runs.first?.predictions == original.predictions)
        #expect(reopened.runs.first?.evaluations["ACME"] == evaluated)
        #expect(reopened.record(original), "Repeating the identical completion is idempotent")
        #expect(reopened.runs.count == 1 && reopened.runs[0].evaluations["ACME"] == evaluated)
        #expect(!reopened.record(run(id: original.id, completed: "2026-09-15T21:00:00Z")))
        #expect(reopened.runs[0].completedAt == original.completedAt)
    }

    @Test func exactTargetSessionAndFiniteAlignedBarsAreRequired() {
        let original = run()
        let variants: [StockSagePriceHistory] = [
            .init(symbol: "ACME", dates: [date("2026-09-15T04:00:00Z"), date("2026-09-24T04:00:00Z")],
                opens: [100, 120], highs: [100, 120], lows: [100, 120], closes: [100, 120], volumes: [100, 100], priceSource: .massiveDaily),
            .init(symbol: "ACME", dates: observation().history.dates,
                opens: [100], highs: [100, 110], lows: [100, 110], closes: [100, 110], volumes: [100, 100], priceSource: .massiveDaily),
            .init(symbol: "ACME", dates: observation().history.dates,
                opens: [100, 110], highs: [100, 110], lows: [100, 110], closes: [.nan, 110], volumes: [100, 100], priceSource: .massiveDaily),
            .init(symbol: "ACME", dates: [date("2026-09-15T04:00:00Z"), date("2026-09-15T12:00:00Z")],
                opens: [100, 110], highs: [100, 110], lows: [100, 110], closes: [100, 110], volumes: [100, 100], priceSource: .massiveDaily)
        ]
        for history in variants {
            let receipt = History.evaluate(original.predictions[0], in: original,
                observation: .init(history: history, splitAdjusted: true, provider: "Fixture", fetchedAt: date("2026-09-24T12:00:00Z")),
                now: date("2026-09-24T13:00:00Z"))
            #expect(receipt.state == .dataUnavailable && receipt.priceReturn == nil)
        }
    }

    @Test func twoStoreInstancesMergeNewRunsAndFailedRetryKeepsTheObservedOutcome() throws {
        let suite = "stocksage.research.merge.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("history.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let first = History(storageURL: url, defaults: defaults)
        let second = History(storageURL: url, defaults: defaults)
        let original = run()
        #expect(first.record(original))
        #expect(second.record(run()))
        #expect(second.runs.count == 2, "A stale in-memory reader must not erase another completed run")
        let evaluated = History.evaluate(original.predictions[0], in: original, observation: observation(),
            now: date("2026-09-24T13:00:00Z"))
        #expect(first.recordEvaluation(evaluated, runID: original.id, symbol: "ACME"))
        let retry = History.evaluate(original.predictions[0], in: original, observation: nil,
            now: date("2026-09-25T13:00:00Z"))
        #expect(first.recordEvaluation(retry, runID: original.id, symbol: "ACME"))
        #expect(first.runs.first(where: { $0.id == original.id })?.evaluations["ACME"] == evaluated)
        #expect(first.runs.count == 2)
    }

    @Test func manualChecksFetchOnlyActiveUnevaluatedPredictionsAndRetryMissingData() async throws {
        let store = History(storageURL: nil)
        let due = run()
        let later = run(completed: "2026-09-24T21:00:00Z")
        #expect(store.record(due) && store.record(later))
        var calls = 0
        await store.checkActive(clock: { date("2026-09-24T13:00:00Z") }, allowed: { true }) { _, current in
            calls += 1
            #expect(current.id == due.id)
            return nil
        }
        #expect(calls == 1 && !store.isChecking)
        #expect(store.runs.first(where: { $0.id == due.id })?.evaluations["ACME"]?.state == .dataUnavailable)
        await store.checkActive(clock: { date("2026-09-24T13:00:00Z") }, allowed: { true }) { _, _ in
            calls += 1
            return observation()
        }
        #expect(calls == 2)
        await store.checkActive(clock: { date("2026-09-24T13:00:00Z") }, allowed: { true }) { _, _ in
            calls += 1
            return observation()
        }
        #expect(calls == 2, "Already evaluated predictions must not refetch")
        #expect(store.runs.first(where: { $0.id == due.id })?.predictions == due.predictions)
    }

    @Test func boundedActiveCheckAdvancesPastUnavailableDataWithoutDroppingRuns() async {
        let store = History(storageURL: nil)
        for _ in 0..<26 { #expect(store.record(run())) }
        var visited: Set<UUID> = []
        await store.checkActive(clock: { date("2026-09-24T13:00:00Z") }, allowed: { true }) { _, current in
            visited.insert(current.id)
            return nil
        }
        #expect(visited.count == 25 && store.runs.count == 26)
        #expect(store.lastCheckSummary == "Checked 25 active predictions. 1 remains for another pass.")
        await store.checkActive(clock: { date("2026-09-25T13:00:00Z") }, allowed: { true }) { _, current in
            visited.insert(current.id)
            return nil
        }
        #expect(visited.count == 26 && store.runs.count == 26)
    }

    @Test(arguments: [true, false])
    func cancelledOrRevokedManualCheckDiscardsLateResponse(cancel: Bool) async throws {
        let store = History(storageURL: nil)
        #expect(store.record(run()))
        var permitted = true
        var continuation: CheckedContinuation<History.Observation?, Never>?
        let checking = Task {
            await store.checkActive(clock: { date("2026-09-24T13:00:00Z") }, allowed: { permitted }) { _, _ in
                await withCheckedContinuation { continuation = $0 }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
        let response = try #require(continuation)
        if cancel { checking.cancel() } else { permitted = false }
        response.resume(returning: observation())
        await checking.value
        #expect(store.runs[0].evaluations.isEmpty && !store.isChecking)
    }

    @Test func completedResearchSavesOnceButCancellationNeverSavesPartialPredictions() async throws {
        let store = History(storageURL: nil)
        let research = StockSageHorizonResearch(history: store)
        let listing = StockSageHorizonResearch.Listing(ticker: "ACME", name: "Acme", market: "stocks", locale: "us",
            active: true, type: "CS", currency_name: "usd", primary_exchange: "XNAS")
        let result = StockSageHorizonResearch.Result(verdict: .init(action: .buy, reason: "Case", risk: "Risk", evidence: ["F1"]),
            facts: ["Source fact"], note: "Unvalidated", model: "fixture",
            referenceClose: (value: 200, at: date("2026-09-11T04:00:00Z")))
        let started = research.start(.week, allowed: { true }, universe: { .init([listing]) },
            rank: { scan, horizon in .success(.fixture(scan: scan, symbols: ["ACME"], horizon: horizon, at: Date())) },
            analyze: { _ in var current = result; current.at = Date(); return current })
        #expect(started)
        var deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while research.running != nil, ContinuousClock.now < deadline { await Task.yield() }
        try #require(research.running == nil)
        #expect(store.runs.count == 1 && store.runs[0].predictions.first?.symbol == "ACME")
        let original = store.runs[0]
        var continuation: CheckedContinuation<StockSageHorizonResearch.Result, Never>?
        let secondStarted = research.start(.fortnight, allowed: { true }, universe: { .init([listing]) }, analyze: { _ in
            await withCheckedContinuation { continuation = $0 }
        })
        #expect(secondStarted)
        deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
        let response = try #require(continuation)
        research.stop()
        response.resume(returning: result)
        deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while research.running != nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(research.running == nil && store.runs == [original])
    }

    @Test func anOldCalendarUnavailableReceiptSurvivesAReadAfterCalendarExpansion() throws {
        let suite = "stocksage.research.calendar.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("history.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let original = run()
        let store = History(storageURL: url, defaults: defaults)
        #expect(store.record(original))
        // Emulate a receipt written before this run's exchange calendar was supported.
        let old = History.Evaluation(state: .dataUnavailable, checkedAt: date("2026-09-24T13:00:00Z"),
            targetCloseAt: nil, note: "Calendar was unavailable at the time")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var records = try #require(object["runs"] as? [[String: Any]])
        records[0]["evaluations"] = ["ACME": try JSONSerialization.jsonObject(with: JSONEncoder().encode(old))]
        object["runs"] = records
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let reopened = History(storageURL: url, defaults: defaults)
        #expect(reopened.lastError == nil && reopened.runs[0].predictions == original.predictions)
        #expect(reopened.runs[0].evaluations["ACME"]?.targetCloseAt == nil)
    }

    @Test func unreadableHistoryIsNeverReplacedAndNilURLIsMemoryOnly() throws {
        let suite = "stocksage.research.corrupt.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("history.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("unreadable original prediction bytes".utf8)
        try original.write(to: url)
        let store = History(storageURL: url, defaults: defaults)
        #expect(store.lastError != nil && !store.record(run()))
        #expect(try Data(contentsOf: url) == original)
        let memory = History(storageURL: nil)
        #expect(memory.record(run()) && memory.runs.count == 1 && memory.lastError == nil)
    }
}

extension StockSageResearchHistoryTests {
    /// Explicit, offline recovery receipt. Never discovers or writes the owner's app directory.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STOCKSAGE_RECOVERY_DIR"] != nil))
    func validateSuppliedRecoveryCheckpoint() throws {
        let path = try #require(ProcessInfo.processInfo.environment["STOCKSAGE_RECOVERY_DIR"])
        try #require(path.hasPrefix("/"))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        struct Document: Decodable { let version: Int; let runs: [History.Run] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: directory.appendingPathComponent("runs-before.json")))
        try #require(document.version == 1)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("live-checks.json"))
        let archive = try JSONDecoder().decode(History.CompletedChecks.self, from: bytes)
        let original = try #require(document.runs.first { $0.startedAt == archive.startedAt && $0.horizon == archive.horizon })
        let checked = try History.decodeCapturedChecks(bytes, matching: original)
        let scan = try #require(History.restoreChecks(checked, matching: original))
        let suite = "stocksage.recovery.validation.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = directory.appendingPathComponent("validated/history.json")
        let history = History(storageURL: target, defaults: defaults)
        try #require(history.record(original))
        try #require(history.saveCompletedChecks(original, scan: scan))
        let reopened = try #require(History(storageURL: target, defaults: defaults).completedScan(horizon: original.horizon == .week ? .week : .fortnight))
        #expect(reopened.run == original && reopened.scan.results.count == archive.checks.count)
        print("RECOVERY_VALIDATED \(archive.checks.count) original checks, \(original.coverage.buyCount) eligible, \(original.coverage.incomplete) incomplete; no model or provider requests")
    }

    @Test func historyCompletionWinsOverPendingCheckpointAfterCrash() throws {
        let (pending, scan) = checkpointFixture(count: 8)
        let suite = "stocksage.checkpoint.crash.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let history = History(storageURL: url, defaults: defaults)
        try #require(history.saveCompletedChecks(pending, scan: scan))
        let checkpointURL = directory.appendingPathComponent("completed-14.json")
        let originalBytes = try Data(contentsOf: checkpointURL)
        var ranked = scan
        ranked.rankingFailure = nil
        ranked.ranking = .fixture(scan: scan, symbols: ["S003", "S002", "S001", "S000"], horizon: .fortnight, at: pending.completedAt.addingTimeInterval(10))
        let saved = History.snapshot(id: pending.id, startedAt: pending.startedAt, completedAt: pending.completedAt.addingTimeInterval(11), horizon: .fortnight, scan: ranked)
        try #require(history.record(saved))
        let restored = try #require(History(storageURL: url, defaults: defaults).completedScan(horizon: .fortnight))
        #expect(restored.run == saved && restored.scan.topBuys.map(\.ticker) == saved.predictions.map(\.symbol))
        #expect(try Data(contentsOf: checkpointURL) == originalBytes)
    }

    private func checkpointFixture(count: Int = 500, start: Date? = nil) -> (History.Run, StockSageHorizonResearch.Scan) {
        let started = start ?? date("2026-09-15T07:00:00Z")
        let reference = started.addingTimeInterval(-86_400)
        var scan = StockSageHorizonResearch.Scan()
        scan.at = started
        for index in 0..<count {
            let symbol = String(format: "S%03d", index)
            scan.listings.append(.init(ticker: symbol, name: "Original company \(index)", market: "stocks", locale: "us",
                active: true, type: "CS", currency_name: "usd", primary_exchange: "XNAS"))
            let action: TradeAdvice.Action = index < 83 ? (index.isMultiple(of: 2) ? .buy : .strongBuy) : .hold
            scan.results[symbol] = .init(verdict: index >= count - min(4, count) ? nil :
                .init(action: action, reason: "Original case \(symbol)", risk: "Original risk \(symbol)", evidence: ["F1", "F2"]),
                levels: .init(entry: 100, stop: 95, target: 110, at: reference, basis: "Original captured scenario"),
                facts: ["Original fact \(symbol)", "Original counterevidence \(symbol)"], note: "Original coverage note",
                at: started.addingTimeInterval(Double(index) + 0.123456), model: "original-model",
                referenceClose: (100, reference), coverage: [.init(source: "News", state: .partial, checkedAt: reference)])
        }
        scan.rankingFailure = "Comparison could not complete; original checks retained."
        return (History.snapshot(startedAt: started, completedAt: started.addingTimeInterval(Double(count) + 60),
            horizon: .fortnight, scan: scan), scan)
    }

    @Test func completedCheckRoundTripRetainsEvidenceAndDiagnosticReceipts() throws {
        let (original, scan) = checkpointFixture(count: 8)
        let captured = try #require(History.captureChecks(scan: scan, horizon: .fortnight,
            startedAt: original.startedAt, completedAt: original.completedAt))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(captured)) as? [String: Any])
        var checks = try #require(object["checks"] as? [[String: Any]])
        let symbol = scan.listings[0].ticker
        let diagnosticID = UUID().uuidString
        checks[0]["evidenceReceipt"] = ["symbol": symbol, "requiredKeys": ["quote"],
            "missingOrUnknownRequiredKeys": [], "offeredKeys": ["quote", "news.item"],
            "omittedKeys": ["news.other"], "prePromptOmittedRecordCount": 2,
            "citedKeys": ["quote", "news.item"]] as [String: Any]
        checks[0]["diagnosticID"] = diagnosticID
        checks[0]["diagnosticsComplete"] = true
        object["checks"] = checks
        let decoded = try History.decodeCapturedChecks(JSONSerialization.data(withJSONObject: object), matching: original)
        let restored = try #require(History.restoreChecks(decoded, matching: original))
        let recaptured = try #require(History.captureChecks(scan: restored, horizon: .fortnight,
            startedAt: original.startedAt, completedAt: original.completedAt))
        let result = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(recaptured)) as? [String: Any])
        let rows = try #require(result["checks"] as? [[String: Any]])
        #expect(rows[0]["diagnosticID"] as? String == diagnosticID)
        #expect(rows[0]["diagnosticsComplete"] as? Bool == true)
        let evidence = rows[0]["evidenceReceipt"] as? [String: Any]
        #expect(evidence?["offeredKeys"] as? [String] == ["quote", "news.item"])
        #expect(evidence?["omittedKeys"] as? [String] == ["news.other"])
        #expect(evidence?["prePromptOmittedRecordCount"] as? Int == 2)
        #expect(restored.results[symbol]?.facts == scan.results[symbol]?.facts)
    }

    @Test func latestCheckpointRetainsAllChecksAndOriginalDatesWithoutGrowingPredictionHistory() throws {
        let (original, scan) = checkpointFixture()
        let suite = "stocksage.research.checkpoint.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = History(storageURL: url, defaults: defaults)
        try #require(store.record(original))
        let historyBytes = try Data(contentsOf: url)
        try #require(store.saveCompletedChecks(original, scan: scan))
        #expect(try Data(contentsOf: url) == historyBytes, "Saving all checks never rewrites original prediction history")
        let reopened = History(storageURL: url, defaults: defaults)
        let restored = try #require(reopened.completedScan(horizon: .fortnight))
        #expect(restored.run == original && restored.scan.listings == scan.listings)
        #expect(restored.scan.results.count == 500 && restored.run.coverage.buyCount == 83 && restored.run.coverage.incomplete == 4)
        for listing in scan.listings {
            let expected = try #require(scan.results[listing.ticker])
            let actual = try #require(restored.scan.results[listing.ticker])
            #expect(actual.verdict == expected.verdict && actual.facts == expected.facts && actual.at == expected.at)
            #expect(actual.levels == expected.levels && actual.coverage == expected.coverage && actual.model == expected.model)
            #expect(actual.referenceClose?.value == expected.referenceClose?.value && actual.referenceClose?.at == expected.referenceClose?.at)
        }
        #expect(restored.scan.topBuys.isEmpty && reopened.runs == [original])
        let (next, nextScan) = checkpointFixture(start: original.startedAt.addingTimeInterval(86_400))
        try #require(reopened.saveCompletedChecks(next, scan: nextScan))
        #expect(!reopened.saveCompletedChecks(original, scan: scan), "A late older callback cannot replace a later complete scan")
        #expect(reopened.completedScan(horizon: .fortnight)?.run == next)
        #expect(try Data(contentsOf: url) == historyBytes)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("completed-") && $0.hasSuffix(".json") }
        #expect(files == ["completed-14.json"], "Later checks replace only the bounded latest checkpoint")
    }

    @Test func capturedArchiveRejectsCorruptionAndPreservesTheAppleEpoch() throws {
        let (original, scan) = checkpointFixture(count: 8)
        let archive = try #require(History.captureChecks(scan: scan, horizon: .fortnight,
            startedAt: original.startedAt, completedAt: original.completedAt))
        let bytes = try JSONEncoder().encode(archive)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["startedAt"] as? Double == original.startedAt.timeIntervalSinceReferenceDate)
        #expect(try History.decodeCapturedChecks(bytes, matching: original) == archive)
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["version"] = 99 }, { $0["horizon"] = 7 }, { $0["startedAt"] = original.startedAt.timeIntervalSince1970 },
            { object in var checks = object["checks"] as! [[String: Any]]; checks.append(checks[0]); object["checks"] = checks },
            { object in var checks = object["checks"] as! [[String: Any]]; checks[0]["at"] = original.completedAt.timeIntervalSinceReferenceDate + 1; object["checks"] = checks },
            { object in var checks = object["checks"] as! [[String: Any]]; var verdict = checks[0]["verdict"] as! [String: Any]; verdict["action"] = "invented"; checks[0]["verdict"] = verdict; object["checks"] = checks },
            { object in var checks = object["checks"] as! [[String: Any]]; var verdict = checks[0]["verdict"] as! [String: Any]; verdict["evidence"] = ["F999"]; checks[0]["verdict"] = verdict; object["checks"] = checks },
            { object in var checks = object["checks"] as! [[String: Any]]; checks[0]["coverage"] = [["source": "News", "state": "invented"]]; object["checks"] = checks }
        ]
        for change in changes {
            var corrupt = object; change(&corrupt)
            let data = try JSONSerialization.data(withJSONObject: corrupt)
            #expect(throws: (any Error).self) { try History.decodeCapturedChecks(data, matching: original) }
        }
        #expect(throws: (any Error).self) {
            try History.decodeCapturedChecks(Data(repeating: 32, count: History.maximumCompletedChecksBytes + 1), matching: original)
        }
    }

    @Test func malformedCheckpointCannotBeSilentlyReplacedAndLegacyHistoryStillReads() throws {
        let (original, scan) = checkpointFixture(count: 8)
        let suite = "stocksage.research.checkpoint-corrupt.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = History(storageURL: url, defaults: defaults)
        try #require(store.record(original))
        #expect(store.completedScan(horizon: .fortnight) == nil, "Legacy counts never invent original evidence")
        let checkpointURL = directory.appendingPathComponent("completed-14.json")
        let corrupt = Data("{malformed original checkpoint".utf8)
        try corrupt.write(to: checkpointURL)
        #expect(store.completedScan(horizon: .fortnight) == nil && store.lastError != nil)
        #expect(!store.saveCompletedChecks(original, scan: scan))
        #expect(try Data(contentsOf: checkpointURL) == corrupt)
        #expect(History(storageURL: url, defaults: defaults).runs == [original])
    }
    private func amendedFixture(_ source: History.Run, scan: StockSageHorizonResearch.Scan,
                                repairCount: Int = 4) -> (History.Run, StockSageHorizonResearch.Scan) {
        var amended = scan
        let began = source.completedAt.addingTimeInterval(1)
        amended.at = began
        amended.retainedFromRunID = source.id
        amended.ranking = nil
        amended.rankingFailure = "Amended checks awaiting comparison."
        for (index, listing) in scan.listings.filter({ scan.results[$0.ticker]?.verdict == nil }).prefix(repairCount).enumerated() {
            var result = scan.results[listing.ticker]!
            result.at = began.addingTimeInterval(Double(index) + 0.25)
            result.verdict = .init(action: .buy, reason: "New case", risk: "New risk", evidence: ["F1"])
            result.facts = ["New source fact for \(listing.ticker)"]
            result.note = "New capture; original failure preserved separately."
            amended.results[listing.ticker] = result
        }
        return (History.snapshot(startedAt: began, completedAt: began.addingTimeInterval(10),
            horizon: .fortnight, scan: amended), amended)
    }

    @Test func amendedCheckpointPreservesOriginalFourFailuresAndAllOtherChecks() async throws {
        let (source, original) = checkpointFixture()
        let suite = "stocksage.checkpoint.amended.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let checkpointURL = directory.appendingPathComponent("completed-14.json")
        let history = History(storageURL: url, defaults: defaults)
        try #require(history.record(source))
        try #require(history.saveCompletedChecks(source, scan: original))
        let originalHistoryBytes = try Data(contentsOf: url)
        let (pending, amended) = amendedFixture(source, scan: original)
        try #require(history.saveCompletedChecks(pending, scan: amended))
        #expect(try Data(contentsOf: url) == originalHistoryBytes)
        let restored = try #require(History(storageURL: url, defaults: defaults).completedScan(horizon: .fortnight))
        #expect(restored.scan.retainedFromRunID == source.id && restored.run.coverage.incomplete == 0)
        #expect(restored.run.coverage.buyCount == 87 && restored.scan.listings == original.listings)
        for listing in original.listings.prefix(496) {
            #expect(History.CompletedCheck(listing: listing, result: restored.scan.results[listing.ticker]!)
                == History.CompletedCheck(listing: listing, result: original.results[listing.ticker]!))
        }
        let checkpoint = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: checkpointURL)) as? [String: Any])
        let receipt = try #require(checkpoint["amendment"] as? [String: Any])
        let failures = try JSONDecoder().decode([History.CompletedCheck].self,
            from: JSONSerialization.data(withJSONObject: try #require(receipt["previousFailures"])))
        #expect(failures == original.listings.suffix(4).map { History.CompletedCheck(listing: $0, result: original.results[$0.ticker]!) })
        #expect(try Data(contentsOf: checkpointURL).count <= History.maximumCompletedChecksBytes)

        // A crash after recording the completed ranking must restore that actual completion,
        // while retaining the amendment receipt and leaving checkpoint bytes unchanged.
        try #require(history.record(pending))
        let checkpointBytes = try Data(contentsOf: checkpointURL)
        var ranked = amended
        ranked.rankingFailure = nil
        let preferred = ["S499", "S498", "S003", "S001", "S000"]
        var compared: Set<String> = []
        let outcome = await StockSageResearchRanking.rank(scan: amended, horizon: .fortnight,
            config: .init(baseURL: URL(string: "http://127.0.0.1:1234")!, model: "offline-ranking-fixture"),
            isOllama: false, allowed: { true }, completion: { _, user, _ in
                guard let object = try? JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: Any],
                      let candidates = object["candidates"] as? [[String: Any]] else {
                    Issue.record("Ranking supplied an invalid candidate packet")
                    return .failure(.init(diagnostic: .init(category: .responseShape)))
                }
                let symbols = candidates.compactMap { $0["symbol"] as? String }
                compared.formUnion(symbols)
                let selected = symbols.sorted {
                    let left = preferred.firstIndex(of: $0) ?? Int.max
                    let right = preferred.firstIndex(of: $1) ?? Int.max
                    return left == right ? $0 < $1 : left < right
                }.prefix(5)
                let bytes = try! JSONSerialization.data(withJSONObject: ["symbols": Array(selected)])
                return .success(.init(text: String(decoding: bytes, as: UTF8.self),
                    diagnostic: .init(finish: .stop), model: "offline-ranking-fixture"))
            })
        let ranking = try outcome.get()
        #expect(StockSageResearchRanking.valid(ranking) && ranking.rounds.count > 1)
        #expect(ranking.symbols == preferred && compared == Set(ranking.candidateSymbols) && compared.count == 87)
        ranked.ranking = ranking
        let success = History.snapshot(startedAt: pending.startedAt, completedAt: Date(),
            horizon: .fortnight, scan: ranked, originalRunID: pending.id)
        try #require(history.record(success))
        let recovered = try #require(History(storageURL: url, defaults: defaults).completedScan(horizon: .fortnight))
        #expect(recovered.run == success && recovered.scan.retainedFromRunID == source.id)
        #expect(recovered.scan.topBuys.map(\.ticker) == success.predictions.map(\.symbol))
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(history.runs.last == source)
        try #require(history.saveCompletedChecks(success, scan: ranked))
        #expect(History(storageURL: url, defaults: defaults).completedScan(horizon: .fortnight)?.run == success)
    }

    @Test(arguments: ["completedResult", "listingOrder", "oldReplacement", "missingParent", "wrongParent", "missingCheckpoint"])
    func amendedCheckpointRejectsChangedRetainedInputsOrInvalidParent(change: String) throws {
        let (source, original) = checkpointFixture(count: 8)
        let history = History()
        try #require(history.record(source))
        if change != "missingCheckpoint" { try #require(history.saveCompletedChecks(source, scan: original)) }
        let (_, prepared) = amendedFixture(source, scan: original)
        var amended = prepared
        switch change {
        case "completedResult": amended.results["S000"]?.facts = ["Changed earlier complete check"]
        case "listingOrder": amended.listings.swapAt(0, 1)
        case "oldReplacement": amended.results["S004"]?.at = source.startedAt
        case "missingParent": amended.retainedFromRunID = UUID()
        case "wrongParent":
            let (other, _) = checkpointFixture(count: 9)
            try #require(history.record(other))
            amended.retainedFromRunID = other.id
        default: break
        }
        let run = History.snapshot(startedAt: amended.at!, completedAt: amended.at!.addingTimeInterval(10),
            horizon: .fortnight, scan: amended)
        #expect(!history.saveCompletedChecks(run, scan: amended))
        #expect(history.completedScan(horizon: .fortnight)?.run == (change == "missingCheckpoint" ? nil : source))
        if change == "missingParent" || change == "wrongParent" { #expect(!history.record(run)) }
    }

    @Test func repeatedAmendmentRetainsEarliestCapturesAndRejectsUnlinkedComparison() throws {
        let (source, original) = checkpointFixture(count: 8)
        let history = History()
        try #require(history.record(source))
        try #require(history.saveCompletedChecks(source, scan: original))
        let (first, firstScan) = amendedFixture(source, scan: original, repairCount: 1)
        try #require(history.saveCompletedChecks(first, scan: firstScan))
        try #require(history.record(first))
        let (second, secondScan) = amendedFixture(first, scan: firstScan, repairCount: 1)
        try #require(history.saveCompletedChecks(second, scan: secondScan))
        try #require(history.record(second))
        let restored = try #require(history.completedScan(horizon: .fortnight))
        #expect(restored.scan.results["S000"]?.at == original.results["S000"]?.at)
        #expect(restored.scan.results["S004"]?.at == firstScan.results["S004"]?.at)
        #expect(restored.run.coverage.incomplete == 2 && history.runs.last == source)
        var lostLink = secondScan
        lostLink.retainedFromRunID = nil
        let invalid = History.snapshot(startedAt: second.startedAt, completedAt: second.completedAt.addingTimeInterval(1),
            horizon: .fortnight, scan: lostLink, originalRunID: second.id)
        #expect(!history.record(invalid), "Comparison-only retries must keep their amendment parent")
    }

    @Test func amendedCheckpointRejectsChangedRetainedFactAfterRelaunch() throws {
        let (source, original) = checkpointFixture(count: 8)
        let suite = "stocksage.checkpoint.amendment-corrupt.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let checkpointURL = directory.appendingPathComponent("completed-14.json")
        let history = History(storageURL: url, defaults: defaults)
        try #require(history.record(source))
        try #require(history.saveCompletedChecks(source, scan: original))
        let (pending, amended) = amendedFixture(source, scan: original)
        try #require(history.saveCompletedChecks(pending, scan: amended))
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: checkpointURL)) as? [String: Any])
        var checks = object["completedChecks"] as! [String: Any]
        var rows = checks["checks"] as! [[String: Any]]
        rows[0]["facts"] = ["Tampered retained evidence", "Original counterevidence S000"]
        checks["checks"] = rows; object["completedChecks"] = checks
        let corrupted = try JSONSerialization.data(withJSONObject: object)
        try corrupted.write(to: checkpointURL)
        let reopened = History(storageURL: url, defaults: defaults)
        #expect(reopened.completedScan(horizon: .fortnight) == nil && reopened.lastError != nil)
        #expect(try Data(contentsOf: checkpointURL) == corrupted && reopened.runs == [source])
    }

    @Test(arguments: [8, 500])
    func repeatedRepairsPreserveEveryOriginalFailedCheck(count: Int) throws {
        let (source, original) = checkpointFixture(count: count)
        let suite = "stocksage.checkpoint.ancestry.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let checkpointURL = directory.appendingPathComponent("completed-14.json")
        let history = History(storageURL: url, defaults: defaults)
        try #require(history.record(source))
        try #require(history.saveCompletedChecks(source, scan: original))
        let (first, firstScan) = amendedFixture(source, scan: original, repairCount: 1)
        try #require(history.saveCompletedChecks(first, scan: firstScan))
        try #require(history.record(first))
        let (second, secondScan) = amendedFixture(first, scan: firstScan, repairCount: 1)
        try #require(history.saveCompletedChecks(second, scan: secondScan))
        try #require(history.record(second))
        let bytes = try Data(contentsOf: checkpointURL)
        let checkpoint = try JSONDecoder().decode(History.CompletedCheckpoint.self, from: bytes)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let previous = try JSONDecoder().decode([History.Amendment].self,
            from: JSONSerialization.data(withJSONObject: try #require(object["previousAmendments"])))
        #expect(previous.count == 1 && previous.first?.sourceRunID == source.id)
        var reconstructed = checkpoint.completedChecks
        for receipt in [try #require(checkpoint.amendment)] + previous {
            let parent = try #require(history.runs.first { $0.id == receipt.sourceRunID })
            let failed = Dictionary(uniqueKeysWithValues: receipt.previousFailures.map { ($0.listing.ticker, $0) })
            reconstructed = .init(version: 1, horizon: parent.horizon, startedAt: parent.startedAt,
                checks: reconstructed.checks.map { failed[$0.listing.ticker] ?? $0 })
        }
        let expected = try #require(History.captureChecks(scan: original, horizon: .fortnight,
            startedAt: source.startedAt, completedAt: source.completedAt))
        #expect(reconstructed == expected, "Repeated repairs must retain the first overwritten failure too")
        #expect(reconstructed.checks[count - 4].verdict == nil)
        let restored = try #require(History(storageURL: url, defaults: defaults).completedScan(horizon: .fortnight))
        #expect(restored.run == second && restored.run.coverage.incomplete == 2)
        // Comparison-only completion/reconciliation must carry all earlier amendment receipts.
        let later = History.snapshot(startedAt: second.startedAt, completedAt: second.completedAt.addingTimeInterval(1),
            horizon: .fortnight, scan: secondScan, originalRunID: second.id)
        try #require(history.record(later))
        #expect(History(storageURL: url, defaults: defaults).completedScan(horizon: .fortnight)?.run == later)
        #expect(try Data(contentsOf: checkpointURL) == bytes)
        try #require(history.saveCompletedChecks(later, scan: secondScan))
        let updatedObject = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: checkpointURL)) as? [String: Any])
        let retained = try JSONDecoder().decode([History.Amendment].self,
            from: JSONSerialization.data(withJSONObject: try #require(updatedObject["previousAmendments"])))
        #expect(retained == previous && history.runs.last == source)
    }

    @Test(arguments: ["missing", "fact", "digest", "source", "duplicate", "tooMany"])
    func corruptedAmendmentAncestryCannotRestoreOrReplaceEvidence(change: String) throws {
        let (source, original) = checkpointFixture(count: 8)
        let suite = "stocksage.checkpoint.bad-ancestry.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let checkpointURL = directory.appendingPathComponent("completed-14.json")
        let history = History(storageURL: url, defaults: defaults)
        try #require(history.record(source))
        try #require(history.saveCompletedChecks(source, scan: original))
        let (first, firstScan) = amendedFixture(source, scan: original, repairCount: 1)
        try #require(history.saveCompletedChecks(first, scan: firstScan))
        try #require(history.record(first))
        let (second, secondScan) = amendedFixture(first, scan: firstScan, repairCount: 1)
        try #require(history.saveCompletedChecks(second, scan: secondScan))
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: checkpointURL)) as? [String: Any])
        var ancestors = try #require(object["previousAmendments"] as? [[String: Any]])
        switch change {
        case "missing": ancestors = []
        case "fact":
            var failed = ancestors[0]["previousFailures"] as! [[String: Any]]
            failed[0]["facts"] = ["Changed earliest failed evidence"]
            ancestors[0]["previousFailures"] = failed
        case "digest": ancestors[0]["sourceChecksDigest"] = String(repeating: "0", count: 64)
        case "source": ancestors[0]["sourceRunID"] = UUID().uuidString
        case "duplicate": ancestors.append(ancestors[0])
        case "tooMany": ancestors = Array(repeating: ancestors[0], count: 501)
        default: break
        }
        object["previousAmendments"] = ancestors
        let corrupted = try JSONSerialization.data(withJSONObject: object)
        try corrupted.write(to: checkpointURL)
        let reopened = History(storageURL: url, defaults: defaults)
        #expect(reopened.completedScan(horizon: .fortnight) == nil && reopened.lastError != nil)
        #expect(!reopened.saveCompletedChecks(second, scan: secondScan))
        #expect(try Data(contentsOf: checkpointURL) == corrupted && reopened.runs == [first, source])
    }


    // MARK: - Daily-bar first-hit outcome policy

    private var newYork: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }

    /// A new-policy run. `stop: nil` captures a prediction with no scenario levels at all.
    private func dailyRun(horizon: History.Horizon = .week, referencePrice: Double? = 100,
                          stop: Double? = 90, target: Double = 120,
                          completed: String = "2026-09-14T21:00:00Z") -> History.Run {
        run(completed: completed, horizon: horizon, referencePrice: referencePrice,
            policy: .nextTradingDateSessions,
            levels: stop.map { History.Levels(entry: 100, stop: $0, target: target,
                at: date("2026-09-11T04:00:00Z"), basis: "Captured ATR scenario") },
            outcomePolicy: .dailyBarFirstHit)
    }

    private var weekSessions: [String] { Array(fortnightDates.prefix(7)) }

    /// One adjusted series: the saved reference bar followed by monitoring sessions.
    private func dailyObservation(highs: [Double], lows: [Double], opens: [Double]? = nil,
                                  closes: [Double]? = nil, sessions: [String]? = nil,
                                  referenceClose: Double? = 100, fetched: String? = nil,
                                  symbol: String = "ACME") -> History.Observation {
        let count = highs.count
        let stamps = Array((sessions ?? fortnightDates).prefix(count)).map { date($0) }
        let barOpens = opens ?? (0..<count).map { min(max(100, lows[$0]), highs[$0]) }
        let barCloses = closes ?? barOpens
        var dates: [Date] = [], o: [Double] = [], h: [Double] = [], l: [Double] = [], c: [Double] = []
        if let referenceClose {
            dates.append(date("2026-09-11T04:00:00Z"))
            o.append(referenceClose); h.append(referenceClose); l.append(referenceClose); c.append(referenceClose)
        }
        dates += stamps; o += barOpens; h += highs; l += lows; c += barCloses
        return .init(history: .init(symbol: symbol, dates: dates, opens: o, highs: h, lows: l, closes: c,
            volumes: Array(repeating: 100, count: dates.count), priceSource: .massiveDaily),
            splitAdjusted: true, provider: "Fixture Massive daily",
            fetchedAt: fetched.map { date($0) } ?? settledMorning(after: stamps.last ?? dates[0]))
    }

    /// Midnight New York on the day after a session, when that session's daily aggregate is settled.
    private func settledMorning(after session: Date) -> Date {
        newYork.date(byAdding: .day, value: 1, to: newYork.startOfDay(for: session))!
    }
    private func dailyNow(afterSessions count: Int, sessions: [String]? = nil) -> Date {
        settledMorning(after: date((sessions ?? fortnightDates)[count - 1])).addingTimeInterval(60)
    }

    @Test func firstTerminalBarWinsAndSameBarUsesStop() throws {
        let original = dailyRun()
        let targetFirst = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: [105, 121, 125], lows: [98, 95, 89]),
            now: date("2026-09-18T04:01:00Z"))
        #expect(targetFirst.terminalKind == .targetHit)
        #expect(targetFirst.state == .evaluated && targetFirst.outcomePrice == 120)
        #expect(targetFirst.terminalAt == date("2026-09-16T04:00:00Z"))
        #expect(targetFirst.sameBarStopFirst == nil && targetFirst.dailyBars?.count == 2)
        #expect(targetFirst.adjustedStop == 90 && targetFirst.adjustedTarget == 120 && targetFirst.adjustedEntry == 100)
        #expect(targetFirst.targetCloseAt == History.targetClose(for: original),
                "The scheduled horizon close is preserved even when the scenario finishes early")
        #expect(targetFirst.dailyCloses == nil)

        let sameBar = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: [105, 121], lows: [98, 89]),
            now: date("2026-09-17T04:01:00Z"))
        #expect(sameBar.terminalKind == .stopHit && sameBar.sameBarStopFirst == true)
        #expect(sameBar.outcomePrice == 90 && sameBar.terminalAt == date("2026-09-16T04:00:00Z"))
    }

    @Test func stopBeforeTargetAndGapsUseTheSessionOpen() throws {
        let original = dailyRun()
        let stopFirst = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: [105, 100, 125], lows: [98, 89, 95]),
            now: dailyNow(afterSessions: 3))
        #expect(stopFirst.terminalKind == .stopHit && stopFirst.outcomePrice == 90)
        #expect(stopFirst.sameBarStopFirst == nil && stopFirst.dailyBars?.count == 2)

        let gapDown = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: [105, 88], lows: [98, 84], opens: [100, 85], closes: [100, 86]),
            now: dailyNow(afterSessions: 2))
        #expect(gapDown.terminalKind == .stopHit && gapDown.outcomePrice == 85,
                "A gap through the stop is observed at the session open, not at the captured stop")

        let gapUp = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: [105, 132], lows: [98, 128], opens: [100, 130], closes: [100, 131]),
            now: dailyNow(afterSessions: 2))
        #expect(gapUp.terminalKind == .targetHit && gapUp.outcomePrice == 130)
    }

    @Test(arguments: [History.Horizon.week, History.Horizon.fortnight])
    func noHitStaysActiveUntilTheExactHorizonSessionClose(horizon: History.Horizon) throws {
        let original = dailyRun(horizon: horizon)
        let sessions = horizon == .week ? weekSessions : fortnightDates
        let count = sessions.count
        let quiet = (0..<count).map { _ in 105.0 }
        let closes = (0..<count).map { 100 + Double($0) / 10 }

        let early = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: Array(quiet.prefix(count - 1)),
                lows: Array(repeating: 95, count: count - 1), closes: Array(closes.prefix(count - 1))),
            now: dailyNow(afterSessions: count - 1))
        #expect(early.state == .notDue && early.terminalKind == nil,
                "No hit before the horizon stays active and stores no terminal receipt")

        let finished = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: quiet, lows: Array(repeating: 95, count: count), closes: closes),
            now: dailyNow(afterSessions: count))
        #expect(finished.state == .evaluated && finished.terminalKind == .horizonClose)
        #expect(finished.terminalAt == date(sessions[count - 1]) && finished.dailyBars?.count == count)
        #expect(finished.outcomePrice == closes[count - 1])
        #expect(finished.sameBarStopFirst == nil)
        #expect(finished.terminalAt.map(newYork.startOfDay) ==
                History.targetClose(for: original).map(newYork.startOfDay))
    }

    @Test func missingInteriorSessionCannotEstablishFirstHitOrder() throws {
        let original = dailyRun()
        let gapped = ["2026-09-15T04:00:00Z", "2026-09-16T04:00:00Z", "2026-09-18T04:00:00Z"]
        let active = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: [105, 106, 125], lows: [98, 97, 96], sessions: gapped),
            now: date("2026-09-19T04:01:00Z"))
        #expect(active.state == .notDue && active.terminalKind == nil,
                "A hole at 2026-09-17 cannot be closed by substituting the 09-18 bar")

        let atHorizon = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: [105, 106, 125], lows: [98, 97, 96], sessions: gapped,
                fetched: "2026-09-24T04:00:00Z"),
            now: dailyNow(afterSessions: 7))
        #expect(atHorizon.state == .dataUnavailable && atHorizon.terminalKind == nil)

        let terminalBeforeTheHole = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: [105, 106, 125], lows: [98, 85, 96], sessions: gapped),
            now: date("2026-09-19T04:01:00Z"))
        #expect(terminalBeforeTheHole.terminalKind == .stopHit && terminalBeforeTheHole.outcomePrice == 90,
                "A terminal event strictly before the hole is still the verified first event")
    }

    @Test func splitAdjustsCapturedLevelsAndAnUnverifiedRatioFailsClosed() throws {
        let original = dailyRun()
        // A 2:1 split halves the freshly adjusted reference close; the scenario stays equivalent.
        let split = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: [52, 61], lows: [48, 49], opens: [50, 50], closes: [50, 60],
                referenceClose: 50),
            now: dailyNow(afterSessions: 2))
        #expect(split.terminalKind == .targetHit && split.outcomePrice == 60)
        #expect(split.adjustedEntry == 50 && split.adjustedStop == 45 && split.adjustedTarget == 60)
        #expect(original.predictions[0].levels?.target == 120, "The captured scenario stays immutable")

        for broken in ["missingReferenceBar", "zeroReferenceClose"] {
            let receipt = History.evaluate(original.predictions[0], in: original,
                observation: dailyObservation(highs: [105, 121], lows: [98, 95],
                    referenceClose: broken == "missingReferenceBar" ? nil : 0),
                now: dailyNow(afterSessions: 2))
            #expect(receipt.state == .dataUnavailable && receipt.terminalKind == nil, "\(broken)")
        }
        let withoutSavedReference = dailyRun(referencePrice: nil)
        #expect(History.evaluate(withoutSavedReference.predictions[0], in: withoutSavedReference,
            observation: dailyObservation(highs: [105, 121], lows: [98, 95], referenceClose: nil),
            now: dailyNow(afterSessions: 2)).state == .dataUnavailable)
    }

    @Test func predictionsWithoutLevelsFinishOnlyAtTheHorizonClose() throws {
        let original = dailyRun(stop: nil)
        #expect(original.predictions[0].levels == nil)
        let early = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: [105, 300], lows: [98, 1]),
            now: dailyNow(afterSessions: 2))
        #expect(early.state == .notDue && early.terminalKind == nil,
                "Missing levels cannot classify a first hit, however extreme the bar")
        let finished = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: Array(repeating: 300, count: 7),
                lows: Array(repeating: 1, count: 7), opens: Array(repeating: 100, count: 7),
                closes: Array(repeating: 111, count: 7)),
            now: dailyNow(afterSessions: 7))
        #expect(finished.terminalKind == .horizonClose && finished.outcomePrice == 111)
        #expect(finished.adjustedStop == nil && finished.adjustedTarget == nil && finished.adjustedEntry == nil)
    }

    @Test(arguments: ["daylight-change", "thanksgiving-and-early-close"])
    func verifiedSessionCountsSurviveHolidaysEarlyClosesAndDaylightChange(schedule: String) throws {
        let completed = schedule == "daylight-change" ? "2026-10-28T21:00:00Z" : "2026-11-20T21:00:00Z"
        let sessions = schedule == "daylight-change"
            ? ["2026-10-29T04:00:00Z", "2026-10-30T04:00:00Z", "2026-11-02T05:00:00Z", "2026-11-03T05:00:00Z",
               "2026-11-04T05:00:00Z", "2026-11-05T05:00:00Z", "2026-11-06T05:00:00Z"]
            : ["2026-11-23T05:00:00Z", "2026-11-24T05:00:00Z", "2026-11-25T05:00:00Z", "2026-11-27T05:00:00Z",
               "2026-11-30T05:00:00Z", "2026-12-01T05:00:00Z", "2026-12-02T05:00:00Z"]
        let original = dailyRun(completed: completed)
        let receipt = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: Array(repeating: 105, count: 7),
                lows: Array(repeating: 95, count: 7), closes: Array(repeating: 103, count: 7),
                sessions: sessions),
            now: dailyNow(afterSessions: 7, sessions: sessions))
        #expect(receipt.terminalKind == .horizonClose && receipt.outcomePrice == 103)
        #expect(receipt.dailyBars?.map(\.date) == sessions.map { date($0) },
                "Exactly seven verified Nasdaq sessions, skipping the holiday and spanning the clock change")
    }

    @Test func legacyRunsKeepEndpointOnlyReceiptsAndEncoding() throws {
        let legacy = run()
        #expect(legacy.outcomePolicy == nil)
        let receipt = History.evaluate(legacy.predictions[0], in: legacy, observation: observation(),
            now: date("2026-09-24T13:00:00Z"))
        #expect(receipt.state == .evaluated && receipt.direction == .rose)
        #expect(receipt.terminalKind == nil && receipt.terminalAt == nil && receipt.outcomePrice == nil)
        #expect(receipt.dailyBars == nil && receipt.adjustedStop == nil && receipt.sameBarStopFirst == nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(receipt)) as? [String: Any])
        for key in ["terminalKind", "terminalAt", "outcomePrice", "dailyBars", "adjustedEntry",
                    "adjustedStop", "adjustedTarget", "adjustmentRatio", "sameBarStopFirst"] {
            #expect(object[key] == nil, "\(key) must stay absent from a legacy endpoint receipt")
        }
        let runObject = try #require(JSONSerialization.jsonObject(with: encoder.encode(legacy)) as? [String: Any])
        #expect(runObject["outcomePolicy"] == nil)
        #expect(History.snapshot(startedAt: date("2026-09-14T20:59:00Z"), completedAt: date("2026-09-14T21:00:00Z"),
            horizon: .week, scan: StockSageHorizonResearch.Scan()).outcomePolicy == .dailyBarFirstHit,
            "Every new snapshot carries the explicit daily-bar policy")
    }

    @Test func terminalReceiptsValidateByRecomputationAndCannotBeRewritten() throws {
        let suite = "stocksage.research.firsthit.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("history.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = History(storageURL: url, defaults: defaults)
        let original = dailyRun()
        try #require(store.record(original))
        let hit = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: [105, 121], lows: [98, 95]),
            now: dailyNow(afterSessions: 2))
        try #require(hit.terminalKind == .targetHit)
        try #require(store.recordEvaluation(hit, runID: original.id, symbol: "ACME"))

        let laterStop = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: Array(repeating: 105, count: 7),
                lows: [98, 95, 80, 95, 95, 95, 95], closes: Array(repeating: 100, count: 7)),
            now: dailyNow(afterSessions: 7))
        try #require(laterStop.terminalKind == .stopHit)
        #expect(store.recordEvaluation(laterStop, runID: original.id, symbol: "ACME"))
        #expect(store.runs[0].evaluations["ACME"] == hit, "An evaluated terminal receipt is immutable")

        for corrupted in ["control", "kind", "price", "terminalAt", "bars", "adjustedStop",
                          "adjustedTarget", "sameBar", "ratio", "outcomePolicy"] {
            var forged = hit
            switch corrupted {
            case "kind": forged.terminalKind = .stopHit
            case "price": forged.outcomePrice = 121
            case "terminalAt": forged.terminalAt = date("2026-09-15T04:00:00Z")
            case "bars": forged.dailyBars = forged.dailyBars.map { Array($0.dropLast()) }
            case "adjustedStop": forged.adjustedStop = 80
            case "adjustedTarget": forged.adjustedTarget = 104
            case "sameBar": forged.sameBarStopFirst = true
            case "ratio": forged.adjustmentRatio = 2
            default: break
            }
            let host = corrupted == "outcomePolicy" ? run(id: original.id) : original
            let isolated = History(storageURL: nil)
            try #require(isolated.record(host))
            #expect(isolated.recordEvaluation(forged, runID: host.id, symbol: "ACME") == (corrupted == "control"),
                    "\(corrupted)")
        }
        let reopened = History(storageURL: url, defaults: defaults)
        #expect(reopened.runs.first { $0.id == original.id }?.evaluations["ACME"] == hit)
        #expect(reopened.lastError == nil)
    }


    @Test func activeChecksStoreOnlyTerminalOrUnavailableReceipts() async throws {
        let store = History(storageURL: nil)
        let active = dailyRun()
        try #require(store.record(active))
        #expect(History.availability(for: active, now: dailyNow(afterSessions: 1)).state == .due,
                "A daily-policy run is checkable once its first monitoring session has ended")
        #expect(History.availability(for: active, now: date("2026-09-15T23:59:00Z")).state == .notDue)
        var calls = 0
        await store.checkActive(clock: { self.dailyNow(afterSessions: 2) }, allowed: { true }) { _, _ in
            calls += 1
            return self.dailyObservation(highs: [105, 106], lows: [95, 96])
        }
        #expect(calls == 1 && store.runs[0].evaluations["ACME"] == nil,
                "A verified no-hit result before the horizon stores no receipt and stays active")
        let activeReceipt = History.evaluate(active.predictions[0], in: active,
            observation: dailyObservation(highs: [105, 106], lows: [95, 96]),
            now: dailyNow(afterSessions: 2))
        #expect(activeReceipt.state == .notDue && activeReceipt.terminalKind == nil)
        #expect(!store.recordEvaluation(activeReceipt, runID: active.id, symbol: "ACME"),
                "The store itself refuses to persist a still-active prediction as a receipt")
        #expect(store.lastCheckSummary == "Checked 1 active prediction.")

        await store.checkActive(clock: { self.dailyNow(afterSessions: 2) }, allowed: { true }) { _, _ in
            calls += 1
            return nil
        }
        #expect(calls == 2 && store.runs[0].evaluations["ACME"]?.state == .dataUnavailable)

        await store.checkActive(clock: { self.dailyNow(afterSessions: 3) }, allowed: { true }) { _, _ in
            calls += 1
            return self.dailyObservation(highs: [105, 106, 121], lows: [95, 96, 97])
        }
        #expect(calls == 3 && store.runs[0].evaluations["ACME"]?.terminalKind == .targetHit)
        #expect(store.lastCheckSummary == "Checked 1 active prediction. 1 completed.")

        await store.checkActive(clock: { self.dailyNow(afterSessions: 4) }, allowed: { true }) { _, _ in
            calls += 1
            return nil
        }
        #expect(calls == 3, "A completed terminal outcome is never refetched")
        #expect(store.runs[0].predictions == active.predictions)
    }

    @Test func boundedActiveCheckReportsCompletedAndRemainingCounts() async {
        let store = History(storageURL: nil)
        for _ in 0..<26 { #expect(store.record(dailyRun())) }
        await store.checkActive(clock: { self.dailyNow(afterSessions: 2) }, allowed: { true }) { _, _ in
            self.dailyObservation(highs: [105, 121], lows: [95, 96])
        }
        #expect(store.lastCheckSummary == "Checked 25 active predictions. 25 completed. 1 remains for another pass.")
        #expect(store.runs.filter { $0.evaluations["ACME"]?.terminalKind == .targetHit }.count == 25)
        await store.checkActive(clock: { self.dailyNow(afterSessions: 2) }, allowed: { true }) { _, _ in
            self.dailyObservation(highs: [105, 121], lows: [95, 96])
        }
        #expect(store.lastCheckSummary == "Checked 1 active prediction. 1 completed.")
        #expect(store.runs.count == 26)
    }

    @Test func homeSummaryWaitsForTheFirstMonitoringSessionOnDailyPolicyRuns() throws {
        let active = dailyRun()
        let legacy = run()
        let summary = History.homeSummary([active, legacy], now: date("2026-09-15T12:00:00Z"))
        #expect(summary.waitingPredictions == 2 && summary.readyPredictions == 0)
        #expect(summary.nextReviewAt == History.checkAvailableAt(for: active))
        #expect(try #require(summary.nextReviewAt) < #require(History.reviewAvailableAt(for: legacy)),
                "The new policy becomes checkable long before the legacy horizon date ends")
        let afterFirstSession = History.homeSummary([active, legacy], now: dailyNow(afterSessions: 1))
        #expect(afterFirstSession.readyPredictions == 1 && afterFirstSession.ready.map(\.id) == [active.id])
    }


    /// A terminal receipt of the requested kind, produced by the real evaluator.
    private func terminalReceipt(_ kind: History.Evaluation.TerminalKind) -> (History.Run, History.Evaluation) {
        let original = dailyRun()
        let observation: History.Observation
        let now: Date
        switch kind {
        case .targetHit:
            observation = dailyObservation(highs: [105, 121], lows: [98, 95])
            now = dailyNow(afterSessions: 2)
        case .stopHit:
            observation = dailyObservation(highs: [105, 121], lows: [98, 89])
            now = dailyNow(afterSessions: 2)
        case .horizonClose:
            observation = dailyObservation(highs: Array(repeating: 105, count: 7),
                lows: Array(repeating: 95, count: 7), closes: Array(repeating: 97, count: 7))
            now = dailyNow(afterSessions: 7)
        }
        return (original, History.evaluate(original.predictions[0], in: original,
            observation: observation, now: now))
    }

    @Test func homeSummaryCountsTerminalKindsSeparatelyFromLegacyDirections() throws {
        var runs: [History.Run] = []
        for kind in [History.Evaluation.TerminalKind.targetHit, .stopHit, .horizonClose] {
            var (original, receipt) = terminalReceipt(kind)
            try #require(receipt.terminalKind == kind)
            original.evaluations["ACME"] = receipt
            runs.append(original)
        }
        let legacy = run()
        var legacyRun = legacy
        legacyRun.evaluations["ACME"] = History.evaluate(legacy.predictions[0], in: legacy,
            observation: observation(), now: date("2026-09-24T13:00:00Z"))
        runs.append(legacyRun)

        let summary = History.homeSummary(runs, now: date("2026-10-06T13:00:00Z"))
        #expect(summary.targetHits == 1)
        #expect(summary.stopHits == 1)
        #expect(summary.horizonCloses == 1)
        #expect(summary.rosePredictions == 1 && summary.fellPredictions == 0 && summary.flatPredictions == 0,
                "Legacy direction counts cover only endpoint-policy receipts")
        #expect(summary.evaluatedPredictions == 4)
        let horizon = try #require(runs[2].evaluations["ACME"])
        #expect(horizon.direction == .fell && horizon.priceReturn != nil,
                "A horizon close reports its own signed return and is never relabelled a target hit")
    }

    @Test func outcomeCopyNamesTheTerminalStateAndItsSession() throws {
        let (_, stopReceipt) = terminalReceipt(.stopHit)
        #expect(StockSageResearchHistoryView.outcomeSummary(stopReceipt).hasPrefix("Stop hit"))
        let (_, targetReceipt) = terminalReceipt(.targetHit)
        #expect(StockSageResearchHistoryView.outcomeSummary(targetReceipt).hasPrefix("Target hit"))
        let (_, horizonReceipt) = terminalReceipt(.horizonClose)
        #expect(StockSageResearchHistoryView.outcomeSummary(horizonReceipt).hasPrefix("Horizon close"))
        for receipt in [stopReceipt, targetReceipt, horizonReceipt] {
            let text = StockSageResearchHistoryView.outcomeSummary(receipt)
            #expect(text.contains("%"), "Every terminal state shows its measured return")
            #expect(text.contains(StockSageResearchHistoryView.sessionDateLabel(try #require(receipt.terminalAt))),
                    "The terminal session date, not the scheduled horizon date")
        }
        let active = dailyRun()
        #expect(StockSageResearchHistoryView.outcomeSummary(
            History.availability(for: active, now: dailyNow(afterSessions: 1)), run: active) == "Active")
        #expect(StockSageResearchHistoryView.outcomeSummary(
            History.availability(for: active, now: date("2026-09-15T12:00:00Z")), run: active) == "Active")
        var unavailable = stopReceipt
        unavailable = History.evaluate(active.predictions[0], in: active, observation: nil,
            now: dailyNow(afterSessions: 2))
        #expect(StockSageResearchHistoryView.outcomeSummary(unavailable) == "Data unavailable")
        #expect(StockSageResearchHistoryView.outcomeSummary(
            History.evaluate(run().predictions[0], in: run(), observation: observation(),
                now: date("2026-09-24T13:00:00Z"))).hasPrefix("Rose"),
            "Legacy endpoint receipts keep their direction copy")
    }

    @Test func sameBarOutcomesDiscloseTheConservativeStopFirstRule() throws {
        let original = dailyRun()
        let sameBar = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: [105, 121], lows: [98, 89]),
            now: dailyNow(afterSessions: 2))
        try #require(sameBar.sameBarStopFirst == true)
        #expect(sameBar.note.contains("The daily bar reached both levels; intraday order is unavailable, so the conservative stop-first rule was applied."))
        #expect(sameBar.note.contains("Daily bars cannot establish intraday order or an actual fill."))
    }


    // MARK: - Compatibility regressions

    private func fileStore(_ name: String) throws -> (History, URL, UserDefaults, String) {
        let suite = "stocksage.research.\(name).\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("history.json")
        return (History(storageURL: url, defaults: defaults), url, defaults, suite)
    }

    @Test func legacyRunsAndEndpointReceiptsRoundTripByteIdentically() throws {
        var legacy = run()
        legacy.evaluations["ACME"] = History.evaluate(legacy.predictions[0], in: legacy,
            observation: observation(), now: date("2026-09-24T13:00:00Z"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(legacy)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["outcomePolicy"] == nil)
        let receipt = try #require((object["evaluations"] as? [String: Any])?["ACME"] as? [String: Any])
        for key in ["terminalKind", "terminalAt", "outcomePrice", "adjustmentRatio", "adjustedEntry",
                    "adjustedStop", "adjustedTarget", "dailyBars", "sameBarStopFirst"] {
            #expect(receipt[key] == nil, "\(key)")
        }
        let decoded = try JSONDecoder().decode(History.Run.self, from: bytes)
        #expect(decoded == legacy && decoded.outcomePolicy == nil)
        #expect(try encoder.encode(decoded) == bytes, "A decoded legacy run re-encodes to the same bytes")

        let (store, url, defaults, suite) = try fileStore("legacy-bytes")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try #require(store.record(run(id: legacy.id)))
        try #require(store.recordEvaluation(try #require(legacy.evaluations["ACME"]), runID: legacy.id, symbol: "ACME"))
        func storedLegacy() throws -> Data {
            let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let runs = try #require(document["runs"] as? [[String: Any]])
            let match = try #require(runs.first { $0["id"] as? String == legacy.id.uuidString.lowercased()
                || $0["id"] as? String == legacy.id.uuidString })
            return try JSONSerialization.data(withJSONObject: match, options: [.sortedKeys])
        }
        let before = try storedLegacy()
        try #require(store.record(dailyRun()))
        #expect(try storedLegacy() == before, "Saving a new-policy run cannot rewrite a legacy run's bytes")
        let reopened = History(storageURL: url, defaults: defaults)
        #expect(reopened.lastError == nil && reopened.runs.count == 2)
        #expect(try storedLegacy() == before)
    }

    @Test(arguments: ["terminalKind", "unknownTerminalKind", "missingTerminalKind", "terminalAt",
                      "outcomePrice", "adjustmentRatio", "adjustedEntry", "adjustedStop", "adjustedTarget",
                      "dailyBars", "sameBarStopFirst", "unknownOutcomePolicy", "control"])
    func corruptedTerminalReceiptsPreserveOriginalBytesAndReportAnError(field: String) throws {
        let (store, url, defaults, suite) = try fileStore("terminal-corrupt")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = dailyRun()
        try #require(store.record(original))
        let stopped = History.evaluate(original.predictions[0], in: original,
            observation: dailyObservation(highs: [105, 121], lows: [98, 89]),
            now: dailyNow(afterSessions: 2))
        try #require(stopped.terminalKind == .stopHit && stopped.sameBarStopFirst == true)
        try #require(store.recordEvaluation(stopped, runID: original.id, symbol: "ACME"))
        let saved = try Data(contentsOf: url)

        var document = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        var runs = try #require(document["runs"] as? [[String: Any]])
        var evaluations = try #require(runs[0]["evaluations"] as? [String: Any])
        var receipt = try #require(evaluations["ACME"] as? [String: Any])
        switch field {
        case "terminalKind": receipt["terminalKind"] = "targetHit"
        case "unknownTerminalKind": receipt["terminalKind"] = "gapFill"
        case "missingTerminalKind": receipt.removeValue(forKey: "terminalKind")
        case "terminalAt": receipt["terminalAt"] = date("2026-09-15T04:00:00Z").timeIntervalSinceReferenceDate
        case "outcomePrice": receipt["outcomePrice"] = 121
        case "adjustmentRatio": receipt["adjustmentRatio"] = 2
        case "adjustedEntry": receipt["adjustedEntry"] = 101
        case "adjustedStop": receipt["adjustedStop"] = 80
        case "adjustedTarget": receipt["adjustedTarget"] = 119
        case "dailyBars": receipt["dailyBars"] = Array((receipt["dailyBars"] as! [[String: Any]]).dropLast())
        case "sameBarStopFirst": receipt.removeValue(forKey: "sameBarStopFirst")
        case "unknownOutcomePolicy": runs[0]["outcomePolicy"] = 99
        default: break
        }
        evaluations["ACME"] = receipt
        runs[0]["evaluations"] = evaluations
        document["runs"] = runs
        let corrupted = try JSONSerialization.data(withJSONObject: document)
        try corrupted.write(to: url)

        let reopened = History(storageURL: url, defaults: defaults)
        if field == "control" {
            #expect(reopened.lastError == nil && reopened.runs.first?.evaluations["ACME"] == stopped)
        } else {
            #expect(reopened.runs.isEmpty && reopened.lastError != nil, "\(field)")
            #expect(!reopened.record(dailyRun()), "An unreadable store never overwrites the owner's bytes")
        }
        #expect(try Data(contentsOf: url) == corrupted, "\(field)")
        // The pre-corruption bytes still decode on their own; nothing about the format changed.
        try saved.write(to: url)
        let restored = History(storageURL: url, defaults: defaults)
        #expect(restored.lastError == nil && restored.runs.first?.evaluations["ACME"] == stopped)
    }

    /// Regression (independent review, 2026-09-16): CompletedCheck previously dropped
    /// `Result.insiderTransactions` entirely on save/restore, silently changing a later
    /// recomputed insider score for a restored historical scan.
    @Test func completedCheckRoundTripsInsiderTransactions() throws {
        var (run, scan) = checkpointFixture(count: 2)
        typealias E = StockSageMassiveEvents
        let symbol = scan.listings[0].ticker
        let purchase = E.InsiderTransaction(direction: .purchase, transactionDate: date("2026-09-14T13:00:00Z"),
            filingDate: date("2026-09-15T13:00:00Z"), ownerName: "Owner", role: "Director",
            shares: 100, pricePerShare: 50, planReported: false, amendment: false)
        scan.results[symbol]?.insiderTransactions = [purchase]
        let history = History()
        try #require(history.record(run))
        try #require(history.saveCompletedChecks(run, scan: scan))
        let restored = try #require(history.completedScan(horizon: .fortnight))
        #expect(restored.scan.results[symbol]?.insiderTransactions == [purchase],
                "The typed insider transaction survives a save/restore round trip")

        // Legacy archive bytes (no insiderTransactions key) must still decode, with an empty array.
        var checks = scan
        checks.results[symbol]?.insiderTransactions = []
        let legacyRun = run
        let legacyHistory = History()
        try #require(legacyHistory.record(legacyRun))
        try #require(legacyHistory.saveCompletedChecks(legacyRun, scan: checks))
        let legacyRestored = try #require(legacyHistory.completedScan(horizon: .fortnight))
        #expect(legacyRestored.scan.results[symbol]?.insiderTransactions == [])
    }

    @Test func completedCheckDecodesActualLegacyBytesWithoutAddingFields() throws {
        let (_, scan) = checkpointFixture(count: 2)
        let listing = scan.listings[0]
        let check = History.CompletedCheck(listing: listing, result: try #require(scan.results[listing.ticker]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(check)) as? [String: Any])
        for key in ["insiderTransactions", "factClasses", "qualityReport", "inferenceProfile"] {
            object.removeValue(forKey: key)
        }
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(History.CompletedCheck.self, from: legacy)
        #expect(decoded.insiderTransactions.isEmpty)
        #expect(decoded == check)
        #expect(try encoder.encode(decoded) == legacy, "Reading a legacy check must not rewrite its evidence")
        let restoredResult = try #require(decoded.result)
        #expect(!decoded.hasRecordedInsiderTransactions && !restoredResult.hasRecordedInsiderTransactions)
        #expect(try encoder.encode(History.CompletedCheck(listing: listing, result: restoredResult)) == legacy,
                "Restoring then recapturing must also preserve legacy key absence")
    }

    @Test func savedPickRetainsInsiderSourcesAfterItsLatestCheckIsReplaced() throws {
        typealias E = StockSageMassiveEvents
        let (original, initial) = checkpointFixture(count: 8)
        var scan = initial
        let symbol = scan.listings[0].ticker
        let at = try #require(scan.results[symbol]?.at)
        let transaction = E.InsiderTransaction(direction: .sale, transactionDate: at.addingTimeInterval(-172_800),
            filingDate: at.addingTimeInterval(-86_400), ownerName: "Reported director", role: "Director",
            shares: 100, pricePerShare: 50, planReported: true, amendment: false)
        let event = E.Event(id: "filing-id", symbol: symbol, feed: .insider, date: transaction.filingDate,
            headline: "Filed sale", details: ["Reported under a Rule 10b5-1 plan."],
            link: URL(string: "https://www.sec.gov/Archives/filing-id"), transactionIdentity: "transaction-id", insider: transaction)
        scan.results[symbol]?.insiderTransactions = [transaction]
        scan.results[symbol]?.insiderEvidence = .init(symbol: symbol, feed: .insider, checkedAt: at,
            outcome: .answered, event: event, insiderEvents: [event], insiderOmittedRecordCount: 0)
        scan.results[symbol]?.coverage.append(.init(source: E.Feed.insider.source, state: .answered, checkedAt: at))
        scan.results[symbol]?.factClasses = [.insider, .coverageGap]
        scan.ranking = .fixture(scan: scan, symbols: Array(scan.listings.prefix(4)).map(\.ticker), horizon: .fortnight, at: original.completedAt)
        scan.rankingFailure = nil
        let first = History.snapshot(startedAt: original.startedAt, completedAt: original.completedAt,
            horizon: .fortnight, scan: scan)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        for change in ["unavailableWithEvents", "unavailableAnswered", "differentFirst", "missingOmitted"] {
            var object = encoded
            var predictions = object["predictions"] as! [[String: Any]]
            var source = predictions[0]["insiderEvidence"] as! [String: Any]
            switch change {
            case "unavailableWithEvents": source["outcome"] = "unavailable"
            case "unavailableAnswered":
                source["outcome"] = "unavailable"
                for key in ["event", "insiderEvents", "insiderOmittedRecordCount"] { source.removeValue(forKey: key) }
            case "differentFirst":
                var event = source["event"] as! [String: Any]; event["id"] = "different-filing"; source["event"] = event
            default: source.removeValue(forKey: "insiderOmittedRecordCount")
            }
            predictions[0]["insiderEvidence"] = source; object["predictions"] = predictions
            let changed = try JSONDecoder().decode(History.Run.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(!History().record(changed), "Reject contradictory source status: \(change)")
        }
        let (history, url, defaults, suite) = try fileStore("insider-prediction")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try #require(history.record(first) && history.saveCompletedChecks(first, scan: scan))
        #expect(history.completedScan(runID: first.id)?.run.id == first.id)
        let (second, replacement) = checkpointFixture(count: 8, start: first.completedAt.addingTimeInterval(60))
        try #require(history.record(second) && history.saveCompletedChecks(second, scan: replacement))
        let reopened = History(storageURL: url, defaults: defaults)
        let saved = try #require(reopened.runs.first { $0.id == first.id }?.predictions.first)
        #expect(saved.insiderEvidence?.insiderEvents == [event] && saved.insiderEvidence?.insiderOmittedRecordCount == 0)
        #expect(saved.hasRecordedInsiderEvidence && saved.insiderCoverage?.state == "answered")
        #expect(saved.factClasses == [.insider, .coverageGap])
        #expect(reopened.completedScan(runID: first.id) == nil, "Never substitute the newer scan's checks")
        #expect(reopened.completedScan(runID: second.id)?.run.id == second.id)
        #expect(reopened.completedScan(runID: UUID()) == nil)
    }

    @Test func savedPredictionRejectsContradictoryEvidenceAndQualification() async throws {
        typealias A = StockSageAIAssessment
        let (original, initial) = strictFixture()
        var scan = initial
        var result = try #require(scan.results["AAA"])
        let oldReceipt = try #require(result.evidenceReceipt)
        let facts = zip(oldReceipt.offeredKeys, result.facts).map {
            A.EvidenceFact(key: $0.0, text: $0.1, required: true, availability: .available)
        }
        let packet = A.EvidencePacket(facts: facts, prePromptOmittedRecordCount: 0)
        result.evidenceReceipt = .init(symbol: "AAA", requiredKeys: oldReceipt.requiredKeys,
            missingOrUnknownRequiredKeys: oldReceipt.missingOrUnknownRequiredKeys,
            offeredKeys: oldReceipt.offeredKeys, omittedKeys: oldReceipt.omittedKeys,
            prePromptOmittedRecordCount: oldReceipt.prePromptOmittedRecordCount, citedKeys: oldReceipt.citedKeys,
            packetVersion: packet.version, classCounts: packet.classCounts, packetDigest: packet.digest)
        result.inferenceProfile = .init(config: .init(baseURL: URL(string: "http://127.0.0.1:1234")!, model: result.model),
            isOllama: false, packet: packet, outputTokens: 192, diagnostic: .init(finish: .stop))
        result.qualityReport = A.quality(result.verdict, offered: facts, symbol: "AAA")
        scan.results["AAA"] = result
        let outcome = await StockSageResearchRanking.rank(scan: scan, horizon: .fortnight,
            config: .init(baseURL: URL(string: "http://127.0.0.1:1234")!, model: "offline-fixture"), isOllama: false,
            allowed: { true }, completion: { _, _, _ in
                .success(.init(text: "{\"symbols\":[\"AAA\"]}", diagnostic: .init(finish: .stop), model: "offline-fixture"))
            })
        scan.ranking = try outcome.get(); scan.rankingFailure = nil
        let run = History.snapshot(startedAt: original.startedAt, completedAt: Date(), horizon: .fortnight, scan: scan)
        try #require(run.predictions.count == 1)
        try #require(History().record(run))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        for change in ["symbol", "digest", "qualification"] {
            var object = encoded
            var predictions = object["predictions"] as! [[String: Any]]
            if change == "qualification" {
                var receipt = predictions[0]["qualification"] as! [String: Any]
                receipt["originalAction"] = "Hold"; predictions[0]["qualification"] = receipt
            } else {
                var receipt = predictions[0]["evidenceReceipt"] as! [String: Any]
                receipt[change == "symbol" ? "symbol" : "packetDigest"] = change == "symbol" ? "OTHER" : String(repeating: "0", count: 64)
                predictions[0]["evidenceReceipt"] = receipt
            }
            object["predictions"] = predictions
            let changed = try JSONDecoder().decode(History.Run.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(!History().record(changed), "Reject contradictory saved metadata: \(change)")
        }
    }
}
