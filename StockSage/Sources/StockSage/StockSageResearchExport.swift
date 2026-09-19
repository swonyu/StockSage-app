import Foundation

/// A portable copy of one saved run. It does not import or recalculate research.
nonisolated enum StockSageResearchExport {
    struct Report: Codable, Sendable {
        var schemaVersion = 1
        let exportedAt: Date
        let scope: String
        let run: StockSageResearchHistory.Run
    }

    static func data(for run: StockSageResearchHistory.Run, at date: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Keep Foundation's lossless Date representation, also used by the saved run.
        // ISO 8601's default encoder drops subsecond evidence timestamps.
        return try encoder.encode(Report(exportedAt: date,
            scope: "Saved research, not live recommendations. This is not a complete scan: it contains the saved shortlist, original evidence, coverage and recorded review progress. Dates are seconds since 2001-01-01T00:00:00Z.",
            run: run))
    }
}
