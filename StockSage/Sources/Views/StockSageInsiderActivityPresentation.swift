import Foundation

/// How a saved prediction's insider evidence should be presented.
///
/// This type reports what was recorded and never infers. It exists to keep three situations apart
/// that a naive `isEmpty` check collapses into one:
///
/// 1. a record saved before insider evidence was captured at all,
/// 2. a check the provider did not answer, and
/// 3. an answered query that returned no qualifying rows for the window it asked about.
///
/// Only the third is a statement about the data, and even then it is a statement about the QUERIED
/// WINDOW, not about the company. No case here licenses the sentence "no insider activity".
nonisolated enum StockSageInsiderActivityPresentation: Equatable {
    /// The archive predates insider capture. Absence of a field is not a fact about the company.
    case notRecorded
    /// Insider evidence was recorded as attempted, but not answered. Never a confirmed empty window.
    case notChecked(checkedAt: Date?)
    /// Answered with no qualifying purchases or sales for the queried window.
    case noQualifyingRows(checkedAt: Date, omittedRecordCount: Int)
    /// Answered with evidence. `untypedEventCount` covers legacy caches that stored an event
    /// without typed Form 4 detail — still recorded evidence, never a confirmed empty window.
    case recorded(transactions: [StockSageMassiveEvents.InsiderTransaction],
                  untypedEventCount: Int, omittedRecordCount: Int, checkedAt: Date)

    static func state(for prediction: StockSageResearchHistory.Prediction) -> Self {
        guard prediction.hasRecordedInsiderEvidence else { return .notRecorded }
        guard let observation = prediction.insiderEvidence else {
            return .notChecked(checkedAt: prediction.insiderCoverage?.checkedAt)
        }
        // Either recorded status may veto a confirmed-empty reading; neither may create one.
        let answered = StockSageHorizonResearch.EvidenceCoverage.State.answered.rawValue
        let coverageAnswered = prediction.insiderCoverage.map { $0.state == answered } ?? true
        guard observation.outcome == .answered, coverageAnswered else {
            return .notChecked(checkedAt: observation.checkedAt)
        }
        let events = observation.insiderEvents ?? observation.event.map { [$0] } ?? []
        let transactions = events.compactMap(\.insider)
        let omitted = max(0, observation.insiderOmittedRecordCount ?? 0)
        guard !events.isEmpty else {
            return .noQualifyingRows(checkedAt: observation.checkedAt, omittedRecordCount: omitted)
        }
        return .recorded(transactions: transactions, untypedEventCount: events.count - transactions.count,
                         omittedRecordCount: omitted, checkedAt: observation.checkedAt)
    }

    var transactions: [StockSageMassiveEvents.InsiderTransaction] {
        if case .recorded(let rows, _, _, _) = self { return rows }
        return []
    }
    var untypedEventCount: Int {
        if case .recorded(_, let count, _, _) = self { return count }
        return 0
    }
    var omittedRecordCount: Int {
        switch self {
        case .noQualifyingRows(_, let omitted): omitted
        case .recorded(_, _, let omitted, _): omitted
        case .notRecorded, .notChecked: 0
        }
    }
    /// True only when evidence was actually returned — typed rows or a legacy untyped event.
    var hasRecordedActivity: Bool {
        if case .recorded = self { return true }
        return false
    }

    var headline: String {
        switch self {
        case .notRecorded:
            "Insider activity was not recorded for this saved research"
        case .notChecked:
            "Insider check did not complete — this is a gap in the data, not a finding about the company"
        case .noQualifyingRows(_, let omitted):
            "Checked — no qualifying purchases or sales returned for the queried window"
                + (omitted > 0 ? ", with \(omitted) record\(omitted == 1 ? "" : "s") omitted from the selection" : "")
        case .recorded(let rows, let untyped, let omitted, _):
            ([rows.isEmpty ? nil : "\(rows.count) Form 4 transaction\(rows.count == 1 ? "" : "s")",
              untyped == 0 ? nil : "\(untyped) recorded filing\(untyped == 1 ? "" : "s") without typed detail",
              omitted == 0 ? nil : "\(omitted) omitted from the selection"]
                .compactMap { $0 }).joined(separator: " · ")
        }
    }
}
