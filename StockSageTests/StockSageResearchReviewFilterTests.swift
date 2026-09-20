import Testing
import Foundation
@testable import StockSage

// Task 23 filters. The facets that matter here are the ones where a careless predicate would
// quietly convert "we do not know" into "no" — insider activity and quality state.
@MainActor struct StockSageResearchReviewFilterTests {
    typealias F = StockSageResearchReviewFilter
    typealias H = StockSageResearchHistory
    private let at = Date(timeIntervalSince1970: 1_788_739_200)

    private func prediction(_ symbol: String, action: String = "Buy",
                            insider: StockSageMassiveEvents.Observation? = nil,
                            coverage: String? = nil,
                            quality: StockSageAIAssessment.QualityReport? = nil) -> H.Prediction {
        var value = H.Prediction(symbol: symbol, name: "\(symbol) co", action: action, reason: "r",
            risk: "k", evidence: ["F1"], facts: ["F1 text"], model: "m", note: "n",
            referencePrice: 100, referenceDate: at, levels: nil)
        value.insiderEvidence = insider
        value.insiderCoverage = coverage.map {
            .init(source: StockSageMassiveEvents.Feed.insider.source, state: $0, checkedAt: at)
        }
        value.qualityReport = quality
        return value
    }

    private func observation(rows: Int, outcome: StockSageMassiveEvents.Observation.Outcome = .answered) -> StockSageMassiveEvents.Observation {
        let events = (0..<rows).map { index -> StockSageMassiveEvents.Event in
            var event = StockSageMassiveEvents.Event(id: "e\(index)", symbol: "AAA", feed: .insider,
                date: at, headline: "Form 4", details: [], link: nil)
            event.insider = .init(direction: .sale, transactionDate: at, filingDate: at,
                ownerName: "S. Seller", role: "CFO", shares: 10, pricePerShare: 1,
                planReported: nil, amendment: false)
            return event
        }
        var value = StockSageMassiveEvents.Observation(symbol: "AAA", feed: .insider, checkedAt: at,
                                                      outcome: outcome, event: events.first)
        value.insiderEvents = events
        value.insiderOmittedRecordCount = 0
        return value
    }

    private func report(_ state: StockSageAIAssessment.QualityReport.State) -> StockSageAIAssessment.QualityReport {
        .init(version: StockSageAIAssessment.QualityReport.version, state: state,
              findings: state == .unverified ? [.uncitedInsiderRecord] : [],
              citedCount: 1, offeredCount: 1, classCounts: ["technical": 1],
              insiderPurchases: 0, insiderSales: 0, uncitedInsiderIDs: [],
              acceptedAction: "Buy", rejectionReason: nil)
    }

    private func run(_ predictions: [H.Prediction], horizon: H.Horizon = .week) -> H.Run {
        .init(id: UUID(), startedAt: at.addingTimeInterval(-60), completedAt: at, horizon: horizon,
              predictions: predictions,
              coverage: .init(requested: predictions.count, checked: predictions.count,
                              incomplete: 0, buyCount: predictions.count, selection: nil))
    }

    @Test func theDefaultFilterIsInactiveAndKeepsEverything() {
        let value = run([prediction("AAA"), prediction("BBB", action: "Strong Buy")])
        #expect(!F().isActive)
        #expect(F().matchingPredictions(in: value).count == 2)
    }

    @Test func completedRunsWithoutPicksRemainVisibleWithoutPredictionFilters() {
        let empty = run([])
        #expect(F().matches(empty))
        #expect(F(horizon: .week).matches(empty))
        #expect(!F(horizon: .fortnight).matches(empty))
        #expect(!F(action: .buy).matches(empty))
        #expect(!F(quality: .notAssessed).matches(empty))
        #expect(!F(insider: .notKnown).matches(empty))
        #expect(!F(outcome: .active).matches(empty))
    }

    @Test func failedComparisonsRemainVisibleForInspection() {
        let failed = H.Run(id: UUID(), startedAt: at.addingTimeInterval(-60),
            completedAt: at, horizon: .week, predictions: [],
            coverage: .init(requested: 500, checked: 500, incomplete: 61,
                            buyCount: 66, selection: nil),
            rankingFailure: "The model could not complete the research comparison.")
        #expect(F().matches(failed))
        #expect(F(horizon: .week).matches(failed))
    }

    @Test func actionAndHorizonNarrowIndependently() {
        let value = run([prediction("AAA"), prediction("BBB", action: "Strong Buy")])
        #expect(F(action: .strongBuy).matchingPredictions(in: value).map(\.symbol) == ["BBB"])
        #expect(F(horizon: .fortnight).matchingPredictions(in: value).isEmpty)
        #expect(F(horizon: .week, action: .buy).matchingPredictions(in: value).map(\.symbol) == ["AAA"])
    }

    @Test func searchFindsSavedSymbolsOrCompaniesAndCombinesWithFacets() {
        let value = run([prediction("AAA"), prediction("BBB", action: "Strong Buy")])
        #expect(F(query: " aaA ").matchingPredictions(in: value).map(\.symbol) == ["AAA"])
        #expect(F(query: "bbb co").matchingPredictions(in: value).map(\.symbol) == ["BBB"])
        #expect(!F(action: .buy, query: "BBB").matches(value))
        #expect(!F(query: "missing").matches(value))
        #expect(F(query: "  \n").matches(run([])))
        #expect(!F(query: "AAA").matches(run([])))
    }

    @Test func exportedResearchRetainsOriginalEvidenceAndDates() throws {
        let saved = run([prediction("AAA", insider: observation(rows: 1), coverage: "answered")])
        let exportedAt = at.addingTimeInterval(86_400.123456)
        let data = try StockSageResearchExport.data(for: saved, at: exportedAt)
        let decoder = JSONDecoder()
        let report = try decoder.decode(StockSageResearchExport.Report.self, from: data)
        #expect(report.schemaVersion == 1 && report.exportedAt == exportedAt)
        #expect(report.run == saved)
        #expect(report.run.predictions[0].insiderEvidence == saved.predictions[0].insiderEvidence)
        #expect(report.scope.contains("not live") && report.scope.contains("not a complete scan"))
    }

    // The heart of it: three insider outcomes that must never collapse into two.
    @Test func insiderFilteringKeepsUnknownApartFromConfirmedNone() {
        let recorded = prediction("REC", insider: observation(rows: 1), coverage: "answered")
        let emptyWindow = prediction("EMP", insider: observation(rows: 0), coverage: "answered")
        let unanswered = prediction("UNK", insider: observation(rows: 0, outcome: .unavailable), coverage: "unavailable")
        let neverRecorded = prediction("OLD")
        let value = run([recorded, emptyWindow, unanswered, neverRecorded])

        #expect(F(insider: .recordedActivity).matchingPredictions(in: value).map(\.symbol) == ["REC"])
        #expect(F(insider: .noQualifyingRows).matchingPredictions(in: value).map(\.symbol) == ["EMP"])
        // Both "never recorded" and "asked but not answered" are unknown — neither is an absence.
        #expect(F(insider: .notKnown).matchingPredictions(in: value).map(\.symbol) == ["UNK", "OLD"])
    }

    // A record with no recorded quality opinion must be reachable as its own state, and must never
    // be swept up by the "unverified" filter.
    @Test func notAssessedIsItsOwnQualityFacetAndNeverCountsAsUnverified() {
        let verified = prediction("VER", quality: report(.verified))
        let unverified = prediction("UNV", quality: report(.unverified))
        let none = prediction("NON")
        let value = run([verified, unverified, none])
        #expect(F(quality: .verified).matchingPredictions(in: value).map(\.symbol) == ["VER"])
        #expect(F(quality: .unverified).matchingPredictions(in: value).map(\.symbol) == ["UNV"])
        #expect(F(quality: .notAssessed).matchingPredictions(in: value).map(\.symbol) == ["NON"])
    }

    @Test func aRunSurvivesOnlyWhileSomethingInItStillMatches() {
        let value = run([prediction("AAA", action: "Buy")])
        #expect(F(action: .buy).matches(value))
        #expect(!F(action: .strongBuy).matches(value))
        #expect(!F(horizon: .fortnight).matches(value))
    }

    // Guards the deliberate omission: adding an overnight facet before the feed exists would ship
    // a filter that can only ever report "no matches".
    @Test func thereIsNoOvernightFacetUntilThereIsOvernightData() {
        let cases = Set(Mirror(reflecting: F()).children.compactMap(\.label))
        #expect(!cases.contains("overnight"))
    }
}
