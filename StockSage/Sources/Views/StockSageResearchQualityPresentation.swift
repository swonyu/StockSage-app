import Foundation

/// How a saved prediction's shadow quality report should be presented.
///
/// Two rules shape everything here. A run saved before shadow-mode capture has no quality opinion
/// at all, and absent metadata must never become `unverified` — that would turn a gap in our own
/// records into a negative judgement of the research. And a `verified` badge is an evidence-output
/// check: it says the answer cited what it was given, not that the answer is right, likely, or
/// profitable. Nothing here is a calibrated probability.
nonisolated enum StockSageResearchQualityPresentation: Equatable {
    case notAssessed
    case assessed(StockSageAIAssessment.QualityReport, captured: [String: Int]?)

    struct ClassCoverage: Equatable {
        let factClass: String
        /// Facts in the originally captured packet, before prompt fitting. nil on a receipt that
        /// predates the recorded counts — unknown, never zero.
        let captured: Int?
        /// Facts actually offered to the model.
        let offered: Int
        /// captured − offered: what prompt fitting trimmed. nil when `captured` is unknown.
        var trimmed: Int? { captured.map { max(0, $0 - offered) } }
    }

    static func state(for prediction: StockSageResearchHistory.Prediction) -> Self {
        guard let report = prediction.qualityReport else { return .notAssessed }
        return .assessed(report, captured: prediction.evidenceReceipt?.classCounts)
    }

    var report: StockSageAIAssessment.QualityReport? {
        if case .assessed(let report, _) = self { return report }
        return nil
    }

    /// True only for a recorded negative outcome. A missing report is never negative.
    var isNegative: Bool {
        switch report?.state {
        case .unverified, .modelRejected: true
        case .verified, .dataUnavailable, nil: false
        }
    }

    var badge: String {
        switch report?.state {
        case nil: "Quality not assessed"
        case .verified: "Evidence checks passed"
        case .unverified: "Evidence checks flagged"
        case .dataUnavailable: "Evidence unavailable"
        case .modelRejected: "Answer rejected"
        }
    }

    var explanation: String {
        switch report?.state {
        case nil:
            "This research was saved before evidence checks were recorded. No quality opinion exists for it, which is not a judgement either way."
        case .verified:
            "The answer cited the evidence it was given and raised no flags. This is a check on evidence handling only — it is not a forecast and says nothing about whether the research turns out to be right."
        case .unverified:
            "The answer was published unchanged, and these evidence checks were flagged for review."
        case .dataUnavailable:
            "The evidence needed for these checks was not available, so no check could run. This describes the evidence, not the company."
        case .modelRejected:
            "The answer was rejected before publication and its original text is retained."
        }
    }

    var findingDescriptions: [String] {
        (report?.findings ?? []).map {
            switch $0 {
            case .uncitedMaterialClaim: "A material claim cited no evidence."
            case .unresolvableCitation: "A citation named a fact that was not offered."
            case .citedUnavailableFact: "A cited fact was reported missing or unknown by its own source."
            case .uncitedInsiderRecord: "An offered insider record was not cited in the evidence list."
            case .insiderSaleFramedAsBuying: "Buying language was used while every cited insider record was a sale."
            case .insiderIntentClaimed: "Motive or confidence was attributed to a filing that states none."
            }
        }
    }

    /// Offered insider records the answer never cited. Surfaced, never removed.
    var uncitedInsiderIDs: [String] { report?.uncitedInsiderIDs ?? [] }

    var insiderCounts: (purchases: Int, sales: Int)? {
        report.map { ($0.insiderPurchases, $0.insiderSales) }
    }

    /// Per class, what was captured and what actually reached the model. These have different
    /// denominators on purpose and are never summed into one number: `captured` counts the original
    /// packet before prompt fitting, `offered` counts what was fitted into the request.
    var classCoverage: [ClassCoverage] {
        guard case .assessed(let report, let captured) = self else { return [] }
        let names = Set(report.classCounts.keys).union(captured?.keys ?? [:].keys)
        return names.sorted().map {
            ClassCoverage(factClass: $0, captured: captured?[$0], offered: report.classCounts[$0] ?? 0)
        }
    }
}
