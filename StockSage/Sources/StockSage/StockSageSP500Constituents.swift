import Foundation
import CryptoKit

/// DataHub's Wikipedia-derived reported constituents, licensed ODC-PDDL-1.0.
/// Retrieval proves which publisher bytes were used, not an official index effective date.
nonisolated enum StockSageSP500Constituents {
    static let sourceURL = "https://raw.githubusercontent.com/datasets/s-and-p-500-companies/refs/heads/main/data/constituents.csv"
    static let sourceLabel = "DataHub reported S&P 500 constituents (Wikipedia-derived; ODC-PDDL-1.0)"
    static let maximumBytes = 1_000_000
    private static let countRange = 450...550
    private static let header = ["Symbol", "Security", "GICS Sector", "GICS Sub-Industry",
                                 "Headquarters Location", "Date added", "CIK", "Founded"]

    struct Provenance: Codable, Equatable, Sendable {
        let sourceURL: String
        let sha256: String
        let retrievedAt: Date
        let reportedCount: Int

        func valid(through date: Date) -> Bool {
            sourceURL == StockSageSP500Constituents.sourceURL
                && sha256.utf8.count == 64 && sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                && retrievedAt.timeIntervalSince1970.isFinite && retrievedAt.timeIntervalSince1970 > 0
                && date.timeIntervalSince1970.isFinite && retrievedAt <= date
                && StockSageSP500Constituents.countRange.contains(reportedCount)
        }
    }
    struct Membership: Codable, Equatable, Sendable {
        let symbol: String
        let provenance: Provenance

        func valid(for symbol: String, through date: Date) -> Bool {
            self.symbol == symbol && StockSageHorizonResearch.validTicker(symbol) && provenance.valid(through: date)
        }
    }
    struct Snapshot: Equatable, Sendable {
        let symbols: Set<String>
        let provenance: Provenance

        func membership(for symbol: String) -> Membership? {
            symbols.contains(symbol) ? Membership(symbol: symbol, provenance: provenance) : nil
        }
    }

    /// Strict parsing rejects incomplete rows; never substitutes a partial membership set.
    static func parse(_ data: Data, retrievedAt: Date) throws -> Snapshot {
        guard !data.isEmpty, data.count <= maximumBytes,
              retrievedAt.timeIntervalSince1970.isFinite, retrievedAt.timeIntervalSince1970 > 0,
              let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
        let rows = StockSageJournalCSVImport.splitRFC4180(text)
        guard rows.first?.fields == header, rows.first?.error == nil,
              countRange.contains(rows.count - 1) else { throw URLError(.cannotParseResponse) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let retrievalDay = formatter.string(from: retrievedAt)
        var symbols: Set<String> = []
        for row in rows.dropFirst() {
            guard row.error == nil, row.fields.count == header.count,
                  StockSageHorizonResearch.validTicker(row.fields[0]),
                  symbols.insert(row.fields[0]).inserted else { throw URLError(.cannotParseResponse) }
            let added = row.fields[5]
            if !added.isEmpty {
                guard added.count == 10, let date = formatter.date(from: added),
                      formatter.string(from: date) == added, added <= retrievalDay else { throw URLError(.cannotParseResponse) }
            }
        }
        return Snapshot(symbols: symbols, provenance: .init(sourceURL: sourceURL,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            retrievedAt: retrievedAt, reportedCount: symbols.count))
    }

    /// One fresh publisher response per explicit run. No credentials, cache or redirect fallback.
    @MainActor static func fetch(allowed: @MainActor () -> Bool, clock: @MainActor () -> Date = Date.init,
        transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> Snapshot {
        try Task.checkCancellation()
        guard allowed() else { throw CancellationError() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: StockSageHTTP.NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: sourceURL)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let response: (Data, URLResponse)
        if let transport { response = try await transport(request) }
        else { response = try await StockSageHTTP.data(for: request, session: session, maximumBytes: maximumBytes) }
        try Task.checkCancellation()
        guard allowed() else { throw CancellationError() }
        guard let http = response.1 as? HTTPURLResponse, http.statusCode == 200,
              http.url == request.url else { throw URLError(.badServerResponse) }
        return try parse(response.0, retrievedAt: clock())
    }
}
