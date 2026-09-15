import Foundation
import Testing
@testable import StockSage

@Suite("Saved research predictions", .serialized)
@MainActor
struct StockSageResearchHistoryTests {
    typealias History = StockSageResearchHistory

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func run(id: UUID = UUID(), completed: String = "2026-09-14T21:00:00Z",
                     horizon: History.Horizon = .week, referencePrice: Double? = 200,
                     policy: History.MeasurementPolicy? = nil) -> History.Run {
        .init(id: id, startedAt: date(completed).addingTimeInterval(-60), completedAt: date(completed),
              horizon: horizon, predictions: [.init(symbol: "ACME", name: "Acme", action: "Buy",
                reason: "Dated evidence supports the setup", risk: "Demand may weaken", evidence: ["F1"],
                facts: ["Original observed facts"], model: "fixture-model", note: "Unvalidated research",
                referencePrice: referencePrice,
                referenceDate: referencePrice == nil ? nil : date("2026-09-11T04:00:00Z"), levels: nil)],
              coverage: .init(requested: 1, checked: 1, incomplete: 0, buyCount: 1, selection: nil),
              measurementPolicy: policy)
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

    @Test func manualChecksFetchOnlyDueUnevaluatedPredictionsAndRetryMissingData() async throws {
        let store = History(storageURL: nil)
        let due = run()
        let later = run(completed: "2026-09-24T21:00:00Z")
        #expect(store.record(due) && store.record(later))
        var calls = 0
        await store.checkDue(clock: { date("2026-09-24T13:00:00Z") }, allowed: { true }) { _, current in
            calls += 1
            #expect(current.id == due.id)
            return nil
        }
        #expect(calls == 1 && !store.isChecking)
        #expect(store.runs.first(where: { $0.id == due.id })?.evaluations["ACME"]?.state == .dataUnavailable)
        await store.checkDue(clock: { date("2026-09-24T13:00:00Z") }, allowed: { true }) { _, _ in
            calls += 1
            return observation()
        }
        #expect(calls == 2)
        await store.checkDue(clock: { date("2026-09-24T13:00:00Z") }, allowed: { true }) { _, _ in
            calls += 1
            return observation()
        }
        #expect(calls == 2, "Already evaluated predictions must not refetch")
        #expect(store.runs.first(where: { $0.id == due.id })?.predictions == due.predictions)
    }

    @Test func boundedManualCheckAdvancesPastUnavailableDataWithoutDroppingRuns() async {
        let store = History(storageURL: nil)
        for _ in 0..<26 { #expect(store.record(run())) }
        var visited: Set<UUID> = []
        await store.checkDue(clock: { date("2026-09-24T13:00:00Z") }, allowed: { true }) { _, current in
            visited.insert(current.id)
            return nil
        }
        #expect(visited.count == 25 && store.runs.count == 26)
        #expect(store.lastCheckSummary?.contains("1 more") == true)
        await store.checkDue(clock: { date("2026-09-25T13:00:00Z") }, allowed: { true }) { _, current in
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
            await store.checkDue(clock: { date("2026-09-24T13:00:00Z") }, allowed: { permitted }) { _, _ in
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
            analyze: { _ in result })
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
