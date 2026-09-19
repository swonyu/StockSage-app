import Foundation

/// A portable copy of one saved run. It does not import or recalculate research.
nonisolated enum StockSageResearchExport {
    struct Report: Codable, Sendable {
        var schemaVersion = 1
        let exportedAt: Date
        let scope: String
        let run: StockSageResearchHistory.Run
        var fullChecksState: StockSageResearchHistory.FullChecksState? = nil
        var fullChecks: StockSageResearchHistory.CompletedChecks? = nil
        var fullChecksRetentionPolicy: String? = nil
    }

    static func data(for run: StockSageResearchHistory.Run,
                     fullChecks: StockSageResearchHistory.FullChecksAvailability? = nil,
                     at date: Date = Date()) throws -> Data {
        guard fullChecks == nil || fullChecks?.runID == run.id else { throw CocoaError(.fileWriteInvalidFileName) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Keep Foundation's lossless Date representation, also used by the saved run.
        // ISO 8601's default encoder drops subsecond evidence timestamps.
        let scope = fullChecks?.checks == nil
            ? "This is not a complete scan: it contains the saved shortlist, original evidence, coverage and recorded review progress."
            : "Includes this run's original full checks, including nonselected and incomplete opinions, plus its saved shortlist and review progress. No evidence was refreshed or reconstructed."
        var report = Report(exportedAt: date,
            scope: "Saved research, not live recommendations. \(scope) Dates are seconds since 2001-01-01T00:00:00Z.", run: run)
        if let fullChecks {
            report.schemaVersion = 2
            report.fullChecksState = fullChecks.state
            report.fullChecks = fullChecks.checks
            report.fullChecksRetentionPolicy = StockSageResearchHistory.fullChecksRetentionPolicy
        }
        return try encoder.encode(report)
    }
}
