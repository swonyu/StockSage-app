import Foundation

/// Task 23's review filters, as a pure value so the predicate is testable without a view.
///
/// Every facet is derived from the SAME presentation states the rows render from
/// (`StockSageInsiderActivityPresentation`, `StockSageResearchQualityPresentation`), so a filter
/// and the row it hides can never disagree about what a record says.
///
/// There is deliberately no "overnight context" facet. Nothing in a saved record can answer it
/// until the overnight feed exists, and a filter whose predicate always evaluates to false is
/// worse than an absent one: it silently reports "no matches" for a question it cannot ask.
nonisolated struct StockSageResearchReviewFilter: Equatable, Sendable {
    enum Action: String, CaseIterable, Sendable { case any, buy, strongBuy }

    enum Quality: String, CaseIterable, Sendable {
        case any, verified, unverified, evidenceUnavailable, notAssessed
    }

    /// Three-valued on purpose. A boolean "has insider activity" would sort every record whose
    /// insider check never ran — or was never recorded — into "none", which is precisely the
    /// missing-data-as-negative-evidence failure the rest of this surface refuses.
    enum Insider: String, CaseIterable, Sendable {
        case any
        /// Form 4 rows, or a legacy untyped filing, were actually recorded.
        case recordedActivity
        /// The query was answered and returned no qualifying purchases or sales for its window.
        case noQualifyingRows
        /// Never recorded, or the source did not answer. Not a statement about the company.
        case notKnown
    }

    enum Outcome: String, CaseIterable, Sendable { case any, active, terminal }

    var horizon: StockSageResearchHistory.Horizon? = nil
    var action: Action = .any
    var quality: Quality = .any
    var insider: Insider = .any
    var outcome: Outcome = .any
    var query = ""

    var isActive: Bool { self != Self() }

    func matches(_ prediction: StockSageResearchHistory.Prediction,
                 in run: StockSageResearchHistory.Run) -> Bool {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty,
           !prediction.symbol.localizedCaseInsensitiveContains(search),
           !prediction.name.localizedCaseInsensitiveContains(search) { return false }
        switch action {
        case .any: break
        case .buy: if prediction.action != "Buy" { return false }
        case .strongBuy: if prediction.action != "Strong Buy" { return false }
        }
        if quality != .any {
            let state = StockSageResearchQualityPresentation.state(for: prediction).report?.state
            switch quality {
            case .any: break
            case .verified: if state != .verified { return false }
            case .unverified: if state != .unverified { return false }
            case .evidenceUnavailable: if state != .dataUnavailable { return false }
            // A record with no recorded opinion, never one judged negatively.
            case .notAssessed: if state != nil { return false }
            }
        }
        if insider != .any {
            switch (insider, StockSageInsiderActivityPresentation.state(for: prediction)) {
            case (.recordedActivity, .recorded): break
            case (.noQualifyingRows, .noQualifyingRows): break
            case (.notKnown, .notRecorded), (.notKnown, .notChecked): break
            default: return false
            }
        }
        if outcome != .any {
            let settled = run.evaluations[prediction.symbol]?.state == .evaluated
            if (outcome == .terminal) != settled { return false }
        }
        return true
    }

    func matchingPredictions(in run: StockSageResearchHistory.Run) -> [StockSageResearchHistory.Prediction] {
        guard horizon == nil || horizon == run.horizon else { return [] }
        return run.predictions.filter { matches($0, in: run) }
    }

    /// Zero-pick runs still contain coverage and comparison failures worth inspecting.
    /// Only prediction-level filters may exclude them; horizon alone is a run-level filter.
    func matches(_ run: StockSageResearchHistory.Run) -> Bool {
        guard horizon == nil || horizon == run.horizon else { return false }
        if action == .any, quality == .any, insider == .any, outcome == .any,
           query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return !matchingPredictions(in: run).isEmpty
    }
}
