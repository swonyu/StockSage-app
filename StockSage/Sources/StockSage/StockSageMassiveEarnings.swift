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
    nonisolated struct Observation: Sendable, Equatable {
        enum Outcome: Sendable, Equatable { case answered(Row?), unavailable, notRequested }
        enum NotRequestedReason: Sendable, Equatable {
            case externalAccessDisabled, cancelled, requestUnavailable
            case priorAuthenticationRejection(checkedAt: Date)
        }
        let outcome: Outcome
        /// Nil means no transport was started. Failed transports retain their attempt time.
        let checkedAt: Date?
        let recordedAt: Date
        var notRequestedReason: NotRequestedReason? = nil
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
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()
    // Only this versioned key can establish a recent HTTP 401. The old gate also stored
    // unqualified 402/403 responses for a day, so it cannot provide authentication provenance.
    private static let gateKey = "stocksage.massive.earningsAuthenticationUnavailableUntil.v2"

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
        guard statusCode == 401, now.timeIntervalSince1970.isFinite else { return nil }
        return now.addingTimeInterval(300)
    }

    nonisolated static func isAvailable(unavailableUntil: Date?, now: Date) -> Bool {
        guard let until = unavailableUntil, until.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite else { return true }
        let remaining = until.timeIntervalSince(now)
        return remaining <= 0 || remaining > 300
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
        switch await observe(symbol, now: now).outcome {
        case .answered(let row): return .answered(row)
        case .unavailable, .notRequested: return .unavailable
        }
    }

    static func observe(_ symbol: String, now: Date = Date()) async -> Observation {
        guard !Task.isCancelled else {
            return .init(outcome: .notRequested, checkedAt: nil, recordedAt: Date(), notRequestedReason: .cancelled)
        }
        guard ToolPolicy.isExternalAllowed else {
            return .init(outcome: .notRequested, checkedAt: nil, recordedAt: Date(), notRequestedReason: .externalAccessDisabled)
        }
        return await observe(symbol, now: now, key: StockSageMassive.apiKey,
            revision: StockSageMassive.credentialRevision())
    }

    /// The same request and parser as the fallback chain, with a receipt that does not label
    /// local suppression as a provider check. Tests supply every credential and transport.
    static func observe(_ symbol: String, now: Date, key: String, revision: String?,
        defaults: UserDefaults = .standard, allowed: () -> Bool = { ToolPolicy.isExternalAllowed },
        clock: @escaping () -> Date = { Date() },
        transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async -> Observation {
        func notRequested() -> Observation {
            let at = clock()
            let reason: Observation.NotRequestedReason
            if Task.isCancelled { reason = .cancelled }
            else if !allowed() { reason = .externalAccessDisabled }
            else if revision != StockSageMassive.credentialRevision(defaults) { reason = .requestUnavailable }
            else if let until = StockSageMassiveCredential.denialUntil(gateKey, defaults: defaults),
                    !isAvailable(unavailableUntil: until, now: at) {
                reason = .priorAuthenticationRejection(checkedAt: until.addingTimeInterval(-300))
            } else { reason = .requestUnavailable }
            return .init(outcome: .notRequested, checkedAt: nil, recordedAt: at, notRequestedReason: reason)
        }
        guard !Task.isCancelled, allowed(), revision == StockSageMassive.credentialRevision(defaults),
              let request = request(symbol: symbol, now: now, key: key) else { return notRequested() }
        var attemptedAt: Date?
        let response = await get(request, revision: revision, defaults: defaults, allowed: allowed, clock: clock,
            transport: { request in
                attemptedAt = clock()
                if let transport { return try await transport(request) }
                return try await StockSageHTTP.data(for: request, session: session, maximumBytes: 2_000_000)
            })
        guard let attemptedAt else { return notRequested() }
        let recordedAt = clock()
        guard let (data, status) = response, status == 200 else {
            return .init(outcome: .unavailable, checkedAt: attemptedAt, recordedAt: recordedAt)
        }
        do {
            return .init(outcome: .answered(try parseNext(data, symbol: symbol, now: now)),
                checkedAt: attemptedAt, recordedAt: recordedAt)
        } catch {
            return .init(outcome: .unavailable, checkedAt: attemptedAt, recordedAt: recordedAt)
        }
    }

    static func get(_ request: URLRequest, revision: String?, defaults: UserDefaults = .standard,
                    allowed: () -> Bool = { ToolPolicy.isExternalAllowed },
                    clock: () -> Date = { Date() },
                    transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async -> (Data, Int)? {
        guard allowed(), !Task.isCancelled, revision == StockSageMassive.credentialRevision(defaults),
              isAvailable(unavailableUntil: StockSageMassiveCredential.denialUntil(gateKey, defaults: defaults), now: clock()),
              let (data, response) = try? await (transport ?? {
                  try await StockSageHTTP.data(for: $0, session: session, maximumBytes: 2_000_000)
              })(request),
              !Task.isCancelled, allowed(), revision == StockSageMassive.credentialRevision(defaults),
              data.count <= 2_000_000, let response = response as? HTTPURLResponse,
              response.url == request.url else { return nil }
        if let until = availabilityOutcome(statusCode: response.statusCode, now: clock()) {
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
