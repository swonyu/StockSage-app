import Foundation

/// https://massive.com/docs/rest/partners/benzinga/earnings — GET /benzinga/v1/earnings.
/// Params: ticker, date.gte/date.lte, sort=date.asc, limit. The official Python SDK's
/// massive/rest/benzinga.py also verifies the date range modifiers. Response: status,
/// results[].ticker/date/date_status, next_url; fiscal_period/actual_eps/importance
/// are documented but unused. ONLY date_status confers confirmation, never EPS.
@MainActor
enum StockSageMassiveEarnings {
    nonisolated static let source = "Massive/Benzinga earnings"
    nonisolated struct Row: Sendable, Equatable {
        let date: Date
        let confirmed: Bool
    }
    private nonisolated enum Failure: Error { case invalidPayload }
    private nonisolated static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
    private static let gateKey = "stocksage.massive.earningsUnavailableUntil"

    nonisolated static func request(symbol: String, now: Date, key: String, limit: Int = 100) -> URLRequest? {
        guard StockSageMassive.covers(symbol), !key.isEmpty, (1...100).contains(limit),
              now.timeIntervalSince1970.isFinite,
              var parts = URLComponents(string: StockSageMassive.host + "/benzinga/v1/earnings") else { return nil }
        parts.queryItems = [
            .init(name: "ticker", value: symbol.uppercased()),
            .init(name: "date.gte", value: dayFormatter.string(from: now)),
            .init(name: "date.lte", value: dayFormatter.string(from: now.addingTimeInterval(400 * 86_400))),
            .init(name: "sort", value: "date.asc"), .init(name: "limit", value: String(limit))]
        guard let url = parts.url else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Calendar-day precision in UTC, consistent with the existing catalyst calendar. Keep
    /// TODAY even after midnight; do not invent an intraday release time from the optional time.
    /// ponytail: one page/100 rows/400 days; partial or malformed answers use the next provider,
    /// never become a false "checked, none". Add pagination only if this bound is hit in practice.
    nonisolated static func parseNext(_ data: Data, symbol: String, now: Date) throws -> Row? {
        guard data.count <= 2_000_000, now.timeIntervalSince1970.isFinite,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", let raw = root["results"] as? [Any], raw.count <= 100 else {
            throw Failure.invalidPayload
        }
        if let next = root["next_url"], !(next is NSNull) {
            guard let text = next as? String, text.isEmpty else { throw Failure.invalidPayload }
        }
        let lower = dayFormatter.string(from: now)
        let upper = dayFormatter.string(from: now.addingTimeInterval(400 * 86_400))
        var candidates: [Row] = []
        for value in raw {
            guard let item = value as? [String: Any],
                  let ticker = item["ticker"] as? String, ticker.uppercased() == symbol.uppercased(),
                  let text = item["date"] as? String, text.count == 10,
                  let date = dayFormatter.date(from: text), dayFormatter.string(from: date) == text,
                  let status = item["date_status"] as? String, ["confirmed", "projected"].contains(status) else {
                throw Failure.invalidPayload
            }
            if text >= lower && text <= upper { candidates.append(.init(date: date, confirmed: status == "confirmed")) }
        }
        guard let date = candidates.map(\.date).min() else { return nil }
        // Duplicate fiscal-period rows on one date cannot upgrade conflicting statuses.
        return Row(date: date, confirmed: candidates.filter { $0.date == date }.allSatisfy(\.confirmed))
    }

    nonisolated static func availabilityOutcome(statusCode: Int?, now: Date) -> Date? {
        guard let statusCode, [401, 402, 403].contains(statusCode) else { return nil }
        return now.addingTimeInterval(86_400)
    }

    nonisolated static func isAvailable(unavailableUntil: Date?, now: Date) -> Bool {
        unavailableUntil.map { now >= $0 } ?? true
    }

    /// One status-only probe before the Store's four-wide sweep, skipped while a known
    /// rejection is cached. No response, request URL, token or headers are logged.
    static func probeAvailability() async {
        let now = Date()
        let revision = StockSageMassive.credentialRevision()
        guard ToolPolicy.isExternalAllowed, !Task.isCancelled,
              isAvailable(unavailableUntil: StockSageMassiveCredential.denialUntil(gateKey, defaults: .standard), now: now),
              let req = request(symbol: "AAPL", now: now, key: StockSageMassive.apiKey, limit: 1) else { return }
        _ = await get(req, revision: revision)
    }

    static func fetch(_ symbol: String, now: Date = Date()) async -> StockSageCatalystChain.Answer<Row?> {
        let revision = StockSageMassive.credentialRevision()
        guard ToolPolicy.isExternalAllowed, !Task.isCancelled,
              isAvailable(unavailableUntil: StockSageMassiveCredential.denialUntil(gateKey, defaults: .standard), now: now),
              let req = request(symbol: symbol, now: now, key: StockSageMassive.apiKey),
              let (data, status) = await get(req, revision: revision), status == 200 else { return .unavailable }
        do { return .answered(try parseNext(data, symbol: symbol, now: now)) }
        catch { return .unavailable }
    }

    static func get(_ request: URLRequest, revision: String?, defaults: UserDefaults = .standard,
                    allowed: () -> Bool = { ToolPolicy.isExternalAllowed },
                    transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async -> (Data, Int)? {
        guard allowed(), !Task.isCancelled, revision == StockSageMassive.credentialRevision(defaults),
              isAvailable(unavailableUntil: StockSageMassiveCredential.denialUntil(gateKey, defaults: defaults), now: Date()),
              let (data, response) = try? await (transport ?? { try await session.data(for: $0) })(request),
              !Task.isCancelled, allowed(), revision == StockSageMassive.credentialRevision(defaults),
              let response = response as? HTTPURLResponse else { return nil }
        if let until = availabilityOutcome(statusCode: response.statusCode, now: Date()) {
            StockSageMassiveCredential.recordDenial(until, gate: gateKey, revision: revision, defaults: defaults)
        }
        return (data, response.statusCode)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                    willPerformHTTPRedirection response: HTTPURLResponse,
                                    newRequest request: URLRequest,
                                    completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
