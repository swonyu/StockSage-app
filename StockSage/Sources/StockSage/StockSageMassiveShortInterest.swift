import Foundation
import CoreFoundation

/// Massive short interest (https://massive.com/docs/rest/stocks/fundamentals/short-interest, reported
/// twice a month per settlement date and published with a lag) and daily short volume
/// (https://massive.com/docs/rest/stocks/fundamentals/short-volume).
/// SHADOW display evidence only. These observations are never a model fact, an evidence-coverage row,
/// a qualification/ranking/Top-5 input or an instruction to trade: research prompt v1 is frozen and
/// `Capture.coverage` is quoted to the model, so a new row or fact would change the model's inputs.
enum StockSageMassiveShortInterest {
    typealias Failure = StockSageMassiveEvents.Failure
    nonisolated static let maximumBytes = 2_000_000

    nonisolated enum Feed: String, Sendable, CaseIterable {
        case shortInterest, shortVolume

        var path: String { self == .shortInterest ? "/stocks/v1/short-interest" : "/stocks/v1/short-volume" }
        var dateField: String { self == .shortInterest ? "settlement_date" : "date" }
        var source: String { self == .shortInterest ? "Massive short interest" : "Massive short volume" }
        var dateLabel: String { self == .shortInterest ? "settlement" : "trading date" }
        var lag: String {
            switch self {
            case .shortInterest:
                "Reported twice a month and published days after settlement; it lags current positioning. Not a squeeze signal or a StockSage input."
            case .shortVolume:
                "Short-sale volume reported for one completed trading day; it is not open short interest or a position change. Not a StockSage input."
            }
        }
    }

    /// Every numeric field is optional; the provider omits null fields.
    nonisolated struct Row: Sendable, Equatable {
        let date: Date
        var shortInterest: Double? = nil
        var daysToCover: Double? = nil
        var averageDailyVolume: Double? = nil
        var shortVolume: Double? = nil
        var totalVolume: Double? = nil
        /// Percent of total volume sold short, 0...100 (provider-computed).
        var shortVolumeRatio: Double? = nil
    }

    nonisolated struct Observation: Sendable, Equatable {
        /// `answered(nil)` is a provider answer with no row, distinct from an unavailable check.
        nonisolated enum Outcome: Sendable, Equatable { case answered(Row?), unavailable(Failure) }
        let feed: Feed
        let checkedAt: Date
        let outcome: Outcome

        var line: String {
            let checked = StockSageCatalystWatch.dateStr(checkedAt)
            switch outcome {
            case .unavailable(let failure):
                return "\(feed.source): unavailable at \(checked), not an empty result. \(failure.message)"
            case .answered(nil):
                return "\(feed.source): checked \(checked); no record returned for this ticker. Not evidence of zero short activity."
            case .answered(let row?):
                let age = max(0, Int(checkedAt.timeIntervalSince(row.date) / 86_400))
                let values: [String?] = feed == .shortInterest
                    ? [row.shortInterest.map { "\(StockSageMassiveShortInterest.whole($0)) shares short" },
                       row.daysToCover.map { "\(StockSageMassiveShortInterest.decimal($0)) days to cover" },
                       row.averageDailyVolume.map { "average daily volume \(StockSageMassiveShortInterest.whole($0))" }]
                    : [row.shortVolume.map { "short volume \(StockSageMassiveShortInterest.whole($0))" },
                       row.totalVolume.map { "total volume \(StockSageMassiveShortInterest.whole($0))" },
                       row.shortVolumeRatio.map { "\(StockSageMassiveShortInterest.decimal($0))% of reported volume sold short" }]
                let supplied = values.compactMap { $0 }
                return "\(feed.source) · \(feed.dateLabel) \(StockSageCatalystWatch.dateStr(row.date)), \(age) day\(age == 1 ? "" : "s") before the \(checked) check: "
                    + (supplied.isEmpty ? "values not supplied" : supplied.joined(separator: "; ")) + ". " + feed.lag
            }
        }
    }

    nonisolated struct Snapshot: Sendable, Equatable {
        let symbol: String
        let shortInterest: Observation
        let shortVolume: Observation
        var lines: [String] { [shortInterest.line, shortVolume.line] }
    }

    private nonisolated static func whole(_ value: Double) -> String {
        String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private nonisolated static func decimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Newest record only: `sort=<date>.desc&limit=1` (the default order returns the oldest first).
    nonisolated static func request(_ feed: Feed, symbol: String, key: String) -> URLRequest? {
        guard StockSageMassive.covers(symbol), !key.isEmpty,
              var parts = URLComponents(string: StockSageMassive.host + feed.path) else { return nil }
        parts.queryItems = [.init(name: "ticker", value: symbol.uppercased()),
                            .init(name: "sort", value: feed.dateField + ".desc"),
                            .init(name: "limit", value: "1")]
        guard let url = parts.url else { return nil }
        // ponytail: 8 s (not the catalyst 12 s) bounds what this shadow check adds to a research capture.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Throws on an invalid payload or a row for a different ticker; nil means the provider answered with no row.
    nonisolated static func parse(_ data: Data, feed: Feed, symbol: String) throws -> Row? {
        guard data.count <= maximumBytes else { throw Failure.responseTooLarge }
        guard StockSageMassive.covers(symbol),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["status"] as? String == "OK", let rows = root["results"] as? [Any] else { throw Failure.invalidPayload }
        guard let first = rows.first else { return nil }
        guard rows.count == 1, let row = first as? [String: Any],
              (row["ticker"] as? String)?.uppercased() == symbol.uppercased(),
              let text = row[feed.dateField] as? String, let date = StockSageMassiveEvents.day(text) else { throw Failure.invalidPayload }
        func number(_ key: String) throws -> Double? {
            guard let value = row[key], !(value is NSNull) else { return nil }
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0 else { throw Failure.invalidPayload }
            return n.doubleValue
        }
        switch feed {
        case .shortInterest:
            return Row(date: date, shortInterest: try number("short_interest"), daysToCover: try number("days_to_cover"),
                       averageDailyVolume: try number("avg_daily_volume"))
        case .shortVolume:
            let ratio = try number("short_volume_ratio")
            if let ratio, ratio > 100 { throw Failure.invalidPayload }
            return Row(date: date, shortVolume: try number("short_volume"), totalVolume: try number("total_volume"),
                       shortVolumeRatio: ratio)
        }
    }

    nonisolated static func observation(_ response: Result<Data, Failure>, feed: Feed, symbol: String, now: Date) -> Observation {
        do { return .init(feed: feed, checkedAt: now, outcome: .answered(try parse(response.get(), feed: feed, symbol: symbol))) }
        catch { return .init(feed: feed, checkedAt: now, outcome: .unavailable(error as? Failure ?? .invalidPayload)) }
    }

    nonisolated static func gateKey(_ feed: Feed) -> String { "stocksage.massive.\(feed.rawValue).authenticationUnavailableUntil.v2" }
    private static let session = URLSession(configuration: .ephemeral, delegate: StockSageHTTP.NoRedirect(), delegateQueue: nil)

    /// Both feeds, one request each, sequentially. The caller decides whether to ask at all.
    static func fetch(symbol: String, allowed: @MainActor () -> Bool = { ToolPolicy.isExternalAllowed }) async -> Snapshot {
        let key = StockSageMassive.apiKey, revision = StockSageMassive.credentialRevision()
        let interest = await get(.shortInterest, request: request(.shortInterest, symbol: symbol, key: key),
                                 now: Date(), revision: revision, allowed: allowed)
        let interestAt = Date()
        let volume = await get(.shortVolume, request: request(.shortVolume, symbol: symbol, key: key),
                               now: Date(), revision: revision, allowed: allowed)
        return .init(symbol: symbol.uppercased(),
                     shortInterest: observation(interest, feed: .shortInterest, symbol: symbol, now: interestAt),
                     shortVolume: observation(volume, feed: .shortVolume, symbol: symbol, now: Date()))
    }

    /// Per-feed gate: 401 or 403 (entitlement is product-wide for these feeds) pauses that feed for
    /// five minutes under the current credential revision, so a 500-stock scan does not repeat a denial.
    static func get(_ feed: Feed, request: URLRequest?, now: Date, revision: String?, defaults: UserDefaults = .standard,
                    allowed: @MainActor () -> Bool = { ToolPolicy.isExternalAllowed },
                    transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async -> Result<Data, Failure> {
        guard allowed() else { return .failure(.externalAccessDisabled) }
        guard !Task.isCancelled, revision == StockSageMassive.credentialRevision(defaults) else { return .failure(.cancelled) }
        guard StockSageMassiveEarnings.isAvailable(
            unavailableUntil: StockSageMassiveCredential.denialUntil(gateKey(feed), defaults: defaults), now: now) else {
            return .failure(.cooldown)
        }
        guard let request, let url = request.url, url.scheme == "https", url.host == "api.massive.com",
              url.port == nil, !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .contains(where: { $0.name.lowercased() == "apikey" }) else { return .failure(.requestUnavailable) }
        do {
            let (data, response) = try await (transport ?? {
                try await StockSageHTTP.data(for: $0, session: session, maximumBytes: maximumBytes)
            })(request)
            guard !Task.isCancelled, revision == StockSageMassive.credentialRevision(defaults) else { return .failure(.cancelled) }
            guard allowed() else { return .failure(.externalAccessDisabled) }
            guard let response = response as? HTTPURLResponse else { return .failure(.transport) }
            if [401, 403].contains(response.statusCode) {
                StockSageMassiveCredential.recordDenial(Date().addingTimeInterval(300), gate: gateKey(feed),
                                                        revision: revision, defaults: defaults)
            }
            guard response.statusCode == 200 else { return .failure(.http(response.statusCode)) }
            guard response.url == url else { return .failure(.invalidPayload) }
            return data.count <= maximumBytes ? .success(data) : .failure(.responseTooLarge)
        } catch {
            if Task.isCancelled { return .failure(.cancelled) }
            let code = (error as? URLError)?.code
            if code == .timedOut { return .failure(.timedOut) }
            return .failure(code == .dataLengthExceedsMaximum ? .responseTooLarge : .transport)
        }
    }
}
