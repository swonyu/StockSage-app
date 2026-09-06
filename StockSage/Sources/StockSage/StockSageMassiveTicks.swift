import Foundation

/// On-demand SIP tape. Never called by the board sweep or stream timer.
/// https://massive.com/docs/rest/stocks/trades-quotes/trades: price, decimal_size/size,
/// exchange, id, sip_timestamp (ns), sequence_number, tape, conditions, trf_id.
/// https://massive.com/docs/rest/stocks/trades-quotes/quotes: bid/ask_price/size/exchange,
/// sip_timestamp (ns), sequence_number. Both expose results[] and next_url.
/// https://massive.com/docs/rest/stocks/market-operations/exchanges: id, mic, acronym.
@MainActor
enum StockSageMassiveTicks {
    nonisolated static let pageLimit = 3
    nonisolated static let rowsPerPage = 100

    nonisolated enum Kind: String, Sendable, CaseIterable { case trades, quotes }
    nonisolated struct Trade: Sendable, Equatable {
        let price: Double
        let size: Double
        let exchange: Int64?
        let timestamp: Date
        let sequence: Int64?
    }
    nonisolated struct Exchange: Sendable, Equatable {
        let id: Int64
        let mic: String?
        let acronym: String?
        var label: String { acronym ?? mic ?? "Exchange #\(id)" }
    }
    nonisolated struct Page: Sendable {
        var trades: [Trade] = []
        var quotes: [StockSageNBBO] = []
        var rejected = 0
        var next: String?
    }
    nonisolated struct Tape: Sendable {
        var trades: [Trade] = []
        var quotes: [StockSageNBBO] = []
        var notices: [String] = []
    }
    nonisolated enum Failure: Error, LocalizedError {
        case invalidRequest, invalidPayload, http(Int), unavailable
        var errorDescription: String? {
            switch self {
            case .invalidRequest: "Invalid or unsafe tape request."
            case .invalidPayload: "Provider returned an invalid tape payload."
            case .http(let status): "Massive HTTP \(status) — check connection and endpoint entitlement."
            case .unavailable: "Tape unavailable — check Web Access, Offline Mode and the Massive key."
            }
        }
    }

    private static var exchangeCache: (at: Date, values: [Int64: Exchange])?
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    nonisolated static func request(kind: Kind, symbol: String, from: Date, to: Date, key: String) -> URLRequest? {
        guard StockSageMassive.covers(symbol), from <= to,
              let lower = nanoseconds(from), let upper = nanoseconds(to),
              var url = URLComponents(string: StockSageMassive.host + "/v3/\(kind.rawValue)/\(symbol.uppercased())") else { return nil }
        url.queryItems = [
            .init(name: "timestamp.gte", value: lower), .init(name: "timestamp.lte", value: upper),
            .init(name: "order", value: "desc"), .init(name: "sort", value: "timestamp"),
            .init(name: "limit", value: String(rowsPerPage)),
        ]
        return url.url.flatMap { authorized($0, key: key) }
    }

    /// Do not send the bearer token to a vendor-supplied different host, path, port or userinfo.
    nonisolated static func nextRequest(_ next: String, kind: Kind, symbol: String, key: String,
                                        pagesLoaded: Int, visited: Set<String>) -> URLRequest? {
        guard pagesLoaded < pageLimit, !visited.contains(next), StockSageMassive.covers(symbol),
              let parts = URLComponents(string: next), parts.scheme == "https", parts.host == "api.massive.com",
              parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.percentEncodedPath == "/v3/\(kind.rawValue)/\(symbol.uppercased())",
              !(parts.queryItems ?? []).contains(where: { $0.name.lowercased() == "apikey" }),
              let url = parts.url else { return nil }
        return authorized(url, key: key)
    }

    private nonisolated static func authorized(_ url: URL, key: String) -> URLRequest? {
        guard !key.isEmpty else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private nonisolated static func nanoseconds(_ date: Date) -> String? {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds > 0, milliseconds < Double(Int64.max / 1_000_000),
              let ms = Int64(exactly: milliseconds.rounded(.down)) else { return nil }
        return String(ms * 1_000_000)
    }

    nonisolated static func parse(_ data: Data, kind: Kind, symbol: String, from: Date, to: Date) throws -> Page {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", let rows = root["results"] as? [Any] else { throw Failure.invalidPayload }
        var page = Page()
        page.next = root["next_url"] as? String
        // ponytail: at most 100 visible rows/page even if an upstream cursor ignores our limit.
        for raw in rows.prefix(rowsPerPage) {
            guard let row = raw as? [String: Any], let ns = StockSageMassive.int64(row["sip_timestamp"]), ns > 0 else {
                page.rejected += 1; continue
            }
            let at = StockSageMassive.date(fromNanoseconds: ns)
            guard at >= from, at <= to else { page.rejected += 1; continue }
            let sequence = StockSageMassive.int64(row["sequence_number"])
            switch kind {
            case .trades:
                guard let price = StockSageMassive.finite(row["price"]), price > 0,
                      let size = StockSageMassive.finite(row["decimal_size"] ?? row["size"]), size > 0 else {
                    page.rejected += 1; continue
                }
                page.trades.append(.init(price: price, size: size, exchange: StockSageMassive.int64(row["exchange"]),
                                         timestamp: at, sequence: sequence))
            case .quotes:
                // Optional/missing sides are unavailable, never synthetic liquidity.
                let bid = row["bid_price"] == nil ? 0 : StockSageMassive.finite(row["bid_price"])
                let ask = row["ask_price"] == nil ? 0 : StockSageMassive.finite(row["ask_price"])
                let bs = row["bid_size"] == nil ? 0 : StockSageMassive.finite(row["bid_size"])
                let az = row["ask_size"] == nil ? 0 : StockSageMassive.finite(row["ask_size"])
                guard let bid, bid >= 0, let ask, ask >= 0, let bs, bs >= 0, let az, az >= 0 else {
                    page.rejected += 1; continue
                }
                page.quotes.append(.init(symbol: symbol.uppercased(), bid: bid, ask: ask, bidSize: bs, askSize: az,
                                         bidExchange: StockSageMassive.int64(row["bid_exchange"]),
                                         askExchange: StockSageMassive.int64(row["ask_exchange"]),
                                         timestamp: at, sequence: sequence))
            }
        }
        page.rejected += max(0, rows.count - rowsPerPage)
        return page
    }

    nonisolated static func parseExchanges(_ data: Data) throws -> [Int64: Exchange] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK" else { throw Failure.invalidPayload }
        // The docs' field table says array but its sample uses an object; accept either shape.
        let rows: [[String: Any]]
        if let array = root["results"] as? [[String: Any]] { rows = array }
        else if let one = root["results"] as? [String: Any] { rows = [one] }
        else { throw Failure.invalidPayload }
        var values: [Int64: Exchange] = [:]
        for row in rows {
            guard let id = StockSageMassive.int64(row["id"]), id >= 0 else { continue }
            let mic = (row["mic"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let acronym = (row["acronym"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            values[id] = Exchange(id: id, mic: mic, acronym: acronym)
        }
        guard !values.isEmpty else { throw Failure.invalidPayload }
        return values
    }

    nonisolated static func isNasdaq(_ id: Int64?, exchanges: [Int64: Exchange]) -> Bool {
        guard let id else { return false }
        return exchanges[id]?.mic == "XNAS"
    }

    static func exchanges(now: Date = Date()) async throws -> [Int64: Exchange] {
        if let cache = exchangeCache, (0..<86_400).contains(now.timeIntervalSince(cache.at)) { return cache.values }
        guard let url = URL(string: StockSageMassive.host + "/v3/reference/exchanges?asset_class=stocks&locale=us"),
              let request = authorized(url, key: StockSageMassive.apiKey) else { throw Failure.unavailable }
        let values = try parseExchanges(await data(for: request))
        exchangeCache = (now, values)
        return values
    }

    static func fetch(symbol: String, from: Date, to: Date) async -> Tape {
        var tape = Tape()
        let key = StockSageMassive.apiKey
        for kind in Kind.allCases {
            guard var request = request(kind: kind, symbol: symbol, from: from, to: to, key: key) else {
                tape.notices.append(Failure.unavailable.localizedDescription); break
            }
            var visited: Set<String> = []
            for pageIndex in 0..<pageLimit {
                do {
                    try Task.checkCancellation()
                    if let url = request.url?.absoluteString { visited.insert(url) }
                    let page = try parse(await data(for: request), kind: kind, symbol: symbol, from: from, to: to)
                    tape.trades += page.trades; tape.quotes += page.quotes
                    if page.rejected > 0 { tape.notices.append("\(kind.rawValue): \(page.rejected) invalid/out-of-window or excess rows omitted.") }
                    guard let next = page.next else { break }
                    guard let next = nextRequest(next, kind: kind, symbol: symbol, key: key,
                                                 pagesLoaded: pageIndex + 1, visited: visited) else {
                        tape.notices.append("\(kind.rawValue): partial tape — page cap or invalid/repeated cursor."); break
                    }
                    request = next
                } catch {
                    // Never display a raw networking error, URL, response body or bearer token.
                    tape.notices.append("\(kind.rawValue): \((error as? Failure)?.localizedDescription ?? "Request interrupted or failed.")")
                    break
                }
            }
            if Task.isCancelled { break }
        }
        return tape
    }

    private static func data(for request: URLRequest) async throws -> Data {
        guard ToolPolicy.isExternalAllowed else { throw Failure.unavailable }
        let (data, response) = try await session.data(for: request)
        guard ToolPolicy.isExternalAllowed else { throw Failure.unavailable }
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidPayload }
        guard response.statusCode == 200 else { throw Failure.http(response.statusCode) }
        return data
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
