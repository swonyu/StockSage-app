import Foundation
import Testing
@testable import StockSage

@MainActor @Suite("Insider activity presentation states")
struct StockSageInsiderActivityPresentationTests {
    typealias P = StockSageInsiderActivityPresentation
    typealias Events = StockSageMassiveEvents

    private let checkedAt = try! Date.ISO8601FormatStyle().parse("2026-09-16T12:00:00Z")

    private func transaction(_ direction: Events.InsiderTransaction.Direction,
                             owner: String = "A. Director", role: String? = "Director",
                             shares: Double = 1_000, price: Double? = 10,
                             plan: Bool? = nil, amendment: Bool = false) -> Events.InsiderTransaction {
        .init(direction: direction, transactionDate: checkedAt.addingTimeInterval(-86_400),
              filingDate: checkedAt, ownerName: owner, role: role, shares: shares,
              pricePerShare: price, planReported: plan, amendment: amendment)
    }

    private func event(_ insider: Events.InsiderTransaction?, id: String = "acc-1") -> Events.Event {
        var value = Events.Event(id: id, symbol: "ACME", feed: .insider, date: checkedAt,
                                 headline: "Form 4 filed", details: ["Reported under a Rule 10b5-1 plan."],
                                 link: URL(string: "https://example.invalid/form4"))
        value.insider = insider
        return value
    }

    private func observation(outcome: Events.Observation.Outcome = .answered,
                             events: [Events.Event]? = nil, omitted: Int? = nil) -> Events.Observation {
        var value = Events.Observation(symbol: "ACME", feed: .insider, checkedAt: checkedAt,
                                       outcome: outcome, event: events?.first)
        value.insiderEvents = events
        value.insiderOmittedRecordCount = omitted
        return value
    }

    private func prediction(evidence: Events.Observation? = nil,
                            coverageState: String? = nil) -> StockSageResearchHistory.Prediction {
        var value = StockSageResearchHistory.Prediction(
            symbol: "ACME", name: "Acme", action: "Hold", reason: "r", risk: "k",
            evidence: ["F1"], facts: ["F1 text"], model: "google/gemma-4-31b-qat",
            note: "n", referencePrice: 10, referenceDate: checkedAt, levels: nil)
        value.insiderEvidence = evidence
        value.insiderCoverage = coverageState.map {
            .init(source: Events.Feed.insider.source, state: $0, checkedAt: checkedAt)
        }
        return value
    }

    // A record saved before insider evidence was captured must never read as "none". This is the
    // legacy case the plan's global constraints are about: absence of a field is not a fact.
    @Test func anArchiveThatNeverRecordedInsiderEvidenceReportsItAsNotRecorded() {
        let state = P.state(for: prediction())
        #expect(state == .notRecorded)
        #expect(!state.headline.lowercased().contains("no insider"))
    }

    // Recorded but the provider did not answer: still not a confirmed empty window.
    @Test func anUnansweredInsiderCheckIsNotAConfirmedEmptyWindow() {
        let state = P.state(for: prediction(evidence: observation(outcome: .unavailable), coverageState: "unavailable"))
        #expect(state == .notChecked(checkedAt: checkedAt))
        #expect(!state.headline.lowercased().contains("no insider"))
    }

    // A disagreeing saved source status fails safe: it can never upgrade into a confirmed empty.
    @Test func aCoverageStatusThatContradictsTheOutcomeFailsSafeToNotChecked() {
        let state = P.state(for: prediction(evidence: observation(events: []), coverageState: "stale"))
        #expect(state == .notChecked(checkedAt: checkedAt))
    }

    // The sharpest rule from the owner: answered-and-empty means no QUALIFYING rows came back for
    // the QUERIED WINDOW. It must never be phrased as an absence of insider activity.
    @Test func anAnsweredEmptyQueryNeverClaimsThereWasNoInsiderActivity() {
        let state = P.state(for: prediction(evidence: observation(events: [], omitted: 2), coverageState: "answered"))
        #expect(state == .noQualifyingRows(checkedAt: checkedAt, omittedRecordCount: 2))
        let headline = state.headline.lowercased()
        #expect(!headline.contains("no insider activity") && !headline.contains("no form 4 activity"))
        #expect(headline.contains("queried window"))
        #expect(state.omittedRecordCount == 2, "An omitted count must survive into the surface, not be dropped")
    }

    // Both directions survive, and a sale is never reordered or suppressed behind a purchase.
    @Test func purchasesAndSalesAreBothRetainedInTheirRecordedOrder() {
        let rows = [event(transaction(.sale), id: "a"), event(transaction(.purchase), id: "b")]
        let state = P.state(for: prediction(evidence: observation(events: rows), coverageState: "answered"))
        #expect(state.transactions.map(\.direction) == [.sale, .purchase])
        #expect(state.transactions.count == 2 && state.untypedEventCount == 0)
    }

    // A legacy cache stored the event without typed Form 4 detail. That is still recorded evidence
    // and must not collapse into the empty-window state.
    @Test func aLegacyUntypedInsiderEventIsStillRecordedEvidence() {
        let state = P.state(for: prediction(evidence: observation(events: [event(nil)]), coverageState: "answered"))
        #expect(state.untypedEventCount == 1 && state.transactions.isEmpty)
        #expect(state != .noQualifyingRows(checkedAt: checkedAt, omittedRecordCount: 0),
                "An untyped legacy event is evidence; it cannot read as a confirmed empty window")
        #expect(state.hasRecordedActivity)
    }

    // Plan disclosure is displayed as supplied. Drawing any conclusion from it would be inferring
    // motive, which Form 4 never states.
    @Test func aPlanDisclosureIsCarriedWithoutAnyMotiveLanguage() {
        let rows = [event(transaction(.sale, plan: true))]
        let state = P.state(for: prediction(evidence: observation(events: rows), coverageState: "answered"))
        let row = try! #require(state.transactions.first)
        #expect(row.planReported == true && row.intent == .unknown)
        let text = state.headline.lowercased()
        for motive in ["routine", "not bearish", "pre-planned sale is", "momentum", "confidence", "signal"] {
            #expect(!text.contains(motive), "Presentation must not interpret a plan disclosure: \(motive)")
        }
    }
}
